// FX textures: decals (texDecals), telegraphs / floor indicators, laser sights, cryo beam, tracers, particles.
// Everything here is a flat texture (no 3/4 projection baked in):
//   atlas Ground    — authored TOP-DOWN (image right = world +x, image up = world -z); draw inside the ground-plane
//                     container (see manifest.projection.groundPlaneTextures)
//   atlas Particles — screen-facing sprites (the web game's point sprites / billboards)
// Single-scale @2x images (point size = px / 2); set node.size from world metres (sizes below).
import path from 'node:path';
import { pageImage, pageGL, additive, maskImage, sheet2d } from './tex2d.mjs';
import { savePNG } from './pipeline.mjs';
import { display, hexLinear, srgbToLinear, linearToSrgb, toHex } from './tonemap.mjs';
import { make, downscale, crop } from './img.mjs';

const TAU = Math.PI * 2;
const smooth = (e0, e1, x) => { const t = Math.min(1, Math.max(0, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t); };
const fract = (x) => x - Math.floor(x);
const CLASS_LASER = { assault: 0xff2a22, pyro: 0xffa214, cryo: 0x30b4ff, gunner: 0x3cff58 };

// supersampled mask: fn(u, v) with u, v in [0, 1] (v down), rendered at 2x and box-filtered
function ssMask(w, h, fn, ss = 2) {
  const big = maskImage(w * ss, h * ss, (x, y) => fn((x + 0.5) / (w * ss), (y + 0.5) / (h * ss)));
  return downscale(big, ss);
}
// colour image (straight alpha) from fn(u, v) -> [r, g, b, a] in 0..1
function ssColor(w, h, fn, ss = 2) {
  const big = make(w * ss, h * ss);
  for (let y = 0; y < h * ss; y++) for (let x = 0; x < w * ss; x++) {
    const c = fn((x + 0.5) / (w * ss), (y + 0.5) / (h * ss)), o = (y * w * ss + x) * 4;
    if (c[3] <= 0) continue;
    big.data[o] = c[0] * 255; big.data[o + 1] = c[1] * 255; big.data[o + 2] = c[2] * 255; big.data[o + 3] = Math.min(1, c[3]) * 255;
  }
  return downscale(big, ss);
}
function split4(img) {
  const h = img.w / 2;
  return [crop(img, 0, 0, h, h), crop(img, h, 0, h, h), crop(img, 0, h, h, h), crop(img, h, h, h, h)];
}

export async function renderFx(ctx) {
  const { page, cat, manifest, SHEETS, PREVIEWS } = ctx;
  for (const k of Object.keys(manifest.sets)) if (manifest.sets[k].group === 'fx') delete manifest.sets[k];
  const sheets = { Ground: [], Particles: [] };
  const put = (atlas, name, img, mode, tint) => { cat.imageset(atlas, name, { '2x': img }); sheets[atlas].push({ img, mode, tint }); return name; };
  const entry = (id, e) => { manifest.sets[id] = { group: 'fx', ...e }; };
  const t0 = Date.now();

  // ------------------------------------------------------------ decals (texDecals redrawn at 2x: 256 px cells)
  const ICHOR = { runner: [0.62, 0.1, 0.22], spitter: [0.5, 0.58, 0.1], brute: [0.58, 0.12, 0.15], boomer: [0.62, 0.24, 0.08] };
  const variants = [];
  for (let v = 0; v < 3; v++) variants.push(split4(await pageImage(page, 'hiresTex', 'decals', 2, v * 101)));
  const maskNames = [];
  for (let v = 0; v < 3; v++) maskNames.push(put('Ground', `decal_splat_${v}`, variants[v][0], 'over'));
  for (let v = 0; v < 3; v++) maskNames.push(put('Ground', `decal_streak_${v}`, variants[v][1], 'over'));
  for (let v = 0; v < 2; v++) maskNames.push(put('Ground', `decal_scorch_${v}`, variants[v][3], 'over'));
  maskNames.push(put('Ground', 'decal_remains_0', variants[0][2], 'over'));
  entry('decals_mask', {
    atlas: 'Ground', kind: 'groundTexture', blend: 'multiply', frames: maskNames, pixelSize: [256, 256],
    worldSize: 'decal size s (metres) = the full texture width; the web game: ichor s = bugScale * 1.0…1.5, frost s = bugScale * 0.8, acid 1.6…2.1, blast scorch r * 1.1 (mini r * 0.8), boomer scorch 2.6, napalm scorch r * 1.8',
    note: 'texDecals cells as white/grey masks (splat, streak toward +x, scorch, colourful corpse remains). The web game multiplies the floor by mix(1, texture * tint, alpha). Tint at runtime only approximately (SpriteKit colorBlendFactor); exact pre-tinted versions are in decals_tinted. Random rotation r about +y.',
  });
  // pre-tinted: per pixel the exact web multiply factor F = sRGB(1 - a + a * tex_lin * tint) re-encoded so that
  // SpriteKit .multiply (dst * (c * a + 1 - a) with a premultiplied texture) gives dst * F
  const tinted = (img, tint) => {
    const out = make(img.w, img.h);
    for (let i = 0; i < img.w * img.h; i++) {
      const a = img.data[i * 4 + 3] / 255;
      if (a < 1 / 255) continue;
      for (let c = 0; c < 3; c++) {
        const lin = srgbToLinear(img.data[i * 4 + c] / 255) * tint[c];
        const F = linearToSrgb(1 - a + a * lin);
        out.data[i * 4 + c] = Math.min(1, Math.max(0, (F - 1 + a) / a)) * 255;
      }
      out.data[i * 4 + 3] = a * 255;
    }
    return out;
  };
  const tintNames = [];
  for (const [id, tint] of Object.entries(ICHOR)) {
    for (let v = 0; v < 2; v++) tintNames.push(put('Ground', `decal_ichor_${id}_splat_${v}`, tinted(variants[v][0], tint), 'mul'));
    for (let v = 0; v < 2; v++) tintNames.push(put('Ground', `decal_ichor_${id}_streak_${v}`, tinted(variants[v][1], tint), 'mul'));
  }
  for (let v = 0; v < 2; v++) tintNames.push(put('Ground', `decal_acid_${v}`, tinted(variants[v][0], [0.42, 0.6, 0.06]), 'mul'));
  for (let v = 0; v < 2; v++) tintNames.push(put('Ground', `decal_frost_${v}`, tinted(variants[v][0], [0.72, 0.84, 0.98]), 'mul'));
  for (let v = 0; v < 2; v++) tintNames.push(put('Ground', `decal_burn_${v}`, tinted(variants[v][3], [0.1, 0.08, 0.07]), 'mul'));
  entry('decals_tinted', {
    atlas: 'Ground', kind: 'groundTexture', blend: 'multiply', frames: tintNames, pixelSize: [256, 256],
    pattern: 'decal_ichor_{runner|spitter|brute|boomer}_{splat|streak}_{0|1} · decal_acid_{v} · decal_frost_{v} · decal_burn_{v} (scorch)',
    note: 'exact web stain colours baked in: SKSpriteNode(blendMode: .multiply), no colour tint; zRotation = r - π/4 inside the ground container. Ichor uses splat or streak 50/50 (fxBugDeath); frozen kills leave decal_frost; acid globs decal_acid; blasts / boomers / napalm decal_burn. The web game keeps a ring buffer of Q.decals stains (500 / 1000 / 1500).',
    tints: { ichor: ICHOR, acid: [0.42, 0.6, 0.06], frost: [0.72, 0.84, 0.98], burn: [0.1, 0.08, 0.07] },
  });

  // ------------------------------------------------------------ telegraphs, floor indicators, glow pools
  const tele = [];
  tele.push(put('Ground', 'tele_ring', await pageImage(page, 'hiresTex', 'ring', 2), 'add'));
  tele.push(put('Ground', 'tele_fill', await pageImage(page, 'hiresTex', 'fill', 2), 'add'));
  tele.push(put('Ground', 'tele_lane', await pageImage(page, 'hiresTex', 'lane', 2), 'add'));
  tele.push(put('Ground', 'glow', await pageImage(page, 'hiresTex', 'glow', 4), 'add'));
  // ringIndMat (beacon / lift / revive circles): the ring band, its 40 dashes and the soft inner disc, white
  const S = 512, P = (u, v) => [u * 2 - 1, 1 - v * 2];
  const ringBand = (r) => smooth(0.84, 0.865, r) * (1 - smooth(0.955, 0.98, r));
  tele.push(put('Ground', 'ind_ring', ssMask(S, S, (u, v) => { const [x, y] = P(u, v); return ringBand(Math.hypot(x, y)); }), 'add'));
  tele.push(put('Ground', 'ind_segments', ssMask(S, S, (u, v) => {
    const [x, y] = P(u, v), ang = fract(Math.atan2(x, y) / TAU + 1);
    return ringBand(Math.hypot(x, y)) * (fract(ang * 40) >= 0.3 ? 1 : 0);
  }), 'add'));
  tele.push(put('Ground', 'ind_inner', ssMask(256, 256, (u, v) => { const [x, y] = P(u, v); return 1 - smooth(0, 0.86, Math.hypot(x, y)); }), 'add'));
  entry('telegraphs', {
    atlas: 'Ground', kind: 'groundTexture', blend: 'add', frames: tele,
    note: 'white, tint at runtime (SKSpriteNode color + colorBlendFactor 1, blendMode .add). tele_ring: pulsing warning / expanding shock rings and the team rings under marines (diameter = 2r; team ring 1.9 m player / 1.5 m bots, laser colour x0.55 / x0.32). tele_fill: acid landing disc growing 0.12→1 x 2r. tele_lane: brute charge lane (width w across x, length along image-up = charge direction, chevrons point up; zRotation = atan2(-dx, -dz) - π/4, centred half-way along the lane; red (1, .18, .1) pulsing 0.55 + 0.45 sin(18 t) during the 0.8 s wind-up, then 1.3 fading while charging). glow: soft light pool (floor splashes, lamp / vent / pillar pools: size = diameter, colour x0.3). ind_*: ringIndMat circles (diameter = 2r; beacon r 4.6, lift r 9.7, revive r 1.5): draw ind_segments at 0.35 x colour for the unfilled part, ind_ring at 1.7 x colour masked to the progress pie (starts at image-up = world -z, runs clockwise in the top-down texture), ind_inner at 0.05 x colour pulsing 0.6 + 0.4 sin(3t − 8r).',
    sizes: { tele_ring: 'diameter', tele_fill: 'diameter', tele_lane: 'w x len', glow: 'diameter', ind_ring: 'diameter (ring band at r 0.84…0.98 of the half size)' },
  });
  // landing pad marking (11 x 11 m) and the hazard stripe (repeats along x; the level kit uses a 0.5 m period)
  const marks = [];
  marks.push(put('Ground', 'pad_mark', await pageImage(page, 'hiresTex', 'pad', 2), 'over'));
  marks.push(put('Ground', 'hazard_stripe', await pageImage(page, 'hiresTex', 'hazard', 2), 'over'));
  entry('ground_marks', { atlas: 'Ground', kind: 'groundTexture', blend: 'alpha', frames: marks, note: 'pad_mark: landing pad marking, 11 x 11 m centred on the start point; hazard_stripe: amber/black stripes (the web game maps 1.6 m per texture width along the edge, 0.42 m across)' });

  // ------------------------------------------------------------ laser sights (laserMat), cryo beam (beamMat), tracers
  const lasers = [];
  const LW = 64, LH = 48;   // one dash repeat (0.625 m) x 0.44 m: 102 px/m
  for (const [cls, hex] of Object.entries(CLASS_LASER)) {
    lasers.push(put('Ground', `laser_${cls}`, additive(await pageGL(page, 'laser', LW, LH, hex, true, false, LW, LH, 0.22)), 'add'));
  }
  lasers.push(put('Ground', 'laser_turret', additive(await pageGL(page, 'laser', LW, 8, 0, true, true, LW, 8, 0.03)), 'add'));
  entry('lasers', {
    atlas: 'Ground', kind: 'groundTexture', blend: 'add', frames: lasers, pixelSize: [LW, LH],
    worldSize: [0.625, 0.44], note: 'laser sights (setRibbon x2: glow 0.44 m wide at colour x0.5 + core 0.11 m at colour x3), colours baked, rendered through the web laserMat. Uniform along x: stretch xScale to the sight length (the web dash texture samples .r of a white canvas, so the shipped web lasers are solid too). Fade the far end to 15 % when nothing is hit (an alpha gradient or a second, fading sprite), 1.6x brighter while firing. laser_turret: 0.06 m wide green turret sight (pixelSize 64 x 8).',
  });
  const beam = [];
  for (let k = 0; k < 8; k++) beam.push(put('Ground', `cryo_beam_${k}`, additive(await pageGL(page, 'cryoBeam', 512, 168, k / 8 / 3.2, 512, 168)), 'add'));
  entry('cryo_beam', {
    atlas: 'Ground', kind: 'groundTexture', blend: 'add', frames: beam, pixelSize: [512, 168], loop: true, fps: 25.6,
    note: 'the cryo beam (beamMat, colours baked): texture x = along the beam 0…beamLen (scale xScale to the current length), texture y = across ±1.3 m (the beam widens 0.7 → 2.6 m, so keep the y size at 2.6 m). Starts at the muzzle; the web beam drops from muzzle height 1.2 m to 0.5 m along its length. Flicker alpha 0.85 + 0.15 sin(40 t).',
  });
  const TR = { assault: [2.6, 0.35, 0.25], gunner: [2.4, 1.9, 0.7], turret: [0.7, 2.4, 0.8] }, trn = [];
  for (const [id, c] of Object.entries(TR)) {
    trn.push(put('Ground', `tracer_${id}`, ssColor(128, 8, (u) => { const d = display(c.map(x => x * u)); const m = Math.max(...d); return m > 0 ? [d[0] / m, d[1] / m, d[2] / m, m] : [0, 0, 0, 0]; }), 'add'));
  }
  entry('tracers', { atlas: 'Ground', kind: 'groundTexture', blend: 'add', frames: trn, pixelSize: [128, 8], note: 'projectile tracers (head at +x, fading to the tail): length min(2.4, speed * 0.028) m, width 0.15 m (assault) / 0.1 m (gunner, turret), 1.2 m above the deck' });

  // ------------------------------------------------------------ particles (the PA / PN point sprite shader)
  const nz = await pageImage(page, 'noise');
  const N = (u, v) => {
    // texture2D on the 64 x 64 repeat / linear noise
    const x = u * 64 - 0.5, y = v * 64 - 0.5, xi = Math.floor(x), yi = Math.floor(y), fx = x - xi, fy = y - yi;
    const at = (i, j) => nz.data[((((j % 64) + 64) % 64) * 64 + (((i % 64) + 64) % 64)) * 4] / 255;
    return (at(xi, yi) * (1 - fx) + at(xi + 1, yi) * fx) * (1 - fy) + (at(xi, yi + 1) * (1 - fx) + at(xi + 1, yi + 1) * fx) * fy;
  };
  const ragged = (seed, add) => (u, v) => {
    const qx = u - 0.5, qy = v - 0.5;
    const n = N(qx * 0.31 + seed * 7.31, qy * 0.31 + seed * 3.17) * 0.6 + N(qx * 0.69 - seed * 2.93, qy * 0.69 - seed * 5.71) * 0.4;
    const d = Math.hypot(qx, qy) * 2 * (0.75 + 0.5 * n);
    const a = 1 - smooth(0, 1, d);
    return add ? a * a : smooth(0, 0.6, a);
  };
  const SEEDS = [0.13, 0.37, 0.61, 0.89];
  const parts = [];
  SEEDS.forEach((s, i) => parts.push(put('Particles', `p_soft_${i}`, ssMask(128, 128, ragged(s, true)), 'add')));
  SEEDS.forEach((s, i) => parts.push(put('Particles', `p_puff_${i}`, ssMask(128, 128, ragged(s, false)), 'over')));
  parts.push(put('Particles', 'p_dot', ssMask(64, 64, (u, v) => { const a = 1 - smooth(0, 1, Math.hypot(u - 0.5, v - 0.5) * 2); return a; }), 'add'));
  parts.push(put('Particles', 'p_spark', ssMask(32, 32, (u, v) => { const a = 1 - smooth(0, 1, Math.hypot(u - 0.5, v - 0.5) * 2); return a * a; }), 'add'));
  parts.push(put('Particles', 'p_snow', ssMask(16, 16, (u, v) => 1 - smooth(0.2, 1, Math.hypot(u - 0.5, v - 0.5) * 2)), 'over'));
  parts.push(put('Particles', 'p_streak', await pageImage(page, 'drawShape', 'streak', 64, 0), 'add'));
  for (let k = 0; k < 2; k++) parts.push(put('Particles', `p_flash_${k}`, await pageImage(page, 'drawShape', 'flash', 128, k), 'add'));
  for (let k = 0; k < 3; k++) parts.push(put('Particles', `p_shard_${k}`, await pageImage(page, 'drawShape', 'shard', 64, k), 'add'));
  for (let k = 0; k < 3; k++) parts.push(put('Particles', `p_chunk_${k}`, await pageImage(page, 'drawShape', 'chunk', 32, k), 'over'));
  for (let k = 0; k < 2; k++) {
    const vS = SEEDS[k * 2];
    parts.push(put('Particles', `p_mist_${k}`, ssMask(256, 256, (u, v) => {
      const qx = u - 0.5, qy = v - 0.5, d = Math.hypot(qx, qy) * 2;
      return (0.75 + 0.25 * Math.sin(qx * 9 + vS * 30) * Math.sin(qy * 7 - vS * 17)) * (1 - smooth(0.1, 1, d));
    }, 1), 'over'));
  }
  entry('particles', {
    atlas: 'Particles', kind: 'particle', frames: parts,
    blend: { p_soft: 'add', p_dot: 'add', p_spark: 'add', p_streak: 'add', p_flash: 'add', p_shard: 'add', p_puff: 'alpha', p_chunk: 'alpha', p_snow: 'alpha', p_mist: 'alpha' },
    note: 'white, tinted at runtime. p_soft_* = the additive PA sprite (fire, sparks, frost, glows; noise-ragged edge, a²), p_puff_* = the alpha PN sprite (smoke, steam, ichor droplets, debris). Sprite size = the emit() size in metres (diameter) * 24 pt, interpolated s0 → s1 over the life. Colour = the emit() colour converted with manifest.colour (ACES + sRGB); alpha ramps: kind 0 a*(1-t), kind 1 fire (see fire frames), kind 2 smoke a*min(1, 6t)*(1-t), kind 3 spark a*(1-t)^2. p_streak: velocity-aligned spark (head +x). p_flash: muzzle flash. p_shard: frost shatter splinters. p_chunk: chitin chips. p_snow: snowflake (0.025…0.065 m). p_mist: drifting mist banks (6…12 m, colour (0.62,0.72,0.84), alpha ≈ 0.1).',
  });
  // fire ramps baked into 8-frame lifetimes (kind 1: white-yellow -> orange -> deep red -> gone)
  const fireCol = (c0, t) => {
    const u = t * 1.6;
    if (u < 1) return [c0[0] + (1 - c0[0]) * u, c0[1] + (0.42 - c0[1]) * u, c0[2] + (0.08 - c0[2]) * u];
    const v = Math.min(1, u - 1);
    return [1 + (0.5 - 1) * v, 0.42 + (0.06 - 0.42) * v, 0.08 + (0.02 - 0.08) * v];
  };
  const fire = [];
  const FIRES = [['fire_pyro', [1, 0.78, 0.4], 0.5, true], ['fire_blast', [1, 0.55, 0.2], 0.45, true], ['fireball', [1.0, 0.42, 0.12], 0.85, false]];
  for (const [id, c0, a0, add] of FIRES) {
    for (let k = 0; k < 8; k++) {
      const t = (k + 0.5) / 8, col = display(fireCol(c0, t)), alpha = a0 * (1 - t * t);
      const shape = ragged(SEEDS[k % 4], add);
      fire.push(put('Particles', `${id}_${k}`, ssColor(128, 128, (u, v) => [col[0], col[1], col[2], shape(u, v) * alpha]), add ? 'add' : 'over'));
    }
  }
  entry('fire', {
    atlas: 'Particles', kind: 'particle', frames: fire, frames_per_life: 8, blend: { fire_pyro: 'add', fire_blast: 'add', fireball: 'alpha' },
    note: 'kind-1 fire particles with the colour + alpha ramp baked: play frames 0…7 evenly over the particle life (no tint). fire_pyro: flamethrower (start (1, .78, .4), a .5, size 0.3 → 1.4…2.1 m, life 0.42…0.58 s, speed 11…15 m/s); fire_blast: explosion / napalm cores (start (1, .55, .2), a .45); fireball: the alpha-blended billowing fireball body (start (1, .42, .12), a .85, size 1.0…1.6 → 2.2…3.4 m).',
  });
  // beacon light beam: open cylinder 0.7 m wide, 60 m tall, additive, (1 - y)^2 fade upward
  const bb = put('Particles', 'beacon_beam', ssMask(32, 512, (u, v) => { const y = 1 - v; return (1 - y) * (1 - y) * smooth(0, 0.08, u) * smooth(0, 0.08, 1 - u); }), 'add');
  entry('beacon_beam', { atlas: 'Particles', kind: 'billboard', blend: 'add', frames: [bb], pixelSize: [32, 512], worldSize: [0.7, 60], anchor: [0.5, 0], note: 'vertical beam standing on the beacon (bottom = deck): screen height = 60 m * 0.544639 * 24 pt; tint with the beacon state colour * intensity (charging 0.25 + 0.2 sin(10t), done 0.6)' });

  // ------------------------------------------------------------ colour conversion table for the native port
  manifest.colour = {
    note: 'web colours are linear HDR values pushed through ACES filmic + sRGB. display(c) below = that conversion (tools/lib/tonemap.mjs); use it for particle / light tints. Hex constants in the web code (0xRRGGBB) are sRGB already: linear = srgbToLinear(hex).',
    examples: Object.fromEntries([
      ['white', [1, 1, 1]], ['spark', [1.0, 0.75, 0.4]], ['frost', [0.45, 0.75, 1.0]], ['acid', [0.7, 1.0, 0.15]], ['pulse', [0.4, 1, 0.9]],
      ['heal', [0.3, 1, 0.5]], ['smoke', [0.06, 0.055, 0.06]], ['steam', [0.8, 0.85, 0.92]],
      ...Object.entries(CLASS_LASER).map(([k, hex]) => ['laser_' + k, hexLinear(hex)]),
    ].map(([k, c]) => [k, { linear: c.map(x => +x.toFixed(3)), display: toHex(display(c)) }])),
  };

  // ------------------------------------------------------------ sheets + previews
  for (const [atlas, items] of Object.entries(sheets)) {
    savePNG(path.join(SHEETS, `fx_${atlas.toLowerCase()}.png`), sheet2d(items, { cols: 10, cell: 160 }));
  }
  savePNG(path.join(PREVIEWS, 'fx.png'), downscale(sheet2d([...sheets.Ground, ...sheets.Particles].filter((_, i) => i % 2 === 0), { cols: 12, cell: 96 }), 1));
  console.log(`  fx: ${sheets.Ground.length} ground + ${sheets.Particles.length} particle textures, ${((Date.now() - t0) / 1000).toFixed(1)} s`);
}
