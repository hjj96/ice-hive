// Summarises calibration results per tag + mode (port of the combat lens' agg2.mjs, plus the Матка and pressure).
//   node harness/calib/agg.mjs a.jsonl [b.jsonl ...]
// Columns: n, win %, downs per run (all four marines), share of runs with 0 / 1–3 / 4+ downs, player downs, median
// player min HP, hold reached %, Матка reached % / killed % of reached / median kill s, idleMax median / max,
// first player down median (AFK), mean win / loss time, wins per class, downs by stage.
import fs from 'node:fs';
const rows = process.argv.slice(2).flatMap((f) => fs.readFileSync(f, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l)));
const errs = rows.filter((r) => r.error);
if (errs.length) console.log('errors:', errs.length, errs.map((r) => r.tag + '/' + r.cls).join(' '));
const ok = rows.filter((r) => !r.error);
const g = {};
for (const r of ok) { const k = r.tag + ' ' + r.mode; (g[k] = g[k] || []).push(r); }
const mean = (a) => (a.length ? a.reduce((x, y) => x + y, 0) / a.length : NaN);
const med = (a) => { const s = [...a].sort((x, y) => x - y); return s.length ? (s.length % 2 ? s[s.length >> 1] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2) : NaN; };
const P = (s, n) => String(s).padStart(n);
const pct = (a, n) => (n ? Math.round((100 * a) / n) : '-');
console.log('tag mode'.padEnd(18), P('n', 3), P('win%', 5), P('dn/r', 5), P('0dn%', 5), P('1-3%', 5), P('4+%', 4), P('pDn', 4), P('pMin', 5),
  P('hold%', 6), P('Qrch%', 6), P('Qkil%', 6), P('Qmed', 5), P('idleMd', 7), P('idleMx', 7), P('pDn1', 6), P('tWin', 5), P('tLoss', 6), '  perClass | downs by stage');
for (const [k, rs] of Object.entries(g).sort()) {
  const won = rs.filter((r) => r.result === 'won'), lost = rs.filter((r) => r.result === 'lost');
  const dn = rs.map((r) => r.downs.reduce((a, b) => a + b, 0));
  const per = {};
  for (const r of rs) { per[r.cls] = per[r.cls] || [0, 0]; per[r.cls][1]++; if (r.result === 'won') per[r.cls][0]++; }
  const ds = {};
  for (const r of rs) for (const [s, v] of Object.entries(r.downSt || {})) ds[s] = (ds[s] || 0) + v;
  const hold = rs.filter((r) => r.stageAt && r.stageAt.hold != null);
  const qr = rs.filter((r) => r.queen), qk = qr.filter((r) => r.queen.killT != null);
  const pd1 = rs.map((r) => r.pFirstDown).filter((t) => t >= 0);
  console.log(k.padEnd(18), P(rs.length, 3), P(pct(won.length, rs.length), 5), P(mean(dn).toFixed(1), 5),
    P(pct(dn.filter((d) => d === 0).length, rs.length), 5), P(pct(dn.filter((d) => d >= 1 && d <= 3).length, rs.length), 5), P(pct(dn.filter((d) => d >= 4).length, rs.length), 4),
    P(mean(rs.map((r) => r.downs[0])).toFixed(1), 4), P(med(rs.map((r) => r.minHp[0])), 5),
    P(pct(hold.length, rs.length), 6), P(pct(qr.length, rs.length), 6), P(pct(qk.length, qr.length), 6), P(qk.length ? med(qk.map((r) => r.queen.killT)).toFixed(1) : '-', 5),
    P(med(rs.map((r) => r.idleMax)).toFixed(2), 7), P(Math.max(...rs.map((r) => r.idleMax)).toFixed(2), 7),
    P(pd1.length ? med(pd1).toFixed(0) + (pd1.length < rs.length ? '*' : '') : '-', 6),
    P(won.length ? Math.round(mean(won.map((r) => r.t))) : '-', 5), P(lost.length ? Math.round(mean(lost.map((r) => r.t))) : '-', 6),
    '  ' + Object.entries(per).map(([c, [w, n]]) => c.slice(0, 2) + w + '/' + n).join(' ') + ' | ' + Object.entries(ds).map(([s, v]) => s + ':' + (v / rs.length).toFixed(1)).join(' '));
}
console.log('(pDn1: median time of the first player down; * = some runs had none. Qkil% is of the runs that reached her.)');
