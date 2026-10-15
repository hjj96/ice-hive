#!/usr/bin/env node
// «Ледяной Улей» v2.0 — copies the UI fonts of the web game (Oswald 400/500/600/700, JetBrains Mono 500/700) as
// TrueType files into ios-native/App/Resources/Fonts/ with their OFL licences, and lists the PostScript names.
//
//   node ios-native/tools/fetch-fonts.mjs
//
// Source: the @expo-google-fonts npm packages (they ship the Google Fonts .ttf files; @fontsource only has
// woff/woff2 subsets). Downloaded with `npm pack` into a temporary directory, nothing is installed.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { RES } from './lib/gamepage.mjs';

const OUT = path.join(RES, 'Fonts');
const PKGS = [
  { pkg: '@expo-google-fonts/oswald@0.4.2', family: 'Oswald', licence: 'OFL-Oswald.txt', files: [['400Regular', 400], ['500Medium', 500], ['600SemiBold', 600], ['700Bold', 700]], prefix: 'Oswald' },
  { pkg: '@expo-google-fonts/jetbrains-mono@0.4.1', family: 'JetBrains Mono', licence: 'OFL-JetBrainsMono.txt', files: [['500Medium', 500], ['700Bold', 700]], prefix: 'JetBrainsMono' },
];

// minimal sfnt reader: name table (PostScript name = nameID 6, family 1 / 16, subfamily 2 / 17) and cmap coverage
function tables(buf) {
  const n = buf.readUInt16BE(4), t = {};
  for (let i = 0; i < n; i++) { const o = 12 + i * 16; t[buf.toString('latin1', o, o + 4)] = { off: buf.readUInt32BE(o + 8), len: buf.readUInt32BE(o + 12) }; }
  return t;
}
function names(buf) {
  const { off } = tables(buf).name, count = buf.readUInt16BE(off + 2), str = off + buf.readUInt16BE(off + 4), out = {};
  for (let i = 0; i < count; i++) {
    const r = off + 6 + i * 12, pid = buf.readUInt16BE(r), id = buf.readUInt16BE(r + 6), len = buf.readUInt16BE(r + 8), o = str + buf.readUInt16BE(r + 10);
    if (out[id]) continue;
    if (pid === 3 || pid === 0) { let s = ''; for (let k = 0; k < len; k += 2) s += String.fromCharCode(buf.readUInt16BE(o + k)); out[id] = s; }
    else if (pid === 1) out[id] = buf.toString('latin1', o, o + len);
  }
  return out;
}
function covers(buf, cp) {
  const { off } = tables(buf).cmap, n = buf.readUInt16BE(off + 2);
  for (let i = 0; i < n; i++) {
    const st = off + buf.readUInt32BE(off + 4 + i * 8 + 4), fmt = buf.readUInt16BE(st);
    if (fmt === 4) {
      const segX2 = buf.readUInt16BE(st + 6), ends = st + 14, starts = ends + segX2 + 2;
      for (let s = 0; s < segX2; s += 2) if (cp <= buf.readUInt16BE(ends + s) && cp >= buf.readUInt16BE(starts + s)) return true;
    } else if (fmt === 12) {
      const groups = buf.readUInt32BE(st + 12);
      for (let g = 0; g < groups; g++) { const o = st + 16 + g * 12; if (cp >= buf.readUInt32BE(o) && cp <= buf.readUInt32BE(o + 4)) return true; }
    }
  }
  return false;
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'icehive-fonts-'));
fs.mkdirSync(OUT, { recursive: true });
for (const f of fs.readdirSync(OUT)) if (/\.(ttf|txt|json)$/.test(f)) fs.rmSync(path.join(OUT, f));
const list = [];
try {
  for (const P of PKGS) {
    const tgz = execFileSync('npm', ['pack', P.pkg, '--silent'], { cwd: tmp, encoding: 'utf8' }).trim().split('\n').pop();
    const dir = path.join(tmp, P.prefix);
    fs.mkdirSync(dir);
    execFileSync('tar', ['-xzf', path.join(tmp, tgz), '-C', dir]);
    fs.copyFileSync(path.join(dir, 'package', 'LICENSE_FONT'), path.join(OUT, P.licence));
    for (const [style, weight] of P.files) {
      const src = path.join(dir, 'package', style, `${P.prefix}_${style}.ttf`);
      const buf = fs.readFileSync(src), nm = names(buf);
      const file = `${P.prefix}-${style.replace(/^\d+/, '')}.ttf`;
      fs.writeFileSync(path.join(OUT, file), buf);
      const cyr = ['Ж', 'ы', 'Ё', '«', '»', '—', '№'].every(ch => covers(buf, ch.codePointAt(0)));
      list.push({ file, family: P.family, weight, postScriptName: nm[6], fullName: nm[4], cyrillic: cyr, bytes: buf.length });
    }
  }
} finally { fs.rmSync(tmp, { recursive: true, force: true }); }
fs.writeFileSync(path.join(OUT, 'fonts.json'), JSON.stringify({
  note: 'register the .ttf files under UIAppFonts in Info.plist (paths relative to the bundle, e.g. "Fonts/Oswald-Medium.ttf" when the folder is a folder reference, or just the file names when the files are copied flat) and create them with UIFont(name: postScriptName, size:) / SKLabelNode(fontNamed: postScriptName). The web UI (game/head.html): Oswald = --font-display for every label, nameplate, button, toast and banner (500 small letter-spaced labels and nameplates, 600 objective text / buttons / the player’s own nameplate, 700 the big banner); JetBrains Mono = --font-mono for the numbers (kill counter, timer, combo, armour value, level, distance marker: 700, tabular). Licence: SIL OFL 1.1 (OFL-*.txt, keep them in the bundle / acknowledgements).',
  fonts: list,
}, null, 2) + '\n');
for (const f of list) console.log(`${f.file.padEnd(28)} ${f.postScriptName.padEnd(26)} ${f.weight}  cyrillic ${f.cyrillic ? 'yes' : 'NO'}  ${(f.bytes / 1024).toFixed(0)} KB`);
