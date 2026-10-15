// Build the iOS web bundle (Capacitor webDir) into www/:
//   index.html   full document: platform-equivalent reset + the game's head.html (no Google Fonts, no import map)
//   fonts.css    @font-face for Oswald 400/500/600/700 + JetBrains Mono 500/700 (cyrillic + latin), local woff2
//   fonts/*.woff2
//   native.js    native/bridge.js bundled as an IIFE (defines window.__native only inside the iOS shell)
//   game.js      game/js/*.js concatenated in order, three.js + addons bundled in (iOS 15 has no import maps)
//   licenses.txt third-party notices (three.js, Capacitor, the two font families)
// Usage: node scripts/build-www.mjs [--no-minify] [--sourcemap]
import fs from 'node:fs';
import path from 'node:path';
import * as esbuild from 'esbuild';
import { ROOT, GAME, readHead, moduleCode } from './game-sources.mjs';

const argv = process.argv.slice(2);
const MINIFY = !argv.includes('--no-minify');
const SOURCEMAP = argv.includes('--sourcemap');
const WWW = path.join(ROOT, 'www');
const NM = path.join(ROOT, 'node_modules');
const TARGET = ['safari15'];   // IPHONEOS_DEPLOYMENT_TARGET 15.0

const t0 = Date.now();
fs.rmSync(WWW, { recursive: true, force: true });
fs.mkdirSync(path.join(WWW, 'fonts'), { recursive: true });

function fail(msg) { console.error('[build] FAILED: ' + msg); process.exit(1); }

// ---------------------------------------------------------------- native bridge
await esbuild.build({
  entryPoints: [path.join(ROOT, 'native', 'bridge.js')],
  outfile: path.join(WWW, 'native.js'),
  bundle: true, format: 'iife', platform: 'browser', target: TARGET,
  minify: MINIFY, sourcemap: SOURCEMAP, legalComments: 'none', logLevel: 'warning',
});

// ---------------------------------------------------------------- game
// The parts form ONE module (shared top-level scope), exactly like the artifact's <script type="module">.
// 'three' and 'three/addons/*' resolve through three's package exports to node_modules/three.
await esbuild.build({
  stdin: { contents: moduleCode(), resolveDir: path.join(GAME, 'js'), sourcefile: 'game.js', loader: 'js' },
  outfile: path.join(WWW, 'game.js'),
  bundle: true, format: 'esm', platform: 'browser', target: TARGET,
  minify: MINIFY, sourcemap: SOURCEMAP, legalComments: 'none', logLevel: 'warning',
  nodePaths: [NM],
});

// ---------------------------------------------------------------- fonts (@fontsource -> local woff2)
const FONTS = [
  { pkg: '@fontsource/oswald', id: 'oswald', family: 'Oswald', weights: [400, 500, 600, 700] },
  { pkg: '@fontsource/jetbrains-mono', id: 'jetbrains-mono', family: 'JetBrains Mono', weights: [500, 700] },
];
const SUBSETS = ['cyrillic', 'latin'];
let fontsCss = '/* Oswald + JetBrains Mono from @fontsource (SIL OFL 1.1), served locally: cyrillic + latin subsets */\n';
const fontFiles = [];
for (const f of FONTS) {
  const dir = path.join(NM, f.pkg);
  for (const wgt of f.weights) {
    const css = fs.readFileSync(path.join(dir, `${wgt}.css`), 'utf8');
    for (const sub of SUBSETS) {
      const name = `${f.id}-${sub}-${wgt}-normal`;
      const block = css.split(`/* ${name} */`)[1];
      if (!block) fail(`no @font-face for ${name} in ${f.pkg}/${wgt}.css`);
      const range = /unicode-range:\s*([^;]+);/.exec(block.slice(0, block.indexOf('}')));
      if (!range) fail(`no unicode-range for ${name}`);
      const src = path.join(dir, 'files', name + '.woff2');
      if (!fs.existsSync(src)) fail('missing ' + src);
      fs.copyFileSync(src, path.join(WWW, 'fonts', name + '.woff2'));
      fontFiles.push(name + '.woff2');
      fontsCss += `@font-face {\n  font-family: '${f.family}';\n  font-style: normal;\n  font-display: swap;\n  font-weight: ${wgt};\n` +
        `  src: url(fonts/${name}.woff2) format('woff2');\n  unicode-range: ${range[1].trim()};\n}\n`;
    }
  }
}
fs.writeFileSync(path.join(WWW, 'fonts.css'), fontsCss);

// ---------------------------------------------------------------- index.html
let head = readHead();
// strip what only the artifact platform needs; every pattern must match exactly once
function strip(re, what) {
  const n = (head.match(new RegExp(re.source, re.flags.includes('g') ? re.flags : re.flags + 'g')) || []).length;
  if (n !== 1) fail(`expected exactly one ${what} in game/head.html, found ${n}`);
  head = head.replace(re, '');
}
strip(/<meta name="claude:viewport-fit-sides"[^>]*>\n?/, 'claude viewport meta');
strip(/<link rel="preconnect" href="https:\/\/fonts\.googleapis\.com">\n?/, 'googleapis preconnect');
strip(/<link rel="preconnect" href="https:\/\/fonts\.gstatic\.com" crossorigin>\n?/, 'gstatic preconnect');
strip(/<link rel="stylesheet" href="https:\/\/fonts\.googleapis\.com\/css2\?[^"]*">\n?/, 'Google Fonts stylesheet');
strip(/<script type="importmap">[\s\S]*?<\/script>\n?/, 'import map');
// <title> and the game stylesheet go to <head>; the markup and the classic loader script stay in <body>
const title = /<title>[^<]*<\/title>\n?/.exec(head);
const style = /<style>[\s\S]*?<\/style>\n?/.exec(head);
if (!title || !style) fail('head.html must contain <title> and <style>');
const body = head.replace(title[0], '').replace(style[0], '').trim();

// Same minimal reset the artifact platform wraps around the page (harness SKELETON_HEAD), so layout matches.
const PLATFORM_RESET = ':root{color-scheme:light;padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}\n' +
  'body{margin:0;font:14px/1.4 system-ui,-apple-system,sans-serif}img{max-width:100%}[hidden]{display:none!important}';

const html = `<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, user-scalable=no">
<meta name="format-detection" content="telephone=no">
<meta name="color-scheme" content="dark">
${title[0].trim()}
<style>${PLATFORM_RESET}</style>
<link rel="stylesheet" href="fonts.css">
${style[0].trim()}
<script src="native.js"></script>
</head>
<body>
${body}
<script type="module" src="game.js"></script>
</body>
</html>
`;
fs.writeFileSync(path.join(WWW, 'index.html'), html);

// ---------------------------------------------------------------- third-party notices
const notices = [
  ['three.js 0.170.0 (MIT)', 'three/LICENSE'],
  ['Capacitor core + plugins (MIT)', '@capacitor/core/LICENSE'],
  ['Oswald (SIL Open Font License 1.1), via @fontsource/oswald', '@fontsource/oswald/LICENSE'],
  ['JetBrains Mono (SIL Open Font License 1.1), via @fontsource/jetbrains-mono', '@fontsource/jetbrains-mono/LICENSE'],
].map(([name, file]) => `==== ${name} ====\n\n${fs.readFileSync(path.join(NM, file), 'utf8').trim()}\n`);
fs.writeFileSync(path.join(WWW, 'licenses.txt'), 'Ледяной Улей — third-party notices\n\n' + notices.join('\n'));

// ---------------------------------------------------------------- report + offline check
const files = [];
(function walk(d) { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else files.push(p); } })(WWW);
let total = 0;
const rows = files.map((p) => { const n = fs.statSync(p).size; total += n; return [path.relative(WWW, p), n]; });
for (const [p, n] of rows.filter(([p]) => !p.startsWith('fonts/'))) console.log(`  www/${p.padEnd(14)} ${(n / 1024).toFixed(1).padStart(8)} KB`);
console.log(`  www/fonts/      ${fontFiles.length} woff2, ${(rows.filter(([p]) => p.startsWith('fonts/')).reduce((a, [, n]) => a + n, 0) / 1024).toFixed(1)} KB`);
const urls = [];
for (const p of files) {
  if (!/\.(html|css|js|txt|json|map)$/.test(p)) continue;
  const s = fs.readFileSync(p, 'utf8');
  for (const m of s.matchAll(/https?:\/\/[^\s"'`<>)\\]+/g)) urls.push([path.relative(WWW, p), m[0]]);
}
// inert: the SVG namespace inside CSS data: URIs, and license texts that are never loaded
const inert = ([f, u]) => u.startsWith('http://www.w3.org/') || f === 'licenses.txt';
const live = urls.filter((x) => !inert(x));
console.log(`[build] www/ ${files.length} files, ${(total / 1024).toFixed(1)} KB in ${Date.now() - t0} ms; ` +
  `http(s) URLs: ${urls.length} total, ${urls.length - live.length} inert, ${live.length} live`);
if (live.length) fail('www must not reference the network:\n  ' + live.map(([f, u]) => f + ': ' + u).join('\n  '));
