#!/usr/bin/env node
// «Ледяной Улей» v2.0 — exports the web game's real 3D meshes and procedural textures for the Metal renderer.
//
//   node ios-native/tools/export-meshes.mjs              # export + validate + verification render
//   node ios-native/tools/export-meshes.mjs --verify     # only re-validate / re-render what is on disk
//
// Loads game/js/01…09 as ONE module in headless Chromium (lib/gamepage.mjs, same as render-sprites.mjs) and
// appends lib/inpage-meshes.js, which reads the geometry the game itself built (buildBugGeometry, the corpse
// meshes, buildMarineGeos, the level / lift / turret / medkit / glob / grenade meshes) and the TEX.* canvases.
//
// Output: ios-native/App/Resources/Meshes/
//   <name>.mesh      IHM1 binary (below)          <tex>.png   procedural textures (canvas pixels as uploaded)
//   manifest.json    { format, meshes: { name: { file, bounds, vertices, indices, flags, notes, … } },
//                      textures: { name: { file, wrap, srgb, size, notes } }, materials }
// Verification: tools/previews/meshes_verify.png — three.js render built ONLY from the exported files.
//
// IHM1 (little-endian):
//   char[4] "IHM1" · u32 vertexCount · u32 indexCount · u32 flags
//   vertexCount × 52 bytes, tightly packed (no SIMD padding; Metal: packed_float3 or MTLVertexDescriptor offsets
//   0 / 12 / 24 / 36 / 40, stride 52): float3 position · float3 normal · float3 colour (linear) · float aGlow ·
//   float3 aLeg. (The spike brief said "48 bytes", but its own field list is 3+3+3+1+3 = 13 floats = 52 bytes;
//   every field is kept and the stride is also written into flags bits 8…15 so a loader can assert it.)
//   indexCount × u32 (triangle list, counter-clockwise front faces seen from outside — three.js winding)
// flags: bits 8…15 vertex stride in bytes (52)
//        bit0 aGlow used (some vertex glows) · bit1 aLeg holds bug leg data (weight, phase, smudge flag)
//        bit2 aLeg.xy holds a texture uv instead (aLeg.z = 0), v already flipped to a top-left image origin
//             (Metal / PNG row order): sample the PNG at aLeg.xy directly.
// Units: metres, y up, the web game's world space (level meshes are world-placed; objects are model space).
import fs from 'node:fs';
import path from 'node:path';
import { openGamePage, TOOLS, RES, ROOT } from './lib/gamepage.mjs';

const OUTDIR = path.join(RES, 'Meshes');
const PREVIEW = path.join(TOOLS, 'previews', 'meshes_verify.png');
const verifyOnly = process.argv.includes('--verify');
const HDR = 16, FPV = 13, STRIDE = FPV * 4;   // 13 floats = 52 bytes (the field list of the contract; see below)
const F_GLOW = 1, F_LEG = 2, F_UV = 4;

// ---------------------------------------------------------------- notes / material table (from the game source)
const MATERIALS = {
  props: { model: 'standard', roughness: 0.62, metalness: 0.45, vertexColors: true, emissive: 'colour * aGlow * 2.2', snowCaps: 'mix(colour, (0.80,0.86,0.93), smoothstep(0.72,0.97,normal.y) * (1-aGlow) * 0.8)', src: '03-render.js makeGlowMaterial({ snow: true })' },
  marine: { model: 'standard', roughness: 0.55, metalness: 0.5, vertexColors: true, emissive: 'colour * aGlow * 2.2', snowCaps: false, src: '06-marines.js makeMarine' },
  floorGrating: { model: 'standard', roughness: 0.72, metalness: 0.42, map: 'grating', bumpMap: 'grating', bumpScale: 1.6, snowBias: 0.0, src: "makeFloorMaterial(TEX.grating, 1.6, 0.0)" },
  floorSlab: { model: 'standard', roughness: 0.72, metalness: 0.42, map: 'slab', bumpMap: 'slab', bumpScale: 0.6, snowBias: 0.18, src: "makeFloorMaterial(TEX.slab, 0.6, 0.18)" },
  floorSnow: 'sm = snow(worldXZ) + snowBias; bar = smoothstep(0.08,0.32, avg(map rgb)); fill = smoothstep(0.28,0.72,sm) * step(0.5,normal.y) * mix(0.55,1,bar); rgb = mix(rgb,(0.68,0.74,0.82),fill); roughness = mix(r,0.92,fill); metalness = mix(m,0,fill)',
  bug: { model: 'lambert', vertexColors: true, instanceColor: true, src: '03-render.js makeBugMaterial',
    vertex: 'if (aLeg.z > 0.5) pos *= step(0.85, up.y/|up|) (smudge hidden while climbing); ph = iAnim.x + aLeg.y; pos.z += sin(ph)*aLeg.x*0.17; pos.y += max(0,cos(ph))*aLeg.x*0.08; pos.y += (aLeg.x == 0) * |sin(iAnim.x)| * 0.03',
    fragment: 'rgb = mix(rgb,(0.2,0.38,0.55),freeze*0.8); rgb *= 1 - burn*0.6; emissive += colour*aGlow*(1-freeze) + (0.22,0.14,0.26)*rim^3*0.3*(1-aGlow)*(1-freeze) + (1,0.3,0.04)*burn*(0.12+0.88*aGlow)*0.9 + (1,0.92,0.88)*flash*0.8 + (0.05,0.16,0.3)*freeze*0.5; iAnim = (phase, flash, burn, freeze)' },
  corpse: { model: 'lambert', vertexColors: true, instanceColor: 'v*(1, 0.72, 0.58) with v = 1.6…2.3 (spitter: v*(0.85,0.95,0.58))', src: '07-fx.js corpseMat / addCorpse' },
  hazard: { model: 'standard', roughness: 0.8, metalness: 0.1, map: 'hazard', polygonOffset: -1 },
  padMark: { model: 'standard', roughness: 0.85, map: 'pad', transparent: true, depthWrite: false, polygonOffset: -2 },
  floorGlow: { model: 'unlit', blend: 'additive', map: 'glow', vertexColors: true, depthWrite: false, fog: false },
  haze: { model: 'unlit', blend: 'alpha', map: 'haze', depthWrite: false, fog: false, renderOrder: -1 },
  unlit: { model: 'unlit', vertexColors: true, fog: false, note: 'glob, grenade, beacon_top: MeshBasicMaterial (colour baked into the vertices)' },
};
const NOTES = {
  bug: (m) => `Instanced swarm geometry for ${m.name} (BT scale ${m.meta.scale}; instance matrix = rotY(heading) * scale, nose +z). Includes the dark contact smudge (aLeg.z = 1). Material: bug.`,
  corpse: (m) => `Flattened corpse (y * 0.55, curled legs, no glints) from the ${m.meta.from}; used for ${m.meta.from === 'brute' ? 'brutes' : 'every non-brute type'}. Instance colour multiplies (see materials.corpse). No glow / legs.`,
  marine: (m) => ({
    body: `Marine (${m.meta.cls}) body. Group: rotation order YXZ, scale 1.12, yaw = aim; body at the group origin (walk bob: body.y = |sin(walkPh)|*0.05*w). Material: marine.`,
    leg: `Marine (${m.meta.cls}) leg, pivot at the hip: drawn twice at (-0.13, 0.78, 0) and (+0.13, 0.78, 0) in group space; swing rotation.x = ±sw*rel, rotation.z = ±sw*0.4*(1-|rel|). Material: marine.`,
    gun: `Marine (${m.meta.cls}) gun at (0.2, 1.12, 0.08) in group space (recoil: z -= 0.05; the gunner barrel spins about z). Material: marine.`,
  })[m.meta.part],
  level_floor_grating: 'Grating floor slabs, stairs and sloped catwalks (world space, uv = world xz * 0.5 on tops). Material: floorGrating + floorSnow.',
  level_floor_slab: 'Snowy concrete slabs (landing pad, both staircases). Material: floorSlab + floorSnow.',
  level_props: 'All static props merged (railings, girders, supports, crates, pillars, pipes, snow drifts, vents, beacon bases, pad lights, stair nosings, distant towers). Material: props (snow caps on).',
  level_hazard: 'Hazard strips along the beacon / pad edges (uv along the strip / 1.6 m). Material: hazard, drawn with a depth bias over the floor.',
  level_pad_mark: 'Landing pad marking quad, 11 x 11 m at the start point. Material: padMark (alpha blended, no depth write).',
  level_glow: 'Floor light pools under lamps / pillars / vents (additive; colours pre-scaled by 0.3, uv 0..1 per quad). Material: floorGlow.',
  level_haze: 'Icy haze plane 16 m below the decks (220 x 220 m, drawn first). Material: haze.',
  lift_floor: 'Lift deck disc (r 10, grating) at rest height LIFT_Y = -6; translate by +rise (0…22 m, u*u*22) during extraction. Material: floorGrating + floorSnow.',
  lift_props: 'Lift railing ring, pads, teal rings, studs — same rise offset as lift_floor. Material: props.',
  turret_base: 'Gunner turret tripod (model space, origin on the floor). Material: props.',
  turret_head: 'Turret head; place at (0, pivotY = 0.95, 0) relative to the base and rotate about y by the aim angle. Material: props.',
  medkit: 'Medkit (origin on the floor). Material: props.',
  glob: 'Spitter acid glob (r 0.22). Material: unlit, colour 0xc8ff3a baked.',
  grenade: 'Grenade (r 0.14). Material: unlit, colour 0xffc040 baked.',
  beacon_top: 'Beacon tip octahedron (r 0.42), placed at ground + 2.9 over each beacon. Material: unlit, colour 0xff3020 baked.',
};
const TEX_NOTES = {
  grating: 'Grated steel floor, one tile = 2 m (uv = world * 0.5). Also the bump source.',
  slab: 'Snow-crusted concrete walkway tile, 2 m.',
  hazard: 'Amber/black hazard stripes, repeats along u (1.6 m per repeat).',
  pad: 'Landing pad marking (circle + H), straight alpha.',
  decals: 'Decal atlas 2x2 (multiply blend): top-left splat, top-right streak splat, bottom-left corpse remains (final colours), bottom-right scorch.',
  glow: 'Soft radial glow (white -> transparent): floor pools, splashes, particles.',
  ring: 'Telegraph / team ring: bright rim, faint fill, ticks.',
  fill: 'Filled disc with a bright rim (acid landing countdown).',
  lane: 'Brute charge lane: border + chevrons pointing toward +v (image top).',
  dash: 'Laser sight dash pattern (repeat along u).',
  streak: 'Streaky noise for the cryo beam (repeat).',
  snow: 'World-space snow drift mask, 2 px per metre over x,z in [-64, 64): sample at ((x + 64) / 128, (z + 64) / 128) with a top-left origin (first row = z -64). Linear data, linear filtering, no mips.',
  haze: 'Radial haze gradient for level_haze.',
};

// ---------------------------------------------------------------- export
function writeMesh(file, m) {
  const vc = m.vcount, pos = f32(m.pos), nrm = f32(m.nrm), col = f32(m.col), glow = f32(m.glow), leg = f32(m.leg);
  const ib = Buffer.from(m.idx, 'base64');
  const idx = new Uint32Array(ib.buffer.slice(ib.byteOffset, ib.byteOffset + ib.byteLength));
  let flags = STRIDE << 8;
  if (glow.some(v => v !== 0)) flags |= F_GLOW;
  if (m.hasLeg) flags |= F_LEG;
  if (m.uv) flags |= F_UV;
  const buf = Buffer.alloc(HDR + vc * STRIDE + idx.length * 4);
  buf.write('IHM1', 0, 'ascii'); buf.writeUInt32LE(vc, 4); buf.writeUInt32LE(idx.length, 8); buf.writeUInt32LE(flags, 12);
  const fv = new Float32Array(vc * FPV);
  for (let i = 0; i < vc; i++) {
    const o = i * FPV;
    fv[o] = pos[i * 3]; fv[o + 1] = pos[i * 3 + 1]; fv[o + 2] = pos[i * 3 + 2];
    fv[o + 3] = nrm[i * 3]; fv[o + 4] = nrm[i * 3 + 1]; fv[o + 5] = nrm[i * 3 + 2];
    fv[o + 6] = col[i * 3]; fv[o + 7] = col[i * 3 + 1]; fv[o + 8] = col[i * 3 + 2];
    fv[o + 9] = glow[i];
    fv[o + 10] = leg[i * 3]; fv[o + 11] = leg[i * 3 + 1]; fv[o + 12] = leg[i * 3 + 2];
  }
  Buffer.from(fv.buffer).copy(buf, HDR);
  Buffer.from(idx.buffer).copy(buf, HDR + vc * STRIDE);
  fs.writeFileSync(file, buf);
  return flags;
}
function f32(b64s) { const b = Buffer.from(b64s, 'base64'); return new Float32Array(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength)); }

// node-side reader (the same parse the Swift loader does) — used by validation
function readMesh(file) {
  const b = fs.readFileSync(file);
  if (b.toString('ascii', 0, 4) !== 'IHM1') throw new Error(file + ': bad magic');
  const vc = b.readUInt32LE(4), ic = b.readUInt32LE(8), flags = b.readUInt32LE(12);
  if (b.length !== HDR + vc * STRIDE + ic * 4) throw new Error(`${file}: size ${b.length} != ${HDR + vc * STRIDE + ic * 4}`);
  const ab = b.buffer.slice(b.byteOffset, b.byteOffset + b.length);
  if (((flags >> 8) & 255) !== STRIDE) throw new Error(`${file}: stride ${(flags >> 8) & 255} != ${STRIDE}`);
  return { vc, ic, flags, v: new Float32Array(ab, HDR, vc * FPV), idx: new Uint32Array(ab, HDR + vc * STRIDE, ic) };
}

if (!verifyOnly) {
  const t0 = Date.now();
  const { browser, page } = await openGamePage([path.join(TOOLS, 'lib', 'inpage-meshes.js')]);
  console.log(`game modules loaded (${Date.now() - t0} ms)`);
  const meshes = await page.evaluate(() => MESHX.collect());
  const textures = await page.evaluate(() => MESHX.textures());
  await browser.close();

  fs.rmSync(OUTDIR, { recursive: true, force: true });
  fs.mkdirSync(OUTDIR, { recursive: true });
  const manifest = {
    format: {
      magic: 'IHM1', endian: 'little', header: 'char[4] magic, u32 vertexCount, u32 indexCount, u32 flags', vertexStride: STRIDE,
      vertex: [['position', 'float3', 0], ['normal', 'float3', 12], ['colour', 'float3', 24, 'linear RGB'], ['aGlow', 'float', 36], ['aLeg', 'float3', 40]],
      indices: 'u32 triangle list after the vertices; CCW front faces (three.js winding)',
      flags: { 'bits8-15': 'vertex stride in bytes (52)', 1: 'aGlow used', 2: 'aLeg = bug leg data (weight, phase, smudgeFlag)', 4: 'aLeg.xy = uv (top-left image origin), aLeg.z = 0' },
      units: 'metres, y up, web game world space; level_* and lift_* are world-placed, the rest model space',
      textures: 'PNG, straight alpha; uv origin top-left: load without flipping (MTKTextureLoader default origin). srgb: true -> *_srgb pixel format. The snow mask is linear data.',
      bundle: 'XcodeGen adds App/Resources as groups, so these files land flat in the bundle root (look them up by name, no subdirectory); keep PNG compression off for exact alpha if needed.',
      source: 'game/js 01…09 via ios-native/tools/export-meshes.mjs',
    },
    meshes: {}, textures: {}, materials: MATERIALS,
    constants: { LIFT_Y: -6, liftRiseMax: 22, lift: { x: -3, z: -42, r: 10 }, start: { x: 30, z: 30 }, fog: '#1a2737', fogDensity: '0.42 / camDist', marineScale: 1.12, bugScale: { runner: 0.8, spitter: 1.02, brute: 2.0, boomer: 1.15 } },
  };
  for (const [name, m] of Object.entries(meshes)) {
    const file = name + '.mesh';
    const flags = writeMesh(path.join(OUTDIR, file), m);
    const kind = m.meta.kind;
    const note = NOTES[name] || (NOTES[kind] ? NOTES[kind]({ name, meta: m.meta }) : '');
    const e = { file, notes: note, flags, source: { triangles: m.src.tris, area: +m.src.area.toFixed(4), colourArea: +m.src.colArea.toFixed(4) } };
    if (m.meta.pivotY != null) e.pivot = [0, m.meta.pivotY, 0];
    if (kind === 'marine' && m.meta.part === 'leg') e.pivots = [[-0.13, 0.78, 0], [0.13, 0.78, 0]];
    if (kind === 'marine' && m.meta.part === 'gun') e.pivot = [0.2, 1.12, 0.08];
    manifest.meshes[name] = e;
  }
  for (const [name, t] of Object.entries(textures)) {
    const file = 'tex_' + name + '.png';
    fs.writeFileSync(path.join(OUTDIR, file), Buffer.from(t.png, 'base64'));
    manifest.textures[name] = { file, wrap: t.repeat ? 'repeat' : 'clamp', srgb: t.srgb, size: [t.w, t.h], notes: TEX_NOTES[name] || '' };
  }
  fs.writeFileSync(path.join(OUTDIR, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  console.log(`exported ${Object.keys(meshes).length} meshes, ${Object.keys(textures).length} textures (${Date.now() - t0} ms)`);
}

// ---------------------------------------------------------------- validate (node re-read)
{
  const manifest = JSON.parse(fs.readFileSync(path.join(OUTDIR, 'manifest.json'), 'utf8'));
  let total = 0, bad = 0;
  const rows = [];
  for (const [name, e] of Object.entries(manifest.meshes)) {
    const file = path.join(OUTDIR, e.file);
    const m = readMesh(file);
    total += fs.statSync(file).size;
    const problems0 = [];
    const mn = [Infinity, Infinity, Infinity], mx = [-Infinity, -Infinity, -Infinity];
    let nonFinite = 0, badN = 0, badIdx = 0, degenerate = 0, area = 0, colArea = 0;
    for (let i = 0; i < m.vc; i++) {
      const o = i * FPV;
      for (let k = 0; k < FPV; k++) if (!Number.isFinite(m.v[o + k])) nonFinite++;
      for (let k = 0; k < 3; k++) { mn[k] = Math.min(mn[k], m.v[o + k]); mx[k] = Math.max(mx[k], m.v[o + k]); }
      const nl = Math.hypot(m.v[o + 3], m.v[o + 4], m.v[o + 5]);
      if (Math.abs(nl - 1) > 0.02) badN++;
    }
    for (let i = 0; i < m.ic; i++) if (m.idx[i] >= m.vc) badIdx++;
    for (let t = 0; t + 2 < m.ic; t += 3) {
      const a = m.idx[t], b = m.idx[t + 1], c = m.idx[t + 2];
      if (a === b || b === c || a === c) degenerate++;
      const A = a * FPV, B = b * FPV, C = c * FPV, v = m.v;
      const ux = v[B] - v[A], uy = v[B + 1] - v[A + 1], uz = v[B + 2] - v[A + 2], wx = v[C] - v[A], wy = v[C + 1] - v[A + 1], wz = v[C + 2] - v[A + 2];
      const ar = 0.5 * Math.hypot(uy * wz - uz * wy, uz * wx - ux * wz, ux * wy - uy * wx);
      area += ar; colArea += ar * (v[A + 6] + v[A + 7] + v[A + 8]);
    }
    // against the source geometry measured in the page before packing (welding may drop zero-area triangles only)
    if (e.source) {
      const rel = (x, y) => Math.abs(x - y) / Math.max(1e-6, Math.abs(y));
      if (rel(area, e.source.area) > 1e-3) problems0.push(`area ${area.toFixed(3)} != source ${e.source.area}`);
      if (rel(colArea, e.source.colourArea) > 1e-3) problems0.push(`colour area ${colArea.toFixed(3)} != source ${e.source.colourArea}`);
      if (m.ic / 3 > e.source.triangles) problems0.push('more triangles than the source');
    }
    const okFlags = m.flags === e.flags;
    const problems = problems0;
    if (m.ic % 3) problems.push('indexCount % 3');
    if (nonFinite) problems.push(nonFinite + ' non-finite');
    if (badIdx) problems.push(badIdx + ' bad indices');
    if (badN) problems.push(badN + ' non-unit normals');
    if (!okFlags) problems.push('flags mismatch');
    if (problems.length) bad++;
    e.bounds = { min: mn.map(v => +v.toFixed(4)), max: mx.map(v => +v.toFixed(4)) };
    e.vertices = m.vc; e.indices = m.ic;
    rows.push([name, m.vc, m.ic, (m.ic / 3) + (e.source ? '/' + e.source.triangles : ''), m.flags & 255, e.bounds.min.map(v => v.toFixed(2)).join(','), e.bounds.max.map(v => v.toFixed(2)).join(','), (fs.statSync(file).size / 1024).toFixed(0) + 'K', (degenerate ? degenerate + ' degen ' : '') + problems.join('; ')]);
  }
  for (const e of Object.values(manifest.textures)) total += fs.statSync(path.join(OUTDIR, e.file)).size;
  fs.writeFileSync(path.join(OUTDIR, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  const W = [22, 7, 7, 13, 3, 24, 24, 6, 0];
  console.log(['mesh', 'verts', 'idx', 'tris/source', 'fl', 'min', 'max', 'size', 'problems'].map((s, i) => String(s).padEnd(W[i])).join(' '));
  for (const r of rows) console.log(r.map((s, i) => String(s).padEnd(W[i])).join(' '));
  for (const [name, e] of Object.entries(manifest.textures)) console.log(`tex ${name.padEnd(8)} ${e.size.join('x').padEnd(8)} ${e.wrap.padEnd(7)} srgb=${e.srgb} ${(fs.statSync(path.join(OUTDIR, e.file)).size / 1024).toFixed(0)}K`);
  console.log(`total ${(total / 1048576).toFixed(2)} MB in ${OUTDIR}`);
  if (bad) { console.error(`${bad} mesh(es) failed validation`); process.exitCode = 1; }
}

// ---------------------------------------------------------------- verification render (exported files only)
{
  const { chromium } = await import('playwright');
  const ORIGIN = 'https://verify.local';
  const THREE_DIR = path.join(ROOT, 'node_modules', 'three');
  const PAGE = `<!doctype html><html><head><meta charset="utf-8">
<script type="importmap">{"imports":{"three":"${ORIGIN}/three/build/three.module.js"}}</script></head>
<body style="margin:0;background:#000"><script type="module" src="${ORIGIN}/verify.js"></script></body></html>`;
  const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--enable-webgl'] });
  const page = await (await browser.newContext({ viewport: { width: 800, height: 600 } })).newPage();
  page.on('pageerror', (e) => console.error('[verify page error]', e.message));
  page.on('console', (m) => { if (m.type() === 'error') console.error('[verify console]', m.text()); });
  await page.route('**/*', async (route) => {
    const url = route.request().url();
    if (url === ORIGIN + '/') return route.fulfill({ status: 200, contentType: 'text/html', body: PAGE });
    if (url === ORIGIN + '/verify.js') return route.fulfill({ status: 200, contentType: 'application/javascript', body: fs.readFileSync(path.join(TOOLS, 'lib', 'verify-meshes.js')) });
    if (url.startsWith(ORIGIN + '/three/')) {
      const p = path.join(THREE_DIR, decodeURIComponent(new URL(url).pathname.slice('/three/'.length)));
      if (fs.existsSync(p)) return route.fulfill({ status: 200, contentType: 'application/javascript', body: fs.readFileSync(p) });
    }
    if (url.startsWith(ORIGIN + '/meshes/')) {
      const p = path.join(OUTDIR, path.basename(new URL(url).pathname));
      if (fs.existsSync(p)) return route.fulfill({ status: 200, contentType: p.endsWith('.png') ? 'image/png' : p.endsWith('.json') ? 'application/json' : 'application/octet-stream', body: fs.readFileSync(p) });
    }
    console.error('[blocked]', url);
    return route.abort();
  });
  await page.goto(ORIGIN + '/');
  await page.waitForFunction(() => window.__shot || window.__fail, null, { timeout: 180000 });
  const fail = await page.evaluate(() => window.__fail);
  if (fail) { console.error('verification render failed:', fail); process.exitCode = 1; }
  else {
    const shot = await page.evaluate(() => window.__shot);
    fs.mkdirSync(path.dirname(PREVIEW), { recursive: true });
    fs.writeFileSync(PREVIEW, Buffer.from(shot, 'base64'));
    console.log('verification render:', PREVIEW, await page.evaluate(() => window.__info));
  }
  await browser.close();
}
