"""The «wooden» numbers of the feel study (feel-spec §1.2) for shipped marine files: body-part ranges (head pitch / yaw,
weapon bob, spine bend, pelvis), harmonic purity of the loops (1.0 = a pure sum of sines), the chest's lag behind the
pelvis (overlap) and the peak frames of one-shots — numpy only, from the clip tracks (FK of skeleton.py).

  python3 -B characters/mocap/metrics.py BEFORE_CHARACTERS_DIR AFTER_CHARACTERS_DIR [OUT.json] [--cls assault]"""
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(os.path.dirname(HERE)))
import ihv  # noqa: E402
import skeleton as S  # noqa: E402
from skeleton import IDX, qconj, qmul, qrotate  # noqa: E402

CLIPS = ('idle', 'idle_b', 'walk_f', 'walk_l', 'walk_b', 'run_f', 'run_l', 'run_b', 'turn_l', 'dash_f')


def fk(row, cls='assault'):
    p = S.Pose(cls)
    p.q = row[:, 0].astype(np.float64).copy()
    p.t = row[:, 1, :3].astype(np.float64).copy()
    return p.world()


def angles(q):
    f = qrotate(q, (0, 0, 1.0))
    r = qrotate(q, (1.0, 0, 0))
    yaw = np.degrees(np.arctan2(f[0], f[2]))
    pitch = np.degrees(np.arcsin(np.clip(-f[1], -1, 1)))
    roll = np.degrees(np.arcsin(np.clip(r[1], -1, 1)))
    return yaw, pitch, roll


def channels(rows):
    C = {k: [] for k in ('pelvis_y_cm', 'pelvis_x_cm', 'pelvis_z_cm', 'pelvis_yaw', 'pelvis_pitch', 'pelvis_roll',
                         'chest_rel_yaw', 'chest_rel_pitch', 'chest_rel_roll', 'head_yaw', 'head_pitch', 'head_roll',
                         'head_y_cm', 'weapon_pitch', 'weapon_y_cm', 'knee_L', 'spine_bend')}
    for row in rows:
        WQ, WP = fk(row)
        pq, cq, hq = WQ[IDX['pelvis']], WQ[IDX['chest']], WQ[IDX['head']]
        C['pelvis_y_cm'].append(WP[IDX['pelvis'], 1] * 100)
        C['pelvis_x_cm'].append(WP[IDX['pelvis'], 0] * 100)
        C['pelvis_z_cm'].append(WP[IDX['pelvis'], 2] * 100)
        y, p, r = angles(pq)
        C['pelvis_yaw'].append(y); C['pelvis_pitch'].append(p); C['pelvis_roll'].append(r)
        y, p, r = angles(qmul(qconj(pq), cq))
        C['chest_rel_yaw'].append(y); C['chest_rel_pitch'].append(p); C['chest_rel_roll'].append(r)
        y, p, r = angles(hq)
        C['head_yaw'].append(y); C['head_pitch'].append(p); C['head_roll'].append(r)
        C['head_y_cm'].append(WP[IDX['head'], 1] * 100)
        y, p, r = angles(WQ[IDX['weapon']])
        C['weapon_pitch'].append(p)
        C['weapon_y_cm'].append(WP[IDX['weapon'], 1] * 100)
        a, b, c = WP[IDX['thigh_L']], WP[IDX['shin_L']], WP[IDX['foot_L']]
        u, v = b - a, c - b
        C['knee_L'].append(np.degrees(np.arccos(np.clip(np.dot(u, v) / np.linalg.norm(u) / np.linalg.norm(v), -1, 1))))
        s1 = qrotate(WQ[IDX['spine1']], (0, 1.0, 0))
        s3 = qrotate(cq, (0, 1.0, 0))
        C['spine_bend'].append(np.degrees(np.arccos(np.clip(np.dot(s1, s3), -1, 1))))
    return {k: np.array(v) for k, v in C.items()}


def harmonic_purity(x, k=2):
    """Share of the variance in the first k harmonics of the loop (1.0 = a pure sum of sines)."""
    x = x - x.mean()
    F = np.abs(np.fft.rfft(x)) ** 2
    if F[1:].sum() < 1e-12:
        return None
    return float(F[1:k + 1].sum() / F[1:].sum())


def lag(a, b):
    """Phase lag of b behind a in % of the loop (circular cross-correlation peak)."""
    a = a - a.mean()
    b = b - b.mean()
    if a.std() < 1e-6 or b.std() < 1e-6:
        return None
    n = len(a)
    cc = [np.dot(a, np.roll(b, -s)) for s in range(n)]
    s = int(np.argmax(np.abs(cc)))
    sign = 1 if cc[s] > 0 else -1
    return round(100.0 * (s if s <= n // 2 else s - n) / n, 1), sign


def summarize(name, rows, loop):
    C = channels(rows)
    o = dict(frames=len(rows))
    for k, v in C.items():
        o[k + '_range'] = round(float(v.max() - v.min()), 2)
    if loop:
        o['purity'] = {k: (round(harmonic_purity(C[k]), 3) if harmonic_purity(C[k]) is not None else None)
                       for k in ('pelvis_y_cm', 'pelvis_yaw', 'pelvis_roll', 'chest_rel_yaw', 'head_pitch', 'head_yaw')}
        o['lag_pct'] = {'chest_rel_yaw_vs_pelvis_yaw': lag(C['pelvis_yaw'], C['chest_rel_yaw']),
                        'head_pitch_vs_pelvis_y': lag(C['pelvis_y_cm'], C['head_pitch']),
                        'weapon_y_vs_pelvis_y': lag(C['pelvis_y_cm'], C['weapon_y_cm'])}
    else:
        pk = {}
        for k in ('pelvis_y_cm', 'pelvis_pitch', 'chest_rel_pitch', 'head_pitch', 'weapon_pitch', 'chest_rel_roll'):
            v = C[k] - C[k][0]
            if np.abs(v).max() > 0.2:
                pk[k] = int(np.argmax(np.abs(v)))
        o['peak_frame'] = pk
    return o


def report(res, cls):
    D = ihv.read(os.path.join(res, f'marine_{cls}.ihv'))
    T = D['tracks']
    out = {}
    for c in D['clips']:
        if c['name'] in CLIPS:
            out[c['name']] = summarize(c['name'], T[c['first']:c['first'] + c['frames']], c['loop'])
    return out


def main():
    a = [x for x in sys.argv[1:] if not x.startswith('--')]
    cls = sys.argv[sys.argv.index('--cls') + 1] if '--cls' in sys.argv else 'assault'
    a = [x for x in a if x != cls]
    R = {'before': report(a[0], cls), 'after': report(a[1], cls)}
    if len(a) > 2:
        json.dump(R, open(a[2], 'w'), indent=1)
    print('%-8s %-8s %7s %7s %7s %7s %7s %7s %7s' % ('', 'clip', 'headP', 'headY', 'wpnBob', 'spine', 'pelvY', 'purity', 'lag%'))
    for tag, rr in R.items():
        for k, v in rr.items():
            pur = (v.get('purity') or {}).get('pelvis_yaw')
            lg = (v.get('lag_pct') or {}).get('chest_rel_yaw_vs_pelvis_yaw')
            print('%-8s %-8s %7.2f %7.2f %7.2f %7.2f %7.2f %7s %7s' % (tag, k, v['head_pitch_range'], v['head_yaw_range'],
                  v['weapon_y_cm_range'], v['spine_bend_range'], v['pelvis_y_cm_range'], pur, lg[0] if lg else None))


if __name__ == '__main__':
    main()
