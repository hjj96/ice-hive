// Renders the «Ледяной Улей» app icon concepts + launch splash with Playwright (Chromium),
// then hands off to postprocess.py (Pillow) to downsample, strip alpha and build the contact sheet.
//
//   node resources/src/render.mjs [--pick hex|beam|lasers] [--only all|icons|splash] [--pw /path/to/playwright/index.mjs]
//
// Needs: `npm ci` (Playwright is a devDependency; --pw or $PLAYWRIGHT_MODULE only to use another copy),
// `npx playwright install chromium`, and Pillow for postprocess.py (`python3 -m pip install Pillow`).
//
// Pages are served from the repo root over a throwaway local HTTP server so the splash can load
// Oswald from node_modules/@fontsource/oswald (no network fonts).
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';
import os from 'node:os';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '../..');
const OUT = path.resolve(HERE, '..');
const RAW = fs.mkdtempSync(path.join(os.tmpdir(), 'icehive-art-')); // 2x intermediates, deleted at the end
const argv = process.argv.slice(2);
const arg = (k, d) => { const i = argv.indexOf('--' + k); return i >= 0 ? argv[i + 1] : d; };
const PW = arg('pw', process.env.PLAYWRIGHT_MODULE);   // optional: another Playwright copy; default is the devDependency
const PICK = arg('pick', 'hex');
const ONLY = arg('only', 'all'); // all | icons | splash
const SS = 2; // supersample factor; postprocess.py downsamples with Lanczos

let chromium;
try { ({ chromium } = PW ? await import(pathToFileURL(path.resolve(PW)).href) : await import('playwright')); }
catch (e) { console.error('[render] cannot load Playwright' + (PW ? ' from ' + PW : '') + ' — run `npm ci` in the repo root (' + e.message + ')'); process.exit(2); }

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.woff': 'font/woff', '.png': 'image/png' };
const server = http.createServer((req, res) => {
  const p = path.normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname));
  const file = path.join(REPO, p);
  if (!file.startsWith(REPO) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream' });
  fs.createReadStream(file).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}/resources/src/`;

const browser = await chromium.launch();
const errors = [];
async function shot(url, size, out) {
  const page = await browser.newPage({ viewport: { width: size, height: size }, deviceScaleFactor: SS });
  page.on('pageerror', (e) => errors.push(url + ': ' + e.message));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(url + ': ' + m.text()); });
  await page.goto(base + url, { waitUntil: 'load' });
  await page.waitForFunction(() => document.documentElement.dataset.ready === '1');
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: out, clip: { x: 0, y: 0, width: size, height: size }, omitBackground: false });
  const fontOk = await page.evaluate(() => document.fonts.check('700 100px Oswald', 'ЛедянойУлей'));
  await page.close();
  return fontOk;
}

for (const c of (ONLY === 'splash' ? [] : ['hex', 'beam', 'lasers'])) {
  await shot(`icon-source.html?c=${c}`, 1024, path.join(RAW, `icon-${c}@2x.png`));
  console.log('rendered icon concept', c);
}
// splash: 2732 CSS px is huge; render at 1x (it is already full resolution)
if (ONLY !== 'icons') {
  const page = await browser.newPage({ viewport: { width: 2732, height: 2732 }, deviceScaleFactor: 1 });
  page.on('pageerror', (e) => errors.push('splash: ' + e.message));
  await page.goto(base + `splash-source.html?c=${PICK}`, { waitUntil: 'load' });
  await page.waitForFunction(() => document.documentElement.dataset.ready === '1');
  await page.evaluate(() => document.fonts.ready);
  const fontOk = await page.evaluate(() => document.fonts.check('700 100px Oswald', 'ЛедянойУлей'));
  const box = await page.evaluate(() => window.__contentBox && window.__contentBox());
  await page.screenshot({ path: path.join(RAW, 'splash@1x.png'), clip: { x: 0, y: 0, width: 2732, height: 2732 } });
  await page.close();
  console.log('rendered splash; Oswald loaded:', fontOk, 'content box:', JSON.stringify(box));
  if (!fontOk) errors.push('splash: Oswald did not load (wordmark would fall back to a system face)');
  // iPhones crop the 2732 square to its central ~1257 px (scaleAspectFill); keep everything inside the central 1000
  if (!box || box.left < 866 || box.top < 866 || box.right > 1866 || box.bottom > 1866) errors.push('splash: content outside the central 1000 px: ' + JSON.stringify(box));
}
await browser.close();
server.close();
if (errors.length) { console.error('PAGE ERRORS:\n' + errors.join('\n')); process.exit(1); }

try {
  execFileSync('python3', [path.join(HERE, 'postprocess.py'), '--pick', PICK, '--raw', RAW, '--out', OUT, '--src', HERE, '--only', ONLY], { stdio: 'inherit' });
} finally {
  fs.rmSync(RAW, { recursive: true, force: true });
}
