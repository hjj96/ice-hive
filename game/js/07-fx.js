// ================================================================
//  FX — particles, decals, corpses, lasers, tracers, telegraphs,
//       floor indicators, weather, light pool, camera shake
// ================================================================
const TONE_TAIL = '\n#include <tonemapping_fragment>\n#include <colorspace_fragment>\n';
let fxK = 1;   // quality scale for emission rates

// ---------- particle pools (CPU sim, one Points draw each) ----------
// Tileable smooth value noise (16 lattice cells over 64 px): ragged flame / smoke edges with one fetch per octave.
const NOISE_TEX = (() => {
  const S = 64, L = 16, R = mulberry32(5), lat = new Float32Array(L * L), data = new Uint8Array(S * S * 4);
  for (let i = 0; i < lat.length; i++) lat[i] = R();
  for (let y = 0; y < S; y++) for (let x = 0; x < S; x++) {
    const fx = x / S * L, fy = y / S * L, xi = Math.floor(fx), yi = Math.floor(fy), u = smooth01(fx - xi), v = smooth01(fy - yi);
    const a = lat[(yi % L) * L + xi % L], b = lat[(yi % L) * L + (xi + 1) % L], c = lat[((yi + 1) % L) * L + xi % L], d = lat[((yi + 1) % L) * L + (xi + 1) % L];
    const o = (y * S + x) * 4; data[o] = data[o + 1] = data[o + 2] = lerp(lerp(a, b, u), lerp(c, d, u), v) * 255; data[o + 3] = 255;
  }
  const t = new THREE.DataTexture(data, S, S, THREE.RGBAFormat);
  t.wrapS = t.wrapT = THREE.RepeatWrapping; t.magFilter = t.minFilter = THREE.LinearFilter; t.generateMipmaps = false; t.needsUpdate = true;
  return t;
})();
const PSTRIDE = 19;   // slot 17: floor height, slot 18: per-particle noise seed
class Particles {
  constructor(cap, additive) {
    this.cap = cap; this.max = cap; this.n = 0; this.additive = additive;
    this.d = new Float32Array(cap * PSTRIDE);
    this.pos = new Float32Array(cap * 3); this.col = new Float32Array(cap * 4); this.size = new Float32Array(cap); this.seed = new Float32Array(cap);
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(this.pos, 3).setUsage(THREE.DynamicDrawUsage));
    g.setAttribute('color4', new THREE.BufferAttribute(this.col, 4).setUsage(THREE.DynamicDrawUsage));
    g.setAttribute('size', new THREE.BufferAttribute(this.size, 1).setUsage(THREE.DynamicDrawUsage));
    g.setAttribute('seed', new THREE.BufferAttribute(this.seed, 1).setUsage(THREE.DynamicDrawUsage));
    g.setDrawRange(0, 0);
    this.geo = g;
    this.mat = new THREE.ShaderMaterial({
      uniforms: { uScale: { value: 400 }, uNoise: { value: NOISE_TEX } },
      vertexShader: `attribute vec4 color4; attribute float size; attribute float seed; uniform float uScale; varying vec4 vC; varying float vS;
        void main() { vec4 mv = modelViewMatrix * vec4(position, 1.0); gl_Position = projectionMatrix * mv;
          gl_PointSize = clamp(size * uScale / -mv.z, 1.0, 300.0); vC = color4; vS = seed; }`,
      // ragged sprites: the disc radius is broken up by two octaves of noise (billowing flame, torn smoke)
      fragmentShader: `uniform sampler2D uNoise; varying vec4 vC; varying float vS;
        void main() { vec2 q = gl_PointCoord - 0.5;
          float n = texture2D(uNoise, q * 0.31 + vS * vec2(7.31, 3.17)).r * 0.6 + texture2D(uNoise, q * 0.69 - vS * vec2(2.93, 5.71)).r * 0.4;
          float d = length(q) * 2.0 * (0.75 + 0.5 * n); float a = smoothstep(1.0, 0.0, d);
          ${additive ? 'a *= a;' : 'a = smoothstep(0.0, 0.6, a);'}
          gl_FragColor = vec4(vC.rgb, vC.a * a);
          ${TONE_TAIL} }`,
      transparent: true, depthWrite: false, blending: additive ? THREE.AdditiveBlending : THREE.NormalBlending,
    });
    this.points = new THREE.Points(g, this.mat);
    this.points.frustumCulled = false;
    this.points.renderOrder = additive ? 3 : 2;
    scene.add(this.points);
  }
  // kind: 0 fade, 1 fire ramp, 2 smoke (fade in/out), 3 spark (stretch-free fast fade)
  // y is relative to the floor under (x, z) unless abs is set; slot 17 keeps the floor height for bounces
  emit(x, y, z, vx, vy, vz, life, s0, s1, r, g, b, a, grav, drag, kind, abs) {
    const gy = groundY(x, z);
    if (!abs) y += gy;
    let i = this.n;
    if (i >= this.max) { i = (Math.random() * this.max) | 0; } else this.n++;
    const d = this.d, o = i * PSTRIDE;
    d[o] = x; d[o + 1] = y; d[o + 2] = z; d[o + 3] = vx; d[o + 4] = vy; d[o + 5] = vz;
    d[o + 6] = 0; d[o + 7] = life; d[o + 8] = s0; d[o + 9] = s1;
    d[o + 10] = r; d[o + 11] = g; d[o + 12] = b; d[o + 13] = a; d[o + 14] = grav; d[o + 15] = drag; d[o + 16] = kind; d[o + 17] = gy + 0.03;
    d[o + 18] = Math.random();
  }
  update(dt) {
    const d = this.d, P = this.pos, C = this.col, S = this.size, SD = this.seed;
    let n = this.n;
    for (let i = 0; i < n; i++) {
      const o = i * PSTRIDE;
      d[o + 6] += dt;
      if (d[o + 6] >= d[o + 7]) { n--; if (i !== n) d.copyWithin(o, n * PSTRIDE, n * PSTRIDE + PSTRIDE); i--; continue; }
      const dr = 1 / (1 + d[o + 15] * dt);
      d[o + 3] *= dr; d[o + 5] *= dr; d[o + 4] = d[o + 4] * dr - d[o + 14] * dt;
      d[o] += d[o + 3] * dt; d[o + 1] += d[o + 4] * dt; d[o + 2] += d[o + 5] * dt;
      if (d[o + 1] < d[o + 17] && d[o + 14] > 0) {
        // landed: bounce on the floor under the particle now, or keep falling into the abyss
        const c = cellOf(d[o], d[o + 2]);
        if (c >= 0 && walk[c]) {
          const gy = groundY(d[o], d[o + 2]) + 0.03;
          if (d[o + 1] < gy) { d[o + 1] = gy; d[o + 4] *= -0.25; d[o + 3] *= 0.5; d[o + 5] *= 0.5; }
          d[o + 17] = gy;
        } else d[o + 17] = -1e9;
      }
      const t = d[o + 6] / d[o + 7], k = d[o + 16];
      const p3 = i * 3, p4 = i * 4;
      P[p3] = d[o]; P[p3 + 1] = d[o + 1]; P[p3 + 2] = d[o + 2];
      S[i] = d[o + 8] + (d[o + 9] - d[o + 8]) * t; SD[i] = d[o + 18];
      let r = d[o + 10], g = d[o + 11], b = d[o + 12], a = d[o + 13];
      if (k === 1) {
        // fire: white-yellow -> orange -> deep red -> gone
        const u = t * 1.6;
        if (u < 1) { r = lerp(r, 1.0, u); g = lerp(g, 0.42, u); b = lerp(b, 0.08, u); }
        else { const v = Math.min(1, u - 1); r = lerp(1.0, 0.5, v); g = lerp(0.42, 0.06, v); b = lerp(0.08, 0.02, v); }
        a *= 1 - t * t;
      } else if (k === 2) a *= Math.min(1, t * 6) * (1 - t);
      else if (k === 3) a *= (1 - t) * (1 - t);
      else a *= 1 - t;
      C[p4] = r; C[p4 + 1] = g; C[p4 + 2] = b; C[p4 + 3] = a;
    }
    this.n = n;
    this.geo.setDrawRange(0, n);
    const A = this.geo.attributes;
    markRange(A.position, 0, n * 3); markRange(A.color4, 0, n * 4); markRange(A.size, 0, n); markRange(A.seed, 0, n);
  }
}
const PA = new Particles(4000, true);   // additive: fire, sparks, frost, glows
const PN = new Particles(2400, false);  // alpha: smoke, steam, ichor, debris

// ---------- persistent floor decals (ring buffer) ----------
const DEC_MAX = 1500;
const decalGeo = new THREE.PlaneGeometry(1, 1).rotateX(-Math.PI / 2);
decalGeo.setAttribute('iUv', new THREE.InstancedBufferAttribute(new Float32Array(DEC_MAX * 2), 2));
// Decals are multiplicative stains over the already-lit floor: one texture fetch + a blend per fragment instead of
// a transparent 9-light Lambert pass (stains read under the flashlights, vanish in the dark like the floor itself).
const decalMat = new THREE.MeshBasicMaterial({ map: TEX.decals, transparent: true, depthWrite: false, blending: THREE.MultiplyBlending, premultipliedAlpha: false, toneMapped: false, fog: false, polygonOffset: true, polygonOffsetFactor: -2, polygonOffsetUnits: -4 });
decalMat.onBeforeCompile = (sh) => {
  sh.vertexShader = sh.vertexShader.replace('#include <common>', '#include <common>\nattribute vec2 iUv;')
    .replace('#include <uv_vertex>', '#include <uv_vertex>\n  vMapUv = vMapUv * 0.5 + iUv;');
  // multiply factor: 1 where the splat is transparent, the stain colour where it is opaque; keep the target alpha
  sh.fragmentShader = sh.fragmentShader.replace('#include <tonemapping_fragment>', 'gl_FragColor = vec4(mix(vec3(1.0), gl_FragColor.rgb, gl_FragColor.a), 1.0);\n#include <tonemapping_fragment>');
};
decalMat.customProgramCacheKey = () => 'decal';
const decals = new THREE.InstancedMesh(decalGeo, decalMat, DEC_MAX);
decals.instanceColor = new THREE.InstancedBufferAttribute(new Float32Array(DEC_MAX * 3), 3);
decals.count = 0; decals.frustumCulled = false; decals.renderOrder = 1; decals.receiveShadow = false;
scene.add(decals);
const DEC_UV = [[0, 0.5], [0.5, 0.5], [0, 0], [0.5, 0]];
let decHead = 0, decFill = 0, decRing = DEC_MAX, decDirty0 = -1, decDirtyN = 0, decY = 0;
function walkable2(x, z) { const c = cellOf(x, z); return c >= 0 && walk[c] !== 0; }
function decalFits(x, z, h) { return walkable2(x - h, z - h) && walkable2(x + h, z - h) && walkable2(x - h, z + h) && walkable2(x + h, z + h); }
function addDecal(x, z, size, cell, r, g, b, rot = rnd() * TAU) {
  const c0 = cellOf(x, z);
  if (c0 < 0 || !walk[c0]) return;
  // shrink splats at the railings so they never hang over the abyss
  for (let k = 0; k < 3 && !decalFits(x, z, size * 0.4); k++) size *= 0.7;
  const gz = hgz[c0], gy = groundY(x, z) + (stairCell[c0] ? 0.08 : 0);
  const i = decHead;
  decHead = (decHead + 1) % decRing;
  if (decFill < decRing) decFill++;
  decY = (decY + 1) % 64;
  const a = decals.instanceMatrix.array, o = i * 16, c = Math.cos(rot) * size, s = Math.sin(rot) * size;
  a[o] = c; a[o + 1] = -s * gz; a[o + 2] = -s; a[o + 3] = 0; a[o + 4] = 0; a[o + 5] = 1; a[o + 6] = 0; a[o + 7] = 0;
  a[o + 8] = s; a[o + 9] = c * gz; a[o + 10] = c; a[o + 11] = 0; a[o + 12] = x; a[o + 13] = gy + 0.018 + decY * 0.0002; a[o + 14] = z; a[o + 15] = 1;
  const col = decals.instanceColor.array; col[i * 3] = r; col[i * 3 + 1] = g; col[i * 3 + 2] = b;
  const uv = decalGeo.attributes.iUv.array; uv[i * 2] = DEC_UV[cell][0]; uv[i * 2 + 1] = DEC_UV[cell][1];
  if (decDirty0 < 0) { decDirty0 = i; decDirtyN = 0; }
  decDirtyN++;
}
function flushDecals() {
  decals.count = decFill;
  if (decDirty0 < 0) return;
  const full = decDirty0 + decDirtyN > decRing;
  const s0 = full ? 0 : decDirty0, n = full ? decRing : decDirtyN;
  markRange(decals.instanceMatrix, s0 * 16, n * 16);
  markRange(decals.instanceColor, s0 * 3, n * 3);
  markRange(decalGeo.attributes.iUv, s0 * 2, n * 2);
  decDirty0 = -1; decDirtyN = 0;
}

// ---------- 3D corpses (ring buffer, generic + brute) ----------
const CORPSE_MAX = 520;
const corpseMat = new THREE.MeshLambertMaterial({ vertexColors: true });
const corpseMeshes = [buildBugGeometry(RUN, true), buildBugGeometry(BRUTE, true)].map(geo => {
  const m = new THREE.InstancedMesh(geo, corpseMat, CORPSE_MAX);
  m.instanceColor = new THREE.InstancedBufferAttribute(new Float32Array(CORPSE_MAX * 3), 3);
  m.count = 0; m.frustumCulled = false; m.receiveShadow = true;
  scene.add(m);
  return { mesh: m, head: 0, fill: 0, dirty: false };
});
function addCorpse(x, z, hd, sc, type) {
  const c0 = cellOf(x, z);
  if (c0 < 0 || !walk[c0]) return;
  const gz = hgz[c0], gy = groundY(x, z) + (stairCell[c0] ? 0.06 : 0);
  const C = corpseMeshes[type === BRUTE ? 1 : 0];
  const ring = type === BRUTE ? Math.max(20, Q.corpses >> 3) : Q.corpses;
  const i = C.head; C.head = (C.head + 1) % ring; if (C.fill < ring) C.fill++;
  const a = C.mesh.instanceMatrix.array, o = i * 16, rot = hd + (rnd() - 0.5) * 1.2, c = Math.cos(rot) * sc, s = Math.sin(rot) * sc;
  a[o] = c; a[o + 1] = -s * gz; a[o + 2] = -s; a[o + 3] = 0; a[o + 4] = 0; a[o + 5] = sc; a[o + 6] = 0; a[o + 7] = 0;
  a[o + 8] = s; a[o + 9] = c * gz; a[o + 10] = c; a[o + 11] = 0; a[o + 12] = x; a[o + 13] = gy + 0.01; a[o + 14] = z; a[o + 15] = 1;
  // the body colours are near-black purple: lift them and pull the blue out so remains read as maroon-brown
  // chunks under the lights (not ink blots, not pale pink candy)
  const v = 1.6 + rnd() * 0.7, col = C.mesh.instanceColor.array;
  col[i * 3] = v * (type === SPIT ? 0.85 : 1); col[i * 3 + 1] = v * (type === SPIT ? 0.95 : 0.72); col[i * 3 + 2] = v * 0.58;
  C.dirty = true;
}
function flushCorpses() {
  for (const C of corpseMeshes) {
    C.mesh.count = C.fill;
    if (C.dirty) { C.mesh.instanceMatrix.needsUpdate = true; C.mesh.instanceColor.needsUpdate = true; C.dirty = false; }
  }
}

// gore lying on the lift deck rides up with it during the extraction
let liftDec = null, liftCor = null, liftRiseLast = -1;
function fxLiftRise(rise) {
  if (rise === liftRiseLast) return;
  liftRiseLast = rise;
  if (!liftDec) {
    const onL = (a, i) => { const c = cellOf(a[i * 16 + 12], a[i * 16 + 14]); return c >= 0 && liftCell[c]; };
    liftDec = []; const a = decals.instanceMatrix.array;
    for (let i = 0; i < decFill; i++) if (onL(a, i)) liftDec.push(i, a[i * 16 + 13]);
    liftCor = corpseMeshes.map(C => { const l = [], b = C.mesh.instanceMatrix.array; for (let i = 0; i < C.fill; i++) if (onL(b, i)) l.push(i, b[i * 16 + 13]); return l; });
  }
  const a = decals.instanceMatrix.array;
  for (let k = 0; k < liftDec.length; k += 2) a[liftDec[k] * 16 + 13] = liftDec[k + 1] + rise;
  if (liftDec.length) markRange(decals.instanceMatrix, 0, decFill * 16);
  corpseMeshes.forEach((C, j) => { const l = liftCor[j], b = C.mesh.instanceMatrix.array; for (let k = 0; k < l.length; k += 2) b[l[k] * 16 + 13] = l[k + 1] + rise; if (l.length) C.mesh.instanceMatrix.needsUpdate = true; });
}

// ---------- dynamic ribbons: laser sights + projectile tracers ----------
const LASER_N = 5;
const laserGeo = new THREE.BufferGeometry();
const lzPos = new Float32Array(LASER_N * 2 * 4 * 3), lzCol = new Float32Array(LASER_N * 2 * 4 * 3), lzUv = new Float32Array(LASER_N * 2 * 4 * 2);
{
  const idx = [];
  for (let q = 0; q < LASER_N * 2; q++) idx.push(q * 4, q * 4 + 1, q * 4 + 2, q * 4, q * 4 + 2, q * 4 + 3);
  laserGeo.setIndex(idx);
}
laserGeo.setAttribute('position', new THREE.BufferAttribute(lzPos, 3).setUsage(THREE.DynamicDrawUsage));
laserGeo.setAttribute('color', new THREE.BufferAttribute(lzCol, 3).setUsage(THREE.DynamicDrawUsage));
laserGeo.setAttribute('uv', new THREE.BufferAttribute(lzUv, 2).setUsage(THREE.DynamicDrawUsage));
const laserMat = new THREE.ShaderMaterial({
  uniforms: { uDash: { value: TEX.dash }, uTime: { value: 0 } },
  vertexShader: `attribute vec3 color; varying vec3 vC; varying vec2 vUv;
    void main() { vC = color; vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`,
  fragmentShader: `uniform sampler2D uDash; uniform float uTime; varying vec3 vC; varying vec2 vUv;
    void main() { float across = 1.0 - abs(vUv.y * 2.0 - 1.0); across = across * across;
      float dash = texture2D(uDash, vec2(vUv.x * 1.6 - uTime * 2.5, 0.5)).r;
      gl_FragColor = vec4(vC * across * (0.45 + 0.55 * dash), 1.0);
      ${TONE_TAIL} }`,
  transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, side: THREE.DoubleSide,
});
const laserMesh = new THREE.Mesh(laserGeo, laserMat);
laserMesh.frustumCulled = false; laserMesh.renderOrder = 4;
scene.add(laserMesh);
const _lc = new THREE.Color();
function setRibbon(q, x0, y0, z0, x1, y1, z1, w0, w1, r, g, b, fadeEnd, len) {
  const dx = x1 - x0, dz = z1 - z0, l = Math.hypot(dx, dz) || 1, px = -dz / l, pz = dx / l;
  const o = q * 12;
  lzPos[o] = x0 + px * w0; lzPos[o + 1] = y0; lzPos[o + 2] = z0 + pz * w0;
  lzPos[o + 3] = x0 - px * w0; lzPos[o + 4] = y0; lzPos[o + 5] = z0 - pz * w0;
  lzPos[o + 6] = x1 - px * w1; lzPos[o + 7] = y1; lzPos[o + 8] = z1 - pz * w1;
  lzPos[o + 9] = x1 + px * w1; lzPos[o + 10] = y1; lzPos[o + 11] = z1 + pz * w1;
  const e = fadeEnd;
  lzCol[o] = lzCol[o + 3] = r; lzCol[o + 1] = lzCol[o + 4] = g; lzCol[o + 2] = lzCol[o + 5] = b;
  lzCol[o + 6] = lzCol[o + 9] = r * e; lzCol[o + 7] = lzCol[o + 10] = g * e; lzCol[o + 8] = lzCol[o + 11] = b * e;
  const u = q * 8;
  lzUv[u] = 0; lzUv[u + 1] = 0; lzUv[u + 2] = 0; lzUv[u + 3] = 1; lzUv[u + 4] = len; lzUv[u + 5] = 1; lzUv[u + 6] = len; lzUv[u + 7] = 0;
}
function hideRibbon(q) { lzPos.fill(0, q * 12, q * 12 + 12); }

const TR_MAX = PMAX;
const trGeo = new THREE.BufferGeometry();
const trPos = new Float32Array(TR_MAX * 4 * 3), trCol = new Float32Array(TR_MAX * 4 * 3);
{
  const idx = new Uint32Array(TR_MAX * 6);
  for (let q = 0; q < TR_MAX; q++) idx.set([q * 4, q * 4 + 1, q * 4 + 2, q * 4, q * 4 + 2, q * 4 + 3], q * 6);
  trGeo.setIndex(new THREE.BufferAttribute(idx, 1));
}
trGeo.setAttribute('position', new THREE.BufferAttribute(trPos, 3).setUsage(THREE.DynamicDrawUsage));
trGeo.setAttribute('color', new THREE.BufferAttribute(trCol, 3).setUsage(THREE.DynamicDrawUsage));
const trMesh = new THREE.Mesh(trGeo, new THREE.MeshBasicMaterial({ vertexColors: true, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, fog: false, side: THREE.DoubleSide }));
trMesh.frustumCulled = false; trMesh.renderOrder = 4;
scene.add(trMesh);
const TR_COL = [[2.6, 0.35, 0.25], [2.4, 1.9, 0.7], [0.7, 2.4, 0.8]];
function updateTracers() {
  const n = PR.n;
  for (let k = 0; k < n; k++) {
    const x = PR.x[k], z = PR.z[k], dx = PR.dx[k], dz = PR.dz[k];
    const len = Math.min(2.4, PR.spd[k] * 0.028), w = PR.col[k] === 0 ? 0.075 : 0.05;
    const tx = x - dx * len, tz = z - dz * len, px = -dz * w, pz = dx * w, y = 1.2 + groundY(x, z);
    const o = k * 12;
    trPos[o] = x + px; trPos[o + 1] = y; trPos[o + 2] = z + pz;
    trPos[o + 3] = x - px; trPos[o + 4] = y; trPos[o + 5] = z - pz;
    trPos[o + 6] = tx - px; trPos[o + 7] = y; trPos[o + 8] = tz - pz;
    trPos[o + 9] = tx + px; trPos[o + 10] = y; trPos[o + 11] = tz + pz;
    const c = TR_COL[PR.col[k]];
    trCol[o] = c[0]; trCol[o + 1] = c[1]; trCol[o + 2] = c[2]; trCol[o + 3] = c[0]; trCol[o + 4] = c[1]; trCol[o + 5] = c[2];
    trCol[o + 6] = trCol[o + 7] = trCol[o + 8] = trCol[o + 9] = trCol[o + 10] = trCol[o + 11] = 0;
  }
  trGeo.setDrawRange(0, n * 6);
  markRange(trGeo.attributes.position, 0, n * 12); markRange(trGeo.attributes.color, 0, n * 12);
}

// ---------- cryo beam ribbon ----------
const beamMat = new THREE.ShaderMaterial({
  uniforms: { uTex: { value: TEX.streak }, uTime: { value: 0 }, uI: { value: 0 } },
  vertexShader: `varying vec2 vUv; void main() { vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`,
  fragmentShader: `uniform sampler2D uTex; uniform float uTime; uniform float uI; varying vec2 vUv;
    void main() { float across = 1.0 - abs(vUv.y * 2.0 - 1.0);
      float n = texture2D(uTex, vec2(vUv.x * 0.9 - uTime * 3.2, vUv.y)).r + texture2D(uTex, vec2(vUv.x * 0.5 - uTime * 1.7, vUv.y * 0.7 + 0.2)).r;
      float core = pow(across, 3.0) * 1.4;
      float fade = smoothstep(0.0, 0.08, vUv.x) * (1.0 - smoothstep(0.75, 1.0, vUv.x));
      vec3 c = vec3(0.45, 0.85, 1.25) * (across * n * 0.9 + core) * fade * uI;
      gl_FragColor = vec4(c, 1.0);
      ${TONE_TAIL} }`,
  transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, side: THREE.DoubleSide,
});
const beamGeo = new THREE.PlaneGeometry(1, 1, 8, 1);
const beamMesh = new THREE.Mesh(beamGeo, beamMat);
beamMesh.frustumCulled = false; beamMesh.visible = false; beamMesh.renderOrder = 4;
scene.add(beamMesh);
const beamBase = Float32Array.from(beamGeo.attributes.position.array);
function updateBeam(m, len) {
  // stretch the plane along the aim: x in [-0.5,0.5] -> [0,len], width grows along the beam
  const p = beamGeo.attributes.position, uvs = beamGeo.attributes.uv;
  const mp = muzzlePos(m), ox = mp[0], oz = mp[1], my = m.mesh.position.y;
  for (let i = 0; i < p.count; i++) {
    const u = beamBase[i * 3] + 0.5, v = beamBase[i * 3 + 1];
    const along = u * len, w = (0.35 + u * 0.95) * v * 2;
    p.setXYZ(i, ox + m.ax * along + m.az * w, my + 1.2 - u * 0.7, oz + m.az * along - m.ax * w);
    uvs.setX(i, u);
  }
  p.needsUpdate = true; uvs.needsUpdate = true;
}

// ---------- telegraphs (rings, filling acid discs, brute charge lanes) ----------
const TELE_MAX = 64, LANE_MAX = 16, FILL_MAX = 32;
function teleMesh(map, n) {
  const tm = new THREE.InstancedMesh(new THREE.PlaneGeometry(1, 1).rotateX(-Math.PI / 2), new THREE.MeshBasicMaterial({ map, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, fog: false }), n);
  tm.instanceColor = new THREE.InstancedBufferAttribute(new Float32Array(n * 3), 3);
  tm.count = 0; tm.frustumCulled = false; tm.renderOrder = 3; scene.add(tm);
  return tm;
}
const teleRingMesh = teleMesh(TEX.ring, TELE_MAX), teleLaneMesh = teleMesh(TEX.lane, LANE_MAX), teleFillMesh = teleMesh(TEX.fill, FILL_MAX);
const TELE = [];
for (let k = 0; k < TELE_MAX + LANE_MAX + FILL_MAX; k++) TELE.push({ on: false, kind: 0, x: 0, z: 0, y: 0, y1: 0, dx: 0, dz: 0, r0: 1, r1: 1, w: 1, len: 1, r: 1, g: 1, b: 1, t: 0, life: 1, wind: 0, pulse: true });
function teleAlloc() { for (const e of TELE) if (!e.on) return e; return null; }
// kind 0: ring (pulsing warning or expanding shock ring)
function teleRing(x, z, r, cr, cg, cb, life, r1 = r, pulse = true) {
  const e = teleAlloc(); if (!e) return;
  Object.assign(e, { on: true, kind: 0, x, z, y: groundY(x, z), r0: r, r1, r: cr, g: cg, b: cb, t: 0, life, pulse });
}
// kind 2: disc that fills up as the impact approaches (acid globs) — the countdown is readable at a glance
function teleFill(x, z, r, cr, cg, cb, life) {
  const e = teleAlloc(); if (!e) return;
  Object.assign(e, { on: true, kind: 2, x, z, y: groundY(x, z), r0: r, r1: r, r: cr, g: cg, b: cb, t: 0, life, pulse: false });
}
// kind 1: brute charge lane — pulses during the wind-up, stays lit while the brute charges along it
function teleLane(x, z, dx, dz, len, w, wind, charge) {
  const e = teleAlloc(); if (!e) return;
  Object.assign(e, { on: true, kind: 1, x, z, y: groundY(x, z), y1: groundY(x + dx * len, z + dz * len), dx, dz, len, w, r: 1.0, g: 0.18, b: 0.1, t: 0, life: wind + charge, wind, pulse: true });
}
function updateTelegraphs(dt, time) {
  let nr = 0, nl = 0, nf = 0;
  const blink = 0.55 + 0.45 * Math.sin(time * 18);
  for (const e of TELE) {
    if (!e.on) continue;
    e.t += dt;
    if (e.t >= e.life) { e.on = false; continue; }
    const u = e.t / e.life;
    if (e.kind === 1) {
      if (nl >= LANE_MAX) continue;
      const inten = e.t < e.wind ? blink * Math.min(1, e.t / e.wind * 4 + 0.3) * (0.8 + 0.5 * e.t / e.wind) : 1.3 * (1 - (e.t - e.wind) / (e.life - e.wind));
      const a = teleLaneMesh.instanceMatrix.array, o = nl * 16, th = Math.atan2(-e.dx, -e.dz), c = Math.cos(th), s = Math.sin(th);
      const cx = e.x + e.dx * e.len / 2, cz = e.z + e.dz * e.len / 2;
      a[o] = c * e.w; a[o + 1] = 0; a[o + 2] = -s * e.w; a[o + 3] = 0; a[o + 4] = 0; a[o + 5] = 1; a[o + 6] = 0; a[o + 7] = 0;
      a[o + 8] = s * e.len; a[o + 9] = e.y - e.y1; a[o + 10] = c * e.len; a[o + 11] = 0; a[o + 12] = cx; a[o + 13] = (e.y + e.y1) * 0.5 + 0.06; a[o + 14] = cz; a[o + 15] = 1;
      const ca = teleLaneMesh.instanceColor.array; ca[nl * 3] = e.r * inten; ca[nl * 3 + 1] = e.g * inten; ca[nl * 3 + 2] = e.b * inten;
      nl++;
    } else if (e.kind === 2) {
      if (nf >= FILL_MAX) continue;
      const rad = e.r0 * (0.12 + 0.88 * u) * 2, inten = (0.3 + 0.7 * u) * (u > 0.75 ? blink * 1.3 : 1);
      const a = teleFillMesh.instanceMatrix.array, o = nf * 16;
      a.fill(0, o, o + 16); a[o] = rad; a[o + 5] = 1; a[o + 10] = rad; a[o + 12] = e.x; a[o + 13] = e.y + 0.055; a[o + 14] = e.z; a[o + 15] = 1;
      const ca = teleFillMesh.instanceColor.array; ca[nf * 3] = e.r * inten; ca[nf * 3 + 1] = e.g * inten; ca[nf * 3 + 2] = e.b * inten;
      nf++;
    } else {
      if (nr >= TELE_MAX) continue;
      const inten = e.pulse ? blink * Math.min(1, u * 4 + 0.3) : 1 - u;
      const rad = lerp(e.r0, e.r1, smooth01(u)) * 2;
      const a = teleRingMesh.instanceMatrix.array, o = nr * 16;
      a.fill(0, o, o + 16); a[o] = rad; a[o + 5] = 1; a[o + 10] = rad; a[o + 12] = e.x; a[o + 13] = e.y + 0.05; a[o + 14] = e.z; a[o + 15] = 1;
      const ca = teleRingMesh.instanceColor.array; ca[nr * 3] = e.r * inten; ca[nr * 3 + 1] = e.g * inten; ca[nr * 3 + 2] = e.b * inten;
      nr++;
    }
  }
  teleRingMesh.count = nr; teleLaneMesh.count = nl; teleFillMesh.count = nf;
  for (const tm of [teleRingMesh, teleLaneMesh, teleFillMesh]) tm.instanceMatrix.needsUpdate = tm.instanceColor.needsUpdate = true;
}

// ---------- floor light splashes: muzzle flashes, flames and blasts lighting the deck (no extra lights) ----------
const SPLASH_MAX = 40;
const splashMesh = teleMesh(TEX.glow, SPLASH_MAX);
splashMesh.renderOrder = 2;
const SPL = [];
for (let k = 0; k < 16; k++) SPL.push({ on: false, x: 0, z: 0, s: 1, r: 1, g: 1, b: 1, t: 0, life: 1 });
let splN = 0;
// persistent splash that fades out over `life`
function splash(x, z, size, r, g, b, life) {
  let e = SPL[0];
  for (const s of SPL) { if (!s.on) { e = s; break; } if (s.t / s.life > e.t / e.life) e = s; }
  Object.assign(e, { on: true, x, z, s: size, r, g, b, t: 0, life });
}
// one-frame splash (continuous emitters re-add it every frame)
function splashNow(x, z, size, r, g, b) {
  if (splN >= SPLASH_MAX) return;
  const c0 = cellOf(x, z);
  if (c0 < 0 || !walk[c0]) return;
  const gz = hgz[c0], gy = groundY(x, z) + 0.04 + (stairCell[c0] ? 0.08 : 0);
  const a = splashMesh.instanceMatrix.array, o = splN * 16;
  a[o] = size; a[o + 1] = 0; a[o + 2] = 0; a[o + 3] = 0; a[o + 4] = 0; a[o + 5] = 1; a[o + 6] = 0; a[o + 7] = 0;
  a[o + 8] = 0; a[o + 9] = gz * size; a[o + 10] = size; a[o + 11] = 0; a[o + 12] = x; a[o + 13] = gy; a[o + 14] = z; a[o + 15] = 1;
  const ca = splashMesh.instanceColor.array; ca[splN * 3] = r; ca[splN * 3 + 1] = g; ca[splN * 3 + 2] = b;
  splN++;
}
function updateSplashes(dt) {
  for (const e of SPL) {
    if (!e.on) continue;
    e.t += dt;
    if (e.t >= e.life) { e.on = false; continue; }
    const k = (1 - e.t / e.life) ** 2;
    splashNow(e.x, e.z, e.s * (0.8 + 0.2 * e.t / e.life), e.r * k, e.g * k, e.b * k);
  }
  splashMesh.count = splN;
  splashMesh.instanceMatrix.needsUpdate = splashMesh.instanceColor.needsUpdate = true;
}

// ---------- small instanced objects: globs, grenades, medkits ----------
function instPool(geo, mat, n) { const m = new THREE.InstancedMesh(geo, mat, n); m.count = 0; m.frustumCulled = false; scene.add(m); return m; }
const globMesh = instPool(new THREE.IcosahedronGeometry(0.22, 1), new THREE.MeshBasicMaterial({ color: 0xc8ff3a, fog: false }), GLMAX);
const grenMesh = instPool(new THREE.IcosahedronGeometry(0.14, 1), new THREE.MeshBasicMaterial({ color: 0xffc040, fog: false }), 12);
const medGeo = (() => {
  const parts = [];
  pBox(parts, 0.62, 0.36, 0.44, 0, 0.18, 0, 0xd8dde2);
  pBox(parts, 0.42, 0.06, 0.12, 0, 0.37, 0, 0x39ff7a, 2.4);
  pBox(parts, 0.12, 0.06, 0.32, 0, 0.37, 0, 0x39ff7a, 2.4);
  return mergeGeometries(parts);
})();
const medMesh = instPool(medGeo, MAT.props, MED.length);
const _m4 = new THREE.Matrix4(), _q = new THREE.Quaternion(), _v3 = new THREE.Vector3(), _s3 = new THREE.Vector3(1, 1, 1), _yAxis = new THREE.Vector3(0, 1, 0);
function setInst(mesh, k, x, y, z, rotY = 0, s = 1) {
  _q.setFromAxisAngle(_yAxis, rotY); _v3.set(x, y, z); _s3.set(s, s, s);
  _m4.compose(_v3, _q, _s3); mesh.setMatrixAt(k, _m4);
}

// ---------- team rings under marines (readability inside the swarm) ----------
const teamRings = new THREE.InstancedMesh(new THREE.PlaneGeometry(1, 1).rotateX(-Math.PI / 2), new THREE.MeshBasicMaterial({ map: TEX.ring, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, fog: false }), 4);
teamRings.instanceColor = new THREE.InstancedBufferAttribute(new Float32Array(12), 3);
teamRings.frustumCulled = false; teamRings.renderOrder = 2; teamRings.count = 0;
scene.add(teamRings);
function updateTeamRings() {
  let n = 0;
  for (const m of M) {
    if (m.downed) continue;
    const s = m.isPlayer ? 1.9 : 1.5, y = m.mesh.position.y + 0.035;
    setInst(teamRings, n, m.mesh.position.x, y, m.mesh.position.z, 0, s);
    _lc.setHex(m.C.laser);
    const k = m.isPlayer ? 0.55 : 0.32, ca = teamRings.instanceColor.array;
    ca[n * 3] = _lc.r * k; ca[n * 3 + 1] = _lc.g * k; ca[n * 3 + 2] = _lc.b * k;
    n++;
  }
  teamRings.count = n; teamRings.instanceMatrix.needsUpdate = true; teamRings.instanceColor.needsUpdate = true;
}

// ---------- turret ----------
const turret = new THREE.Group();
{
  const base = [], head = [];
  for (let k = 0; k < 3; k++) { const a = k / 3 * TAU; const g = new THREE.BoxGeometry(0.08, 0.8, 0.08); g.rotateZ(0.5); g.rotateY(a); g.translate(Math.cos(a) * 0.25, 0.35, -Math.sin(a) * 0.25); base.push(paint(g, 0x30363c)); }
  pCyl(base, 0.16, 0.2, 0.3, 8, 0, 0.7, 0, 0x3e5a32);
  pBox(head, 0.36, 0.26, 0.5, 0, 0, 0, 0x3e5a32);
  pBox(head, 0.08, 0.08, 0.7, -0.08, 0, 0.45, 0x22272c); pBox(head, 0.08, 0.08, 0.7, 0.08, 0, 0.45, 0x22272c);
  pBox(head, 0.2, 0.05, 0.05, 0, 0.1, 0.26, 0x3cff58, 2.5);
  const b = new THREE.Mesh(mergeGeometries(base), MAT.props), h = new THREE.Mesh(mergeGeometries(head), MAT.props);
  h.position.y = 0.95;
  turret.add(b, h); turret.userData.head = h; turret.visible = false;
  scene.add(turret);
}

// ---------- beacons, lift and revive floor indicators ----------
const ringIndMat = new THREE.ShaderMaterial({
  uniforms: { uProg: { value: 0 }, uCol: { value: new THREE.Color(0.25, 0.9, 0.85) }, uTime: { value: 0 }, uAlpha: { value: 1 } },
  vertexShader: `varying vec2 vUv; void main() { vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`,
  fragmentShader: `uniform float uProg; uniform vec3 uCol; uniform float uTime; uniform float uAlpha; varying vec2 vUv;
    void main() { vec2 p = vUv * 2.0 - 1.0; float r = length(p);
      float ang = fract(atan(p.x, p.y) / 6.2831853 + 1.0);
      float ring = smoothstep(0.84, 0.865, r) * (1.0 - smoothstep(0.955, 0.98, r));
      float seg = step(0.3, fract(ang * 40.0));
      float prog = step(ang, uProg);
      float inner = (1.0 - smoothstep(0.0, 0.86, r)) * 0.05 * (0.6 + 0.4 * sin(uTime * 3.0 - r * 8.0));
      float sweep = smoothstep(0.86, 0.0, abs(r - fract(uTime * 0.5) * 0.86)) * 0.12 * step(r, 0.86);
      vec3 c = uCol * (ring * (prog * 1.7 + (1.0 - prog) * 0.35 * seg) + inner + sweep * (1.0 - step(0.999, uProg)));
      gl_FragColor = vec4(c * uAlpha, 1.0);
      ${TONE_TAIL} }`,
  transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, side: THREE.DoubleSide,
});
function makeIndicator(r) {
  const mat = ringIndMat.clone();
  mat.uniforms.uCol.value = new THREE.Color(0.25, 0.9, 0.85);
  const m = new THREE.Mesh(new THREE.PlaneGeometry(r * 2, r * 2).rotateX(-Math.PI / 2), mat);
  m.renderOrder = 3; m.frustumCulled = false;
  scene.add(m);
  return m;
}
const beaconFx = LV.beacons.map((b) => {
  const gy = groundY(b.x, b.z);
  const ind = makeIndicator(4.6); ind.position.set(b.x, gy + 0.04, b.z);
  const top = new THREE.Mesh(new THREE.OctahedronGeometry(0.42, 0), new THREE.MeshBasicMaterial({ color: 0xff3020, fog: false }));
  top.position.set(b.x, gy + 2.9, b.z); scene.add(top);
  const beam = new THREE.Mesh(new THREE.CylinderGeometry(0.35, 0.35, 60, 12, 1, true), new THREE.ShaderMaterial({
    uniforms: { uCol: { value: new THREE.Color(0.2, 1, 0.9) }, uI: { value: 0 } },
    vertexShader: 'varying float vY; void main() { vY = uv.y; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }',
    fragmentShader: `uniform vec3 uCol; uniform float uI; varying float vY; void main() { gl_FragColor = vec4(uCol * uI * (1.0 - vY) * (1.0 - vY), 1.0); ${TONE_TAIL} }`,
    transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, side: THREE.DoubleSide,
  }));
  beam.position.set(b.x, gy + 30, b.z); beam.frustumCulled = false; scene.add(beam);
  return { ind, top, beam, gy };
});
const liftInd = makeIndicator(LV.lift.r - 0.3);
liftGroup.add(liftInd); liftInd.position.set(LV.lift.x, LIFT_Y + 0.06, LV.lift.z);
const reviveInd = [0, 1, 2, 3].map(() => { const m = makeIndicator(1.5); m.visible = false; return m; });

// ---------- weather: GPU-animated snowfall + motes rising from the abyss ----------
const SNOW_MAX = 1300;
const snowGeo = new THREE.BufferGeometry();
{
  const p = new Float32Array(SNOW_MAX * 3), s = new Float32Array(SNOW_MAX);
  for (let i = 0; i < SNOW_MAX; i++) { p[i * 3] = rr(-24, 24); p[i * 3 + 1] = rr(0, 18); p[i * 3 + 2] = rr(-24, 24); s[i] = rnd(); }
  snowGeo.setAttribute('position', new THREE.BufferAttribute(p, 3));
  snowGeo.setAttribute('aSeed', new THREE.BufferAttribute(s, 1));
}
const snowMat = new THREE.ShaderMaterial({
  uniforms: { uTime: { value: 0 }, uCenter: { value: new THREE.Vector3() }, uScale: { value: 400 } },
  vertexShader: `attribute float aSeed; uniform float uTime; uniform vec3 uCenter; uniform float uScale; varying float vA;
    void main() { vec3 p = position;
      p.y = mod(p.y - uTime * (1.1 + aSeed * 0.9), 18.0) - 1.0 + uCenter.y;
      p.x += sin(uTime * 0.8 + aSeed * 40.0) * 0.5 + uTime * 1.6;
      p.z += cos(uTime * 0.6 + aSeed * 30.0) * 0.4 + uTime * 0.7;
      p.x = mod(p.x - uCenter.x + 24.0, 48.0) - 24.0 + uCenter.x;
      p.z = mod(p.z - uCenter.z + 24.0, 48.0) - 24.0 + uCenter.z;
      vec4 mv = modelViewMatrix * vec4(p, 1.0); gl_Position = projectionMatrix * mv;
      gl_PointSize = clamp((0.025 + aSeed * 0.04) * uScale / -mv.z, 1.0, 7.0);
      vA = 0.35 + aSeed * 0.45; }`,
  fragmentShader: `varying float vA; void main() { float d = length(gl_PointCoord - 0.5) * 2.0; gl_FragColor = vec4(0.85, 0.9, 1.0, vA * smoothstep(1.0, 0.2, d)); ${TONE_TAIL} }`,
  transparent: true, depthWrite: false,
});
const snow = new THREE.Points(snowGeo, snowMat);
snow.frustumCulled = false; snow.renderOrder = 5;
scene.add(snow);
// low drifting mist banks (GPU animated, alpha blended; disabled on low)
const MIST_N = 26;
const mistGeo = new THREE.BufferGeometry();
{
  const p = new Float32Array(MIST_N * 3), s = new Float32Array(MIST_N), R = mulberry32(17);
  for (let i = 0; i < MIST_N; i++) { p[i * 3] = R() * 60 - 30; p[i * 3 + 1] = 0.4 + R() * 1.4; p[i * 3 + 2] = R() * 60 - 30; s[i] = R(); }
  mistGeo.setAttribute('position', new THREE.BufferAttribute(p, 3));
  mistGeo.setAttribute('aSeed', new THREE.BufferAttribute(s, 1));
}
const mistMat = new THREE.ShaderMaterial({
  uniforms: { uTime: { value: 0 }, uCenter: { value: new THREE.Vector3() }, uScale: { value: 400 } },
  vertexShader: `attribute float aSeed; uniform float uTime; uniform vec3 uCenter; uniform float uScale; varying float vA; varying float vS;
    void main() { vec3 p = position; p.y += uCenter.y;
      p.x += uTime * (0.35 + aSeed * 0.3); p.z += uTime * 0.12;
      p.x = mod(p.x - uCenter.x + 30.0, 60.0) - 30.0 + uCenter.x;
      p.z = mod(p.z - uCenter.z + 30.0, 60.0) - 30.0 + uCenter.z;
      vec4 mv = modelViewMatrix * vec4(p, 1.0); gl_Position = projectionMatrix * mv;
      gl_PointSize = clamp((6.0 + aSeed * 6.0) * uScale / -mv.z, 8.0, 180.0);
      vA = (0.07 + 0.05 * sin(uTime * 0.3 + aSeed * 20.0)) * 1.4; vS = aSeed; }`,
  fragmentShader: `varying float vA; varying float vS;
    void main() { vec2 q = gl_PointCoord - 0.5; float d = length(q) * 2.0;
      float n = 0.75 + 0.25 * sin(q.x * 9.0 + vS * 30.0) * sin(q.y * 7.0 - vS * 17.0);
      gl_FragColor = vec4(0.62, 0.72, 0.84, vA * n * smoothstep(1.0, 0.1, d));
      ${TONE_TAIL} }`,
  transparent: true, depthWrite: false,
});
const mist = new THREE.Points(mistGeo, mistMat);
mist.frustumCulled = false; mist.renderOrder = 6;
scene.add(mist);
const MOTE_N = 420;
const moteGeo = new THREE.BufferGeometry();
{
  const p = new Float32Array(MOTE_N * 3), s = new Float32Array(MOTE_N), R = mulberry32(41);
  for (let i = 0; i < MOTE_N; i++) { p[i * 3] = -50 + R() * 95; p[i * 3 + 1] = -6 - R() * 40; p[i * 3 + 2] = -58 + R() * 100; s[i] = R(); }
  moteGeo.setAttribute('position', new THREE.BufferAttribute(p, 3));
  moteGeo.setAttribute('aSeed', new THREE.BufferAttribute(s, 1));
}
const moteMat = new THREE.ShaderMaterial({
  uniforms: { uTime: { value: 0 }, uScale: { value: 400 } },
  vertexShader: `attribute float aSeed; uniform float uTime; uniform float uScale; varying float vA;
    void main() { vec3 p = position; p.x += sin(uTime * 0.3 + aSeed * 20.0) * 0.8; p.z += cos(uTime * 0.25 + aSeed * 13.0) * 0.8;
      vec4 mv = modelViewMatrix * vec4(p, 1.0); gl_Position = projectionMatrix * mv;
      gl_PointSize = clamp((0.12 + aSeed * 0.2) * uScale / -mv.z, 1.0, 8.0);
      vA = (0.4 + 0.6 * sin(uTime * (1.0 + aSeed * 2.0) + aSeed * 50.0)) * smoothstep(-48.0, -8.0, p.y); }`,
  fragmentShader: `varying float vA; void main() { float d = length(gl_PointCoord - 0.5) * 2.0; gl_FragColor = vec4(1.0, 0.2, 0.45, max(vA, 0.0) * smoothstep(1.0, 0.0, d)); ${TONE_TAIL} }`,
  transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, side: THREE.DoubleSide,
});
const motes = new THREE.Points(moteGeo, moteMat);
motes.frustumCulled = false;
scene.add(motes);

// ---------- light pool + camera shake ----------
function flashLight(x, y, z, color, peak, dur) {
  // phones have no flash lights in the pool: the floor splash carries the blast light on the deck
  if (plights.length < 2) { splash(x, z, 5 + Math.sqrt(peak) * 0.25, ((color >> 16) & 255) / 640, ((color >> 8) & 255) / 640, (color & 255) / 640, dur); return; }
  let best = plights[1];
  for (let k = 1; k < plights.length; k++) if (plights[k].light.intensity < best.light.intensity) best = plights[k];
  best.light.position.set(x, y + groundY(x, z), z); best.light.color.setHex(color); best.peak = peak; best.t = 0; best.dur = dur;
}
let shake = 0;
function addShake(a) { shake = Math.min(1.4, shake + a * (REDUCED_MOTION ? 0.35 : 1)); }
// hit-stop: a few frames of slow motion on heavy impacts (brute kills, close blasts, the player going down)
let hsT = 0, hsK = 1, hsCd = 0;
function hitStop(dur, k) {
  if (GS.attract || simOnly || hsCd > 0) return;
  hsT = Math.max(hsT, dur); hsK = Math.min(hsK, k); hsCd = dur + 0.8;   // rare enough to never feel like stutter
}

// ---------- effect events ----------
// stain tints (multiplied over the floor) and the ichor droplet colours
const ICHOR = [[0.62, 0.1, 0.22], [0.5, 0.58, 0.1], [0.58, 0.12, 0.15], [0.62, 0.24, 0.08]];
const ICHOR_P = [[0.3, 0.05, 0.14], [0.28, 0.32, 0.04], [0.26, 0.06, 0.08], [0.32, 0.12, 0.04]];
function fxBugDeath(i, frozen) {
  const x = B.x[i], z = B.z[i], ty = B.type[i], sc = B.sc[i];
  if (frozen) {
    for (let k = 0; k < 8 * fxK; k++) PA.emit(x, 0.4, z, rr(-3, 3), rr(1, 4), rr(-3, 3), rr(0.25, 0.5), 0.2, 0.04, 0.35, 0.6, 0.8, 1, 9, 1, 3);
    addDecal(x, z, sc * 0.8, 0, 0.72, 0.84, 0.98);   // round, faint cold stain (no white ghost streaks)
    sfx('shatter', x, z);
    return;
  }
  const c = ICHOR[ty], cp = ICHOR_P[ty];
  // bright pop at the moment of death, then ichor + chitin shards
  PA.emit(x, 0.35 * sc + B.y[i], z, 0, 0.6, 0, 0.11, 0.7 * sc, 1.5 * sc, 1.0, 0.45, 0.7, 0.85, 0, 0, 3);
  for (let k = 0; k < (ty === BRUTE ? 9 : 2) * fxK; k++) PN.emit(x, 0.4 + B.y[i], z, rr(-3.2, 3.2), rr(2, 5.5), rr(-3.2, 3.2), rr(0.5, 0.9), rr(0.08, 0.15) * (ty === BRUTE ? 1.6 : 1), 0.07, 0.13, 0.07, 0.11, 1, 15, 0.4, 0);
  if (ty === BRUTE) { sfx('thud', x, z); splash(x, z, 4, 0.3, 0.06, 0.16, 0.35); }
  addDecal(x, z, sc * rr(1.0, 1.5), rnd() < 0.5 ? 0 : 1, c[0], c[1], c[2]);
  if (ty !== BOOM) addCorpse(x, z, B.hd[i], sc, ty);
  else addDecal(x, z, 2.6, 3, 0.1, 0.08, 0.08);
  const n = (ty === BRUTE ? 14 : 5) * fxK;
  for (let k = 0; k < n; k++) PN.emit(x, 0.35, z, rr(-2.5, 2.5), rr(1.5, 4), rr(-2.5, 2.5), rr(0.4, 0.8), rr(0.12, 0.22), 0.06, cp[0] * 1.6, cp[1] * 1.6, cp[2] * 1.6, 0.95, 12, 0.5, 0);
  if (ty !== SPIT) for (let k = 0; k < 2 * fxK; k++) PA.emit(x, 0.4, z, rr(-2, 2), rr(1, 3), rr(-2, 2), 0.35, 0.18, 0.05, 1.0, 0.25, 0.5, 1, 8, 0.5, 3);
  sfx('squish', x, z);
}
function fxExplosion(x, z, r, kind) {
  if (kind === 'pulse') {
    teleRing(x, z, 1, 0.2, 1.0, 0.85, 0.45, r, false);
    teleRing(x, z, 1, 0.1, 0.5, 0.45, 0.7, r * 0.95, false);
    for (let k = 0; k < 60 * fxK; k++) { const a = rnd() * TAU; PA.emit(x + Math.cos(a) * r * 0.95, 0.3, z + Math.sin(a) * r * 0.95, Math.cos(a) * 2, rr(1, 4), Math.sin(a) * 2, rr(0.2, 0.45), 0.25, 0.05, 0.4, 1, 0.9, 1, 4, 1, 3); }
    flashLight(x, 3, z, 0x40ffe0, 380, 0.4);
    splash(x, z, r * 2.4, 0.06, 0.32, 0.28, 0.45);
    sfx('shock', x, z);
    return;
  }
  if (kind === 'frost') {
    for (let k = 0; k < 9 * fxK; k++) { const a = rnd() * TAU, s = rr(2, 6); PA.emit(x, 0.4, z, Math.cos(a) * s, rr(1, 3), Math.sin(a) * s, rr(0.3, 0.6), 0.26, 0.05, 0.45, 0.75, 1.0, 0.9, 6, 1.5, 3); }
    for (let k = 0; k < 3 * fxK; k++) PN.emit(x, 0.4, z, rr(-3, 3), rr(2, 4.5), rr(-3, 3), rr(0.5, 0.8), rr(0.1, 0.16), 0.08, 0.55, 0.75, 0.9, 1, 15, 0.4, 0);
    for (let k = 0; k < 3; k++) PN.emit(x, 0.4, z, rr(-3, 3), rr(2, 4), rr(-3, 3), rr(0.4, 0.7), 0.12, 0.08, 0.75, 0.9, 1.0, 0.95, 15, 0.4, 0);
    return;
  }
  const big = kind !== 'mini';
  const nf = (big ? 26 : 8) * fxK, ns = (big ? 22 : 8) * fxK;
  // additive core: deeper orange, lower alpha, so stacked sprites stay fire-coloured instead of washing out white
  for (let k = 0; k < nf; k++) { const a = rnd() * TAU, s = rr(0.5, r * 1.3); PA.emit(x + Math.cos(a) * 0.3, rr(0.3, 1), z + Math.sin(a) * 0.3, Math.cos(a) * s, rr(0.5, 3), Math.sin(a) * s, rr(0.35, 0.7), rr(0.6, 1.1), rr(1.3, 2.2), 1, 0.55, 0.2, 0.45, -1, 2.2, 1); }
  for (let k = 0; k < ns; k++) { const a = rnd() * TAU, s = rr(6, 16); PA.emit(x, 0.5, z, Math.cos(a) * s, rr(2, 7), Math.sin(a) * s, rr(0.3, 0.7), 0.12, 0.04, 1.0, 0.75, 0.35, 1, 14, 0.6, 3); }
  // normal-blend fireball body: billowing orange cloud
  for (let k = 0; k < (big ? 18 : 6) * fxK; k++) { const a = rnd() * TAU, s = rr(0.5, r); PN.emit(x + Math.cos(a) * 0.5, rr(0.4, 1.2), z + Math.sin(a) * 0.5, Math.cos(a) * s, rr(1, 3), Math.sin(a) * s, rr(0.5, 0.9), rr(1.0, 1.6), rr(2.2, 3.4), 1.0, 0.42, 0.12, 0.85, -1.5, 2.0, 1); }
  // dark smoke rolling up after it
  for (let k = 0; k < (big ? 16 : 4) * fxK; k++) PN.emit(x + rr(-1, 1), rr(0.5, 1.5), z + rr(-1, 1), rr(-1.2, 1.2), rr(1, 2.5), rr(-1.2, 1.2), rr(1.6, 2.6), 1.6, 4.2, 0.06, 0.055, 0.06, 0.75, -0.3, 0.8, 2);
  addDecal(x, z, r * (big ? 1.1 : 0.8), 3, 0.08, 0.07, 0.07);
  flashLight(x, 1.6, z, kind === 'boomer' ? 0xff5a20 : 0xff7a30, big ? 220 : 90, big ? 0.5 : 0.25);
  splash(x, z, r * (big ? 2.4 : 2.0), 0.4, 0.14, 0.03, big ? 0.6 : 0.3);
  const P = M[0], d = Math.hypot(P.x - x, P.z - z);
  // shake grows with the blast radius and falls off with distance (reduced, not removed, for reduced motion)
  addShake((big ? 0.11 : 0.06) * r * clamp(1 - d / 26, 0, 1));
  if (big && d < 9) { GS.flash = Math.max(GS.flash, 0.25 * (1 - d / 9)); if (kind === 'frag' ? d < 8 : d < 3.5) hitStop(0.05, 0.3); haptic('medium'); }
  sfx(big ? 'explode' : 'pop', x, z);
}
function fxAcid(x, z) {
  for (let k = 0; k < 9 * fxK; k++) PA.emit(x, 0.2, z, rr(-2.5, 2.5), rr(1, 3.5), rr(-2.5, 2.5), rr(0.3, 0.6), 0.2, 0.05, 0.7, 1.0, 0.15, 1, 8, 1, 3);
  for (let k = 0; k < 4 * fxK; k++) PN.emit(x + rr(-0.6, 0.6), 0.2, z + rr(-0.6, 0.6), 0, rr(0.4, 1), 0, rr(0.8, 1.4), 0.5, 1.4, 0.4, 0.55, 0.15, 0.35, -0.2, 1, 2);
  addDecal(x, z, rr(1.6, 2.1), 0, 0.42, 0.6, 0.06);
  sfx('acid', x, z);
}
function fxBulletHit(x, z, dx, dz, killed) {
  if (rnd() > 0.6 * fxK + 0.2) return;
  PA.emit(x, 0.45, z, -dx * rr(2, 5) + rr(-2, 2), rr(1, 3), -dz * rr(2, 5) + rr(-2, 2), 0.18, 0.14, 0.04, 1.0, 0.75, 0.4, 1, 10, 1, 3);
  if (killed || rnd() < 0.4) PN.emit(x, 0.4, z, rr(-1.5, 1.5) + dx * 2, rr(1, 2.5), rr(-1.5, 1.5) + dz * 2, 0.4, 0.13, 0.05, 0.45, 0.08, 0.2, 0.9, 10, 0.5, 0);
}
function fxDash(m) {
  for (let k = 0; k < 12 * fxK; k++) PA.emit(m.x + rr(-0.3, 0.3), rr(0.3, 1.5), m.z + rr(-0.3, 0.3), -m.dashX * rr(1, 4), rr(0, 1), -m.dashZ * rr(1, 4), rr(0.2, 0.4), 0.35, 0.05, 0.3, 0.9, 0.85, 0.6, 0, 3, 0);
  for (let k = 0; k < 5 * fxK; k++) PN.emit(m.x, 0.15, m.z, rr(-1.5, 1.5), rr(0.3, 1), rr(-1.5, 1.5), rr(0.5, 0.9), 0.4, 1.3, 0.75, 0.8, 0.88, 0.4, -0.2, 2, 2);
}
function fxNapalmBurst(x, z, r) {
  // a rolling ring of fire, not a white-out: deeper orange sprites at lower alpha, a softer flash
  for (let k = 0; k < 70 * fxK; k++) { const a = rnd() * TAU, s = rr(r * 0.6, r * 1.6); PA.emit(x, 0.5, z, Math.cos(a) * s, rr(0.5, 2), Math.sin(a) * s, rr(0.4, 0.8), 0.6, 2.0, 1, 0.6, 0.22, 0.55, -1, 1.6, 1); }
  flashLight(x, 1.5, z, 0xff6a20, 200, 0.6);
  splash(x, z, r * 2.4, 0.38, 0.14, 0.03, 0.7);
  teleRing(x, z, r, 1.0, 0.32, 0.06, 5, r, false);   // the burning edge lies on the deck for the whole burn
  addShake(0.3);
  addDecal(x, z, r * 1.8, 3, 0.12, 0.08, 0.06);
}
function fxNova(x, z, r) {
  teleRing(x, z, 0.5, 0.3, 0.6, 0.8, 0.55, r, false);
  teleRing(x, z, 0.5, 0.15, 0.35, 0.6, 0.8, r * 0.9, false);
  for (let k = 0; k < 70 * fxK; k++) { const a = rnd() * TAU, s = rr(r * 0.8, r * 2.2); PA.emit(x, rr(0.2, 1), z, Math.cos(a) * s, rr(0.2, 2), Math.sin(a) * s, rr(0.4, 0.8), rr(0.2, 0.45), 0.05, 0.3, 0.55, 0.8, 1, 1, 2.5, 3); }
  flashLight(x, 2, z, 0x6ad8ff, 120, 0.45);
  splash(x, z, r * 2.4, 0.05, 0.13, 0.22, 0.5);
  addShake(0.35);
}
function fxTurretDrop(x, z) {
  for (let k = 0; k < 16 * fxK; k++) PA.emit(x, 0.5, z, rr(-4, 4), rr(2, 6), rr(-4, 4), rr(0.2, 0.5), 0.12, 0.03, 0.6, 1, 0.6, 1, 14, 0.5, 3);
  for (let k = 0; k < 6 * fxK; k++) PN.emit(x, 0.2, z, rr(-1, 1), rr(0.3, 1), rr(-1, 1), 1, 0.5, 1.6, 0.7, 0.75, 0.82, 0.4, -0.1, 1.5, 2);
}
function fxHeal(m) {
  for (let k = 0; k < 18; k++) PA.emit(m.x + rr(-0.5, 0.5), rr(0.2, 1.4), m.z + rr(-0.5, 0.5), 0, rr(1, 2.5), 0, rr(0.5, 0.9), 0.25, 0.05, 0.3, 1, 0.5, 1, -0.5, 1, 0);
}

// ---------- per-frame visual update ----------
let steamT = 0;
function renderFx(dt, time) {
  splN = 0;
  // emitters tied to ongoing actions
  for (const m of M) {
    if (m.downed) continue;
    const mp = muzzlePos(m), ox = mp[0], oz = mp[1];
    if (m.muzzle > 0 && (m.cls === 'assault' || m.cls === 'gunner')) {
      const c = m.cls === 'assault' ? [1, 0.35, 0.25] : [1, 0.85, 0.4];
      PA.emit(ox, 1.2, oz, m.ax * 2, 0, m.az * 2, 0.05, 0.9, 0.4, c[0], c[1], c[2], 1, 0, 0, 0);
      // spent casings / heat-sink pellets kicked out to the right
      if (m.muzzle > 0.85 && rnd() < (m.isPlayer ? 0.7 : 0.3) * fxK) PN.emit(m.x + m.az * 0.3, 1.1, m.z - m.ax * 0.3, m.az * rr(1.5, 2.6), rr(1.5, 3), -m.ax * rr(1.5, 2.6), rr(0.45, 0.7), 0.06, 0.05, 0.95, 0.68, 0.28, 1, 14, 0.3, 0);
      // the muzzle flash lights the deck around the shooter
      const f = (0.55 + 0.45 * rnd()) * Math.min(1, m.muzzle) * (m.isPlayer ? 0.34 : 0.22);
      splashNow(ox + m.ax * 0.6, oz + m.az * 0.6, 3.6, c[0] * f, c[1] * f, c[2] * f);
    }
    if (m.firing && m.cls === 'pyro') { const f = 0.2 + 0.07 * rnd(); splashNow(ox + m.ax * 3, oz + m.az * 3, 6.5, f, f * 0.45, f * 0.12); }
    if (m.firing && m.cls === 'cryo') { const f = 0.1 + 0.03 * rnd(); splashNow(ox + m.ax * m.beamLen * 0.45, oz + m.az * m.beamLen * 0.45, 5.5, f * 0.45, f * 0.8, f); }
    if (m.firing && m.cls === 'pyro') {
      const n = Math.max(1, Math.round(150 * fxK * dt + rnd() * 0.5));
      for (let k = 0; k < n; k++) {
        const sp = rr(11, 15), sx = rr(-1, 1) * 2.6, sy = rr(-0.2, 1.2);
        PA.emit(ox, 1.15, oz, m.ax * sp - m.az * sx + m.vx * 0.5, sy, m.az * sp + m.ax * sx + m.vz * 0.5, rr(0.42, 0.58), 0.3, rr(1.4, 2.1), 1, 0.78, 0.4, 0.5, -1.5, 1.25, 1);
      }
      if (rnd() < 30 * fxK * dt) PN.emit(ox + m.ax * 6, 1.4, oz + m.az * 6, m.ax * 2, 1.4, m.az * 2, 1.4, 1, 3, 0.09, 0.08, 0.08, 0.4, -0.4, 0.6, 2);
    }
    if (m.firing && m.cls === 'cryo' && rnd() < 40 * fxK * dt) {
      const t = rnd() * m.beamLen;
      PA.emit(ox + m.ax * t, 0.8, oz + m.az * t, rr(-1, 1), rr(-0.5, 1), rr(-1, 1), rr(0.3, 0.6), 0.25, 0.05, 0.6, 0.9, 1, 1, 1, 1, 3);
    }
  }
  for (const n of NAP) {
    if (!n.on) continue;
    { const f = 0.16 + 0.05 * rnd(); splashNow(n.x, n.z, n.r * 2.6, f, f * 0.42, f * 0.1); }
    // a dense, low, continuous burning edge rather than floating orbs
    const cnt = Math.round(240 * fxK * dt * (n.r / 5) + rnd());
    for (let k = 0; k < cnt; k++) { const a = rnd() * TAU, rad = n.r + rr(-0.4, 0.4); PA.emit(n.x + Math.cos(a) * rad, 0.15, n.z + Math.sin(a) * rad, rr(-0.3, 0.3), rr(1.5, 3), rr(-0.3, 0.3), rr(0.3, 0.5), 0.25, 0.9, 1, 0.6, 0.2, 0.6, -1, 1, 1); }
  }
  if (DIR.stage === 'extract' && dt > 0) {
    // the platform tears loose: steam pours off the rim, sparks rain into the shaft
    const L = LV.lift, ry = LIFT_Y + liftGroup.position.y;
    const ns = Math.round(140 * fxK * dt + rnd()), nk = Math.round(90 * fxK * dt + rnd());
    for (let k = 0; k < ns; k++) { const a = rnd() * TAU; PN.emit(L.x + Math.cos(a) * L.r, ry + 0.2, L.z + Math.sin(a) * L.r, Math.cos(a) * 0.6, rr(-2, -0.5), Math.sin(a) * 0.6, 1.2, 0.6, 2.4, 0.8, 0.85, 0.9, 0.35, 0, 0.6, 2, true); }
    for (let k = 0; k < nk; k++) { const a = rnd() * TAU; PA.emit(L.x + Math.cos(a) * (L.r + 0.6), ry - 0.3, L.z + Math.sin(a) * (L.r + 0.6), Math.cos(a) * rr(0.5, 2), rr(-1, 1.5), Math.sin(a) * rr(0.5, 2), rr(0.4, 0.8), 0.14, 0.04, 1.0, 0.7, 0.3, 1, 12, 0.3, 3, true); }
  }
  steamT -= dt;
  if (steamT <= 0) {
    steamT = 0.12;
    for (const [x, z] of LV.vents) if (Math.abs(x - camTarget.x) < 30 && Math.abs(z - camTarget.z) < 30 && rnd() < 0.6) PN.emit(x + rr(-0.4, 0.4), 0.2, z + rr(-0.4, 0.4), rr(-0.3, 0.3) + 0.4, rr(1.2, 2), rr(-0.3, 0.3), rr(2, 3), 0.6, 3.2, 0.8, 0.85, 0.92, 0.22, -0.15, 0.3, 2);
  }
  PA.update(dt); PN.update(dt);
  updateSplashes(dt);
  updateTeamRings();
  flushDecals(); flushCorpses();
  if (DIR.stage === 'extract') fxLiftRise(liftGroup.position.y);
  updateTracers();
  updateTelegraphs(dt, time);
  // laser sights (one ribbon pair per marine + turret)
  laserMat.uniforms.uTime.value = time;
  for (let k = 0; k < 4; k++) {
    const m = M[k];
    if (!m || m.downed) { hideRibbon(k * 2); hideRibbon(k * 2 + 1); continue; }
    const mp = muzzlePos(m), ox = mp[0], oz = mp[1];
    const dist = raycastBugs(ox, oz, m.ax, m.az, 24);
    const hit = rayHit >= 0;
    m.laserLen = dist;
    _lc.setHex(m.C.laser);
    const k2 = m.firing ? 1.6 : 1.0;
    const my = m.mesh.position.y, oy = my + 1.22;
    const ex = ox + m.ax * dist, ez = oz + m.az * dist, ey = hit ? groundY(ex, ez) + Math.max(-0.5, B.y[rayHit]) + 0.5 : my + 0.9;
    setRibbon(k * 2, ox, oy, oz, ex, ey, ez, 0.22, 0.22, _lc.r * 0.5 * k2, _lc.g * 0.5 * k2, _lc.b * 0.5 * k2, hit ? 1 : 0.15, dist);
    setRibbon(k * 2 + 1, ox, oy, oz, ex, ey, ez, 0.055, 0.055, _lc.r * 3 * k2, _lc.g * 3 * k2, _lc.b * 3 * k2, hit ? 1 : 0.15, dist);
    if (hit) PA.emit(ex, ey, ez, 0, 0, 0, 0.04, 0.5, 0.5, _lc.r, _lc.g, _lc.b, 1, 0, 0, 0, true);
  }
  if (TUR.on) {
    const ox = TUR.x + Math.sin(TUR.ang) * 0.75, oz = TUR.z + Math.cos(TUR.ang) * 0.75, ax = Math.sin(TUR.ang), az = Math.cos(TUR.ang);
    const dist = raycastBugs(ox, oz, ax, az, turretRange() + 1), ty = groundY(TUR.x, TUR.z);
    const tex = ox + ax * dist, tez = oz + az * dist;
    setRibbon(9, ox, ty + 1.05, oz, tex, rayHit >= 0 ? groundY(tex, tez) + 0.6 : ty + 0.6, tez, 0.025, 0.025, 0.4, 2.2, 0.6, rayHit >= 0 ? 1 : 0, dist);
    if (TUR.laser > 0) { PA.emit(ox, 1.05, oz, ax * 2, 0, az * 2, 0.05, 0.7, 0.3, 0.5, 1, 0.5, 1, 0, 0, 0); TUR.laser = 0; }
  } else hideRibbon(8), hideRibbon(9);
  laserGeo.attributes.position.needsUpdate = laserGeo.attributes.color.needsUpdate = laserGeo.attributes.uv.needsUpdate = true;
  // cryo beam
  const cryo = cryoIdx >= 0 ? M[cryoIdx] : null;
  beamMesh.visible = !!(cryo && cryo.firing && !cryo.downed);
  if (beamMesh.visible) { updateBeam(cryo, cryo.beamLen); beamMat.uniforms.uTime.value = time; beamMat.uniforms.uI.value = 0.85 + 0.15 * Math.sin(time * 40); }
  // globs, grenades, medkits, turret
  for (let k = 0; k < GL.n; k++) {
    const u = GL.t[k] / GL.dur[k];
    const gx = lerp(GL.x0[k], GL.x1[k], u), gz = lerp(GL.z0[k], GL.z1[k], u);
    const gy = lerp(groundY(GL.x0[k], GL.z0[k]), groundY(GL.x1[k], GL.z1[k]), u) + 0.6 + Math.sin(u * Math.PI) * 3.2;
    setInst(globMesh, k, gx, gy, gz);
    if (rnd() < 0.5) PA.emit(gx, gy, gz, 0, 0, 0, 0.25, 0.3, 0.05, 0.6, 1, 0.15, 0.8, 1, 0, 0, true);
  }
  globMesh.count = GL.n; globMesh.instanceMatrix.needsUpdate = true;
  let gn = 0;
  for (const g of GRN) {
    if (!g.on) continue;
    const u = g.t / g.dur, x = lerp(g.sx, g.tx, u), z = lerp(g.sz, g.tz, u);
    const y = lerp(groundY(g.sx, g.sz), groundY(g.tx, g.tz), u) + 1.2 + Math.sin(u * Math.PI) * (g.big ? 3 : 1.2) - u * 1.0;
    setInst(grenMesh, gn++, x, y, z, 0, g.big ? 1 : 0.7);
    PA.emit(x, y, z, 0, 0, 0, 0.12, 0.25, 0.05, 1, 0.7, 0.3, 0.7, 0, 0, 0, true);
  }
  grenMesh.count = gn; grenMesh.instanceMatrix.needsUpdate = true;
  let mn = 0;
  for (const k of MED) if (k.on && (k.t > 5 || Math.sin(time * 14) > 0)) setInst(medMesh, mn++, k.x, groundY(k.x, k.z) + 0.12 + Math.sin(time * 3 + k.x) * 0.06, k.z, time * 1.5);
  medMesh.count = mn; medMesh.instanceMatrix.needsUpdate = true;
  turret.visible = TUR.on;
  if (TUR.on) { turret.position.set(TUR.x, groundY(TUR.x, TUR.z), TUR.z); turret.userData.head.rotation.y = TUR.ang; }
  // beacons / lift / revive indicators
  for (let k = 0; k < beaconFx.length; k++) {
    const b = DIR.beacons[k], f = beaconFx[k], u = f.ind.material.uniforms;
    u.uTime.value = time; u.uProg.value = b.progress;
    const col = b.state === 2 ? [0.25, 1.0, 0.85] : b.state === 1 ? [1.0, 0.7, 0.15] : [1.0, 0.25, 0.15];
    u.uCol.value.setRGB(col[0], col[1], col[2]);
    u.uAlpha.value = b.state === 2 ? 0.5 : 1;
    f.top.material.color.setRGB(col[0] * 1.6, col[1] * 1.6, col[2] * 1.6);
    f.top.rotation.y = time * (b.state === 1 ? 4 : 1.2);
    f.top.position.y = f.gy + 2.9 + Math.sin(time * 2 + k) * 0.12;
    f.beam.material.uniforms.uI.value = b.state === 2 ? 0.6 : b.state === 1 ? 0.25 + 0.2 * Math.sin(time * 10) : 0;
    f.beam.material.uniforms.uCol.value.setRGB(col[0], col[1], col[2]);
    f.beam.visible = b.state > 0;
  }
  {
    const u = liftInd.material.uniforms;
    u.uTime.value = time;
    const show = DIR.stage === 'toLift' || DIR.stage === 'hold' || DIR.stage === 'extract';
    liftInd.visible = show;
    u.uProg.value = DIR.stage === 'hold' ? 1 - DIR.liftT / DIR.liftDur : DIR.stage === 'extract' ? 1 : 0;
    u.uCol.value.setRGB(0.25, 1.0, 0.85);
    u.uAlpha.value = DIR.stage === 'extract' ? 0.4 + 0.4 * smooth01(DIR.extractT / 2) : 0.4;
  }
  for (let k = 0; k < 4; k++) {
    const m = M[k], ind = reviveInd[k];
    ind.visible = !!(m && m.downed);
    if (!ind.visible) continue;
    ind.position.set(m.x, groundY(m.x, m.z) + 0.06, m.z);
    const u = ind.material.uniforms; u.uTime.value = time; u.uProg.value = m.revive;
    u.uCol.value.setRGB(1.0, 0.25 + m.revive * 0.6, 0.2 + m.revive * 0.6);
  }
  // point lights: [0] follows flames / napalm, [1..2] flashes
  const pl0 = plights[0].light;
  const pyro = pyroIdx >= 0 ? M[pyroIdx] : null;
  const nap = NAP[0].on ? NAP[0] : NAP[1].on ? NAP[1] : NAP[2].on ? NAP[2] : null;
  if (pyro && pyro.firing && !pyro.downed) { pl0.position.set(pyro.x + pyro.ax * 3.5, pyro.mesh.position.y + 1.4, pyro.z + pyro.az * 3.5); pl0.color.setHex(0xff7a28); pl0.intensity = 110 * (0.8 + 0.2 * Math.sin(time * 37)); }
  else if (nap) { pl0.position.set(nap.x, groundY(nap.x, nap.z) + 1.5, nap.z); pl0.color.setHex(0xff6a20); pl0.intensity = 140 * (0.8 + 0.2 * Math.sin(time * 29)); }
  else if (M[0] && !M[0].downed && M[0].muzzle > 0 && (M[0].cls === 'assault' || M[0].cls === 'gunner')) {
    // the player's muzzle flash really lights bugs and props nearby
    const P = M[0], mp = muzzlePos(P);
    pl0.position.set(mp[0] + P.ax * 0.4, P.mesh.position.y + 1.3, mp[1] + P.az * 0.4);
    pl0.color.setHex(P.cls === 'assault' ? 0xff6040 : 0xffc060);
    pl0.intensity = 75 * (0.55 + 0.45 * rnd()) * Math.min(1, P.muzzle + 0.3);
  } else if (M[0] && !M[0].downed && M[0].firing && M[0].cls === 'cryo') {
    const P = M[0];
    pl0.position.set(P.x + P.ax * P.beamLen * 0.5, P.mesh.position.y + 1.2, P.z + P.az * P.beamLen * 0.5);
    pl0.color.setHex(0x60c8ff); pl0.intensity = 60 * (0.85 + 0.15 * Math.sin(time * 40));
  }
  else pl0.intensity = Math.max(0, pl0.intensity - dt * 600);
  for (let k = 1; k < plights.length; k++) {
    const p = plights[k];
    p.t += dt;
    const u = p.t / p.dur;
    p.light.intensity = u < 1 ? p.peak * (1 - u) * (1 - u) : 0;
  }
  // flashlights follow aim
  for (let k = 0; k < 4; k++) {
    const m = M[k], s = spots[k];
    if (!m) { s.intensity = 0; continue; }
    const x = m.mesh.position.x, z = m.mesh.position.z, y = m.mesh.position.y;
    if (m.downed) {
      s.position.set(x, y + 0.6, z); s.target.position.set(x + m.ax * 2, y, z + m.az * 2);
      s.intensity = 12 * (0.6 + 0.4 * Math.sin(time * 9 + k));
    } else {
      s.position.set(x + m.ax * 0.3, y + 1.75, z + m.az * 0.3);
      s.target.position.set(x + m.ax * 9, y, z + m.az * 9);
      s.intensity = (m.isPlayer ? 62 : 42) * (m.firing ? 1.12 : 1) * (m.hurtT > 0 ? 0.6 + 0.4 * Math.sin(time * 60) : 1);
    }
  }
  snowMat.uniforms.uTime.value = time;
  snowMat.uniforms.uCenter.value.set(camTarget.x, camTarget.y, camTarget.z);
  moteMat.uniforms.uTime.value = time;
  mistMat.uniforms.uTime.value = time;
  mistMat.uniforms.uCenter.value.set(camTarget.x, camTarget.y, camTarget.z);
}

function fxApplyQuality() {
  fxK = qName === 'high' ? 1 : qName === 'med' ? 0.7 : 0.4;
  PA.max = Math.min(PA.cap, Q.particles); PN.max = Math.min(PN.cap, Math.round(Q.particles * 0.6));
  PA.n = Math.min(PA.n, PA.max); PN.n = Math.min(PN.n, PN.max);
  if (decRing !== Q.decals) { decRing = Q.decals; decHead = 0; decFill = Math.min(decFill, decRing); }
  for (const C of corpseMeshes) { C.head = 0; C.fill = Math.min(C.fill, Q.corpses); }
  snowGeo.setDrawRange(0, Q.snow);
  mistGeo.setDrawRange(0, qName === 'low' ? 0 : qName === 'med' ? 6 : 14);
  bugShadow.castShadow = bugShadow.visible = Q.shadows; if (!Q.shadows) bugShadow.count = 0;
}
function fxOnResize() {
  for (const m of [PA.mat, PN.mat, snowMat, moteMat, mistMat]) m.uniforms.uScale.value = pxScale;
}
function fxReset() {
  PA.n = 0; PN.n = 0; decHead = 0; decFill = 0; decals.count = 0;
  for (const C of corpseMeshes) { C.head = 0; C.fill = 0; C.mesh.count = 0; }
  for (const e of TELE) e.on = false;
  for (const e of SPL) e.on = false;
  liftDec = liftCor = null; liftRiseLast = -1;
  hsT = 0; hsK = 1; hsCd = 0;
  for (const p of plights) { p.light.intensity = 0; p.peak = 0; }
  shake = 0;
}
