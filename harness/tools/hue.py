import sys, colorsys
from PIL import Image
def stats(path, box):
    im = Image.open(path).convert('RGB').crop(box)
    n = mag = lit = 0; satsum = 0.0
    for r, g, b in im.get_flattened_data() if hasattr(im, "get_flattened_data") else im.getdata():
        h, s, v = colorsys.rgb_to_hsv(r/255, g/255, b/255)
        n += 1
        if v > 0.22:
            lit += 1
            if s > 0.35 and (285 <= h*360 <= 352): mag += 1
            satsum += s
    return dict(px=n, bright=round(lit/n, 3), magentaPink=round(mag/n, 4), meanSatBright=round(satsum/max(1, lit), 3))
for a in sys.argv[1:]:
    p, b = a.split('@'); box = tuple(int(x) for x in b.split(','))
    print(p, box, stats(p, box))
