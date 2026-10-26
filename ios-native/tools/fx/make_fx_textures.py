#!/usr/bin/env python3
"""«Ледяной Улей» — the effects' textures (WP5 «Эффекты»), built procedurally and deterministically:

  App/Resources/FX/fx_fire.iht    8 × 8 flipbook of a flame puff (r = heat, g = density), 1024², ASTC 6×6 + mips
  App/Resources/FX/fx_blast.iht   8 × 8 flipbook of a fireball rolling into dark billows (r = heat, g = density)
  App/Resources/FX/fx_smoke.iht   8 × 8 flipbook of a smoke puff (r = shade lit from above the camera, g = density)
  App/Resources/FX/fx_decals.iht  4 × 2 stain atlas, 1024 × 512, ASTC 4×4 + mips: r coverage, g thickness (wet
                                  relief), b flecks / embers / crystal glints, a variation. Cells: 0 splat, 1 streak,
                                  2 gore, 3 scorch, 4 acid pool, 5 frost rime, 6 small splat, 7 drips.

Frames run row by row from the top-left (frame f at column f % 8, row f // 8); sprite space has +y up (row 0 is the
top). Every frame fades to zero before its cell's edge (no bleeding between frames, mips stop at 8 px per cell).

  python3 tools/fx/make_fx_textures.py [--out App/Resources/FX] [--preview DIR]

Needs numpy + Pillow and the pinned astcenc (tools/textures/astc.sh, through tools/blender/iht.py); the same inputs
give byte-identical files on every machine (fixed seeds, invariant astcenc).
"""
import argparse
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'tools', 'blender'))
import iht  # noqa: E402

CELL = 128          # flipbook frame size (px)
GRID = 8            # 8 × 8 frames
DCELL = 256         # decal cell size (px)


# ---------------------------------------------------------------- noise
class Noise3:
    """Smooth value noise on a periodic random lattice in (x, y, t), fbm on top."""

    def __init__(self, seed, size=64):
        self.lat = np.random.default_rng(seed).random((size, size, size)).astype(np.float64)
        self.n = size

    def value(self, x, y, t):
        n = self.n
        xi, yi, ti = np.floor(x).astype(np.int64), np.floor(y).astype(np.int64), np.floor(t).astype(np.int64)
        xf, yf, tf = x - xi, y - yi, t - ti
        sx, sy, st = xf * xf * (3 - 2 * xf), yf * yf * (3 - 2 * yf), tf * tf * (3 - 2 * tf)
        L = self.lat

        def g(dx, dy, dt):
            return L[(xi + dx) % n, (yi + dy) % n, (ti + dt) % n]
        a = g(0, 0, 0) * (1 - sx) + g(1, 0, 0) * sx
        b = g(0, 1, 0) * (1 - sx) + g(1, 1, 0) * sx
        c = g(0, 0, 1) * (1 - sx) + g(1, 0, 1) * sx
        d = g(0, 1, 1) * (1 - sx) + g(1, 1, 1) * sx
        e = a * (1 - sy) + b * sy
        f = c * (1 - sy) + d * sy
        return e * (1 - st) + f * st

    def fbm(self, x, y, t, octaves=4, lac=2.03, gain=0.5):
        s, amp, norm = 0.0, 1.0, 0.0
        for o in range(octaves):
            s = s + amp * self.value(x * lac ** o + 17.3 * o, y * lac ** o - 9.1 * o, t * (1.0 + 0.4 * o) + 3.7 * o)
            norm += amp
            amp *= gain
        return s / norm


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def grid(size):
    """Sprite-space coordinates in −1…1 (x right, y up) at pixel centres."""
    v = (np.arange(size) + 0.5) / size * 2 - 1
    x, y = np.meshgrid(v, -v)
    return x, y


def edge_window(x, y, inner=0.82):
    return smoothstep(1.0, inner, np.maximum(np.abs(x), np.abs(y)))


def blur(a, r):
    """Separable box blur, 3 passes (≈ gaussian)."""
    out = a
    k = 2 * r + 1
    for _ in range(3):
        p = np.pad(out, ((r, r), (0, 0)), mode='edge')
        c = np.cumsum(p, 0)
        c = np.concatenate([np.zeros((1, c.shape[1])), c], 0)
        out = (c[k:] - c[:-k]) / k
        p = np.pad(out, ((0, 0), (r, r)), mode='edge')
        c = np.cumsum(p, 1)
        c = np.concatenate([np.zeros((c.shape[0], 1)), c], 1)
        out = (c[:, k:] - c[:, :-k]) / k
    return out


# ---------------------------------------------------------------- flipbooks
def puff_field(x, y, puffs, N, t, warp=0.18, detail=0.35, soft=0.72, relief=1.0):
    """A cluster of soft spheres seen from the camera: the union's coverage, the top surface's height and its normal
    (the classic puff-sprite look). The coordinates are domain-warped by fbm so the outline billows."""
    wx = N.fbm(x * 2.1 + 3.3, y * 2.1 - t * 1.5, t * 1.7, 3) - 0.5
    wy = N.fbm(x * 2.1 - 7.7, y * 2.1 - t * 1.5 + 4.1, t * 1.7 + 9, 3) - 0.5
    X, Y = x + warp * wx, y + warp * wy
    H = np.full(x.shape, -1.0)
    cov = np.zeros_like(x)
    for (cx, cy, r) in puffs:
        q2 = ((X - cx) ** 2 + (Y - cy) ** 2) / (r * r)
        z = np.sqrt(np.clip(1 - q2, 0, 1))
        h = np.where(q2 < 1, z * r + cy * 0.15, -1.0)
        H = np.maximum(H, h)
        cov = np.maximum(cov, smoothstep(1.0, soft, np.sqrt(q2)))
    fine = N.fbm(X * 7 + 1.7, Y * 7 - t * 2, t * 2.3 + 5, 4)
    Hs = blur(np.where(H > -1, H, 0) + detail * 0.08 * fine * cov, 2)
    gy, gx = np.gradient(Hs)
    k = x.shape[0] * 0.5 * relief
    nx, ny = -gx * k, gy * k
    nz = np.ones_like(x)
    ln = np.sqrt(nx * nx + ny * ny + nz * nz)
    return cov, np.where(H > -1, H, 0), (nx / ln, ny / ln, nz / ln), fine


def lam(nrm, L):
    L = np.array(L, np.float64)
    L = L / np.linalg.norm(L)
    return np.clip(nrm[0] * L[0] + nrm[1] * L[1] + nrm[2] * L[2], 0, 1)


def make_puffs(rng, n, spread, rmin, rmax, lift=0.0):
    out = []
    for i in range(n):
        a = rng.random() * 2 * np.pi
        d = spread * rng.random() ** 0.7
        out.append((np.cos(a) * d, np.sin(a) * d * 0.8 + lift * rng.random(), rmin + (rmax - rmin) * rng.random(), a, d))
    return out


def smoke_frame(N, t, x, y, base):
    grow = 1 - (1 - t) ** 2.2
    puffs = []
    for (px, py, pr, a, d) in base:
        s = 0.7 + 0.45 * grow
        puffs.append((px * (0.75 + 0.55 * grow), py * (0.75 + 0.55 * grow) + 0.08 * grow, pr * s))
    cov, H, nrm, fine = puff_field(x, y, puffs, N, t, warp=0.24 + 0.12 * t, soft=0.45, relief=2.6)
    # thins out late in the life: a soft, low-frequency erosion (no speckle)
    coarse = N.fbm(x * 2.2 + 6.1, y * 2.2 - t * 0.8, t * 1.2 + 3, 3)
    erode = -0.2 + 0.85 * t * t
    d = cov * smoothstep(erode, erode + 0.45, coarse) * (0.78 + 0.22 * fine)
    d = np.clip(d * 1.1, 0, 1) * edge_window(x, y)
    # lit from above the camera; the underside in its own shadow (density between the pixel and the top)
    above = np.cumsum(blur(d, 2), 0) / x.shape[0] * 5.0
    shade = (0.12 + 0.88 * lam(nrm, (-0.3, 0.8, 0.5))) * (0.45 + 0.55 * np.exp(-above * 2.2)) + 0.08 * H
    return np.clip(shade, 0, 1), d


def fire_frame(N, t, x, y, base):
    grow = 1 - (1 - t) ** 2
    # a flame: an ellipse anchored low in the cell, its edge torn by fbm that rises through it (more turbulence
    # higher up), domain-warped into tongues; the core hottest, the tongues cooler; it swells, then burns out
    wx = N.fbm(x * 1.7 + 4.1, y * 1.7 - t * 3.0, t * 2.0, 3) - 0.5
    X = x + 0.32 * wx * (0.4 + (y + 1) * 0.5)
    sc = 0.62 + 0.38 * grow
    ex, ey = X / (0.56 * sc), (y + 0.4) / (0.86 * sc)
    shape = 1 - np.sqrt(ex * ex + np.maximum(ey, -1.5) ** 2 * np.where(ey > 0, 0.55, 1.6))
    h = np.clip((y + 0.8) / 1.6, 0, 1)
    n = N.fbm(X * 2.6 + 1.3, (y - t * 3.4) * 2.4, t * 2.6, 5)
    f = shape + (n - 0.5) * (0.55 + 0.9 * h) - 0.32 * t * t
    dens = smoothstep(0.0, 0.22, f)
    heat = smoothstep(-0.05, 0.75, f) * (1.05 - 0.45 * h) * (1.0 - 0.45 * t)
    w = edge_window(x, y)
    return np.clip(heat * w, 0, 1), np.clip(dens * w, 0, 1)


def blast_frame(N, t, x, y, base):
    grow = 1 - (1 - t) ** 2.6
    puffs = []
    for (px, py, pr, a, d) in base:
        puffs.append((px * (0.35 + 0.75 * grow), py * (0.35 + 0.75 * grow) + 0.12 * grow, pr * (0.45 + 0.6 * grow)))
    cov, H, nrm, fine = puff_field(x, y, puffs, N, t * 1.4, warp=0.2, detail=0.8)
    dens = np.clip(cov * (0.75 + 0.35 * fine) * 1.15 - 0.25 * t * t, 0, 1)
    r = np.sqrt(x * x + y * y) / (0.3 + 0.6 * grow)
    # hot where the billows are thick and near the core; it cools from the rim inward, glowing creases last longest
    thick = np.clip(H / 0.45, 0, 1)
    crease = 1 - np.abs(2 * fine - 1)
    cool = np.clip(t * 1.25 + 0.35 * r * t, 0, 1)
    heat = dens * ((0.55 + 0.6 * thick) * (1 - cool) ** 1.3 + crease ** 3 * 0.45 * (1 - t) ** 0.7)
    heat *= 0.7 + 0.45 * lam(nrm, (0.0, 0.3, 1.0))
    if t < 0.12:
        heat = np.maximum(heat, dens * (1 - t / 0.12))
    w = edge_window(x, y)
    return np.clip(heat * w, 0, 1), np.clip(dens * w, 0, 1)


def flipbook(kind, seed):
    N = Noise3(seed)
    x, y = grid(CELL)
    atlas = np.zeros((CELL * GRID, CELL * GRID, 4), np.float32)
    rng = np.random.default_rng(seed + 1)
    if kind == 'smoke':
        base = make_puffs(rng, 14, 0.5, 0.26, 0.42)
    elif kind == 'fire':
        base = make_puffs(rng, 13, 0.36, 0.22, 0.4, lift=0.75)
    else:
        base = make_puffs(rng, 15, 0.5, 0.2, 0.36)
    for f in range(GRID * GRID):
        t = f / (GRID * GRID - 1)
        if kind == 'smoke':
            r, g = smoke_frame(N, t, x, y, base)
        elif kind == 'fire':
            r, g = fire_frame(N, t, x, y, base)
        else:
            r, g = blast_frame(N, t, x, y, base)
        cx, cy = f % GRID, f // GRID
        cell = atlas[cy * CELL:(cy + 1) * CELL, cx * CELL:(cx + 1) * CELL]
        cell[..., 0] = r
        cell[..., 1] = g
        cell[..., 3] = 1.0
    return atlas


# ---------------------------------------------------------------- decals
def decal_cell(kind, seed):
    N = Noise3(seed)
    rng = np.random.default_rng(seed)
    x, y = grid(DCELL)
    r = np.sqrt(x * x + y * y)
    ang = np.arctan2(y, x)
    var = N.fbm(x * 3 + 1, y * 3 - 2, 0.5, 4)
    cov = np.zeros_like(x)
    thick = np.zeros_like(x)
    fl = np.zeros_like(x)

    def droplets(n, rmin, rmax, smin, smax, along=None):
        c, h = np.zeros_like(x), np.zeros_like(x)
        for _ in range(n):
            if along is None:
                a = rng.random() * 2 * np.pi
                d = rmin + (rmax - rmin) * rng.random() ** 0.7
                px, py = np.cos(a) * d, np.sin(a) * d
            else:
                py = rmin + (rmax - rmin) * rng.random()
                px = (rng.random() - 0.5) * along * (0.4 + py)
            s = smin + (smax - smin) * rng.random()
            q = np.sqrt((x - px) ** 2 + (y - py) ** 2) / s
            c = np.maximum(c, smoothstep(1.0, 0.7, q))
            h = np.maximum(h, np.clip(1 - q * q, 0, 1))
        return c, h

    def flecks(n, rad, size, mask):
        f = np.zeros_like(x)
        for _ in range(n):
            a = rng.random() * 2 * np.pi
            d = rad * rng.random() ** 0.5
            px, py = np.cos(a) * d, np.sin(a) * d
            q = np.sqrt((x - px) ** 2 + (y - py) ** 2) / (size * (0.6 + 0.8 * rng.random()))
            f = np.maximum(f, smoothstep(1.0, 0.2, q))
        return f * mask

    if kind in ('splat', 'small'):
        sc = 0.55 if kind == 'splat' else 0.38
        edge = N.fbm(np.cos(ang) * 2.2 + 3, np.sin(ang) * 2.2 + 3, 0.2, 4)
        q = r / (sc * (0.7 + 0.6 * edge))
        cov = smoothstep(1.0, 0.85, q)
        thick = np.clip(1 - q, 0, 1) ** 0.6 * (0.7 + 0.3 * var)
        dc, dh = droplets(14 if kind == 'splat' else 6, sc * 1.05, 0.92, 0.02, 0.07)
        cov = np.maximum(cov, dc)
        thick = np.maximum(thick, dh * 0.7)
        fl = flecks(22 if kind == 'splat' else 9, sc * 0.95, 0.035, cov)
    elif kind == 'streak':
        # a splat thrown along +y (the shot): an elongated torn teardrop, droplets flung ahead of it
        edge = N.fbm(x * 3.5 + 2, y * 2.0, 0.7, 4)
        yy = y + 0.25
        wx = 0.3 * np.clip(1.0 - (yy + 0.45) * 0.45, 0.25, 1.0)
        q = np.sqrt((x / wx) ** 2 + (yy / 0.62) ** 2) / (0.78 + 0.45 * edge)
        cov = smoothstep(1.0, 0.85, q)
        thick = np.clip(1 - q, 0, 1) ** 0.6
        dc, dh = droplets(16, 0.45, 0.92, 0.015, 0.05, along=0.5)
        cov = np.maximum(cov, dc)
        thick = np.maximum(thick, dh * 0.6)
        fl = flecks(16, 0.5, 0.03, cov)
    elif kind == 'gore':
        for _ in range(7):
            a = rng.random() * 2 * np.pi
            d = 0.45 * rng.random() ** 0.8
            cx, cy = np.cos(a) * d, np.sin(a) * d
            s = 0.08 + 0.12 * rng.random()
            e = N.fbm((x - cx) * 6 + rng.random() * 9, (y - cy) * 6, 0.3, 3)
            q = np.sqrt((x - cx) ** 2 + ((y - cy) * (1 + rng.random())) ** 2) / (s * (0.7 + 0.6 * e))
            cov = np.maximum(cov, smoothstep(1.0, 0.75, q))
            thick = np.maximum(thick, np.clip(1 - q, 0, 1) ** 0.5)
        sm = smoothstep(0.75, 0.3, r) * smoothstep(0.35, 0.6, var) * 0.6
        cov = np.maximum(cov, sm)
        fl = flecks(14, 0.55, 0.03, cov)
    elif kind == 'scorch':
        # soot thinning outward, rays thrown out by the blast, embers near the middle
        rays = N.fbm(np.cos(ang) * 6 + 4, np.sin(ang) * 6 + 4, 0.1, 3)
        q = r / (0.62 + 0.3 * rays)
        cov = smoothstep(1.0, 0.25, q) * (0.75 + 0.25 * var)
        thick = np.zeros_like(x)
        fl = flecks(40, 0.45, 0.02, smoothstep(0.7, 0.2, r))
    elif kind == 'acid':
        edge = N.fbm(np.cos(ang) * 1.8 + 7, np.sin(ang) * 1.8 + 7, 0.9, 4)
        q = r / (0.66 * (0.72 + 0.5 * edge))
        cov = smoothstep(1.0, 0.9, q)
        thick = smoothstep(1.0, 0.35, q) * (0.75 + 0.25 * var)
        # bubbles: rings on the pool
        for _ in range(16):
            a = rng.random() * 2 * np.pi
            d = 0.5 * rng.random() ** 0.6
            px, py = np.cos(a) * d, np.sin(a) * d
            s = 0.02 + 0.05 * rng.random()
            qq = np.sqrt((x - px) ** 2 + (y - py) ** 2) / s
            ring = np.exp(-((qq - 1) * 5) ** 2)
            thick = np.maximum(thick, ring * cov)
            fl = np.maximum(fl, ring * cov)
    elif kind == 'frost':
        # rime: dendritic spokes and a crystalline edge, glints on the crystals
        spokes = np.abs(np.sin(ang * 6 + N.fbm(x * 3, y * 3, 0.4, 3) * 4))
        den = N.fbm(x * 9 + 1, y * 9 + 5, 0.6, 4)
        edge = N.fbm(np.cos(ang) * 3 + 2, np.sin(ang) * 3 + 2, 0.2, 4)
        q = r / (0.7 * (0.7 + 0.5 * edge))
        cov = smoothstep(1.0, 0.55, q) * np.clip(0.45 + 0.55 * den + 0.35 * spokes * (1 - q), 0, 1)
        thick = cov * 0.4 * den
        fl = smoothstep(0.78, 0.9, N.fbm(x * 22, y * 22, 0.9, 2)) * cov
    elif kind == 'drips':
        dc, dh = droplets(26, -0.85, 0.85, 0.02, 0.06, along=0.25)
        cov, thick = dc, dh * 0.8
        fl = flecks(8, 0.5, 0.025, cov)
    w = edge_window(x, y, 0.88)
    return np.clip(cov * w, 0, 1), np.clip(thick * w, 0, 1), np.clip(fl * w, 0, 1), np.clip(var, 0, 1)


def decal_atlas(seed):
    kinds = ['splat', 'streak', 'gore', 'scorch', 'acid', 'frost', 'small', 'drips']
    atlas = np.zeros((DCELL * 2, DCELL * 4, 4), np.float32)
    for i, k in enumerate(kinds):
        c, t, f, v = decal_cell(k, seed + 31 * i)
        cx, cy = i % 4, i // 4
        cell = atlas[cy * DCELL:(cy + 1) * DCELL, cx * DCELL:(cx + 1) * DCELL]
        cell[..., 0], cell[..., 1], cell[..., 2], cell[..., 3] = c, t, f, v
    return atlas


# ---------------------------------------------------------------- output
def write_iht(path, img, fmt, min_size):
    chain, _ = iht.mip_chain(img, 'data', min_size=min_size)
    block = iht.ASTC[fmt]
    levels = [[iht.astc_encode(iht._u8(lv[..., :4]), block, 'data') for lv in chain]]
    n = iht.write(path, fmt, img.shape[1], img.shape[0], levels)
    return n, len(chain)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=os.path.join(ROOT, 'App', 'Resources', 'FX'))
    ap.add_argument('--preview', default=None, help='also write PNG previews here')
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    jobs = [('fx_fire', flipbook('fire', 101), 3, 64), ('fx_blast', flipbook('blast', 202), 3, 64),
            ('fx_smoke', flipbook('smoke', 303), 3, 64), ('fx_decals', decal_atlas(404), 1, 32)]
    for name, img, fmt, mn in jobs:
        p = os.path.join(a.out, name + '.iht')
        n, mips = write_iht(p, img, fmt, mn)
        print(f'{name}.iht  {img.shape[1]}x{img.shape[0]}  ASTC {iht.ASTC[fmt][0]}x{iht.ASTC[fmt][1]}  {mips} mips  {n / 1024:.0f} KB  md5 {iht.md5(p)}')
        if a.preview:
            from PIL import Image
            os.makedirs(a.preview, exist_ok=True)
            Image.fromarray(iht._u8(img), 'RGBA').save(os.path.join(a.preview, name + '.png'))


if __name__ == '__main__':
    main()
