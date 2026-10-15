// ================================================================
//  LEVEL — «Станция Кельвин-9»: grated platforms over an abyss
//  Three height tiers: landing pad / hub / beacon A at 0 m, plaza and
//  beacons B, C at −3 m, the cargo lift at −6 m. Real staircases and
//  sloped catwalks connect them (the simulation stays 2D; every visual
//  y comes from groundY()).
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

const LIFT_Y = -6;
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

// ---------- walk grid + height field ----------
function rasterLevel() {
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
  for (const [x0, z0, x1, z1, h] of [[-8, 38.3, 6, 38.3, 0], [-12, -12.3, -6, -12.3, -3], [22, -16.3, 38, -16.3, -3], [-42, -18.3, -26, -18.3, -3], [38.3, 22, 38.3, 38, 0]]) {
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
  for (let k = 0; k < 8; k++) {
    for (const [x, z] of [[22.6 + k * 2, 22.6], [22.6 + k * 2, 37.4], [22.6, 22.6 + k * 2], [37.4, 22.6 + k * 2]]) pBox(PROP_PARTS, 0.18, 0.08, 0.18, x, 0.04, z, COL.amber, 1.6);
  }
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

// ---------- assemble ----------
rasterLevel();
snowTex = buildSnowMask();
const MAT = {
  grating: makeFloorMaterial(TEX.grating, 1.6, 0.0),
  slab: makeFloorMaterial(TEX.slab, 0.6, 0.18),
  props: makeGlowMaterial({ snow: true }),
  bug: makeBugMaterial(),
};
buildRailings();
buildSupports();
buildProps();
buildLift();

const level = new THREE.Group();
scene.add(level);
{
  const bg = new SlabBuilder(), bs = new SlabBuilder();
  for (const [x0, z0, x1, z1, k, , hs] of RECTS) {
    const sb = k === 's' ? bs : bg;
    if (typeof hs === 'number') { sb.box(x0, z0, x1, z1, hs - 0.5, hs); continue; }
    // flat landings at both ends + stairs or a sloped deck between
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
  // hazard strips (one merged mesh)
  const hb = new SlabBuilder();
  for (const [x, z, w, d, horiz] of HAZ_STRIPS) {
    const x0 = x - w / 2, x1 = x + w / 2, z0 = z - d / 2, z1 = z + d / 2, y = groundY(x, z) + 0.012;
    if (horiz) hb.quad([x0, y, z1], [x1, y, z1], [x1, y, z0], [x0, y, z0], 0, 1, 0, [x0 / 1.6, 1], [x1 / 1.6, 1], [x1 / 1.6, 0], [x0 / 1.6, 0]);
    else hb.quad([x0, y, z1], [x1, y, z1], [x1, y, z0], [x0, y, z0], 0, 1, 0, [z1 / 1.6, 0], [z1 / 1.6, 1], [z0 / 1.6, 1], [z0 / 1.6, 0]);
  }
  const hz = new THREE.Mesh(hb.geometry(), new THREE.MeshStandardMaterial({ map: TEX.hazard, roughness: 0.8, metalness: 0.1, polygonOffset: true, polygonOffsetFactor: -1, polygonOffsetUnits: -1 }));
  hz.receiveShadow = true;
  level.add(hz);
  // landing pad marking
  const pad = new THREE.Mesh(new THREE.PlaneGeometry(11, 11).rotateX(-Math.PI / 2), new THREE.MeshStandardMaterial({ map: TEX.pad, transparent: true, depthWrite: false, roughness: 0.85, polygonOffset: true, polygonOffsetFactor: -2, polygonOffsetUnits: -2 }));
  pad.position.set(LV.start.x, groundY(LV.start.x, LV.start.z) + 0.01, LV.start.z);
  level.add(pad);
  // floor glows under lamps (additive, one mesh)
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
  level.add(new THREE.Mesh(gg, new THREE.MeshBasicMaterial({ map: TEX.glow, vertexColors: true, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, fog: false })));
}
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
// lift group (geometry sits at LIFT_Y; the group offset is the extraction rise)
const liftGroup = new THREE.Group();
scene.add(liftGroup);
{
  const L = LV.lift, lb = new SlabBuilder();
  lb.disc(L.x, L.z, L.r, LIFT_Y - 0.6, LIFT_Y + 0.03, 48);
  const lf = new THREE.Mesh(lb.geometry(), MAT.grating);
  lf.receiveShadow = true;
  const lp = new THREE.Mesh(mergeGeometries(LIFT_PARTS), MAT.props);
  LIFT_PARTS.length = 0;
  liftGroup.add(lf, lp);
}
