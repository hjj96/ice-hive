// ================================================================
//  Native bridge for the iOS app (Capacitor) — bundled by esbuild into www/native.js (IIFE) and loaded
//  before the game. In the iOS shell it defines window.__native, the only surface the game talks to:
//
//    window.__native = {
//      platform: 'ios',
//      ready,             // Promise<void>: saved Preferences ('ledulei.*') copied into localStorage; 1.5 s cap, never rejects
//      haptic(kind),      // 'light'|'medium'|'heavy'|'success'|'warning'|'error'|'select' (throttled per kind)
//      setHaptics(on), hapticsOn(),   // the «Вибрация» setting (persisted)
//      save(key, json),   // mirror of the game's store.set into Preferences
//      booted(),          // first frame drawn: fade the launch splash out
//    }
//
//  It also hides the status bar, routes App pause/resume to window.__game, and makes the page's audio
//  session 'ambient' (mixes with the user's music, obeys the silent switch) where WebKit exposes it.
//
//  In a plain browser (and in the claude.ai artifact, which never loads this file) it defines nothing:
//  Capacitor and the plugins are imported lazily, only once a native shell has been detected.
// ================================================================

const PREFIX = 'ledulei.';            // the game's localStorage namespace (store.get / store.set)
const HAPTICS_KEY = PREFIX + 'haptics';
const READY_TIMEOUT = 1500;           // never hold the game's boot longer than this
const SPLASH_FALLBACK = 8000;         // hide the splash even if the game never reports a drawn frame
const SPLASH_FADE = 250;

// minimum gap between two haptics of the same kind (ms); impacts and the selection tick also share a short global gap
const HAPTIC_GAP = { light: 90, medium: 150, heavy: 250, select: 60, success: 400, warning: 600, error: 600 };
const IMPACT_GAP = 35;

const w = window;
const noop = () => {};
const quiet = (p) => { if (p && typeof p.catch === 'function') p.catch(noop); return p; };

// The iOS shell injects window.Capacitor (isNativePlatform() === true) and the 'bridge' message handler at
// document start, before any page script runs; a browser has neither.
function nativeShell() {
  try {
    if (w.Capacitor && typeof w.Capacitor.isNativePlatform === 'function' && w.Capacitor.isNativePlatform()) return true;
    return !!(w.webkit && w.webkit.messageHandlers && w.webkit.messageHandlers.bridge) || !!w.androidBridge;
  } catch (e) {
    return false;
  }
}

const ls = {
  get(k) { try { return w.localStorage.getItem(k); } catch (e) { return null; } },
  set(k, v) { try { w.localStorage.setItem(k, v); } catch (e) { /* storage unavailable */ } },
  keys() {
    const out = [];
    try { for (let i = 0; i < w.localStorage.length; i++) { const k = w.localStorage.key(i); if (k && k.startsWith(PREFIX)) out.push(k); } } catch (e) { /* storage unavailable */ }
    return out;
  },
};

function install() {
  // Audio first: the game creates its AudioContext on the first tap, after this has run.
  try { if (navigator.audioSession) navigator.audioSession.type = 'ambient'; } catch (e) { /* older WebKit */ }

  // Capacitor core + plugins, evaluated only here (esbuild inlines these dynamic imports as lazy modules).
  const plugins = Promise.all([
    import('@capacitor/core'),
    import('@capacitor/preferences'),
    import('@capacitor/haptics'),
    import('@capacitor/app'),
    import('@capacitor/status-bar'),
    import('@capacitor/splash-screen'),
  ]).then(([core, prefs, haptics, app, statusBar, splash]) => {
    if (!core.Capacitor.isNativePlatform()) return null;
    return {
      Preferences: prefs.Preferences,
      Haptics: haptics.Haptics, ImpactStyle: haptics.ImpactStyle, NotificationType: haptics.NotificationType,
      App: app.App, StatusBar: statusBar.StatusBar, SplashScreen: splash.SplashScreen,
    };
  }).catch(() => null);
  let P = null;   // the loaded plugins (null until then, or when unavailable)

  // ---------- settings: Preferences -> localStorage, before the game reads them ----------
  let settled = false;     // ready has resolved: a late restore must not overwrite what the game wrote since
  let hapticsEnabled = ls.get(HAPTICS_KEY) !== 'false';
  const restore = plugins.then(async (p) => {
    if (!p) return;
    const { keys } = await p.Preferences.keys();
    const mine = (keys || []).filter((k) => k.startsWith(PREFIX));
    const pairs = await Promise.all(mine.map((key) => p.Preferences.get({ key }).then((r) => [key, r && r.value], () => [key, null])));
    if (settled) return;
    for (const [key, value] of pairs) if (typeof value === 'string') ls.set(key, value);
    // keys only localStorage has (a write cut short when the app was killed): push them to the durable store
    for (const key of ls.keys()) if (!mine.includes(key)) { const v = ls.get(key); if (v != null) quiet(p.Preferences.set({ key, value: v })); }
    hapticsEnabled = ls.get(HAPTICS_KEY) !== 'false';
  });
  const ready = Promise.race([
    restore.catch(noop),
    new Promise((resolve) => setTimeout(resolve, READY_TIMEOUT)),
  ]).then(() => { settled = true; }, () => { settled = true; });

  // ---------- writes ----------
  // Reactions on one promise run in registration order, so rapid toggles are posted to native in order (and
  // Capacitor runs a plugin's calls on one serial queue) without waiting for each other: a slow write never
  // holds the next one back.
  function save(key, json) {
    if (typeof key !== 'string' || json == null) return;
    if (!key.startsWith(PREFIX)) key = PREFIX + key;
    const value = String(json);
    plugins.then((p) => p && p.Preferences.set({ key, value })).catch(noop);
  }

  // ---------- haptics ----------
  const lastAt = Object.create(null);
  let lastImpact = -1e9, selecting = false;
  function haptic(kind) {
    if (!hapticsEnabled || !P) return;
    const gap = HAPTIC_GAP[kind];
    if (gap === undefined) return;
    const now = performance.now();
    if (now - (lastAt[kind] || -1e9) < gap) return;
    const notify = kind === 'success' || kind === 'warning' || kind === 'error';
    if (!notify && now - lastImpact < IMPACT_GAP) return;
    lastAt[kind] = now;
    if (!notify) lastImpact = now;
    const H = P.Haptics;
    try {
      if (kind === 'light') quiet(H.impact({ style: P.ImpactStyle.Light }));
      else if (kind === 'medium') quiet(H.impact({ style: P.ImpactStyle.Medium }));
      else if (kind === 'heavy') quiet(H.impact({ style: P.ImpactStyle.Heavy }));
      else if (kind === 'success') quiet(H.notification({ type: P.NotificationType.Success }));
      else if (kind === 'warning') quiet(H.notification({ type: P.NotificationType.Warning }));
      else if (kind === 'error') quiet(H.notification({ type: P.NotificationType.Error }));
      else if (kind === 'select') {
        // UISelectionFeedbackGenerator only ticks between selectionStart and selectionEnd: keep one open
        if (!selecting) { selecting = true; quiet(H.selectionStart()); }
        quiet(H.selectionChanged());
      }
    } catch (e) { /* plugin missing: stay silent */ }
  }
  function setHaptics(on) {
    hapticsEnabled = !!on;
    const json = JSON.stringify(hapticsEnabled);
    ls.set(HAPTICS_KEY, json);
    save(HAPTICS_KEY, json);
  }

  // ---------- launch splash ----------
  let splashDone = false;
  function booted() {
    if (splashDone) return;
    splashDone = true;
    plugins.then((p) => p && p.SplashScreen.hide({ fadeOutDuration: SPLASH_FADE })).catch(noop);
  }
  setTimeout(booted, SPLASH_FALLBACK);

  // ---------- shell setup once the plugins are loaded ----------
  plugins.then((p) => {
    if (!p) return;
    P = p;
    quiet(p.StatusBar.hide());
    if (hapticsEnabled) { selecting = true; quiet(p.Haptics.selectionStart()); }   // warm the selection generator
    const pause = () => { try { w.__game && w.__game.pause && w.__game.pause(); } catch (e) { /* game not booted */ } };
    const resume = () => { try { w.__game && w.__game.resume && w.__game.resume(); } catch (e) { /* game not booted */ } };
    // didEnterBackground / willEnterForeground
    quiet(p.App.addListener('pause', pause));
    quiet(p.App.addListener('resume', resume));
    // willResignActive (Control Centre, an incoming call banner, the app switcher) pauses a fight too
    quiet(p.App.addListener('appStateChange', (s) => { if (s && s.isActive) resume(); else pause(); }));
  }).catch(noop);

  w.__native = Object.freeze({
    platform: w.androidBridge ? 'android' : 'ios',
    ready,
    haptic,
    setHaptics,
    hapticsOn: () => hapticsEnabled,
    save,
    booted,
  });
}

if (nativeShell() && !w.__native) install();
