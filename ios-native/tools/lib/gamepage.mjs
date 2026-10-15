// Loads the web game's own source parts (game/js/01-core.js … 09-audio.js, ONE module scope exactly like the
// shipped build) into headless Chromium (SwiftShader WebGL) and appends tool code to that same module, so the
// renderers below call the game's real geometry builders, materials, textures and synth recipes.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const TOOLS = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const NATIVE = path.resolve(TOOLS, '..');
export const ROOT = path.resolve(NATIVE, '..');
export const RES = path.join(NATIVE, 'App', 'Resources');
export const OUT = path.join(TOOLS, 'out');
const THREE_DIR = path.join(ROOT, 'node_modules', 'three');
const ORIGIN = 'https://assets.local';

// The part files the asset tools need: everything up to the audio section (no input/UI/main loop).
const PARTS = ['01-core.js', '02-textures.js', '03-render.js', '04-level.js', '05-sim.js', '06-marines.js', '07-fx.js', '08-director.js', '09-audio.js'];

// Identifiers defined in the parts we leave out (10-input, 11-ui, 12-main) that 01–09 touch at load time or in
// the functions the tools call. Plain stand-ins; nothing here runs game logic.
const STUBS = `
let simOnly = false, benchCombat = false, timeScale = 1, dbgGod = false;
const camTarget = new THREE.Vector3();
const IN = { mode: 'touch', abil: false, dash: false };
function toast() {} function banner() {} function showScreen() {} function buildSquadUI() {} function renderCards() {}
function pollGamepad() {}
`;

export function moduleCode(toolFiles) {
  let code = '';
  for (const p of PARTS) code += '\n' + fs.readFileSync(path.join(ROOT, 'game', 'js', p), 'utf8');
  code += '\n' + STUBS;
  for (const f of toolFiles) code += '\n// ---- ' + path.basename(f) + '\n' + fs.readFileSync(f, 'utf8');
  code += '\nwindow.__ready = true;\n';
  return code;
}

const PAGE = `<!doctype html><html><head><meta charset="utf-8">
<script type="importmap">{"imports":{"three":"${ORIGIN}/three/build/three.module.js","three/addons/":"${ORIGIN}/three/examples/jsm/"}}</script>
<style>html,body{margin:0;background:#000}#stage{position:fixed;left:0;top:0;width:8px;height:8px;overflow:hidden}</style>
</head><body><div id="stage"></div><script type="module" src="${ORIGIN}/game.js"></script></body></html>`;

export async function openGamePage(toolFiles, { verbose = false } = {}) {
  let chromium;
  try { ({ chromium } = await import('playwright')); }
  catch (e) { console.error('cannot load playwright — run `npm ci` in the repo root (' + e.message + ')'); process.exit(2); }
  const browser = await chromium.launch({
    args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--enable-webgl', '--autoplay-policy=no-user-gesture-required'],
  });
  const context = await browser.newContext({ viewport: { width: 640, height: 480 }, deviceScaleFactor: 1 });
  const page = await context.newPage();
  const code = moduleCode(toolFiles);
  const errors = [];
  page.on('pageerror', (e) => { errors.push(String(e)); console.error('[page error]', e.message); });
  page.on('console', (m) => { if (m.type() === 'error') { errors.push(m.text()); console.error('[console.error]', m.text()); } else if (verbose) console.log('[page]', m.text()); });
  await page.route('**/*', async (route) => {
    const url = route.request().url();
    if (url === ORIGIN + '/' || url === ORIGIN + '/index.html') return route.fulfill({ status: 200, contentType: 'text/html; charset=utf-8', body: PAGE });
    if (url === ORIGIN + '/game.js') return route.fulfill({ status: 200, contentType: 'application/javascript; charset=utf-8', body: code });
    if (url.startsWith(ORIGIN + '/three/')) {
      const p = path.join(THREE_DIR, decodeURIComponent(new URL(url).pathname.slice('/three/'.length)));
      if (fs.existsSync(p)) return route.fulfill({ status: 200, contentType: 'application/javascript; charset=utf-8', body: fs.readFileSync(p) });
    }
    console.error('[blocked]', url);
    return route.abort();
  });
  await page.goto(ORIGIN + '/index.html');
  await page.waitForFunction(() => window.__ready === true || window.__failed, null, { timeout: 120000 }).catch(() => {});
  const ok = await page.evaluate(() => window.__ready === true);
  if (!ok) { await browser.close(); throw new Error('game modules failed to load: ' + errors.join(' | ')); }
  return { browser, page, errors };
}

// base64 -> Buffer helper for page results
export function b64(s) { return Buffer.from(s, 'base64'); }
