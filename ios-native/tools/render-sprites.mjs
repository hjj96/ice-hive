#!/usr/bin/env node
// «Ледяной Улей» v2.0 — pre-renders the web game's art into SpriteKit texture atlases.
//
//   node ios-native/tools/render-sprites.mjs [--only bugs,marines,corpses,props,fx,level,bg] [--sheets-only]
//
// Loads the web game's own source parts (game/js/01…09) into headless Chromium (Playwright + SwiftShader WebGL)
// and renders the game's real meshes / materials / canvas textures with an orthographic camera at the web
// camera's yaw (45°) and pitch (57°). Output:
//   ios-native/art/Sprites/<Atlas>.spriteatlas/<frame>.imageset/{<frame>@2x.png,<frame>@3x.png}  (source frames, not bundled)
//   ios-native/App/Resources/Sheets/sheet_*.png + sheets.json      (pack-sheets.mjs, run at the end: what the app loads)
//   ios-native/App/Resources/sprites-manifest.json  (merged per section, so --only re-renders just that part)
//   ios-native/tools/out/sheets/*.png               (contact sheets: full light | in-game darkness + glow)
// Needs the repo's npm devDependencies (three, playwright): run `npm ci` in the repo root first.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { openGamePage, TOOLS, RES, OUT, NATIVE } from './lib/gamepage.mjs';
import { Catalog, runSet, contactSheet, savePNG, json, MPPM, SIN_P, COS_P, PT_PER_M, AMBIENT, previewRows, composePreview } from './lib/pipeline.mjs';
import { renderFx } from './lib/fx.mjs';
import { renderLevel } from './lib/level.mjs';
import { renderBackground } from './lib/background.mjs';

const argv = process.argv.slice(2);
const onlyArg = argv.includes('--only') ? argv[argv.indexOf('--only') + 1].split(',') : null;
const want = (s) => !onlyArg || onlyArg.includes(s);
// source frames live outside the app bundle; tools/pack-sheets.mjs packs them into App/Resources/Sheets
const XC = path.join(NATIVE, 'art', 'Sprites');
const MANIFEST = path.join(RES, 'sprites-manifest.json');
const SHEETS = path.join(OUT, 'sheets');
const PREVIEWS = path.join(TOOLS, 'previews');   // committed: one small PNG per group
fs.mkdirSync(SHEETS, { recursive: true });
fs.mkdirSync(PREVIEWS, { recursive: true });
const preview = { group: null, rows: [] };
function previewBegin(group) { preview.group = group; preview.rows = []; }
function previewEnd(k = 2) { if (preview.rows.length) savePNG(path.join(PREVIEWS, preview.group + '.png'), composePreview(preview.rows, k)); preview.group = null; preview.rows = []; }
fs.mkdirSync(XC, { recursive: true });

const TAU = Math.PI * 2, DIRS = 16;
const BUGS = [
  { t: 0, id: 'runner', scale: 0.8, speed: 4.5, R: 1.0, Hm: 0.9 },
  { t: 1, id: 'spitter', scale: 1.02, speed: 3.0, R: 1.15, Hm: 1.3 },
  { t: 2, id: 'brute', scale: 2.0, speed: 2.6, R: 2.0, Hm: 2.4 },
  { t: 3, id: 'boomer', scale: 1.15, speed: 3.6, R: 1.4, Hm: 1.9 },
];
const CLASSES = ['assault', 'pyro', 'cryo', 'gunner'];
const BUG_V = 1.15;   // instance brightness the bug frames are rendered at (the game spreads 0.55…1.3)

const s6 = (v) => Math.ceil(v / 6) * 6;
// canvas for an object with footprint radius R (m) and height Hm (m) standing on the anchor
function cv(R, Hm, below = 0) {
  const up = Hm * COS_P + R * SIN_P, down = R * SIN_P + below * COS_P;
  return { canvas: [s6(2 * R * MPPM), s6((up + down) * MPPM)], anchor: [s6(R * MPPM), s6(up * MPPM)] };
}
const dd = (d) => String(d).padStart(2, '0');
const hdOf = (d) => d * TAU / DIRS;

const cat = new Catalog(XC);
const manifest = fs.existsSync(MANIFEST) ? JSON.parse(fs.readFileSync(MANIFEST, 'utf8')) : {};
manifest.sets = manifest.sets || {};
const t0 = Date.now();
const { browser, page } = await openGamePage(['inpage-sprites.js', 'inpage-fx.js', 'inpage-level.js'].map(f => path.join(TOOLS, 'lib', f)));
console.log(`game modules loaded (${Date.now() - t0} ms)`);

const images = {};   // frame name -> { lit3, glow2, ax, ay } (@3x pixels; used by the level assembly test)
async function set(def, cols, sheetOpts = {}) {
  const { entry, sheet } = await runSet(page, cat, def);
  manifest.sets[def.id] = entry;
  for (const s of sheet) images[s.name] = { lit3: s.lit3, glow2: s.glow2, ax: entry.anchorPixel3x[0], ay: entry.anchorPixel3x[1] };
  savePNG(path.join(SHEETS, def.id + '.png'), contactSheet(sheet, cols, sheetOpts));
  if (preview.group && def.preview !== false) preview.rows.push(previewRows(sheet, def.previewOpts));
  return entry;
}
function dirFrames(prefix, frames, poseFn, fn, extraArgs) {
  const out = [];
  for (let d = 0; d < DIRS; d++) for (let f = 0; f < frames; f++) {
    out.push({ name: frames > 1 ? `${prefix}_${dd(d)}_${f}` : `${prefix}_${dd(d)}`, fn, args: extraArgs(poseFn(hdOf(d), f)), dir: d, frame: f });
  }
  return out;
}
function dropSets(prefixes) { for (const k of Object.keys(manifest.sets)) if (prefixes.some(p => k.startsWith(p))) delete manifest.sets[k]; }

// ------------------------------------------------------------------ bugs
if (want('bugs')) {
  previewBegin('bugs');
  dropSets(BUGS.map(b => b.id + '_').filter(p => !p.endsWith('corpse_')));
  for (const b of BUGS) {
    const fpm = +(64 / (TAU * b.scale)).toFixed(3);   // gait: phase += speed * dt * 8 / scale, 8 frames per 2π
    const walkC = cv(b.R, b.Hm);
    const body = (pose) => [b.t, 'body', pose];
    await set({
      id: `${b.id}_walk`, atlas: 'Bugs', glowAtlas: 'BugsGlow', ...walkC,
      frames: dirFrames(`${b.id}_walk`, 8, (hd, f) => ({ hd, ph: f * TAU / 8, s: b.scale, v: BUG_V }), 'bug', body),
      meta: { kind: 'bug', pattern: `${b.id}_walk_{dir:02}_{frame}`, directions: DIRS, frames: 8, loop: true, framesPerMetre: fpm, fpsAtBaseSpeed: +(fpm * b.speed).toFixed(1), worldScale: b.scale },
    }, 8);
    // climbing the platform side (nose up 1.4 rad) and cresting the railing (0.7 rad); phase += dt * 14
    const climbC = cv(b.R, b.Hm * 1.5, b.Hm * 0.6);
    await set({
      id: `${b.id}_climb`, preview: false, atlas: 'Bugs', glowAtlas: 'BugsGlow', ...climbC,
      frames: dirFrames(`${b.id}_climb`, 4, (hd, f) => ({ hd, ph: f * TAU / 4, s: b.scale, v: BUG_V, pitch: 1.4 }), 'bug', body),
      meta: { kind: 'bug', pattern: `${b.id}_climb_{dir:02}_{frame}`, directions: DIRS, frames: 4, loop: true, fps: +(14 / TAU * 4).toFixed(1), worldScale: b.scale, note: 'S_CLIMB below the deck edge (y < -0.85): body pitched 1.4 rad nose-up against the platform wall' },
    }, 4);
    await set({
      id: `${b.id}_crest`, preview: false, atlas: 'Bugs', glowAtlas: 'BugsGlow', ...climbC,
      frames: dirFrames(`${b.id}_crest`, 2, (hd, f) => ({ hd, ph: f * Math.PI, s: b.scale, v: BUG_V, pitch: 0.7 }), 'bug', body),
      meta: { kind: 'bug', pattern: `${b.id}_crest_{dir:02}_{frame}`, directions: DIRS, frames: 2, loop: true, fps: +(14 / TAU * 2).toFixed(1), worldScale: b.scale, note: 'S_CLIMB while cresting the railing (-0.85 < y < 0): pitch 0.7 rad; switch to walk at y >= -0.1' },
    }, 2);
    if (b.id === 'brute') {
      await set({
        id: 'brute_charge', atlas: 'Bugs', glowAtlas: 'BugsGlow', ...walkC,
        frames: dirFrames('brute_charge', 4, (hd, f) => ({ hd, ph: f * TAU / 4 + 0.4, s: b.scale, sy: b.scale * 0.93, v: BUG_V, pitch: -0.14 }), 'bug', body),
        meta: { kind: 'bug', pattern: 'brute_charge_{dir:02}_{frame}', directions: DIRS, frames: 4, loop: true, fps: 16, worldScale: b.scale, note: 'S_CHARGE (12.5 m/s along the lane): head lowered, body flattened 7 %. Wind-up (S_WIND, 0.8 s): walk frame 0 with yScale *= 1 + sin(t*30)*0.05' },
      }, 4);
    }
    if (b.id === 'boomer') {
      await set({
        id: 'boomer_swell', atlas: 'Bugs', glowAtlas: 'BugsGlow', ...cv(b.R * 1.45, b.Hm * 1.45),
        frames: dirFrames('boomer_swell', 3, (hd, f) => ({ hd, ph: 0, s: b.scale * (1 + (f + 1) / 3 * 0.45), v: BUG_V }), 'bug', body),
        meta: { kind: 'bug', pattern: 'boomer_swell_{dir:02}_{frame}', directions: DIRS, frames: 3, loop: false, durationSeconds: 0.8, worldScale: b.scale, note: 'S_SWELL 0.8 s: frames = 1/3, 2/3, 3/3 of the +45 % swell. Blink white faster and faster (colorBlendFactor, white): 0.9*(0.5+0.5*sin(t*(18+30*p)))' },
      }, 3);
    }
    await set({
      id: `${b.id}_shadow`, atlas: 'Bugs', ...walkC, post: 'shadow', margin: 12,
      frames: dirFrames(`${b.id}_shadow`, 1, (hd) => ({ hd, ph: 0, s: b.scale }), 'bug', (pose) => [b.t, 'smudge', pose]),
      meta: { kind: 'shadow', pattern: `${b.id}_shadow_{dir:02}`, directions: DIRS, frames: 1, worldScale: b.scale, note: 'dark contact smudge (opaque near-black in the game; crowds merge into a black flood). Draw under all bugs, alpha ~0.9; hide while climbing' },
    }, 8, { dark: false });
  }
  previewEnd(3);
}

// ------------------------------------------------------------------ corpses
if (want('corpses')) {
  previewBegin('corpses');
  dropSets(['corpse_']);
  for (const b of BUGS) {
    const v = 1.9, tint = b.t === 1 ? [v * 0.85, v * 0.95, v * 0.58] : [v, v * 0.72, v * 0.58];
    const frames = [];
    for (let k = 0; k < 6; k++) frames.push({ name: `${b.id}_corpse_${k}`, fn: 'corpse', args: [b.t, k * TAU / 6 + 0.35 + (k % 2) * 0.2, b.scale, tint] });
    await set({
      id: `corpse_${b.id}`, atlas: 'Corpses', ...cv(b.R, 0.6),
      frames,
      meta: { kind: 'corpse', pattern: `${b.id}_corpse_{variant}`, variants: 6, worldScale: b.scale, note: 'lies on the deck; the web game draws runner remains for runner/spitter and none for boomers (scorch decal instead)' },
    }, 6, { dark: true });
  }
  previewEnd(2);
}

// ------------------------------------------------------------------ marines
if (want('marines')) {
  previewBegin('marines');
  dropSets(CLASSES.map(c => c + '_'));
  for (const cls of CLASSES) {
    const C = cv(1.15, 2.25);
    const mk = (anim, frames, ph) => dirFrames(`${cls}_${anim}`, frames, (hd, f) => ({ hd, anim, ph: ph(f) }), 'marine', (pose) => [cls, pose]);
    const fpm = +(2.6 * 8 / TAU).toFixed(3);   // walkPh += speed * dt * 2.6
    await set({ id: `${cls}_run`, atlas: 'Marines', glowAtlas: 'MarinesGlow', ...C, frames: mk('run', 8, (f) => f * TAU / 8),
      meta: { kind: 'marine', pattern: `${cls}_run_{dir:02}_{frame}`, directions: DIRS, frames: 8, loop: true, framesPerMetre: fpm, fpsAtBaseSpeed: +(fpm * 5.3).toFixed(1), note: 'direction = AIM heading (the web marine always faces its aim); legs swing along it' } }, 8);
    await set({ id: `${cls}_strafe`, preview: false, atlas: 'Marines', glowAtlas: 'MarinesGlow', ...C, frames: dirFrames(`${cls}_strafe`, 4, (hd, f) => ({ hd, anim: 'strafe', rel: 0, ph: f * TAU / 4 }), 'marine', (pose) => [cls, pose]),
      meta: { kind: 'marine', pattern: `${cls}_strafe_{dir:02}_{frame}`, directions: DIRS, frames: 4, loop: true, framesPerMetre: +(fpm / 2).toFixed(3), note: 'moving sideways to the aim (|cos(move - aim)| < 0.5): legs swing sideways. Running backwards = run frames played in reverse' } }, 4);
    await set({ id: `${cls}_idle`, preview: false, atlas: 'Marines', glowAtlas: 'MarinesGlow', ...C, frames: mk('idle', 1, () => 0),
      meta: { kind: 'marine', pattern: `${cls}_idle_{dir:02}`, directions: DIRS, frames: 1 } }, 8);
    await set({ id: `${cls}_dash`, preview: false, atlas: 'Marines', glowAtlas: 'MarinesGlow', ...cv(1.6, 2.3), frames: mk('dash', 1, () => Math.PI / 2),
      meta: { kind: 'marine', pattern: `${cls}_dash_{dir:02}`, directions: DIRS, frames: 1, note: 'dash (0.22 s): body leans 0.35 rad forward; like the web game it keeps facing the AIM heading (dir = aim), legs half-swung' } }, 8);
    await set({ id: `${cls}_downed`, atlas: 'Marines', glowAtlas: 'MarinesGlow', ...cv(2.4, 1.0), frames: mk('downed', 1, () => 0),
      meta: { kind: 'marine', pattern: `${cls}_downed_{dir:02}`, directions: DIRS, frames: 1, note: 'lying on the back (rotation.x = -1.35, raised 0.28 m)' } }, 8);
  }
  previewEnd(2);
}

// ------------------------------------------------------------------ small props
if (want('props')) {
  previewBegin('props');
  dropSets(['turret_', 'medkit', 'glob', 'grenade', 'beacon_top']);
  const one = (id, name, rot, C, meta) => set({ id, atlas: 'Props', ...C, frames: [{ name, fn: 'prop', args: [name, rot] }], meta }, 1);
  await one('turret_base', 'turret_base', 0, cv(0.6, 1.0), { kind: 'prop', pattern: 'turret_base', note: 'auto-turret tripod; draw turret_head_{dir} on top at the same anchor' });
  await set({ id: 'turret_head', atlas: 'Props', ...cv(1.0, 1.4), frames: Array.from({ length: DIRS }, (_, d) => ({ name: `turret_head_${dd(d)}`, fn: 'prop', args: ['turret_head', hdOf(d)] })),
    meta: { kind: 'prop', pattern: 'turret_head_{dir:02}', directions: DIRS, note: 'anchor = turret base point (the head pivot sits 0.95 m up)' } }, 8);
  await one('medkit', 'medkit', 0.3, cv(0.6, 0.6), { kind: 'prop', pattern: 'medkit' });
  await one('glob', 'glob', 0, cv(0.4, 0.6, 0.3), { kind: 'prop', pattern: 'glob', note: 'acid glob (unlit, centre anchor): place at the arc height' });
  await one('grenade', 'grenade', 0, cv(0.3, 0.4, 0.2), { kind: 'prop', pattern: 'grenade', note: 'unlit, centre anchor' });
  await set({ id: 'beacon_top', atlas: 'Props', ...cv(0.6, 0.6, 0.6), frames: [0, 1, 2, 3].map(k => ({ name: `beacon_top_${k}`, fn: 'prop', args: ['beacon_top', k * Math.PI / 8] })),
    meta: { kind: 'prop', pattern: 'beacon_top_{frame}', frames: 4, loop: true, note: 'white octahedron spinning 1.2 rad/s (4 rad/s while charging); tint with the beacon state colour x1.6; centre anchor, hover 2.9 m above the beacon base' } }, 4);
  previewEnd(2);
}

const ctx = { page, cat, manifest, SHEETS, PREVIEWS, set, cv, dd, DIRS, previewBegin, previewEnd, images };
if (want('fx')) await renderFx(ctx);
if (want('level')) await renderLevel(ctx);
if (want('bg')) await renderBackground(ctx);

await browser.close();

// ------------------------------------------------------------------ manifest
manifest.version = 1;
manifest.generator = 'ios-native/tools/render-sprites.mjs (renders game/js/01…09 with three.js r170 in headless Chromium)';
manifest.projection = {
  type: 'orthographic 3/4 view, same yaw/pitch as the web camera (CAM_YAW 45°, CAM_PITCH 57°), no perspective',
  yawDegrees: 45, pitchDegrees: 57,
  pointsPerMetre: PT_PER_M, pixelsPerMetre3x: PT_PER_M * 3, pixelsPerMetre2x: PT_PER_M * 2,
  worldAxes: 'world x, z on the deck (sim coordinates of the web game), y up. The camera sits at +x,+z looking toward -x,-z.',
  screenFromWorld: 'u = (x - z) * 0.707107 * ppm ;  v = (y * 0.544639 - (x + z) * 0.707107 * 0.838671) * ppm   (u right, v up; ppm = 24 for SpriteKit points)',
  screenFromWorldConstants: { cosYaw: 0.707107, sinPitch: +SIN_P.toFixed(6), cosPitch: +COS_P.toFixed(6) },
  depth: 'nearness = (x + z) * 0.385118 + y * 0.838671  (larger = closer to the camera = draw later / higher zPosition)',
  cellDiamondPoints: [+(Math.SQRT2 * PT_PER_M).toFixed(4), +(Math.SQRT2 * PT_PER_M * SIN_P).toFixed(4)],
  heightStepPoints: +(COS_P * PT_PER_M).toFixed(4),
  directions: 'dir = Int((hd / (2π) * 16).rounded()) & 15 with hd = atan2(dx, dz) in WORLD space (the web game\'s heading / aim angle). dir 0 faces world +z (screen down-left), 4 faces +x (down-right), 8 faces -z (up-right), 12 faces -x (up-left); screen-up (the web FWD vector) is hd = 225° (dir 10)',
  groundPlaneTextures: 'flat textures (Ground atlas: decals, telegraph rings / fills / lanes, glow pools, floor indicators, pad mark, lasers, cryo beam, tracers; Background/bg_haze) are authored TOP-DOWN: image right = world +x, image up = world -z. Put the SKSpriteNode inside a container node with yScale = 0.838671 (= sin pitch, container zRotation 0) and give the sprite zRotation = r - π/4, where r is the web rotation about +y (three.js rotation.y; e.g. decals: the random rot, charge lanes: atan2(-dx, -dz), beams / lasers / tracers lying along the aim angle a = atan2(ax, az): r = a - π/2). Size in points = metres * 24 (before the squash). Position the container at screenFromWorld(x, y, z). Exact for the orthographic camera.',
  recommendedCameraScale: 'the web game shows ~23 m across a portrait iPhone (≈17–18 pt/m): SKCameraNode.setScale(1.35) (≈18 pt/m) matches it; 1.0 is a closer view at native sprite resolution',
};
manifest.lighting = {
  rig: 'sprites are pre-lit with a bright "full light" rig: the game\'s moon direction (-25, 60, 35), cool sky dome, warm fill from the viewer (flashlights). ACES filmic, sRGB.',
  inGameDarkness: `multiply by a light map: about [${AMBIENT.join(', ')}] in the dark (moon + sky only), 1.0 inside flashlight cones / lamp pools, >1 not possible with multiply — add light pools additively instead`,
  glowLayers: '*Glow atlases (BugsGlow, MarinesGlow, LevelGlow, BackgroundGlow) hold the emissive parts only (pink / acid / ember speckles, visors, chest lamps, lamp heads, light strips, rim studs) with a soft halo, premultiplied: draw ABOVE the darkness with blendMode .add at the same position, anchor and point size as the lit frame (frame name + "_g"; @2x-only images, so their pixel size is 2/3 of the lit @3x frame)',
  bugBrightness: `bug frames use instance brightness ${BUG_V}; the web game varies it per bug 0.55…1.3 → multiply color by 0.48…1.13 (colorBlendFactor 1, SKColor(white:))`,
};
manifest.atlasNotes = 'Shipped as five packed sheets (App/Resources/Sheets, tools/pack-sheets.mjs: @2x, trimmed, grouped by draw layer; sheets.json gives every frame\'s rect and its offset in the full frame). Source format: .spriteatlas folders in ios-native/art/Sprites (Xcode 7+ "Sprite Atlas"): each frame is an imageset with @2x + @3x PNGs, so App Store thinning ships only the device scale, actool packs every atlas into texture pages per scale at build time and trims transparent borders (SKTexture.size() keeps the untrimmed frame size, so the anchors stay valid). Loose .atlas folders would ship both scales to every device. Load with SKTextureAtlas(named: "Bugs").textureNamed("runner_walk_03_5") (preload the atlases at launch: SKTextureAtlas.preloadTextureAtlases). Frame names are unique across the whole catalog. Lit frames (Bugs, Corpses, Marines, Props, Level, Background towers) are @2x + @3x; glow layers and the flat textures (Ground, Particles, Background haze / motes) are single @2x images (point size = px / 2 — set their size explicitly from metres). Every set entry below gives the atlas, the frame naming pattern, directions / frames / fps, the anchor (feet / ground point, as SKSpriteNode.anchorPoint, y up) and the frame size.';
manifest.atlases = {
  Bugs: 'runner / spitter / brute / boomer: walk, climb, crest, brute charge, boomer swell, contact shadows',
  BugsGlow: 'additive emissive layer of every Bugs frame (+ "_g")',
  Corpses: 'bug remains lying on the deck (6 variants per type)',
  Marines: 'assault / pyro / cryo / gunner: run, strafe, idle, dash, downed (weapon included, class colour on pads / trim / visor)',
  MarinesGlow: 'additive emissive layer of every Marines frame',
  Props: 'turret base + 16 head directions, medkit, acid glob, grenade, beacon top',
  Level: 'the station tile kit (floors, ramps, stairs, skirts, walls, railings, lamps, crates, pillars, vents, supports, lift); see manifest.level',
  LevelGlow: 'additive emissive layer of the lit Level pieces (lamps, pillar strips, vents, studs, lift lights, crate labels, support marker lights)',
  Ground: 'top-down flat textures: decals (multiply), telegraphs / indicators / glow pools (add), pad mark, hazard stripe, lasers, cryo beam, tracers',
  Particles: 'screen-facing particle textures (soft / puff / spark / streak / flash / shards / chunks / snow / mist), baked fire ramps, beacon beam',
  Background: 'abyss haze, distant towers (1/4 scale), mote field',
  BackgroundGlow: 'tower beacon lights',
};
const sorted = {};
for (const k of Object.keys(manifest.sets).sort()) sorted[k] = manifest.sets[k];
manifest.sets = sorted;
const order = ['version', 'generator', 'projection', 'lighting', 'colour', 'atlasNotes', 'atlases', 'level', 'sets'];
const outObj = {};
for (const k of order) if (manifest[k] !== undefined) outObj[k] = manifest[k];
for (const k of Object.keys(manifest)) if (!(k in outObj)) outObj[k] = manifest[k];
fs.writeFileSync(MANIFEST, json(outObj));
console.log(`done: ${cat.files} PNGs, ${(cat.bytes / 1048576).toFixed(1)} MB written this run, ${((Date.now() - t0) / 1000).toFixed(0)} s`);
execFileSync(process.execPath, [path.join(TOOLS, 'pack-sheets.mjs')], { stdio: 'inherit' });
