#!/usr/bin/env node
// «Ледяной Улей» v2.0 — packs the rendered sprite frames into a few big texture sheets for SpriteKit.
//
//   node ios-native/tools/pack-sheets.mjs [--dry]
//
// Input:  ios-native/art/Sprites/<Atlas>.spriteatlas/<frame>.imageset/<frame>@2x.png  (render-sprites.mjs output)
// Output: ios-native/App/Resources/Sheets/sheet_<name>.png + sheets.json
//
// Why not Xcode sprite atlases: every frame lookup in a compiled .spriteatlas costs milliseconds on iOS 26
// (≈4 ms per SKTexture on the simulator: 4360 frames = 15–25 s of preloading), page grouping is out of our hands
// and every lit frame shipped at @3x (430 MB of decoded textures). Here every frame is @2x (48 px per metre — the
// game camera shows the world at 1/1.35, so @2x is still ≥ 0.9 device pixel per texel on 3x screens), trimmed to
// its visible pixels and packed into one sheet per draw layer, so sprites that are drawn together share a texture
// and SpriteKit batches them:
//   bugs   — swarm frames, contact shadows, corpses (depth-sorted objects + the corpse / shadow bands)
//   squad  — marines, props, and the level pieces that stand on the deck (crates, pillars, lamps, railings, lift rails)
//   glow   — every additive emissive layer (*Glow atlases): drawn above the darkness in one band
//   level  — floor / ramp / stair tiles, skirts, walls, supports, pipes, lift deck + the background towers / haze
//   fx     — flat ground textures (decals, telegraphs, lasers, beams) and particles (not trimmed: sized in metres)
// sheets.json: { scale: 2, sheets: [{ name, file, w, h, scale }], frames: { name: [sheet, x, y, w, h, ox, oy, fw, fh] } }
// (the glow sheet is packed at @1x — sheet "scale": 1 — the app only uses the frame ratios, not the pixel density)
// x, y, w, h = trimmed rect in the sheet (px, top-left origin); ox, oy = its offset inside the full frame;
// fw, fh = full frame size (px). The app derives the sprite's anchor / size from the full frame (sprites-manifest.json).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { decodePNG, encodePNG } from './lib/png.mjs';

const TOOLS = path.dirname(fileURLToPath(import.meta.url));
const IOS = path.resolve(TOOLS, '..');
const SRC = path.join(IOS, 'art', 'Sprites');
const OUT = path.join(IOS, 'App', 'Resources', 'Sheets');
const dry = process.argv.includes('--dry');
const PAGE = 4096;   // max sheet side (every iOS 16 GPU supports 16384)

// BugsGlow frames carry the web bug material's faint violet rim term (alpha ≲ 0.2). In WebGL only the nearest bug's
// rim shows; drawn additively per sprite, hundreds of overlapping rims sum into a purple haze over the swarm. A knee
// on alpha drops the rim and keeps the glands / speckles (alpha 50 → 0, 205 → 255).
function kneeRim(img) {
  const d = img.data;
  for (let i = 0; i < d.length; i += 4) {
    const a = Math.max(0, Math.min(255, Math.round((d[i + 3] - 50) * 255 / 155)));
    d[i + 3] = a;
    if (a === 0) { d[i] = d[i + 1] = d[i + 2] = 0; }
  }
  return img;
}
// Bug bodies are rendered for full light, but the game shows them under the darkness multiply (ambient ≈ 0.3), where
// they went near-black — the web swarm keeps maroon bodies with readable legs (store 2-swarm.png: ≈ 41 / 26 / 28 in
// the dark). A filmic lift per type, y = 255 · (1 − e^(−g·x/255)) / (1 − e^(−g)), multiplies the dark body tones by
// ≈ 4.8 (runner, spitter) / 3.6 (brute) and rolls the highlights off instead of clipping them. Boomers glow orange
// already; contact shadows stay as they are.
const BODY_LIFT = { runner: 6.5, spitter: 6.5, brute: 5.3 };
function liftBody(img, name) {
  if (name.includes('_shadow')) return img;
  const g = BODY_LIFT[name.split('_')[0]];
  if (!g) return img;
  const lut = new Uint8Array(256), norm = 1 - Math.exp(-g);
  for (let v = 0; v < 256; v++) lut[v] = Math.round(255 * (1 - Math.exp(-g * v / 255)) / norm);
  const d = img.data;
  for (let i = 0; i < d.length; i += 4) { d[i] = lut[d[i]]; d[i + 1] = lut[d[i + 1]]; d[i + 2] = lut[d[i + 2]]; }
  return img;
}
const ADJUST = { BugsGlow: kneeRim, Bugs: liftBody };

// Half resolution (@1x) with a "brightest of 2 × 2" filter: the additive emissive layers are soft light, drawn at
// 2× they look the same, and the brightest-sample pick keeps every 1-px glint of the swarm instead of averaging it
// away (the app grows glints by a texel in its glint shader anyway). Saves ~33 MB of the glow sheet's 45 MB.
function halfBrightest(img) {
  const { w, h, data } = img;
  const W = Math.ceil(w / 2), H = Math.ceil(h / 2);
  const out = Buffer.alloc(W * H * 4);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      let best = -1, bi = 0;
      for (let dy = 0; dy < 2; dy++) {
        const sy = Math.min(h - 1, y * 2 + dy);
        for (let dx = 0; dx < 2; dx++) {
          const sx = Math.min(w - 1, x * 2 + dx), i = (sy * w + sx) * 4;
          const v = data[i + 3] * (data[i] * 0.3 + data[i + 1] * 0.59 + data[i + 2] * 0.11 + 1);
          if (v > best) { best = v; bi = i; }
        }
      }
      const o = (y * W + x) * 4;
      out[o] = data[bi]; out[o + 1] = data[bi + 1]; out[o + 2] = data[bi + 2]; out[o + 3] = data[bi + 3];
    }
  }
  return { w: W, h: H, data: out };
}

const isLevelObject = (n) => /^(crate_|pillar$|beacon_base$|lamp_|rail_|lift_center$|lift_rail_)/.test(n);
const GROUPS = [
  { name: 'bugs', parts: [['Bugs'], ['Corpses']] },
  { name: 'squad', parts: [['Marines'], ['Props'], ['Level', isLevelObject]] },
  { name: 'glow', parts: [['BugsGlow'], ['MarinesGlow'], ['LevelGlow'], ['BackgroundGlow']], half: true },
  { name: 'level', parts: [['Level', (n) => !isLevelObject(n)], ['Background']], noTrim: (n) => n === 'bg_haze' || n === 'bg_motes' },
  { name: 'fx', parts: [['Ground'], ['Particles']], noTrim: () => true },
];

function loadFrames(atlas, filter) {
  const dir = path.join(SRC, atlas + '.spriteatlas');
  if (!fs.existsSync(dir)) throw new Error('missing ' + dir + ' (run render-sprites.mjs first)');
  const out = [];
  for (const d of fs.readdirSync(dir).sort()) {
    if (!d.endsWith('.imageset')) continue;
    const name = d.slice(0, -'.imageset'.length);
    if (filter && !filter(name)) continue;
    const contents = JSON.parse(fs.readFileSync(path.join(dir, d, 'Contents.json'), 'utf8'));
    const img = contents.images.find((i) => i.scale === '2x' && i.filename);
    if (!img) throw new Error(`${atlas}/${name}: no @2x image`);
    const png = decodePNG(fs.readFileSync(path.join(dir, d, img.filename)));
    out.push({ name, atlas, png: ADJUST[atlas] ? ADJUST[atlas](png, name) : png });
  }
  return out;
}

// visible bbox (alpha > 0) grown by 1 px, clamped to the image; whole image when trimming is off
function trimBox(img, noTrim) {
  const { w, h, data } = img;
  if (noTrim) return { x: 0, y: 0, w, h };
  let x0 = w, y0 = h, x1 = -1, y1 = -1;
  for (let y = 0; y < h; y++) {
    const row = y * w * 4;
    for (let x = 0; x < w; x++) {
      if (data[row + x * 4 + 3] !== 0) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
  }
  if (x1 < 0) return { x: 0, y: 0, w: 1, h: 1 };   // fully transparent frame: keep one texel
  x0 = Math.max(0, x0 - 1); y0 = Math.max(0, y0 - 1);
  x1 = Math.min(w - 1, x1 + 1); y1 = Math.min(h - 1, y1 + 1);
  return { x: x0, y: y0, w: x1 - x0 + 1, h: y1 - y0 + 1 };
}

// skyline bottom-left packer; slots are the trimmed rect + a 1 px extruded border on every side
class Skyline {
  constructor(W, H) { this.W = W; this.H = H; this.sky = [{ x: 0, y: 0, w: W }]; this.used = 0; }
  fit(i, w) {
    const s = this.sky;
    if (s[i].x + w > this.W) return -1;
    let y = 0, left = w, j = i;
    while (left > 0) {
      if (j >= s.length) return -1;
      y = Math.max(y, s[j].y);
      left -= s[j].w;
      j++;
    }
    return y;
  }
  insert(w, h) {
    let best = -1, bestY = Infinity, bestX = Infinity;
    for (let i = 0; i < this.sky.length; i++) {
      const y = this.fit(i, w);
      if (y < 0 || y + h > this.H) continue;
      if (y < bestY || (y === bestY && this.sky[i].x < bestX)) { best = i; bestY = y; bestX = this.sky[i].x; }
    }
    if (best < 0) return null;
    const s = this.sky, x = s[best].x;
    s.splice(best, 0, { x, y: bestY + h, w });
    // shrink / drop the segments now covered by [x, x + w)
    let i = best + 1;
    while (i < s.length) {
      const prevEnd = s[i - 1].x + s[i - 1].w;
      if (s[i].x >= prevEnd) break;
      const cut = prevEnd - s[i].x;
      if (cut >= s[i].w) { s.splice(i, 1); continue; }
      s[i].x += cut; s[i].w -= cut;
      break;
    }
    for (let k = 0; k < s.length - 1; k++) {
      if (s[k].y === s[k + 1].y) { s[k].w += s[k + 1].w; s.splice(k + 1, 1); k--; }
    }
    this.used = Math.max(this.used, bestY + h);
    return { x, y: bestY };
  }
}

function blit(dst, dw, src, sw, sx, sy, w, h, dx, dy) {
  for (let y = 0; y < h; y++) {
    const s = ((sy + y) * sw + sx) * 4, d = ((dy + y) * dw + dx) * 4;
    src.copy(dst, d, s, s + w * 4);
  }
}

const sheetsOut = [];
const frames = {};
let totalPx = 0;
const t0 = Date.now();
for (const g of GROUPS) {
  const items = [];
  for (const [atlas, filter] of g.parts) {
    for (const f of loadFrames(atlas, filter)) {
      if (g.half) f.png = halfBrightest(f.png);
      const b = trimBox(f.png, g.noTrim ? g.noTrim(f.name) : false);
      items.push({ ...f, box: b });
    }
  }
  // tallest first, then widest: rows of similar frames
  items.sort((a, b) => (b.box.h - a.box.h) || (b.box.w - a.box.w) || (a.name < b.name ? -1 : 1));
  const area = items.reduce((s, it) => s + (it.box.w + 2) * (it.box.h + 2), 0);
  const W = area > 2048 * 2048 * 0.85 ? PAGE : (area > 1024 * 1024 * 0.85 ? 2048 : 1024);
  const pages = [];
  let pk = null;
  for (const it of items) {
    const sw = it.box.w + 2, sh = it.box.h + 2;
    let pos = pk ? pk.insert(sw, sh) : null;
    if (!pos) {
      pk = new Skyline(W, PAGE);
      pages.push(pk);
      pos = pk.insert(sw, sh);
      if (!pos) throw new Error(`${it.name}: ${sw}x${sh} does not fit a ${W}x${PAGE} page`);
    }
    it.page = pages.length - 1;
    it.pos = pos;
  }
  pages.forEach((p, k) => {
    const H = Math.ceil(p.used / 8) * 8;
    const file = pages.length === 1 ? `sheet_${g.name}.png` : `sheet_${g.name}_${k}.png`;
    const idx = sheetsOut.length;
    sheetsOut.push({ name: pages.length === 1 ? g.name : `${g.name}_${k}`, file, w: W, h: H, scale: g.half ? 1 : 2 });
    const pix = Buffer.alloc(W * H * 4);
    for (const it of items.filter((i) => i.page === k)) {
      const { box, png, pos } = it;
      const ix = pos.x + 1, iy = pos.y + 1;
      blit(pix, W, png.data, png.w, box.x, box.y, box.w, box.h, ix, iy);
      // 1 px extrusion so linear filtering at the rect edge never reads a neighbour
      blit(pix, W, png.data, png.w, box.x, box.y, box.w, 1, ix, iy - 1);
      blit(pix, W, png.data, png.w, box.x, box.y + box.h - 1, box.w, 1, ix, iy + box.h);
      for (let y = -1; y <= box.h; y++) {
        const row = (iy + y) * W;
        pix.copy(pix, (row + ix - 1) * 4, (row + ix) * 4, (row + ix) * 4 + 4);
        pix.copy(pix, (row + ix + box.w) * 4, (row + ix + box.w - 1) * 4, (row + ix + box.w - 1) * 4 + 4);
      }
      if (frames[it.name]) throw new Error('duplicate frame name ' + it.name);
      frames[it.name] = [idx, ix, iy, box.w, box.h, box.x, box.y, png.w, png.h];
    }
    totalPx += W * H;
    const eff = items.filter((i) => i.page === k).reduce((s, i) => s + i.box.w * i.box.h, 0) / (W * H);
    console.log(`sheet ${file}: ${W}x${H}, ${items.filter((i) => i.page === k).length} frames, ${(eff * 100).toFixed(0)}% used`);
    if (!dry) {
      fs.mkdirSync(OUT, { recursive: true });
      fs.writeFileSync(path.join(OUT, file), encodePNG(W, H, pix));
    }
  });
}
const names = Object.keys(frames).sort();
const sorted = {};
for (const n of names) sorted[n] = frames[n];
console.log(`${names.length} frames in ${sheetsOut.length} sheets, ${(totalPx / 1e6).toFixed(1)} Mpx = ${(totalPx * 4 / 1048576).toFixed(0)} MB decoded (${((Date.now() - t0) / 1000).toFixed(1)} s)`);
if (!dry) {
  // one frame per line: small diffs when a single set is re-rendered
  const lines = names.map((n) => `    ${JSON.stringify(n)}: ${JSON.stringify(sorted[n])}`);
  const head = `{\n  "scale": 2,\n  "sheets": ${JSON.stringify(sheetsOut)},\n  "frames": {\n`;
  fs.writeFileSync(path.join(OUT, 'sheets.json'), head + lines.join(',\n') + '\n  }\n}\n');
  // stale sheets from an earlier layout
  for (const f of fs.readdirSync(OUT)) if (f.startsWith('sheet_') && !sheetsOut.some((s) => s.file === f)) fs.rmSync(path.join(OUT, f));
}
