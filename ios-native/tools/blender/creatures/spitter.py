"""Spitter («Плевун») — a high-legged acid spitter with a caged lantern sac (frost's silhouette, kept modest).

Six long spidery legs carry the body high; the abdomen ends in a translucent acid sac (chartreuse, flags SAC + GLAND so
the glow table pumps it) caged by dark rib plates with pink-white pores; a long jointed proboscis (bone `prob`) aims
the spit. Instance scale 1.02 (BUG_SPECS). Clips: idle / walk / run / attack (rear and jab) / hit / spit (the core's
0.5 s wind-up: rear, pump, release, recoil) / death (the sac bursts, the body slumps) / death2 (flips over).
"""
import math

import numpy as np

from geo import Part, cone, ellipsoid, shell_plate, smoothstep, tube
from insect import (D2R, F_GLAND, F_SAC, FPS, SIDES, SN, TWO, Leg, State, bell, blob, bone_frame, col_ramp, eye, feet_gait,
                    feet_planted, gland, leg_parts, plate, roll_lift, rx, ry, rz, sc3, skeleton_legs, surface_z, tr)

NAME = 'spitter'
SCALE = 1.02
SWITCH_PX = (80.0, 16.0, 0.0)

PAL = dict(plate=0x1c2224, edge=0x4a5a3c, keel=0x2a3326, core=0x111515, belly=0x233024, leg=0x161a1b, leg_dist=0x2c3a26,
           joint=0x34402c, claw=0xb8c098, mand=0x3a4a2a, mand_tip=0xd8e0b0, ant=0x1c2220, ant_tip=0x56683a,
           gland=0xff3c7a, gland_hot=0xffc6dc, gland_red=0xe0183a, eye=0xc8ff40, sac=0x6f8c1c, sac_vein=0x1a2408, rib=0x161c1c)

BODY_Z = 0.50


def _legs():
    out = []
    for i in range(3):
        for s in SIDES:
            yc = (0.20, 0.08, -0.06)[i]
            out.append(Leg(i, s, C=(s * 0.09, yc, BODY_Z - 0.04), H=(s * 0.15, yc + (0.04, 0.0, -0.04)[i], BODY_Z - 0.02),
                           F0=(s * (0.56, 0.74, 0.62)[i], (0.66, 0.12, -0.52)[i], 0.0),
                           L=((0.42, 0.46, 0.44)[i], (0.56, 0.60, 0.58)[i], (0.17, 0.18, 0.18)[i]), beta=22.0))
    return out


LEGS = _legs()
SAC_C = np.array([0.0, -0.46, 0.74])
SAC_R = np.array([0.21, 0.26, 0.20])


def skeleton():
    B = []

    def add(name, parent, head, tail, zhint=(0, 0, 1)):
        B.append((name, parent, bone_frame(head, tail, zhint), float(np.linalg.norm(np.subtract(tail, head)))))
    z = BODY_Z
    add('root', None, (0, 0, 0), (0, 0.25, 0))
    add('thorax', 'root', (0, -0.06, z), (0, 0.24, z))
    add('head', 'thorax', (0, 0.24, z + 0.02), (0, 0.40, z + 0.02))
    add('prob', 'head', (0, 0.42, z - 0.02), (0, 0.66, z - 0.12))
    for s in SIDES:
        add(f'mand.{SN[s]}', 'head', (s * 0.04, 0.40, z - 0.05), (s * 0.05, 0.50, z - 0.07))
    add('abd.1', 'thorax', (0, -0.08, z + 0.02), (0, -0.30, z + 0.12))
    add('abd.2', 'abd.1', (0, -0.30, z + 0.12), tuple(SAC_C + [0, -0.12, 0.02]))
    add('sac', 'abd.2', tuple(SAC_C), tuple(SAC_C + [0, -0.2, 0]))
    skeleton_legs(B, LEGS)
    return B


EXTRA_SOCKETS = [('mouth', 'prob', (0, 0.68, BODY_Z - 0.13), 0), ('core', 'thorax', (0, 0.06, BODY_Z + 0.06), 0),
                 ('sac', 'sac', tuple(SAC_C + [0, 0, 0.05]), 0), ('back', 'abd.1', (0, -0.22, BODY_Z + 0.16), 0)]


def _sac(lod):
    nu, nv = ((18, 10), (8, 4), (7, 2))[lod]
    V, F = ellipsoid(SAC_C, SAC_R, nu, nv, rx=0.25)
    d = V - SAC_C
    # veins: dark bands where two sine fields cross; the middle stays bright (the lantern), the belly darker
    a = np.arctan2(d[:, 0], d[:, 1])
    v1 = np.abs(np.sin(a * 5 + d[:, 2] * 18 + np.sin(d[:, 1] * 22) * 0.7))
    vein = np.clip(1 - v1 / 0.22, 0, 1) if lod == 0 else np.zeros(len(V))
    # LOD1 / LOD2 lose the veins and (some of) the rib cage: their sac is darkened on average so a LOD switch keeps its value
    shade = (0.0, 0.25, 0.25)[lod]
    col = col_ramp(len(V), PAL['sac'], PAL['sac_vein'], np.clip(vein * 0.85 + np.clip(-d[:, 2] / SAC_R[2], 0, 1) * 0.4 + shade, 0, 1))
    return Part('sac', V, F, 'sac', PAL['sac'], glow=0.25, rough=0.25, flags=F_SAC | F_GLAND, vcolor=col, sharp_deg=180)


def _ribs(lod):
    """dark rib plates arching over the sac (the cage of the lantern)"""
    P = []
    n = (4, 2, 0)[lod]
    for k in range(n):
        t = (k + 0.5) / n
        y0 = SAC_C[1] + SAC_R[1] * (0.85 - 1.7 * t) + 0.04
        a = SAC_R[0] * (1.05 + 0.18 * math.sin(math.pi * t))
        b = SAC_R[2] * (1.04 + 0.12 * math.sin(math.pi * t))
        P.append(plate(f'rib{k}', 'sac', (8, 3)[lod], 1, dict(PAL, plate=PAL['rib'], core=PAL['rib']), y0=y0,
                       length=(0.07, 0.16)[lod], a=(a, a), b=(b, b), zc=SAC_C[2] - 0.02, theta_deg=(135, 120)[lod],
                       thick=0.012, bulge=0.0, ridge=(0.016, 0.0)[lod], flare=0.0))
    return P


def build_parts(lod):
    P = []
    hi = lod == 0
    C = PAL
    z = BODY_Z
    # ---- thorax: core + two plates (LOD2: one blob)
    if lod < 2:
        P.append(blob('thorax.core', 'thorax', (0, 0.09, z), (0.13, 0.18, 0.10), (10, 6)[lod], (5, 3)[lod], C['belly'], C['core'], rough=0.5))
        P.append(plate('pronotum', 'thorax', (8, 3)[lod], (3, 1)[lod], C, y0=0.27, length=(0.17, 0.36)[lod], a=(0.11, 0.15), b=(0.10, 0.115),
                       zc=z, theta_deg=110, thick=0.013, bulge=0.07, ridge=(0.026, 0.0)[lod], flare=(0.14, 0.0)[lod], serr=(0.025, 0.0)[lod]))
        if hi:
            P.append(plate('mesonotum', 'thorax', 8, 2, C, y0=0.10, length=0.18, a=(0.14, 0.13), b=(0.11, 0.10), zc=z, theta_deg=110,
                           thick=0.012, bulge=0.06, ridge=0.022, flare=0.1, serr=0.02))
            for k in range(3):
                b = np.array([0, 0.18 - k * 0.1, z + 0.12])
                P.append(Part(f'spine{k}', *cone(b, b + [0, -0.05, 0.07], 0.014, 4), 'thorax', C['keel'], rough=0.3))
    else:
        P.append(blob('thorax.core', 'thorax', (0, 0.09, z + 0.01), (0.15, 0.2, 0.12), 4, 1, C['plate'], C['core'], rough=0.4))
    # ---- head + proboscis + small mandibles
    hc = (0, 0.34, z + 0.01)
    if lod < 2:
        P.append(blob('head', 'head', hc, (0.085, 0.1, 0.075), (10, 5)[lod], (5, 2)[lod], C['plate'], C['core'], rough=0.4))
    else:
        P.append(blob('head', 'head', hc, (0.09, 0.11, 0.08), 4, 1, C['plate'], C['core'], rough=0.4))
    path = [(0, 0.41, z - 0.02), (0, 0.50, z - 0.06), (0, 0.59, z - 0.10), (0, 0.67, z - 0.13)]
    if hi:
        V, F = tube(path, [0.034, 0.03, 0.024, 0.0], 6, tip=True)
        P.append(Part('prob', V, F, 'prob', C['mand'], rough=0.3, vcolor=col_ramp(len(V), C['mand'], C['mand_tip'], np.linspace(0, 1, len(V)) ** 2)))
        for k in range(3):    # segment rings
            q = np.array(path[0]) * (1 - (k + 1) / 4) + np.array(path[3]) * ((k + 1) / 4)
            P.append(Part(f'prob.ring{k}', *tube([q - [0, 0.012, -0.005], q + [0, 0.012, -0.005]], [0.04 - k * 0.006] * 2, 6), 'prob', C['edge'], rough=0.3))
        P.append(gland('gland.tip', 'prob', (0, 0.665, z - 0.125), 0.016, C, glow=1.0, glint=True, intensity=1.2))
        for s in SIDES:
            for k, (dx, dy, dz, r) in enumerate(((0.07, 0.38, 0.05, 0.016), (0.085, 0.35, 0.02, 0.012), (0.06, 0.36, 0.075, 0.011))):
                P.append(eye(f'eye.{SN[s]}{k}', 'head', (s * dx, dy, z + dz - 0.02), r, C, glow=0.9))
            P.append(Part(f'mand.{SN[s]}', *tube([(s * 0.04, 0.40, z - 0.05), (s * 0.06, 0.45, z - 0.07), (s * 0.03, 0.5, z - 0.08)],
                                                 [0.014, 0.01, 0.0], 4, tip=True), f'mand.{SN[s]}', C['mand_tip'], rough=0.3))
            # antennae: short, swept back over the head (one bone each: the head's)
            P.append(Part(f'ant.{SN[s]}', *tube([(s * 0.03, 0.40, z + 0.06), (s * 0.12, 0.42, z + 0.2), (s * 0.2, 0.36, z + 0.27)],
                                                [0.01, 0.007, 0.0], 4, tip=True), 'head', C['ant'], rough=0.45,
                          vcolor=None))
    elif lod == 1:
        V, F = tube([path[0], path[3]], [0.032, 0.0], 4, tip=True)
        P.append(Part('prob', V, F, 'prob', C['mand'], rough=0.3, sharp_deg=180))
        for s in SIDES:
            P.append(eye(f'eye.{SN[s]}', 'head', (s * 0.075, 0.37, z + 0.03), 0.016, C, glow=0.9))
    else:
        P.append(Part('prob', *cone(path[0], path[3], 0.03, 3), 'prob', C['mand'], rough=0.3, sharp_deg=180))
    # ---- abdomen: a slim stalk rising to the sac
    if lod < 2:
        P.append(blob('abd', 'abd.1', (0, -0.2, z + 0.08), (0.1, 0.16, 0.09), (8, 4)[lod], (4, 2)[lod], C['plate'], C['belly'], rough=0.45, rxa=-0.35))
        if hi:
            P.append(plate('tergite', 'abd.1', 6, 2, C, y0=-0.07, length=0.24, a=(0.1, 0.09), b=(0.09, 0.08), zc=z + 0.07, theta_deg=120,
                           thick=0.01, bulge=0.05, ridge=0.02, flare=0.08, serr=0.02, lift=0.08))
    else:
        P.append(blob('abd', 'abd.1', (0, -0.2, z + 0.08), (0.1, 0.17, 0.09), 4, 1, C['plate'], C['belly'], rough=0.45, rxa=-0.35))
    P.append(_sac(lod))
    ribs = _ribs(lod)
    P.extend(ribs)
    # ---- pores: on the ribs and the plates (asymmetric), seated on this LOD's surface
    if lod < 2:
        seat = ribs + [p for p in P if p.name in ('pronotum', 'mesonotum', 'sac')]
        pores = [(-0.06, -0.30, 0.016, True), (0.09, -0.37, 0.014, True), (-0.11, -0.46, 0.018, True), (0.04, -0.52, 0.015, True),
                 (0.12, -0.58, 0.012, True), (-0.03, -0.63, 0.013, True), (0.05, 0.20, 0.014, True), (-0.07, 0.12, 0.012, False)]
        for k, (x, y, r, hot) in enumerate(pores):
            if not hi and not hot:
                continue
            bone = 'sac' if y < -0.25 else 'thorax'
            zz = surface_z(seat, x, y) - 0.2 * r
            P.append(gland(f'gland.{k}', bone, (x, y, zz), r, C, hot=hot, red=not hot, glow=1.0 if hot else 0.7, glint=hot,
                           intensity=1.0 if hot else 0.6))
    # ---- legs
    for lg in LEGS:
        P.extend(leg_parts(lg, lod, C, thick=1.05))
    return P


# ------------------------------------------------------------------ animation
GROUND_CLAMP = {'death', 'death2', 'hit', 'spit', 'attack'}
CLIPS = [
    ('idle', 30, True, 0.0, 0, 'sway on the long legs, sac breathes, proboscis tastes the air; feet planted'),
    ('walk', 24, True, 1.10, 0, 'tripod gait on stilts, duty 0.62, body sways, sac bobs behind'),
    ('run', 18, True, 1.90, 0, 'tripod gait, duty 0.45, body lowered, sac swinging'),
    ('attack', 16, False, 0.0, 9, 'rears, front legs up, stabs down with the proboscis on the event frame'),
    ('hit', 10, False, 0.0, 1, 'recoil, sac quivers, legs splay'),
    ('spit', 16, False, 0.0, 12, 'the 0.5 s wind-up: rear back, sac pumps, the proboscis aims, release on frame 12, recoil'),
    ('death', 30, False, 0.0, 29, 'the sac bursts and deflates, the body slumps sideways, legs curl over it, a kick'),
    ('death2', 30, False, 0.0, 29, 'flips onto its back, the long legs fold up and twitch, the sac dims'),
]


def _sac_scale(st, s):
    st.set('sac', sc3(s, s, s))


def _death_burst(st, f):
    k = [0, 1.0, 0.8, 0.55][f] if f < 4 else 0.0
    burst = smoothstep(1, 5, f)
    drop = smoothstep(3, 12, f)
    roll = smoothstep(6, 16, f)
    tw = bell(f, 20, 1.4) + 0.6 * bell(f, 25, 1.2)
    st.set('root', tr(0.02 * roll, 0.05 * drop, -0.36 * drop) @ rz(-12 * D2R * drop) @ ry(5 * D2R * roll))
    st.set('thorax', tr(0, -0.04 * k, 0.03 * k) @ rx((10 * k - 3 * drop) * D2R))
    st.set('head', rx((18 * k + 12 * drop) * D2R))
    st.set('prob', rx((20 * drop - 15 * tw) * D2R))
    st.set('abd.1', rx((12 * k - 12 * drop) * D2R))
    st.set('abd.2', rx((-10 * drop) * D2R) @ rz(8 * tw * D2R))
    _sac_scale(st, 1.0 + 0.18 * k - 0.42 * burst)
    for s in SIDES:
        st.set(f'mand.{SN[s]}', rz(-s * (20 * k + 25 * drop) * D2R))
    buckle = smoothstep(2, 10, f)
    for lg in LEGS:
        kick = tw * (1.0 if (lg.i + (lg.s > 0)) % 2 else 0.3)
        jitter = np.array([0.0, 0.3 * kick, -0.5 * kick, 0.6 * kick])
        st.feet[lg.name] = ('mix', lg.F0 + np.array([lg.s * 0.06, 0, 0]) * k, lg.splay_params(14, -2, -14) + jitter, buckle)
    fade = 1 - smoothstep(2, 22, f)
    st.glow.update(gland=max(0.05, (1.0 + 2.5 * bell(f, 2, 1.2)) * (0.06 + 0.94 * fade)), eye=max(0.05, 1 - smoothstep(2, 16, f)))


def _death_flip(st, f):
    k = [0, 1.0, 0.85, 0.6][f] if f < 4 else 0.0
    flip = smoothstep(3, 13, f)
    hop = math.sin(math.pi * min(max((f - 3) / 10, 0), 1))
    rho = math.pi * flip * 0.96
    lift = roll_lift(rho, BODY_Z * 0.55, 0.2, 0.18, flip) + 0.08 * hop
    st.set('root', tr(-0.3 * math.sin(rho), -0.04 * flip, lift - 0.25 * flip) @ ry(rho))
    tw = sum(a * bell(f, t0, 1.5) for t0, a in ((17, 1.0), (23, 0.6)))
    st.set('thorax', tr(0, -0.05 * k, 0.02 * k) @ rx(10 * k * D2R) @ ry(-8 * tw * D2R))
    st.set('head', rx((14 * k - 20 * flip) * D2R))
    st.set('prob', rx((-15 * flip + 12 * tw) * D2R))
    st.set('abd.1', rx((-10 * flip + 6 * tw) * D2R))
    st.set('abd.2', rx((-14 * flip) * D2R))
    _sac_scale(st, 1.0 - 0.15 * flip)
    tuck = smoothstep(1.5, 6, f)
    curl = smoothstep(10, 18, f)
    flail = math.sin(math.pi * min(max((f - 3) / 14, 0), 1)) * (0.35 + 0.65 * curl)
    for lg in LEGS:
        seed = lg.i * 1.7 + (lg.s + 1) * 2.3
        twl = tw * (0.6 + 0.4 * math.sin(seed * 3.1))
        jitter = np.array([0.0, 0.5 * flail * math.sin(f * 1.9 + seed) + 0.45 * twl,
                           0.8 * flail * math.sin(f * 2.3 + seed * 1.3) - 0.7 * twl, 0.6 * flail * math.sin(f * 2.9 + seed) + 0.9 * twl])
        st.feet[lg.name] = ('mix2', lg.F0 + np.array([lg.s * 0.05, 0, 0]) * k, lg.tuck_params() + jitter * 0.5, tuck, lg.dead_params() + jitter, curl)
    fade = 1 - smoothstep(4, 26, f)
    st.glow.update(gland=max(0.05, (1.0 + 1.5 * k) * (0.08 + 0.92 * fade) + 0.8 * bell(f, 17, 0.8) * fade), eye=max(0.05, 1 - smoothstep(2, 18, f)))


def clip_state(name, f, n):
    st = State()
    tau = f / n if name in ('idle', 'walk', 'run') else f / (n - 1)
    if name == 'idle':
        w = TWO * tau
        st.set('thorax', tr(0, 0, 0.01 * math.sin(w)) @ rz(4 * D2R * math.sin(w)) @ ry(3 * D2R * math.sin(w + 0.5)))
        st.set('head', rz(9 * D2R * math.sin(w + 0.8)) @ rx(5 * D2R * math.sin(2 * w)))
        st.set('prob', rx(8 * D2R * math.sin(2 * w + 0.4)) @ rz(6 * D2R * math.sin(w + 1.3)))
        st.set('abd.1', rx(-3 * D2R * math.sin(w - 0.6)))
        st.set('abd.2', rx(-4 * D2R * math.sin(w - 1.1)) @ rz(4 * D2R * math.sin(w)))
        _sac_scale(st, 1.0 + 0.035 * math.sin(w))
        for s in SIDES:
            st.set(f'mand.{SN[s]}', rz(-s * (8 + 10 * max(0, math.sin(2 * w)) ** 2) * D2R))
        feet_planted(st, LEGS)
        st.glow.update(gland=0.85, pulse=0.25, wave=tau)
    elif name in ('walk', 'run'):
        run = name == 'run'
        w = TWO * tau
        duty, D, h = (0.45, 1.90, 0.17) if run else (0.62, 1.10, 0.12)
        zb = -(0.025 if run else 0.015) * math.cos(2 * w) + (-0.06 if run else 0.0)
        st.set('thorax', tr(0, 0, zb) @ rz((3 if run else 5) * D2R * math.sin(w + 0.4)) @ rx(((-7 if run else 0) + 1.5 * math.sin(2 * w + 0.6)) * D2R)
               @ ry((6 if run else 5) * D2R * math.sin(w)))
        st.set('head', rz(-3 * D2R * math.sin(w + 0.4)) @ rx(((5 if run else 0) - 2 * math.sin(2 * w + 1.4)) * D2R))
        st.set('prob', rx(((10 if run else 4) + 3 * math.sin(2 * w)) * D2R))
        st.set('abd.1', rz(-(5 if run else 4) * D2R * math.sin(w - 0.5)) @ rx(((4 if run else 0) + 2 * math.sin(2 * w - 0.2)) * D2R))
        st.set('abd.2', rz(-(9 if run else 6) * D2R * math.sin(w - 1.3)) @ rx(3.0 * D2R * math.sin(2 * w - 1.0)))
        _sac_scale(st, 1.0 + 0.03 * math.sin(2 * w - 1.5))
        for s in SIDES:
            st.set(f'mand.{SN[s]}', rz(-s * 6 * D2R * (0.5 + 0.5 * math.sin(2 * w))))
        feet_gait(st, LEGS, tau, duty, D, h, fb=0.05 if run else 0.0)
        st.glow.update(gland=0.9, pulse=0.2, wave=2 * tau)
    elif name == 'attack':
        t = tau
        up = smoothstep(0.0, 0.4, t) * (1 - smoothstep(0.5, 0.62, t))
        stab = smoothstep(0.48, 0.6, t) * (1 - smoothstep(0.66, 1.0, t))
        st.set('root', tr(0, -0.05 * up + 0.22 * stab, 0))
        st.set('thorax', tr(0, 0, 0.08 * up - 0.06 * stab) @ rx((28 * up - 18 * stab) * D2R))
        st.set('head', rx((10 * up - 14 * stab) * D2R))
        st.set('prob', rx((-30 * up + 40 * stab) * D2R))
        st.set('abd.1', rx((14 * up) * D2R))
        st.set('abd.2', rx((10 * up) * D2R))
        for s in SIDES:
            st.set(f'mand.{SN[s]}', rz(-s * 28 * up * D2R))
        for lg in LEGS:
            if lg.i == 0:
                st.feet[lg.name] = ('ik', lg.F0 + np.array([lg.s * -0.08, 0.1, 0.42]) * up + np.array([0, 0.2, 0.0]) * stab)
            else:
                st.feet[lg.name] = ('ik', lg.F0)
        st.glow.update(gland=1.0 + 0.8 * up + 0.8 * stab)
    elif name == 'hit':
        k = [0, 1.0, 0.86, 0.58, 0.28, 0.06, -0.1, -0.08, -0.03, 0.0][f]
        st.set('thorax', tr(0, -0.06 * k, 0.03 * k) @ rx(10 * k * D2R) @ ry(12 * k * D2R))
        st.set('head', rx(14 * k * D2R) @ rz(-7 * k * D2R))
        st.set('prob', rx(-18 * k * D2R))
        st.set('abd.1', rx(10 * k * D2R) @ rz(-6 * k * D2R))
        st.set('abd.2', rx(10 * k * D2R) @ rz(-9 * k * D2R))
        _sac_scale(st, 1.0 + 0.08 * k * math.cos(f * 2.2))
        feet_planted(st, LEGS, lambda lg: np.array([lg.s * 0.06, 0.0, 0.0]) * max(k, 0))
        st.glow.update(gland=1.0 + 1.6 * max(k, 0))
    elif name == 'spit':
        t = tau
        rear = smoothstep(0.0, 0.55, t) * (1 - smoothstep(0.82, 1.0, t) * 0.6)
        pump = smoothstep(0.3, 0.75, t) * (1 - smoothstep(0.75, 0.82, t))
        rel = smoothstep(0.74, 0.8, t)
        rec = rel * (1 - smoothstep(0.85, 1.0, t))
        st.set('root', tr(0, -0.08 * rear - 0.08 * rec, 0))
        st.set('thorax', tr(0, 0, 0.1 * rear) @ rx((24 * rear - 8 * rec) * D2R))
        st.set('head', rx((8 * rear + 6 * rec) * D2R))
        st.set('prob', rx((-26 * rear + 18 * rec) * D2R))
        st.set('abd.1', rx((-12 * rear + 10 * pump) * D2R))
        st.set('abd.2', rx((-16 * rear + 8 * pump) * D2R))
        _sac_scale(st, 1.0 + 0.2 * pump + 0.04 * math.sin(f * 2.5) * pump - 0.12 * rec)
        for s in SIDES:
            st.set(f'mand.{SN[s]}', rz(-s * (10 + 30 * rel * (1 - rec)) * D2R))
        for lg in LEGS:
            brace = np.array([lg.s * 0.05, (0.06 if lg.i == 2 else -0.02), 0.0]) * rear
            st.feet[lg.name] = ('ik', lg.F0 + brace)
        st.glow.update(gland=1.0 + 2.2 * pump + 1.2 * rel * (1 - rec), pulse=0.3 * pump, wave=t * 4)
    elif name == 'death':
        _death_burst(st, f)
    elif name == 'death2':
        _death_flip(st, f)
    return st
