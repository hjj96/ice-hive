// ================================================================
//  Appended to the game's module scope (after inpage-sprites.js / inpage-fx.js).
//  Level tile kit: every piece is built with the game's own level builders (SlabBuilder, pBox, pBeam, pCyl, pTorus,
//  pRock, COL, MAT.props, TEX.grating / slab / hazard) in a LOCAL frame whose origin is the piece's anchor, then shot
//  with the sprite camera (SPR.shoot). Floors use a copy of makeFloorMaterial() whose snow mask comes from four
//  corner levels (Wang-style corner tiles) plus a 2 m periodic noise instead of the level-wide snow texture.
// ================================================================
{
  const KIT = {};
  // ---------------------------------------------------------------- floor material with corner snow
  function kitFloorMaterial(map, bump) {
    const m = new THREE.MeshStandardMaterial({ map, bumpMap: map, bumpScale: bump, roughness: 0.72, metalness: 0.42 });
    const u = { uC: { value: new THREE.Vector4() }, uOff: { value: new THREE.Vector2() }, uLvl: { value: new THREE.Vector2(0.2, 0.8) }, uNoise: { value: 1 } };
    m.userData.u = u;
    m.onBeforeCompile = (sh) => {
      Object.assign(sh.uniforms, u);
      sh.vertexShader = sh.vertexShader
        .replace('#include <common>', '#include <common>\nvarying vec3 vWP;\nvarying float vUp;')
        .replace('#include <begin_vertex>', '#include <begin_vertex>\nvWP = (modelMatrix * vec4(transformed, 1.0)).xyz;\nvUp = normal.y;');
      sh.fragmentShader = sh.fragmentShader
        .replace('#include <common>', `#include <common>
varying vec3 vWP;
varying float vUp;
uniform vec4 uC;
uniform vec2 uOff;
uniform vec2 uLvl;
uniform float uNoise;
float snowFill;
float kh(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
// value noise on a lattice that repeats every P cells (so the snow noise repeats every 2 m, like the texture)
float kvn(vec2 p, float P) {
  vec2 i = floor(p), f = fract(p), w = f * f * (3.0 - 2.0 * f);
  float a = kh(mod(i, P)), b = kh(mod(i + vec2(1.0, 0.0), P)), c = kh(mod(i + vec2(0.0, 1.0), P)), d = kh(mod(i + vec2(1.0, 1.0), P));
  return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}`)
        .replace('#include <map_fragment>', `#include <map_fragment>
  vec2 tc = clamp(vWP.xz + 0.5, 0.0, 1.0);
  float bil = mix(mix(uC.x, uC.y, tc.x), mix(uC.z, uC.w, tc.x), tc.y);
  vec2 wp = vWP.xz + uOff;
  float sm = mix(uLvl.x, uLvl.y, bil) + uNoise * ((kvn(wp * 2.0, 4.0) - 0.5) * 0.36 + (kvn(wp * 4.0, 8.0) - 0.5) * 0.2);
  float bar = smoothstep(0.08, 0.32, dot(diffuseColor.rgb, vec3(0.333)));
  snowFill = smoothstep(0.28, 0.72, sm) * step(0.5, vUp) * mix(0.55, 1.0, bar);
  diffuseColor.rgb = mix(diffuseColor.rgb, vec3(0.68, 0.74, 0.82), snowFill);`)
        .replace('#include <roughnessmap_fragment>', '#include <roughnessmap_fragment>\nroughnessFactor = mix(roughnessFactor, 0.92, snowFill);')
        .replace('#include <metalnessmap_fragment>', '#include <metalnessmap_fragment>\nmetalnessFactor = mix(metalnessFactor, 0.0, snowFill);');
    };
    m.customProgramCacheKey = () => 'kitfloor';
    return m;
  }
  const FMAT = { g: kitFloorMaterial(TEX.grating, 1.6), s: kitFloorMaterial(TEX.slab, 0.6) };
  // snow levels (mask value at a corner = 0 / 1): grating like the open deck (0.2 bare … 0.8 drifted),
  // slab like the game's slab cells (+0.18 bias +0.38 mask: mostly snow-covered)
  const LVL = { g: [0.2, 0.8], s: [0.46, 0.92] };
  function setSnow(k, corners, off, noise = 1, lvl = LVL[k]) {
    const u = FMAT[k].userData.u;
    u.uC.value.set(corners[0], corners[1], corners[2], corners[3]);
    u.uOff.value.set(off[0], off[1]);
    u.uLvl.value.set(lvl[0], lvl[1]);
    u.uNoise.value = noise;
  }
  const hazMat = new THREE.MeshStandardMaterial({ map: TEX.hazard, roughness: 0.8, metalness: 0.1 });

  // world-UV quad helper on a SlabBuilder: corners a, b, c, d (CCW seen from the normal side); uv(p) -> [u, v]
  function quadW(sb, a, b, c, d, n, uv) { sb.quad(a, b, c, d, n[0], n[1], n[2], uv(a), uv(b), uv(c), uv(d)); }
  const mesh = (sb, mat) => { const m = new THREE.Mesh(sb.geometry(), mat); m.frustumCulled = false; return m; };
  const props = (list) => { const m = new THREE.Mesh(mergeGeometries(list), MAT.props); m.frustumCulled = false; return m; };
  const group = (...objs) => { const g = new THREE.Group(); for (const o of objs) if (o) g.add(o); return g; };
  // ascent direction -> unit vector on the deck (n: -z, s: +z, e: +x, w: -x)
  const ASC = { n: [0, -1], s: [0, 1], e: [1, 0], w: [-1, 0] };
  const BLEED = 0.02;

  // ---------------------------------------------------------------- floors
  // flat 1 x 1 m deck tile, anchor = cell centre on the deck; phase p: world cell parity (x & 1) + 2 (z & 1)
  KIT.floor = ({ k, p, c }) => {
    const ox = (p & 1) + 0.5, oz = (p >> 1) + 0.5, sb = new SlabBuilder(), b = 0.5 + BLEED;
    const uv = (q) => [(q[0] + ox) * 0.5, (q[2] + oz) * 0.5];
    quadW(sb, [-b, 0, b], [b, 0, b], [b, 0, -b], [-b, 0, -b], [0, 1, 0], uv);
    setSnow(k, c, [ox, oz]);
    return mesh(sb, FMAT[k]);
  };
  // sloped catwalk deck (grating): rises g per metre toward `asc`
  KIT.ramp = ({ k, p, asc, g, snow }) => {
    const ox = (p & 1) + 0.5, oz = (p >> 1) + 0.5, sb = new SlabBuilder(), b = 0.5 + BLEED, [ax, az] = ASC[asc];
    const Y = (x, z) => g * (x * ax + z * az);
    const uv = (q) => [(q[0] + ox) * 0.5, (q[2] + oz) * 0.5];
    const nl = Math.hypot(1, g), n = [-g * ax / nl, 1 / nl, -g * az / nl];
    quadW(sb, [-b, Y(-b, b), b], [b, Y(b, b), b], [b, Y(b, -b), -b], [-b, Y(-b, -b), -b], n, uv);
    setSnow(k, [snow, snow, snow, snow], [ox, oz]);
    return mesh(sb, FMAT[k]);
  };
  // stair cell (slab): two 0.5 m treads at the ramp height of their centres (±0.25 g around the cell centre), boxes
  // reaching one riser + 3 cm below the lower tread; pale nosing on each tread's downhill edge (amber on the first /
  // last step of a flight: edge = 'first' | 'last' | ''), contact shadow at the riser foot
  KIT.stair = ({ asc, g, edge, snow }) => {
    const sb = new SlabBuilder(), [ax, az] = ASC[asc], parts = [], rise = g * 0.5;
    for (let t = 0; t < 2; t++) {
      // tread t spans s in [t - 1, t] * 0.5 along the ascent axis (s = signed distance uphill from the cell centre)
      const s0 = (t - 1) * 0.5, s1 = t * 0.5, top = g * (s0 + s1) / 2;
      const r0 = Math.min(s0 * ax + s0 * az, s1 * ax + s1 * az), r1 = Math.max(s0 * ax + s0 * az, s1 * ax + s1 * az);
      const x0 = ax ? r0 : -0.5 - BLEED, x1 = ax ? r1 : 0.5 + BLEED, z0 = az ? r0 : -0.5 - BLEED, z1 = az ? r1 : 0.5 + BLEED;
      sb.box(x0, z0, x1, z1, top - rise - 0.03, top);
      // nosing on the downhill edge (s0), shadow at the uphill end (foot of the next riser)
      const amber = (edge === 'first' && t === 0) || (edge === 'last' && t === 1);
      const nos = s0 + 0.06, sh = s1 - 0.08;
      if (ax) {
        pBox(parts, 0.12, 0.03, 1.0, nos * ax, top + 0.014, 0, amber ? COL.amber : COL.nosing, amber ? 0.35 : 0.12);
        pBox(parts, 0.16, 0.02, 1.0, sh * ax, top + 0.01, 0, COL.dark, 1);
      } else {
        pBox(parts, 1.0, 0.03, 0.12, 0, top + 0.014, nos * az, amber ? COL.amber : COL.nosing, amber ? 0.35 : 0.12);
        pBox(parts, 1.0, 0.02, 0.16, 0, top + 0.01, sh * az, COL.dark, 1);
      }
    }
    setSnow('s', [snow, snow, snow, snow], [0.5, 0.5]);
    return group(mesh(sb, FMAT.s), props(parts));
  };
  // hazard strip (0.42 m wide, 1 m long) lying on the deck along x or z; stripes every 0.5 m (tile seamlessly per cell)
  KIT.haz = ({ axis }) => {
    const sb = new SlabBuilder(), y = 0.012, L = 0.5 + 0.005, W = 0.21;
    if (axis === 'x') quadW(sb, [-L, y, W], [L, y, W], [L, y, -W], [-L, y, -W], [0, 1, 0], (q) => [(q[0] + 0.5) / 2, (q[2] + W) / (2 * W)]);
    else quadW(sb, [-W, y, L], [W, y, L], [W, y, -L], [-W, y, -L], [0, 1, 0], (q) => [(q[2] + 0.5) / 2, (q[0] + W) / (2 * W)]);
    return mesh(sb, hazMat);
  };

  // ---------------------------------------------------------------- platform edges seen from the camera
  // side skirt of a 0.5 m deck on the S (+z) or E (+x) edge of a cell, sloping g per metre along the edge, plus the
  // girder under the railing (0.37 m inside the edge, 0.7 m tall). Anchor = edge midpoint on the deck.
  KIT.side = ({ k, face, g }) => {
    const sb = new SlabBuilder(), parts = [], b = 0.5 + BLEED;
    if (face === 's') {
      const Y = (x) => g * x;
      quadW(sb, [-b, Y(-b) - 0.5, 0], [b, Y(b) - 0.5, 0], [b, Y(b), 0], [-b, Y(-b), 0], [0, 0, 1], (q) => [q[0] * 0.5, q[1] * 0.5]);
      pBeam(parts, -0.5, Y(-0.5) - 0.85, -0.37, 0.5, Y(0.5) - 0.85, -0.37, 0.35, 0.7, COL.girder);
    } else {
      const Y = (z) => g * z;
      quadW(sb, [0, Y(b) - 0.5, b], [0, Y(-b) - 0.5, -b], [0, Y(-b), -b], [0, Y(b), b], [1, 0, 0], (q) => [q[2] * 0.5, q[1] * 0.5]);
      pBeam(parts, -0.37, Y(-0.5) - 0.85, -0.5, -0.37, Y(0.5) - 0.85, 0.5, 0.35, 0.7, COL.girder);
    }
    setSnow(k, [0, 0, 0, 0], [0, 0]);
    return group(mesh(sb, FMAT[k]), props(parts));
  };
  // staircase side wall (slab) on the E edge (stairs ascending n / s) or the S edge (ascending e / w): the two tread
  // profiles down to the foot of the flight. kIdx = cell index from the low end; the flight's low landing is at
  // (kIdx + 0.5) * g below the cell centre and the wall goes 0.5 m below that. Anchor = edge midpoint at the cell
  // centre's ramp height.
  KIT.wall = ({ face, asc, g, kIdx }) => {
    const sb = new SlabBuilder(), [ax, az] = ASC[asc], bot = -(kIdx + 0.5) * g - 0.5;
    for (let t = 0; t < 2; t++) {
      const s0 = (t - 1) * 0.5, s1 = t * 0.5, top = g * (s0 + s1) / 2;
      const along = face === 'e' ? az : ax;   // the wall runs along the ascent axis
      const r0 = Math.min(s0 * along, s1 * along), r1 = Math.max(s0 * along, s1 * along);
      if (face === 'e') quadW(sb, [0, bot, r1], [0, bot, r0], [0, top, r0], [0, top, r1], [1, 0, 0], (q) => [q[2] * 0.5, q[1] * 0.5]);
      else quadW(sb, [r0, bot, 0], [r1, bot, 0], [r1, top, 0], [r0, top, 0], [0, 0, 1], (q) => [q[0] * 0.5, q[1] * 0.5]);
    }
    setSnow('s', [0, 0, 0, 0], [0, 0]);
    return mesh(sb, FMAT.s);
  };

  // ---------------------------------------------------------------- railings, lamps
  // two rails (0.55 / 1.05 m) along x or z, 1 m long, sloping g per metre; anchor = rail line midpoint on the deck
  KIT.rail = ({ axis, g }) => {
    const parts = [];
    for (const ry of [0.55, 1.05]) {
      if (axis === 'x') pBeam(parts, -0.5, -0.5 * g + ry, 0, 0.5, 0.5 * g + ry, 0, 0.07, 0.07, COL.rail);
      else pBeam(parts, 0, -0.5 * g + ry, -0.5, 0, 0.5 * g + ry, 0.5, 0.07, 0.07, COL.rail);
    }
    return props(parts);
  };
  KIT.post = () => { const parts = []; pBox(parts, 0.1, 1.1, 0.1, 0, 0.55, 0, COL.post); return props(parts); };
  // outer corner (flat): the post at the corner + both rails running to the cell boundaries. corner = which cell
  // corner ('nw' = -x / -z ...). Anchor = the post (0.38 m from the cell centre on both axes)
  KIT.corner = ({ corner }) => {
    const parts = [], sx = corner[1] === 'w' ? 1 : -1, sz = corner[0] === 'n' ? 1 : -1;   // direction into the cell
    for (const ry of [0.55, 1.05]) {
      pBeam(parts, 0, ry, 0, sx * 0.88, ry, 0, 0.07, 0.07, COL.rail);
      pBeam(parts, 0, ry, 0, 0, ry, sz * 0.88, 0.07, 0.07, COL.rail);
    }
    pBox(parts, 0.1, 1.1, 0.1, 0, 0.55, 0, COL.post);
    return props(parts);
  };
  // lamp post at a railing: pole 3.2 m, arm reaching 0.9 m toward `inward`, glowing head (teal / green)
  KIT.lamp = ({ inward, color }) => {
    const parts = [], [ix, iz] = ASC[inward], lc = color === 'green' ? COL.green : COL.teal;
    pBox(parts, 0.14, 3.2, 0.14, 0, 1.6, 0, COL.post);
    pBox(parts, ix ? 0.9 : 0.12, 0.1, ix ? 0.12 : 0.9, ix * 0.4, 3.15, iz * 0.4, COL.post);
    pBox(parts, 0.32, 0.12, 0.32, ix * 0.8, 3.05, iz * 0.8, lc, 1.2);
    return props(parts);
  };

  // ---------------------------------------------------------------- props
  KIT.pillar = () => {
    const parts = [];
    pBox(parts, 0.8, 3.6, 0.8, 0, 1.8, 0, COL.pillar);
    pBox(parts, 0.95, 0.3, 0.95, 0, 0.15, 0, COL.girder);
    pBox(parts, 0.95, 0.12, 0.95, 0, 3.6, 0, COL.girder);
    for (const [ox, oz] of [[0.41, 0], [-0.41, 0], [0, 0.41], [0, -0.41]]) pBox(parts, ox ? 0.04 : 0.18, 1.1, oz ? 0.04 : 0.18, ox, 2.2, oz, COL.teal, 1.6);
    return props(parts);
  };
  KIT.crate = ({ w, d, h, col }) => {
    const parts = [];
    pBox(parts, w - 0.08, h, d - 0.08, 0, h / 2, 0, [COL.crateA, COL.crateB, COL.crateC][col]);
    pBox(parts, w + 0.02, 0.08, d + 0.02, 0, h * 0.72, 0, COL.dark);
    pBox(parts, Math.min(0.5, w * 0.3), 0.06, 0.04, 0, h * 0.45, d / 2 - 0.02, COL.amber, 0.6);
    return props(parts);
  };
  KIT.beacon = () => {
    const parts = [];
    pCyl(parts, 1.3, 1.5, 0.45, 10, 0, 0.22, 0, COL.girder);
    pBox(parts, 0.7, 2.3, 0.7, 0, 1.4, 0, COL.pillar);
    for (let k = 0; k < 4; k++) { const a = k / 4 * TAU + Math.PI / 4; pBox(parts, 0.18, 1.6, 0.7, Math.cos(a) * 0.55, 1.0, Math.sin(a) * 0.55, COL.post, 0, -a); }
    pBox(parts, 0.74, 0.12, 0.74, 0, 2.0, 0, COL.amber, 1.0);
    return props(parts);
  };
  KIT.vent = () => {
    const parts = [];
    pBox(parts, 1.5, 0.12, 1.5, 0, 0.06, 0, COL.dark);
    for (let k = -2; k <= 2; k++) pBox(parts, 1.2, 0.04, 0.1, 0, 0.13, k * 0.26, 0xff5a1a, 0.9);
    return props(parts);
  };
  KIT.stud = ({ color }) => { const parts = []; pBox(parts, 0.18, 0.08, 0.18, 0, 0.04, 0, { amber: COL.amber, teal: COL.teal, green: COL.green }[color], 1.6); return props(parts); };
  // snow drift against a railing (the game scatters 90 of them along the edges) / mound beside a crate
  KIT.drift = ({ r, sy, color, seed }) => { const parts = []; pRock(parts, r, sy, 0, -0.05, 0, color, seed); return props(parts); };
  // pipe bundle hanging 0.3 m outside a platform edge (1 m segment along the edge); side = which edge of the cell
  KIT.pipes = ({ side }) => {
    const parts = [], along = side === 'n' || side === 's' ? 'x' : 'z', out = side === 's' || side === 'e' ? 0.3 : -0.3;
    for (const [dy, r, col] of [[-0.25, 0.17, COL.pipe], [-0.62, 0.12, COL.girder]]) {
      const g = new THREE.CylinderGeometry(r, r, 1.02, 8);
      g.rotateZ(Math.PI / 2); if (along === 'z') g.rotateY(-Math.PI / 2);
      g.translate(along === 'x' ? 0 : out, dy, along === 'x' ? out : 0);
      parts.push(paint(g, col));
    }
    return props(parts);
  };
  // support column under a platform (anchor = column top, which sits 0.5 m below the deck) fading into the abyss
  KIT.support = ({ light, depth }) => {
    const parts = [];
    pBox(parts, 0.7, depth, 0.7, 0, -depth / 2, 0, COL.support);
    pBox(parts, 0.9, 0.5, 0.9, 0, -0.9, 0, COL.girder);
    if (light) pBox(parts, 0.2, 0.5, 0.2, 0.46, -6, 0, COL.red, 1.5);
    return props(parts);
  };
  KIT.girder = ({ axis, len = 1 }) => { const parts = []; pBox(parts, axis === 'x' ? len : 0.4, 0.4, axis === 'x' ? 0.4 : len, 0, 0, 0, COL.girder); return props(parts); };

  // ---------------------------------------------------------------- the cargo lift (radius 10, lift-local frame:
  // centre = origin, deck = y 0). Pieces: deck (disc + pads + studs, floor layer), centre pillar, 12 ring-rail
  // segments (3 of the game's 36 each, the opening toward +z skipped), shaft band below the rim.
  const LR = 10;
  KIT.liftDeck = () => {
    const lb = new SlabBuilder();
    lb.disc(0, 0, LR, -0.6, 0.03, 48);
    const deck = mesh(lb, FMAT.g);
    setSnow('g', [0, 0, 0, 0], [0, 0], 1, [0.0, 0.0]);
    const parts = [];
    for (let k = 0; k < 4; k++) {
      const a = Math.PI / 4 + k * Math.PI / 2, x = Math.cos(a) * 5.2, z = Math.sin(a) * 5.2;
      pCyl(parts, 1.7, 1.8, 0.1, 24, x, 0.08, z, COL.girder);
      pCyl(parts, 1.15, 1.15, 0.11, 24, x, 0.09, z, 0x1a3b44);
      pTorus(parts, 1.45, 0.05, x, 0.15, z, COL.teal, 1.5);
      for (let m = 0; m < 6; m++) { const b = m / 6 * TAU; pBox(parts, 0.14, 0.06, 0.14, x + Math.cos(b) * 1.62, 0.15, z + Math.sin(b) * 1.62, COL.green, 2); }
    }
    for (let k = 0; k < 24; k++) { const a = k / 24 * TAU; pBox(parts, 0.16, 0.06, 0.16, Math.cos(a) * (LR - 0.6), 0.06, Math.sin(a) * (LR - 0.6), COL.teal, 1.8); }
    return group(deck, props(parts));
  };
  KIT.liftCenter = () => { const parts = []; pCyl(parts, 0.9, 1.1, 0.5, 16, 0, 0.25, 0, COL.pillar); pTorus(parts, 1.0, 0.05, 0, 0.5, 0, COL.teal, 1.6); return props(parts); };
  // segment s (0…11) covers the game's ring segments 3s…3s+2; anchor = the segment's middle on the ring (offset given
  // by liftRailAnchor)
  KIT.liftRailAnchor = (s) => { const a = (s * 3 + 1.5) / 36 * TAU, r = LR - 0.15; return [Math.cos(a) * r, 0, Math.sin(a) * r]; };
  KIT.liftRail = ({ s }) => {
    const parts = [], r = LR - 0.15, [cx, , cz] = KIT.liftRailAnchor(s);
    for (let k = s * 3; k < s * 3 + 3; k++) {
      const a0 = k / 36 * TAU, a1 = (k + 1) / 36 * TAU, mid = (a0 + a1) / 2;
      if (Math.abs(angDiff(mid, Math.PI / 2)) < 0.33) continue;
      const x0 = Math.cos(a0) * r - cx, z0 = Math.sin(a0) * r - cz, x1 = Math.cos(a1) * r - cx, z1 = Math.sin(a1) * r - cz;
      const len = Math.hypot(x1 - x0, z1 - z0), ang = Math.atan2(z1 - z0, x1 - x0);
      for (const y of [0.55, 1.05]) pBox(parts, len, 0.07, 0.07, (x0 + x1) / 2, y, (z0 + z1) / 2, COL.rail, 0, -ang);
      pBox(parts, 0.1, 1.1, 0.1, x0, 0.55, z0, COL.post);
    }
    return parts.length ? props(parts) : new THREE.Group();
  };
  KIT.liftShaft = () => {
    const parts = [];
    pCyl(parts, LR + 0.6, LR + 0.6, 3, 40, 0, -2.0, 0, COL.girder, 0, 0, 0, true);
    for (let k = 0; k < 16; k++) { const a = k / 16 * TAU; pBox(parts, 0.25, 0.25, 0.25, Math.cos(a) * (LR + 1.0), -3.6, Math.sin(a) * (LR + 1.0), COL.teal, 1.5); }
    return props(parts);
  };

  // ---------------------------------------------------------------- far background: distant towers (scaled down by
  // `k` so a 100 m tower fits the sprite canvas; the native draws them with setScale(k))
  KIT.tower = ({ w, h, d, ry, seed, k }) => {
    const parts = [], R = mulberry32(seed);
    pBox(parts, w, h, d, 0, -h / 2, 0, 0x10151b, 0, ry);
    for (let m = 0; m < 3; m++) pBox(parts, 0.5, 0.5, 0.5, (R() - 0.5) * w, -R() * 20, (R() - 0.5) * w, R() < 0.5 ? COL.red : COL.teal, 2);
    const o = props(parts); o.scale.setScalar(1 / k);
    return o;
  };

  // build -> shoot -> dispose (pieces are cheap; the floor materials are shared and re-parameterised per piece)
  SPR.piece = function (kind, opts, w, h, ppm, ax, ay) {
    const obj = KIT[kind](opts);
    try { return SPR.shoot(obj, w, h, ppm, [0, 0, 0], ax, ay); }
    finally { obj.traverse((o) => { if (o.geometry) o.geometry.dispose(); }); }
  };
  SPR.liftRailAnchor = (s) => KIT.liftRailAnchor(s);
}
