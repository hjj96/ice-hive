// Frame-set pipeline: render (supersampled) -> union-trim -> @3x / @2x imagesets inside .spriteatlas folders,
// glow layers, contact sheets and manifest entries.
import fs from 'node:fs';
import path from 'node:path';
import { b64 } from './gamepage.mjs';
import { fromGL, downscale, bbox, unionBox, crop, make, draw, addOnto, blur } from './img.mjs';
import { encodePNG } from './png.mjs';

// World scale: 24 pt per metre at 1x -> 72 px/m @3x, 48 px/m @2x. Frames are rendered at 2x the @3x density
// (144 px/m) and box-filtered down, so crop boxes and anchors are kept on multiples of 6 master pixels.
export const PT_PER_M = 24;
export const SS = 2;                      // supersampling of the @3x image
export const MPPM = PT_PER_M * 3 * SS;    // master pixels per metre (144)
export const SIN_P = Math.sin(57 * Math.PI / 180), COS_P = Math.cos(57 * Math.PI / 180);
export const FOG = [0x1a, 0x27, 0x37];
// approximate in-game ambient (moon + sky) relative to the sprites' full-light rig; used for previews only
export const AMBIENT = [0.27, 0.31, 0.42];

const XC_INFO = { author: 'xcode', version: 1 };
export function json(o) { return JSON.stringify(o, null, 2) + '\n'; }

export class Catalog {
  constructor(dir) { this.dir = dir; this.bytes = 0; this.files = 0; this.atlases = new Set(); }
  atlas(name) {
    const d = path.join(this.dir, name + '.spriteatlas');
    if (!this.atlases.has(name)) {
      fs.rmSync(d, { recursive: true, force: true });
      fs.mkdirSync(d, { recursive: true });
      fs.writeFileSync(path.join(d, 'Contents.json'), json({ info: XC_INFO }));
      this.atlases.add(name);
    }
    return d;
  }
  // images: { '2x': img, '3x': img } (any subset)
  imageset(atlasName, name, images) {
    const d = path.join(this.atlas(atlasName), name + '.imageset');
    fs.mkdirSync(d, { recursive: true });
    const list = [];
    for (const sc of ['1x', '2x', '3x']) {
      const img = images[sc];
      if (!img) { list.push({ idiom: 'universal', scale: sc }); continue; }
      const file = `${name}@${sc}.png`;
      const png = encodePNG(img.w, img.h, img.data);
      fs.writeFileSync(path.join(d, file), png);
      this.bytes += png.length; this.files++;
      list.push({ filename: file, idiom: 'universal', scale: sc });
    }
    fs.writeFileSync(path.join(d, 'Contents.json'), json({ images: list, info: XC_INFO }));
  }
}

async function shot(page, fn, args, W, H, AX, AY, lights) {
  const s = await page.evaluate(({ fn, args, W, H, P, AX, AY, lights }) => {
    window.__S.lightsOn(lights);
    try { return window.__S[fn](...args, W, H, P, AX, AY); } finally { window.__S.lightsOn(1); }
  }, { fn, args, W, H, P: MPPM, AX, AY, lights });
  return fromGL(W, H, b64(s));
}

// emissive-only render (opaque black body, glowing parts) -> additive layer: premultiplied colour, alpha = max channel
function toAdditive(img) {
  const out = make(img.w, img.h);
  for (let i = 0; i < img.w * img.h; i++) {
    const a = img.data[i * 4 + 3] / 255;
    const r = img.data[i * 4] * a, g = img.data[i * 4 + 1] * a, b = img.data[i * 4 + 2] * a;
    const m = Math.max(r, g, b);
    if (m < 2) continue;   // drop the near-black body (and the faint rim term below 1 %)
    out.data[i * 4] = r / m * 255; out.data[i * 4 + 1] = g / m * 255; out.data[i * 4 + 2] = b / m * 255; out.data[i * 4 + 3] = m;
  }
  return out;
}
// additive halo: sharp + gaussian(sigma) * k, re-encoded as premultiplied (alpha = max channel)
function halo(img, sigma, k) {
  const bl = blur(img, sigma), out = make(img.w, img.h);
  for (let i = 0; i < img.w * img.h; i++) {
    const a0 = img.data[i * 4 + 3] / 255, a1 = bl.data[i * 4 + 3] / 255;
    const r = img.data[i * 4] * a0 + bl.data[i * 4] * a1 * k, g = img.data[i * 4 + 1] * a0 + bl.data[i * 4 + 1] * a1 * k, b = img.data[i * 4 + 2] * a0 + bl.data[i * 4 + 2] * a1 * k;
    const m = Math.min(255, Math.max(r, g, b));
    if (m < 1) continue;
    out.data[i * 4] = Math.min(255, r / m * 255); out.data[i * 4 + 1] = Math.min(255, g / m * 255); out.data[i * 4 + 2] = Math.min(255, b / m * 255); out.data[i * 4 + 3] = m;
  }
  return out;
}
function snap(v, m, up) { return up ? Math.ceil(v / m) * m : Math.floor(v / m) * m; }

// set: { id, atlas, glowAtlas?, canvas: [W, H], anchor: [ax, ay] (master px, multiples of 6), frames: [{ name, fn, args }],
//        post?: 'shadow', margin?: master px, meta: {...} }
// returns { entry (manifest), sheet: [{ name, lit3, glow2 }] }
export async function runSet(page, cat, set, log = console.log) {
  const [W, H] = set.canvas, [AX, AY] = set.anchor;
  if (W % 6 || H % 6 || AX % 6 || AY % 6) throw new Error(set.id + ': canvas/anchor must be multiples of 6');
  const t0 = Date.now();
  const lit = [], glow = [];
  for (const f of set.frames) {
    let img = await shot(page, f.fn, f.args, W, H, AX, AY, 1);
    if (set.post === 'shadow') img = blur(img, 2.2);
    else if (typeof set.post === 'function') img = set.post(img, { W, H, AX, AY });
    lit.push(img);
    if (set.glowAtlas) glow.push(toAdditive(await shot(page, f.fn, f.args, W, H, AX, AY, 0)));
  }
  let box = null;
  for (const im of lit) box = unionBox(box, bbox(im, 1));
  for (const im of glow) box = unionBox(box, bbox(im, 1));
  if (!box) throw new Error(set.id + ': empty');
  const m = set.margin ?? 6;
  let x0 = snap(box.x0 - m, 6, false), y0 = snap(box.y0 - m, 6, false);
  let x1 = snap(box.x1 + 1 + m, 6, true), y1 = snap(box.y1 + 1 + m, 6, true);
  if (box.x0 - m < 0 || box.y0 - m < 0 || box.x1 + m >= W || box.y1 + m >= H) log(`  ! ${set.id}: content touches the canvas edge (${JSON.stringify(box)} in ${W}x${H})`);
  const cw = x1 - x0, ch = y1 - y0;
  const sheet = [];
  for (let i = 0; i < set.frames.length; i++) {
    const f = set.frames[i];
    const c = crop(lit[i], x0, y0, cw, ch);
    const im3 = downscale(c, SS), im2 = downscale(c, 3);
    const imgs = {};
    if (!set.only2x) imgs['3x'] = im3;
    imgs['2x'] = im2;
    cat.imageset(set.atlas, f.name, imgs);
    let g2 = null;
    if (set.glowAtlas) {
      const gc = crop(glow[i], x0, y0, cw, ch);
      g2 = halo(downscale(gc, 3), 2.2, 1.4);
      cat.imageset(set.glowAtlas, f.name + '_g', { '2x': g2 });
    }
    sheet.push({ name: f.name, lit3: im3, glow2: g2, dir: f.dir, frame: f.frame });
  }
  const px3 = [cw / SS, ch / SS];
  const entry = {
    atlas: set.atlas,
    ...(set.glowAtlas ? { glowAtlas: set.glowAtlas, glowSuffix: '_g', glowBlend: 'add', glowScale: '2x only' } : {}),
    ...set.meta,
    sizePoints: [+(px3[0] / 3).toFixed(3), +(px3[1] / 3).toFixed(3)],
    pixelSize3x: px3,
    anchor: [+((AX - x0) / cw).toFixed(5), +(1 - (AY - y0) / ch).toFixed(5)],
    anchorPixel3x: [(AX - x0) / SS, (AY - y0) / SS],
    screenSizeMetres: [+(cw / MPPM).toFixed(3), +(ch / MPPM).toFixed(3)],
  };
  log(`  ${set.id}: ${set.frames.length} frames, ${px3[0]}x${px3[1]} px @3x, ${((Date.now() - t0) / 1000).toFixed(1)} s`);
  return { entry, sheet };
}

// contact sheet: rows x cols grid of frames (lit over the fog colour; optional darkness preview with glow on the right)
export function contactSheet(sheet, cols, { dark = true, bg = FOG, scale = 1, gap = 4 } = {}) {
  const cw = Math.max(...sheet.map(s => s.lit3.w)), ch = Math.max(...sheet.map(s => s.lit3.h));
  const rows = Math.ceil(sheet.length / cols);
  const panelW = cols * (cw + gap) + gap, panelH = rows * (ch + gap) + gap;
  const out = make(panelW * (dark ? 2 : 1) + (dark ? gap * 2 : 0), panelH, [...bg, 255]);
  sheet.forEach((s, i) => {
    const x = gap + (i % cols) * (cw + gap), y = gap + Math.floor(i / cols) * (ch + gap);
    draw(out, s.lit3, x + ((cw - s.lit3.w) >> 1), y + ((ch - s.lit3.h) >> 1));
    if (dark) {
      const xo = panelW + gap * 2;
      const dk = make(s.lit3.w, s.lit3.h, [...bg, 255]);
      for (let p = 0; p < dk.w * dk.h; p++) {
        const a = s.lit3.data[p * 4 + 3] / 255;
        for (let c = 0; c < 3; c++) dk.data[p * 4 + c] = bg[c] * (1 - a) + s.lit3.data[p * 4 + c] * AMBIENT[c] * a;
      }
      draw(out, dk, xo + x + ((cw - s.lit3.w) >> 1), y + ((ch - s.lit3.h) >> 1));
      if (s.glow2) {
        // upsample the @2x glow to @3x for the preview (nearest/bilinear-ish 1.5x)
        const g3 = make(Math.round(s.glow2.w * 1.5), Math.round(s.glow2.h * 1.5));
        for (let yy = 0; yy < g3.h; yy++) for (let xx = 0; xx < g3.w; xx++) {
          const sx = Math.min(s.glow2.w - 1, Math.floor(xx / 1.5)), sy = Math.min(s.glow2.h - 1, Math.floor(yy / 1.5));
          const so = (sy * s.glow2.w + sx) * 4, d = (yy * g3.w + xx) * 4;
          g3.data[d] = s.glow2.data[so]; g3.data[d + 1] = s.glow2.data[so + 1]; g3.data[d + 2] = s.glow2.data[so + 2]; g3.data[d + 3] = s.glow2.data[so + 3];
        }
        addOnto(out, g3, xo + x + ((cw - s.lit3.w) >> 1), y + ((ch - s.lit3.h) >> 1));
      }
    }
  });
  return scale === 1 ? out : downscale(out, scale);
}
export function savePNG(file, img) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, encodePNG(img.w, img.h, img.data));
}

// small preview (committed under tools/previews/): one row per set, frame 0 of every `step`-th direction (or the
// first `max` frames), over the fog colour, downscaled from @3x by `k`
export function previewRows(sheet, { step = 2, max = 8 } = {}) {
  const hasDir = sheet.some(s => s.dir !== undefined);
  const pick = hasDir ? sheet.filter(s => s.dir % step === 0 && !s.frame) : sheet;
  return pick.slice(0, max).map(s => s.lit3);
}
export function composePreview(rows, k = 2, gap = 6, bg = FOG) {
  const W = Math.max(...rows.map(r => r.reduce((a, im) => a + im.w + gap, gap)));
  const H = rows.reduce((a, r) => a + Math.max(...r.map(im => im.h)) + gap, gap);
  const out = make(W, H, [...bg, 255]);
  let y = gap;
  for (const r of rows) {
    let x = gap;
    const rh = Math.max(...r.map(im => im.h));
    for (const im of r) { draw(out, im, x, y + rh - im.h); x += im.w + gap; }
    y += rh + gap;
  }
  return downscale(out, k);
}
