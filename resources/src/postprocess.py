#!/usr/bin/env python3
"""Post-process the Playwright renders for «Ледяной Улей».

- downsample the 2x icon renders to 1024x1024 (Lanczos), flatten to RGB (no alpha channel)
- copy the picked concept to resources/icon.png
- flatten the splash to RGB -> resources/splash.png
- build resources/src/icon-contact.png: every concept at 1024 preview + 180/120/60/40 px,
  masked like iOS does, on a dark and a light home-screen wallpaper
- verify sizes + PNG colour type straight from the IHDR chunk
"""
import argparse
import os
import struct

from PIL import Image, ImageDraw, ImageFont

ap = argparse.ArgumentParser()
ap.add_argument('--pick', default='hex')
ap.add_argument('--raw', required=True)
ap.add_argument('--out', required=True)
ap.add_argument('--src', required=True)
ap.add_argument('--only', default='all')
a = ap.parse_args()

CONCEPTS = [('hex', 'A «Сота» (ice hive cell)'), ('beam', 'B «Луч» (flashlight beam)'), ('lasers', 'C «Перекрестье» (squad crossfire)')]
BG = (5, 7, 10)


def flatten(im):
    """RGBA -> RGB over the game background (screenshots are opaque already; this only drops the channel)."""
    if im.mode in ('RGBA', 'LA', 'P'):
        im = im.convert('RGBA')
        base = Image.new('RGB', im.size, BG)
        base.paste(im, mask=im.split()[3])
        return base
    return im.convert('RGB')


def ios_mask(size, ss=4):
    """Approximate the iOS app-icon squircle (continuous corners) with a superellipse, n≈5."""
    s = size * ss
    m = Image.new('L', (s, s), 0)
    px = m.load()
    n = 5.0
    r = s / 2.0
    for y in range(s):
        dy = abs((y + 0.5 - r) / r)
        lim = (1 - dy ** n) ** (1 / n) if dy < 1 else 0
        x0 = int(round(r - lim * r))
        x1 = int(round(r + lim * r))
        for x in range(x0, x1):
            px[x, y] = 255
    return m.resize((size, size), Image.LANCZOS)


icons = {}
if a.only in ('all', 'icons'):
    for key, _ in CONCEPTS:
        raw = Image.open(os.path.join(a.raw, f'icon-{key}@2x.png'))
        im = flatten(raw).resize((1024, 1024), Image.LANCZOS)
        im.save(os.path.join(a.src, f'icon-{key}.png'), optimize=True)
        icons[key] = im
    icons[a.pick].save(os.path.join(a.out, 'icon.png'), optimize=True)

    # ---- contact sheet ----
    sizes = [180, 120, 60, 40]
    pad = 28
    prev = 360
    row_h = prev + 2 * pad
    wall_w = sum(sizes) + pad * (len(sizes) + 1)
    W = pad + prev + pad + wall_w * 2 + pad
    H = 70 + row_h * len(CONCEPTS) + 40
    sheet = Image.new('RGB', (W, H), (18, 20, 24))
    d = ImageDraw.Draw(sheet)
    def load_font(sz):
        for cand in ('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', '/System/Library/Fonts/Supplemental/Arial.ttf', '/Library/Fonts/Arial.ttf'):
            if os.path.exists(cand):
                return ImageFont.truetype(cand, sz)
        try:
            return ImageFont.load_default(size=sz)
        except TypeError:  # very old Pillow
            return ImageFont.load_default()
    font, small = load_font(22), load_font(16)
    d.text((pad, 22), 'Ледяной Улей — app icon concepts (iOS mask simulated; 180/120/60/40 px, Lanczos from 1024)', fill=(220, 230, 238), font=font)
    for i, (key, label) in enumerate(CONCEPTS):
        y0 = 70 + i * row_h
        im = icons[key]
        sheet.paste(im.resize((prev, prev), Image.LANCZOS), (pad, y0 + pad))
        d.text((pad + 6, y0 + 6), label + ('   <- PICK' if key == a.pick else ''), fill=(255, 180, 32) if key == a.pick else (200, 210, 220), font=small)
        for w, wall in enumerate([(30, 38, 52), (196, 206, 218)]):
            x0 = pad + prev + pad + w * wall_w
            sheet.paste(Image.new('RGB', (wall_w, row_h - pad), wall), (x0, y0 + pad // 2))
            x = x0 + pad
            for s in sizes:
                ic = im.resize((s, s), Image.LANCZOS)
                yy = y0 + pad // 2 + (row_h - pad - s) // 2
                sheet.paste(ic, (x, yy), ios_mask(s))
                x += s + pad
    d.text((pad, H - 30), 'left wall: dark home screen  ·  right wall: light home screen', fill=(140, 150, 160), font=small)
    sheet.save(os.path.join(a.src, 'icon-contact.png'), optimize=True)

if a.only in ('all', 'splash'):
    sp = flatten(Image.open(os.path.join(a.raw, 'splash@1x.png')))
    sp.save(os.path.join(a.out, 'splash.png'), optimize=True)
    # preview of what iPhones actually show (scaleAspectFill crops to the central ~1257 px)
    prevs = []
    for name, (wpt, hpt) in [('SE 375x667', (375, 667)), ('13 mini 375x812', (375, 812)), ('16 Pro Max 440x956', (440, 956)), ('landscape 932x430', (932, 430))]:
        # visible image px: the long side spans the whole 2732; the short side is cropped
        vis_w = round(2732 * min(wpt, hpt) / max(wpt, hpt)) if wpt < hpt else 2732
        vis_h = 2732 if wpt < hpt else round(2732 * hpt / wpt)
        crop = sp.crop(((2732 - vis_w) // 2, (2732 - vis_h) // 2, (2732 + vis_w) // 2, (2732 + vis_h) // 2))
        k = 520 / max(crop.size)
        prevs.append((name, crop.resize((round(crop.size[0] * k), round(crop.size[1] * k)), Image.LANCZOS)))
    PW = sum(p.size[0] for _, p in prevs) + 28 * (len(prevs) + 1)
    sheet = Image.new('RGB', (PW, 600), (40, 44, 50))
    d = ImageDraw.Draw(sheet)
    x = 28
    for name, p in prevs:
        sheet.paste(p, (x, 50 + (520 - p.size[1]) // 2))
        d.text((x, 16), name, fill=(220, 230, 238))
        x += p.size[0] + 28
    sheet.save(os.path.join(a.src, 'splash-crops.png'), optimize=True)


# ---- verification (reads the PNG header directly, independent of Pillow's mode guess) ----
def ihdr(path):
    with open(path, 'rb') as fh:
        head = fh.read(33)
    assert head[:8] == b'\x89PNG\r\n\x1a\n', 'not a PNG'
    w, h, depth, ctype = struct.unpack('>IIBB', head[16:26])
    return w, h, depth, ctype


CT = {0: 'grayscale', 2: 'RGB (truecolor, no alpha)', 3: 'palette', 4: 'gray+alpha', 6: 'RGBA'}
print('verification:')
for name, want in [('icon.png', (1024, 1024)), ('splash.png', (2732, 2732))]:
    p = os.path.join(a.out, name)
    if not os.path.exists(p):
        continue
    w, h, depth, ctype = ihdr(p)
    im = Image.open(p)
    ok = (w, h) == want and ctype == 2 and im.mode == 'RGB' and 'transparency' not in im.info
    print(f'  {name}: {w}x{h}, bit depth {depth}, colour type {ctype} = {CT.get(ctype)}, PIL mode {im.mode}, '
          f'tRNS={"transparency" in im.info}, {os.path.getsize(p)} bytes -> {"OK" if ok else "FAIL"}')
    if not ok:
        raise SystemExit(f'{name} failed verification')
