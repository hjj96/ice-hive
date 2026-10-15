// ================================================================
//  Appended to the game's own module scope by tools/lib/gamepage.mjs.
//  Orthographic 3/4 renderer for SpriteKit sprites: same yaw / pitch as the web camera (CAM_YAW, CAM_PITCH),
//  transparent background, a fixed bright "full light" rig. Every builder below calls the game's functions.
// ================================================================
const SPR = {};
{
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = 16;
  const R2 = new THREE.WebGLRenderer({ canvas, antialias: false, alpha: true, premultipliedAlpha: false, preserveDrawingBuffer: true, stencil: false });
  R2.setPixelRatio(1);
  R2.toneMapping = THREE.ACESFilmicToneMapping;
  R2.toneMappingExposure = 1.0;
  R2.outputColorSpace = THREE.SRGBColorSpace;
  R2.setClearColor(0x000000, 0);
  const gl = R2.getContext();
  const S2 = new THREE.Scene();
  // "full light" rig: the moon from the game's direction, a cool sky dome and a warm fill from the viewer
  // (the flashlights). The native game darkens these sprites with its own light map.
  const RIG = {
    hemi: new THREE.HemisphereLight(0xa9b9d8, 0x1a2029, 1.25),
    key: new THREE.DirectionalLight(0xe2e9f8, 2.5),
    fill: new THREE.DirectionalLight(0xfff0dc, 1.15),
  };
  RIG.key.position.set(-25, 60, 35);
  RIG.fill.position.set(0.55, 1.25, 1.0);
  S2.add(RIG.hemi, RIG.key, RIG.key.target, RIG.fill, RIG.fill.target);
  const BASE = { hemi: RIG.hemi.intensity, key: RIG.key.intensity, fill: RIG.fill.intensity };
  function lightsOn(k) { RIG.hemi.intensity = BASE.hemi * k; RIG.key.intensity = BASE.key * k; RIG.fill.intensity = BASE.fill * k; }

  const cam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0.1, 400);
  const DIR = new THREE.Vector3(Math.sin(CAM_YAW) * Math.cos(CAM_PITCH), Math.sin(CAM_PITCH), Math.cos(CAM_YAW) * Math.cos(CAM_PITCH));

  function b64(u8) {
    let s = '';
    for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
    return btoa(s);
  }
  // Render `obj` so that world point `anchor` lands on pixel (ax, ay) (from the top-left) of a w x h image.
  function shoot(obj, w, h, ppm, anchor, ax, ay) {
    if (canvas.width !== w || canvas.height !== h) R2.setSize(w, h, false);
    const l = -ax / ppm, r = (w - ax) / ppm, t = ay / ppm, b = -(h - ay) / ppm;
    cam.left = l; cam.right = r; cam.top = t; cam.bottom = b; cam.updateProjectionMatrix();
    cam.position.set(anchor[0] + DIR.x * 150, anchor[1] + DIR.y * 150, anchor[2] + DIR.z * 150);
    cam.up.set(0, 1, 0);
    cam.lookAt(anchor[0], anchor[1], anchor[2]);
    cam.updateMatrixWorld();
    S2.add(obj);
    R2.render(S2, cam);
    S2.remove(obj);
    const buf = new Uint8Array(w * h * 4);
    gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, buf);
    return b64(buf);
  }
  SPR.shoot = shoot;
  SPR.lightsOn = lightsOn;
  SPR.RIG = RIG;

  // ---------------------------------------------------------------- bugs
  // split the game's bug geometry into the body and the dark contact smudge (aLeg.z flag) so the smudge
  // becomes its own shadow sprite
  function splitSmudge(geo, keepSmudge) {
    const g = geo.clone(), L = g.attributes.aLeg, idx = g.index.array, keep = [];
    for (let i = 0; i < idx.length; i += 3) {
      const s = L.getZ(idx[i]) > 0.5;
      if (s === keepSmudge) keep.push(idx[i], idx[i + 1], idx[i + 2]);
    }
    g.setIndex(keep);
    return g;
  }
  const bugGeo = {};
  function bugMesh(type, part) {
    const key = type + part;
    if (!bugGeo[key]) {
      const base = buildBugGeometry(type);
      const geo = splitSmudge(base, part === 'smudge');
      geo.setAttribute('iAnim', new THREE.InstancedBufferAttribute(new Float32Array(4), 4));
      const mesh = new THREE.InstancedMesh(geo, part === 'smudge' ? new THREE.MeshBasicMaterial({ color: 0x000000 }) : MAT.bug, 1);
      mesh.instanceColor = new THREE.InstancedBufferAttribute(new Float32Array(3), 3);
      mesh.frustumCulled = false;
      bugGeo[key] = mesh;
    }
    return bugGeo[key];
  }
  const _m = new THREE.Matrix4();
  // pose: { hd, ph, s (uniform scale), sy (vertical scale), pitch (nose-up climb tilt), v (brightness),
  //         flash, burn, frost, y (lift) }
  SPR.bug = function (type, part, pose, w, h, ppm, ax, ay) {
    const mesh = bugMesh(type, part);
    const s = pose.s, sy = pose.sy ?? s, c = Math.cos(pose.hd), sn = Math.sin(pose.hd);
    const a = mesh.instanceMatrix.array;
    if (pose.pitch) {
      const p = pose.pitch, cp = Math.cos(p), sp = Math.sin(p);
      a[0] = c * s; a[1] = 0; a[2] = -sn * s; a[3] = 0;
      a[4] = -sn * sp * sy; a[5] = cp * sy; a[6] = -c * sp * sy; a[7] = 0;
      a[8] = sn * cp * s; a[9] = sp * s; a[10] = c * cp * s; a[11] = 0;
    } else {
      a[0] = c * s; a[1] = 0; a[2] = -sn * s; a[3] = 0;
      a[4] = 0; a[5] = sy; a[6] = 0; a[7] = 0;
      a[8] = sn * s; a[9] = 0; a[10] = c * s; a[11] = 0;
    }
    a[12] = 0; a[13] = pose.y || 0; a[14] = 0; a[15] = 1;
    mesh.instanceMatrix.needsUpdate = true;
    const v = pose.v ?? 1;
    mesh.instanceColor.array.set([v, v * (pose.vg ?? 1), v]); mesh.instanceColor.needsUpdate = true;
    const an = mesh.geometry.attributes.iAnim;
    an.array.set([pose.ph || 0, pose.flash || 0, pose.burn || 0, pose.frost || 0]); an.needsUpdate = true;
    return shoot(mesh, w, h, ppm, [0, 0, 0], ax, ay);
  };

  // ---------------------------------------------------------------- corpses (the game's corpse geometry: curled
  // legs, flattened, Lambert) tinted like addCorpse() does
  const corpseGeo = {};
  const corpseMat = new THREE.MeshLambertMaterial({ vertexColors: true });
  SPR.corpse = function (type, rot, sc, tint, w, h, ppm, ax, ay) {
    if (!corpseGeo[type]) { const m = new THREE.InstancedMesh(buildBugGeometry(type, true), corpseMat, 1); m.instanceColor = new THREE.InstancedBufferAttribute(new Float32Array(3), 3); m.frustumCulled = false; corpseGeo[type] = m; }
    const m = corpseGeo[type];
    _m.makeRotationY(rot).scale(new THREE.Vector3(sc, sc, sc)); _m.setPosition(0, 0.01, 0);
    m.setMatrixAt(0, _m); m.instanceMatrix.needsUpdate = true;
    m.instanceColor.array.set(tint); m.instanceColor.needsUpdate = true;
    return shoot(m, w, h, ppm, [0, 0, 0], ax, ay);
  };

  // ---------------------------------------------------------------- marines (makeMarine + renderMarines poses)
  const marines = {};
  function marineRig(cls) {
    if (marines[cls]) return marines[cls];
    const geos = buildMarineGeos(cls);
    const mat = makeGlowMaterial({ snow: false, roughness: 0.55, metalness: 0.5 });
    const g = new THREE.Group(); g.rotation.order = 'YXZ';
    const body = new THREE.Mesh(geos.body, mat);
    const legL = new THREE.Mesh(geos.leg, mat), legR = new THREE.Mesh(geos.leg, mat);
    legL.position.set(-0.13, 0.78, 0); legR.position.set(0.13, 0.78, 0);
    const gun = new THREE.Mesh(geos.gun, mat); gun.position.set(0.2, 1.12, 0.08);
    g.add(body, legL, legR, gun);
    g.scale.setScalar(1.12);
    const outer = new THREE.Group(); outer.add(g);
    return (marines[cls] = { outer, g, body, legL, legR, gun, mat });
  }
  // pose: { hd, anim: 'run'|'idle'|'dash'|'downed', ph (walk phase), spin (gunner barrel angle) }
  SPR.marine = function (cls, pose, w, h, ppm, ax, ay) {
    const m = marineRig(cls);
    m.g.rotation.set(0, pose.hd, 0);
    m.g.position.set(0, 0, 0);
    m.legL.rotation.set(0, 0, 0); m.legR.rotation.set(0, 0, 0);
    m.body.position.y = 0;
    m.gun.position.z = 0.08; m.gun.rotation.z = pose.spin || 0;
    if (pose.anim === 'downed') {
      m.g.position.y = 0.28; m.g.rotation.x = -1.35;
      m.legL.rotation.x = 0.2; m.legR.rotation.x = -0.1;
    } else {
      m.g.rotation.x = pose.anim === 'dash' ? 0.35 : 0;
      const w1 = pose.anim === 'run' || pose.anim === 'strafe' ? 1 : pose.anim === 'dash' ? 0.6 : 0;
      const sw = Math.sin(pose.ph || 0) * 0.75 * w1;
      // renderMarines(): legs swing along the movement direction relative to the aim (rel = cos(move - aim))
      const rel = pose.rel ?? 1;
      m.legL.rotation.x = sw * rel; m.legR.rotation.x = -sw * rel;
      m.legL.rotation.z = sw * 0.4 * (1 - Math.abs(rel)); m.legR.rotation.z = -m.legL.rotation.z;
      m.body.position.y = Math.abs(Math.sin(pose.ph || 0)) * 0.05 * w1;
    }
    return shoot(m.outer, w, h, ppm, [0, 0, 0], ax, ay);
  };

  // ---------------------------------------------------------------- small props (turret, medkit, globs, beacon top)
  const props = {};
  function propObj(name) {
    if (props[name]) return props[name];
    let o;
    if (name === 'turret_base') o = new THREE.Mesh(turret.children[0].geometry, MAT.props);
    else if (name === 'turret_head') { o = new THREE.Group(); const h = new THREE.Mesh(turret.children[1].geometry, MAT.props); h.position.y = 0.95; o.add(h); }
    else if (name === 'medkit') o = new THREE.Mesh(medGeo, MAT.props);
    else if (name === 'glob') o = new THREE.Mesh(globMesh.geometry, new THREE.MeshBasicMaterial({ color: 0xc8ff3a }));
    else if (name === 'grenade') o = new THREE.Mesh(grenMesh.geometry, new THREE.MeshBasicMaterial({ color: 0xffc040 }));
    else if (name === 'beacon_top') o = new THREE.Mesh(new THREE.OctahedronGeometry(0.42, 0), new THREE.MeshLambertMaterial({ color: 0xffffff, emissive: 0x9a9a9a, flatShading: true }));
    const wrap = new THREE.Group(); wrap.add(o);
    return (props[name] = { wrap, o });
  }
  SPR.prop = function (name, rotY, w, h, ppm, ax, ay) {
    const p = propObj(name);
    p.wrap.rotation.set(0, rotY || 0, 0);
    return shoot(p.wrap, w, h, ppm, [0, 0, 0], ax, ay);
  };

  // ---------------------------------------------------------------- the game's canvas textures, as raw RGBA
  SPR.tex = function (name) {
    const c = TEX[name].image, g = c.getContext('2d'), d = g.getImageData(0, 0, c.width, c.height).data;
    return { w: c.width, h: c.height, b64: b64(new Uint8Array(d.buffer)) };
  };
  SPR.noise = function () { return { w: 64, h: 64, b64: b64(NOISE_TEX.image.data) }; };
}
window.__S = SPR;
