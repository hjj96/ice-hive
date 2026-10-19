"""IHT1 — «Ледяной Улей» raw GPU texture container (ASTC / plain formats, mip chains, arrays). Writer + reader
+ the mip builder and the astcenc driver (numpy + Pillow; astcenc via ios-native/tools/textures/astc.sh).

The project has no MetalKit (no MTKTextureLoader), so the app reads these itself (KitStore.swift): one
MTLTexture per file, every (layer, mip) uploaded with replace(region:mipmapLevel:slice:withBytes:bytesPerRow:
bytesPerImage:) straight from the file bytes.

HEADER (64 bytes)
  0  char[4] "IHT1"   4  u32 version = 1   8  u32 fileBytes   12 u32 flags
                                                                 bit0 sRGB · bit1 normal map (x in .r/.g/.b, y in .a:
                                                                 astcenc -normal; z = sqrt(1 - x² - y²)) · bit2 array
  16 u32 format       1 ASTC 4×4 · 2 ASTC 5×5 · 3 ASTC 6×6 · 4 ASTC 8×8 (all LDR) · 16 RGBA8 · 17 R8 · 18 RG8
  20 u32 width        24 u32 height        28 u32 layers (array length; 1 = plain 2D)     32 u32 mipCount
  36 u32 levelTableOffset                  40..63 reserved 0
LEVEL RECORD (16 bytes, layers × mipCount, layer-major: record = layer * mipCount + mip)
  0  u32 offset       4  u32 bytes         8  u32 bytesPerRow (ASTC: blocksWide × 16)     12 u32 rows (block rows)
Level data starts on 256-byte boundaries. ASTC blocks are the raw 16-byte blocks of astcenc's .astc output without its
16-byte file header.
"""
import hashlib
import os
import struct
import subprocess
import tempfile

import numpy as np

ALIGN = 256
MAGIC = b'IHT1'
HDR = 64
FL_SRGB, FL_NORMAL, FL_ARRAY = 1, 2, 4
ASTC = {1: (4, 4), 2: (5, 5), 3: (6, 6), 4: (8, 8)}
PLAIN = {16: 4, 17: 1, 18: 2}
HDR_FMT = '<4sIIIIIIIII'

HERE = os.path.dirname(os.path.abspath(__file__))
ASTC_SH = os.path.normpath(os.path.join(HERE, '..', 'textures', 'astc.sh'))


def _al(n):
    return (n + ALIGN - 1) // ALIGN * ALIGN


def level_dims(w, h, mip):
    return max(1, w >> mip), max(1, h >> mip)


def level_layout(fmt, w, h):
    """(bytesPerRow, rows, bytes) of one level."""
    if fmt in ASTC:
        bw, bh = ASTC[fmt]
        bx, by = (w + bw - 1) // bw, (h + bh - 1) // bh
        return bx * 16, by, bx * by * 16
    c = PLAIN[fmt]
    return w * c, h, w * h * c


def write(path, fmt, width, height, levels, flags=0):
    """levels[layer][mip] = raw bytes of that level (ASTC blocks or tightly packed pixels)."""
    layers = len(levels)
    mips = len(levels[0])
    assert all(len(l) == mips for l in levels)
    tab_off = HDR
    off = _al(tab_off + 16 * layers * mips)
    recs = b''
    chunks = []
    for L in range(layers):
        for m in range(mips):
            w, h = level_dims(width, height, m)
            bpr, rows, nbytes = level_layout(fmt, w, h)
            b = levels[L][m]
            assert len(b) == nbytes, f'layer {L} mip {m}: {len(b)} bytes, expected {nbytes}'
            recs += struct.pack('<IIII', off, nbytes, bpr, rows)
            chunks.append((off, b))
            off = _al(off + nbytes)
    total = off
    buf = bytearray(total)
    buf[0:HDR] = struct.pack(HDR_FMT, MAGIC, 1, total, flags | (FL_ARRAY if layers > 1 else 0), fmt, width, height, layers,
                             mips, tab_off) + b'\0' * (HDR - struct.calcsize(HDR_FMT))
    buf[tab_off:tab_off + len(recs)] = recs
    for o, b in chunks:
        buf[o:o + len(b)] = b
    with open(path, 'wb') as f:
        f.write(buf)
    return total


def read(path):
    data = open(path, 'rb').read()
    assert data[:4] == MAGIC, 'not an IHT1 file'
    _, ver, total, flags, fmt, w, h, layers, mips, tab = struct.unpack_from(HDR_FMT, data, 0)
    assert ver == 1 and total == len(data), 'version / size mismatch'
    lv = []
    for L in range(layers):
        row = []
        for m in range(mips):
            o, n, bpr, rows = struct.unpack_from('<IIII', data, tab + 16 * (L * mips + m))
            mw, mh = level_dims(w, h, m)
            ebpr, erows, en = level_layout(fmt, mw, mh)
            assert (n, bpr, rows) == (en, ebpr, erows) and o % 16 == 0 and o + n <= total, f'bad level {L}/{m}'
            row.append(data[o:o + n])
        lv.append(row)
    return dict(format=fmt, width=w, height=h, layers=layers, mips=mips, flags=flags, bytes=total, levels=lv)


# ---------------------------------------------------------------- mips
def _down(a):
    """2× box filter of an (h, w, c) float image (odd edges clamp)."""
    h, w = a.shape[:2]
    if h > 1 and h % 2:
        a = np.concatenate([a, a[-1:]], 0)
    if w > 1 and w % 2:
        a = np.concatenate([a, a[:, -1:]], 1)
    h, w = a.shape[:2]
    if h > 1:
        a = 0.5 * (a[0::2] + a[1::2])
    if w > 1:
        a = 0.5 * (a[:, 0::2] + a[:, 1::2])
    return a


def mip_chain(img, kind, min_size=1):
    """img (h, w, c) float 0..1. kind 'normal': img = unit normals xyz in -1..1 (renormalised per level, the lost
    length handed back to `rough_out` for Toksvig); 'data': plain average. Returns [levels] and, for normals, the
    per-level normal-length maps (1 = flat)."""
    out, lens = [img], [np.ones(img.shape[:2], np.float32)]
    a = img.astype(np.float64)
    while max(a.shape[:2]) > min_size:
        a = _down(a)
        if kind == 'normal':
            ln = np.linalg.norm(a, axis=2)
            lens.append(np.clip(ln, 1e-4, 1.0).astype(np.float32))
            out.append((a / np.maximum(ln[..., None], 1e-6)).astype(np.float32))
            # keep averaging the unnormalised vectors (the length keeps the variance of the finer level)
        else:
            out.append(a.astype(np.float32))
            lens.append(np.ones(a.shape[:2], np.float32))
    return out, lens


# ---------------------------------------------------------------- astcenc
def _u8(a):
    return np.clip(np.round(a * 255.0), 0, 255).astype(np.uint8)


def astc_encode(rgba_u8, block, mode, quality='-thorough'):
    """rgba_u8 (h, w, 4) uint8 -> raw ASTC blocks (bytes) through tools/textures/astc.sh (pinned astcenc, invariant
    build: identical output on every machine and thread count). mode: 'data' (-cl) or 'normal' (-cl -normal: input
    R = x, G = y)."""
    from PIL import Image
    with tempfile.TemporaryDirectory() as td:
        src = os.path.join(td, 'in.png')
        dst = os.path.join(td, 'out.astc')
        Image.fromarray(rgba_u8, 'RGBA').save(src)
        args = [ASTC_SH, 'encode', src, dst, f'{block[0]}x{block[1]}', quality] + (['-normal'] if mode == 'normal' else [])
        r = subprocess.run(args, capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError('astcenc failed: ' + r.stdout[-800:] + r.stderr[-800:])
        raw = open(dst, 'rb').read()
    assert raw[:4] == b'\x13\xab\xa1\x5c', 'not an .astc file'
    bw, bh = raw[4], raw[5]
    w = raw[7] | raw[8] << 8 | raw[9] << 16
    h = raw[10] | raw[11] << 8 | raw[12] << 16
    assert (bw, bh) == tuple(block) and (w, h) == rgba_u8.shape[1::-1]
    return raw[16:]


def encode_layers(layers, fmt, kind, toksvig_layers=None):
    """layers: list of (h, w, 4) float images (kind 'normal': xyz unit normals in channels 0..2; 'data': 0..1 values).
    Returns levels[layer][mip] bytes. toksvig_layers: for 'data' ORM layers, the matching normal layers — the lost
    normal length of each mip raises the roughness channel (G) so a minified grating does not sparkle."""
    block = ASTC[fmt]
    out = []
    for li, img in enumerate(layers):
        if kind == 'normal':
            chain, _ = mip_chain(img[..., :3], 'normal')
        else:
            chain, _ = mip_chain(img, 'data')
            if toksvig_layers is not None:
                n = toksvig_layers[li][..., :3]
                _, lens = mip_chain(n, 'normal')
                for m in range(1, len(chain)):
                    ln = lens[m]
                    r = chain[m][..., 1].astype(np.float64)
                    a2 = (r * r) ** 2 + (1.0 - ln) / np.maximum(ln, 1e-3) * 0.5
                    chain[m][..., 1] = np.clip(np.sqrt(np.sqrt(np.clip(a2, 0, 1))), 0, 1)
        row = []
        for lvl in chain:
            if kind == 'normal':
                px = np.zeros(lvl.shape[:2] + (4,), np.uint8)
                px[..., 0] = _u8(lvl[..., 0] * 0.5 + 0.5)
                px[..., 1] = _u8(lvl[..., 1] * 0.5 + 0.5)
                px[..., 3] = 255
                row.append(astc_encode(px, block, 'normal'))
            else:
                row.append(astc_encode(_u8(lvl[..., :4]), block, 'data'))
        out.append(row)
    return out


def md5(path):
    return hashlib.md5(open(path, 'rb').read()).hexdigest()
