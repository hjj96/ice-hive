// Level tile kit: modular 1 m pieces that rebuild «Станция Кельвин-9» (and future generated stations) from the walk
// grid + height field. Built in-page by inpage-level.js with the game's own level builders and materials.
// Atlases: Level (lit, @2x + @3x), LevelGlow (additive emissive layer, @2x).
import path from 'node:path';
import { MPPM, SIN_P, COS_P, FOG, savePNG } from './pipeline.mjs';
import { make, draw, addOnto, downscale } from './img.mjs';

const S2 = Math.SQRT1_2;
const s6 = (v) => Math.ceil(v / 6) * 6;
// canvas + anchor for a piece whose geometry lies inside the local box lo..hi (anchor = local origin)
export function cvBox(lo, hi, m = 0.12) {
  let u0 = 1e9, u1 = -1e9, v0 = 1e9, v1 = -1e9;
  for (const x of [lo[0], hi[0]]) for (const y of [lo[1], hi[1]]) for (const z of [lo[2], hi[2]]) {
    const u = (x - z) * S2, v = y * COS_P - (x + z) * S2 * SIN_P;
    u0 = Math.min(u0, u); u1 = Math.max(u1, u); v0 = Math.min(v0, v); v1 = Math.max(v1, v);
  }
  const AX = s6(Math.max(0, -u0 + m) * MPPM), AY = s6(Math.max(0, v1 + m) * MPPM);
  return { canvas: [AX + s6(Math.max(0, u1 + m) * MPPM), AY + s6(Math.max(0, -v0 + m) * MPPM)], anchor: [AX, AY] };
}
// signed slope -> name code: 0 -> '000', 0.1875 -> '188', -0.15 -> 'm150'
export const code = (g) => (g < 0 ? 'm' : '') + String(Math.round(Math.abs(g) * 1000)).padStart(3, '0');
const CORNER_BITS = 'bit 1 = NW (-x,-z) corner snowy, 2 = NE (+x,-z), 4 = SW (-x,+z), 8 = SE (+x,+z)';
const RAMP_G = [0.15, 0.1875, 0.25], STAIR_G = [0.2143, 0.25, 0.3], RAIL_G = [0, 0.15, 0.1875, 0.2143, 0.25, 0.3];
const ASCS = ['n', 's', 'e', 'w'];
const CRATES = [[1, 1, [0.8, 0.9, 1.0, 1.1, 1.2, 1.3]], [2, 1, [0.9, 1.0, 1.1]], [1, 2, [1.2]], [2, 2, [1.4]]];

export async function renderLevel(ctx) {
  const { set, manifest, previewBegin, previewEnd, images, SHEETS, PREVIEWS } = ctx;
  for (const k of Object.keys(manifest.sets)) if (manifest.sets[k].group === 'level') delete manifest.sets[k];
  const t0 = Date.now();
  previewBegin('level');
  const L = (meta) => ({ group: 'level', ...meta });
  const piece = (name, kind, opts) => ({ name, fn: 'piece', args: [kind, opts] });

  // ---------------------------------------------------------------- floors (Wang corner tiles x texture phase)
  for (const k of ['g', 's']) {
    const frames = [];
    for (let p = 0; p < 4; p++) for (let c = 0; c < 16; c++) {
      frames.push(piece(`floor_${k}_p${p}_c${String(c).padStart(2, '0')}`, 'floor', { k, p, c: [c & 1, (c >> 1) & 1, (c >> 2) & 1, (c >> 3) & 1] }));
    }
    await set({ id: `floor_${k === 'g' ? 'grating' : 'slab'}`, atlas: 'Level', ...cvBox([-0.55, -0.02, -0.55], [0.55, 0.02, 0.55]), frames,
      meta: L({ kind: 'floor', layer: 'floor', pattern: `floor_${k}_p{phase}_c{corners:02}`, phases: 4, cornerVariants: 16,
        note: `1 x 1 m ${k === 'g' ? 'steel grating (open decks, catwalks, the lift)' : 'snow-crusted concrete slab (landing pad, stairs)'} cell, 2 cm bleed so neighbours overlap without seams. Anchor = cell centre on the deck. phase = (i & 1) + 2 * (j & 1) with i = floor(x), j = floor(z) (keeps the 2 m texture continuous). corners = snow at the 4 cell corners (${CORNER_BITS}): sample a snow mask at the grid VERTICES (the web buildSnowMask: value noise + more snow within ~3 m of railings / props + slab bonus) and threshold at 0.5 — neighbouring tiles then always agree along their shared edge.` }) }, 16, { dark: true });
  }
  // ---------------------------------------------------------------- ramps + stairs
  {
    const frames = [];
    for (const asc of ASCS) for (const g of RAMP_G) for (let p = 0; p < 4; p++) frames.push(piece(`ramp_${asc}_${code(g)}_p${p}`, 'ramp', { k: 'g', p, asc, g, snow: 0.45 }));
    await set({ id: 'ramp_grating', atlas: 'Level', ...cvBox([-0.55, -0.16, -0.55], [0.55, 0.16, 0.55]), frames,
      meta: L({ kind: 'floor', layer: 'floor', pattern: 'ramp_{asc}_{slope}_p{phase}', ascents: ASCS, slopes: RAMP_G.map(code),
        note: 'sloped grating catwalk cell (the web west / east loop catwalks: slope 0.1875 and 0.15 m/m). asc = uphill direction: n = -z, s = +z, e = +x, w = -x. Anchor = cell centre on the ramp surface (deck height at the cell centre). Pair with side_e_g_{±slope} / side_s_g_{±slope} skirts and rail_{x|z}_{±slope} railings.' }) }, 12, { dark: true });
  }
  {
    const frames = [];
    for (const asc of ASCS) for (const g of STAIR_G) for (const edge of ['', 'first', 'last']) frames.push(piece(`stair_${asc}_${code(g)}${edge ? '_' + edge : ''}`, 'stair', { asc, g, edge, snow: 0.55 }));
    await set({ id: 'stairs', atlas: 'Level', ...cvBox([-0.55, -0.3, -0.55], [0.55, 0.12, 0.55]), frames,
      meta: L({ kind: 'floor', layer: 'floor', pattern: 'stair_{asc}_{slope}[_first|_last]', ascents: ASCS, slopes: STAIR_G.map(code),
        note: 'stair cell (slab): two 0.5 m treads whose tops sit at the ramp height of their centres (web: hub→plaza 0.3 m/m, plaza→lift 0.2143 m/m). Anchor = cell centre at the ramp height. _first = amber nosing on the bottom step of the flight (first cell), _last = amber nosing on the top step (last cell). Side walls: wall_{e|s}_{asc}_{slope}_{k}.' }) }, 12, { dark: true });
  }
  // ---------------------------------------------------------------- hazard strips
  await set({ id: 'hazard_strip', atlas: 'Level', ...cvBox([-0.55, 0, -0.55], [0.55, 0.02, 0.55]), frames: [piece('haz_x', 'haz', { axis: 'x' }), piece('haz_z', 'haz', { axis: 'z' })],
    meta: L({ kind: 'floorDecal', layer: 'floorDecal', pattern: 'haz_{x|z}', note: 'amber/black stripe 1 m x 0.42 m lying on the deck (above floors and stains). The web hazard platforms (beacons, landing pad) run one along every railing edge, centred 0.54 m inside the cell edge: haz_x for N / S edges, haz_z for W / E edges. Stripes repeat every 0.5 m, so cells tile seamlessly.' }) }, 2, { dark: true });

  // ---------------------------------------------------------------- skirts, walls (layer: under)
  {
    const frames = [];
    for (const face of ['s', 'e']) {
      for (const g of [0, ...RAMP_G.flatMap(v => [v, -v])]) frames.push(piece(`side_${face}_g_${code(g)}`, 'side', { k: 'g', face, g }));
      frames.push(piece(`side_${face}_s_000`, 'side', { k: 's', face, g: 0 }));
    }
    await set({ id: 'sides', atlas: 'Level', ...cvBox([-0.6, -1.35, -0.6], [0.6, 0.2, 0.6]), frames,
      meta: L({ kind: 'edge', layer: 'under', pattern: 'side_{s|e}_{g|s}_{slope}',
        note: 'visible platform edge: the 0.5 m deck skirt + the girder under the railing (only edges facing +z (s) or +x (e) can be seen; n / w edges need no skirt). Anchor = midpoint of the cell edge on the deck surface. slope = height change per metre along the edge (+ = rising toward +x for side_s, toward +z for side_e): ramps ascending e / w need side_s_g_{±slope}, ramps ascending n / s need side_e_g_{±slope}. g = grating, s = slab (flat only).' }) }, 8, { dark: true });
  }
  for (const face of ['e', 's']) {
    for (const asc of face === 'e' ? ['n', 's'] : ['e', 'w']) {
      for (const g of STAIR_G) {
        const n = Math.round(3 / g), frames = [];
        for (let k = 0; k < n; k++) frames.push(piece(`wall_${face}_${asc}_${code(g)}_${String(k).padStart(2, '0')}`, 'wall', { face, asc, g, kIdx: k }));
        await set({ id: `wall_${face}_${asc}_${code(g)}`, atlas: 'Level', preview: false, ...cvBox([-0.6, -(n * g + 0.7), -0.6], [0.6, 0.2, 0.6]), frames,
          meta: L({ kind: 'edge', layer: 'under', pattern: `wall_${face}_${asc}_${code(g)}_{k:02}`, frames: n,
            note: `side wall of a 3 m stair flight (${n} cells at ${g} m/m) on its ${face === 'e' ? 'E (+x)' : 'S (+z)'} edge; k = cell index counted from the LOW end of the flight. Anchor = edge midpoint at the cell centre's ramp height; the wall reaches 0.5 m below the low landing.` }) }, 7, { dark: true });
      }
    }
  }
  // ---------------------------------------------------------------- railings
  {
    const frames = [];
    for (const axis of ['x', 'z']) for (const g of RAIL_G.flatMap(v => v ? [v, -v] : [0])) frames.push(piece(`rail_${axis}_${code(g)}`, 'rail', { axis, g }));
    await set({ id: 'rails', atlas: 'Level', ...cvBox([-0.6, -0.25, -0.6], [0.6, 1.5, 0.6]), frames,
      meta: L({ kind: 'object', layer: 'object', pattern: 'rail_{x|z}_{slope}',
        note: 'two rails (0.55 / 1.05 m) along one 1 m cell edge; rail_x for N / S edges, rail_z for W / E edges; slope = rise per metre toward +x (rail_x) or +z (rail_z), following the deck. Anchor = midpoint of the rail line on the deck, 0.12 m inside the cell edge (web buildRailings). Depth-sort with the characters by that anchor. Posts (rail_post) every ~2 m and at run ends; the lift has its own ring.' }) }, 11, { dark: true });
  }
  await set({ id: 'rail_post', atlas: 'Level', ...cvBox([-0.2, 0, -0.2], [0.2, 1.2, 0.2]), frames: [piece('rail_post', 'post', {})],
    meta: L({ kind: 'object', layer: 'object', pattern: 'rail_post', note: 'railing post (0.1 x 1.1 m), anchor = foot on the deck at the rail line' }) }, 1, { dark: true });
  await set({ id: 'rail_corner', atlas: 'Level', ...cvBox([-1, -0.1, -1], [1, 1.3, 1]), frames: ['nw', 'ne', 'sw', 'se'].map(c => piece(`rail_corner_${c}`, 'corner', { corner: c })),
    meta: L({ kind: 'object', layer: 'object', pattern: 'rail_corner_{nw|ne|sw|se}', note: 'outer corner of a flat platform (cell with abyss on two adjacent sides): replaces that cell\'s two rail pieces. Anchor = the corner post, 0.38 m from the cell centre toward the named corner (nw = -x, -z).' }) }, 4, { dark: true });
  await set({ id: 'lamps', atlas: 'Level', glowAtlas: 'LevelGlow', ...cvBox([-1.1, -0.1, -1.1], [1.1, 3.4, 1.1]), frames: ['n', 's', 'e', 'w'].flatMap(i => ['teal', 'green'].map(c => piece(`lamp_${i}_${c}`, 'lamp', { inward: i, color: c }))),
    meta: L({ kind: 'object', layer: 'object', pattern: 'lamp_{inward}_{teal|green}', note: 'lamp post standing on a railing line, the arm reaching 0.8 m toward `inward` (n = -z …): a lamp on a S edge points n. Web: every 12 m along runs ≥ 6 m, every third one green. Add a ground glow pool (Ground/glow, 3 m, lamp colour x0.3, additive) 1.5 m inward.' }) }, 8, { dark: true });

  // ---------------------------------------------------------------- props
  await set({ id: 'pillar', atlas: 'Level', glowAtlas: 'LevelGlow', ...cvBox([-0.6, -0.1, -0.6], [0.6, 3.8, 0.6]), frames: [piece('pillar', 'pillar', {})],
    meta: L({ kind: 'object', layer: 'object', pattern: 'pillar', blocks: '1 cell', note: 'light pillar with teal strips (blocks its cell). Ground glow pool 3.2 m teal x0.3.' }) }, 1, { dark: true });
  for (const [w, d, hs] of CRATES) {
    const frames = [];
    for (const h of hs) for (let col = 0; col < 3; col++) frames.push(piece(`crate_${w}x${d}_${Math.round(h * 10)}_${'abc'[col]}`, 'crate', { w, d, h, col }));
    await set({ id: `crate_${w}x${d}`, atlas: 'Level', glowAtlas: 'LevelGlow', ...cvBox([-w / 2 - 0.1, -0.05, -d / 2 - 0.1], [w / 2 + 0.1, Math.max(...hs) + 0.1, d / 2 + 0.1]), frames,
      meta: L({ kind: 'object', layer: 'object', pattern: `crate_${w}x${d}_{height*10}_{a|b|c}`, footprint: [w, d], note: 'cargo crate (a olive, b blue-grey, c rust) with the amber label on its +z face; anchor = footprint centre on the deck; blocks the cells it covers. The web game adds a snow mound (mound_*) at the +z side of 60 % of them.' }) }, 6, { dark: true });
  }
  await set({ id: 'beacon_base', atlas: 'Level', glowAtlas: 'LevelGlow', ...cvBox([-1.6, -0.1, -1.6], [1.6, 2.3, 1.6]), frames: [piece('beacon_base', 'beacon', {})],
    meta: L({ kind: 'object', layer: 'object', pattern: 'beacon_base', note: 'beacon («маяк») pedestal, blocks the 2 x 2 cells around its centre; Props/beacon_top_* hovers 2.9 m above, Particles/beacon_beam stands on it while charging / done' }) }, 1, { dark: true });
  await set({ id: 'vent', atlas: 'Level', glowAtlas: 'LevelGlow', ...cvBox([-0.85, -0.05, -0.85], [0.85, 0.2, 0.85]), frames: [piece('vent', 'vent', {})],
    meta: L({ kind: 'floorDecal', layer: 'floorDecal', pattern: 'vent', note: 'steam / burrow vent plate (1.5 m) with glowing orange slats; ground glow 2.6 m orange (0xff5a1a) x0.3; steam puffs every 0.12 s (60 %)' }) }, 1, { dark: true });
  await set({ id: 'studs', atlas: 'Level', glowAtlas: 'LevelGlow', ...cvBox([-0.2, 0, -0.2], [0.2, 0.15, 0.2]), frames: ['amber', 'teal', 'green'].map(c => piece(`stud_${c}`, 'stud', { color: c })),
    meta: L({ kind: 'floorDecal', layer: 'floorDecal', pattern: 'stud_{amber|teal|green}', note: 'small glowing deck light (landing pad edge: 8 per side every 2 m, 0.4 m inside the edge)' }) }, 3, { dark: true });
  {
    const frames = [];
    [[0.7, 11], [0.85, 24], [1.0, 37], [1.2, 50]].forEach(([r, seed], i) => frames.push(piece(`drift_${i}`, 'drift', { r, sy: 0.16, color: 0xb4c1cf, seed })));
    [[0.45, 63], [0.45, 76]].forEach(([r, seed], i) => frames.push(piece(`mound_${i}`, 'drift', { r, sy: 0.35, color: 0xd2dbe6, seed })));
    await set({ id: 'snow', atlas: 'Level', ...cvBox([-1.4, -0.1, -1.4], [1.4, 0.3, 1.4]), frames,
      meta: L({ kind: 'floorDecal', layer: 'floorDecal', pattern: 'drift_{0..3} · mound_{0|1}', note: 'snow drifts (web: 90 random spots just inside the railings) and the small mounds beside crates; anchor = centre on the deck' }) }, 6, { dark: true });
  }
  await set({ id: 'pipes', atlas: 'Level', ...cvBox([-0.6, -0.9, -0.6], [0.6, 0.1, 0.6]), frames: ['n', 's', 'e', 'w'].map(s => piece(`pipes_${s}`, 'pipes', { side: s })),
    meta: L({ kind: 'edge', layer: 'under', pattern: 'pipes_{n|s|e|w}', note: '1 m segment of the pipe bundle hanging 0.3 m outside the named platform edge (0.25 / 0.62 m below the deck); anchor = cell edge midpoint on the deck' }) }, 4, { dark: true });
  // support columns fading into the abyss (alpha + fog tint grow with depth)
  const fade = (img, { AY }) => {
    for (let y = 0; y < img.h; y++) {
      const depth = Math.max(0, (y - AY) / (MPPM * COS_P)), f = Math.exp(-((depth / 24) ** 2)), mix = (1 - f) * 0.6;
      for (let x = 0; x < img.w; x++) {
        const o = (y * img.w + x) * 4;
        if (!img.data[o + 3]) continue;
        for (let c = 0; c < 3; c++) img.data[o + c] = img.data[o + c] * (1 - mix) + FOG[c] * mix;
        img.data[o + 3] *= f;
      }
    }
    return img;
  };
  await set({ id: 'support', preview: false, atlas: 'Level', glowAtlas: 'LevelGlow', post: fade, ...cvBox([-0.6, -40, -0.6], [0.6, 0.1, 0.6]), frames: [piece('support_0', 'support', { light: false, depth: 40 }), piece('support_1', 'support', { light: true, depth: 40 })],
    meta: L({ kind: 'under', layer: 'under', pattern: 'support_{0|1}', note: 'support column (0.7 m) dropping ~40 m into the abyss and fading out; support_1 carries a red marker light 6 m down. Anchor = column top, 0.5 m below the deck. Web buildSupports: on the rim of every platform rectangle every ~9 m (1 m inside the corners); the lift has 8 of them on a 10.9 m circle.' }) }, 2, { dark: true });
  await set({ id: 'girder', atlas: 'Level', ...cvBox([-0.6, -0.3, -0.6], [0.6, 0.3, 0.6]), frames: [piece('girder_x', 'girder', { axis: 'x' }), piece('girder_z', 'girder', { axis: 'z' })],
    meta: L({ kind: 'under', layer: 'under', pattern: 'girder_{x|z}', note: '1 m segment of the 0.4 m cross bracing hung 6 m under big platforms (web: platforms wider and deeper than 10 m get two braces along x, 1 m inside the N / S rims); anchor = segment centre' }) }, 2, { dark: true });

  // ---------------------------------------------------------------- the cargo lift
  await set({ id: 'lift_deck', preview: false, atlas: 'Level', glowAtlas: 'LevelGlow', ...cvBox([-10.2, -0.7, -10.2], [10.2, 0.25, 10.2]), frames: [piece('lift_deck', 'liftDeck', {})],
    meta: L({ kind: 'floor', layer: 'floor', pattern: 'lift_deck', note: 'cargo lift disc (radius 10 m, web LIFT_Y = -6) with its 4 teal pads and rim lights; anchor = disc centre on the deck. The whole lift (deck, centre, rail ring, shaft) rises during the extraction: move all lift pieces + everything standing on it by the rise.' }) }, 1, { dark: true });
  await set({ id: 'lift_center', atlas: 'Level', glowAtlas: 'LevelGlow', ...cvBox([-1.2, -0.05, -1.2], [1.2, 0.6, 1.2]), frames: [piece('lift_center', 'liftCenter', {})],
    meta: L({ kind: 'object', layer: 'object', pattern: 'lift_center', note: 'central hub on the lift (r 1.1 m, blocks the centre cells); anchor = lift centre' }) }, 1, { dark: true });
  {
    const frames = [], anchors = {};
    for (let s = 0; s < 12; s++) {
      const a = (s * 3 + 1.5) / 36 * Math.PI * 2, r = 9.85;
      anchors[`lift_rail_${String(s).padStart(2, '0')}`] = [+(Math.cos(a) * r).toFixed(4), 0, +(Math.sin(a) * r).toFixed(4)];
      frames.push(piece(`lift_rail_${String(s).padStart(2, '0')}`, 'liftRail', { s }));
    }
    await set({ id: 'lift_rail', preview: false, atlas: 'Level', ...cvBox([-1.8, -0.1, -1.8], [1.8, 1.3, 1.8]), frames,
      meta: L({ kind: 'object', layer: 'object', pattern: 'lift_rail_{00..11}', anchorsFromLiftCentre: anchors, note: 'lift ring railing in 12 arcs of 30° (the opening toward +z, where the stairs arrive, is left out of segments 02 / 03); place each at lift centre + anchorsFromLiftCentre (metres, x / z) and depth-sort it like any object' }) }, 6, { dark: true });
  }
  await set({ id: 'lift_shaft', preview: false, atlas: 'Level', glowAtlas: 'LevelGlow', ...cvBox([-11.4, -3.8, -11.4], [11.4, -0.4, 11.4]), frames: [piece('lift_shaft', 'liftShaft', {})],
    meta: L({ kind: 'under', layer: 'under', pattern: 'lift_shaft', note: 'shaft collar under the lift rim (3 m band, r 10.6) with 16 teal lights; anchor = lift centre on the deck. Add support_0 columns at 8 points on a 10.9 m circle (deck - 0.5 m).' }) }, 1, { dark: true });
  previewEnd(3);

  manifest.level = levelDoc();
  assembly(images, SHEETS, PREVIEWS);
  console.log(`  level kit: ${((Date.now() - t0) / 1000).toFixed(1)} s`);
}

function levelDoc() {
  return {
    cell: '1 m grid cell (web walk grid G = 128, world x / z in [-64, 64)); every floor / edge piece covers one cell or one cell edge',
    layers: [
      'background (Background atlas: haze, towers, motes) — fixed behind everything',
      'under: support columns, girders, lift shaft, pipes, side skirts and stair walls — sort by nearness of the anchor',
      'floor: floor / ramp / stair tiles and the lift deck — LOWER height tiers first, then nearness (tiles of one tier never overlap except by the 2 cm bleed)',
      'floorDecal: stains (Ground decals, .multiply), hazard strips, vents, studs, snow drifts, glow pools (.add), telegraph rings',
      'object: railings, posts, lamps, pillars, crates, beacon bases, lift rail / centre, corpses, bugs, marines, props — ONE layer sorted by nearness of the anchor (zPosition = nearness)',
      'fx: particles, lasers, beams, glow layers (*Glow atlases, .add) above the darkness overlay',
    ],
    nearness: 'nearness = (x + z) * 0.385118 + y * 0.838671 (manifest.projection.depth)',
    assembly: [
      'for every walkable cell (walk != 0): floor_{g|s}_p{phase}_c{corners} (or ramp_* / stair_* where the height field slopes; the lift disc is one lift_deck)',
      'for every cell side that borders the abyss (walk == 0): a rail piece (+ rail_post every 2 m and at run ends, rail_corner_* at outer corners), and for s (+z) / e (+x) sides a side_* skirt (stair cells: wall_*) ',
      'hazard platforms: haz_x / haz_z along the railing edges; landing pad: Ground/pad_mark + stud_amber',
      'supports under every platform rectangle; girders under platforms > 10 x 10 m; pipes on a few long sides',
      'props from the level data (crates, pillars, vents, beacon bases, lamps every 12 m on runs ≥ 6 m)',
    ],
    testRender: 'tools/out/sheets/level_assembly.png (+ tools/previews/level_assembly.png) is assembled from these sprites by tools/lib/level.mjs (assembly()) with exactly the rules above — a reference implementation for the native builder',
  };
}

// ---------------------------------------------------------------- assembly test: a small station built from the kit
function assembly(images, SHEETS, PREVIEWS) {
  const P = 72;   // @3x px per metre
  const W = 1700, H = 1800, OX = 1150, OY = 330;
  const out = make(W, H, [...FOG, 255]);
  const glow = make(W, H);
  const scr = (x, y, z) => [OX + (x - z) * S2 * P, OY - (y * COS_P - (x + z) * S2 * SIN_P) * P];
  const items = [];
  const add = (name, x, y, z, layer, tier = 0) => { if (images[name]) items.push({ name, x, y, z, layer, tier, near: (x + z) * 0.385118 + y * 0.838671 }); else console.log('  ! assembly: missing ' + name); };
  // layout: upper deck (grating 8 x 6 at y 0), a ramp catwalk down to a lower slab deck at y -3 (8 x 5) via stairs
  const walk = new Map(), H0 = new Map();
  const cellKey = (i, j) => i + ',' + j;
  const deck = (i0, j0, i1, j1, k, h) => { for (let j = j0; j < j1; j++) for (let i = i0; i < i1; i++) { walk.set(cellKey(i, j), k); H0.set(cellKey(i, j), h); } };
  deck(0, 0, 8, 6, 'g', 0);
  deck(2, 6, 5, 16, 'stair', null);   // stairs descending toward +z (asc n), 10 cells at 0.3
  deck(0, 16, 9, 21, 's', -3);
  const snowAt = (vi, vj) => ((vi * 7 + vj * 13) % 5 < 2 || vi === 0 || vj === 0 || vi === 8 || vj === 21) ? 1 : 0;
  for (const [key, k] of walk) {
    const [i, j] = key.split(',').map(Number), x = i + 0.5, z = j + 0.5;
    if (k === 'stair') {
      const kIdx = 15 - j, g = 0.3, h = -3 + (kIdx + 0.5) * g;   // low end at j = 15 (+z)
      add(`stair_n_300${kIdx === 0 ? '_first' : kIdx === 9 ? '_last' : ''}`, x, h, z, 'floor', h);
      if (!walk.has(cellKey(i + 1, j))) add(`wall_e_n_300_${String(kIdx).padStart(2, '0')}`, i + 1, h, z, 'under');
      if (!walk.has(cellKey(i - 1, j))) add('rail_z_m300', i + 0.12, h, z, 'object');
      if (!walk.has(cellKey(i + 1, j))) add('rail_z_m300', i + 1 - 0.12, h, z, 'object');
      continue;
    }
    const h = H0.get(key), p = (i & 1) + 2 * (j & 1);
    const c = snowAt(i, j) | snowAt(i + 1, j) << 1 | snowAt(i, j + 1) << 2 | snowAt(i + 1, j + 1) << 3;
    add(`floor_${k}_p${p}_c${String(c).padStart(2, '0')}`, x, h, z, 'floor', h);
    const open = (di, dj) => !walk.has(cellKey(i + di, j + dj));
    const N = open(0, -1), S = open(0, 1), Wd = open(-1, 0), E = open(1, 0);
    if (S) add(`side_s_${k}_000`, x, h, j + 1, 'under');
    if (E) add(`side_e_${k}_000`, i + 1, h, z, 'under');
    const corner = N && Wd ? 'nw' : N && E ? 'ne' : S && Wd ? 'sw' : S && E ? 'se' : null;
    if (corner) {
      add(`rail_corner_${corner}`, x + (corner[1] === 'w' ? -0.38 : 0.38), h, z + (corner[0] === 'n' ? -0.38 : 0.38), 'object');
      if (N && S) add('rail_x_000', x, h, j + 1 - 0.12, 'object');
      if (Wd && E) add('rail_z_000', i + 1 - 0.12, h, z, 'object');
    } else {
      if (N) add('rail_x_000', x, h, j + 0.12, 'object');
      if (S) add('rail_x_000', x, h, j + 1 - 0.12, 'object');
      if (Wd) add('rail_z_000', i + 0.12, h, z, 'object');
      if (E) add('rail_z_000', i + 1 - 0.12, h, z, 'object');
    }
    if ((N || S) && !corner && (i % 2 === 0)) add('rail_post', i, h, N ? j + 0.12 : j + 1 - 0.12, 'object');
  }
  for (const [x, z] of [[1, 1], [7, 1], [1, 17], [8, 20]]) add('support_1', x, (z > 10 ? -3 : 0) - 0.5, z, 'under');
  add('crate_1x1_12_a', 1.5, 0, 4.5, 'object'); add('crate_2x1_10_c', 6, 0, 1.5, 'object'); add('pillar', 6.5, -3, 18.5, 'object');
  add('vent', 4.5, 0, 2.5, 'floorDecal'); add('drift_2', 7.4, 0, 3.0, 'floorDecal'); add('lamp_s_teal', 3, 0, 0.12, 'object');
  add('beacon_base', 2.5, -3, 18.5, 'object');
  const ORDER = { under: 0, floor: 1, floorDecal: 2, object: 3 };
  items.sort((a, b) => ORDER[a.layer] - ORDER[b.layer] || (a.layer === 'floor' ? a.tier - b.tier : 0) || a.near - b.near);
  for (const it of items) {
    const im = images[it.name], [sx, sy] = scr(it.x, it.y, it.z);
    draw(out, im.lit3, Math.round(sx - im.ax), Math.round(sy - im.ay));
    if (im.glow2) {
      const g3 = make(Math.round(im.glow2.w * 1.5), Math.round(im.glow2.h * 1.5));
      for (let y = 0; y < g3.h; y++) for (let x = 0; x < g3.w; x++) {
        const so = (Math.min(im.glow2.h - 1, Math.floor(y / 1.5)) * im.glow2.w + Math.min(im.glow2.w - 1, Math.floor(x / 1.5))) * 4, d = (y * g3.w + x) * 4;
        for (let c = 0; c < 4; c++) g3.data[d + c] = im.glow2.data[so + c];
      }
      draw(glow, g3, Math.round(sx - im.ax), Math.round(sy - im.ay), { mode: 'add' });
    }
  }
  addOnto(out, glow, 0, 0);
  savePNG(path.join(SHEETS, 'level_assembly.png'), out);
  savePNG(path.join(PREVIEWS, 'level_assembly.png'), downscale(out, 2));
}
