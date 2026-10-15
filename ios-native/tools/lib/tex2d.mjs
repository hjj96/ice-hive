// Flat 2D textures (ground-plane decals / telegraphs, screen-facing particles): helpers to pull images out of the
// page, write them as single-scale imagesets, and build contact sheets.
import { b64 } from './gamepage.mjs';
import { make, draw, addOnto, downscale, crop } from './img.mjs';
import { FOG } from './pipeline.mjs';

export async function pageImage(page, fn, ...args) {
  const r = await page.evaluate(({ fn, args }) => window.__S[fn](...args), { fn, args });
  return typeof r === 'string' ? null : { w: r.w, h: r.h, data: new Uint8ClampedArray(b64(r.b64)) };
}
// WebGL readback (rows bottom-up) of a W x H shot
export async function pageGL(page, fn, W, H, ...args) {
  const s = await page.evaluate(({ fn, args }) => window.__S[fn](...args), { fn, args });
  const buf = b64(s), data = new Uint8ClampedArray(W * H * 4), stride = W * 4;
  for (let y = 0; y < H; y++) data.set(buf.subarray((H - 1 - y) * stride, (H - y) * stride), y * stride);
  return { w: W, h: H, data };
}
// emissive render on transparent black (additive blending wrote rgb with alpha 1) -> premultiplied-style additive
// texture: alpha = max channel, colour normalised (SpriteKit .add with a premultiplied texture adds rgb * a)
export function additive(img) {
  const out = make(img.w, img.h);
  for (let i = 0; i < img.w * img.h; i++) {
    const r = img.data[i * 4], g = img.data[i * 4 + 1], b = img.data[i * 4 + 2], m = Math.max(r, g, b);
    if (m < 1) continue;
    out.data[i * 4] = r / m * 255; out.data[i * 4 + 1] = g / m * 255; out.data[i * 4 + 2] = b / m * 255; out.data[i * 4 + 3] = m;
  }
  return out;
}
// white mask from a float alpha field
export function maskImage(w, h, fn) {
  const out = make(w, h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const a = Math.max(0, Math.min(1, fn(x, y)));
    const o = (y * w + x) * 4;
    out.data[o] = out.data[o + 1] = out.data[o + 2] = 255; out.data[o + 3] = Math.round(a * 255);
  }
  return out;
}
export function subImage(img, x, y, w, h) { return crop(img, x, y, w, h); }

// contact sheet of flat textures: additive ones over black, alpha ones over the fog colour, multiply ones over a
// light grey; cells larger than `cell` px are box-downscaled
export function sheet2d(items, { cols = 8, cell = 192, gap = 6 } = {}) {
  const prepared = items.map(it => {
    let im = it.img, k = 1;
    while (Math.max(im.w, im.h) / k > cell) k++;
    if (k > 1) im = downscale(im, k);
    return { ...it, im };
  });
  const cw = Math.max(...prepared.map(p => p.im.w)), ch = Math.max(...prepared.map(p => p.im.h));
  const rows = Math.ceil(prepared.length / cols);
  const out = make(cols * (cw + gap) + gap, rows * (ch + gap) + gap, [12, 14, 18, 255]);
  prepared.forEach((p, i) => {
    const x = gap + (i % cols) * (cw + gap), y = gap + Math.floor(i / cols) * (ch + gap);
    const bg = p.mode === 'add' ? [0, 0, 0] : p.mode === 'mul' ? [196, 200, 206] : FOG;
    const tile = make(p.im.w, p.im.h, [...bg, 255]);
    if (p.mode === 'add') addOnto(tile, p.im, 0, 0);
    else if (p.mode === 'mul') draw(tile, p.im, 0, 0, { mode: 'mul' });
    else draw(tile, p.im, 0, 0, { tint: p.tint });
    draw(out, tile, x + ((cw - p.im.w) >> 1), y + ((ch - p.im.h) >> 1));
  });
  return out;
}
