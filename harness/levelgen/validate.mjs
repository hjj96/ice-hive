// Station generator check over many seeds, in Node (no browser): loads the generator straight from
// game/js/04-level.js, then re-checks every layout with an independent raster + BFS (the same rules as
// rasterLevel): start reaches every beacon ring and the lift, >= 97% of the floor reachable, no cliffs between
// walkable neighbours, objective tour 190-320 cells, and a lift rim edge with z - lift.z < -4 (the queen's climb).
//   node harness/levelgen/validate.mjs [N=1000] [maps=1,2,3]
// Exit code 1 when any seed fails. ASCII maps of the hand-made level and a few seeds -> harness/out/levelgen-maps.txt
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '../..');
const JS = path.join(ROOT, 'game', 'js');
const core = fs.readFileSync(path.join(JS, '01-core.js'), 'utf8');
const lvl = fs.readFileSync(path.join(JS, '04-level.js'), 'utf8');
const cut = (src, a, b) => { const i = src.indexOf(a), j = src.indexOf(b, i + 1); if (i < 0 || j < 0) throw new Error('validate: cannot find ' + a + ' .. ' + b); return src.slice(i, j); };
const code = [
  'const G = 128, GH = 64, TAU = Math.PI * 2;',
  cut(core, 'function mulberry32', 'function fmtTime'),
  cut(lvl, 'function cellOf', 'function cellX'),
  cut(lvl, 'const LG = {', 'let LIFT_Y'),
  cut(lvl, 'let LIFT_Y', 'let levelSeed'),
  'return { genLevel, genCheck, HAND_LEVEL };',
].join('\n');
const api = new Function(code)();

// ---------- independent re-check ----------
const G = 128, GH = 64;
const rectH = (hs, z) => typeof hs === 'number' ? hs : z <= hs.a ? hs.ha : z >= hs.b ? hs.hb : hs.ha + (hs.hb - hs.ha) * (z - hs.a) / (hs.b - hs.a);
const cellOf = (x, z) => { const i = Math.floor(x + GH), j = Math.floor(z + GH); return (i < 0 || j < 0 || i >= G || j >= G) ? -1 : j * G + i; };
function raster(L) {
  const walk = new Uint8Array(G * G), hgt = new Float32Array(G * G), lift = new Uint8Array(G * G);
  for (const [x0, z0, x1, z1, , , hs] of L.rects) for (let j = 0; j < G; j++) for (let i = 0; i < G; i++) {
    const x = i - GH + 0.5, z = j - GH + 0.5; if (x > x0 && x < x1 && z > z0 && z < z1) { walk[j * G + i] = 1; hgt[j * G + i] = rectH(hs, z); }
  }
  const T = L.lift;
  for (let j = 0; j < G; j++) for (let i = 0; i < G; i++) { const x = i - GH + 0.5, z = j - GH + 0.5; if ((x - T.x) ** 2 + (z - T.z) ** 2 < (T.r - 0.3) ** 2) { walk[j * G + i] = 1; lift[j * G + i] = 1; hgt[j * G + i] = T.y; } }
  for (const [x0, z0, w, d] of L.crates) for (let a = 0; a < w; a++) for (let b = 0; b < d; b++) { const c = cellOf(x0 + a + 0.5, z0 + b + 0.5); if (c >= 0) walk[c] = 2; }
  for (const [x, z] of L.pillars) { const c = cellOf(x, z); if (c >= 0) walk[c] = 2; }
  // spawn edges as rasterLevel builds them (before the beacon bases are placed)
  const edges = [];
  for (let j = 1; j < G - 1; j++) for (let i = 1; i < G - 1; i++) { const c = j * G + i; if (walk[c] === 1 && (!walk[c - 1] || !walk[c + 1] || !walk[c - G] || !walk[c + G])) edges.push(c); }
  for (const b of L.beacons) for (const [ox, oz] of [[-0.5, -0.5], [0.5, -0.5], [-0.5, 0.5], [0.5, 0.5]]) walk[cellOf(b.x + ox, b.z + oz)] = 2;
  let floor = 0, cliffs = 0;
  for (let j = 1; j < G - 1; j++) for (let i = 1; i < G - 1; i++) {
    const c = j * G + i; if (walk[c] !== 1) continue; floor++;
    if (walk[c + 1] === 1 && Math.abs(hgt[c + 1] - hgt[c]) > 0.05) cliffs++;
    if (walk[c + G] === 1 && Math.abs(hgt[c + G] - hgt[c]) > 0.65) cliffs++;
  }
  return { walk, lift, edges, floor, cliffs };
}
function bfs(walk, from) {
  const d = new Int32Array(G * G).fill(-1), q = new Int32Array(G * G); let h = 0, t = 0; d[from] = 0; q[t++] = from;
  while (h < t) { const c = q[h++], i = c % G; for (const n of [i > 0 ? c - 1 : -1, i < G - 1 ? c + 1 : -1, c - G, c + G]) { if (n < 0 || n >= G * G || walk[n] !== 1 || d[n] >= 0) continue; d[n] = d[c] + 1; q[t++] = n; } }
  return d;
}
function check(L) {
  const r = raster(L), s = cellOf(L.start.x + 0.5, L.start.z + 0.5);
  if (r.walk[s] !== 1) return { ok: false, why: 'start blocked', r };
  const d = bfs(r.walk, s);
  let reach = 0; for (let c = 0; c < G * G; c++) if (r.walk[c] === 1 && d[c] >= 0) reach++;
  const ringD = (x, z) => { let m = 1e9; for (let j = -4; j <= 4; j++) for (let i = -4; i <= 4; i++) { if (i * i + j * j > 16) continue; const c = cellOf(x + i, z + j); if (c >= 0 && d[c] >= 0) m = Math.min(m, d[c]); } return m; };
  if (L.beacons.some(b => ringD(b.x, b.z) >= 1e9) || ringD(L.lift.x, L.lift.z) >= 1e9) return { ok: false, why: 'unreachable objective', r };
  let pos = s, tour = 0; const left = L.beacons.slice();
  while (left.length) { const dd = bfs(r.walk, pos); let bi = 0, bv = 1e9; left.forEach((b, k) => { const c = cellOf(b.x + 2.5, b.z + 2.5); const v = dd[c] >= 0 ? dd[c] : 1e9; if (v < bv) { bv = v; bi = k; } }); tour += bv; pos = cellOf(left[bi].x + 2.5, left[bi].z + 2.5); left.splice(bi, 1); }
  tour += bfs(r.walk, pos)[cellOf(L.lift.x, L.lift.z)];
  const T = L.lift;
  const rim = r.edges.filter(c => { const x = (c % G) - GH + 0.5, z = ((c / G) | 0) - GH + 0.5; return (x - T.x) ** 2 + (z - T.z) ** 2 <= (T.r + 1.5) ** 2 && z - T.z < -4; }).length;
  const frac = reach / r.floor;
  const why = r.cliffs ? 'cliff' : frac <= 0.97 ? 'pockets' : tour < 190 || tour > 320 ? 'tour' : !rim ? 'no queen rim' : '';
  return { ok: !why, why, reach: +frac.toFixed(3), floor: r.floor, edges: r.edges.length, tour, rim, cliffs: r.cliffs, r };
}
function ascii(L, r) {
  const mark = new Map();
  mark.set(cellOf(L.start.x, L.start.z), 'S');
  L.beacons.forEach((b, k) => mark.set(cellOf(b.x, b.z), 'ABC'[k]));
  mark.set(cellOf(L.lift.x, L.lift.z), 'L');
  for (const v of L.vents) mark.set(cellOf(v[0], v[1]), 'v');
  const rows = [];
  for (let j = 6; j < G - 6; j += 2) {
    let line = '';
    for (let i = 4; i < G - 4; i++) {
      const c = j * G + i, c2 = c + G, m = mark.get(c) || mark.get(c2);
      if (m) { line += m; continue; }
      const w = Math.max(r.walk[c], r.walk[c2]);
      line += w === 0 ? ' ' : (r.walk[c] === 2 || r.walk[c2] === 2) ? '#' : (r.lift[c] ? 'o' : '.');
    }
    rows.push(line.replace(/\s+$/, ''));
  }
  return rows.join('\n');
}

const N = +(process.argv[2] || 1000);
const hand = api.HAND_LEVEL, hc = check(hand), hg = api.genCheck(hand);
console.log('hand-made «Кельвин-9»:', { floor: hc.floor, edges: hc.edges, tour: hc.tour, reach: hc.reach, rim: hc.rim, cliffs: hc.cliffs, ok: hc.ok }, '| in-game genCheck:', { ok: hg.ok, tour: hg.tour });
let ok = 0, nullGen = 0, attempts = 0, maxAtt = 0, disagree = 0;
const fail = {}, tours = [], floors = [], edgesA = [], rims = [], genT = [];
for (let s = 1; s <= N; s++) {
  const a = performance.now();
  const L = api.genLevel(s);
  genT.push(performance.now() - a);
  if (!L) { nullGen++; fail['fallback to seed 0'] = (fail['fallback to seed 0'] || 0) + 1; continue; }
  attempts += L.attempts; maxAtt = Math.max(maxAtt, L.attempts);
  const c = check(L);
  if (c.tour !== L.check.tour || c.ok !== L.check.ok) disagree++;
  if (c.ok) { ok++; tours.push(c.tour); floors.push(c.floor); edgesA.push(c.edges); rims.push(c.rim); } else fail[c.why] = (fail[c.why] || 0) + 1;
}
const q = (a, p) => { const b = a.slice().sort((x, y) => x - y); return b[Math.floor(p * (b.length - 1))]; };
console.log(`seeds ${N}: valid ${ok}/${N}, failures`, fail, `| in-game check disagrees on ${disagree} | tries per seed avg ${(attempts / Math.max(1, N - nullGen)).toFixed(2)} (max ${maxAtt})`);
console.log('tour cells  p10/p50/p90:', q(tours, 0.1), q(tours, 0.5), q(tours, 0.9), '(hand-made', hc.tour + ', enforced 190-320)');
console.log('floor cells p10/p50/p90:', q(floors, 0.1), q(floors, 0.5), q(floors, 0.9), '(hand-made', hc.floor + ')');
console.log('edge cells  p10/p50/p90:', q(edgesA, 0.1), q(edgesA, 0.5), q(edgesA, 0.9), '(hand-made', hc.edges + ')');
console.log('queen rim edges min/p50:', Math.min(...rims), q(rims, 0.5), '(hand-made', hc.rim + ')');
console.log('genLevel ms p50/p99/max:', q(genT, 0.5).toFixed(2), q(genT, 0.99).toFixed(2), Math.max(...genT).toFixed(2));
const show = String(process.argv[3] || '1,2,3').split(',').map(Number);
let out = '=== hand-made «Кельвин-9» ===\n' + ascii(hand, hc.r) + '\n';
for (const s of show) { const L = api.genLevel(s); if (!L) continue; const c = check(L); out += `\n=== seed ${s} (tries ${L.attempts}, tour ${c.tour}, floor ${c.floor}, ok ${c.ok} ${c.why}) rowH ${L.meta.rowH} ===\n` + ascii(L, c.r) + '\n'; }
const MAPS = path.join(ROOT, 'harness', 'out', 'levelgen-maps.txt');
fs.mkdirSync(path.dirname(MAPS), { recursive: true });
fs.writeFileSync(MAPS, out);
console.log('maps ->', path.relative(ROOT, MAPS));
console.log(ok === N && hc.ok && !disagree ? 'RESULT PASS' : 'RESULT FAIL');
process.exitCode = ok === N && hc.ok && !disagree ? 0 : 1;
