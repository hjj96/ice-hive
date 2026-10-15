// Checks the App Store texts in store/app-store-ru.md before they are pasted into App Store Connect.
//   node scripts/check-store.mjs [--file store/app-store-ru.md]     (npm run check:store)
// - every copy block against its App Store Connect limit. All fields count characters (code points; a Cyrillic
//   letter and a line break are 1 each), EXCEPT Keywords, which are limited to 100 BYTES of UTF-8 (Cyrillic = 2 bytes);
// - the "**N / L**" figures in the headings and the summary table match the real counts;
// - keywords: comma-separated, no spaces, no duplicates, every keyword longer than two characters;
// - customer-facing texts never promise online / multiplayer / co-op play (the squadmates are AI) and never mention
//   other platforms (guideline 2.3.10);
// - the Copyright block has no © (App Store Connect adds it).
// Exit code 1 on any problem.
import fs from 'node:fs';
import path from 'node:path';
import { ROOT } from './game-sources.mjs';

const fi = process.argv.indexOf('--file');
const FILE = fi > 0 ? path.resolve(process.argv[fi + 1]) : path.join(ROOT, 'store', 'app-store-ru.md');
const md = fs.readFileSync(FILE, 'utf8');
const problems = [];
const chars = (s) => [...s].length;
const bytes = (s) => Buffer.byteLength(s, 'utf8');

// sections by "## N." heading; inside each: the copy blocks (``` fences) and the "**N / L**" figure that precedes each
const sections = {};
for (const part of md.split(/^(?=## \d+\. )/m).slice(1)) {
  const num = Number(/^## (\d+)\./.exec(part)[1]);
  const blocks = [];
  const re = /```\n([\s\S]*?)\n```/g;
  let m, from = 0;
  while ((m = re.exec(part))) {
    const before = part.slice(from, m.index);
    const fig = [...before.matchAll(/\*\*(\d+) \/ (\d+)\*\*/g)].pop();
    blocks.push({ text: m[1], stated: fig ? Number(fig[1]) : null, statedLimit: fig ? Number(fig[2]) : null });
    from = m.index + m[0].length;
  }
  sections[num] = { title: part.split('\n')[0], blocks };
}

// [section, block index, field, limit, unit, customer-facing]
const FIELDS = [
  [1, 0, 'Name', 30, 'chars', true],
  [1, 1, 'Name (fallback)', 30, 'chars', true],
  [2, 0, 'Subtitle', 30, 'chars', true],
  [3, 0, 'Promotional Text', 170, 'chars', true],
  [4, 0, 'Description', 4000, 'chars', true],
  [5, 0, 'Keywords', 100, 'bytes', true],
  [10, 0, 'App Review Notes', 4000, 'chars', false],
  [11, 0, "What's New", 4000, 'chars', true],
];
const BANNED = /(^|[^а-яёa-z])(онлайн|мультиплеер|кооператив|браузер|android|андроид|claude|веб-верси)/i;
const counts = {};
for (const [sec, i, field, limit, unit, facing] of FIELDS) {
  const b = sections[sec] && sections[sec].blocks[i];
  if (!b) { problems.push(`${field}: no copy block ${i + 1} in section ${sec}`); continue; }
  const n = unit === 'bytes' ? bytes(b.text) : chars(b.text);
  counts[field] = { n, limit, unit, chars: chars(b.text) };
  const line = `${field.padEnd(18)} ${String(n).padStart(4)} / ${limit} ${unit}` + (unit === 'bytes' ? ` (${chars(b.text)} chars)` : '');
  console.log('  ' + line);
  if (n > limit) problems.push(`${field}: ${n} ${unit}, limit ${limit}`);
  if (b.stated != null && (b.stated !== n || b.statedLimit !== limit)) problems.push(`${field}: heading says ${b.stated} / ${b.statedLimit}, real ${n} / ${limit} ${unit}`);
  if (facing) { const w = BANNED.exec(b.text); if (w) problems.push(`${field}: must not say «${w[2]}»`); }
}

// keywords
const kw = sections[5] && sections[5].blocks[0] && sections[5].blocks[0].text;
if (kw) {
  if (/\s/.test(kw)) problems.push('Keywords: no spaces or line breaks (comma-separated only)');
  const list = kw.split(',');
  for (const k of list) if (chars(k) <= 2) problems.push(`Keywords: «${k}» must be longer than two characters`);
  const dup = list.filter((k, j) => list.indexOf(k) !== j);
  if (dup.length) problems.push('Keywords: duplicates ' + dup.join(', '));
}

// copyright: App Store Connect prefixes the © itself
const cr = sections[9] && sections[9].blocks[0] && sections[9].blocks[0].text;
if (cr && /©|\(c\)/i.test(cr)) problems.push('Copyright: drop the ©, App Store Connect adds it');

// summary table at the top: "| Поле (English) | limit | now |"
const ROWS = { 'Name': 'Name', 'Subtitle': 'Subtitle', 'Promotional Text': 'Promotional Text', 'Description': 'Description',
  'Keywords': 'Keywords', "What's New": "What's New", 'App Review Notes': 'App Review Notes' };
for (const m of md.matchAll(/^\| [^|]*\(([^)]+)\) \| ([^|]+) \| ([^|]+) \|$/gm)) {
  const field = ROWS[m[1]];
  if (!field || !counts[field]) continue;
  const lim = Number(/\d+/.exec(m[2])[0]), now = Number(/\d+/.exec(m[3])[0]);
  if (lim !== counts[field].limit || now !== counts[field].n) problems.push(`summary table, ${field}: says ${now} / ${lim}, real ${counts[field].n} / ${counts[field].limit} ${counts[field].unit}`);
}

if (problems.length) { console.error('[check:store] FAILED\n  - ' + problems.join('\n  - ')); process.exit(1); }
console.log('[check:store] OK — ' + path.relative(ROOT, FILE));
