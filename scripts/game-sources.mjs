// Shared helpers for the two builds (single-file artifact + iOS www bundle).
// The game lives in game/head.html (markup + CSS + loader scripts) and game/js/NN-*.js
// (one ES module split into ordered parts that are concatenated, never imported separately).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const GAME = path.join(ROOT, 'game');

export function readHead() {
  return fs.readFileSync(path.join(GAME, 'head.html'), 'utf8');
}

// Same order as the shell glob `src/js/*.js` in the original build.sh (byte-wise name order).
export function jsParts() {
  const dir = path.join(GAME, 'js');
  return fs.readdirSync(dir)
    .filter((f) => f.endsWith('.js'))
    .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))
    .map((f) => ({ name: f, file: path.join(dir, f), code: fs.readFileSync(path.join(dir, f), 'utf8') }));
}

// The module body exactly as the artifact embeds it between '<script type="module">\n' and '\n</script>\n':
// every part is preceded by a newline (same as build.sh).
export function moduleCode(parts = jsParts()) {
  let out = '';
  for (const p of parts) out += '\n' + p.code;
  return out;
}
