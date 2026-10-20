// Verification render for export-meshes.mjs: a bare three.js page (NO game code) that loads only the exported
// Meshes/*.mesh + tex_*.png + manifest.json and draws (1) the whole level from far away along the game's
// camera axis, (2) a game-camera close-up of the landing pad / hub, (3) a lineup of every object mesh.
import * as THREE from 'three';

const BASE = 'https://verify.local/meshes/';
const W = 1600, H = 1200, TOP = 700;
try {
  const man = await (await fetch(BASE + 'manifest.json')).json();

  // ---- IHM1 parse -> BufferGeometry
  async function loadMesh(name) {
    const e = man.meshes[name];
    const ab = await (await fetch(BASE + e.file)).arrayBuffer();
    const dv = new DataView(ab);
    const magic = String.fromCharCode(dv.getUint8(0), dv.getUint8(1), dv.getUint8(2), dv.getUint8(3));
    if (magic !== 'IHM1') throw new Error(name + ': magic ' + magic);
    const vc = dv.getUint32(4, true), ic = dv.getUint32(8, true), flags = dv.getUint32(12, true), stride = (flags >> 8) & 255;
    const fpv = stride / 4, v = new Float32Array(ab, 16, vc * fpv), idx = new Uint32Array(ab, 16 + vc * stride, ic);
    const ib = new THREE.InterleavedBuffer(v, fpv);
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.InterleavedBufferAttribute(ib, 3, 0));
    g.setAttribute('normal', new THREE.InterleavedBufferAttribute(ib, 3, 3));
    g.setAttribute('color', new THREE.InterleavedBufferAttribute(ib, 3, 6));
    g.setAttribute('aGlow', new THREE.InterleavedBufferAttribute(ib, 1, 9));
    g.setAttribute('aLeg', new THREE.InterleavedBufferAttribute(ib, 3, 10));
    if (flags & 4) g.setAttribute('uv', new THREE.InterleavedBufferAttribute(ib, 2, 10));
    g.setIndex(new THREE.BufferAttribute(idx, 1));
    g.computeBoundingSphere();
    return g;
  }
  const texLoader = new THREE.TextureLoader();
  async function loadTex(name) {
    const e = man.textures[name];
    const t = await texLoader.loadAsync(BASE + e.file);
    t.flipY = false;   // uvs in the files use a top-left image origin (Metal convention)
    if (e.wrap === 'repeat') t.wrapS = t.wrapT = THREE.RepeatWrapping;
    if (e.srgb) t.colorSpace = THREE.SRGBColorSpace;
    t.anisotropy = 4; t.needsUpdate = true;
    return t;
  }
  const G = {};
  for (const n of Object.keys(man.meshes)) G[n] = await loadMesh(n);
  const T = {};
  for (const n of Object.keys(man.textures)) T[n] = await loadTex(n);
  // the station (level_* / lift_* meshes, grating / slab / hazard / snow textures) is retired from this exporter: it
  // comes from the Blender kit now (tools/blender, App/Resources/Kit); a neutral stand-in keeps the materials valid
  const none = new THREE.DataTexture(new Uint8Array([128, 128, 128, 255]), 1, 1); none.needsUpdate = true;
  for (const n of ['grating', 'slab', 'hazard', 'snow']) if (!T[n]) T[n] = none;
  T.snow.minFilter = THREE.LinearFilter; T.snow.generateMipmaps = false;

  // ---- materials (reduced versions of the game's, enough to see colours / glow / uv / legs / snow)
  function glowMat({ glow = 2.2, rough = 0.62, metal = 0.45, snow = false } = {}) {
    const m = new THREE.MeshStandardMaterial({ vertexColors: true, roughness: rough, metalness: metal });
    m.onBeforeCompile = (sh) => {
      sh.vertexShader = sh.vertexShader.replace('#include <common>', '#include <common>\nattribute float aGlow;\nvarying float vGlow;\nvarying float vUp;')
        .replace('#include <begin_vertex>', '#include <begin_vertex>\nvGlow = aGlow;\nvUp = normal.y;');
      sh.fragmentShader = sh.fragmentShader.replace('#include <common>', '#include <common>\nvarying float vGlow;\nvarying float vUp;')
        .replace('#include <color_fragment>', '#include <color_fragment>\n' + (snow ? 'diffuseColor.rgb = mix(diffuseColor.rgb, vec3(0.80, 0.86, 0.93), smoothstep(0.72, 0.97, vUp) * (1.0 - vGlow) * 0.8);' : ''))
        .replace('#include <emissivemap_fragment>', '#include <emissivemap_fragment>\ntotalEmissiveRadiance += vColor.rgb * vGlow * ' + glow.toFixed(2) + ';');
    };
    m.customProgramCacheKey = () => 'v' + glow + snow + rough;
    return m;
  }
  function floorMat(map, bias) {
    const m = new THREE.MeshStandardMaterial({ map, roughness: 0.72, metalness: 0.42 });
    m.onBeforeCompile = (sh) => {
      sh.uniforms.uSnow = { value: T.snow };
      sh.vertexShader = sh.vertexShader.replace('#include <common>', '#include <common>\nvarying vec3 vWP;\nvarying float vUp;')
        .replace('#include <begin_vertex>', '#include <begin_vertex>\nvWP = (modelMatrix * vec4(transformed, 1.0)).xyz;\nvUp = normal.y;');
      sh.fragmentShader = sh.fragmentShader.replace('#include <common>', '#include <common>\nvarying vec3 vWP;\nvarying float vUp;\nuniform sampler2D uSnow;')
        .replace('#include <map_fragment>', `#include <map_fragment>
  float sm = texture2D(uSnow, (vWP.xz + 64.0) / 128.0).r + ${bias.toFixed(2)};
  float bar = smoothstep(0.08, 0.32, dot(diffuseColor.rgb, vec3(0.333)));
  float snowFill = smoothstep(0.28, 0.72, sm) * step(0.5, vUp) * mix(0.55, 1.0, bar);
  diffuseColor.rgb = mix(diffuseColor.rgb, vec3(0.68, 0.74, 0.82), snowFill);`);
    };
    m.customProgramCacheKey = () => 'f' + bias;
    return m;
  }
  function bugMat(phase) {
    const m = new THREE.MeshLambertMaterial({ vertexColors: true });
    m.onBeforeCompile = (sh) => {
      sh.vertexShader = sh.vertexShader.replace('#include <common>', '#include <common>\nattribute float aGlow;\nattribute vec3 aLeg;\nvarying float vGlow;')
        .replace('#include <begin_vertex>', `#include <begin_vertex>
  float ph = ${phase.toFixed(3)} + aLeg.y;
  transformed.z += sin(ph) * aLeg.x * 0.17;
  transformed.y += max(0.0, cos(ph)) * aLeg.x * 0.08;
  vGlow = aGlow;`);
      sh.fragmentShader = sh.fragmentShader.replace('#include <common>', '#include <common>\nvarying float vGlow;')
        .replace('#include <emissivemap_fragment>', '#include <emissivemap_fragment>\ntotalEmissiveRadiance += vColor.rgb * vGlow;');
    };
    m.customProgramCacheKey = () => 'bug' + phase;
    return m;
  }
  const M = {
    props: glowMat({ snow: true }), marine: glowMat({ rough: 0.55, metal: 0.5 }),
    grating: floorMat(T.grating, 0), slab: floorMat(T.slab, 0.18),
    hazard: new THREE.MeshStandardMaterial({ map: T.hazard, roughness: 0.8, metalness: 0.1, polygonOffset: true, polygonOffsetFactor: -1, polygonOffsetUnits: -1 }),
    pad: new THREE.MeshStandardMaterial({ map: T.pad, transparent: true, depthWrite: false, roughness: 0.85, polygonOffset: true, polygonOffsetFactor: -2, polygonOffsetUnits: -2 }),
    glowq: new THREE.MeshBasicMaterial({ map: T.glow, vertexColors: true, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false }),
    haze: new THREE.MeshBasicMaterial({ map: T.haze, transparent: true, depthWrite: false }),
    unlit: new THREE.MeshBasicMaterial({ vertexColors: true }),
    corpse: new THREE.MeshLambertMaterial({ vertexColors: true, color: new THREE.Color(1.9, 1.37, 1.1) }),
  };

  const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true });
  renderer.setPixelRatio(1); renderer.setSize(W, H, false);
  renderer.toneMapping = THREE.ACESFilmicToneMapping; renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.autoClear = false;
  document.body.appendChild(renderer.domElement);

  function rig(scene, k = 1) {
    scene.add(new THREE.HemisphereLight(0x9fb4d8, 0x1a2029, 1.3 * k));
    const key = new THREE.DirectionalLight(0xe2e9f8, 2.2 * k); key.position.set(-25, 60, 35); scene.add(key, key.target);
    const fill = new THREE.DirectionalLight(0xfff0dc, 1.0 * k); fill.position.set(40, 50, 40); scene.add(fill, fill.target);
  }
  const mesh = (g, m, x = 0, y = 0, z = 0) => { const o = new THREE.Mesh(g, m); o.position.set(x, y, z); return o; };

  // ---- level scene
  const lvl = new THREE.Scene();
  lvl.background = new THREE.Color(0x1a2737);
  rig(lvl);
  const hz = mesh(G.level_haze, M.haze); hz.renderOrder = -1; lvl.add(hz);
  const opt = (n, m) => G[n] ? [mesh(G[n], m)] : [];
  lvl.add(...opt('level_floor_grating', M.grating), ...opt('level_floor_slab', M.slab), ...opt('level_props', M.props),
    ...opt('level_hazard', M.hazard), ...opt('level_pad_mark', M.pad), ...opt('level_glow', M.glowq),
    ...opt('lift_floor', M.grating), ...opt('lift_props', M.props));
  if (!G.level_props) { const deck = new THREE.Mesh(new THREE.PlaneGeometry(40, 40).rotateX(-Math.PI / 2), M.grating); deck.position.set(30, 0, 30); lvl.add(deck); }
  // one of each bug + a marine squad standing on the landing pad (visible in the close-up)
  const BUGS = [['runner', 0.8], ['spitter', 1.02], ['brute', 2.0], ['boomer', 1.15]];
  BUGS.forEach(([n, s], k) => { const o = mesh(G['bug_' + n], bugMat(k * 1.3), 26 + k * 2.2, 0, 27); o.scale.setScalar(s); o.rotation.y = Math.PI * 0.25; lvl.add(o); });
  function marine(cls, x, y, z, yaw) {
    const g = new THREE.Group(); g.rotation.order = 'YXZ';
    g.add(mesh(G[`marine_${cls}_body`], M.marine));
    const p = man.meshes[`marine_${cls}_leg`].pivots;
    for (const [px, py, pz] of p) g.add(mesh(G[`marine_${cls}_leg`], M.marine, px, py, pz));
    const gp = man.meshes[`marine_${cls}_gun`].pivot;
    g.add(mesh(G[`marine_${cls}_gun`], M.marine, gp[0], gp[1], gp[2]));
    g.scale.setScalar(1.12); g.position.set(x, y, z); g.rotation.y = yaw;
    return g;
  }
  ['assault', 'pyro', 'cryo', 'gunner'].forEach((c, k) => lvl.add(marine(c, 28 + k * 1.6, 0, 32, Math.PI * 1.25)));

  // ---- lineup scene (model-space objects in a row on a grating strip)
  const lu = new THREE.Scene();
  lu.background = new THREE.Color(0x1a2737);
  rig(lu, 1.1);
  const ROWS = [[], []];
  BUGS.forEach(([n, s]) => ROWS[0].push(() => { const o = mesh(G['bug_' + n], bugMat(0.6)); o.scale.setScalar(s); return [o, s * 0.9]; }));
  ROWS[0].push(() => { const o = mesh(G.corpse_generic, M.corpse); o.scale.setScalar(0.8); return [o, 0.8]; });
  ROWS[0].push(() => { const o = mesh(G.corpse_brute, M.corpse); o.scale.setScalar(2.0); return [o, 1.6]; });
  for (const c of ['assault', 'pyro', 'cryo', 'gunner']) ROWS[1].push(() => [marine(c, 0, 0, 0, 0), 0.8]);
  ROWS[1].push(() => { const g = new THREE.Group(); g.add(mesh(G.turret_base, M.props)); g.add(mesh(G.turret_head, M.props, 0, man.meshes.turret_head.pivot[1], 0)); return [g, 0.7]; });
  ROWS[1].push(() => [mesh(G.medkit, M.props), 0.6]);
  ROWS[1].push(() => [mesh(G.glob, M.unlit, 0, 0.4, 0), 0.4]);
  ROWS[1].push(() => [mesh(G.grenade, M.unlit, 0, 0.3, 0), 0.35]);
  if (G.beacon_top) ROWS[1].push(() => [mesh(G.beacon_top, M.unlit, 0, 0.6, 0), 0.6]);
  // rows along the screen-right axis (x - z), the second row nearer the camera (screen-down = +x +z)
  const RX = Math.SQRT1_2, RZ = -Math.SQRT1_2, DX = Math.SQRT1_2, DZ = Math.SQRT1_2;
  ROWS.forEach((row, r) => {
    const items = row.map(f => f()), tot = items.reduce((a, [, w]) => a + 2 * w, 0);
    let t = -tot / 2;
    for (const [o, w] of items) { t += w; o.position.x += RX * t + DX * (r * 3.2 - 1.6); o.position.z += RZ * t + DZ * (r * 3.2 - 1.6); lu.add(o); t += w; }
  });
  const strip = new THREE.PlaneGeometry(26, 7.5).rotateX(-Math.PI / 2).rotateY(Math.PI / 4);
  { const uv = strip.attributes.uv, p = strip.attributes.position; for (let i = 0; i < uv.count; i++) uv.setXY(i, p.getX(i) * 0.5, 1 - p.getZ(i) * 0.5); }
  lu.add(mesh(strip, floorMat(T.grating, -1)));

  // ---- cameras along the game axis (yaw 45°, pitch 57°)
  const YAW = Math.PI / 4, PITCH = 57 * Math.PI / 180;
  function cam(fov, aspect, tx, ty, tz, dist) {
    const c = new THREE.PerspectiveCamera(fov, aspect, 0.5, 600);
    c.position.set(tx + Math.sin(YAW) * Math.cos(PITCH) * dist, ty + Math.sin(PITCH) * dist, tz + Math.cos(YAW) * Math.cos(PITCH) * dist);
    c.lookAt(tx, ty, tz); return c;
  }
  renderer.setClearColor(0x000000, 1); renderer.clear();
  const draw = (scene, camera, x, y, w, h) => { renderer.setViewport(x, H - y - h, w, h); renderer.setScissor(x, H - y - h, w, h); renderer.setScissorTest(true); renderer.clear(); renderer.render(scene, camera); };
  draw(lvl, cam(40, W / TOP, -2, -3, -4, 175), 0, 0, W, TOP);
  draw(lvl, cam(40, 800 / 500, 29, 0, 29.5, 22), 0, TOP, 800, H - TOP);
  draw(lu, cam(30, 800 / 500, 0, 0.5, 0, 21), 800, TOP, 800, H - TOP);
  const info = { meshes: Object.keys(G).length, textures: Object.keys(T).length, calls: renderer.info.render.calls };
  window.__info = JSON.stringify(info);
  window.__shot = renderer.domElement.toDataURL('image/png').split(',')[1];
} catch (e) {
  window.__fail = String(e && e.stack || e);
}
