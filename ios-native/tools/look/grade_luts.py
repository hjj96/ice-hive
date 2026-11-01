#!/usr/bin/env python3
"""Grade LUTs of the four moods (WP7 «Режиссура»): App/Resources/Grade/<mood>.lut.

The composite (Shaders/Post.metal fs_composite) applies, per pixel:
    scene (+ bloom) × 2^EV → ACES (three.js fit) → sRGB → 32³ LUT → brightness gamma → vignette → grain → dither
so a LUT maps display-referred sRGB to display-referred sRGB. Format: raw 32³ RGBA8, r fastest, then g, then b,
alpha 255, 131 072 bytes (PostChain.loadResources / makeLUT). The EV of each mood and of each cinematic shot is in
App/Resources/Look/exposure.json (not here).

The look is the user's blend: «Кристалл» (crisp: neutral-cool, readable, tight) as the base, with horror's deep blacks
(the soft toe below ~4 % stays — ambient is faint moonlight, the squad's lights are the light) and no heavy wash. Every
mood starts from the built-in "gameplay" grade of PostChain.grade() (kept identical here: `base`) and adds:

  gameplay    a small lift of the low mid-tones (≈ 6–30 %: the lamp-lit deck and the dark structure, where the swarm
              has to read) — the near-blacks under the toe and the highlights are untouched — and a little more contrast
              around the mid-tones (pivot 30 %, 0.20 since the polish pass: the lit pools and effects stand off the body of the frame, swarmshot
              p95/p50 ≥ 3.6 with the median at 40+); cool shadows / neutral-warm highlights as before
  beacon      gameplay + warmer highlights (the amber beacon column and the muzzles) and a touch more mid contrast
  extraction  gameplay + cooler, a little more open shadows (the lift shaft is the darkest set: its void reads as
              deep teal-navy instead of black) and cleaner cyan highlights (the lift ring)
  title       gameplay + deeper toe and a stronger split tone (the attract mode behind the menu: a still, a poster)

Usage:
    python3 grade_luts.py                     # writes the four .lut files (deterministic: identical bytes every run)
    python3 grade_luts.py --check             # verifies the committed files match this script
    python3 grade_luts.py --simulate shot.png --mood gameplay --ev 0.1 [--brightness 1.3] [--out sim.png]
                                              # estimate what a CI shot (graded with the built-in grade at 0 EV) would
                                              # look like with this mood, EV and brightness (approximate inverse)
"""
import argparse
import os
import sys

import numpy as np

N = 32
W709 = np.array([0.2126, 0.7152, 0.0722])
HERE = os.path.dirname(os.path.abspath(__file__))
GRADE_DIR = os.path.normpath(os.path.join(HERE, '..', '..', 'App', 'Resources', 'Grade'))
MOODS = ('gameplay', 'beacon', 'extraction', 'title')


def smooth01(x):
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3.0 - 2.0 * x)


def luma(c):
    return c @ W709


def base(c):
    """PostChain.grade (the built-in "gameplay" grade) — keep in sync with PostChain.swift."""
    x = np.maximum(0.0, c - 0.03 * (1.0 - smooth01(c / 0.3)))           # toe: sinks only the near-blacks
    t = np.clip(x, 0.0, 1.0)
    x = t + (t * t * (3.0 - 2.0 * t) - t) * 0.22                       # S-curve around the mid-tones
    l = luma(x)[..., None]
    sat = 0.9 + (1.06 - 0.9) * smooth01((l - 0.04) / 0.3)              # 0.9 deep shadows → 1.06 from the mids up
    x = l + (x - l) * sat
    sh = 1.0 - smooth01(l / 0.45)
    hl = smooth01((l - 0.55) / 0.45)
    x = x + np.array([-0.006, 0.001, 0.008]) * sh + np.array([0.010, 0.004, -0.008]) * hl
    return np.clip(x, 0.0, 1.0)


def bump(l, lo, peak, hi):
    """0 below lo, rises to 1 at peak, falls to 0 at hi (smooth)."""
    up = smooth01((l - lo) / max(1e-6, peak - lo))
    down = 1.0 - smooth01((l - peak) / max(1e-6, hi - peak))
    return up * down


def lift_lowmids(x, amount, lo=0.035, peak=0.14, hi=0.42):
    """Hue-preserving gain on the low mid-tones: luma l → l · (1 + amount · bump(l))."""
    l = luma(x)[..., None]
    g = 1.0 + amount * bump(l, lo, peak, hi)
    return np.clip(x * g, 0.0, 1.0)


def contrast_mids(x, amount, pivot=0.32):
    """A little more (amount > 0) mid-tone contrast around `pivot`, highlights and blacks kept (luma-driven gain)."""
    l = luma(x)[..., None]
    w = bump(l, 0.06, pivot, 0.8)
    target = pivot + (l - pivot) * (1.0 + amount)
    g = np.where(l > 1e-4, (l + (target - l) * w) / np.maximum(l, 1e-4), 1.0)
    return np.clip(x * g, 0.0, 1.0)


def tint(x, shadows, highlights, sh_end=0.45, hl_start=0.55):
    l = luma(x)[..., None]
    sh = 1.0 - smooth01(l / sh_end)
    hl = smooth01((l - hl_start) / (1.0 - hl_start))
    return np.clip(x + np.array(shadows) * sh + np.array(highlights) * hl, 0.0, 1.0)


def deeper_toe(x, depth):
    """Extra black point: sinks values under ~8 % a little more (title poster blacks)."""
    return np.maximum(0.0, x - depth * (1.0 - smooth01(x / 0.18)))


def saturate_by_luma(x, lo_sat, hi_sat, l0=0.06, l1=0.5):
    l = luma(x)[..., None]
    s = lo_sat + (hi_sat - lo_sat) * smooth01((l - l0) / (l1 - l0))
    return np.clip(l + (x - l) * s, 0.0, 1.0)


def grade(c, mood):
    x = base(c)
    if mood == 'gameplay':
        x = lift_lowmids(x, 0.10)
        x = contrast_mids(x, 0.20, pivot=0.30)
    elif mood == 'beacon':
        x = lift_lowmids(x, 0.10)
        x = contrast_mids(x, 0.06)
        x = tint(x, (0.0, 0.0, 0.0), (0.012, 0.004, -0.014), hl_start=0.5)
    elif mood == 'extraction':
        x = lift_lowmids(x, 0.16, peak=0.12)
        x = tint(x, (-0.004, 0.003, 0.008), (-0.004, 0.004, 0.006))
        x = saturate_by_luma(x, 1.0, 1.05)
    elif mood == 'title':
        x = deeper_toe(x, 0.008)
        x = lift_lowmids(x, 0.06)
        x = tint(x, (-0.004, 0.0, 0.007), (0.010, 0.003, -0.010))
    else:
        raise ValueError(mood)
    return x


def lut_bytes(mood):
    i = np.arange(N, dtype=np.float64) / (N - 1)
    b, g, r = np.meshgrid(i, i, i, indexing='ij')               # b slowest, r fastest
    c = np.stack([r, g, b], axis=-1)
    out = grade(c, mood)
    px = np.empty(out.shape[:-1] + (4,), dtype=np.uint8)
    px[..., :3] = np.round(out * 255.0).astype(np.uint8)
    px[..., 3] = 255
    data = px.tobytes()
    assert len(data) == N * N * N * 4
    return data


# ---------------------------------------------------------------- simulation (estimates only)
def srgb_encode(v):
    v = np.clip(v, 0.0, 1.0)
    return np.where(v <= 0.0031308, v * 12.92, 1.055 * np.power(v, 1.0 / 2.4) - 0.055)


def srgb_decode(v):
    v = np.clip(v, 0.0, 1.0)
    return np.where(v <= 0.04045, v / 12.92, np.power((v + 0.055) / 1.055, 2.4))


ACES_IN = np.array([[0.59719, 0.35458, 0.04823], [0.07600, 0.90834, 0.01566], [0.02840, 0.13383, 0.83777]])
ACES_OUT = np.array([[1.60475, -0.53108, -0.07367], [-0.10208, 1.10813, -0.00605], [-0.00327, -0.07276, 1.07602]])


def display(lin):
    """three.js ACESFilmicToneMapping (Post.metal acesFilmic) + sRGB — PostChain.display."""
    a = (lin / 0.6) @ ACES_IN.T
    r = (a * (a + 0.0245786) - 0.000090537) / (a * (0.983729 * a + 0.4329510) + 0.238081)
    return srgb_encode(r @ ACES_OUT.T)


def invert(f, y, x0, iters=40, damp=0.9):
    """Per-pixel fixed-point inverse of a near-monotone colour map f (vectorised)."""
    x = x0.copy()
    for _ in range(iters):
        x = np.clip(x + (y - f(x)) * damp, 0.0, 1.0)
    return x


def simulate(path, mood, ev, brightness, out=None):
    from PIL import Image
    im = Image.open(path).convert('RGB')
    w, h = im.size
    if w > 1400:
        im = im.resize((w // 2, h // 2), Image.BILINEAR)
    d = np.asarray(im).astype(np.float64) / 255.0
    pre = invert(base, d, d)                                    # display value before the built-in grade
    if ev != 0:
        # exposure: invert display() by a multiplicative search on the linear value, scale, re-display (rough: strongly
        # saturated colours do not invert cleanly — isolated speckles in the saved image are this, not the LUT)
        lin = srgb_decode(pre) * 0.6
        for _ in range(40):
            cur = display(lin)
            lin = np.clip(lin * np.power(np.maximum(srgb_decode(pre), 1e-5) / np.maximum(srgb_decode(cur), 1e-5), 0.8), 0.0, 64.0)
        d2 = display(lin * (2.0 ** ev))
        d2 = np.where(pre >= 0.999, pre, d2)
    else:
        d2 = pre
    g = grade(d2, mood)
    g = np.power(np.maximum(g, 0.0), 1.0 / brightness)
    o = np.clip(np.round(g * 255.0), 0, 255).astype(np.uint8)
    if out:
        Image.fromarray(o).save(out)
    y0 = luma(d * 255.0)
    y1 = luma(o.astype(np.float64))
    print(f'{os.path.basename(path)} mood {mood} ev {ev:+.2f} brightness {brightness:.2f}: median luma {np.median(y0):.1f} → '
          f'{np.median(y1):.1f}, mean {y0.mean():.1f} → {y1.mean():.1f}, p95 {np.percentile(y0, 95):.1f} → '
          f'{np.percentile(y1, 95):.1f}, near-black {(y0 < 16).mean() * 100:.1f} % → {(y1 < 16).mean() * 100:.1f} %')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--check', action='store_true', help='verify the committed LUTs match this script')
    ap.add_argument('--out', default=GRADE_DIR, help='output folder (default App/Resources/Grade)')
    ap.add_argument('--simulate', metavar='PNG')
    ap.add_argument('--mood', default='gameplay', choices=MOODS)
    ap.add_argument('--ev', type=float, default=0.0)
    ap.add_argument('--brightness', type=float, default=1.0)
    ap.add_argument('--save', metavar='PNG', help='--simulate: write the estimated image')
    a = ap.parse_args()
    if a.simulate:
        simulate(a.simulate, a.mood, a.ev, a.brightness, a.save)
        return 0
    bad = 0
    for m in MOODS:
        data = lut_bytes(m)
        p = os.path.join(a.out, m + '.lut')
        if a.check:
            ok = os.path.exists(p) and open(p, 'rb').read() == data
            print(f'{m}.lut {"ok" if ok else "DIFFERS"}')
            bad |= not ok
        else:
            os.makedirs(a.out, exist_ok=True)
            with open(p, 'wb') as f:
                f.write(data)
            print(f'{p}: {len(data)} bytes')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
