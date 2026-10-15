// Minimal PNG encode/decode (RGBA 8-bit, non-interlaced) on top of node:zlib — no npm dependencies.
// encodePNG picks a filter per row (minimum sum of absolute differences heuristic, like libpng's default).
import zlib from 'node:zlib';

const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();
function crc32(buf, start = 0, end = buf.length) {
  let c = -1;
  for (let i = start; i < end; i++) c = CRC_TABLE[(c ^ buf[i]) & 255] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}
function chunk(type, data) {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, 'ascii');
  Buffer.from(data.buffer, data.byteOffset, data.length).copy(out, 8);
  out.writeUInt32BE(crc32(out, 4, 8 + data.length), 8 + data.length);
  return out;
}
const SIG = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

function paeth(a, b, c) {
  const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
  return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
}

// rgba: Uint8Array/Buffer, length w*h*4, straight (non-premultiplied) alpha, rows top-down.
// Fully transparent pixels are written as 0,0,0,0 (better compression, no colour garbage under alpha 0).
export function encodePNG(w, h, rgba, { level = 9 } = {}) {
  const stride = w * 4;
  const src = Buffer.from(rgba.buffer, rgba.byteOffset, rgba.length);
  const clean = Buffer.allocUnsafe(src.length);
  for (let i = 0; i < src.length; i += 4) {
    if (src[i + 3] === 0) { clean[i] = clean[i + 1] = clean[i + 2] = clean[i + 3] = 0; }
    else { clean[i] = src[i]; clean[i + 1] = src[i + 1]; clean[i + 2] = src[i + 2]; clean[i + 3] = src[i + 3]; }
  }
  const raw = Buffer.alloc((stride + 1) * h);
  const cand = [Buffer.alloc(stride), Buffer.alloc(stride), Buffer.alloc(stride), Buffer.alloc(stride), Buffer.alloc(stride)];
  for (let y = 0; y < h; y++) {
    const row = y * stride, prev = (y - 1) * stride;
    let best = 0, bestSum = Infinity;
    for (let f = 0; f < 5; f++) {
      const o = cand[f];
      let sum = 0;
      for (let x = 0; x < stride; x++) {
        const v = clean[row + x];
        const a = x >= 4 ? clean[row + x - 4] : 0;
        const b = y > 0 ? clean[prev + x] : 0;
        const c = x >= 4 && y > 0 ? clean[prev + x - 4] : 0;
        let r;
        if (f === 0) r = v;
        else if (f === 1) r = v - a;
        else if (f === 2) r = v - b;
        else if (f === 3) r = v - ((a + b) >> 1);
        else r = v - paeth(a, b, c);
        r &= 255;
        o[x] = r;
        sum += r < 128 ? r : 256 - r;
        if (sum >= bestSum) break;
      }
      if (sum < bestSum) { bestSum = sum; best = f; }
    }
    // recompute the winner fully (the loop above may have stopped early for it on a later candidate)
    const o = cand[best];
    for (let x = 0; x < stride; x++) {
      const v = clean[row + x];
      const a = x >= 4 ? clean[row + x - 4] : 0;
      const b = y > 0 ? clean[prev + x] : 0;
      const c = x >= 4 && y > 0 ? clean[prev + x - 4] : 0;
      let r;
      if (best === 0) r = v;
      else if (best === 1) r = v - a;
      else if (best === 2) r = v - b;
      else if (best === 3) r = v - ((a + b) >> 1);
      else r = v - paeth(a, b, c);
      o[x] = r & 255;
    }
    raw[y * (stride + 1)] = best;
    o.copy(raw, y * (stride + 1) + 1);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  const idat = zlib.deflateSync(raw, { level, memLevel: 9, strategy: zlib.constants.Z_DEFAULT_STRATEGY });
  return Buffer.concat([SIG, chunk('IHDR', ihdr), chunk('IDAT', idat), chunk('IEND', Buffer.alloc(0))]);
}

// Decodes 8-bit RGBA / RGB / grey(+alpha) PNGs (non-interlaced) to { w, h, data: RGBA Buffer }.
export function decodePNG(buf) {
  if (!buf.subarray(0, 8).equals(SIG)) throw new Error('not a PNG');
  let p = 8, w = 0, h = 0, ct = 0, bd = 0, il = 0;
  const idat = [];
  while (p < buf.length) {
    const len = buf.readUInt32BE(p), type = buf.toString('ascii', p + 4, p + 8), data = buf.subarray(p + 8, p + 8 + len);
    if (type === 'IHDR') { w = data.readUInt32BE(0); h = data.readUInt32BE(4); bd = data[8]; ct = data[9]; il = data[12]; }
    else if (type === 'IDAT') idat.push(data);
    else if (type === 'IEND') break;
    p += 12 + len;
  }
  if (bd !== 8 || il !== 0) throw new Error('unsupported PNG (bit depth ' + bd + ', interlace ' + il + ')');
  const ch = { 0: 1, 2: 3, 4: 2, 6: 4 }[ct];
  if (!ch) throw new Error('unsupported PNG colour type ' + ct);
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = w * ch, img = Buffer.alloc(stride * h);
  for (let y = 0; y < h; y++) {
    const f = raw[y * (stride + 1)], s = y * (stride + 1) + 1, row = y * stride, prev = (y - 1) * stride;
    for (let x = 0; x < stride; x++) {
      const a = x >= ch ? img[row + x - ch] : 0, b = y > 0 ? img[prev + x] : 0, c = x >= ch && y > 0 ? img[prev + x - ch] : 0;
      let v = raw[s + x];
      if (f === 1) v += a; else if (f === 2) v += b; else if (f === 3) v += (a + b) >> 1; else if (f === 4) v += paeth(a, b, c);
      img[row + x] = v & 255;
    }
  }
  if (ch === 4) return { w, h, data: img };
  const out = Buffer.alloc(w * h * 4);
  for (let i = 0; i < w * h; i++) {
    if (ch === 3) { out[i * 4] = img[i * 3]; out[i * 4 + 1] = img[i * 3 + 1]; out[i * 4 + 2] = img[i * 3 + 2]; out[i * 4 + 3] = 255; }
    else if (ch === 1) { out[i * 4] = out[i * 4 + 1] = out[i * 4 + 2] = img[i]; out[i * 4 + 3] = 255; }
    else { out[i * 4] = out[i * 4 + 1] = out[i * 4 + 2] = img[i * 2]; out[i * 4 + 3] = img[i * 2 + 1]; }
  }
  return { w, h, data: out };
}
