// Checks the English App Store package of ICE HIVE 2.0 before anything is pasted into App Store Connect.
//   node scripts/check-store.mjs [--release] [--file store/app-store-en.md]          (npm run check:store)
//
// store/app-store-en.md — every copy block is marked `<!-- field: <id> -->` right above its ``` fence:
//   - each block against its App Store Connect limit. Every field counts characters (code points; a line break is one),
//     except Keywords: 100 BYTES of UTF-8;
//   - the "**N / L**" figure before each block and the summary table at the top match the real counts;
//   - keywords: comma-separated, no spaces, no duplicates, each longer than two characters, none repeating a word of the
//     name or the subtitle;
//   - customer-facing texts (everything but the review notes and the copyright) never promise play with other people
//     (the squadmates are AI), never name other platforms or other games, carry no price or ranking claims and no
//     Cyrillic (no Russian ships in 2.0);
//   - the Copyright block has no © (App Store Connect adds it).
// Every English store file (the listing, the privacy policy .md / .html, the screenshot plan):
//   - never says WebGL, portrait, three.js (1.x facts), nor the banned names;
//   - `[OWNER: …]` placeholders are listed; with --release any placeholder left is a failure.
// Facts against the native project (ios-native/): version and minimum iOS from project.yml, iPhone only, landscape-only
// orientations in Info.plist, no networking / web-view / ad / tracking API in the Swift sources, every bundled font has
// its OFL text, PrivacyInfo.xcprivacy declares no tracking and no collected data, and every UserDefaults key that
// SettingsStore writes is named in both privacy policy files.
// The screenshot plan: ten shots, each with a caption (≤ 30 chars) and a subline (≤ 48 chars), all three sizes listed.
// Exit code 1 on any problem.
import fs from 'node:fs';
import path from 'node:path';
import { ROOT } from './game-sources.mjs';

const argv = process.argv.slice(2);
const RELEASE = argv.includes('--release');
const fi = argv.indexOf('--file');
const FILE = fi >= 0 ? path.resolve(argv[fi + 1]) : path.join(ROOT, 'store', 'app-store-en.md');
const STORE = path.join(ROOT, 'store');
const NATIVE = path.join(ROOT, 'ios-native');
const POLICY_MD = path.join(STORE, 'privacy-policy.md');
const POLICY_HTML = path.join(STORE, 'privacy-policy.html');
const SHOT_PLAN = path.join(STORE, 'screenshot-plan-en.md');
const CONTACT = 'zviaginzevandrew@gmail.com';

const problems = [];
const notes = [];
const chars = (s) => [...s].length;
const bytes = (s) => Buffer.byteLength(s, 'utf8');
const rel = (f) => path.relative(ROOT, f);
const read = (f) => { try { return fs.readFileSync(f, 'utf8'); } catch { problems.push(`missing ${rel(f)}`); return ''; } };

// ---------- the listing ----------
const md = read(FILE);

// copy blocks: `<!-- field: id -->` then a ``` fence; the figure "**N / L**" is the last one between the previous block and this one
const blocks = {};
{
  const re = /<!-- field: ([a-z0-9-]+) -->\s*\n```\n([\s\S]*?)\n```/g;
  let m, from = 0;
  while ((m = re.exec(md))) {
    const before = md.slice(from, m.index);
    const fig = [...before.matchAll(/\*\*(\d+) \/ (\d+)\*\*/g)].pop();
    if (blocks[m[1]]) problems.push(`field ${m[1]}: two copy blocks`);
    blocks[m[1]] = { text: m[2], stated: fig ? Number(fig[1]) : null, statedLimit: fig ? Number(fig[2]) : null };
    from = m.index + m[0].length;
  }
}

// [id, label, limit, unit, customer-facing]
const FIELDS = [
  ['name', 'Name', 30, 'chars', true],
  ['name-fallback-a', 'Name (fallback A)', 30, 'chars', true],
  ['name-fallback-b', 'Name (fallback B)', 30, 'chars', true],
  ['subtitle', 'Subtitle', 30, 'chars', true],
  ['promo', 'Promotional Text', 170, 'chars', true],
  ['description', 'Description', 4000, 'chars', true],
  ['keywords', 'Keywords', 100, 'bytes', true],
  ['whats-new', "What's New", 4000, 'chars', true],
  ['review-notes', 'App Review Notes', 4000, 'chars', false],
  ['copyright', 'Copyright', 200, 'chars', false],
];

// customer-facing: no play with other people (the squad is AI), no other platforms / stores, no other games' names,
// no price or ranking claims, no pre-release words
const BANNED_FACING = [
  'online', 'multiplayer', 'multi-player', 'co-op', 'coop', 'cooperative', 'pvp', 'friends', 'clan', 'guild', 'leaderboard',
  'browser', 'web version', 'android', 'google play', 'steam', 'xbox', 'playstation', 'nintendo', 'windows',
  'beta version', 'beta test', 'testflight', 'demo version', 'coming soon',
  '#1', 'number one', 'best game', 'top game', 'award', 'free', 'sale', 'discount', 'download now',
  'alien swarm', 'helldivers', 'starship troopers', 'vampire survivors', 'alien shooter', 'earth defense force', 'deep rock',
];
// anywhere in every English store file: 1.x facts that are false for 2.0, and names the game must never use or imitate
const BANNED_EVERYWHERE = ['webgl', 'portrait', 'three.js', 'threejs', 'capacitor', 'wkwebview', 'darkswarm', 'dark swarm', 'bitfire', 'chryos', 'claude'];

const esc = (w) => w.replace(/[.*+?^${}()|[\]\\#]/g, '\\$&');
const wordRe = (w) => new RegExp(`(^|[^a-z0-9])${esc(w)}(?=$|[^a-z0-9])`, 'i');
const findBanned = (text, list) => list.filter((w) => wordRe(w).test(text));

const counts = {};
for (const [id, label, limit, unit, facing] of FIELDS) {
  const b = blocks[id];
  if (!b) { problems.push(`${label}: no copy block <!-- field: ${id} -->`); continue; }
  const n = unit === 'bytes' ? bytes(b.text) : chars(b.text);
  counts[label] = { n, limit, unit };
  if (id !== 'copyright') console.log(`  ${label.padEnd(18)} ${String(n).padStart(4)} / ${limit} ${unit}` + (unit === 'bytes' ? ` (${chars(b.text)} chars)` : ''));
  if (n > limit) problems.push(`${label}: ${n} ${unit}, limit ${limit}`);
  if (b.stated != null && id !== 'copyright' && (b.stated !== n || b.statedLimit !== limit)) problems.push(`${label}: heading says ${b.stated} / ${b.statedLimit}, real ${n} / ${limit} ${unit}`);
  if (/[Ѐ-ӿ]/.test(b.text)) problems.push(`${label}: Cyrillic text (2.0 ships in English only)`);
  if (/\t/.test(b.text)) problems.push(`${label}: tab character`);
  if (/[ \t]+$/m.test(b.text)) problems.push(`${label}: trailing spaces`);
  if (facing) for (const w of findBanned(b.text, BANNED_FACING)) problems.push(`${label}: must not say «${w}»`);
}
// price words matter most where Apple forbids them outright (name, subtitle, keywords); the general list above covers all

// keywords
const kw = blocks.keywords && blocks.keywords.text;
if (kw) {
  if (/\s/.test(kw)) problems.push('Keywords: no spaces or line breaks (comma-separated only)');
  const list = kw.split(',');
  for (const k of list) if (chars(k) <= 2) problems.push(`Keywords: «${k}» must be longer than two characters`);
  const dup = list.filter((k, j) => list.indexOf(k) !== j);
  if (dup.length) problems.push('Keywords: duplicates ' + dup.join(', '));
  const indexed = new Set(`${blocks.name ? blocks.name.text : ''} ${blocks.subtitle ? blocks.subtitle.text : ''}`.toLowerCase().split(/[^a-z0-9-]+/).filter((w) => w.length > 2));
  for (const k of list) {
    const stem = k.toLowerCase().replace(/s$/, '');
    if (indexed.has(k.toLowerCase()) || indexed.has(stem)) problems.push(`Keywords: «${k}» is already in the name or subtitle (wasted bytes)`);
  }
  for (const w of ['game', 'games', 'app', 'iphone', 'apple', 'action', 'arcade']) if (list.includes(w)) problems.push(`Keywords: «${w}» is a category or platform word`);
}

// copyright: App Store Connect prefixes the © itself
const cr = blocks.copyright && blocks.copyright.text;
if (cr && /©|\(c\)/i.test(cr)) problems.push('Copyright: drop the ©, App Store Connect adds it');

// summary table at the top: "| Field | limit | now |"
for (const m of md.matchAll(/^\| ([A-Za-z' ]+) \| (\d+)[^|]*\| (\d+)[^|]*\|$/gm)) {
  const c = counts[m[1].trim()];
  if (!c) continue;
  const lim = Number(m[2]), now = Number(m[3]);
  if (lim !== c.limit || now !== c.n) problems.push(`summary table, ${m[1].trim()}: says ${now} / ${lim}, real ${c.n} / ${c.limit} ${c.unit}`);
}
for (const label of ['Name', 'Subtitle', 'Promotional Text', 'Description', 'Keywords', "What's New", 'App Review Notes'])
  if (!new RegExp(`^\\| ${esc(label)} \\|`, 'm').test(md)) problems.push(`summary table: no row for ${label}`);

// ---------- facts against the native project ----------
const projectYml = read(path.join(NATIVE, 'project.yml'));
const infoPlist = read(path.join(NATIVE, 'App', 'Resources', 'Info.plist'));
const version = (/MARKETING_VERSION:\s*"?([\d.]+)"?/.exec(projectYml) || [])[1];
const minIOS = (/IPHONEOS_DEPLOYMENT_TARGET:\s*"?([\d.]+)"?/.exec(projectYml) || [])[1];
const family = (/TARGETED_DEVICE_FAMILY:\s*"?([\d,]+)"?/.exec(projectYml) || [])[1];
const notes10 = blocks['review-notes'] ? blocks['review-notes'].text : '';
if (!version) problems.push('project.yml: no MARKETING_VERSION');
else {
  if (!md.includes(`| ${version} /`)) problems.push(`listing: the Version row must say ${version} (project.yml MARKETING_VERSION)`);
  const major = version.replace(/\.0$/, '');
  if (!notes10.includes(`${major} `) && !notes10.includes(version)) problems.push(`App Review Notes: must name version ${major}`);
}
if (!minIOS) problems.push('project.yml: no IPHONEOS_DEPLOYMENT_TARGET');
else {
  if (!notes10.includes(`iOS ${minIOS} or later`)) problems.push(`App Review Notes: must say «iOS ${minIOS} or later» (project.yml)`);
  if (!new RegExp(`iPhone only, iOS ${esc(minIOS)} or later`).test(md)) problems.push(`listing: the Devices row must say «iPhone only, iOS ${minIOS} or later»`);
}
if (family !== '1') problems.push(`project.yml: TARGETED_DEVICE_FAMILY is ${family}, the listing says iPhone only`);
if (!/landscape only/i.test(notes10)) problems.push('App Review Notes: must say «landscape only»');
{
  const m = /<key>UISupportedInterfaceOrientations<\/key>\s*<array>([\s\S]*?)<\/array>/.exec(infoPlist);
  const o = m ? [...m[1].matchAll(/<string>([^<]+)<\/string>/g)].map((x) => x[1]) : [];
  if (!o.length || o.some((x) => !/Landscape/.test(x))) problems.push(`Info.plist: orientations ${o.join(', ') || '(none)'} — the listing says landscape only`);
  if (!/<key>ITSAppUsesNonExemptEncryption<\/key>\s*<false\/>/.test(infoPlist)) problems.push('Info.plist: ITSAppUsesNonExemptEncryption must be NO (section 8 says so)');
  const dn = (/<key>CFBundleDisplayName<\/key>\s*<string>([^<]*)<\/string>/.exec(infoPlist) || [])[1] || '';
  const name = blocks.name ? blocks.name.text : '';
  if (dn !== name) notes.push(`Info.plist CFBundleDisplayName is «${dn}», the store name is «${name}» (the English build sets it; check before upload)`);
}
// no networking, web view, ads or tracking in the app's Swift code (the review notes and the privacy policy say so)
const NET = /\bURLSession\b|\bURLRequest\b|\bNWConnection\b|\bNWPathMonitor\b|^\s*import\s+(Network|WebKit|SafariServices|StoreKit|GameKit|AdSupport|AppTrackingTransparency|CloudKit|Firebase\w*)\b|\bWKWebView\b|\bSFSafariViewController\b|\bASIdentifierManager\b|\bATTrackingManager\b|\bNSUbiquitousKeyValueStore\b/m;
const swiftFiles = [];
const walk = (d) => {
  let ents = [];
  try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
  for (const e of ents) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) { if (!['.build', 'build', 'DerivedData', 'node_modules'].includes(e.name)) walk(p); }
    else if (e.name.endsWith('.swift')) swiftFiles.push(p);
  }
};
walk(path.join(NATIVE, 'App', 'Sources'));
walk(path.join(NATIVE, 'IceHiveCore', 'Sources'));
if (!swiftFiles.length) problems.push('ios-native: no Swift sources found');
for (const f of swiftFiles) {
  const src = fs.readFileSync(f, 'utf8').split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
  const m = NET.exec(src);
  if (m) problems.push(`${rel(f)}: «${m[0].trim()}» — the listing and the privacy policy say the app makes no network requests and has no web view, ads or tracking`);
}
// fonts: every bundled font has its OFL licence text next to it
{
  const dir = path.join(NATIVE, 'App', 'Resources', 'Fonts');
  let files = [];
  try { files = fs.readdirSync(dir); } catch { problems.push(`missing ${rel(dir)}`); }
  for (const f of files.filter((x) => /\.(ttf|otf)$/i.test(x))) {
    const fam = f.replace(/[-[].*$/, '').replace(/\.(ttf|otf)$/i, '');
    if (!files.includes(`OFL-${fam}.txt`)) problems.push(`Fonts: ${f} has no OFL-${fam}.txt (the listing says every font is under the SIL Open Font License)`);
  }
}
// privacy manifest: no tracking, no collected data (App Privacy: Data Not Collected)
{
  const pi = read(path.join(NATIVE, 'App', 'Resources', 'PrivacyInfo.xcprivacy'));
  if (!/<key>NSPrivacyTracking<\/key>\s*<false\/>/.test(pi)) problems.push('PrivacyInfo.xcprivacy: NSPrivacyTracking must be false');
  if (!/<key>NSPrivacyCollectedDataTypes<\/key>\s*<array\/>/.test(pi)) problems.push('PrivacyInfo.xcprivacy: NSPrivacyCollectedDataTypes must be empty (Data Not Collected)');
}

// ---------- privacy policy ----------
const policyMd = read(POLICY_MD);
const policyHtml = read(POLICY_HTML);
{
  const store = read(path.join(NATIVE, 'IceHiveCore', 'Sources', 'IceHiveCore', 'SettingsStore.swift'));
  const keys = [...new Set([...store.matchAll(/\bput\("(\w+)"/g)].map((m) => m[1]))];
  if (keys.length < 5) problems.push(`SettingsStore.swift: found only ${keys.length} stored keys — has the store moved?`);
  for (const [f, t] of [[POLICY_MD, policyMd], [POLICY_HTML, policyHtml]]) {
    if (!t) continue;
    for (const k of keys) if (!t.includes(`ledulei.${k}`)) problems.push(`${rel(f)}: the stored-data list does not name ledulei.${k} (SettingsStore writes it)`);
    if (!t.includes(CONTACT)) problems.push(`${rel(f)}: no contact e-mail ${CONTACT}`);
    if (/[Ѐ-ӿ]/.test(t)) problems.push(`${rel(f)}: Cyrillic text (the 2.0 policy is English; the Russian one is store/privacy-policy-ru.*)`);
  }
  if (policyHtml) {
    if (/<script\b/i.test(policyHtml)) problems.push('privacy-policy.html: no scripts (the page must be self-contained and static)');
    if (/<link\b[^>]*rel=["']?stylesheet|@import|url\(\s*["']?https?:|\bsrc=["']?https?:/i.test(policyHtml)) problems.push('privacy-policy.html: no external styles, fonts or images');
    if (!/<html lang="en"/.test(policyHtml)) problems.push('privacy-policy.html: <html lang="en"> expected');
  }
}

// ---------- screenshot plan ----------
const plan = read(SHOT_PLAN);
if (plan) {
  for (const s of ['2868 × 1320', '2778 × 1284', '2622 × 1206']) if (!plan.includes(s)) problems.push(`screenshot plan: size ${s} not listed`);
  const shots = [...plan.matchAll(/^### (\d+)\. .*$/gm)].map((m) => Number(m[1]));
  if (shots.length !== 10 || shots.some((n, i) => n !== i + 1)) problems.push(`screenshot plan: ten shots numbered 1–10 expected, found ${shots.join(', ') || 'none'}`);
  const caps = [...plan.matchAll(/^Caption: `([^`]*)`$/gm)].map((m) => m[1]);
  const subs = [...plan.matchAll(/^Subline: `([^`]*)`$/gm)].map((m) => m[1]);
  if (caps.length !== 10) problems.push(`screenshot plan: ${caps.length} captions, 10 expected`);
  if (subs.length !== 10) problems.push(`screenshot plan: ${subs.length} sublines, 10 expected`);
  caps.forEach((c, i) => {
    if (chars(c) > 30) problems.push(`screenshot ${i + 1}: caption «${c}» is ${chars(c)} chars, limit 30`);
    for (const w of findBanned(c, BANNED_FACING)) problems.push(`screenshot ${i + 1}: caption must not say «${w}»`);
  });
  subs.forEach((c, i) => {
    if (chars(c) > 48) problems.push(`screenshot ${i + 1}: subline «${c}» is ${chars(c)} chars, limit 48`);
    for (const w of findBanned(c, BANNED_FACING)) problems.push(`screenshot ${i + 1}: subline must not say «${w}»`);
  });
  if (new Set(caps).size !== caps.length) problems.push('screenshot plan: two shots share a caption');
}

// ---------- every English store file ----------
const placeholders = [];
for (const [f, t] of [[FILE, md], [POLICY_MD, policyMd], [POLICY_HTML, policyHtml], [SHOT_PLAN, plan]]) {
  if (!t) continue;
  for (const w of findBanned(t, BANNED_EVERYWHERE)) problems.push(`${rel(f)}: must not say «${w}»`);
  for (const m of t.matchAll(/\[OWNER: ([^\]]+)\]/g)) placeholders.push(`${rel(f)}: [OWNER: ${m[1]}]`);
  // a placeholder in any other bracket style would slip past the list above
  for (const m of t.matchAll(/\[([A-Z][A-Z .,'/-]{5,})\]/g)) problems.push(`${rel(f)}: placeholder «[${m[1]}]» — write it as [OWNER: …]`);
}
const uniq = [...new Set(placeholders)];
if (uniq.length) {
  console.log(`  placeholders the owner fills (${uniq.length}):`);
  for (const p of uniq) console.log('    - ' + p);
  if (RELEASE) problems.push(`${uniq.length} [OWNER: …] placeholder(s) left (release check)`);
}
for (const n of notes) console.log('  note: ' + n);

if (problems.length) { console.error('[check:store] FAILED\n  - ' + problems.join('\n  - ')); process.exit(1); }
console.log(`[check:store] OK — ${rel(FILE)}, privacy policy, screenshot plan` + (RELEASE ? ' (release)' : ''));
