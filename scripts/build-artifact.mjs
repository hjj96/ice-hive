// Build the single-file claude.ai Artifact (the live web version of the game).
//   node scripts/build-artifact.mjs [--out dist/artifact.html]
// Output = game/head.html + <script type="module"> + game/js/*.js (in order) + </script>,
// the same layout the original scratchpad build.sh produced. The artifact contract from SPEC.md "Hard rules" (no
// <!doctype>/<html>/<head>/<body>; <title>, the claude viewport meta, then <style>; Google Fonts + the exact jsdelivr
// import map only; no alert/confirm/prompt/print, no download links) is checked before writing.
import fs from 'node:fs';
import path from 'node:path';
import { ROOT, readHead, moduleCode } from './game-sources.mjs';

const argv = process.argv.slice(2);
const outArg = argv.indexOf('--out') >= 0 ? argv[argv.indexOf('--out') + 1] : 'dist/artifact.html';
const OUT = path.resolve(ROOT, outArg);

const head = readHead();
const html = head + '<script type="module">\n' + moduleCode() + '\n</script>\n';

// ---- artifact contract checks (fail the build instead of publishing a broken page) ----
const problems = [];
const IMPORT_MAP = '<script type="importmap">{"imports":{"three":"https://cdn.jsdelivr.net/npm/three@0.170.0/build/three.module.min.js",' +
  '"three/addons/":"https://cdn.jsdelivr.net/npm/three@0.170.0/examples/jsm/"}}</script>';
if (!html.startsWith('<title>Ледяной Улей</title>\n<meta name="claude:viewport-fit-sides" content="cover">\n<style>')) {
  problems.push('first lines must be <title>Ледяной Улей</title>, <meta name="claude:viewport-fit-sides" content="cover">, then <style>');
}
if (/<!doctype|<html[\s>]|<head[\s>]|<body[\s>]/i.test(html)) problems.push('page content only: no <!doctype>/<html>/<head>/<body>');
if (/window\.__native\s*=/.test(html)) problems.push('the native bridge must not be part of the artifact');
const urls = [...html.matchAll(/https?:\/\/[^\s"'<>)]+/g)].map((m) => m[0]);
const allowed = [
  /^https:\/\/fonts\.googleapis\.com(\/|$)/,
  /^https:\/\/fonts\.gstatic\.com(\/|$)/,
  /^https:\/\/cdn\.jsdelivr\.net\/npm\/three@0\.170\.0\//,
  /^http:\/\/www\.w3\.org\//,   // SVG xmlns (inert)
];
for (const u of urls) if (!allowed.some((re) => re.test(u))) problems.push('URL outside the artifact allowlist: ' + u);
const maps = html.match(/<script type="importmap">[\s\S]*?<\/script>/g) || [];
if (maps.length !== 1 || maps[0] !== IMPORT_MAP) problems.push('exactly one import map, identical to the one in SPEC.md: ' + IMPORT_MAP);
// every <script> body (the classic loader in head.html and the game module): no blocking dialogs, no printing
const scripts = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1]).join('\n');
const dialog = /(^|[^\w.$])(alert|confirm|prompt|print)\s*\(|window\.(alert|confirm|prompt|print)\b/m.exec(scripts);
if (dialog) problems.push('no alert/confirm/prompt/print: found "' + dialog[0].trim() + '"');
if (/<a\b[^>]*\sdownload\b|\.download\s*=/i.test(html)) problems.push('no download links');
if (problems.length) {
  console.error('[build:artifact] FAILED\n  - ' + problems.join('\n  - '));
  process.exit(1);
}

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, html);
console.log(`[build:artifact] ${path.relative(ROOT, OUT)}  ${html.length} chars, ${Buffer.byteLength(html)} bytes, ${html.split('\n').length - 1} lines`);
