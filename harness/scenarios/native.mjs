// iOS bridge + game hook checks.
//
//   In the fake iOS shell (real Capacitor native-bridge.js, JS stand-in for the plugins):
//     node harness/run.mjs --www --fake-ios --scenario harness/scenarios/native.mjs --prefs @harness/scenarios/native-prefs.json [--landscape]
//   Slow native storage (ready must give up after 1.5 s and the late restore must not clobber anything):
//     ... --native-delay 2500
//   In a plain browser (www or artifact) — the bridge and every hook must stay inert:
//     node harness/run.mjs --www --scenario harness/scenarios/native.mjs
export default async (page, h) => {
  const { log, fail, sleep, shot, native } = h;
  const expect = (cond, msg) => { if (cond) log('[ok]', msg); else fail(msg); };
  const fake = !!h.args['fake-ios'];
  const delay = Number(h.args['native-delay'] || 0);
  const screen = async () => (await h.stats()).screen;
  const visible = (sel) => page.evaluate((s) => { const el = document.querySelector(s); if (!el) return null; const r = el.getBoundingClientRect(); return { text: el.textContent, w: r.width, h: r.height, x: r.x + r.width / 2, y: r.y + r.height / 2, bottom: r.bottom, vh: innerHeight }; }, sel);
  const tap = async (sel) => {
    const v = await visible(sel);
    if (!v || !v.w) { fail('cannot tap ' + sel + ' (not visible)'); return; }
    if (h.mobile) await h.touch.tap(v.x, v.y); else await page.mouse.click(v.x, v.y);
    await sleep(250);
  };

  if (!fake) {
    const env = await page.evaluate(() => ({
      native: typeof window.__native, game: typeof window.__game, capacitor: typeof window.Capacitor,
      vib: !!document.getElementById('pHaptics'), lsKeys: Object.keys(localStorage),
    }));
    expect(env.native === 'undefined' && env.game === 'undefined' && env.capacitor === 'undefined', 'plain browser: bridge defines nothing ' + JSON.stringify(env));
    expect(!env.vib, 'plain browser: no «Вибрация» button');
    await page.evaluate(() => window.__dbg.start('pyro'));
    await sleep(500);
    await page.keyboard.press('Escape');
    await sleep(300);
    const items = await page.evaluate(() => [...document.querySelectorAll('#sPause .btn')].map((b) => b.textContent));
    expect(!items.some((t) => t.startsWith('Вибрация')), 'plain browser pause menu: ' + items.join(' | '));
    await shot('pause-plain');
    return;
  }

  const calls = async (plugin, method) => (await native.calls()).filter((c) => c.plugin === plugin && (!method || c.method === method));
  const haptics = async () => (await calls('Haptics')).filter((c) => c.method !== 'selectionStart')
    .map((c) => (c.method === 'impact' ? c.options.style : c.method === 'notification' ? c.options.type : 'SELECT'));
  const count = (list) => list.reduce((o, k) => ((o[k] = (o[k] || 0) + 1), o), {});

  // ---- 1. bridge surface
  const surf = await page.evaluate(() => { const n = window.__native; return n && { platform: n.platform, frozen: Object.isFrozen(n), keys: Object.keys(n).sort().join(','), ready: n.ready instanceof Promise, on: n.hapticsOn() }; });
  expect(surf && surf.platform === 'ios' && surf.ready && surf.frozen, '__native: ' + JSON.stringify(surf));

  // ---- 2. settings restored from Preferences before boot (or, slow storage: boot after the 1.5 s cap, no clobbering)
  const seeded = await page.evaluate(() => ({ ...window.__fakeNative.prefs }));   // what Preferences held at launch (none written yet)
  const ls = await page.evaluate(() => { const o = {}; for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); o[k] = localStorage.getItem(k); } return o; });
  const st0 = await h.stats();
  const splash = await calls('SplashScreen', 'hide');
  if (!delay) {
    for (const k in seeded) expect(ls[k] === seeded[k], `restored ${k} -> localStorage ${ls[k]}`);
    if (seeded['ledulei.cls']) expect(st0.player.cls === JSON.parse(seeded['ledulei.cls']), 'title preselects the restored class: ' + st0.player.cls);
    if (seeded['ledulei.muted']) expect(st0.muted === JSON.parse(seeded['ledulei.muted']), 'restored mute setting: ' + st0.muted);
    const lastGet = Math.max(0, ...(await calls('Preferences', 'get')).map((c) => c.t));
    expect(splash.length === 1 && splash[0].t >= lastGet, `splash hidden once, after the restore (get@${lastGet} ms, hide@${splash[0] && splash[0].t} ms)`);
  } else {
    expect(splash.length === 1 && splash[0].t >= 1400 && splash[0].t < delay + 1500, `slow storage: boot waited for the 1.5 s cap only (splash hide @${splash[0] && splash[0].t} ms)`);
    expect(st0.player.cls === 'assault', 'slow storage: booted with defaults, cls ' + st0.player.cls);
    await sleep(delay * 2 + 500);   // let keys() + get() finally answer
    const ls2 = await page.evaluate(() => localStorage.getItem('ledulei.cls'));
    expect(ls2 == null, 'late restore did not overwrite localStorage after ready (ledulei.cls ' + ls2 + ')');
  }
  expect(splash.length === 1 && splash[0].options.fadeOutDuration === 250, 'SplashScreen.hide({fadeOutDuration:250})');
  expect((await calls('StatusBar', 'hide')).length === 1, 'StatusBar.hide() once');
  const evs = (await native.listeners()).map((l) => l.pluginId + ':' + l.eventName).sort();
  expect(['App:appStateChange', 'App:pause', 'App:resume'].every((e) => evs.includes(e)), 'App listeners: ' + evs.join(', '));

  // ---- 3. the title attract mode never buzzes
  const n0 = (await haptics()).length;
  await sleep(2000);
  expect((await haptics()).length === n0, 'no haptics during the title attract mode (' + n0 + ')');
  await shot('title');

  // ---- 4. store.set mirrors into Preferences
  await page.evaluate(() => window.__dbg.start('assault'));
  await sleep(700);
  expect((await native.prefs())['ledulei.cls'] === '"assault"', 'store.set mirrored: Preferences ledulei.cls = ' + (await native.prefs())['ledulei.cls']);

  // ---- 5. gameplay haptics
  await page.evaluate(() => window.__dbg.horde(30));                 // horde banner -> WARNING
  await sleep(500);
  await page.mouse.move(h.width / 2 + 30, h.height / 2 + 10);        // aim a grenade a few metres away
  await page.keyboard.press('KeyQ');                                 // ability -> LIGHT, frag blast near the player -> MEDIUM
  await sleep(1600);
  await page.keyboard.press('Space');                                // dash -> SELECT
  await sleep(300);
  await page.evaluate(() => { window.__dbg.spawn(40, 'runner'); window.__dbg.spawn(3, 'brute'); });
  await sleep(4000);                                                 // bites -> LIGHT, brute hits / charges -> HEAVY
  await page.evaluate(() => window.__dbg.levelup());                 // level-up screen -> SUCCESS
  await sleep(900);
  if ((await screen()) === 'levelup') await tap('#lvCards .card');   // card picked -> SELECT
  await sleep(300);
  log('[haptics] gameplay:', count(await haptics()));
  await shot('combat');

  // ---- 6. backgrounding: App 'pause' pauses a running mission and parks the audio; 'resume' wakes the audio only
  if ((await screen()) === 'levelup') await tap('#lvCards .card');
  expect((await screen()) === 'playing', 'back in the fight before the pause test (' + (await screen()) + ')');
  await native.fire('App', 'pause');
  await sleep(400);
  let st = await h.stats();
  expect(st.screen === 'paused' && st.audio === 'suspended', `App pause -> screen ${st.screen}, audio ${st.audio}`);
  await native.fire('App', 'resume');
  await sleep(700);
  st = await h.stats();
  expect(st.screen === 'paused' && st.audio === 'running', `App resume -> screen ${st.screen} (stays paused), audio ${st.audio}`);

  // ---- 7. «Вибрация» toggle in the pause menu
  const vib = await visible('#pHaptics');
  expect(vib && vib.w > 0 && vib.text === 'Вибрация: вкл', 'pause menu shows ' + JSON.stringify(vib && vib.text));
  const box = await visible('#sPause .m-box');
  expect(box && box.bottom <= box.vh + 1, `pause menu fits the screen (bottom ${box && box.bottom.toFixed(0)} / ${box && box.vh})`);
  // the smallest iOS 15 screens (iPhone SE 1st gen / iPod touch 7): «Сдаться» must be reachable without scrolling
  for (const [w, hh] of [[568, 320], [320, 568]]) {
    await page.setViewportSize({ width: w, height: hh });
    await sleep(400);
    const fit = await page.evaluate(() => {
      const s = document.getElementById('sPause'), b = document.querySelector('#sPause .m-box').getBoundingClientRect();
      const q = document.getElementById('pQuit').getBoundingClientRect();
      return { bottom: Math.round(b.bottom), quit: Math.round(q.bottom), vh: innerHeight, scroll: s.scrollHeight - s.clientHeight };
    });
    expect(fit.bottom <= fit.vh && fit.quit <= fit.vh && fit.scroll <= 0, `pause menu fits ${w}x${hh}: ${JSON.stringify(fit)}`);
  }
  await page.setViewportSize({ width: h.width, height: h.height });
  await sleep(400);
  await shot('pause-menu');
  await tap('#pHaptics');
  const off = await page.evaluate(() => ({ text: document.getElementById('pHaptics').textContent, on: window.__native.hapticsOn(), ls: localStorage.getItem('ledulei.haptics') }));
  await sleep(200);
  expect(off.text === 'Вибрация: выкл' && !off.on && off.ls === 'false' && (await native.prefs())['ledulei.haptics'] === 'false', 'toggle off: ' + JSON.stringify(off));
  const before = (await haptics()).length;
  await page.evaluate(() => { for (const k of ['light', 'medium', 'heavy', 'success', 'warning', 'error', 'select']) window.__native.haptic(k); });
  await sleep(200);
  expect((await haptics()).length === before, 'haptics off: no Haptics calls reach native');
  await tap('#pHaptics');
  await sleep(200);
  const on = await page.evaluate(() => ({ text: document.getElementById('pHaptics').textContent, on: window.__native.hapticsOn() }));
  expect(on.text === 'Вибрация: вкл' && on.on && (await native.prefs())['ledulei.haptics'] === 'true', 'toggle back on: ' + JSON.stringify(on));

  // ---- 8. throttling: a burst of 50 light calls in one frame reaches native once
  const b0 = (await haptics()).length;
  await sleep(150);
  await page.evaluate(() => { for (let i = 0; i < 50; i++) window.__native.haptic('light'); });
  await sleep(200);
  expect((await haptics()).length - b0 === 1, 'throttle: 50 light calls -> ' + ((await haptics()).length - b0) + ' native call');

  // ---- 9. Control Centre / call banner (appStateChange inactive) pauses too
  await tap('#pResume');
  expect((await screen()) === 'playing', 'resumed by the player');
  await native.fire('App', 'appStateChange', { isActive: false });
  await sleep(300);
  expect((await screen()) === 'paused', 'appStateChange(isActive:false) -> paused');
  await native.fire('App', 'appStateChange', { isActive: true });
  await tap('#pResume');

  // ---- 10. beacons + victory (success), then a lost fight (downed + defeat: error)
  await page.evaluate(() => window.__dbg.god(true));
  for (let i = 0; i < 24 && (await screen()) !== 'won'; i++) {
    const s = await screen();
    if (s === 'levelup') { await sleep(700); await tap('#lvCards .card'); continue; }
    await page.evaluate(() => window.__dbg.skip());
    await sleep(700);
  }
  expect((await screen()) === 'won', 'mission won via skip()');
  await sleep(300);
  await shot('won');
  const hw = count(await haptics());
  log('[haptics] after the win:', hw);
  await tap('#eAgain');
  // the player stands still without firing while waves of brutes and boomers pile in (bots revive, so it takes a while)
  const lost = await page.evaluate(() => {
    window.__dbg.god(false);
    let s = 'playing';
    for (let i = 0; i < 40 && s === 'playing'; i++) {
      window.__dbg.spawn(200, 'runner'); window.__dbg.spawn(25, 'brute'); window.__dbg.spawn(40, 'boomer');
      s = window.__dbg.fast(10).screen;
    }
    return s;
  });
  await sleep(500);
  expect(lost === 'lost', 'overrun squad -> ' + lost);
  const all = count(await haptics());
  log('[haptics] total:', all);
  for (const k of ['LIGHT', 'MEDIUM', 'HEAVY', 'SUCCESS', 'WARNING', 'ERROR', 'SELECT']) expect(all[k] > 0, 'haptic kind fired: ' + k + ' x' + (all[k] || 0));
  await shot('lost');
};
