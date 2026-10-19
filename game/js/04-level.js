// ================================================================
//  LEVEL — grated platforms over an abyss. Seed 0 is the hand-made
//  «Кельвин-9» (landing pad / hub / beacon A at 0 m, plaza and beacons
//  B, C at −3 m, the cargo lift at −6 m); any other seed is a generated
//  station (LEVELGEN below). Real staircases and sloped catwalks connect
//  the decks (the simulation stays 2D; every visual y comes from groundY()).
//  rebuildLevel(seed) swaps the layout in place between missions.
// ================================================================
const walk = new Uint8Array(G * G);      // 0 abyss, 1 floor, 2 floor blocked by a prop
const liftCell = new Uint8Array(G * G);  // 1 = part of the lift disc
const hazCell = new Uint8Array(G * G);   // 1 = hazard-striped platform (beacons / pad)
const hgt = new Float32Array(G * G);     // floor height at the cell centre
const hgz = new Float32Array(G * G);     // dy/dz inside the cell (ramps run along z)
const stairCell = new Uint8Array(G * G); // 1 = stepped staircase (decals float a little higher there)
function cellOf(x, z) {
  const i = Math.floor(x + GH), j = Math.floor(z + GH);
  return (i < 0 || j < 0 || i >= G || j >= G) ? -1 : j * G + i;
}
function cellX(c) { return (c % G) - GH + 0.5; }
function cellZ(c) { return ((c / G) | 0) - GH + 0.5; }
// Visual ground height at any world point (exact on ramps; abyss cells near floors inherit the floor height)
function groundY(x, z) {
  const i = Math.floor(x + GH), j = Math.floor(z + GH);
  if (i < 0 || j < 0 || i >= G || j >= G) return 0;
  const c = j * G + i;
  return hgt[c] + hgz[c] * (z - (j - GH + 0.5));
}

// ================================================================
//  LEVELGEN — seeded station layouts from modules on a 4x4 node lattice.
//  Pure data (no THREE): returns rects / crates / pillars / lift / beacons / vents / pipes in the exact
//  format 04-level.js already consumes. Ramps and stairs only run along z and heights only step DOWN
//  toward -z (away from the camera), so every lower deck is seen from above and never hides a higher one.
// ================================================================
const LG = { COLS: 4, ROWS: 4, PITCH: 24, TOUR_MIN: 190, TOUR_MAX: 320, REACH: 0.97 };
// a layout is accepted only when genCheck passes; after 40 rejected tries the caller falls back to seed 0
function genLevel(seed, opt) {
  opt = opt || {};
  for (let attempt = 0; attempt < 40; attempt++) {
    const L = genTry((seed >>> 0) * 977 + attempt * 7919, opt);
    if (!L) continue;
    const c = genCheck(L);
    if (c.ok) { L.seed = seed; L.attempts = attempt + 1; L.check = c; return L; }
  }
  return null;
}
// ---- validation on a scratch raster (same rules as rasterLevel; the live walk grid is never touched) ----
const GC_WALK = new Uint8Array(G * G), GC_LIFT = new Uint8Array(G * G), GC_H = new Float32Array(G * G);
const GC_D = new Int32Array(G * G), GC_Q = new Int32Array(G * G);
function genBfs(from) {
  const d = GC_D, q = GC_Q, w = GC_WALK; d.fill(-1);
  let h = 0, t = 0; d[from] = 0; q[t++] = from;
  while (h < t) {
    const c = q[h++], i = c % G, n1 = d[c] + 1;
    if (i > 0 && w[c - 1] === 1 && d[c - 1] < 0) { d[c - 1] = n1; q[t++] = c - 1; }
    if (i < G - 1 && w[c + 1] === 1 && d[c + 1] < 0) { d[c + 1] = n1; q[t++] = c + 1; }
    if (c >= G && w[c - G] === 1 && d[c - G] < 0) { d[c - G] = n1; q[t++] = c - G; }
    if (c < G * (G - 1) && w[c + G] === 1 && d[c + G] < 0) { d[c + G] = n1; q[t++] = c + G; }
  }
  return d;
}
// connectivity (start reaches every beacon ring and the lift, >= 97% of the floor), no cliffs between walkable
// neighbours, objective tour 190-320 cells (the greedy order the autopilot plays), and a lift rim edge on the far
// side (z - lift.z < -4) for the queen's climb
function genCheck(L) {
  const w = GC_WALK, lc = GC_LIFT, hg = GC_H;
  w.fill(0); lc.fill(0); hg.fill(0);
  for (const [x0, z0, x1, z1, , , hs] of L.rects) {
    const i0 = Math.max(0, Math.floor(x0 + GH - 0.5)), i1 = Math.min(G - 1, Math.ceil(x1 + GH)), j0 = Math.max(0, Math.floor(z0 + GH - 0.5)), j1 = Math.min(G - 1, Math.ceil(z1 + GH));
    for (let j = j0; j <= j1; j++) for (let i = i0; i <= i1; i++) {
      const x = i - GH + 0.5, z = j - GH + 0.5;
      if (x > x0 && x < x1 && z > z0 && z < z1) { w[j * G + i] = 1; hg[j * G + i] = rectH(hs, z); }
    }
  }
  const T = L.lift;
  for (let j = 0; j < G; j++) for (let i = 0; i < G; i++) {
    const x = i - GH + 0.5, z = j - GH + 0.5;
    if ((x - T.x) ** 2 + (z - T.z) ** 2 < (T.r - 0.3) ** 2) { const c = j * G + i; w[c] = 1; lc[c] = 1; hg[c] = T.y; }
  }
  for (const [x0, z0, cw, cd] of L.crates) for (let a = 0; a < cw; a++) for (let b = 0; b < cd; b++) { const c = cellOf(x0 + a + 0.5, z0 + b + 0.5); if (c >= 0) w[c] = 2; }
  for (const [x, z] of L.pillars) { const c = cellOf(x, z); if (c >= 0) w[c] = 2; }
  // the queen's rim: a spawn edge (floor next to the abyss) by the lift, on its far side
  let rim = 0;
  for (let j = 1; j < G - 1; j++) for (let i = 1; i < G - 1; i++) {
    const c = j * G + i; if (w[c] !== 1) continue;
    if (w[c - 1] && w[c + 1] && w[c - G] && w[c + G]) continue;
    const x = i - GH + 0.5, z = j - GH + 0.5;
    if ((x - T.x) ** 2 + (z - T.z) ** 2 <= (T.r + 1.5) ** 2 && z - T.z < -4) rim++;
  }
  for (const b of L.beacons) for (const [ox, oz] of [[-0.5, -0.5], [0.5, -0.5], [-0.5, 0.5], [0.5, 0.5]]) { const c = cellOf(b.x + ox, b.z + oz); if (c >= 0) w[c] = 2; }
  let floor = 0, cliffs = 0;
  for (let j = 1; j < G - 1; j++) for (let i = 1; i < G - 1; i++) {
    const c = j * G + i; if (w[c] !== 1) continue; floor++;
    if (w[c + 1] === 1 && Math.abs(hg[c + 1] - hg[c]) > 0.05) cliffs++;
    if (w[c + G] === 1 && Math.abs(hg[c + G] - hg[c]) > 0.65) cliffs++;
  }
  const s = cellOf(L.start.x + 0.5, L.start.z + 0.5);
  if (s < 0 || w[s] !== 1) return { ok: false, why: 'start' };
  let d = genBfs(s), reach = 0;
  for (let c = 0; c < G * G; c++) if (w[c] === 1 && d[c] >= 0) reach++;
  const ringD = (x, z) => { let m = 1e9; for (let j = -4; j <= 4; j++) for (let i = -4; i <= 4; i++) { if (i * i + j * j > 16) continue; const c = cellOf(x + i, z + j); if (c >= 0 && d[c] >= 0) m = Math.min(m, d[c]); } return m; };
  if (L.beacons.some(b => ringD(b.x, b.z) >= 1e9) || ringD(T.x, T.z) >= 1e9) return { ok: false, why: 'unreachable' };
  // greedy tour start -> nearest unvisited beacon -> ... -> lift
  let tour = 0;
  const left = L.beacons.slice();
  while (left.length) {
    let bi = 0, bv = 1e9;
    left.forEach((b, k) => { const c = cellOf(b.x + 2.5, b.z + 2.5), v = c >= 0 && d[c] >= 0 ? d[c] : 1e9; if (v < bv) { bv = v; bi = k; } });
    if (bv >= 1e9) return { ok: false, why: 'unreachable' };
    tour += bv;
    d = genBfs(cellOf(left[bi].x + 2.5, left[bi].z + 2.5));
    left.splice(bi, 1);
  }
  const lt = d[cellOf(T.x, T.z)];
  if (lt < 0) return { ok: false, why: 'unreachable' };
  tour += lt;
  const reachFrac = reach / Math.max(1, floor);
  const why = cliffs ? 'cliff' : reachFrac <= LG.REACH ? 'pockets' : tour < LG.TOUR_MIN || tour > LG.TOUR_MAX ? 'tour' : !rim ? 'rim' : '';
  return { ok: !why, why, tour, floor, reach: +reachFrac.toFixed(3), rim, cliffs };
}
function genTry(s, opt) {
  const R = mulberry32(s), ri = (a, b) => a + Math.floor(R() * (b - a + 1)), pick = (a) => a[Math.floor(R() * a.length)];
  const { COLS, ROWS, PITCH } = LG;
  const id = (c, r) => r * COLS + c, colOf = (n) => n % COLS, rowOf = (n) => (n / COLS) | 0;
  const nb = (n) => { const c = colOf(n), r = rowOf(n), o = []; if (c > 0) o.push(n - 1); if (c < COLS - 1) o.push(n + 1); if (r > 0) o.push(n - COLS); if (r < ROWS - 1) o.push(n + COLS); return o; };
  // ---- 1. grow a random tree from the start node (row 0 = nearest the camera, highest deck) ----
  const target = opt.nodes || ri(8, 10);
  const start = id(ri(0, COLS - 1), 0);
  const inSet = new Uint8Array(COLS * ROWS), edges = new Set(), adj = Array.from({ length: COLS * ROWS }, () => []);
  const ek = (a, b) => a < b ? a + ':' + b : b + ':' + a;
  const link = (a, b) => { edges.add(ek(a, b)); adj[a].push(b); adj[b].push(a); };
  inSet[start] = 1; let count = 1;
  while (count < target) {
    const front = [];
    for (let n = 0; n < COLS * ROWS; n++) if (inSet[n]) for (const m of nb(n)) if (!inSet[m]) front.push([n, m]);
    if (!front.length) break;
    // bias toward growing downward (-z): the mission reads as a descent into the station
    const w = front.map(([n, m]) => rowOf(m) > rowOf(n) ? 1.6 : 1);
    let t = R() * w.reduce((a, b) => a + b, 0), k = 0;
    for (; k < front.length - 1; k++) { t -= w[k]; if (t <= 0) break; }
    const [n, m] = front[k];
    inSet[m] = 1; count++; link(n, m);
  }
  const bfs = (from) => { const d = new Int32Array(COLS * ROWS).fill(-1), q = [from]; d[from] = 0; while (q.length) { const n = q.shift(); for (const m of adj[n]) if (d[m] < 0) { d[m] = d[n] + 1; q.push(m); } } return d; };
  // ---- 2. lift: a leaf in row >= 2 whose only link comes from +z (the lift railing opens toward +z) ----
  let d0 = bfs(start), lift = -1, best = -1;
  for (let n = 0; n < COLS * ROWS; n++) {
    if (!inSet[n] || rowOf(n) < 2 || adj[n].length !== 1 || adj[n][0] !== n - COLS) continue;
    const sc = d0[n] * 10 + rowOf(n) * 3 + R();
    if (sc > best) { best = sc; lift = n; }
  }
  if (lift < 0) return null;
  // ---- 3. one or two loop links (never into the lift): flanking routes and kiting circles ----
  const loops = ri(1, 2);
  for (let tries = 0, made = 0; tries < 30 && made < loops; tries++) {
    const n = ri(0, COLS * ROWS - 1); if (!inSet[n] || n === lift) continue;
    const m = pick(nb(n)); if (!inSet[m] || m === lift || edges.has(ek(n, m))) continue;
    link(n, m); made++;
  }
  d0 = bfs(start);
  // ---- 4. three beacons: far from the start and from each other (farthest-point on graph distance) ----
  const cand = []; for (let n = 0; n < COLS * ROWS; n++) if (inSet[n] && n !== start && n !== lift) cand.push(n);
  if (cand.length < 3) return null;
  const beac = [];
  while (beac.length < 3) {
    let bn = -1, bs = -1;
    for (const n of cand) {
      if (beac.includes(n)) continue;
      const dn = bfs(n);
      let mind = d0[n] * 0.8;
      for (const b of beac) mind = Math.min(mind, dn[b] * 1.2);
      // the node next to the lift stays a plain approach (the climax needs a clean run-up)
      const sc = mind + (adj[lift][0] === n ? -2 : 0) + R() * 0.5;
      if (sc > bs) { bs = sc; bn = n; }
    }
    beac.push(bn);
  }
  // ---- 5. heights per row: each row is level with, or 3 m below, the row nearer the camera ----
  const rowH = [0]; for (let r = 1; r < ROWS; r++) rowH.push(rowH[r - 1] - (R() < 0.55 ? 3 : 0));
  // ---- 6. node footprints (integer metres so the 1 m walk grid rasterises cleanly) ----
  const N = [];
  for (let n = 0; n < COLS * ROWS; n++) {
    if (!inSet[n]) { N.push(null); continue; }
    const big = beac.includes(n) || n === start;
    const hx = big ? ri(8, 9) : ri(6, 8), hz = big ? ri(8, 9) : ri(6, 8);
    const cx = -36 + PITCH * colOf(n) + ri(-2, 2), cz = 36 - PITCH * rowOf(n) + ri(-2, 2);
    N.push({ n, cx, cz, hx, hz, h: rowH[rowOf(n)], x0: cx - hx, x1: cx + hx, z0: cz - hz, z1: cz + hz });
  }
  const rects = [], crates = [], pillars = [], vents = [], pipes = [], mouths = [];
  const Lnode = N[lift], up = N[lift - COLS];
  const LIFT_R = 10, liftY = up.h - 3;
  // the lift disc sits under its approach node, centred on a 6 m stair that must fit inside that node
  const lx = clampI(Lnode.cx, up.x0 + 4, up.x1 - 4), lz = up.z0 - ri(10, 12) - LIFT_R;
  const liftInfo = { x: lx, z: lz, r: LIFT_R, y: liftY };
  N[lift] = null;
  for (const nd of N) if (nd) {
    const isB = beac.includes(nd.n), isS = nd.n === start;
    const kind = isS ? 's' : R() < 0.3 ? 's' : 'g';
    rects.push([nd.x0, nd.z0, nd.x1, nd.z1, kind, isB || isS ? 1 : 0, nd.h]);
    // L-shaped wing on some plain nodes: more corners, more railing edges for climbers
    if (!isB && !isS && R() < 0.4) {
      const side = ri(0, 3), w = ri(4, 6), len = ri(4, 6);
      let r2;
      if (side === 0) r2 = [nd.x1, nd.z1 - w - ri(0, 3), nd.x1 + len, null];
      else if (side === 1) r2 = [nd.x0 - len, nd.z0 + ri(0, 3), nd.x0, null];
      else if (side === 2) r2 = [nd.x0 + ri(0, 3), nd.z1, null, nd.z1 + len];
      else r2 = [nd.x1 - w - ri(0, 3), nd.z0 - len, null, nd.z0];
      if (r2[3] === null) r2[3] = r2[1] + w; if (r2[2] === null) r2[2] = r2[0] + w;
      nd.wing = r2;
    }
  }
  // ---- 7. connectors: flat bridges E-W, bridges / ramps / stairs N-S ----
  const conns = [];
  for (const e of edges) {
    const [a, b] = e.split(':').map(Number);
    if (a === lift || b === lift) continue;
    const A = N[a], Bn = N[b];
    if (rowOf(a) === rowOf(b)) {
      const W = colOf(a) < colOf(b) ? A : Bn, E = W === A ? Bn : A;
      const lo = Math.max(W.z0, E.z0) + 1, hi = Math.min(W.z1, E.z1) - 1;
      let w = R() < 0.25 ? 3 : ri(4, 6); if (hi - lo < w) w = hi - lo; if (w < 3) return null;
      const zc = clampI(Math.round((W.cz + E.cz) / 2), lo + Math.ceil(w / 2), hi - Math.floor(w / 2));
      const z0 = zc - Math.floor(w / 2), z1 = z0 + w;
      conns.push([W.x1, z0, E.x0, z1, R() < 0.2 ? 's' : 'g', 0, W.h]);
      mouths.push([W.x1, (z0 + z1) / 2], [E.x0, (z0 + z1) / 2]);
    } else {
      const U = rowOf(a) < rowOf(b) ? A : Bn, D = U === A ? Bn : A;   // U nearer the camera (+z), D lower z
      const lo = Math.max(U.x0, D.x0) + 1, hi = Math.min(U.x1, D.x1) - 1;
      const drop = U.h - D.h, stairs = drop !== 0 && R() < 0.6;
      let w = drop ? (stairs ? 6 : 4) : (R() < 0.25 ? 3 : ri(4, 6)); if (hi - lo < w) w = hi - lo; if (w < 3) return null;
      const xc = clampI(Math.round((U.cx + D.cx) / 2), lo + Math.ceil(w / 2), hi - Math.floor(w / 2));
      const x0 = xc - Math.floor(w / 2), x1 = x0 + w, za = D.z1, zb = U.z0;
      if (zb - za < 4) return null;
      const hs = drop ? { a: za + 0.5, ha: D.h, b: zb - 0.5, hb: U.h, stairs } : U.h;
      if (drop && zb - za - 1 < (stairs ? 5 : 6)) return null;   // too steep
      conns.push([x0, za, x1, zb, stairs ? 's' : 'g', 0, hs]);
      mouths.push([(x0 + x1) / 2, za], [(x0 + x1) / 2, zb]);
    }
  }
  // the stair down to the lift (lands 0.5 m inside the disc rim, as in the hand-made level)
  conns.push([lx - 3, lz + LIFT_R - 0.5, lx + 3, up.z0, 's', 0, { a: lz + LIFT_R + 1.5, ha: liftY, b: up.z0 - 0.5, hb: up.h, stairs: true }]);
  mouths.push([lx, up.z0]);
  // wings must not touch connectors or other nodes (2 m clearance), else they are dropped
  const all = () => rects.concat(conns);
  const hitsAny = (r, list, m) => list.some(o => r[0] < o[2] + m && r[2] > o[0] - m && r[1] < o[3] + m && r[3] > o[1] - m);
  const liftBox = [lx - LIFT_R - 1, lz - LIFT_R - 1, lx + LIFT_R + 1, lz + LIFT_R + 1];
  // the disc must clear every deck and bridge except its own stair (2 m air gap), and stay on the grid
  if (hitsAny(liftBox, rects.concat(conns.slice(0, -1)), 1) || lz - LIFT_R < -58) return null;
  for (const nd of N) if (nd && nd.wing) {
    const w = nd.wing, others = all().filter(o => !(o[0] === nd.x0 && o[1] === nd.z0 && o[2] === nd.x1 && o[3] === nd.z1));
    if (!hitsAny(w, others, 2) && !hitsAny(w, [liftBox], 1) && w[0] > -56 && w[2] < 56 && w[1] > -56 && w[3] < 56) rects.push([w[0], w[1], w[2], w[3], 'g', 0, nd.h]);
  }
  // ---- 8. dead-end catwalk spurs: extra climbing lanes that flank the route ----
  const spurs = ri(1, 2);
  for (let t = 0, made = 0; t < 20 && made < spurs; t++) {
    const nd = pick(N.filter(Boolean)); const side = ri(0, 3), w = 3, len = ri(5, 8);
    let r;
    if (side === 0) { const z0 = ri(nd.z0 + 1, nd.z1 - 4); r = [nd.x1, z0, nd.x1 + len, z0 + w]; }
    else if (side === 1) { const z0 = ri(nd.z0 + 1, nd.z1 - 4); r = [nd.x0 - len, z0, nd.x0, z0 + w]; }
    else if (side === 2) { const x0 = ri(nd.x0 + 1, nd.x1 - 4); r = [x0, nd.z1, x0 + w, nd.z1 + len]; }
    else { const x0 = ri(nd.x0 + 1, nd.x1 - 4); r = [x0, nd.z0 - len, x0 + w, nd.z0]; }
    const others = all().filter(o => !(o[0] === nd.x0 && o[1] === nd.z0 && o[2] === nd.x1 && o[3] === nd.z1));
    if (hitsAny(r, others, 2) || hitsAny(r, [liftBox], 1) || r[0] < -56 || r[2] > 56 || r[1] < -56 || r[3] > 56) continue;
    rects.push([r[0], r[1], r[2], r[3], 'g', 0, nd.h]);
    // a burrow vent at the far end: a visible flank the horde can pour out of
    vents.push([side === 0 ? r[2] - 1.5 : side === 1 ? r[0] + 1.5 : (r[0] + r[2]) / 2, side === 2 ? r[3] - 1.5 : side === 3 ? r[1] + 1.5 : (r[1] + r[3]) / 2]);
    made++;
  }
  // ---- 9. objective and prop placement ----
  const names = ['Альфа', 'Бета', 'Гамма'];
  const beacons = beac.map((n, k) => { const nd = N[n]; return { x: nd.cx + ri(-1, 1), z: nd.cz + ri(-1, 1), name: names[k], node: n }; });
  const sN = N[start];
  const startP = { x: sN.cx, z: sN.cz };
  const near = (x, z, list, r) => list.some(p => (p[0] - x) ** 2 + (p[1] - z) ** 2 < r * r);
  for (const b of beacons) {
    const nd = N[b.node];
    for (let k = 0, made = 0; k < 20 && made < 2; k++) {
      const a = R() * Math.PI * 2, d = 5.5 + R() * 1.5, x = Math.round(b.x + Math.cos(a) * d) + 0.5, z = Math.round(b.z + Math.sin(a) * d) + 0.5;
      if (x < nd.x0 + 1.5 || x > nd.x1 - 1.5 || z < nd.z0 + 1.5 || z > nd.z1 - 1.5 || near(x, z, vents, 4)) continue;
      vents.push([x, z]); made++;
    }
  }
  for (const nd of N) if (nd) {
    const isB = beac.includes(nd.n), isS = nd.n === start;
    // teal-lit pillars on the corners (inset 1.5 m), like the hand-made decks
    if (R() < 0.6 || isB || isS) for (const [sx, sz] of [[-1, -1], [1, 1], [-1, 1], [1, -1]]) if (R() < 0.6) {
      const x = (sx < 0 ? nd.x0 : nd.x1) - sx * 1.5, z = (sz < 0 ? nd.z0 : nd.z1) - sz * 1.5;
      if (!near(x, z, mouths, 3.5)) pillars.push([x, z]);
    }
    if (isS) {
      // crates stacked in one corner of the landing pad
      crates.push([nd.x0 + 2, nd.z1 - 3, 1, 1, 1.2], [nd.x0 + 3, nd.z1 - 3, 1, 1, 0.9], [nd.x0 + 2, nd.z1 - 4, 1, 1, 0.9]);
      continue;
    }
    const clusters = ri(1, 3);
    for (let c = 0, t = 0; c < clusters && t < 25; t++) {
      const w = ri(1, 2), d = ri(1, 2), x0 = ri(nd.x0 + 2, nd.x1 - 2 - w), z0 = ri(nd.z0 + 2, nd.z1 - 2 - d);
      const cx = x0 + w / 2, cz = z0 + d / 2;
      if (near(cx, cz, mouths, 4.5) || near(cx, cz, vents, 2.5) || near(cx, cz, pillars, 2)) continue;
      if (isB) { const b = beacons.find(q => q.node === nd.n); if (Math.hypot(cx - b.x, cz - b.z) < 4.6 + 2) continue; }
      crates.push([x0, z0, w, d, 0.8 + R() * 0.6]);
      if (R() < 0.5) crates.push([x0 + w, z0, 1, 1, 0.7 + R() * 0.4]);
      c++;
    }
  }
  // pipe bundles under a few south (−z) deck edges
  for (const nd of N) if (nd && R() < 0.45) pipes.push([nd.x0, nd.z0 - 0.3, nd.x1, nd.z0 - 0.3, nd.h]);
  return {
    rects: rects.concat(conns), crates, pillars, vents, pipes,
    start: startP, pad: [sN.x0, sN.z0, sN.x1, sN.z1], lift: liftInfo, beacons: beacons.map(b => ({ x: b.x, z: b.z, name: b.name })),
    meta: { nodes: count, start, lift, beac, rowH, edges: edges.size },
  };
}
function clampI(v, a, b) { return a > b ? Math.round((a + b) / 2) : v < a ? a : v > b ? b : v; }

let LIFT_Y = -6;
// x0, z0, x1, z1, kind (g = grating, s = snowy slab), hazard flag, height:
//   a number (flat) or a ramp along z: { a, ha, b, hb } — ha for z <= a, hb for z >= b, linear between (stairs: real steps)
const RECTS = [
  [22, 22, 38, 38, 's', 1, 0],      // landing pad
  [6, 27, 22, 33, 'g', 0, 0],
  [-8, 18, 6, 38, 'g', 0, 0],       // hub
  [-24, 25, -8, 31, 'g', 0, 0],
  [-40, 18, -24, 36, 'g', 1, 0],    // beacon A
  [-4, 2, 2, 18, 's', 0, { a: 5, ha: -3, b: 15, hb: 0, stairs: true }],      // staircase hub -> plaza
  [-12, -12, 10, 2, 'g', 0, -3],    // plaza
  [10, -8, 22, -2, 'g', 0, -3],
  [22, -16, 38, 0, 'g', 1, -3],     // beacon B
  [-26, -9, -12, -3, 'g', 0, -3],
  [-42, -18, -26, 0, 'g', 1, -3],   // beacon C
  [-6, -32.5, 0, -12, 's', 0, { a: -29, ha: LIFT_Y, b: -15, hb: -3, stairs: true }],  // staircase down to the lift
  [-36, 0, -32, 18, 'g', 0, { a: 1, ha: -3, b: 17, hb: 0 }],  // west loop catwalk (sloped)
  [30, 0, 34, 22, 'g', 0, { a: 1, ha: -3, b: 21, hb: 0 }],    // east loop catwalk (sloped)
];
function rectH(hs, z) {
  if (typeof hs === 'number') return hs;
  if (z <= hs.a) return hs.ha;
  if (z >= hs.b) return hs.hb;
  return hs.ha + (hs.hb - hs.ha) * (z - hs.a) / (hs.b - hs.a);
}
function rectGz(hs, z) { return (typeof hs === 'number' || z <= hs.a || z >= hs.b) ? 0 : (hs.hb - hs.ha) / (hs.b - hs.a); }
function rectMinH(hs) { return typeof hs === 'number' ? hs : Math.min(hs.ha, hs.hb); }

const LV = {
  start: { x: 30, z: 30 },
  lift: { x: -3, z: -42, r: 10, y: LIFT_Y },
  beacons: [
    { x: -32, z: 27, name: 'Альфа' },
    { x: 30, z: -8, name: 'Бета' },
    { x: -34, z: -9, name: 'Гамма' },
  ],
  vents: [[-27, 21], [-37, 33], [26, -13], [35, -3], [-39, -14], [-29, -4], [7, -9], [-9, -1]],
  edgeN: 0, edgeX: null, edgeZ: null, edgeNX: null, edgeNZ: null,
};
// crates: x0, z0, w, d, h (cells they cover become blocked)
const CRATES = [
  [24, 35, 1, 1, 1.2], [25, 35, 1, 1, 0.9], [24, 34, 1, 1, 0.9], [35, 23, 2, 1, 1.0], [36, 24, 1, 1, 1.3],
  [-7, 20, 1, 1, 1.1], [-6, 20, 1, 1, 0.8], [4, 35, 2, 1, 1.0], [3, 22, 1, 2, 1.2],
  [-10, -10, 2, 1, 1.1], [-10, -9, 1, 1, 0.8], [7, -10, 1, 1, 1.2], [8, -1, 2, 1, 0.9], [-11, 0, 1, 1, 1.0], [3, -6, 1, 1, 0.9], [-4, -4, 2, 2, 1.4],
  [-39, 19, 1, 1, 1.0], [-26, 34, 2, 1, 1.1], [-38, 33, 1, 2, 1.2],
  [23, -15, 1, 1, 1.1], [36, -2, 1, 1, 0.9], [35, -15, 2, 1, 1.0],
  [-41, -17, 1, 1, 1.2], [-28, -2, 1, 1, 1.0], [-40, -3, 2, 1, 0.9],
];
const PILLARS = [[23.5, 23.5], [36.5, 36.5], [-6.5, 36.5], [-11.5, -11.5], [9.5, -11.5], [9.5, 1.5], [-11.5, 1.5],
  [-39.5, 35.5], [-24.5, 18.5], [37.5, -15.5], [22.5, -0.5], [-41.5, -17.5], [-26.5, -0.5]];
// pipe bundles hanging off a few platform sides (x0, z0, x1, z1, platform height) and the landing pad rect
const PIPES = [[-8, 38.3, 6, 38.3, 0], [-12, -12.3, -6, -12.3, -3], [22, -16.3, 38, -16.3, -3], [-42, -18.3, -26, -18.3, -3], [38.3, 22, 38.3, 38, 0]];
const PAD = [22, 22, 38, 38];
const HAND_LEVEL = { rects: RECTS.slice(), crates: CRATES.slice(), pillars: PILLARS.slice(), pipes: PIPES.slice(), pad: PAD.slice(),
  start: { ...LV.start }, lift: { ...LV.lift }, beacons: LV.beacons.map(b => ({ ...b })), vents: LV.vents.slice() };
let levelSeed = 0;
function loadLevelData(L) {
  for (const [dst, src] of [[RECTS, L.rects], [CRATES, L.crates], [PILLARS, L.pillars], [PIPES, L.pipes], [PAD, L.pad], [LV.vents, L.vents]]) { dst.length = 0; dst.push(...src); }
  LV.beacons.length = 0; for (const b of L.beacons) LV.beacons.push({ ...b });
  LV.start.x = L.start.x; LV.start.z = L.start.z;
  Object.assign(LV.lift, L.lift); LIFT_Y = L.lift.y;
}

// ---------- walk grid + height field ----------
function rasterLevel() {
  walk.fill(0); liftCell.fill(0); hazCell.fill(0); hgt.fill(0); hgz.fill(0); stairCell.fill(0);
  const hset = new Uint8Array(G * G);
  for (const [x0, z0, x1, z1, , haz, hs] of RECTS) {
    for (let j = 0; j < G; j++) for (let i = 0; i < G; i++) {
      const x = i - GH + 0.5, z = j - GH + 0.5;
      if (x > x0 && x < x1 && z > z0 && z < z1) {
        const c = j * G + i;
        walk[c] = 1; if (haz) hazCell[c] = 1;
        hgt[c] = rectH(hs, z); hgz[c] = rectGz(hs, z); hset[c] = 1;
        if (typeof hs !== 'number' && hs.stairs && z > hs.a && z < hs.b) stairCell[c] = 1;
      }
    }
  }
  const L = LV.lift;
  for (let j = 0; j < G; j++) for (let i = 0; i < G; i++) {
    const x = i - GH + 0.5, z = j - GH + 0.5;
    if ((x - L.x) ** 2 + (z - L.z) ** 2 < (L.r - 0.3) ** 2) { const c = j * G + i; walk[c] = 1; liftCell[c] = 1; hgt[c] = LIFT_Y; hgz[c] = 0; hset[c] = 1; }
  }
  // abyss cells next to floors inherit the floor height (climbing bugs, effects and lasers at the edges)
  for (let pass = 0; pass < 4; pass++) {
    const add = [];
    for (let c = G; c < G * (G - 1); c++) {
      if (hset[c]) continue;
      for (const n of [c - 1, c + 1, c - G, c + G]) if (hset[n]) { add.push(c, n); break; }
    }
    for (let k = 0; k < add.length; k += 2) { const c = add[k], n = add[k + 1]; hgt[c] = hgt[n] + hgz[n] * (cellZ(c) - cellZ(n)); hgz[c] = hgz[n]; hset[c] = 1; }
  }
  for (const [x0, z0, w, d] of CRATES) {
    for (let a = 0; a < w; a++) for (let b = 0; b < d; b++) { const c = cellOf(x0 + a + 0.5, z0 + b + 0.5); if (c >= 0) walk[c] = 2; }
  }
  for (const [x, z] of PILLARS) { const c = cellOf(x, z); if (c >= 0) walk[c] = 2; }
  // abyss-adjacent floor cells become spawn edges (bugs climb over the railing there)
  const ex = [], ez = [], enx = [], enz = [];
  for (let j = 1; j < G - 1; j++) for (let i = 1; i < G - 1; i++) {
    const c = j * G + i; if (walk[c] !== 1) continue;
    let nx = 0, nz = 0;
    if (walk[c - 1] === 0) nx -= 1; if (walk[c + 1] === 0) nx += 1;
    if (walk[c - G] === 0) nz -= 1; if (walk[c + G] === 0) nz += 1;
    if (nx === 0 && nz === 0) continue;
    const l = Math.hypot(nx, nz); ex.push(i - GH + 0.5); ez.push(j - GH + 0.5); enx.push(nx / l); enz.push(nz / l);
  }
  LV.edgeN = ex.length;
  LV.edgeX = Float32Array.from(ex); LV.edgeZ = Float32Array.from(ez);
  LV.edgeNX = Float32Array.from(enx); LV.edgeNZ = Float32Array.from(enz);
}

// ---------- snow drift mask (world-space, 2 px per meter) ----------
function valueNoise(seed) {
  const R = mulberry32(seed), P = new Float32Array(256 * 256);
  for (let i = 0; i < P.length; i++) P[i] = R();
  return (x, z) => {
    const xi = Math.floor(x), zi = Math.floor(z), fx = x - xi, fz = z - zi;
    const u = fx * fx * (3 - 2 * fx), v = fz * fz * (3 - 2 * fz);
    const a = P[(zi & 255) * 256 + (xi & 255)], b = P[(zi & 255) * 256 + ((xi + 1) & 255)];
    const c = P[((zi + 1) & 255) * 256 + (xi & 255)], d = P[((zi + 1) & 255) * 256 + ((xi + 1) & 255)];
    return lerp(lerp(a, b, u), lerp(c, d, u), v);
  };
}
function buildSnowMask() {
  // distance (in cells) from railings / props, via BFS
  const dist = new Float32Array(G * G).fill(99), q = new Int32Array(G * G);
  let qh = 0, qt = 0;
  for (let c = 0; c < G * G; c++) {
    if (walk[c] === 0) continue;
    const i = c % G, j = (c / G) | 0;
    let edge = walk[c] === 2;
    if (!edge) for (const n of [c - 1, c + 1, c - G, c + G]) { const ni = n % G, nj = (n / G) | 0; if (Math.abs(ni - i) + Math.abs(nj - j) === 1 && walk[n] === 0) edge = true; }
    if (edge) { dist[c] = 0; q[qt++] = c; }
  }
  while (qh < qt) {
    const c = q[qh++], d = dist[c] + 1;
    for (const n of [c - 1, c + 1, c - G, c + G]) { if (n < 0 || n >= G * G || walk[n] === 0 || dist[n] <= d) continue; dist[n] = d; q[qt++] = n; }
  }
  const S = 256, data = new Uint8Array(S * S * 4), n1 = valueNoise(4), n2 = valueNoise(9);
  const slab = new Uint8Array(G * G);
  for (const [x0, z0, x1, z1, k] of RECTS) if (k === 's') {
    for (let j = 0; j < G; j++) for (let i = 0; i < G; i++) { const x = i - GH + 0.5, z = j - GH + 0.5; if (x > x0 && x < x1 && z > z0 && z < z1) slab[j * G + i] = 1; }
  }
  for (let py = 0; py < S; py++) for (let px = 0; px < S; px++) {
    const x = px * 0.5 - GH + 0.25, z = py * 0.5 - GH + 0.25;
    const c = cellOf(x, z);
    const d = c >= 0 ? Math.min(dist[c] + 0.5, 12) : 0;
    let v = n1(x * 0.16, z * 0.16) * 0.55 + n2(x * 0.6, z * 0.6) * 0.25 - 0.12;
    v += (1 - smooth01(d / 3.2)) * 0.5;
    if (c >= 0 && slab[c]) v += 0.38;
    if (c >= 0 && liftCell[c]) v -= 0.25;
    const o = (py * S + px) * 4;
    data[o] = clamp(v, 0, 1) * 255; data[o + 1] = data[o]; data[o + 2] = data[o]; data[o + 3] = 255;
  }
  if (snowTex) { snowTex.image.data.set(data); snowTex.needsUpdate = true; return snowTex; }
  const t = new THREE.DataTexture(data, S, S, THREE.RGBAFormat);
  t.magFilter = THREE.LinearFilter; t.minFilter = THREE.LinearFilter; t.generateMipmaps = false;
  t.needsUpdate = true;
  return t;
}

// ---------- geometry builder for slabs with world-space UVs ----------
class SlabBuilder {
  constructor() { this.p = []; this.n = []; this.u = []; }
  quad(a, b, c, d, nx, ny, nz, ua, ub, uc, ud) {
    for (const [v, uv] of [[a, ua], [b, ub], [c, uc], [a, ua], [c, uc], [d, ud]]) { this.p.push(v[0], v[1], v[2]); this.n.push(nx, ny, nz); this.u.push(uv[0], uv[1]); }
  }
  box(x0, z0, x1, z1, y0, y1) {
    const s = 0.5;
    this.quad([x0, y1, z1], [x1, y1, z1], [x1, y1, z0], [x0, y1, z0], 0, 1, 0, [x0 * s, z1 * s], [x1 * s, z1 * s], [x1 * s, z0 * s], [x0 * s, z0 * s]);
    this.quad([x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1], 0, 0, 1, [x0 * s, y0 * s], [x1 * s, y0 * s], [x1 * s, y1 * s], [x0 * s, y1 * s]);
    this.quad([x1, y0, z0], [x0, y0, z0], [x0, y1, z0], [x1, y1, z0], 0, 0, -1, [x1 * s, y0 * s], [x0 * s, y0 * s], [x0 * s, y1 * s], [x1 * s, y1 * s]);
    this.quad([x1, y0, z1], [x1, y0, z0], [x1, y1, z0], [x1, y1, z1], 1, 0, 0, [z1 * s, y0 * s], [z0 * s, y0 * s], [z0 * s, y1 * s], [z1 * s, y1 * s]);
    this.quad([x0, y0, z0], [x0, y0, z1], [x0, y1, z1], [x0, y1, z0], -1, 0, 0, [z0 * s, y0 * s], [z1 * s, y0 * s], [z1 * s, y1 * s], [z0 * s, y1 * s]);
  }
  // sloped deck between z = za (height ha) and z = zb (height hb), `th` thick, with sloped sides and underside
  slope(x0, x1, za, zb, ha, hb, th) {
    const s = 0.5, g = (hb - ha) / (zb - za), nl = Math.hypot(1, g);
    this.quad([x0, hb, zb], [x1, hb, zb], [x1, ha, za], [x0, ha, za], 0, 1 / nl, -g / nl, [x0 * s, zb * s], [x1 * s, zb * s], [x1 * s, za * s], [x0 * s, za * s]);
    this.quad([x0, ha - th, za], [x1, ha - th, za], [x1, hb - th, zb], [x0, hb - th, zb], 0, -1 / nl, g / nl, [x0 * s, za * s], [x1 * s, za * s], [x1 * s, zb * s], [x0 * s, zb * s]);
    this.quad([x1, ha - th, za], [x1, hb - th, zb], [x1, hb, zb], [x1, ha, za], 1, 0, 0, [za * s, (ha - th) * s], [zb * s, (hb - th) * s], [zb * s, hb * s], [za * s, ha * s]);
    this.quad([x0, hb - th, zb], [x0, ha - th, za], [x0, ha, za], [x0, hb, zb], -1, 0, 0, [zb * s, (hb - th) * s], [za * s, (ha - th) * s], [za * s, ha * s], [zb * s, hb * s]);
  }
  disc(cx, cz, r, y0, y1, seg) {
    const s = 0.5;
    for (let k = 0; k < seg; k++) {
      const a0 = k / seg * TAU, a1 = (k + 1) / seg * TAU;
      const x0 = cx + Math.cos(a0) * r, z0 = cz + Math.sin(a0) * r, x1 = cx + Math.cos(a1) * r, z1 = cz + Math.sin(a1) * r;
      for (const v of [[cx, cz], [x1, z1], [x0, z0]]) { this.p.push(v[0], y1, v[1]); this.n.push(0, 1, 0); this.u.push(v[0] * s, v[1] * s); }
      const mx = Math.cos((a0 + a1) / 2), mz = Math.sin((a0 + a1) / 2), L = r * TAU / seg;
      this.quad([x1, y0, z1], [x0, y0, z0], [x0, y1, z0], [x1, y1, z1], mx, 0, mz, [(k + 1) * L * s, y0 * s], [k * L * s, y0 * s], [k * L * s, y1 * s], [(k + 1) * L * s, y1 * s]);
    }
  }
  geometry() {
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(this.p, 3));
    g.setAttribute('normal', new THREE.Float32BufferAttribute(this.n, 3));
    g.setAttribute('uv', new THREE.Float32BufferAttribute(this.u, 2));
    g.computeBoundingSphere();
    return g;
  }
}
const STEP_D = 0.5;   // stair tread depth

// ---------- prop builder (merged into one draw call) ----------
const PROP_PARTS = [], LIFT_PARTS = [];
function pBox(list, w, h, d, x, y, z, color, glow = 0, ry = 0) {
  const g = new THREE.BoxGeometry(w, h, d); if (ry) g.rotateY(ry); g.translate(x, y, z); list.push(paint(g, color, glow));
}
// box of cross-section w x h stretched between two 3D points (sloped rails, girders)
function pBeam(list, x0, y0, z0, x1, y1, z1, w, h, color, glow = 0) {
  const dx = x1 - x0, dy = y1 - y0, dz = z1 - z0, hl = Math.hypot(dx, dz), L = Math.hypot(hl, dy);
  if (L < 1e-3) return;
  const g = new THREE.BoxGeometry(L, h, w);
  g.rotateZ(Math.atan2(dy, hl)); g.rotateY(-Math.atan2(dz, dx)); g.translate((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2);
  list.push(paint(g, color, glow));
}
function pCyl(list, rt, rb, h, seg, x, y, z, color, glow = 0, rx = 0, ry = 0, open = false) {
  const g = new THREE.CylinderGeometry(rt, rb, h, seg, 1, open); if (rx) g.rotateX(rx); if (ry) g.rotateY(ry); g.translate(x, y, z); list.push(paint(g, color, glow));
}
function pTorus(list, r, tube, x, y, z, color, glow) {
  const g = new THREE.TorusGeometry(r, tube, 4, 40); g.rotateX(Math.PI / 2); g.translate(x, y, z); list.push(paint(g, color, glow));
}
function pRock(list, r, sy, x, y, z, color, seed) {
  // indexed + welded so the normals are smooth: soft mounds instead of faceted paper lumps
  let g = new THREE.IcosahedronGeometry(r, 2); g.deleteAttribute('normal'); g.deleteAttribute('uv'); g = mergeVertices(g);
  const R = mulberry32(seed); const p = g.attributes.position;
  for (let i = 0; i < p.count; i++) { const k = 0.75 + R() * 0.4; p.setXYZ(i, p.getX(i) * k, p.getY(i) * k * sy, p.getZ(i) * k); }
  g.computeVertexNormals(); g.translate(x, y, z); list.push(paint(g, color, 0));
}

const COL = {
  rail: 0x5e6874, post: 0x48515b, support: 0x1a2027, girder: 0x262d35, crateA: 0x4a5340, crateB: 0x3b4855, crateC: 0x6e4a20,
  pillar: 0x353d46, teal: 0x29f2da, green: 0x3dff9a, amber: 0xffa21a, red: 0xff2a3a, snow: 0xd2dbe6, pipe: 0x5a4c3a, dark: 0x13181e, nosing: 0x8d99a6,
};
const GLOWQ = []; // floor glow quads: x, z, size, color
const HAZ_STRIPS = [];

function buildRailings() {
  // collect abyss edges per line, merge into runs
  const runs = [];
  const hRuns = new Map(), vRuns = new Map();
  for (let j = 1; j < G - 1; j++) for (let i = 1; i < G - 1; i++) {
    const c = j * G + i; if (walk[c] === 0 || liftCell[c]) continue;
    const x = i - GH, z = j - GH;
    if (walk[c - G] === 0) addSeg(hRuns, 'n' + j, i, z + 0.12, +1, c);
    if (walk[c + G] === 0) addSeg(hRuns, 's' + j, i, z + 1 - 0.12, -1, c);
    if (walk[c - 1] === 0) addSeg(vRuns, 'w' + i, j, x + 0.12, +1, c);
    if (walk[c + 1] === 0) addSeg(vRuns, 'e' + i, j, x + 1 - 0.12, -1, c);
  }
  function addSeg(map, key, t, line, inward, c) { let a = map.get(key); if (!a) { a = []; map.set(key, a); } a.push([t, line, inward, hazCell[c]]); }
  for (const [map, horiz] of [[hRuns, true], [vRuns, false]]) {
    for (const segs of map.values()) {
      segs.sort((a, b) => a[0] - b[0]);
      let s0 = segs[0][0], prev = s0;
      for (let k = 1; k <= segs.length; k++) {
        if (k < segs.length && segs[k][0] === prev + 1) { prev = segs[k][0]; continue; }
        runs.push({ horiz, a: s0 - GH, b: prev + 1 - GH, line: segs[k - 1][1], inward: segs[k - 1][2], haz: segs[k - 1][3] });
        if (k < segs.length) { s0 = segs[k][0]; prev = s0; }
      }
    }
  }
  let lampN = 0;
  for (const r of runs) {
    const len = r.b - r.a;
    const P = (t, off = 0) => r.horiz ? [r.a + t, r.line + off * r.inward] : [r.line + off * r.inward, r.a + t];
    // ground height along the run (sampled just inside the floor), split into straight pieces where the slope changes
    const H = (t) => { const [x, z] = P(clamp(t, 0.02, len - 0.02), 0.3); return groundY(x, z); };
    const knots = [0];
    for (let t = 1; t < len; t++) { const s0 = H(t) - H(t - 1), s1 = H(t + 1) - H(t); if (Math.abs(s0 - s1) > 1e-3) knots.push(t); }
    knots.push(len);
    for (let k = 0; k + 1 < knots.length; k++) {
      const ta = knots[k], tb = knots[k + 1], ya = H(ta), yb = H(tb);
      const [xa, za] = P(ta), [xb, zb] = P(tb);
      for (const ry of [0.55, 1.05]) pBeam(PROP_PARTS, xa, ya + ry, za, xb, yb + ry, zb, 0.07, 0.07, COL.rail);
      // girder under the edge
      const [ga, gza] = P(ta, 0.25), [gb, gzb] = P(tb, 0.25);
      pBeam(PROP_PARTS, ga, ya - 0.85, gza, gb, yb - 0.85, gzb, 0.35, 0.7, COL.girder);
    }
    const nPosts = Math.max(1, Math.round(len / 2));
    for (let k = 0; k <= nPosts; k++) { const t = k * len / nPosts, [x, z] = P(t); pBox(PROP_PARTS, 0.1, 1.1, 0.1, x, H(t) + 0.55, z, COL.post); }
    // hazard strip inside the edge (hazard platforms are flat)
    if (r.haz) { const [x, z] = P(len / 2, 0.42); HAZ_STRIPS.push([x, z, r.horiz ? len : 0.42, r.horiz ? 0.42 : len, r.horiz]); }
    // lamps every ~12 m along long runs
    if (len >= 6) {
      for (let t = 3; t < len - 1; t += 12) {
        const [x, z] = P(t), y = H(t);
        const ix = r.horiz ? 0 : r.inward, iz = r.horiz ? r.inward : 0;
        pBox(PROP_PARTS, 0.14, 3.2, 0.14, x, y + 1.6, z, COL.post);
        pBox(PROP_PARTS, r.horiz ? 0.12 : 0.9, 0.1, r.horiz ? 0.9 : 0.12, x + ix * 0.4, y + 3.15, z + iz * 0.4, COL.post);
        const lc = (lampN++ % 3 === 2) ? COL.green : COL.teal;
        pBox(PROP_PARTS, 0.32, 0.12, 0.32, x + ix * 0.8, y + 3.05, z + iz * 0.8, lc, 1.2);
        // a local pool on the deck, kept inside the railing so it never paints the void
        GLOWQ.push([x + ix * 1.5, z + iz * 1.5, 3.0, lc]);
      }
    }
  }
}

function buildSupports() {
  const R = mulberry32(31);
  for (const [x0, z0, x1, z1, , , hs] of RECTS) {
    const w = x1 - x0, d = z1 - z0;
    const cols = [];
    const nx = Math.max(1, Math.round(w / 9)), nz = Math.max(1, Math.round(d / 9));
    for (let a = 0; a <= nx; a++) for (let b = 0; b <= nz; b++) {
      if (a !== 0 && a !== nx && b !== 0 && b !== nz) continue;
      cols.push([x0 + 1 + (w - 2) * a / nx, z0 + 1 + (d - 2) * b / nz]);
    }
    for (const [x, z] of cols) {
      const top = rectMinH(typeof hs === 'number' ? hs : rectH(hs, z)) - 0.5;
      const h = 46 + R() * 10;
      pBox(PROP_PARTS, 0.7, h, 0.7, x, top - h / 2, z, COL.support);
      pBox(PROP_PARTS, 0.9, 0.5, 0.9, x, top - 0.9, z, COL.girder);
      if (R() < 0.35) pBox(PROP_PARTS, 0.2, 0.5, 0.2, x + 0.46, top - 3.5 - R() * 6, z, COL.red, 1.5);
    }
    // cross bracing under big platforms
    if (w > 10 && d > 10) {
      const y = rectMinH(hs) - 6;
      pBox(PROP_PARTS, w - 2, 0.4, 0.4, (x0 + x1) / 2, y, z0 + 1, COL.girder);
      pBox(PROP_PARTS, w - 2, 0.4, 0.4, (x0 + x1) / 2, y, z1 - 1, COL.girder);
    }
  }
  // lift shaft
  const L = LV.lift;
  pCyl(PROP_PARTS, L.r + 0.6, L.r + 0.6, 3, 40, L.x, LIFT_Y - 2.0, L.z, COL.girder, 0, 0, 0, true);
  for (let k = 0; k < 8; k++) { const a = k / 8 * TAU; pBox(PROP_PARTS, 0.8, 50, 0.8, L.x + Math.cos(a) * (L.r + 0.9), LIFT_Y - 26, L.z + Math.sin(a) * (L.r + 0.9), COL.support); }
  for (let k = 0; k < 16; k++) { const a = k / 16 * TAU; pBox(PROP_PARTS, 0.25, 0.25, 0.25, L.x + Math.cos(a) * (L.r + 1.0), LIFT_Y - 3.6, L.z + Math.sin(a) * (L.r + 1.0), COL.teal, 1.5); }
  // distant towers fading into the fog
  for (let k = 0; k < 14; k++) {
    const a = k / 14 * TAU + R() * 0.3, d = 74 + R() * 26, x = Math.cos(a) * d, z = -5 + Math.sin(a) * d;
    const top = -8 + R() * 30, w = 5 + R() * 9, h = top + 90;
    pBox(PROP_PARTS, w, h, w * (0.6 + R() * 0.6), x, top - h / 2, z, 0x10151b, 0, R() * 3);
    for (let m = 0; m < 3; m++) pBox(PROP_PARTS, 0.5, 0.5, 0.5, x + (R() - 0.5) * w, top - R() * 20, z + (R() - 0.5) * w, R() < 0.5 ? COL.red : COL.teal, 2);
  }
}

function buildProps() {
  const R = mulberry32(57);
  for (const [x0, z0, w, d, h] of CRATES) {
    const cx = x0 + w / 2, cz = z0 + d / 2, y = groundY(cx, cz), col = [COL.crateA, COL.crateB, COL.crateC][(R() * 3) | 0];
    pBox(PROP_PARTS, w - 0.08, h, d - 0.08, cx, y + h / 2, cz, col, 0, (R() - 0.5) * 0.08);
    pBox(PROP_PARTS, w + 0.02, 0.08, d + 0.02, cx, y + h * 0.72, cz, COL.dark);
    pBox(PROP_PARTS, Math.min(0.5, w * 0.3), 0.06, 0.04, cx, y + h * 0.45, cz + d / 2 - 0.02, COL.amber, 0.6);
    if (R() < 0.6) pRock(PROP_PARTS, 0.45, 0.35, cx + (R() - 0.5) * w, y + 0.05, cz + d / 2 + 0.25, COL.snow, (R() * 1e6) | 0);
  }
  for (const [x, z] of PILLARS) {
    const y = groundY(x, z);
    pBox(PROP_PARTS, 0.8, 3.6, 0.8, x, y + 1.8, z, COL.pillar);
    pBox(PROP_PARTS, 0.95, 0.3, 0.95, x, y + 0.15, z, COL.girder);
    pBox(PROP_PARTS, 0.95, 0.12, 0.95, x, y + 3.6, z, COL.girder);
    for (const [ox, oz] of [[0.41, 0], [-0.41, 0], [0, 0.41], [0, -0.41]]) {
      pBox(PROP_PARTS, ox ? 0.04 : 0.18, 1.1, oz ? 0.04 : 0.18, x + ox, y + 2.2, z + oz, COL.teal, 1.6);
    }
    GLOWQ.push([x, z, 3.2, COL.teal]);
  }
  // pipe bundles hanging off a few platform sides (x0, z0, x1, z1, platform height)
  for (const [x0, z0, x1, z1, h] of PIPES) {
    const len = Math.hypot(x1 - x0, z1 - z0), ang = Math.atan2(z1 - z0, x1 - x0);
    for (const [dy, r, col] of [[-0.25, 0.17, COL.pipe], [-0.62, 0.12, COL.girder]]) {
      const g = new THREE.CylinderGeometry(r, r, len, 8);
      g.rotateZ(Math.PI / 2); g.rotateY(-ang); g.translate((x0 + x1) / 2, h + dy, (z0 + z1) / 2);
      PROP_PARTS.push(paint(g, col));
    }
  }
  // snow drifts against railings
  for (let k = 0; k < 90; k++) {
    const e = (R() * LV.edgeN) | 0;
    const x = LV.edgeX[e] - LV.edgeNX[e] * 0.1, z = LV.edgeZ[e] - LV.edgeNZ[e] * 0.1;
    if (liftCell[cellOf(x, z)]) continue;
    pRock(PROP_PARTS, (0.5 + R() * 0.5) * 1.3, 0.16, x, groundY(x, z) - 0.05, z, 0xb4c1cf, k * 13 + 1);
  }
  // steam / burrow vents
  for (const [x, z] of LV.vents) {
    const y = groundY(x, z);
    pBox(PROP_PARTS, 1.5, 0.12, 1.5, x, y + 0.06, z, COL.dark);
    for (let k = -2; k <= 2; k++) pBox(PROP_PARTS, 1.2, 0.04, 0.1, x, y + 0.13, z + k * 0.26, 0xff5a1a, 0.9);
    GLOWQ.push([x, z, 2.6, 0xff5a1a]);
  }
  // beacon bases
  for (const b of LV.beacons) {
    const y = groundY(b.x, b.z);
    pCyl(PROP_PARTS, 1.3, 1.5, 0.45, 10, b.x, y + 0.22, b.z, COL.girder);
    pBox(PROP_PARTS, 0.7, 2.3, 0.7, b.x, y + 1.4, b.z, COL.pillar);
    for (let k = 0; k < 4; k++) { const a = k / 4 * TAU + Math.PI / 4; pBox(PROP_PARTS, 0.18, 1.6, 0.7, b.x + Math.cos(a) * 0.55, y + 1.0, b.z + Math.sin(a) * 0.55, COL.post, 0, -a); }
    pBox(PROP_PARTS, 0.74, 0.12, 0.74, b.x, y + 2.0, b.z, COL.amber, 1.0);
    for (const [ox, oz] of [[-0.5, -0.5], [0.5, -0.5], [-0.5, 0.5], [0.5, 0.5]]) walk[cellOf(b.x + ox, b.z + oz)] = 2;
  }
  // landing pad edge lights
  { const [px0, pz0, px1, pz1] = PAD, ny = Math.round((px1 - px0) / 2), py = groundY((px0 + px1) / 2, (pz0 + pz1) / 2);
    for (let k = 0; k < ny; k++) for (const [x, z] of [[px0 + 0.6 + k * 2, pz0 + 0.6], [px0 + 0.6 + k * 2, pz1 - 0.6], [px0 + 0.6, pz0 + 0.6 + k * 2], [px1 - 0.6, pz0 + 0.6 + k * 2]]) pBox(PROP_PARTS, 0.18, 0.08, 0.18, x, py + 0.04, z, COL.amber, 1.6); }
  // stair nosings: pale edge on every tread, amber warning stripe on the first and last step
  for (const [x0, , x1, , , , hs] of RECTS) {
    if (typeof hs === 'number' || !hs.stairs) continue;
    const n = Math.round((hs.b - hs.a) / STEP_D);
    for (let k = 0; k < n; k++) {
      const top = hs.ha + (hs.hb - hs.ha) * (k + 0.5) / n, z = hs.a + k * STEP_D + 0.05;
      const edge = k === 0 || k === n - 1;
      pBox(PROP_PARTS, x1 - x0 - 0.3, 0.03, 0.12, (x0 + x1) / 2, top + 0.014, z + 0.01, edge ? COL.amber : COL.nosing, edge ? 0.35 : 0.12);
      // contact shadow where the tread below meets the riser (risers face away from the camera)
      if (k > 0) pBox(PROP_PARTS, x1 - x0 - 0.3, 0.02, 0.16, (x0 + x1) / 2, top - (hs.hb - hs.ha) / n + 0.01, z - 0.13, COL.dark, 1);
    }
  }
}

function buildLift() {
  const L = LV.lift, Y = LIFT_Y;
  // ring railing
  for (let k = 0; k < 36; k++) {
    const a0 = k / 36 * TAU, a1 = (k + 1) / 36 * TAU, r = L.r - 0.15;
    const x0 = L.x + Math.cos(a0) * r, z0 = L.z + Math.sin(a0) * r, x1 = L.x + Math.cos(a1) * r, z1 = L.z + Math.sin(a1) * r;
    const mid = (a0 + a1) / 2;
    if (Math.abs(angDiff(mid, Math.PI / 2)) < 0.33) continue; // opening toward the stairs (+z side)
    const len = Math.hypot(x1 - x0, z1 - z0), ang = Math.atan2(z1 - z0, x1 - x0);
    for (const y of [0.55, 1.05]) pBox(LIFT_PARTS, len, 0.07, 0.07, (x0 + x1) / 2, Y + y, (z0 + z1) / 2, COL.rail, 0, -ang);
    pBox(LIFT_PARTS, 0.1, 1.1, 0.1, x0, Y + 0.55, z0, COL.post);
  }
  // four pads with teal rings
  for (let k = 0; k < 4; k++) {
    const a = Math.PI / 4 + k * Math.PI / 2, x = L.x + Math.cos(a) * 5.2, z = L.z + Math.sin(a) * 5.2;
    pCyl(LIFT_PARTS, 1.7, 1.8, 0.1, 24, x, Y + 0.08, z, COL.girder);
    pCyl(LIFT_PARTS, 1.15, 1.15, 0.11, 24, x, Y + 0.09, z, 0x1a3b44);
    pTorus(LIFT_PARTS, 1.45, 0.05, x, Y + 0.15, z, COL.teal, 1.5);
    for (let m = 0; m < 6; m++) { const b = m / 6 * TAU; pBox(LIFT_PARTS, 0.14, 0.06, 0.14, x + Math.cos(b) * 1.62, Y + 0.15, z + Math.sin(b) * 1.62, COL.green, 2); }
  }
  pCyl(LIFT_PARTS, 0.9, 1.1, 0.5, 16, L.x, Y + 0.25, L.z, COL.pillar);
  pTorus(LIFT_PARTS, 1.0, 0.05, L.x, Y + 0.5, L.z, COL.teal, 1.6);
  // light studs around the rim
  for (let k = 0; k < 24; k++) { const a = k / 24 * TAU; pBox(LIFT_PARTS, 0.16, 0.06, 0.16, L.x + Math.cos(a) * (L.r - 0.6), Y + 0.06, L.z + Math.sin(a) * (L.r - 0.6), COL.teal, 1.8); }
}

// ---------- assemble (rebuildable: a new seed swaps geometry only, never materials or shader programs) ----------
const MAT = {
  grating: makeFloorMaterial(TEX.grating, 1.6, 0.0),
  slab: makeFloorMaterial(TEX.slab, 0.6, 0.18),
  props: makeGlowMaterial({ snow: true }),
  bug: makeBugMaterial(),
};
const level = new THREE.Group();
scene.add(level);
const liftGroup = new THREE.Group();   // the group offset is the extraction rise
scene.add(liftGroup);
const liftDeck = new THREE.Group();
liftGroup.add(liftDeck);
const HZ_MAT = new THREE.MeshStandardMaterial({ map: TEX.hazard, roughness: 0.8, metalness: 0.1, polygonOffset: true, polygonOffsetFactor: -1, polygonOffsetUnits: -1 });
const PAD_MAT = new THREE.MeshStandardMaterial({ map: TEX.pad, transparent: true, depthWrite: false, roughness: 0.85, polygonOffset: true, polygonOffsetFactor: -2, polygonOffsetUnits: -2 });
const GLOW_MAT = new THREE.MeshBasicMaterial({ map: TEX.glow, vertexColors: true, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, fog: false });
function clearGroup(g) { for (const o of g.children.slice()) { g.remove(o); if (o.geometry) o.geometry.dispose(); } }
function buildLevel() {
  PROP_PARTS.length = 0; LIFT_PARTS.length = 0; GLOWQ.length = 0; HAZ_STRIPS.length = 0;
  rasterLevel();
  snowTex = buildSnowMask();
  buildRailings();
  buildSupports();
  buildProps();
  buildLift();
  clearGroup(level); clearGroup(liftDeck);
  const bg = new SlabBuilder(), bs = new SlabBuilder();
  for (const [x0, z0, x1, z1, k, , hs] of RECTS) {
    const sb = k === 's' ? bs : bg;
    if (typeof hs === 'number') { sb.box(x0, z0, x1, z1, hs - 0.5, hs); continue; }
    if (hs.a > z0) sb.box(x0, z0, x1, hs.a, hs.ha - 0.5, hs.ha);
    if (hs.b < z1) sb.box(x0, hs.b, x1, z1, hs.hb - 0.5, hs.hb);
    if (hs.stairs) {
      const n = Math.round((hs.b - hs.a) / STEP_D), bot = Math.min(hs.ha, hs.hb) - 0.5;
      for (let s = 0; s < n; s++) sb.box(x0, hs.a + s * STEP_D, x1, hs.a + (s + 1) * STEP_D, bot, hs.ha + (hs.hb - hs.ha) * (s + 0.5) / n);
    } else sb.slope(x0, x1, hs.a, hs.b, hs.ha, hs.hb, 0.5);
  }
  const mg = new THREE.Mesh(bg.geometry(), MAT.grating), ms = new THREE.Mesh(bs.geometry(), MAT.slab);
  mg.receiveShadow = ms.receiveShadow = true;
  level.add(mg, ms);
  const props = new THREE.Mesh(mergeGeometries(PROP_PARTS), MAT.props);
  props.receiveShadow = true;
  level.add(props);
  PROP_PARTS.length = 0;
  const hb = new SlabBuilder();
  for (const [x, z, w, d, horiz] of HAZ_STRIPS) {
    const x0 = x - w / 2, x1 = x + w / 2, z0 = z - d / 2, z1 = z + d / 2, y = groundY(x, z) + 0.012;
    if (horiz) hb.quad([x0, y, z1], [x1, y, z1], [x1, y, z0], [x0, y, z0], 0, 1, 0, [x0 / 1.6, 1], [x1 / 1.6, 1], [x1 / 1.6, 0], [x0 / 1.6, 0]);
    else hb.quad([x0, y, z1], [x1, y, z1], [x1, y, z0], [x0, y, z0], 0, 1, 0, [z1 / 1.6, 0], [z1 / 1.6, 1], [z0 / 1.6, 1], [z0 / 1.6, 0]);
  }
  const hz = new THREE.Mesh(hb.geometry(), HZ_MAT);
  hz.receiveShadow = true;
  level.add(hz);
  const pad = new THREE.Mesh(new THREE.PlaneGeometry(11, 11).rotateX(-Math.PI / 2), PAD_MAT);
  pad.position.set(LV.start.x, groundY(LV.start.x, LV.start.z) + 0.01, LV.start.z);
  level.add(pad);
  const gp = [], gc = [], gu = [];
  for (const [x, z, s, col] of GLOWQ) {
    _col.set(col); const h = s / 2, y = groundY(x, z) + 0.03;
    const v = [[x - h, z + h, 0, 0], [x + h, z + h, 1, 0], [x + h, z - h, 1, 1], [x - h, z + h, 0, 0], [x + h, z - h, 1, 1], [x - h, z - h, 0, 1]];
    for (const [vx, vz, u, w] of v) { gp.push(vx, y, vz); gc.push(_col.r * 0.3, _col.g * 0.3, _col.b * 0.3); gu.push(u, w); }
  }
  const gg = new THREE.BufferGeometry();
  gg.setAttribute('position', new THREE.Float32BufferAttribute(gp, 3));
  gg.setAttribute('color', new THREE.Float32BufferAttribute(gc, 3));
  gg.setAttribute('uv', new THREE.Float32BufferAttribute(gu, 2));
  level.add(new THREE.Mesh(gg, GLOW_MAT));
  const L = LV.lift, lb = new SlabBuilder();
  lb.disc(L.x, L.z, L.r, LIFT_Y - 0.6, LIFT_Y + 0.03, 48);
  const lf = new THREE.Mesh(lb.geometry(), MAT.grating);
  lf.receiveShadow = true;
  const lp = new THREE.Mesh(mergeGeometries(LIFT_PARTS), MAT.props);
  LIFT_PARTS.length = 0;
  liftDeck.add(lf, lp);
}
// seed 0 = the hand-made «Кельвин-9»; any other seed = a generated station (falls back to the hand-made one when
// 40 tries fail validation). Never called mid-mission (04b-stations.js guards that). Returns the cost in ms.
function rebuildLevel(seed) {
  const t0 = performance.now();
  const L = seed ? genLevel(seed) : null;
  loadLevelData(L || HAND_LEVEL);
  levelSeed = L ? seed : 0;
  buildLevel();
  placeObjectiveFx();
  objFlowKey = '';
  updateFlows();
  return performance.now() - t0;
}
buildLevel();
// icy haze far below the decks: the abyss reads as a cold blue-grey chasm, piers fade into it (one draw)
{
  const c = mkCanvas(256, 256), g = c.getContext('2d');
  const rg = g.createRadialGradient(128, 128, 0, 128, 128, 128);
  rg.addColorStop(0, 'rgba(120,150,185,0.55)'); rg.addColorStop(0.5, 'rgba(80,105,135,0.35)'); rg.addColorStop(1, 'rgba(40,55,75,0)');
  g.fillStyle = rg; g.fillRect(0, 0, 256, 256);
  const haze = new THREE.Mesh(new THREE.PlaneGeometry(220, 220).rotateX(-Math.PI / 2),
    new THREE.MeshBasicMaterial({ map: canvasTex(c, { aniso: 1 }), transparent: true, depthWrite: false, fog: false }));
  haze.position.set(0, -16, -5); haze.renderOrder = -1;
  scene.add(haze);
}
