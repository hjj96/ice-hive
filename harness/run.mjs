// Local test harness for «Ледяной Улей» — drives headless Chromium (SwiftShader WebGL) through Playwright.
//
// Two targets:
//   artifact (default)  --file dist/artifact.html
//       Wraps the page in the same skeleton the Artifact platform adds, applies an approximation of its CSP,
//       serves three.js for cdn.jsdelivr.net from node_modules/three, stubs Google Fonts (offline).
//   www                 --www [dir]          (default dir: www)
//       Serves every file of the iOS web bundle from a fake origin. ALL other requests are blocked and reported
//       (the app must work fully offline). Add --fake-ios to run inside a simulated Capacitor iOS shell
//       (real native-bridge.js, JS stand-in for the native plugins; see harness/fake-ios.mjs).
//
// Usage:
//   node harness/run.mjs [--file F | --www [DIR]] [--scenario smoke|play|mobile|bench|fonts|<path.mjs>]
//        [--seconds 8] [--out harness/out/name] [--cls assault|pyro|cryo|gunner]
//        [--mobile] [--landscape] [--width W] [--height H] [--dpr N]
//        [--fake-ios] [--prefs JSON|@file.json] [--ls JSON] [--native-delay MS] [--quiet] [--verbose]
// A custom scenario file exports: default async function (page, h) { ... }
//   h = { shot(name), stats(), sleep(ms), log(...), fail(msg), touch, keys, mouse, args, logs, page, width, height, native }
// Exit code 1 on page errors, console errors, failed / blocked / external requests, 404s or a scenario error.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { fakeIosInitScript } from './fake-ios.mjs';

let chromium;
try { ({ chromium } = await import('playwright')); }
catch (e) { console.error('[harness] cannot load Playwright (a devDependency) — run `npm ci` in the repo root (' + e.message + ')'); process.exit(2); }

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const THREE_DIR = path.join(ROOT, 'node_modules', 'three');

const argv = process.argv.slice(2);
const args = {};
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a.startsWith('--')) {
    const k = a.slice(2);
    const v = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true;
    args[k] = v;
  }
}
const WWW = args.www ? path.resolve(ROOT, args.www === true ? 'www' : String(args.www)) : null;
const FILE = WWW ? null : path.resolve(ROOT, args.file || 'dist/artifact.html');
const SCENARIO = args.scenario || 'smoke';
const SECONDS = Number(args.seconds || 8);
const FAKE_IOS = !!args['fake-ios'];
const TAG = (WWW ? 'www-' : 'artifact-') + (FAKE_IOS ? 'ios-' : '') + path.basename(String(SCENARIO), '.mjs') + (args.landscape ? '-land' : '');
const OUT = path.resolve(ROOT, args.out || `harness/out/${TAG}`);
const CLS = args.cls || 'assault';
const QUIET = !!args.quiet;
fs.mkdirSync(path.dirname(OUT), { recursive: true });
if (WWW && !fs.existsSync(path.join(WWW, 'index.html'))) { console.error('[harness] no ' + path.join(WWW, 'index.html') + ' — run npm run build first'); process.exit(2); }
if (FILE && !fs.existsSync(FILE)) { console.error('[harness] no ' + FILE + ' — run npm run build:artifact first'); process.exit(2); }

// Same skeleton the Artifact tool wraps around the page at publish time.
const SKELETON_HEAD = `<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<style>:root{color-scheme:light;padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}
body{margin:0;font:14px/1.4 system-ui,-apple-system,sans-serif}img{max-width:100%}[hidden]{display:none!important}</style>
</head><body>`;
const SKELETON_TAIL = `</body></html>`;

// Approximation of the artifact CSP allowlist (scripts only from the allowed CDNs, styles only Google Fonts).
const CSP = [
  "default-src 'self' data: blob:",
  "script-src 'self' 'unsafe-inline' blob: https://cdnjs.cloudflare.com https://cdn.jsdelivr.net/npm/ https://unpkg.com https://cdn.tailwindcss.com https://code.jquery.com",
  "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
  "font-src 'self' data: https://fonts.gstatic.com",
  "img-src 'self' data: blob:",
  "media-src 'self' data: blob:",
  "connect-src 'self' data: blob:",
  "worker-src 'self' blob:",
].join('; ');

const ORIGIN = WWW ? 'https://app.local' : 'https://artifact.local';
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript; charset=utf-8', '.mjs': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.woff2': 'font/woff2', '.woff': 'font/woff', '.json': 'application/json', '.txt': 'text/plain; charset=utf-8',
  '.map': 'application/json', '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon' };
const logs = [];
// --quiet still prints the verdict, the environment lines and anything that makes the run fail
const LOUD = /^\[(harness\] RESULT|FAIL\]|pageerror\]|console\.error\]|harness\] BLOCKED|harness\] 404|harness\] MISSING|requestfailed\]|env\]|fonts\])/;
const log = (...a) => { const s = a.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' '); logs.push(s); if (!QUIET || LOUD.test(s)) console.log(s); };
const problems = { pageErrors: 0, consoleErrors: 0, consoleWarnings: 0, external: [], missing: [], failed: [], scenario: [] };

const mobile = SCENARIO === 'mobile' || !!args.mobile || (FAKE_IOS && !args.desktop);
const landscape = !!args.landscape;
const width = Number(args.width || (mobile ? (landscape ? 844 : 390) : 1280));
const height = Number(args.height || (mobile ? (landscape ? 390 : 844) : 720));
const dpr = Number(args.dpr || (mobile ? 2 : 1));

const browser = await chromium.launch({
  args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--autoplay-policy=no-user-gesture-required', '--enable-webgl'],
});
const context = await browser.newContext({
  viewport: { width, height },
  deviceScaleFactor: dpr,
  isMobile: !!mobile,
  hasTouch: !!mobile,
  userAgent: mobile ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1' : undefined,
});
const page = await context.newPage();

if (args.ls) {
  const seed = typeof args.ls === 'string' ? JSON.parse(args.ls) : {};
  await page.addInitScript((s) => { try { for (const k in s) if (localStorage.getItem(k) == null) localStorage.setItem(k, s[k]); } catch (e) { /* no storage */ } }, seed);
}
if (FAKE_IOS) {
  await page.exposeFunction('__harnessNative', (s) => log('[native]', s));
  // --prefs '{"ledulei.cls":"\"cryo\""}' or --prefs @file.json: what native Preferences already holds at launch
  const prefs = typeof args.prefs === 'string' ? JSON.parse(args.prefs.startsWith('@') ? fs.readFileSync(path.resolve(ROOT, args.prefs.slice(1)), 'utf8') : args.prefs) : {};
  await page.addInitScript({ content: fakeIosInitScript(ROOT, { prefs, delayMs: Number(args['native-delay'] || 0) }) });
}

const served = [];
await page.route('**/*', async (route) => {
  const url = route.request().url();
  if (url.startsWith('data:') || url.startsWith('blob:')) return route.continue();
  if (WWW) {
    if (url.startsWith(ORIGIN + '/')) {
      let rel = decodeURIComponent(new URL(url).pathname).replace(/^\/+/, '') || 'index.html';
      const p = path.resolve(WWW, rel);
      if (!p.startsWith(WWW + path.sep) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) {
        problems.missing.push(rel); log('[harness] 404', rel);
        return route.fulfill({ status: 404, body: 'not found' });
      }
      served.push(rel);
      return route.fulfill({ status: 200, contentType: MIME[path.extname(p)] || 'application/octet-stream', body: fs.readFileSync(p) });
    }
    problems.external.push(url);
    log('[harness] BLOCKED external request (www must be offline):', url);
    return route.abort();
  }
  if (url === ORIGIN + '/' || url === ORIGIN + '/index.html') {
    const body = SKELETON_HEAD + fs.readFileSync(FILE, 'utf8') + SKELETON_TAIL;
    return route.fulfill({ status: 200, contentType: 'text/html; charset=utf-8', headers: { 'content-security-policy': CSP }, body });
  }
  const m = url.match(/^https:\/\/cdn\.jsdelivr\.net\/npm\/three@0\.170\.0\/(.+)$/);
  if (m) {
    const p = path.join(THREE_DIR, m[1].split('?')[0]);
    if (fs.existsSync(p)) return route.fulfill({ status: 200, contentType: 'application/javascript', headers: { 'access-control-allow-origin': '*' }, body: fs.readFileSync(p) });
    problems.missing.push(m[1]); log('[harness] MISSING three.js file', p);
    return route.fulfill({ status: 404, body: 'not found' });
  }
  if (/^https:\/\/fonts\.(googleapis|gstatic)\.com\//.test(url)) {
    // No outbound network here: serve empty CSS so fallback fonts are used.
    return route.fulfill({ status: 200, contentType: 'text/css', body: '/* fonts offline in harness */' });
  }
  problems.external.push(url);
  log('[harness] BLOCKED request (not allowed / not available offline):', url);
  return route.abort();
});

page.on('console', (msg) => {
  const t = msg.type();
  if (t === 'error') problems.consoleErrors++;
  if (t === 'warning') problems.consoleWarnings++;
  if (t === 'error' || t === 'warning' || args.verbose) log(`[console.${t}]`, msg.text());
});
page.on('pageerror', (err) => { problems.pageErrors++; log('[pageerror]', err.message, (err.stack || '').split('\n').slice(0, 4).join(' | ')); });
page.on('requestfailed', (r) => {
  if (!r.url().startsWith(ORIGIN)) return;
  problems.failed.push(r.url()); log('[requestfailed]', r.url(), r.failure()?.errorText);
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let shotN = 0;
const shot = async (name) => {
  const p = `${OUT}-${String(++shotN).padStart(2, '0')}-${name}.png`;
  // SwiftShader renders the capture frame on the CPU: on a loaded machine one frame can take longer than
  // Playwright's 30 s default, which is not a game failure
  await page.screenshot({ path: p, timeout: 120000 });
  log('[shot]', path.relative(ROOT, p));
  return p;
};
const stats = async () => page.evaluate(() => (window.__dbg && window.__dbg.state) ? window.__dbg.state() : { noDbg: true });
const fail = (msg) => { problems.scenario.push(msg); log('[FAIL]', msg); };

// Multi-touch helper via CDP (Playwright's touchscreen API is single-point tap only).
const cdp = await context.newCDPSession(page);
const touch = {
  async set(points, type = 'touchMove') {
    await cdp.send('Input.dispatchTouchEvent', { type, touchPoints: points.map((p, i) => ({ x: p.x, y: p.y, id: p.id ?? i, radiusX: 4, radiusY: 4, force: 1 })) });
  },
  async start(points) { return this.set(points, 'touchStart'); },
  async move(points) { return this.set(points, 'touchMove'); },
  async end() { return cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] }); },
  async tap(x, y) { await this.start([{ x, y }]); await sleep(60); await this.end(); },
};
const native = {
  calls: () => page.evaluate(() => (window.__fakeNative ? window.__fakeNative.calls.slice() : [])),
  prefs: () => page.evaluate(() => (window.__fakeNative ? { ...window.__fakeNative.prefs } : {})),
  listeners: () => page.evaluate(() => (window.__fakeNative ? window.__fakeNative.listeners : [])),
  fire: (plugin, event, data) => page.evaluate(([p, e, d]) => window.__fakeNative.fire(p, e, d), [plugin, event, data || {}]),
};

const h = { shot, stats, sleep, log, fail, touch, keys: page.keyboard, mouse: page.mouse, args, logs, page, width, height, native, mobile, landscape };

const t0 = Date.now();
await page.goto(ORIGIN + '/', { waitUntil: 'load' });
await sleep(2500);
const hasDbg = await page.evaluate(() => !!window.__dbg);
log('[harness] target', WWW ? path.relative(ROOT, WWW) + '/ (www bundle)' + (FAKE_IOS ? ' in fake iOS shell' : '') : path.relative(ROOT, FILE) + ' (artifact)',
  '| loaded in', Date.now() - t0, 'ms | __dbg:', hasDbg, '| viewport', width + 'x' + height, '@' + dpr + 'x', mobile ? '(mobile/touch)' : '');
if (!hasDbg) fail('window.__dbg missing (the game did not boot)');
const env = await page.evaluate(() => ({ native: typeof window.__native, capacitor: typeof window.Capacitor, game: typeof window.__game }));
log('[env] window.__native:', env.native, '| window.Capacitor:', env.capacitor, '| window.__game:', env.game);

// fonts actually in use (FontFaceSet): the www bundle must load its local Oswald / JetBrains Mono faces
async function fontReport() {
  return page.evaluate(async () => {
    await document.fonts.ready;
    const faces = [...document.fonts].map((f) => ({ family: f.family.replace(/["']/g, ''), weight: String(f.weight), status: f.status, range: f.unicodeRange }));
    return { declared: faces.length, loaded: faces.filter((f) => f.status === 'loaded').map((f) => f.family + ' ' + f.weight + (/U\+0*400-/i.test(f.range) ? ' cyr' : ' lat')), errors: faces.filter((f) => f.status === 'error').length };
  });
}
const fonts = await fontReport();
log('[fonts]', fonts.declared, 'faces declared,', fonts.loaded.length, 'loaded:', fonts.loaded.join(', ') || 'none', fonts.errors ? '| ERRORS: ' + fonts.errors : '');
if (fonts.errors) fail(fonts.errors + ' font faces failed to load');
if (WWW && !fonts.loaded.length) fail('no web font loaded in www');

try {
  if (SCENARIO === 'smoke') {
    await shot('title');
    if (hasDbg) {
      await page.evaluate((c) => window.__dbg.start(c), CLS);
      await sleep(1500);
      await shot('start');
      await page.evaluate(() => window.__dbg.spawn && window.__dbg.spawn(400));
      await page.mouse.move(width * 0.7, height * 0.4);
      await page.mouse.down();
      await sleep(SECONDS * 1000);
      await page.mouse.up();
      await shot('combat');
      log('[stats]', await stats());
    }
  } else if (SCENARIO === 'play') {
    if (hasDbg) await page.evaluate((c) => window.__dbg.start(c), CLS);
    await sleep(1000);
    const keys = ['KeyW', 'KeyD', 'KeyS', 'KeyA'];
    const steps = Math.max(1, Math.round(SECONDS));
    await page.mouse.move(width / 2 + 200, height / 2);
    await page.mouse.down();
    for (let i = 0; i < steps; i++) {
      const k = keys[i % 4];
      await page.keyboard.down(k);
      const ang = i * 0.9;
      for (let j = 0; j < 10; j++) {
        await page.mouse.move(width / 2 + Math.cos(ang + j * 0.1) * 260, height / 2 + Math.sin(ang + j * 0.1) * 200);
        await sleep(100);
      }
      await page.keyboard.up(k);
      if (i % 3 === 2) { await page.keyboard.press('Space'); }
      if (i % 4 === 0) log('[stats t=' + i + ']', await stats());
    }
    await page.mouse.up();
    await shot('play-end');
    log('[stats]', await stats());
  } else if (SCENARIO === 'mobile') {
    await shot('title');
    if (hasDbg) await page.evaluate((c) => window.__dbg.start(c), CLS);
    await sleep(1200);
    await shot('start');
    if (hasDbg) await page.evaluate(() => window.__dbg.spawn && window.__dbg.spawn(300));
    // Twin-stick: left thumb bottom-left, right thumb bottom-right.
    const L = { x: width * 0.2, y: height * 0.8, id: 1 }, R = { x: width * 0.8, y: height * 0.8, id: 2 };
    await touch.start([L]);
    await touch.move([L, R]);
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: L.x, y: L.y, id: 1 }, { x: R.x, y: R.y, id: 2 }] });
    for (let i = 0; i < SECONDS * 10; i++) {
      const a = i * 0.15;
      await touch.move([{ x: L.x + Math.cos(a) * 40, y: L.y + Math.sin(a) * 40, id: 1 }, { x: R.x + Math.cos(-a) * 45, y: R.y + Math.sin(-a) * 45, id: 2 }]);
      await sleep(100);
      if (i === SECONDS * 5) await shot('twinstick');
    }
    await touch.end();
    await shot('end');
    log('[stats]', await stats());
  } else if (SCENARIO === 'bench') {
    if (!hasDbg) throw new Error('no __dbg');
    const counts = String(args.counts || '500,1500,3000').split(',').map(Number);
    const r = await page.evaluate((c) => window.__dbg.bench(c), counts);
    log('[bench]', r);
  } else if (SCENARIO === 'fonts') {
    // every declared face must load from the bundle, and text must really render in it (not the fallback)
    const r = await page.evaluate(async () => {
      const faces = [...document.fonts];
      const res = await Promise.all(faces.map((f) => f.load().then(() => 'ok', (e) => 'ERR ' + e)));
      const c = document.createElement('canvas').getContext('2d');
      const w = (font) => { c.font = font; return +c.measureText('ЛЕДЯНОЙ УЛЕЙ 0123 Кельвин-9').width.toFixed(1); };
      const title = getComputedStyle(document.querySelector('.t-title') || document.body);
      return {
        loaded: faces.map((f, i) => f.family.replace(/["']/g, '') + ' ' + f.weight + (/U\+0*400-/i.test(f.unicodeRange) ? ' cyr' : ' lat') + ': ' + res[i]),
        oswald: [w('700 40px Oswald'), w('700 40px sans-serif')], mono: [w('700 40px "JetBrains Mono"'), w('700 40px monospace')],
        check: [document.fonts.check('700 40px Oswald', 'Ж'), document.fonts.check('500 12px "JetBrains Mono"', 'Ж')],
        titleFont: title.fontFamily,
      };
    });
    log('[fonts] all faces:', r.loaded);
    log('[fonts] width Oswald vs sans-serif:', r.oswald, '| JetBrains Mono vs monospace:', r.mono, '| check():', r.check, '| title font-family:', r.titleFont);
    if (r.loaded.some((s) => !s.endsWith(': ok'))) fail('a font face failed to load');
    if (WWW && (r.loaded.length !== 12 || r.oswald[0] === r.oswald[1] || r.mono[0] === r.mono[1])) fail('web fonts are not rendering');
    await shot('title-fonts');
  } else {
    const mod = await import(pathToFileURL(path.resolve(ROOT, SCENARIO)).href);
    await mod.default(page, h);
  }
} catch (e) {
  fail('SCENARIO ERROR ' + e.message);
}

await sleep(300);
const extList = [...new Set(problems.external)];
log('[harness] ' + (WWW ? 'external requests' : 'blocked requests') + ':', extList.length ? extList : 'none');
if (WWW) log('[harness] served from www:', [...new Set(served)].join(', '));
const bad = problems.pageErrors + problems.consoleErrors + extList.length + problems.missing.length + problems.failed.length + problems.scenario.length;
log(`[harness] RESULT ${bad ? 'FAIL' : 'PASS'} — pageErrors ${problems.pageErrors}, consoleErrors ${problems.consoleErrors}, consoleWarnings ${problems.consoleWarnings}, ` +
  `external ${extList.length}, 404 ${problems.missing.length}, failedRequests ${problems.failed.length}, scenarioFailures ${problems.scenario.length}`);
await browser.close();
process.exitCode = bad ? 1 : 0;
