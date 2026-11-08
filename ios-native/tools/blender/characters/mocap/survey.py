"""Authoring tool: root speed / height / travel summary of BVH takes (a text parse, no FK) — the first look at a
candidate take. CMU units × 0.05644 = m, 100STYLE cm. Beware: some CMU subjects (141, 143, …) were captured at 60 fps
but the cgspeed conversion stamps every take 120 fps — their speeds read twice too fast; the clips use none of them.

  python3 -I survey.py FILES..."""
import sys

import numpy as np


def main(files):
    for f in files:
        L = open(f).read().split('\n')
        i = next(k for k, l in enumerate(L) if l.strip().startswith('Frames:'))
        n = int(L[i].split()[1])
        dt = float(L[i + 1].split()[-1])
        rootch = [l for l in L[:i] if 'CHANNELS' in l][0].split()[2:]
        M = np.array([[float(x) for x in l.split()] for l in L[i + 2:i + 2 + n] if l.strip()])
        xi, yi, zi = rootch.index('Xposition'), rootch.index('Yposition'), rootch.index('Zposition')
        P = M[:, [xi, yi, zi]]
        v = np.linalg.norm(np.diff(P[:, [0, 2]], axis=0), axis=1) / dt
        print(f"{f.split('/')[-1]}: frames {n} fps {1 / dt:.0f} dur {n * dt:.2f}s hipY mean {P[:, 1].mean():.2f} "
              f"speed p50 {np.percentile(v, 50):.2f} p90 {np.percentile(v, 90):.2f} (units/s) "
              f"travel {np.linalg.norm(P[-1, [0, 2]] - P[0, [0, 2]]):.1f}")


if __name__ == '__main__':
    main(sys.argv[1:])
