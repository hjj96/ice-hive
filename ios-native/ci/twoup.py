#!/usr/bin/env python3
"""CI 2-up sheets (WP7 «Режиссура»): today | concept | this commit, one sheet per scene of ci/golden/thresholds.json.

Left column: the scene on native-metal before WP7 (golden today-<scene>.jpg, HUD on) above this commit's shot (the
first of the scene's shots that exists; HUD-off when the run has them), both at phone size (1311 × 603). Right: the
concept panel (golden concept-<scene>.jpg: «Кристалл», the base, next to the horror / frost frame each blend rule comes
from). Labels in the game's Oswald; the commit's look numbers (ci/look_metrics.py --json) under its label.

Usage: twoup.py [--golden DIR] [--look look.json] [--sha SHA] <results dir>   → <results dir>/twoup-<scene>.jpg
"""
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONTS = os.path.normpath(os.path.join(HERE, '..', 'App', 'Resources', 'Fonts'))
W1, H1, GAP, HEAD, PAD = 1311, 603, 8, 54, 16
BG = (10, 12, 16)


def font(size, weight='Medium'):
    for f in (os.path.join(FONTS, f'Oswald-{weight}.ttf'), os.path.join(FONTS, 'Oswald-Regular.ttf')):
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


def label(d, xy, text, f, fill=(235, 240, 245), box=(0, 0, 0, 150)):
    x, y = xy
    l, t, r, b = d.textbbox((x, y), text, font=f)
    d.rectangle((l - 8, t - 5, r + 8, b + 6), fill=box)
    d.text((x, y), text, font=f, fill=fill)


def numbers(row):
    if not row:
        return ''
    s = (f'медиана {row["median"]:.0f} · p95/p50 {row["p95_p50"]:.1f} · тёмного {row["dark"]:.0f} % · клип {row["clip"]:.2f} % · '
         f'поры {row["specks"]} · R−B {row["warm"]:+.0f}/{row["cold"]:+.0f}')
    if 'deck_median' in row:
        s += f' · палуба {row["deck_median"]:.0f}'
    if row.get('fails'):
        s += '  · НЕ ПРОШЛО: ' + '; '.join(row['fails'])
    return s


def sheet(name, sc, res, golden, look, sha):
    shot = next((s for s in sc['shots'] if os.path.exists(os.path.join(res, s))), None)
    if not shot:
        return None
    today = Image.open(os.path.join(golden, sc['today'])).convert('RGB').resize((W1, H1), Image.LANCZOS)
    now = Image.open(os.path.join(res, shot)).convert('RGB').resize((W1, H1), Image.LANCZOS)
    concept = Image.open(os.path.join(golden, sc['concept'])).convert('RGB')
    ch = 2 * H1 + GAP
    if concept.height != ch:
        concept = concept.resize((round(concept.width * ch / concept.height), ch), Image.LANCZOS)
    W = PAD + W1 + PAD + concept.width + PAD
    H = HEAD + ch + PAD
    im = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(im, 'RGBA')
    big, mid, small = font(34, 'SemiBold'), font(24), font(19, 'Regular')
    d.text((PAD, 8), f'«ЛЕДЯНОЙ УЛЕЙ» · {name}', font=big, fill=(255, 196, 64))
    sub = 'сегодня (native-metal 385e8a7, до WP7) | концепт | этот коммит' + (f' {sha[:7]}' if sha else '')
    sw = d.textbbox((0, 0), sub, font=mid)[2]
    d.text((W - PAD - sw, 16), sub, font=mid, fill=(170, 180, 190))
    y0 = HEAD
    im.paste(today, (PAD, y0))
    im.paste(now, (PAD, y0 + H1 + GAP))
    im.paste(concept, (PAD + W1 + PAD, y0))
    label(d, (PAD + 12, y0 + 10), 'СЕГОДНЯ · HUD вкл.', mid)
    hud = 'без HUD' if '-nohud' in shot else 'HUD вкл. (замер в маске)'
    label(d, (PAD + 12, y0 + H1 + GAP + 10), f'ЭТОТ КОММИТ · {shot} · {hud}', mid, fill=(120, 230, 255))
    n = numbers(look.get('scenes', {}).get(name))
    if n:
        label(d, (PAD + 12, y0 + H1 + GAP + 52), n, small)
    label(d, (PAD + W1 + PAD + 12, y0 + 10), 'КОНЦЕПТ · ' + sc.get('concept_label', ''), mid, fill=(255, 210, 120))
    return im


def main():
    args = sys.argv[1:]
    golden, lookp, sha = os.path.join(HERE, 'golden'), None, os.environ.get('GITHUB_SHA', '')
    while args and args[0].startswith('--'):
        a = args.pop(0)
        if a == '--golden':
            golden = args.pop(0)
        elif a == '--look':
            lookp = args.pop(0)
        elif a == '--sha':
            sha = args.pop(0)
    if len(args) != 1:
        print(__doc__)
        return 2
    res = args[0]
    cfg = json.load(open(os.path.join(golden, 'thresholds.json')))
    look = json.load(open(lookp)) if lookp and os.path.exists(lookp) else {}
    for name, sc in cfg['scenes'].items():
        im = sheet(name, sc, res, golden, look, sha)
        if im is None:
            print(f'twoup {name}: no shot')
            continue
        p = os.path.join(res, f'twoup-{name}.jpg')
        im.save(p, quality=84, optimize=True)
        print(f'twoup {name}: {p} {im.size[0]}x{im.size[1]} {os.path.getsize(p) // 1024} KB')
    return 0


if __name__ == '__main__':
    sys.exit(main())
