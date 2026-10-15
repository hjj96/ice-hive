// ================================================================
//  Appended to the game's module scope (after inpage-sprites.js).
//  FX texture sources: the game's own canvas textures redrawn at a higher resolution, a few hand-drawn particle
//  shapes, and the shader effects (cryo beam, laser sights) rendered through the game's own materials.
// ================================================================
{
  const TEXFN = { grating: texGrating, slab: texSlab, hazard: texHazard, pad: texPadMark, decals: texDecals, glow: texGlow, ring: texRing, fill: texFill, lane: texLane, dash: texDash, streak: texStreak };
  function canvasRGBA(c) {
    const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
    return { w: c.width, h: c.height, b64: SPR.b64(new Uint8Array(d.buffer)) };
  }
  // Redraw one of the game's canvas textures at k x its resolution: the same drawing code runs on a pre-scaled
  // context (vector shapes stay crisp). seedAdd shifts every mulberry32 seed -> variants of the random layouts.
  SPR.hiresTex = function (name, k, seedAdd = 0) {
    const mk0 = mkCanvas, mb0 = mulberry32;
    mkCanvas = (w, h) => {
      const c = document.createElement('canvas');
      c.width = Math.round(w * k); c.height = Math.round(h * k);
      c.getContext('2d').scale(k, k);
      return c;
    };
    if (seedAdd) mulberry32 = (a) => mb0(a + seedAdd);
    try { return canvasRGBA(TEXFN[name]().image); }
    finally { mkCanvas = mk0; mulberry32 = mb0; }
  };

  // ---------------------------------------------------------------- hand-drawn particle shapes (white, glow baked)
  SPR.drawShape = function (kind, S, seed) {
    const c = document.createElement('canvas'); c.width = c.height = S;
    const g = c.getContext('2d'), R = mulberry32(1000 + seed), m = S / 2;
    if (kind === 'shard') {
      // a jagged ice splinter: long thin crystal with a bright spine, soft cold halo
      const L = S * (0.34 + R() * 0.08), W = S * (0.07 + R() * 0.04), a = R() * TAU;
      const pts = [[L, 0], [L * 0.35, W * (0.8 + R() * 0.5)], [L * (-0.1 + R() * 0.2), W * 1.1], [-L * 0.7, W * 0.4], [-L * 0.85, -W * 0.2], [-L * 0.2, -W * (0.9 + R() * 0.4)], [L * 0.45, -W * 0.7]];
      g.translate(m, m); g.rotate(a);
      g.shadowColor = 'rgba(200,235,255,0.9)'; g.shadowBlur = S * 0.08;
      g.fillStyle = 'rgba(225,245,255,0.92)';
      g.beginPath(); pts.forEach(([x, y], i) => i ? g.lineTo(x, y) : g.moveTo(x, y)); g.closePath(); g.fill();
      g.shadowBlur = 0;
      g.strokeStyle = 'rgba(255,255,255,1)'; g.lineWidth = Math.max(1, S * 0.025);
      g.beginPath(); g.moveTo(-L * 0.6, 0); g.lineTo(L * 0.9, 0); g.stroke();
    } else if (kind === 'flash') {
      // muzzle flash: 4-point star over a hot round core
      g.translate(m, m); g.rotate(R() * 0.5);
      const rg = g.createRadialGradient(0, 0, 0, 0, 0, m);
      rg.addColorStop(0, 'rgba(255,255,255,1)'); rg.addColorStop(0.25, 'rgba(255,255,255,0.55)'); rg.addColorStop(1, 'rgba(255,255,255,0)');
      g.fillStyle = rg; g.beginPath(); g.arc(0, 0, m, 0, TAU); g.fill();
      g.fillStyle = 'rgba(255,255,255,0.95)';
      for (let k = 0; k < 4; k++) {
        const l = m * (k % 2 ? 0.55 : 0.95) * (0.85 + R() * 0.15), w = m * 0.09;
        g.save(); g.rotate(k * Math.PI / 2);
        g.beginPath(); g.moveTo(0, -w); g.lineTo(l, 0); g.lineTo(0, w); g.closePath(); g.fill();
        g.restore();
      }
    } else if (kind === 'streak') {
      // velocity-aligned spark: thin bright line with a soft glow, head at +x
      c.height = Math.max(4, S >> 2);
      const H = c.height, g2 = c.getContext('2d');
      const lg = g2.createLinearGradient(0, 0, S, 0);
      lg.addColorStop(0, 'rgba(255,255,255,0)'); lg.addColorStop(0.75, 'rgba(255,255,255,0.8)'); lg.addColorStop(1, 'rgba(255,255,255,1)');
      g2.fillStyle = lg;
      g2.shadowColor = 'rgba(255,255,255,0.8)'; g2.shadowBlur = H * 0.5;
      g2.beginPath(); g2.ellipse(S * 0.55, H / 2, S * 0.43, H * 0.16, 0, 0, TAU); g2.fill();
    } else if (kind === 'chunk') {
      // chitin / debris chip: irregular dark-edged polygon (alpha-blended, tinted at runtime)
      g.translate(m, m); g.rotate(R() * TAU);
      const n = 5 + (R() * 3 | 0), pts = [];
      for (let k = 0; k < n; k++) { const a = k / n * TAU + R() * 0.5, r = m * (0.45 + R() * 0.4); pts.push([Math.cos(a) * r, Math.sin(a) * r * (0.6 + R() * 0.3)]); }
      g.fillStyle = 'rgba(255,255,255,1)';
      g.beginPath(); pts.forEach(([x, y], i) => i ? g.lineTo(x, y) : g.moveTo(x, y)); g.closePath(); g.fill();
      g.strokeStyle = 'rgba(120,120,120,1)'; g.lineWidth = Math.max(1, S * 0.05); g.stroke();
    }
    return canvasRGBA(c);
  };

  // ---------------------------------------------------------------- cryo beam (the game's beamMat), top-down
  // updateBeam(): along = u * len, half width = (0.35 + 0.95 u) -> texture x = u (0..1), y = across / 1.3
  const beamPlane = (() => {
    const g = new THREE.PlaneGeometry(1, 1, 16, 1), p = g.attributes.position, uv = g.attributes.uv;
    for (let i = 0; i < p.count; i++) {
      const u = p.getX(i) + 0.5, v = p.getY(i);
      p.setXYZ(i, u * 8, 0, -(0.35 + u * 0.95) * v * 2);
      uv.setX(i, u);
    }
    return new THREE.Mesh(g, beamMat);
  })();
  beamPlane.frustumCulled = false;
  SPR.cryoBeam = function (t, W, H) {
    beamMat.uniforms.uTime.value = t; beamMat.uniforms.uI.value = 1;
    return SPR.shootTop(beamPlane, W, H, 0, 8, -1.3, 1.3);
  };

  // ---------------------------------------------------------------- laser sights (the game's laserMat ribbons)
  // setRibbon(): a wide glow (w 0.22, colour x0.5) + a core (w 0.055, colour x3) — rendered as one tile of
  // length 0.625 m (= one repeat of the dash texture: uv.x = metres, dash lookup = uv.x * 1.6)
  const WHITE = new THREE.DataTexture(new Uint8Array([255, 255, 255, 255]), 1, 1); WHITE.needsUpdate = true;
  const laserSolid = laserMat.clone(); laserSolid.uniforms.uDash = { value: WHITE }; laserSolid.uniforms.uTime = { value: 0 };
  function ribbonGeo(L, ribbons) {
    const pos = [], col = [], uvs = [], idx = [];
    ribbons.forEach(([w, r, g, b], q) => {
      pos.push(0, 0, -w, 0, 0, w, L, 0, w, L, 0, -w);
      for (let k = 0; k < 4; k++) col.push(r, g, b);
      uvs.push(0, 0, 0, 1, L, 1, L, 0);
      idx.push(q * 4, q * 4 + 1, q * 4 + 2, q * 4, q * 4 + 2, q * 4 + 3);
    });
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
    geo.setAttribute('color', new THREE.Float32BufferAttribute(col, 3));
    geo.setAttribute('uv', new THREE.Float32BufferAttribute(uvs, 2));
    geo.setIndex(idx);
    return geo;
  }
  // hex: laser colour; turret: the turret's thin green sight
  SPR.laser = function (hex, dashed, turret, W, H, halfW) {
    _lc.setHex(hex);
    const rib = turret ? [[0.025, 0.4, 2.2, 0.6]] : [[0.22, _lc.r * 0.5, _lc.g * 0.5, _lc.b * 0.5], [0.055, _lc.r * 3, _lc.g * 3, _lc.b * 3]];
    const mat = dashed ? laserMat : laserSolid;
    mat.uniforms.uTime.value = 0;
    const mesh = new THREE.Mesh(ribbonGeo(0.625, rib), mat);
    mesh.frustumCulled = false;
    const s = SPR.shootTop(mesh, W, H, 0, 0.625, -halfW, halfW);
    mesh.geometry.dispose();
    return s;
  };
  // the game's noise texture (ragged particle edges) as raw RGBA
  SPR.noiseRGBA = function () { return { w: 64, h: 64, b64: SPR.b64(NOISE_TEX.image.data) }; };
}
