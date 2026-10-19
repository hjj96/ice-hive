// ================================================================
//  SIM — bug swarm as struct-of-arrays + uniform grid hash + flow field
// ================================================================
const B = {
  n: 0,
  x: new Float32Array(MAXB), z: new Float32Array(MAXB), vx: new Float32Array(MAXB), vz: new Float32Array(MAXB),
  y: new Float32Array(MAXB), hp: new Float32Array(MAXB), hpMax: new Float32Array(MAXB), r: new Float32Array(MAXB),
  spd: new Float32Array(MAXB), sc: new Float32Array(MAXB), t: new Float32Array(MAXB), cd: new Float32Array(MAXB),
  chill: new Float32Array(MAXB), frz: new Float32Array(MAXB), burn: new Float32Array(MAXB), ph: new Float32Array(MAXB),
  hd: new Float32Array(MAXB), fl: new Float32Array(MAXB), ax: new Float32Array(MAXB), az: new Float32Array(MAXB),
  vr: new Float32Array(MAXB),
  type: new Uint8Array(MAXB), st: new Uint8Array(MAXB), dead: new Uint8Array(MAXB), hit: new Uint8Array(MAXB),
  bsrc: new Int8Array(MAXB), uid: new Int32Array(MAXB),
};
const B_ARRAYS = Object.keys(B).filter(k => k !== 'n').map(k => B[k]);
const BMASS = BT.map(t => t.mass);
let uidSeq = 1, deadPending = 0;

// ---------- uniform grid spatial hash (1 m cells, counting sort) ----------
const hStart = new Int32Array(G * G + 1), hCursor = new Int32Array(G * G);
const hItems = new Int32Array(MAXB), hCell = new Int32Array(MAXB);
let hashN = 0;
const QB = new Int32Array(MAXB);   // shared query result buffer (queries never nest)
function cellClamp(x, z) {
  let i = Math.floor(x + GH), j = Math.floor(z + GH);
  i = i < 0 ? 0 : i >= G ? G - 1 : i; j = j < 0 ? 0 : j >= G ? G - 1 : j;
  return j * G + i;
}
function rebuildHash() {
  hStart.fill(0);
  const n = B.n;
  for (let i = 0; i < n; i++) { const c = cellClamp(B.x[i], B.z[i]); hCell[i] = c; hStart[c + 1]++; }
  for (let c = 1; c <= G * G; c++) hStart[c] += hStart[c - 1];
  hCursor.set(hStart.subarray(0, G * G));
  for (let i = 0; i < n; i++) hItems[hCursor[hCell[i]]++] = i;
  hashN = n;
}
// All live bugs whose body overlaps the circle -> QB[0..count)
function queryCircle(x, z, r) {
  let cnt = 0;
  const i0 = Math.max(0, Math.floor(x - r - 1 + GH)), i1 = Math.min(G - 1, Math.floor(x + r + 1 + GH));
  const j0 = Math.max(0, Math.floor(z - r - 1 + GH)), j1 = Math.min(G - 1, Math.floor(z + r + 1 + GH));
  for (let j = j0; j <= j1; j++) {
    for (let i = i0; i <= i1; i++) {
      const c = j * G + i, e = hStart[c + 1];
      for (let k = hStart[c]; k < e; k++) {
        const b = hItems[k];
        if (B.dead[b]) continue;
        const dx = B.x[b] - x, dz = B.z[b] - z, rr = r + B.r[b];
        if (dx * dx + dz * dz < rr * rr) QB[cnt++] = b;
      }
    }
  }
  return cnt;
}
// First bug hit by a ray (DDA over cells). Returns distance (or maxD) and sets rayHit index.
let rayHit = -1;
function raycastBugs(ox, oz, dx, dz, maxD) {
  rayHit = -1;
  let best = maxD;
  const step = 0.9;
  let lastC = -1;
  for (let s = 0; s <= maxD + 1; s += step) {
    if (s > best + 1.2) break;
    const px = ox + dx * s, pz = oz + dz * s;
    const ci = Math.floor(px + GH), cj = Math.floor(pz + GH);
    for (let dj = -1; dj <= 1; dj++) for (let di = -1; di <= 1; di++) {
      const i = ci + di, j = cj + dj;
      if (i < 0 || j < 0 || i >= G || j >= G) continue;
      const c = j * G + i;
      if (c === lastC) continue;
      const e = hStart[c + 1];
      for (let k = hStart[c]; k < e; k++) {
        const b = hItems[k];
        if (B.dead[b] || B.st[b] === S_CLIMB) continue;
        const bx = B.x[b] - ox, bz = B.z[b] - oz;
        const t = bx * dx + bz * dz;
        if (t < 0 || t > best) continue;
        const px2 = bx - dx * t, pz2 = bz - dz * t, r = B.r[b];
        const d2 = px2 * px2 + pz2 * pz2;
        if (d2 < r * r) { const tt = t - Math.sqrt(r * r - d2); if (tt < best) { best = Math.max(0, tt); rayHit = b; } }
      }
    }
    lastC = cj * G + ci;
  }
  return best;
}

// ---------- flow fields: multi-source BFS over the walk grid ----------
const fq = new Int32Array(G * G);
const N8 = [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [1, -1], [-1, 1], [-1, -1]];
class FlowField {
  constructor() { this.d = new Uint16Array(G * G); this.x = new Float32Array(G * G); this.z = new Float32Array(G * G); }
  // sources: flat [x0, z0, x1, z1, ...]
  compute(src) {
    const D = this.d, FX = this.x, FZ = this.z;
    D.fill(65535); FX.fill(0); FZ.fill(0);
    let qh = 0, qt = 0;
    for (let k = 0; k < src.length; k += 2) {
      const c = cellOf(src[k], src[k + 1]);
      if (c >= 0 && D[c] !== 0) { D[c] = 0; fq[qt++] = c; }
    }
    while (qh < qt) {
      const c = fq[qh++], d = D[c] + 1, i = c % G;
      if (i > 0 && walk[c - 1] === 1 && D[c - 1] > d) { D[c - 1] = d; fq[qt++] = c - 1; }
      if (i < G - 1 && walk[c + 1] === 1 && D[c + 1] > d) { D[c + 1] = d; fq[qt++] = c + 1; }
      if (c >= G && walk[c - G] === 1 && D[c - G] > d) { D[c - G] = d; fq[qt++] = c - G; }
      if (c < G * (G - 1) && walk[c + G] === 1 && D[c + G] > d) { D[c + G] = d; fq[qt++] = c + G; }
    }
    // direction = weighted sum toward lower-distance neighbours (8-way, no corner cutting)
    for (let q = 0; q < qt; q++) {
      const c = fq[q], d0 = D[c], i = c % G, j = (c / G) | 0;
      if (d0 === 0) continue;
      let vx = 0, vz = 0;
      for (let k = 0; k < 8; k++) {
        const dx = N8[k][0], dz = N8[k][1], ni = i + dx, nj = j + dz;
        if (ni < 0 || nj < 0 || ni >= G || nj >= G) continue;
        const n = nj * G + ni;
        if (walk[n] !== 1) continue;
        if (dx && dz && (walk[j * G + ni] !== 1 || walk[nj * G + i] !== 1)) continue;
        const dd = d0 - D[n];
        if (dd > 0) { const w = (dx && dz) ? dd * 0.7071 : dd; vx += dx * w; vz += dz * w; }
      }
      // never point diagonally into a blocked corner cell (crates, beacon bases): keep the dominant axis
      if (vx !== 0 && vz !== 0 && walk[(j + (vz > 0 ? 1 : -1)) * G + (i + (vx > 0 ? 1 : -1))] !== 1) {
        if (Math.abs(vx) >= Math.abs(vz)) vz = 0; else vx = 0;
      }
      const l = Math.hypot(vx, vz);
      if (l > 0) { FX[c] = vx / l; FZ[c] = vz / l; }
    }
  }
}
const swarmFlow = new FlowField();   // toward the nearest standing marine (bugs)
const squadFlow = new FlowField();   // toward the player (bots regrouping)
const objFlow = new FlowField();     // toward the current objective (autopilot)
const reviveFlow = new FlowField();  // toward downed marines (rescuers)
const flowX = swarmFlow.x, flowZ = swarmFlow.z;
let flowTimer = 0, objFlowKey = '';
const _src = [];
function updateFlows() {
  _src.length = 0;
  let anyUp = false;
  for (const m of M) if (!m.downed) anyUp = true;
  for (const m of M) if (!anyUp || !m.downed) _src.push(m.x, m.z);
  swarmFlow.compute(_src);
  _src.length = 0; _src.push(M[0].x, M[0].z);
  squadFlow.compute(_src);
  _src.length = 0;
  for (const m of M) if (m.downed) _src.push(m.x, m.z);
  if (_src.length) reviveFlow.compute(_src);
  const [ox, oz] = objectivePoint();
  const key = Math.round(ox) + ',' + Math.round(oz);
  if (key !== objFlowKey) { objFlowKey = key; _src.length = 0; _src.push(ox, oz); objFlow.compute(_src); }
}

// ---------- spawning / removal ----------
// mode 0: on the floor, 1: climbing up the platform side from the abyss and over the railing (nx,nz = outward
// normal, depth = how far below the deck it starts), 2: bursting from a vent
function spawnBug(type, x, z, mode = 0, nx = 0, nz = 0, depth = 1.8) {
  if (B.n >= MAXB) return -1;
  const i = B.n++, T = BT[type];
  if (type !== RUN && !GS.seen[type] && !GS.attract && !simOnly) { GS.seen[type] = true; toast(T.name + ': ' + BUG_TIPS[type], 'warn'); }
  const k = 0.88 + rnd() * 0.24;
  B.type[i] = type; B.dead[i] = 0; B.hit[i] = 0; B.bsrc[i] = -1; B.uid[i] = uidSeq++;
  B.r[i] = T.radius * k; B.sc[i] = T.scale * k; B.spd[i] = T.speed * (0.85 + rnd() * 0.3);
  B.hp[i] = B.hpMax[i] = T.hp * DIR.hpMul * (type === BRUTE ? 1 : k);
  B.vx[i] = B.vz[i] = 0; B.cd[i] = rnd() * T.atkCd; B.chill[i] = B.frz[i] = B.burn[i] = B.fl[i] = 0;
  B.ph[i] = rnd() * TAU; B.vr[i] = rnd();
  if (mode === 1) {
    B.st[i] = S_CLIMB; B.t[i] = 4; B.x[i] = x + nx * 0.85; B.z[i] = z + nz * 0.85; B.y[i] = -depth;
    B.ax[i] = -nx; B.az[i] = -nz; B.hd[i] = Math.atan2(-nx, -nz);
  } else if (mode === 2) {
    const a = rnd() * TAU;
    B.st[i] = S_CLIMB; B.t[i] = 0.45; B.x[i] = x + (rnd() - 0.5) * 0.8; B.z[i] = z + (rnd() - 0.5) * 0.8; B.y[i] = -0.9;
    B.ax[i] = Math.cos(a); B.az[i] = Math.sin(a); B.hd[i] = Math.atan2(B.ax[i], B.az[i]);
  } else {
    B.st[i] = S_MOVE; B.t[i] = 0; B.x[i] = x; B.z[i] = z; B.y[i] = 0; B.hd[i] = rnd() * TAU; B.ax[i] = B.az[i] = 0;
  }
  return i;
}
// Remove dead bugs by swapping the last live one into each hole (order does not matter: instances are rebuilt
// every frame and AI / turret targets are validated by uid). Called at tick start before the hash rebuild.
function compactBugs() {
  if (!deadPending) return;
  const D = B.dead, NA = B_ARRAYS.length;
  let n = B.n;
  for (let r = n - 1; r >= 0; r--) {
    if (!D[r]) continue;
    const l = --n;
    if (r !== l) for (let a = 0; a < NA; a++) { const A = B_ARRAYS[a]; A[r] = A[l]; }
  }
  B.n = n; deadPending = 0;
}
function clearBugs() { B.n = 0; deadPending = 0; hashN = 0; hStart.fill(0); GL.n = 0; BOOMS.length = 0; }

// ---------- damage ----------
// dot = continuous damage (burn, flame, beam): no hit flash
function hitBug(i, dmg, src, dot) {
  if (B.dead[i]) return false;
  if (B.frz[i] > 0) dmg *= 2.5;
  B.hp[i] -= dmg;
  if (!dot && B.fl[i] < 0.6) B.fl[i] = 0.6;
  if (B.hp[i] <= 0) { killBug(i, src); return true; }
  return false;
}
function killBug(i, src) {
  B.dead[i] = 1; deadPending++;
  const x = B.x[i], z = B.z[i], ty = B.type[i];
  const frozen = B.frz[i] > 0;
  onBugKilled(ty, src, x, z);
  if (ty === BOOM) queueBoom(x, z, 3.1, 70, src, 'boomer');
  else if (ty === BRUTE && !simOnly && src >= 0 && Math.hypot(x - M[0].x, z - M[0].z) < 16) hitStop(0.085, 0.12);
  else if (frozen) { const sh = src >= 0 && src < 4 ? M[src].mods.shatter : 1; queueBoom(x, z, 1.7 * sh, 24 * sh, src, 'frost'); }
  if (!simOnly) fxBugDeath(i, frozen);
  if (ty === BRUTE && rnd() < 0.35) dropMedkit(x, z);
}

// ---------- explosions (deferred, so chain reactions ripple tick by tick) ----------
const BOOMS = [];
function queueBoom(x, z, r, dmg, src, kind) { if (BOOMS.length < 48) BOOMS.push({ x, z, r, dmg, src, kind }); }
function processBooms() {
  const n = BOOMS.length;
  for (let k = 0; k < n; k++) {
    const e = BOOMS[k];
    const cnt = queryCircle(e.x, e.z, e.r);
    const knock = e.kind === 'frost' ? 2 : e.kind === 'pulse' ? 5 : 11;
    for (let q = 0; q < cnt; q++) {
      const b = QB[q];
      const dx = B.x[b] - e.x, dz = B.z[b] - e.z, d = Math.sqrt(dx * dx + dz * dz) + 1e-4;
      const f = e.kind === 'pulse' ? 1 : 1 - 0.55 * Math.min(1, d / e.r);
      if (e.kind === 'frost') B.chill[b] = Math.min(1, B.chill[b] + 0.45);
      if (knock && B.type[b] !== BRUTE) { B.vx[b] += dx / d * knock * f; B.vz[b] += dz / d * knock * f; }
      hitBug(b, e.dmg * f, e.src);
    }
    if (e.kind === 'boomer') {
      for (const m of M) {
        const dx = m.x - e.x, dz = m.z - e.z, d = Math.hypot(dx, dz);
        if (d < e.r + 0.4) hurtMarine(m, BT[BOOM].dmg * DIR.dmgMul * (1 - 0.5 * d / (e.r + 0.4)), dx / (d + 0.01) * 7, dz / (d + 0.01) * 7);
      }
    }
    if (!simOnly) fxExplosion(e.x, e.z, e.r, e.kind);
  }
  BOOMS.splice(0, n);
}

// ---------- acid globs (spitters) ----------
const GLMAX = 64;
const GL = { n: 0, x0: new Float32Array(GLMAX), z0: new Float32Array(GLMAX), x1: new Float32Array(GLMAX), z1: new Float32Array(GLMAX), t: new Float32Array(GLMAX), dur: new Float32Array(GLMAX) };
function launchGlob(x0, z0, x1, z1) {
  if (GL.n >= GLMAX) return;
  const k = GL.n++;
  GL.x0[k] = x0; GL.z0[k] = z0; GL.x1[k] = x1; GL.z1[k] = z1; GL.t[k] = 0; GL.dur[k] = 0.95;
  if (!simOnly) sfx('spit', x0, z0);
}
function updateGlobs(dt) {
  for (let k = 0; k < GL.n; k++) {
    GL.t[k] += dt;
    if (GL.t[k] < GL.dur[k]) continue;
    const x = GL.x1[k], z = GL.z1[k];
    for (const m of M) { const d = Math.hypot(m.x - x, m.z - z); if (d < 1.5) hurtMarine(m, BT[SPIT].dmg * DIR.dmgMul, 0, 0); }
    if (!simOnly) fxAcid(x, z);
    const l = --GL.n;
    GL.x0[k] = GL.x0[l]; GL.z0[k] = GL.z0[l]; GL.x1[k] = GL.x1[l]; GL.z1[k] = GL.z1[l]; GL.t[k] = GL.t[l]; GL.dur[k] = GL.dur[l];
    k--;
  }
}

// ---------- per-tick swarm update ----------
const crowd = new Float32Array(4);      // bugs pressing on each marine (slows them)
const typeAlive = new Int32Array(4);    // live count per bug type (caps on specials)
const mX = new Float32Array(4), mZ = new Float32Array(4), mUp = new Uint8Array(4);
let simTime = 0, nearCam = 0;
function walkable(x, z) { const c = cellOf(x, z); return c >= 0 && walk[c] === 1; }

function simBugs(dt) {
  let anyUp = 0;
  for (let k = 0; k < 4; k++) { const m = M[k]; mX[k] = m.x; mZ[k] = m.z; mUp[k] = m.downed ? 0 : 1; anyUp |= mUp[k]; crowd[k] = 0; }
  typeAlive.fill(0);
  for (let i = 0; i < B.n; i++) if (!B.dead[i]) typeAlive[B.type[i]]++;
  const n = B.n;
  const spreadRate = 1.4 * pyroSpread();
  const liftFall = DIR.stage === 'extract' && DIR.extractT > 0.4;
  for (let i = 0; i < n; i++) {
    if (B.dead[i]) continue;
    const ty = B.type[i];
    if (B.fl[i] > 0) B.fl[i] -= dt * 4;
    // --- status effects ---
    if (B.burn[i] > 0) {
      B.burn[i] -= dt;
      const src = B.bsrc[i];
      if (hitBug(i, CLASSES.pyro.burnDps * pyroBurnMul(src) * dt, src, true)) continue;
      if (rnd() < spreadRate * dt) {
        const c = hCell[i] | 0, e = hStart[c + 1];
        for (let k = hStart[c]; k < e; k++) { const o = hItems[k]; if (o !== i && !B.dead[o] && B.burn[o] <= 0) { B.burn[o] = 2.5; B.bsrc[o] = src; break; } }
      }
    }
    if (B.frz[i] > 0) {
      B.frz[i] -= dt; B.vx[i] = B.vz[i] = 0;
      if (B.frz[i] <= 0) B.chill[i] = 0.5;
      continue;
    }
    if (B.chill[i] > 0) B.chill[i] = Math.max(0, B.chill[i] - dt * 0.4);
    let x = B.x[i], z = B.z[i];
    const st = B.st[i];
    if (liftFall && liftCell[cellClamp(x, z)]) {
      B.y[i] -= dt * (4 + (-B.y[i]) * 3); B.ph[i] += dt * 20;
      if (B.y[i] < -12) { B.dead[i] = 1; deadPending++; }
      continue;
    }
    // --- climbing up the side of the platform, cresting over the railing / bursting from a vent ---
    if (st === S_CLIMB) {
      B.t[i] -= dt; B.ph[i] += dt * 14;
      let y = B.y[i];
      if (y < -0.85) y += dt * (2.8 + B.vr[i]);           // scaling the wall below the deck edge
      else { y += dt * 2.4; B.x[i] = x + B.ax[i] * 2.6 * dt; B.z[i] = z + B.az[i] * 2.6 * dt; }   // cresting inward
      if (y >= 0 || B.t[i] <= 0) { y = 0; B.st[i] = S_MOVE; B.vx[i] = B.ax[i] * 2; B.vz[i] = B.az[i] * 2; }
      B.y[i] = y;
      continue;
    }
    // --- pick target marine ---
    let best = 0, bd = 1e9;
    for (let k = 0; k < 4; k++) {
      if (anyUp && !mUp[k]) continue;
      const dx = mX[k] - x, dz = mZ[k] - z, d2 = dx * dx + dz * dz;
      if (d2 < bd) { bd = d2; best = k; }
    }
    const dist = Math.sqrt(bd) + 1e-4;
    const tx = (mX[best] - x) / dist, tz = (mZ[best] - z) / dist;
    let ddx, ddz;
    const c0 = cellOf(x, z);
    if (dist < 5.5 || c0 < 0 || (flowX[c0] === 0 && flowZ[c0] === 0)) { ddx = tx; ddz = tz; }
    else { ddx = flowX[c0]; ddz = flowZ[c0]; }
    let speed = B.spd[i] * (1 - 0.6 * B.chill[i]) * (B.burn[i] > 0 ? 1.15 : 1);
    if (B.cd[i] > 0) B.cd[i] -= dt;
    let acc = 9;
    // --- type behaviours ---
    if (ty === SPIT) {
      if (st === S_MOVE) {
        if (dist < 11 && dist > 3.2 && B.cd[i] <= 0 && anyUp) {
          const m = M[best];
          const ax = mX[best] + m.vx * 0.8 + (rnd() - 0.5) * 1.2, az = mZ[best] + m.vz * 0.8 + (rnd() - 0.5) * 1.2;
          B.st[i] = S_WIND; B.t[i] = 0.5; B.ax[i] = ax; B.az[i] = az;
          if (!simOnly) { teleRing(ax, az, 1.5, 0.75, 1.0, 0.15, 1.45); teleFill(ax, az, 1.5, 0.5, 0.85, 0.08, 1.45); }
        } else if (dist < 4) { ddx = -tx; ddz = -tz; speed *= 0.8; }
        else if (dist < 10 && B.cd[i] > 0.4) speed *= 0.25;
      } else {
        speed = 0;
        B.t[i] -= dt;
        if (B.t[i] <= 0) { launchGlob(x, z, B.ax[i], B.az[i]); B.st[i] = S_MOVE; B.cd[i] = 2.8 + rnd() * 1.6; }
      }
    } else if (ty === BRUTE) {
      if (st === S_MOVE) {
        if (dist < 9.5 && dist > 2.4 && B.cd[i] <= 0 && anyUp) {
          B.st[i] = S_WIND; B.t[i] = 0.8; B.ax[i] = tx; B.az[i] = tz; B.hit[i] = 0;
          if (!simOnly) { teleLane(x, z, tx, tz, 12, 2.3, 0.8, 0.9); sfx('roar', x, z); }
        }
      } else if (st === S_WIND) {
        speed = 0; ddx = B.ax[i]; ddz = B.az[i];
        B.t[i] -= dt;
        if (B.t[i] <= 0) { B.st[i] = S_CHARGE; B.t[i] = 0.9; }
      } else if (st === S_CHARGE) {
        ddx = B.ax[i]; ddz = B.az[i]; speed = 12.5; acc = 30;
        B.t[i] -= dt;
        for (let k = 0; k < 4; k++) {
          if (!mUp[k] || (B.hit[i] & (1 << k))) continue;
          const dx = mX[k] - x, dz = mZ[k] - z;
          if (dx * dx + dz * dz < (B.r[i] + 0.6) ** 2) { B.hit[i] |= 1 << k; hurtMarine(M[k], 16 * DIR.dmgMul, B.ax[i] * 13, B.az[i] * 13); }
        }
        if (B.t[i] <= 0) { B.st[i] = S_MOVE; B.cd[i] = 5 + rnd() * 3; }
      }
    } else if (ty === BOOM) {
      if (st === S_MOVE && dist < 2.4 && anyUp) {
        B.st[i] = S_SWELL; B.t[i] = 0.8;
        if (!simOnly) { teleFill(x, z, 3.1, 1.0, 0.2, 0.1, 0.8); teleRing(x, z, 3.1, 1.0, 0.35, 0.2, 0.8); sfx('swell', x, z); }
      } else if (st === S_SWELL) {
        speed *= 0.35; B.t[i] -= dt;
        if (B.t[i] <= 0) { killBug(i, -1); continue; }
      }
    }
    // --- steering ---
    const k1 = Math.min(1, acc * dt);
    let vx = B.vx[i] + (ddx * speed - B.vx[i]) * k1;
    let vz = B.vz[i] + (ddz * speed - B.vz[i]) * k1;
    // --- separation (the 2x2 cells nearest the bug's sub-cell position, at most 16 live neighbours) ---
    const ri = B.r[i], mi = BMASS[ty];
    let px = 0, pz = 0, checks = 0;
    const hc = i < hashN ? hCell[i] : cellClamp(x, z), hi = hc % G, hj = (hc / G) | 0;
    const di0 = (x + GH - hi) < 0.5 ? -1 : 0, dj0 = (z + GH - hj) < 0.5 ? -1 : 0;
    outer:
    for (let dj = dj0; dj <= dj0 + 1; dj++) {
      const j = hj + dj; if (j < 0 || j >= G) continue;
      for (let di = di0; di <= di0 + 1; di++) {
        const ii = hi + di; if (ii < 0 || ii >= G) continue;
        const c = j * G + ii, e = hStart[c + 1];
        for (let k = hStart[c]; k < e; k++) {
          const o = hItems[k];
          if (o === i || B.dead[o]) continue;
          const dx = x - B.x[o], dz = z - B.z[o], rr = ri + B.r[o], d2 = dx * dx + dz * dz;
          if (d2 < rr * rr && d2 > 1e-8) {
            const d = Math.sqrt(d2), mo = BMASS[B.type[o]];
            const w = (rr - d) / d * (mo / (mi + mo));
            px += dx * w; pz += dz * w;
          }
          if (++checks >= 16) break outer;
        }
      }
    }
    // --- marines are solid; bugs pressing on them slow them down ---
    for (let k = 0; k < 4; k++) {
      const dx = x - mX[k], dz = z - mZ[k], rr = ri + 0.42, d2 = dx * dx + dz * dz;
      if (d2 < (rr + 0.5) * (rr + 0.5)) {
        if (mUp[k]) crowd[k] += BMASS[ty];
        if (d2 < rr * rr && d2 > 1e-8) { const d = Math.sqrt(d2), w = (rr - d) / d; px += dx * w; pz += dz * w; }
      }
    }
    const pl = Math.hypot(px, pz);
    if (pl > 0.14) { px *= 0.14 / pl; pz *= 0.14 / pl; }
    let nx = x + vx * dt + px * 0.65, nz = z + vz * dt + pz * 0.65;
    if (c0 >= 0 && walk[c0] === 1 && !walkable(nx, nz)) {
      if (walkable(nx, z)) { nz = z; vz *= 0.3; }
      else if (walkable(x, nz)) { nx = x; vx *= 0.3; }
      else { nx = x; nz = z; vx *= -0.2; vz *= -0.2; if (st === S_CHARGE) { B.st[i] = S_MOVE; B.cd[i] = 4; } }
    }
    B.x[i] = nx; B.z[i] = nz; B.vx[i] = vx; B.vz[i] = vz;
    // --- melee ---
    if (dist < ri + 0.62 && B.cd[i] <= 0 && B.st[i] === S_MOVE && ty !== BOOM && mUp[best]) {
      // attack slots: only a few small bugs can land a bite per second on one marine
      const mm = M[best];
      if (ty === BRUTE || mm.bite >= 1) {
        if (ty !== BRUTE) mm.bite -= 1;
        hurtMarine(mm, BT[ty].dmg * DIR.dmgMul, tx * (ty === BRUTE ? 6 : 0.6), tz * (ty === BRUTE ? 6 : 0.6));
        B.cd[i] = BT[ty].atkCd * (0.8 + rnd() * 0.4);
        B.ph[i] += 1.5;
      } else B.cd[i] = 0.15 + rnd() * 0.2;
    }
    // --- heading + gait phase ---
    const sp2 = vx * vx + vz * vz, stN = B.st[i];
    let want = NaN;
    if (stN === S_WIND) want = ty === SPIT ? Math.atan2(B.ax[i] - x, B.az[i] - z) : Math.atan2(B.ax[i], B.az[i]);
    else if (sp2 > 0.09) want = Math.atan2(vx, vz);
    if (want === want) B.hd[i] += angDiff(B.hd[i], want) * Math.min(1, 10 * dt);
    B.ph[i] += Math.sqrt(sp2) * dt * 8 / B.sc[i];
  }
}

// ---------- bug meshes (one InstancedMesh per type) ----------
function bugPart(geo, color, glow, legW = 0, legPh = 0) {
  return paint(geo, color, glow, (g, n) => {
    const a = new Float32Array(n * 3);
    for (let i = 0; i < n; i++) { a[i * 3] = legW; a[i * 3 + 1] = legPh; }
    g.setAttribute('aLeg', new THREE.BufferAttribute(a, 3));
  });
}
function ellip(r, sx, sy, sz, x, y, z, detail = 0, rx = 0) {
  const g = new THREE.IcosahedronGeometry(r, detail); g.scale(sx, sy, sz); if (rx) g.rotateX(rx); g.translate(x, y, z); return g;
}
// Two-segment leg (hip -> knee -> foot). Weight grows with horizontal distance from the hip.
function legGeo(parts, hip, knee, foot, th, ph, color) {
  for (const [a, b] of [[hip, knee], [knee, foot]]) {
    const ax = b[0] - a[0], ay = b[1] - a[1], az = b[2] - a[2], len = Math.hypot(ax, ay, az);
    const g = new THREE.CylinderGeometry(th * 0.8, th, len, 3, 1, true);
    g.translate(0, len / 2, 0);
    const q = new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 1, 0), new THREE.Vector3(ax / len, ay / len, az / len));
    g.applyQuaternion(q); g.translate(a[0], a[1], a[2]);
    const part = bugPart(g, color, 0, 1, ph);
    const p = part.attributes.position, L = part.attributes.aLeg;
    const reach = Math.hypot(foot[0] - hip[0], foot[2] - hip[2]) || 1;
    for (let i = 0; i < p.count; i++) L.setX(i, clamp(Math.hypot(p.getX(i) - hip[0], p.getZ(i) - hip[2]) / reach, 0, 1));
    parts.push(part);
  }
}
function legs6(parts, hipX, hipY, zs, kneeX, kneeY, footX, spread, th, color, curl = 0) {
  zs.forEach((hz, k) => {
    for (const side of [-1, 1]) {
      const ph = ((k + (side > 0 ? 1 : 0)) % 2) * Math.PI;
      const fz = hz + (k - 1) * spread;
      legGeo(parts, [side * hipX, hipY, hz], [side * kneeX, kneeY, hz + (k - 1) * spread * 0.5], [side * (footX - curl), curl ? hipY + 0.05 : 0.0, curl ? hz : fz], th, ph, color);
    }
  });
}
// sparse = 1: the gland only lights on the brighter half of the instances (flag carried in aLeg.y of a non-leg part)
function speckles(parts, R, n, cx, cy, cz, sx, sz, size, color, sparse = 0) {
  for (let k = 0; k < n; k++) {
    const g = new THREE.TetrahedronGeometry(size * (0.7 + R() * 0.6));
    g.translate(cx + (R() - 0.5) * sx, cy, cz + (R() - 0.5) * sz);
    parts.push(bugPart(g, color, 1, 0, sparse));
  }
}
function buildBugGeometry(type, corpse = false) {
  const P = [], R = mulberry32(100 + type);
  const curl = corpse ? 0.22 : 0;
  // dark contact smudge under the body: in a crowd these merge into the black flood of the references
  if (!corpse) {
    const g = new THREE.CircleGeometry([0.46, 0.52, 0.5, 0.48][type], 9); g.rotateX(-Math.PI / 2); g.scale(1, 1, 1.3); g.translate(0, 0.012, -0.05);
    const part = bugPart(g, 0x040205, 0), L = part.attributes.aLeg;
    for (let k = 0; k < L.count; k++) L.setZ(k, 1);   // flagged: hidden while the bug climbs a wall
    P.push(part);
  }
  if (type === RUN) {
    P.push(bugPart(ellip(0.2, 1.0, 0.7, 1.15, 0, 0.3, 0.05), 0x2b1a27, 0));
    // flatter, longer abdomen (kept at detail 1: once welded it has fewer unique vertices than flat detail 0)
    P.push(bugPart(ellip(0.25, 0.85, 0.58, 1.6, 0, 0.32, -0.38, 1), 0x35202f, 0));
    P.push(bugPart(ellip(0.13, 1.0, 0.8, 1.2, 0, 0.27, 0.33), 0x1d121b, 0));
    for (const s of [-1, 1]) { const g = new THREE.ConeGeometry(0.03, 0.2, 3); g.rotateX(Math.PI / 2); g.rotateY(-s * 0.35); g.translate(s * 0.07, 0.24, 0.47); P.push(bugPart(g, 0x6a2a3e, 0.2)); }
    for (let k = 0; k < 3; k++) { const g = new THREE.ConeGeometry(0.04, 0.16, 3); g.rotateX(-0.5); g.translate(0, 0.52, -0.2 - k * 0.15); P.push(bugPart(g, 0x1a0f18, 0)); }
    // sparse glints: a dark chitin flood with scattered pink sparks, not a carpet of studded beads
    if (!corpse) { speckles(P, R, 2, 0, 0.5, -0.3, 0.3, 0.55, 0.035, 0xff3c7a, 1); speckles(P, R, 1, 0, 0.47, -0.25, 0.4, 0.7, 0.03, 0xd8142c, 1); }
    // long legs: knees above the back, feet pushed out so they break the silhouette in a crowd
    legs6(P, 0.1, 0.3, [0.2, 0.04, -0.12], 0.42, 0.62, 0.8, 0.36, 0.03, 0x24161f, curl);
  } else if (type === SPIT) {
    P.push(bugPart(ellip(0.2, 1.0, 0.8, 1.2, 0, 0.42, 0.12), 0x2a1d24, 0));
    P.push(bugPart(ellip(0.32, 1.0, 0.9, 1.25, 0, 0.62, -0.32, 1, -0.5), 0x3a2a1c, 0));
    P.push(bugPart(ellip(0.15, 1.0, 0.85, 1.25, 0, 0.42, 0.42), 0x1e1418, 0));
    if (!corpse) speckles(P, R, 3, 0, 0.86, -0.36, 0.36, 0.4, 0.045, 0xb8ff2a);
    if (!corpse) P.push(bugPart(ellip(0.07, 1, 1, 1, 0, 0.42, 0.55), 0xc8ff40, 1));
    legs6(P, 0.12, 0.42, [0.2, 0.08, -0.06], 0.46, 0.66, 0.7, 0.34, 0.04, 0x221820, curl);
  } else if (type === BRUTE) {
    P.push(bugPart(ellip(0.3, 1.15, 0.8, 1.1, 0, 0.42, 0.0, 1), 0x2a1c1c, 0));
    P.push(bugPart(ellip(0.3, 1.0, 0.75, 1.3, 0, 0.44, -0.42, 1), 0x231716, 0));
    const plate = new THREE.BoxGeometry(0.52, 0.16, 0.42); plate.rotateX(-0.25); plate.translate(0, 0.66, 0.06); P.push(bugPart(plate, 0x4d3a33, 0));
    const plate2 = new THREE.BoxGeometry(0.46, 0.14, 0.4); plate2.rotateX(0.2); plate2.translate(0, 0.66, -0.38); P.push(bugPart(plate2, 0x45332d, 0));
    P.push(bugPart(ellip(0.19, 1.3, 0.8, 1.0, 0, 0.38, 0.36, 0), 0x392624, 0));
    for (const s of [-1, 1]) { const g = new THREE.ConeGeometry(0.06, 0.38, 4); g.rotateX(Math.PI / 2 - 0.4); g.rotateY(s * 0.4); g.translate(s * 0.16, 0.48, 0.5); P.push(bugPart(g, 0xc9b9a0, 0)); }
    if (!corpse) speckles(P, R, 3, 0, 0.62, -0.3, 0.4, 0.6, 0.05, 0xff4a2a);
    legs6(P, 0.18, 0.4, [0.2, 0.0, -0.22], 0.44, 0.58, 0.6, 0.3, 0.06, 0x1e1414, curl);
  } else {
    P.push(bugPart(ellip(0.17, 1.0, 0.8, 1.1, 0, 0.3, 0.18), 0x2a1a20, 0));
    P.push(bugPart(ellip(0.36, 1.0, 0.9, 1.1, 0, 0.46, -0.2, 1), corpse ? 0x3a2018 : 0xff6a2a, corpse ? 0 : 0.38));
    P.push(bugPart(ellip(0.12, 1.0, 0.8, 1.1, 0, 0.27, 0.42), 0x1e1418, 0));
    if (!corpse) speckles(P, R, 3, 0, 0.78, -0.2, 0.4, 0.45, 0.05, 0xffd05a);
    legs6(P, 0.12, 0.3, [0.24, 0.14, 0.04], 0.34, 0.44, 0.5, 0.2, 0.035, 0x24161f, curl);
  }
  // welded + indexed: the GPU post-transform cache reuses shared vertices (about half the vertex shading);
  // flat-shaded parts keep distinct normals and stay unmerged, so the look is unchanged
  let g = mergeGeometries(P);
  // baked height shading: feet and belly sink into shadow, backs stay lit, so every body keeps its own edge in a pile
  if (!corpse) {
    const p = g.attributes.position, c = g.attributes.color, gl = g.attributes.aGlow;
    for (let i = 0; i < p.count; i++) {
      if (gl.getX(i) > 0.5) continue;
      const ao = 0.38 + 0.62 * smooth01((p.getY(i) - 0.02) / 0.42);
      c.setXYZ(i, c.getX(i) * ao, c.getY(i) * ao, c.getZ(i) * ao);
    }
  }
  if (!corpse) g = mergeVertices(g, 1e-4);
  if (corpse) {
    g.deleteAttribute('aGlow'); g.deleteAttribute('aLeg');
    const p = g.attributes.position;
    for (let i = 0; i < p.count; i++) p.setY(i, p.getY(i) * 0.55);
    g.computeVertexNormals();
  }
  g.computeBoundingSphere();
  return g;
}

const bugMeshes = [];
for (let t = 0; t < 4; t++) {
  const geo = buildBugGeometry(t);
  geo.setAttribute('iAnim', new THREE.InstancedBufferAttribute(new Float32Array(MAXB * 4), 4).setUsage(THREE.DynamicDrawUsage));
  const mesh = new THREE.InstancedMesh(geo, MAT.bug, MAXB);
  mesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
  mesh.instanceColor = new THREE.InstancedBufferAttribute(new Float32Array(MAXB * 3), 3).setUsage(THREE.DynamicDrawUsage);
  // bugs never cast shadows themselves: a cheap caster-only proxy below stands in for those inside the flashlight
  mesh.count = 0; mesh.frustumCulled = false; mesh.castShadow = false;
  scene.add(mesh);
  bugMeshes.push(mesh);
}
// Shadow proxy ('high' only): a 20-triangle blob per bug inside the player's flashlight cone.
// colorWrite/depthWrite off = invisible in the main pass; the shadow pass uses its own depth material.
const SHADOW_PROXY_MAX = 400;
const bugShadow = new THREE.InstancedMesh(new THREE.IcosahedronGeometry(0.3, 0).scale(1, 0.7, 1.3).translate(0, 0.35, 0),
  new THREE.MeshBasicMaterial({ colorWrite: false, depthWrite: false }), SHADOW_PROXY_MAX);
bugShadow.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
bugShadow.count = 0; bugShadow.frustumCulled = false; bugShadow.castShadow = false;
scene.add(bugShadow);
const _pv4 = new THREE.Matrix4();
const _bc = new Int32Array(4);
// per-bug chitin tints (umber / slate / plum), picked and scaled by B.vr; the queen gets a violet multiplier
const BUG_TINT = [[1.0, 0.86, 0.74], [0.8, 0.86, 1.0], [1.0, 0.8, 0.98]], QUEEN_TINT = [0.72, 0.45, 1.5];
function markRange(attr, start, count) { attr.clearUpdateRanges(); attr.addUpdateRange(start, count); attr.needsUpdate = true; }
function writeBugInstances(time, dt) {
  _bc.fill(0);
  const emitK = 9 * dt * fxK;
  const n = B.n, cx = camTarget.x, cz = camTarget.z;
  const qUid = (DIR.q && DIR.q.uid) | 0;
  let near = 0;
  // CPU frustum cull: clip-space test of a point at mid-body height (15 % margin covers the body size)
  _pv4.multiplyMatrices(camera.projectionMatrix, camera.matrixWorldInverse);
  const pe = _pv4.elements;
  // shadow proxies: bugs within the player's flashlight cone (only when shadows are on)
  const shadowsOn = Q.shadows && bugShadow.castShadow;
  const sp0 = spots[0], spx = sp0.position.x, spy = sp0.position.y, spz = sp0.position.z;
  let sdx = sp0.target.position.x - spx, sdy = sp0.target.position.y - spy, sdz = sp0.target.position.z - spz;
  { const l = Math.hypot(sdx, sdy, sdz) || 1; sdx /= l; sdy /= l; sdz /= l; }
  const shA = bugShadow.instanceMatrix.array, cosCone = Math.cos(0.6);
  let shN = 0;
  for (let i = 0; i < n; i++) {
    if (B.dead[i]) continue;
    const bx = B.x[i], bz = B.z[i];
    if (Math.abs(bx - cx) < 22 && Math.abs(bz - cz) < 22) near++;
    const bs = B.sc[i], gy = groundY(bx, bz) + B.y[i], my = gy + 0.3 * bs;
    const cw = pe[3] * bx + pe[7] * my + pe[11] * bz + pe[15];
    if (cw <= 0) continue;
    // the margin grows with the body: a 4.2x queen keeps drawing until all of her has left the screen
    const ccx = pe[0] * bx + pe[4] * my + pe[8] * bz + pe[12], ccy = pe[1] * bx + pe[5] * my + pe[9] * bz + pe[13], mg = (bs > 2 ? 1 + 0.15 * bs : 1.15) * cw;
    if (ccx > mg || ccx < -mg || ccy > mg || ccy < -mg) continue;
    const t = B.type[i], k = _bc[t]++, mesh = bugMeshes[t];
    const a = mesh.instanceMatrix.array, o = k * 16;
    let s = B.sc[i], sy = s;
    if (B.st[i] === S_SWELL) { const p = 1 - B.t[i] / 0.8; s *= 1 + p * 0.45 + Math.sin(time * 40) * 0.04 * p; sy = s; }
    if (B.st[i] === S_WIND && t === BRUTE) sy = s * (1 + Math.sin(time * 30) * 0.05);
    const c = Math.cos(B.hd[i]), sn = Math.sin(B.hd[i]);
    if (B.st[i] === S_CLIMB && B.y[i] < -0.1) {
      // nose up while scaling the wall, levelling out as it crests the edge
      const p = clamp((-B.y[i] - 0.1) / 0.7, 0, 1) * 1.4, cp = Math.cos(p), sp = Math.sin(p);
      a[o] = c * s; a[o + 1] = 0; a[o + 2] = -sn * s; a[o + 3] = 0;
      a[o + 4] = -sn * sp * sy; a[o + 5] = cp * sy; a[o + 6] = -c * sp * sy; a[o + 7] = 0;
      a[o + 8] = sn * cp * s; a[o + 9] = sp * s; a[o + 10] = c * cp * s; a[o + 11] = 0;
    } else {
      a[o] = c * s; a[o + 1] = 0; a[o + 2] = -sn * s; a[o + 3] = 0;
      a[o + 4] = 0; a[o + 5] = sy; a[o + 6] = 0; a[o + 7] = 0;
      a[o + 8] = sn * s; a[o + 9] = 0; a[o + 10] = c * s; a[o + 11] = 0;
    }
    a[o + 12] = bx; a[o + 13] = gy; a[o + 14] = bz; a[o + 15] = 1;
    if (shadowsOn && shN < SHADOW_PROXY_MAX) {
      const ox = bx - spx, oy = my - spy, oz = bz - spz, d2 = ox * ox + oy * oy + oz * oz;
      if (d2 < 32 * 32 && ox * sdx + oy * sdy + oz * sdz > cosCone * Math.sqrt(d2)) { shA.set(a.subarray(o, o + 16), shN * 16); shN++; }
    }
    // three chitin tints x a wide brightness spread: breaks up the uniform carpet without extra draws
    const isQ = qUid !== 0 && B.uid[i] === qUid;
    const col = mesh.instanceColor.array, oc = k * 3, tv = B.vr[i] * 3, ti = tv | 0, v = 0.6 + (tv - ti) * 0.6, tt = isQ ? QUEEN_TINT : BUG_TINT[ti > 2 ? 2 : ti];
    col[oc] = v * tt[0]; col[oc + 1] = v * tt[1]; col[oc + 2] = v * tt[2];
    const an = mesh.geometry.attributes.iAnim.array, oa = k * 4;
    an[oa] = B.ph[i];
    // hit flash; swelling boomers blink white-hot faster and faster before they pop. The queen is under fire the
    // whole fight: her flash is a faint flicker, so she stays violet instead of a white blob
    an[oa + 1] = B.st[i] === S_SWELL ? Math.max(B.fl[i], (0.5 + 0.5 * Math.sin(time * (18 + 30 * (1 - B.t[i] / 0.8)))) * 0.9) : Math.max(0, B.fl[i]) * (isQ ? 0.25 : 1);
    if (B.burn[i] > 0) {
      an[oa + 2] = 0.55 + 0.45 * Math.sin(time * 23 + i * 1.7);
      if (rnd() < emitK) PA.emit(B.x[i] + rr(-0.2, 0.2), 0.35 * B.sc[i], B.z[i] + rr(-0.2, 0.2), 0, rr(1, 2.2), 0, rr(0.25, 0.45), 0.35 * B.sc[i], 0.7 * B.sc[i], 1, 0.6, 0.25, 0.55, -0.5, 1, 1);
    } else an[oa + 2] = 0;
    an[oa + 3] = isQ ? -1 : B.frz[i] > 0 ? 1 : B.chill[i] * 0.55;
  }
  nearCam = near;
  bugShadow.count = shN;
  if (shN) markRange(bugShadow.instanceMatrix, 0, shN * 16);
  for (let t = 0; t < 4; t++) {
    const mesh = bugMeshes[t], cnt = _bc[t];
    mesh.count = cnt;
    if (!cnt) continue;
    markRange(mesh.instanceMatrix, 0, cnt * 16);
    markRange(mesh.instanceColor, 0, cnt * 3);
    markRange(mesh.geometry.attributes.iAnim, 0, cnt * 4);
  }
}
