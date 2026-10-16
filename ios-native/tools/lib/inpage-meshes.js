// ================================================================
//  Appended to the game's own module scope by tools/lib/gamepage.mjs (export-meshes.mjs).
//  Collects the game's real geometry (buildBugGeometry, buildMarineGeos, the level built by 04-level.js,
//  the turret / medkit / glob / grenade from 07-fx.js) and its procedural canvas textures, and hands them
//  to node as flat attribute arrays (base64): position, normal, colour (linear), aGlow, aLeg + u32 indices.
//  export-meshes.mjs interleaves them into the IHM1 binary layout.
// ================================================================
const MESHX = {};
{
  function b64(u8) {
    let s = '';
    for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
    return btoa(s);
  }
  const f32b64 = (a) => b64(new Uint8Array(a.buffer, a.byteOffset, a.byteLength));

  // Normalise any game geometry to the exporter's attribute set:
  //   position, normal, color (white when absent), aGlow (0), aLeg (0,0,0) — or, for textured meshes, the
  //   uv in aLeg.xy with v flipped to a top-left image origin (Metal / PNG row order), aLeg.z = 0.
  // `matrix` (optional THREE.Matrix4) bakes an object transform. Then welded (lossless: only identical vertices
  // merge) and indexed.
  function pack(geo, { matrix = null, uv = false, color = null } = {}) {
    let g = geo.clone();
    for (const k of Object.keys(g.attributes)) if (!['position', 'normal', 'color', 'aGlow', 'aLeg', 'uv'].includes(k)) g.deleteAttribute(k);
    if (matrix) g.applyMatrix4(matrix);
    if (!g.attributes.normal) g.computeVertexNormals();
    const n = g.attributes.position.count;
    if (!g.attributes.color) {
      const c = new Float32Array(n * 3); const cc = new THREE.Color(color == null ? 0xffffff : color);
      for (let i = 0; i < n; i++) { c[i * 3] = cc.r; c[i * 3 + 1] = cc.g; c[i * 3 + 2] = cc.b; }
      g.setAttribute('color', new THREE.BufferAttribute(c, 3));
    }
    if (!g.attributes.aGlow) g.setAttribute('aGlow', new THREE.BufferAttribute(new Float32Array(n), 1));
    let hasLeg = !!g.attributes.aLeg;
    if (uv) {
      const u = g.attributes.uv, L = new Float32Array(n * 3);
      for (let i = 0; i < n; i++) { L[i * 3] = u.getX(i); L[i * 3 + 1] = 1 - u.getY(i); }
      g.setAttribute('aLeg', new THREE.BufferAttribute(L, 3));
    } else if (!hasLeg) g.setAttribute('aLeg', new THREE.BufferAttribute(new Float32Array(n * 3), 3));
    if (g.attributes.uv) g.deleteAttribute('uv');
    // de-interleave anything mergeGeometries left interleaved, then weld
    for (const k of Object.keys(g.attributes)) {
      const a = g.attributes[k];
      if (a.isInterleavedBufferAttribute || !(a.array instanceof Float32Array)) {
        const out = new Float32Array(a.count * a.itemSize);
        for (let i = 0; i < a.count; i++) for (let c = 0; c < a.itemSize; c++) out[i * a.itemSize + c] = a.getComponent(i, c);
        g.setAttribute(k, new THREE.BufferAttribute(out, a.itemSize));
      }
    }
    g = mergeVertices(g, 1e-5);
    if (!g.index) { const idx = new Uint32Array(g.attributes.position.count); for (let i = 0; i < idx.length; i++) idx[i] = i; g.setIndex(new THREE.BufferAttribute(idx, 1)); }
    const A = (k) => Float32Array.from(g.attributes[k].array);
    return {
      vcount: g.attributes.position.count,
      pos: f32b64(A('position')), nrm: f32b64(A('normal')), col: f32b64(A('color')), glow: f32b64(A('aGlow')), leg: f32b64(A('aLeg')),
      idx: b64(new Uint8Array(Uint32Array.from(g.index.array).buffer)),
      hasLeg: hasLeg && !uv, uv,
    };
  }

  // surface area and colour-weighted area of the SOURCE geometry (before packing / welding): node compares these
  // with the exported binary to prove nothing was dropped, moved or recoloured
  function srcStats(geo, matrix, color) {
    const cc = new THREE.Color(color == null ? 0xffffff : color), c0 = cc.r + cc.g + cc.b;
    const g = geo.clone(); if (matrix) g.applyMatrix4(matrix);
    const p = g.attributes.position, c = g.attributes.color, idx = g.index, n = idx ? idx.count : p.count;
    const v = (i) => idx ? idx.getX(i) : i;
    let A = 0, CA = 0;
    for (let t = 0; t < n; t += 3) {
      const a = v(t), b = v(t + 1), d = v(t + 2);
      const ux = p.getX(b) - p.getX(a), uy = p.getY(b) - p.getY(a), uz = p.getZ(b) - p.getZ(a);
      const wx = p.getX(d) - p.getX(a), wy = p.getY(d) - p.getY(a), wz = p.getZ(d) - p.getZ(a);
      const ar = 0.5 * Math.hypot(uy * wz - uz * wy, uz * wx - ux * wz, ux * wy - uy * wx);
      A += ar; CA += ar * (c ? c.getX(a) + c.getY(a) + c.getZ(a) : c0);
    }
    return { tris: n / 3, area: A, colArea: CA };
  }
  const NAMES = ['runner', 'spitter', 'brute', 'boomer'];
  const M4 = (o) => { o.updateMatrix(); return o.matrix.clone(); };

  MESHX.collect = function () {
    const out = {};
    const put = (name, geo, opt = {}, meta = {}) => { out[name] = Object.assign(pack(geo, opt), { meta, src: srcStats(geo, opt.matrix, opt.color) }); };

    // ---- bugs (the instanced swarm geometry, smudge included) and corpses
    for (let t = 0; t < 4; t++) put('bug_' + NAMES[t], bugMeshes[t].geometry, {}, { kind: 'bug', type: t, scale: BT[t].scale });
    put('corpse_generic', corpseMeshes[0].mesh.geometry, {}, { kind: 'corpse', from: 'runner' });
    put('corpse_brute', corpseMeshes[1].mesh.geometry, {}, { kind: 'corpse', from: 'brute' });

    // ---- marines: body / one leg (used twice) / gun, pivots as in makeMarine
    for (const cls of CLASS_ORDER) {
      const geos = buildMarineGeos(cls);
      put(`marine_${cls}_body`, geos.body, {}, { kind: 'marine', part: 'body', cls });
      put(`marine_${cls}_leg`, geos.leg, {}, { kind: 'marine', part: 'leg', cls });
      put(`marine_${cls}_gun`, geos.gun, {}, { kind: 'marine', part: 'gun', cls });
    }

    // ---- static level (children of `level`, identified by material)
    const lv = level.children;
    const byMat = (m) => lv.find(o => o.material === m);
    const grating = byMat(MAT.grating), slab = byMat(MAT.slab), props = byMat(MAT.props);
    const others = lv.filter(o => o !== grating && o !== slab && o !== props);
    const hz = others.find(o => o.material.map === TEX.hazard), pad = others.find(o => o.material.map === TEX.pad), gq = others.find(o => o.material.map === TEX.glow);
    if (!grating || !slab || !props || !hz || !pad || !gq) throw new Error('level children not found');
    put('level_floor_grating', grating.geometry, { uv: true, matrix: M4(grating) }, { kind: 'level' });
    put('level_floor_slab', slab.geometry, { uv: true, matrix: M4(slab) }, { kind: 'level' });
    put('level_props', props.geometry, { matrix: M4(props) }, { kind: 'level' });
    put('level_hazard', hz.geometry, { uv: true, matrix: M4(hz) }, { kind: 'level' });
    put('level_pad_mark', pad.geometry, { uv: true, matrix: M4(pad) }, { kind: 'level' });
    put('level_glow', gq.geometry, { uv: true, matrix: M4(gq) }, { kind: 'level' });
    // icy haze plane far below the decks (scene child at y = -16)
    const haze = scene.children.find(o => o.isMesh && o.position.y === -16 && o.renderOrder === -1);
    if (haze) put('level_haze', haze.geometry, { uv: true, matrix: M4(haze) }, { kind: 'level' });
    // lift: deck disc (grating) and its props, both at rest height LIFT_Y; the renderer offsets them by the rise
    const lf = liftGroup.children.find(o => o.material === MAT.grating), lp = liftGroup.children.find(o => o.material === MAT.props);
    put('lift_floor', lf.geometry, { uv: true, matrix: M4(lf) }, { kind: 'lift' });
    put('lift_props', lp.geometry, { matrix: M4(lp) }, { kind: 'lift' });

    // ---- small objects
    const [tb, th] = turret.children;
    put('turret_base', tb.geometry, {}, { kind: 'object' });
    put('turret_head', th.geometry, {}, { kind: 'object', pivotY: th.position.y });
    put('medkit', medGeo, {}, { kind: 'object' });
    put('glob', globMesh.geometry, { color: globMesh.material.color.getHex() }, { kind: 'object' });
    put('grenade', grenMesh.geometry, { color: grenMesh.material.color.getHex() }, { kind: 'object' });
    const btop = beaconFx[0].top;
    put('beacon_top', btop.geometry, { color: btop.material.color.getHex() }, { kind: 'object' });
    return out;
  };

  // ---- textures: PNG data URLs of the very canvases the game uploads
  MESHX.textures = function () {
    const out = {};
    for (const [k, t] of Object.entries(TEX)) {
      const img = t.image;
      out[k] = { png: img.toDataURL('image/png').split(',')[1], w: img.width, h: img.height, repeat: t.wrapS === THREE.RepeatWrapping, srgb: t.colorSpace === THREE.SRGBColorSpace };
    }
    // snow drift mask (DataTexture, 2 px per metre over the 128 m world; rows = +z, first row z = -64)
    {
      const img = snowTex.image, c = document.createElement('canvas'); c.width = img.width; c.height = img.height;
      const g = c.getContext('2d'), id = g.createImageData(img.width, img.height);
      id.data.set(img.data); g.putImageData(id, 0, 0);
      out.snow = { png: c.toDataURL('image/png').split(',')[1], w: img.width, h: img.height, repeat: false, srgb: false };
    }
    const haze = scene.children.find(o => o.isMesh && o.position.y === -16 && o.renderOrder === -1);
    if (haze && haze.material.map) {
      const img = haze.material.map.image;
      out.haze = { png: img.toDataURL('image/png').split(',')[1], w: img.width, h: img.height, repeat: false, srgb: true };
    }
    return out;
  };
}
window.MESHX = MESHX;
