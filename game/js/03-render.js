// ================================================================
//  RENDER — renderer, scene, camera, fixed light rig, materials
// ================================================================
const IS_MOBILE = /iPhone|iPad|iPod|Android|Mobile/i.test(navigator.userAgent) || (typeof matchMedia === 'function' && matchMedia('(pointer: coarse)').matches);
let qName = IS_MOBILE ? 'med' : 'high';
let Q = QUALITY[qName];
let qLocked = false;      // set by the pause menu / __dbg.setQuality: disables adaptive downgrade
let prScale = 1;          // adaptive pixel-ratio multiplier
// Gameplay cap on live bugs. Only the boot tier or an explicit choice sets it; adaptive steps change rendering only.
let simCap = Q.cap;
// Desktop renders every tier through the composer into one 4x MSAA target (tone mapping lives in OutputPass,
// so tier switches never change material programs except for shadows). Phones render straight to the screen.
const USE_COMPOSER = !IS_MOBILE;

const renderer = new THREE.WebGLRenderer({ antialias: false, powerPreference: 'high-performance', stencil: false });
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.0;
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.shadowMap.enabled = false;
renderer.shadowMap.type = THREE.PCFShadowMap;
$('stage').appendChild(renderer.domElement);

const scene = new THREE.Scene();
scene.background = new THREE.Color(FOG_COLOR);
scene.fog = new THREE.FogExp2(FOG_COLOR, 0.016);
const camera = new THREE.PerspectiveCamera(40, 1, 1, 260);

// ---- fixed light rig: never add/remove lights at runtime (shader recompiles) ----
const hemi = new THREE.HemisphereLight(0x5a74a0, 0x05070b, 0.42);
const moon = new THREE.DirectionalLight(0x8eaade, 0.5);
moon.position.set(-25, 60, 35);
scene.add(hemi, moon, moon.target);
const spots = [];
for (let i = 0; i < 4; i++) {
  // gentler than inverse-square so the beam pool reads evenly instead of a blown-out hot spot at the boots
  const s = new THREE.SpotLight(0xfff2de, 0, 32, 0.5, 0.55, 1.35);
  s.position.set(0, -50, 0);
  s.shadow.mapSize.set(1024, 1024);
  s.shadow.bias = -0.0006;
  s.shadow.camera.near = 0.5; s.shadow.camera.far = 32;
  scene.add(s, s.target);
  spots.push(s);
}
// Every visible light is evaluated by every lit fragment, so phones keep a single pooled point light
// (blast flashes fall back to floor splashes there).
const plights = [];
const N_PL = IS_MOBILE ? 1 : 3;
for (let i = 0; i < N_PL; i++) {
  const p = new THREE.PointLight(0xff8a3a, 0, 18, 2);
  p.position.set(0, -60, 0);
  scene.add(p);
  plights.push({ light: p, t: 0, dur: 1, peak: 0, follow: null });
}

// ---- post (desktop only; bloom enabled on 'high') ----
let composer = null, bloomPass = null;
function ensureComposer() {
  if (composer || !USE_COMPOSER) return;
  const rt = new THREE.WebGLRenderTarget(4, 4, { type: THREE.HalfFloatType, samples: 4 });
  composer = new EffectComposer(renderer, rt);
  composer.addPass(new RenderPass(scene, camera));
  bloomPass = new UnrealBloomPass(new THREE.Vector2(256, 256), 0.45, 0.4, 0.95);
  bloomPass.enabled = Q.bloom;
  composer.addPass(bloomPass);
  composer.addPass(new OutputPass());
}

// ---- viewport / camera fit ----
let viewW = 1, viewH = 1, camDist = 28, pxScale = 1, safeBottom = 0;
let stillDrawn = false;   // a paused / menu frame has been drawn once (frame() then skips rendering)
function resize() {
  viewW = Math.max(1, window.innerWidth); viewH = Math.max(1, window.innerHeight);
  stillDrawn = false;
  // the platform pads :root with the bottom safe-area inset; the touch sticks sit above it
  try { safeBottom = parseFloat(getComputedStyle(document.documentElement).paddingBottom) || 0; } catch (e) { safeBottom = 0; }
  const pr = Math.min(window.devicePixelRatio || 1, Q.pr) * prScale;
  renderer.setPixelRatio(pr);
  renderer.setSize(viewW, viewH, false);
  if (composer) { composer.setPixelRatio(pr); composer.setSize(viewW, viewH); }
  const aspect = viewW / viewH;
  camera.aspect = aspect;
  camera.fov = aspect < 1 ? 50 : 40;
  // keep roughly the same world radius visible on the short axis (portrait pulls back)
  const vis = aspect < 1 ? 11.5 : 10.8;
  camDist = vis / (Math.tan(camera.fov * Math.PI / 360) * Math.min(1, aspect));
  camera.far = camDist + 140;
  camera.updateProjectionMatrix();
  scene.fog.density = 0.42 / camDist;
  pxScale = (viewH * pr) / (2 * Math.tan(camera.fov * Math.PI / 360));
  if (typeof fxOnResize === 'function') fxOnResize();
}

// ---- materials ----
// Standard material with per-vertex color + aGlow emissive (props, marines); optional snow caps.
// rim: optional THREE.Color (kept by reference) for a class-coloured fresnel edge light (marines; one extra program)
function makeGlowMaterial({ roughness = 0.62, metalness = 0.45, snow = false, glow = 2.2, rim = null } = {}) {
  const m = new THREE.MeshStandardMaterial({ vertexColors: true, roughness, metalness });
  m.onBeforeCompile = (sh) => {
    if (rim) sh.uniforms.uRim = { value: rim };
    sh.vertexShader = sh.vertexShader
      .replace('#include <common>', '#include <common>\nattribute float aGlow;\nvarying float vGlow;\nvarying float vUp;')
      .replace('#include <begin_vertex>', '#include <begin_vertex>\nvGlow = aGlow;\nvUp = normal.y;');
    sh.fragmentShader = sh.fragmentShader
      .replace('#include <common>', '#include <common>\nvarying float vGlow;\nvarying float vUp;')
      .replace('#include <color_fragment>', '#include <color_fragment>\n' +
        (snow ? 'diffuseColor.rgb = mix(diffuseColor.rgb, vec3(0.80, 0.86, 0.93), smoothstep(0.72, 0.97, vUp) * (1.0 - vGlow) * 0.8);' : ''))
      .replace('#include <emissivemap_fragment>', '#include <emissivemap_fragment>\ntotalEmissiveRadiance += vColor.rgb * vGlow * ' + glow.toFixed(2) + ';' +
        // class-coloured fresnel backlight: a marine reads as a coloured cut-out against both the dark deck and the dark swarm
        (rim ? '\n{ float fr = 1.0 - abs(dot(normal, normalize(vViewPosition))); totalEmissiveRadiance += uRim * fr * fr * (0.35 + 0.65 * smoothstep(0.4, 1.0, fr)); }' : ''));
    if (rim) sh.fragmentShader = sh.fragmentShader.replace('#include <common>', '#include <common>\nuniform vec3 uRim;');
  };
  m.customProgramCacheKey = () => 'glow' + (snow ? 1 : 0) + glow + (rim ? 'r' : '');
  return m;
}

// Floor material: grating/slab texture + world-space snow drift mask.
let snowTex = null;
function makeFloorMaterial(map, bump, snowBias) {
  // phones skip the derivative bump (3 fewer texture fetches per floor fragment); the map already shows the slots
  const m = new THREE.MeshStandardMaterial({ map, bumpMap: IS_MOBILE ? null : map, bumpScale: IS_MOBILE ? 0 : bump, roughness: 0.72, metalness: 0.42 });
  m.onBeforeCompile = (sh) => {
    sh.uniforms.uSnow = { value: snowTex };
    sh.vertexShader = sh.vertexShader
      .replace('#include <common>', '#include <common>\nvarying vec3 vWP;\nvarying float vUp;')
      .replace('#include <begin_vertex>', '#include <begin_vertex>\nvWP = (modelMatrix * vec4(transformed, 1.0)).xyz;\nvUp = normal.y;');
    sh.fragmentShader = sh.fragmentShader
      .replace('#include <common>', '#include <common>\nvarying vec3 vWP;\nvarying float vUp;\nuniform sampler2D uSnow;\nfloat snowFill;')
      .replace('#include <map_fragment>', `#include <map_fragment>
  float sm = texture2D(uSnow, (vWP.xz + 64.0) / 128.0).r + ${snowBias.toFixed(2)};
  float bar = smoothstep(0.08, 0.32, dot(diffuseColor.rgb, vec3(0.333)));
  snowFill = smoothstep(0.28, 0.72, sm) * step(0.5, vUp) * mix(0.55, 1.0, bar);
  diffuseColor.rgb = mix(diffuseColor.rgb, vec3(0.68, 0.74, 0.82), snowFill);`)
      .replace('#include <roughnessmap_fragment>', '#include <roughnessmap_fragment>\nroughnessFactor = mix(roughnessFactor, 0.92, snowFill);')
      .replace('#include <metalnessmap_fragment>', '#include <metalnessmap_fragment>\nmetalnessFactor = mix(metalnessFactor, 0.0, snowFill);');
  };
  m.customProgramCacheKey = () => 'floor' + snowBias;
  return m;
}

// Instanced bug material: Lambert + leg animation + glow speckles + status tints, then a bug-only tone curve.
// iAnim = (walk phase, hit flash, burn, frost); frost < 0 flags the queen (she never freezes): full chroma + violet edge.
function makeBugMaterial() {
  const m = new THREE.MeshLambertMaterial({ vertexColors: true });
  m.onBeforeCompile = (sh) => {
    sh.vertexShader = sh.vertexShader
      .replace('#include <common>', `#include <common>
attribute float aGlow;
attribute vec3 aLeg;
attribute vec4 iAnim;
varying float vGlow;
varying vec3 vFx;
varying float vSparse;`)
      .replace('#include <begin_vertex>', `#include <begin_vertex>
  vSparse = (1.0 - step(0.001, aLeg.x)) * aLeg.y;
  if (aLeg.z > 0.5) { vec3 iu = instanceMatrix[1].xyz; transformed *= step(0.85, iu.y / max(length(iu), 1e-4)); }
  float ph = iAnim.x + aLeg.y;
  transformed.z += sin(ph) * aLeg.x * 0.17;
  transformed.y += max(0.0, cos(ph)) * aLeg.x * 0.08;
  transformed.y += (1.0 - step(0.001, aLeg.x)) * abs(sin(iAnim.x)) * 0.03;
  vGlow = aGlow;
  vFx = iAnim.yzw;`);
    sh.fragmentShader = sh.fragmentShader
      .replace('#include <common>', '#include <common>\nvarying float vGlow;\nvarying vec3 vFx;\nvarying float vSparse;')
      .replace('#include <color_fragment>', `#include <color_fragment>
  float frz = max(vFx.z, 0.0), qn = max(-vFx.z, 0.0);
  diffuseColor.rgb = mix(diffuseColor.rgb, vec3(0.2, 0.38, 0.55), frz * 0.8);
  diffuseColor.rgb *= 1.0 - vFx.y * 0.6;`)
      .replace('#include <emissivemap_fragment>', `#include <emissivemap_fragment>
  vec3 gland = vColor.rgb * vGlow * (1.0 - frz);
  // runner glands are sparse (only the brighter half of the instances shows them) and burn orange, not white
  gland *= (1.0 - vSparse * (1.0 - smoothstep(0.85, 1.1, vColor.r))) * (1.0 - 0.5 * vFx.y);
  totalEmissiveRadiance += gland;
  float rim = 1.0 - abs(dot(normal, normalize(vViewPosition)));
  totalEmissiveRadiance += vec3(0.10, 0.13, 0.19) * rim * rim * rim * 0.3 * (1.0 - vGlow) * (1.0 - frz);
  // burning: charred body, the glands glow hot (the ember particles supply the flames)
  totalEmissiveRadiance += vec3(1.0, 0.3, 0.04) * vFx.y * (0.12 + 0.88 * vGlow) * 0.9;
  totalEmissiveRadiance += vec3(1.0, 0.92, 0.88) * vFx.x * 0.8;
  totalEmissiveRadiance += vec3(0.05, 0.16, 0.3) * frz * 0.5;
  // the queen: a deep-violet sheen that survives the tone curve below and any light pool
  totalEmissiveRadiance += vec3(0.30, 0.07, 0.62) * qn * (0.10 + 0.9 * rim * rim);`)
      // lit chitin is tone-mapped on its own: half the chroma, a soft shoulder, a cold edge glint where lit,
      // and the glands dim inside light pools (they are the signal in the dark, noise in the light)
      .replace('#include <envmap_fragment>', `#include <envmap_fragment>
  {
    vec3 dif = outgoingLight - totalEmissiveRadiance;
    float L = dot(dif, vec3(0.2126, 0.7152, 0.0722));
    float lit = smoothstep(0.03, 0.25, L);
    float keep = max(frz, qn);
    dif = mix(vec3(L), dif, 0.5 + 0.5 * keep);
    // the shoulder works per channel on chitin (it also pulls lit highlights toward grey) but on luminance for frozen
    // bugs and the queen, so ice stays blue and she stays violet inside a flashlight pool
    dif = mix(dif * 1.15 / (1.0 + dif * 3.0), dif * (1.15 / (1.0 + L * 3.0)), keep);
    dif += vec3(0.55, 0.62, 0.70) * rim * rim * lit * 0.22 * (1.0 - vGlow);
    outgoingLight = dif + totalEmissiveRadiance - gland * 0.55 * lit;
  }`);
  };
  m.customProgramCacheKey = () => 'bug';
  return m;
}

// Attach constant color + glow attributes to a geometry (non-indexed, uv stripped) for merging.
const _col = new THREE.Color();
function paint(geo, color, glow = 0, extra) {
  if (geo.index) geo = geo.toNonIndexed();
  geo.deleteAttribute('uv');
  const n = geo.attributes.position.count;
  const col = new Float32Array(n * 3), gl = new Float32Array(n);
  _col.set(color);
  for (let i = 0; i < n; i++) { col[i * 3] = _col.r; col[i * 3 + 1] = _col.g; col[i * 3 + 2] = _col.b; gl[i] = glow; }
  geo.setAttribute('color', new THREE.BufferAttribute(col, 3));
  geo.setAttribute('aGlow', new THREE.BufferAttribute(gl, 1));
  if (extra) extra(geo, n);
  return geo;
}

// adaptive = true for the automatic frame-time steps: they never touch the gameplay cap (simCap)
function applyQuality(name, lock, adaptive) {
  if (!QUALITY[name]) return;
  qName = name; Q = QUALITY[name];
  if (lock !== undefined) qLocked = lock;
  if (!adaptive) simCap = Q.cap;
  const sh = Q.shadows;
  if (renderer.shadowMap.enabled !== sh) {
    renderer.shadowMap.enabled = sh;
    spots[0].castShadow = sh;
    scene.traverse(o => { if (o.material) { const ms = Array.isArray(o.material) ? o.material : [o.material]; for (const m of ms) m.needsUpdate = true; } });
  }
  ensureComposer();
  if (bloomPass) bloomPass.enabled = Q.bloom;
  prScale = 1;
  resize();
  if (typeof fxApplyQuality === 'function') fxApplyQuality();
}
