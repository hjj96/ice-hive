"""Authoring tool (feel build A3): the armour hull of the marines — per bone, the bind-space extreme points of the
LOD0 vertices it carries (weight ≥ 0.5), in 14 directions, the union over the four classes — written to hull.json.
The action clips (clips.action) keep every hull point of a lying / kneeling pose above the deck with it (the build's
floor gate skins the real mesh; the hull lets the retarget lift the body before that gate, without the mesh).

  python3 -I hull.py RESOURCES_CHARACTERS_DIR     (the marine_<class>.ihv files; rerun after a mesh change)"""
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))
import ihv  # noqa: E402

DIRS = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] + \
       [(x, y, z) for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)]


def main(res):
    pts = {}
    for cls in ('assault', 'pyro', 'cryo', 'gunner'):
        D = ihv.read(os.path.join(res, f'marine_{cls}.ihv'))
        V = D['lods'][0]['vertices']
        rest = V['rest'][:, :3].astype(np.float64)
        w = V['weights'].astype(np.float64) / 255.0
        b = V['bones'].astype(int)
        par = [p for _, p in D['bones']]
        loc = np.array([t for _, t in D['bone_rest']], dtype=np.float64)
        bw = np.zeros((len(par), 3))
        for k in range(len(par)):
            bw[k] = loc[k] + (bw[par[k]] if par[k] >= 0 else 0)
        names = [n for n, _ in D['bones']]
        for k, nm in enumerate(names):
            m = (b[:, 0] == k) & (w[:, 0] >= 0.5)
            if m.sum() < 4:
                continue
            P = rest[m] - bw[k]
            for d in DIRS:
                i = int(np.argmax(P @ np.array(d, dtype=np.float64)))
                pts.setdefault(nm, set()).add(tuple(round(float(x), 3) for x in P[i]))
    out = {nm: sorted(v) for nm, v in sorted(pts.items())}
    json.dump(out, open(os.path.join(HERE, 'hull.json'), 'w'), separators=(',', ':'))
    print({k: len(v) for k, v in out.items()})


if __name__ == '__main__':
    main(sys.argv[1])
