"""Boomer («Взрывун») — a short-legged gas bomb: a translucent amber sac on a small insect body.

Not a pumpkin: the sac (flags SAC + GLAND: lit from inside, pumped by the glow table) is veined and darker at its
belly, split by a dark armoured keel of small spiked plates along the spine and rib plates low on the flanks, so the
silhouette stays an insect carrying a sac; a small head low in front, amber eyes, six stubby legs splayed under the
weight. Instance scale 1.15 (BUG_SPECS). Clips: idle / walk / run / swell (the core's 0.8 s fuse: the sac swells and
shudders, the legs brace, the pores flare — then the core bursts it) / hit. No attack (boomers do not bite) and no
deaths (every boomer bursts: no corpse).
"""
import math

import numpy as np

from geo import Part, cone, ellipsoid, hex2rgb, smoothstep, tube
from insect import (D2R, F_GLAND, F_SAC, FPS, SIDES, SN, TWO, Leg, State, blob, bone_frame, col_ramp, eye, feet_gait,
                    feet_planted, gland, leg_parts, plate, rx, ry, rz, sc3, skeleton_legs, surface_z, tr)

NAME = 'boomer'
SCALE = 1.15
SWITCH_PX = (80.0, 16.0, 0.0)

PAL = dict(plate=0x1a1614, edge=0x4e3a2c, keel=0x2c221c, core=0x100c0b, belly=0x2a1a12, leg=0x17120f, leg_dist=0x34261c,
           joint=0x3a2c22, claw=0xc0a888, mand=0x3a2a20, mand_tip=0xd8c0a0, ant=0x1e1814, ant_tip=0x5a4430,
           gland=0xff3c7a, gland_hot=0xffc6dc, gland_red=0xe0183a, eye=0xffa030, sac=0x8a4614, sac_vein=0x1e0c04)

BODY_Z = 0.30
SAC_C = np.array([0.0, -0.12, 0.50])
SAC_R = np.array([0.30, 0.41, 0.29])


def _legs():
    out = []
    for i in range(3):
        for s in SIDES:
            yc = (0.28, 0.17, 0.05)[i]
            out.append(Leg(i, s, C=(s * 0.08, yc, BODY_Z - 0.02), H=(s * 0.13, yc, BODY_Z - 0.03),
                           F0=(s * (0.42, 0.52, 0.46)[i], (0.52, 0.14, -0.28)[i], 0.0),
                           L=(0.29, 0.37, 0.1), beta=26.0))
    return out


LEGS = _legs()


def skeleton():
    B = []

    def add(name, parent, head, tail, zhint=(0, 0, 1)):
        B.append((name, parent, bone_frame(head, tail, zhint), float(np.linalg.norm(np.subtract(tail, head)))))
    z = BODY_Z
    add('root', None, (0, 0, 0), (0, 0.25, 0))
    add('thorax', 'root', (0, 0.06, z), (0, 0.34, z))
    add('head', 'thorax', (0, 0.34, z - 0.01), (0, 0.5, z - 0.04))
    for s in SIDES:
        add(f'mand.{SN[s]}', 'head', (s * 0.03, 0.47, z - 0.07), (s * 0.03, 0.56, z - 0.1))
    add('abd.1', 'thorax', (0, 0.06, z + 0.04), tuple(SAC_C))
    add('sac', 'abd.1', tuple(SAC_C), tuple(SAC_C + [0, -0.3, 0]))
    skeleton_legs(B, LEGS)
    return B


EXTRA_SOCKETS = [('mouth', 'head', (0, 0.54, BODY_Z - 0.1), 0), ('core', 'sac', tuple(SAC_C), 0),
                 ('back', 'sac', tuple(SAC_C + [0, 0, SAC_R[2] * 0.9]), 0)]


def _sac(lod):
    nu, nv = ((20, 12), (8, 5), (8, 3))[lod]
    V, F = ellipsoid(SAC_C, SAC_R, nu, nv, rx=0.12)
    d = (V - SAC_C) / SAC_R
    a = np.arctan2(d[:, 0], d[:, 1])
    if lod == 0:
        v1 = np.abs(np.sin(a * 6 + d[:, 2] * 7 + np.sin(d[:, 1] * 13 + d[:, 0] * 5) * 0.8))
        v2 = np.abs(np.sin(np.arctan2(d[:, 2], d[:, 1]) * 5 + d[:, 0] * 9))
        vein = np.clip(1 - np.minimum(v1, v2 + 0.1) / 0.2, 0, 1)
    else:
        vein = np.zeros(len(V))
    belly = np.clip(-d[:, 2] * 0.9 + 0.1, 0, 1)
    # LOD1 / LOD2 carry no rib bands: the sac's average is darkened instead, so the LOD switch keeps its value;
    # LOD2 has no keel plates either: the keel is painted along the spine (top pole + the ring's spine vertices)
    shade = (0.0, 0.4, 0.4)[lod]
    col = col_ramp(len(V), PAL['sac'], PAL['sac_vein'], np.clip(vein * 0.85 + belly * 0.55 + shade, 0, 1))
    if lod == 2:
        keel = np.clip(d[:, 2] * 1.2 - np.abs(d[:, 0]) * 1.5, 0, 1)[:, None]
        col = col * (1 - keel * 0.9) + hex2rgb(PAL['keel']) * keel * 0.9
    return Part('sac', V, F, 'sac', PAL['sac'], glow=0.3, rough=0.22, flags=F_SAC | F_GLAND, vcolor=col, sharp_deg=180)


def build_parts(lod):
    P = []
    hi = lod == 0
    C = PAL
    z = BODY_Z
    # ---- thorax + head
    if lod < 2:
        P.append(blob('thorax.core', 'thorax', (0, 0.2, z), (0.13, 0.15, 0.1), (10, 6)[lod], (5, 3)[lod], C['belly'], C['core'], rough=0.5))
        P.append(plate('pronotum', 'thorax', (8, 3)[lod], (2, 1)[lod], C, y0=0.34, length=0.24, a=(0.11, 0.14), b=(0.1, 0.11), zc=z,
                       theta_deg=115, thick=0.012, bulge=0.06, ridge=(0.02, 0.0)[lod], flare=(0.12, 0.0)[lod]))
        P.append(blob('head', 'head', (0, 0.42, z - 0.03), (0.09, 0.09, 0.075), (10, 5)[lod], (5, 2)[lod], C['plate'], C['core'], rough=0.4))
    else:
        P.append(blob('thorax.core', 'thorax', (0, 0.24, z), (0.14, 0.2, 0.11), 4, 1, C['plate'], C['core'], rough=0.4))
    for s in SIDES:
        path = [(s * 0.03, 0.47, z - 0.07), (s * 0.04, 0.52, z - 0.1), (s * 0.01, 0.57, z - 0.12)]
        if hi:
            P.append(Part(f'mand.{SN[s]}', *tube(path, [0.02, 0.014, 0.0], 4, tip=True), f'mand.{SN[s]}', C['mand_tip'], rough=0.3))
            for k, (dx, dy, dz, r) in enumerate(((0.06, 0.47, 0.0, 0.018), (0.075, 0.43, 0.02, 0.013))):
                P.append(eye(f'eye.{SN[s]}{k}', 'head', (s * dx, dy, z + dz - 0.02), r, C, glow=0.95))
        elif lod == 1:
            P.append(Part(f'mand.{SN[s]}', *cone(path[0], path[2], 0.02, 3), f'mand.{SN[s]}', C['mand_tip'], rough=0.3, sharp_deg=180))
            P.append(eye(f'eye.{SN[s]}', 'head', (s * 0.065, 0.46, z - 0.01), 0.018, C, glow=0.95))
    # ---- the sac, its keel and flank ribs
    P.append(_sac(lod))
    keel = []
    if lod < 2:
        nk = (6, 3)[lod]
        for k in range(nk):
            ang = (k - (nk - 1) / 2) * (0.34 if hi else 0.62)
            # a small plate seated on the sac's spine (y, z on the sac ellipse at angle ang from the top)
            yc = SAC_C[1] + math.sin(ang) * SAC_R[1] * 1.02
            zc = SAC_C[2] + math.cos(ang) * SAC_R[2] * 1.02
            kp = plate(f'keel{k}', 'sac', (6, 3)[lod], 1, C, y0=yc + 0.07, length=0.13 if hi else 0.22, a=(0.15, 0.13), b=(0.07, 0.06),
                       zc=zc - 0.055, theta_deg=124, thick=0.012, bulge=0.0, ridge=(0.014, 0.0)[lod], flare=(0.08, 0.0)[lod])
            keel.append(kp)
            if hi:
                b = np.array([0, yc, zc + 0.02])
                P.append(Part(f'kspike{k}', *cone(b, b + [0, -0.03, 0.06], 0.012, 4), 'sac', C['edge'], rough=0.3))
        P.extend(keel)
        if hi:
            # flank ribs: two dark bands hooping the sac's lower half (the sac glows between them)
            for k in range(2):
                yy = SAC_C[1] + (0.16 if k == 0 else -0.14)
                P.append(plate(f'rib{k}', 'sac', 12, 1, dict(C, plate=C['plate'], edge=C['edge']), y0=yy + 0.035, length=0.07,
                               a=(SAC_R[0] * 1.03, SAC_R[0] * 1.03), b=(SAC_R[2] * 1.03, SAC_R[2] * 1.03), zc=SAC_C[2],
                               theta_deg=230, thick=0.012, bulge=0.0, ridge=0.0, flare=0.0))
    # ---- pores: on the keel plates and across the top of the sac
    if lod < 2:
        seat = keel + [p for p in P if p.name == 'sac']
        pores = [(0.0, -0.08, 0.02, True), (0.06, 0.08, 0.016, True), (-0.05, -0.24, 0.018, True), (0.16, -0.02, 0.016, True),
                 (-0.18, 0.06, 0.017, True), (0.14, -0.30, 0.015, True), (-0.12, -0.40, 0.014, False), (0.22, -0.18, 0.013, False)]
        for k, (x, y, r, hot) in enumerate(pores):
            if not hi and not hot:
                continue
            zz = surface_z(seat, x, y) - 0.2 * r
            P.append(gland(f'gland.{k}', 'sac', (x, y, zz), r, C, hot=hot, red=not hot, glow=1.0 if hot else 0.7, glint=hot,
                           intensity=1.0 if hot else 0.6))
    for lg in LEGS:
        P.extend(leg_parts(lg, lod, C, thick=1.15))
    return P


# ------------------------------------------------------------------ animation
GROUND_CLAMP = {'hit', 'swell'}
CLIPS = [
    ('idle', 30, True, 0.0, 0, 'the sac heaves, the head bobs; feet planted'),
    ('walk', 20, True, 0.60, 0, 'short stubby tripod gait, duty 0.62, the sac wobbles behind'),
    ('run', 16, True, 1.0, 0, 'scuttle, duty 0.45, the sac bounces'),
    ('swell', 24, False, 0.0, 23, 'the 0.8 s fuse: the sac swells to 1.32 and shudders, legs brace outward, pores flare'),
    ('hit', 10, False, 0.0, 1, 'recoil, the sac wobbles'),
]


def _sac_scale(st, sx, sy=None, sz=None):
    st.set('sac', sc3(sx, sy if sy is not None else sx, sz if sz is not None else sx))


def clip_state(name, f, n):
    st = State()
    tau = f / n if name in ('idle', 'walk', 'run') else f / (n - 1)
    if name == 'idle':
        w = TWO * tau
        st.set('thorax', tr(0, 0, 0.006 * math.sin(w)) @ rz(3 * D2R * math.sin(w)))
        st.set('head', rx(5 * D2R * math.sin(2 * w)) @ rz(6 * D2R * math.sin(w + 0.8)))
        st.set('abd.1', rx(-2 * D2R * math.sin(w - 0.6)))
        _sac_scale(st, 1.0 + 0.03 * math.sin(w), 1.0 + 0.02 * math.sin(w + 0.6), 1.0 + 0.035 * math.sin(w))
        feet_planted(st, LEGS)
        st.glow.update(gland=0.85, pulse=0.25, wave=tau)
    elif name in ('walk', 'run'):
        run = name == 'run'
        w = TWO * tau
        duty, D, h = (0.45, 1.0, 0.1) if run else (0.62, 0.60, 0.07)
        zb = -(0.02 if run else 0.012) * math.cos(2 * w)
        st.set('thorax', tr(0, 0, zb) @ rz(4 * D2R * math.sin(w + 0.4)) @ ry(4 * D2R * math.sin(w)))
        st.set('head', rx(-2 * D2R * math.sin(2 * w + 1.4)))
        st.set('abd.1', rz(-5 * D2R * math.sin(w - 0.8)) @ rx(3 * D2R * math.sin(2 * w - 0.6)))
        wob = (0.04 if run else 0.025) * math.sin(2 * w - 1.6)
        _sac_scale(st, 1.0 - wob * 0.5, 1.0 + wob, 1.0 - wob * 0.6)
        feet_gait(st, LEGS, tau, duty, D, h)
        st.glow.update(gland=0.9, pulse=0.2, wave=2 * tau)
    elif name == 'swell':
        p = smoothstep(0.0, 1.0, tau)
        sh = math.sin(f * 2.7) * 0.03 * p + math.sin(f * 4.1) * 0.015 * p
        _sac_scale(st, 1.0 + 0.32 * p + sh, 1.0 + 0.26 * p - sh, 1.0 + 0.3 * p + sh * 0.5)
        st.set('thorax', tr(0, 0, -0.03 * p) @ rx(-6 * p * D2R) @ rz(3 * D2R * math.sin(f * 3.3) * p))
        st.set('head', rx(14 * p * D2R))
        st.set('abd.1', rx(-4 * p * D2R))
        for lg in LEGS:
            st.feet[lg.name] = ('ik', lg.F0 + np.array([lg.s * 0.07, (0.05 if lg.i == 0 else -0.04 if lg.i == 2 else 0), 0]) * p)
        st.glow.update(gland=1.0 + 2.6 * p, pulse=0.5 * p, wave=tau * 6)
    elif name == 'hit':
        k = [0, 1.0, 0.86, 0.58, 0.28, 0.06, -0.1, -0.08, -0.03, 0.0][f]
        st.set('thorax', tr(0, -0.05 * k, 0.02 * k) @ rx(8 * k * D2R) @ ry(10 * k * D2R))
        st.set('head', rx(12 * k * D2R))
        st.set('abd.1', rx(8 * k * D2R))
        _sac_scale(st, 1.0 + 0.07 * k * math.cos(f * 2.4), 1.0 - 0.05 * k * math.cos(f * 2.4), 1.0 + 0.06 * k * math.cos(f * 2.4))
        feet_planted(st, LEGS, lambda lg: np.array([lg.s * 0.04, 0.0, 0.0]) * max(k, 0))
        st.glow.update(gland=1.0 + 1.6 * max(k, 0))
    return st
