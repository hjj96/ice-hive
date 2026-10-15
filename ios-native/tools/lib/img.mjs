// Small RGBA image toolkit (straight alpha, 8-bit, rows top-down): { w, h, data: Uint8ClampedArray }.
// Resampling and blurs work on premultiplied values so edges never pick up dark fringes.
export function make(w, h, rgba = [0, 0, 0, 0]) {
  const data = new Uint8ClampedArray(w * h * 4);
  if (rgba[3] || rgba[0] || rgba[1] || rgba[2]) for (let i = 0; i < w * h; i++) data.set(rgba, i * 4);
  return { w, h, data };
}

// WebGL readPixels output (rows bottom-up) -> image
export function fromGL(w, h, buf) {
  const data = new Uint8ClampedArray(w * h * 4), stride = w * 4;
  for (let y = 0; y < h; y++) data.set(buf.subarray((h - 1 - y) * stride, (h - y) * stride), y * stride);
  return { w, h, data };
}

// k x k box filter (k integer) — exact supersampling resolve
export function downscale(img, k) {
  if (k === 1) return { w: img.w, h: img.h, data: new Uint8ClampedArray(img.data) };
  const w = Math.floor(img.w / k), h = Math.floor(img.h / k), out = new Uint8ClampedArray(w * h * 4), s = img.data, n = k * k;
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let r = 0, g = 0, b = 0, a = 0;
    for (let j = 0; j < k; j++) {
      let o = ((y * k + j) * img.w + x * k) * 4;
      for (let i = 0; i < k; i++, o += 4) { const al = s[o + 3]; r += s[o] * al; g += s[o + 1] * al; b += s[o + 2] * al; a += al; }
    }
    const q = (y * w + x) * 4;
    if (a > 0) { out[q] = r / a; out[q + 1] = g / a; out[q + 2] = b / a; out[q + 3] = a / n; }
  }
  return { w, h, data: out };
}

// tight bounding box of pixels with alpha >= thr; null when empty
export function bbox(img, thr = 1) {
  let x0 = img.w, y0 = img.h, x1 = -1, y1 = -1;
  const d = img.data;
  for (let y = 0; y < img.h; y++) {
    const row = y * img.w * 4;
    for (let x = 0; x < img.w; x++) if (d[row + x * 4 + 3] >= thr) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
  }
  return x1 < 0 ? null : { x0, y0, x1, y1 };
}
export function unionBox(a, b) {
  if (!a) return b; if (!b) return a;
  return { x0: Math.min(a.x0, b.x0), y0: Math.min(a.y0, b.y0), x1: Math.max(a.x1, b.x1), y1: Math.max(a.y1, b.y1) };
}

// crop (areas outside the source become transparent)
export function crop(img, x0, y0, w, h) {
  const out = make(w, h);
  for (let y = 0; y < h; y++) {
    const sy = y0 + y; if (sy < 0 || sy >= img.h) continue;
    for (let x = 0; x < w; x++) {
      const sx = x0 + x; if (sx < 0 || sx >= img.w) continue;
      const s = (sy * img.w + sx) * 4, d = (y * w + x) * 4;
      out.data[d] = img.data[s]; out.data[d + 1] = img.data[s + 1]; out.data[d + 2] = img.data[s + 2]; out.data[d + 3] = img.data[s + 3];
    }
  }
  return out;
}

// source-over compositing of src onto dst at integer offset (both straight alpha); mode 'over' | 'add' | 'mul'
export function draw(dst, src, ox, oy, { mode = 'over', alpha = 1, tint = null } = {}) {
  const tr = tint ? tint[0] : 1, tg = tint ? tint[1] : 1, tb = tint ? tint[2] : 1;
  for (let y = 0; y < src.h; y++) {
    const dy = oy + y; if (dy < 0 || dy >= dst.h) continue;
    for (let x = 0; x < src.w; x++) {
      const dx = ox + x; if (dx < 0 || dx >= dst.w) continue;
      const s = (y * src.w + x) * 4, d = (dy * dst.w + dx) * 4;
      const sa = src.data[s + 3] / 255 * alpha;
      if (sa <= 0) continue;
      const sr = src.data[s] * tr, sg = src.data[s + 1] * tg, sb = src.data[s + 2] * tb;
      const da = dst.data[d + 3] / 255;
      if (mode === 'add') {
        // premultiplied sum, alpha saturates at 1
        const oa = Math.min(1, da + sa);
        dst.data[d] = (dst.data[d] * da + sr * sa) / oa;
        dst.data[d + 1] = (dst.data[d + 1] * da + sg * sa) / oa;
        dst.data[d + 2] = (dst.data[d + 2] * da + sb * sa) / oa;
        dst.data[d + 3] = oa * 255;
        continue;
      }
      if (mode === 'mul') {
        // multiply the destination colour by mix(1, src, sa) (decal stains)
        dst.data[d] *= 1 - sa + sa * sr / 255; dst.data[d + 1] *= 1 - sa + sa * sg / 255; dst.data[d + 2] *= 1 - sa + sa * sb / 255;
        continue;
      }
      const oa = sa + da * (1 - sa);
      dst.data[d] = (sr * sa + dst.data[d] * da * (1 - sa)) / oa;
      dst.data[d + 1] = (sg * sa + dst.data[d + 1] * da * (1 - sa)) / oa;
      dst.data[d + 2] = (sb * sa + dst.data[d + 2] * da * (1 - sa)) / oa;
      dst.data[d + 3] = oa * 255;
    }
  }
}

// additive blend onto an OPAQUE destination (contact sheets / previews)
export function addOnto(dst, src, ox, oy, k = 1) {
  for (let y = 0; y < src.h; y++) {
    const dy = oy + y; if (dy < 0 || dy >= dst.h) continue;
    for (let x = 0; x < src.w; x++) {
      const dx = ox + x; if (dx < 0 || dx >= dst.w) continue;
      const s = (y * src.w + x) * 4, d = (dy * dst.w + dx) * 4, a = src.data[s + 3] / 255 * k;
      dst.data[d] += src.data[s] * a; dst.data[d + 1] += src.data[s + 1] * a; dst.data[d + 2] += src.data[s + 2] * a;
    }
  }
}

// multiply an opaque image by an RGB factor (preview of the in-game darkness)
export function multiply(img, f) {
  const out = { w: img.w, h: img.h, data: new Uint8ClampedArray(img.data) };
  for (let i = 0; i < out.data.length; i += 4) { out.data[i] *= f[0]; out.data[i + 1] *= f[1]; out.data[i + 2] *= f[2]; }
  return out;
}

// separable gaussian blur on premultiplied values
export function blur(img, sigma) {
  const r = Math.max(1, Math.ceil(sigma * 3)), ker = [];
  let ks = 0;
  for (let i = -r; i <= r; i++) { const v = Math.exp(-i * i / (2 * sigma * sigma)); ker.push(v); ks += v; }
  for (let i = 0; i < ker.length; i++) ker[i] /= ks;
  const { w, h } = img, n = w * h;
  let p = new Float32Array(n * 4);
  for (let i = 0; i < n; i++) { const a = img.data[i * 4 + 3] / 255; p[i * 4] = img.data[i * 4] * a; p[i * 4 + 1] = img.data[i * 4 + 1] * a; p[i * 4 + 2] = img.data[i * 4 + 2] * a; p[i * 4 + 3] = a * 255; }
  const q = new Float32Array(n * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let r0 = 0, g0 = 0, b0 = 0, a0 = 0;
    for (let k = -r; k <= r; k++) { const xx = x + k; if (xx < 0 || xx >= w) continue; const o = (y * w + xx) * 4, kv = ker[k + r]; r0 += p[o] * kv; g0 += p[o + 1] * kv; b0 += p[o + 2] * kv; a0 += p[o + 3] * kv; }
    const o = (y * w + x) * 4; q[o] = r0; q[o + 1] = g0; q[o + 2] = b0; q[o + 3] = a0;
  }
  const out = make(w, h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let r0 = 0, g0 = 0, b0 = 0, a0 = 0;
    for (let k = -r; k <= r; k++) { const yy = y + k; if (yy < 0 || yy >= h) continue; const o = (yy * w + x) * 4, kv = ker[k + r]; r0 += q[o] * kv; g0 += q[o + 1] * kv; b0 += q[o + 2] * kv; a0 += q[o + 3] * kv; }
    const o = (y * w + x) * 4;
    if (a0 > 0.01) { out.data[o] = r0 / (a0 / 255); out.data[o + 1] = g0 / (a0 / 255); out.data[o + 2] = b0 / (a0 / 255); out.data[o + 3] = a0; }
  }
  return out;
}

// pad an image by m pixels on every side
export function pad(img, m) { return crop(img, -m, -m, img.w + 2 * m, img.h + 2 * m); }

export function hexRGB(hex) { return [(hex >> 16) & 255, (hex >> 8) & 255, hex & 255]; }
