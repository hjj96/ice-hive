"""Runner bug («Бегун») — the pipeline proof creature, now with three LODs and three deaths.

Skeleton (29 bones: no coxa bones — the coxae ride on the thorax), LOD0 ≤ 3000 / LOD1 ≤ 450 / LOD2 ≤ 150 triangles,
clips idle / walk / run / attack / hit / death (flip onto the back) / death2 (crumple onto the belly) / death3 (thrown
back, spinning over). Instance scale 0.8 in game (BUG_SPECS). See insect.py for the conventions.
"""
import math

import numpy as np

from geo import Part, cone, ellipsoid, octa, smoothstep, tube
from insect import (D2R, F_EYE, FPS, SIDES, SN, TWO, Leg, State, bell, blob, bone_frame, col_ramp, eye, feet_gait,
                    feet_planted, gland, leg_parts, plate, roll_lift, rx, ry, rz, skeleton_legs, socket_flags,
                    surface_z, tr)

NAME = 'runner'
SCALE = 0.8                  # BUG_SPECS scale (game instance scale) — game_camera.py sizes the read-back with it
SWITCH_PX = (80.0, 16.0, 0.0)

PAL = dict(plate=0x261a2a, edge=0x5c3a5e, keel=0x36233e, core=0x150f17, belly=0x3d1628, leg=0x1d1520, leg_dist=0x3e2032,
           joint=0x3c2438, claw=0xa88890, mand=0x4c2236, mand_tip=0xd8b8c0, ant=0x231824, ant_tip=0x6c3a54,
           gland=0xff3c7a, gland_hot=0xffc6dc, gland_red=0xe0183a, eye=0xff5a8a)


def _legs():
    out = []
    for i in range(3):
        for s in SIDES:
            yc = (0.20, 0.10, 0.00)[i]
            out.append(Leg(i, s, C=(s * 0.085, yc, 0.235), H=(s * 0.15, yc + (0.035, 0.0, -0.035)[i], 0.255),
                           F0=(s * (0.56, 0.66, 0.62)[i], (0.58, 0.14, -0.42)[i], 0.0),
                           L=((0.34, 0.37, 0.39)[i], (0.42, 0.44, 0.48)[i], (0.15, 0.16, 0.18)[i])))
    return out


LEGS = _legs()


def skeleton():
    B = []   # (name, parent, rest 4x4, length)

    def add(name, parent, head, tail, zhint=(0, 0, 1)):
        B.append((name, parent, bone_frame(head, tail, zhint), float(np.linalg.norm(np.subtract(tail, head)))))
    add('root', None, (0, 0, 0), (0, 0.25, 0))
    add('thorax', 'root', (0, -0.03, 0.27), (0, 0.27, 0.27))
    add('head', 'thorax', (0, 0.27, 0.27), (0, 0.45, 0.27))
    for s in SIDES:
        add(f'mand.{SN[s]}', 'head', (s * 0.05, 0.45, 0.205), (s * 0.06, 0.60, 0.205))
        add(f'ant.{SN[s]}.1', 'head', (s * 0.04, 0.46, 0.31), (s * 0.13, 0.66, 0.44))
        add(f'ant.{SN[s]}.2', f'ant.{SN[s]}.1', (s * 0.13, 0.66, 0.44), (s * 0.37, 0.70, 0.37))
    add('abd.1', 'thorax', (0, -0.05, 0.29), (0, -0.40, 0.29))
    add('abd.2', 'abd.1', (0, -0.40, 0.29), (0, -0.84, 0.25))
    skeleton_legs(B, LEGS)
    return B


TERGITES = [  # y0, a (front, back), b (front, back), zc
    (-0.030, (0.200, 0.226), (0.130, 0.146), 0.282),
    (-0.185, (0.214, 0.220), (0.140, 0.140), 0.278),
    (-0.340, (0.204, 0.190), (0.134, 0.120), 0.272),
    (-0.495, (0.176, 0.146), (0.115, 0.095), 0.266),
    (-0.650, (0.134, 0.088), (0.090, 0.058), 0.260),
]
DORSAL_PORES = [            # per tergite: (u, v, radius) — hand-placed, asymmetric (a mirrored layout reads as dominoes)
    [(-0.18, 0.45, 0.016), (0.62, 0.30, 0.012)],
    [(0.28, 0.55, 0.024), (-0.62, 0.32, 0.014), (-0.22, 0.80, 0.011)],
    [(-0.38, 0.50, 0.021), (0.52, 0.68, 0.016), (0.10, 0.18, 0.011)],
    [(0.30, 0.42, 0.018), (-0.48, 0.62, 0.012)],
]
LATERAL_PORES = [(0, 1), (1, -1), (1, 1), (2, -1), (3, 1), (3, -1)]    # (tergite, side) — not mirrored
EXTRA_SOCKETS = [('mouth', 'head', (0, 0.6, 0.2), 0), ('core', 'thorax', (0, 0.05, 0.3), 0),
                 ('back', 'abd.1', (0, -0.3, 0.42), 0)]


def build_parts(lod):
    P = []
    hi = lod == 0
    C = PAL
    # ---- head
    if hi:
        V, F = ellipsoid((0, 0.36, 0.262), (0.105, 0.118, 0.085), 10, 5, squash_bottom=0.8)
        P.append(Part('head.core', V, F, 'head', C['core'], rough=0.5))
        P.append(plate('head.shield', 'head', 6, 3, C, y0=0.475, length=0.23, a=(0.07, 0.128), b=(0.06, 0.098), zc=0.27,
                       theta_deg=84, thick=0.012, bulge=0.06, ridge=0.02, flare=0.2, serr=0.03))
        for s in SIDES:
            for k, (dy, dz, r) in enumerate(((0.0, 0.0, 0.016), (-0.028, 0.012, 0.012), (-0.02, -0.018, 0.010))):
                P.append(eye(f'eye.{SN[s]}{k}', 'head', (s * 0.098, 0.425 + dy, 0.285 + dz), r, C))
            P.append(Part(f'palp.{SN[s]}', *tube([(s * 0.03, 0.45, 0.2), (s * 0.04, 0.5, 0.15), (s * 0.03, 0.53, 0.12)],
                                                  [0.012, 0.01, 0.0], 4, tip=True), 'head', C['joint'], rough=0.5))
    elif lod == 1:
        P.append(blob('head.core', 'head', (0, 0.36, 0.268), (0.11, 0.13, 0.095), 5, 2, C['plate'], C['core'], rough=0.4))
    else:
        P.append(blob('head.core', 'head', (0, 0.37, 0.27), (0.11, 0.14, 0.095), 4, 1, C['plate'], C['core'], rough=0.4))
    # ---- mandibles: sickles curving in, pale tips, inner teeth
    for s in SIDES:
        path = [(s * 0.052, 0.445, 0.206), (s * 0.092, 0.515, 0.204), (s * 0.088, 0.585, 0.200), (s * 0.048, 0.64, 0.196), (s * 0.006, 0.662, 0.192)]
        if hi:
            V, F = tube(path, [0.03, 0.026, 0.019, 0.011, 0.0], 5, tip=True, flat=0.55)
            t = np.repeat(np.linspace(0, 1, 5), 5)[:len(V)]
            t = np.concatenate([t, np.ones(len(V) - len(t))])
            P.append(Part(f'mand.{SN[s]}', V, F, f'mand.{SN[s]}', C['mand'], rough=0.28, vcolor=col_ramp(len(V), C['mand'], C['mand_tip'], t ** 1.6), sharp_deg=60))
            for f, ln in ((0.35, 0.03), (0.6, 0.024)):
                q = np.array(path[1]) * (1 - f) + np.array(path[3]) * f
                P.append(Part(f'tooth.{SN[s]}{f}', *cone(q, q + [-s * ln, 0.006, 0], 0.008, 3), f'mand.{SN[s]}', C['mand_tip'], rough=0.3))
        elif lod == 1:
            V, F = tube(path[::2], [0.03, 0.018, 0.0], 3, tip=True, flat=0.6)
            t = np.repeat(np.linspace(0, 1, 3), 3)[:len(V)]
            t = np.concatenate([t, np.ones(len(V) - len(t))])
            P.append(Part(f'mand.{SN[s]}', V, F, f'mand.{SN[s]}', C['mand'], rough=0.3, sharp_deg=180,
                          vcolor=col_ramp(len(V), C['mand'], C['mand_tip'], t ** 1.6)))
        else:
            V, F = cone(path[0], path[3], 0.028, 3)
            P.append(Part(f'mand.{SN[s]}', V, F, f'mand.{SN[s]}', C['mand'], rough=0.3, sharp_deg=180,
                          vcolor=col_ramp(len(V), C['mand'], C['mand_tip'], np.array([0, 0, 0, 1.0]))))
    # ---- antennae (two bones each; none on LOD2: sub-pixel lines alias)
    for s in SIDES:
        a1 = [(s * 0.04, 0.46, 0.31), (s * 0.085, 0.57, 0.39), (s * 0.13, 0.66, 0.44)]
        a2 = [(s * 0.13, 0.66, 0.44), (s * 0.24, 0.70, 0.43), (s * 0.31, 0.70, 0.40), (s * 0.37, 0.70, 0.37)]
        if hi:
            P.append(Part(f'ant.{SN[s]}.1', *tube(a1, [0.016, 0.013, 0.012], 4), f'ant.{SN[s]}.1', C['ant'], rough=0.45, sharp_deg=95))
            V, F = tube(a2, [0.011, 0.009, 0.007, 0.0], 4, tip=True)
            P.append(Part(f'ant.{SN[s]}.2', V, F, f'ant.{SN[s]}.2', C['ant'], rough=0.45, sharp_deg=95,
                          vcolor=col_ramp(len(V), C['ant'], C['ant_tip'], np.linspace(0, 1, len(V)))))
        elif lod == 1:
            P.append(Part(f'ant.{SN[s]}.1', *tube([a1[0], a1[-1]], [0.014, 0.011], 3, cap0=False, cap1=False), f'ant.{SN[s]}.1', C['ant'],
                          sharp_deg=180))
            P.append(Part(f'ant.{SN[s]}.2', *tube([a2[0], a2[-1]], [0.011, 0.0], 3, tip=True, cap0=False), f'ant.{SN[s]}.2', C['ant'],
                          sharp_deg=180))
    # ---- thorax
    if hi:
        P.append(Part('thorax.core', *ellipsoid((0, 0.11, 0.255), (0.12, 0.2, 0.092), 10, 5, squash_bottom=0.9), 'thorax', C['belly'], rough=0.55))
        P.append(plate('pronotum', 'thorax', 8, 3, C, y0=0.315, length=0.2, a=(0.128, 0.166), b=(0.104, 0.121), zc=0.255,
                       theta_deg=110, thick=0.014, bulge=0.08, ridge=0.026, flare=0.14, serr=0.025, skirt=0.16))
        P.append(plate('mesonotum', 'thorax', 8, 2, C, y0=0.135, length=0.2, a=(0.15, 0.162), b=(0.114, 0.121), zc=0.255,
                       theta_deg=110, thick=0.013, bulge=0.06, ridge=0.022, flare=0.1, serr=0.025, skirt=0.14))
        for s in SIDES:
            b = np.array([s * 0.055, 0.21, 0.385])
            P.append(Part(f'horn.{SN[s]}', *cone(b, b + [s * 0.03, -0.07, 0.07], 0.016, 4), 'thorax', C['keel'], rough=0.3))
        b = np.array([0, 0.03, 0.385])
        P.append(Part('spine.meso', *cone(b, b + [0, -0.06, 0.06], 0.014, 4), 'thorax', C['keel'], rough=0.3))
    elif lod == 1:
        P.append(Part('thorax.core', *ellipsoid((0, 0.11, 0.255), (0.12, 0.2, 0.092), 6, 3), 'thorax', C['belly'], rough=0.55))
        P.append(plate('pronotum', 'thorax', 3, 1, C, y0=0.31, length=0.4, a=(0.13, 0.165), b=(0.108, 0.122), zc=0.255,
                       theta_deg=100, thick=0.016, bulge=0.08, ridge=0.0, flare=0.0))
    else:
        P.append(blob('thorax.core', 'thorax', (0, 0.11, 0.265), (0.15, 0.21, 0.11), 4, 1, C['plate'], C['belly'], rough=0.4))
    # ---- abdomen: waist, two cores, five overlapping tergites, tail spike
    if hi:
        P.append(Part('waist', *ellipsoid((0, -0.06, 0.27), (0.075, 0.07, 0.065), 8, 4), 'abd.1', C['core'], rough=0.5))
        P.append(Part('abd.core1', *ellipsoid((0, -0.25, 0.28), (0.18, 0.22, 0.12), 12, 6, squash_bottom=0.85), 'abd.1', C['belly'], rough=0.55))
        P.append(Part('abd.core2', *ellipsoid((0, -0.56, 0.265), (0.15, 0.27, 0.105), 10, 6, squash_bottom=0.85), 'abd.2', C['belly'], rough=0.55))
        for k, (y0, a, b, zc) in enumerate(TERGITES):
            P.append(plate(f'tergite{k}', 'abd.1' if k < 2 else 'abd.2', 8 if k < 4 else 6, 2, C, y0=y0, length=0.19, a=a, b=b,
                           zc=zc, theta_deg=118, thick=0.012, bulge=0.05, ridge=0.024, flare=0.1, serr=0.03, skirt=0.12))
            if k < 4:
                bt = np.array([0, y0 - 0.15, zc + (b[0] + b[1]) / 2 * 1.04 + 0.022])
                P.append(Part(f'dspike{k}', *cone(bt, bt + [0, -0.075, 0.045 - 0.008 * k], 0.017, 4), 'abd.1' if k < 2 else 'abd.2',
                              C['keel'], rough=0.32))
        P.append(Part('tail', *cone((0, -0.78, 0.255), (0, -0.95, 0.235), 0.03, 5), 'abd.2', C['keel'], rough=0.3))
        for s in SIDES:
            P.append(Part(f'cercus.{SN[s]}', *cone((s * 0.05, -0.76, 0.25), (s * 0.11, -0.86, 0.24), 0.012, 3), 'abd.2', C['keel'], rough=0.35))
    elif lod == 1:
        P.append(Part('abd.core1', *ellipsoid((0, -0.25, 0.28), (0.18, 0.22, 0.12), 6, 3), 'abd.1', C['belly'], rough=0.55))
        P.append(Part('abd.core2', *ellipsoid((0, -0.58, 0.265), (0.15, 0.3, 0.105), 6, 3), 'abd.2', C['belly'], rough=0.55))
        P.append(plate('tergiteA', 'abd.1', 3, 1, C, y0=-0.03, length=0.33, a=(0.205, 0.222), b=(0.135, 0.142), zc=0.28,
                       theta_deg=110, thick=0.014, bulge=0.05, ridge=0.0, flare=0.0))
        P.append(plate('tergiteB', 'abd.2', 3, 1, C, y0=-0.34, length=0.42, a=(0.205, 0.10), b=(0.134, 0.06), zc=0.27,
                       theta_deg=110, thick=0.014, bulge=0.05, ridge=0.0, flare=0.0))
    else:
        # LOD2: two blobs coloured like the plates on top (the plates' paler rims averaged in), belly below
        P.append(blob('abd.core1', 'abd.1', (0, -0.22, 0.29), (0.215, 0.24, 0.15), 4, 2, 0x291c2f, C['belly'], rough=0.4))
        P.append(blob('abd.core2', 'abd.2', (0, -0.57, 0.27), (0.17, 0.3, 0.12), 4, 2, 0x251a2c, C['belly'], rough=0.4))
    # ---- glands: dorsal pores + lateral rows; seated on THIS LOD's carapace (LOD0 for the sockets)
    if lod < 2:
        plates = [p for p in P if p.name.startswith(('tergite', 'pronotum'))]
        GL = []
        for k, pores in enumerate(DORSAL_PORES):
            y0, a, b, zc = TERGITES[k]
            bone = 'abd.1' if k < 2 else 'abd.2'
            for j, (u, v, r) in enumerate(pores):
                aw = a[0] + (a[1] - a[0]) * v
                x, y = u * 0.5 * aw, y0 - 0.02 - 0.15 * v
                z = surface_z(plates, x, y) - 0.2 * r
                GL.append((f'gland.d{k}{j}', bone, (x, y, z), r, True, False, True))
        for k, side in LATERAL_PORES:
            y0, a, b, zc = TERGITES[k]
            th = math.radians(100)
            GL.append((f'gland.l{k}{SN[side]}', 'abd.1' if k < 2 else 'abd.2',
                       (side * a[1] * math.sin(th), y0 - 0.172, zc + b[1] * math.cos(th)), 0.015, False, k % 2 == 1, False))
        y4 = TERGITES[4][0] - 0.08
        GL.append(('gland.d4', 'abd.2', (0.012, y4, surface_z(plates, 0.012, y4) - 0.2 * 0.019), 0.019, True, False, True))
        GL.append(('gland.pro', 'thorax', (-0.022, 0.2, surface_z(plates, -0.022, 0.2) - 0.2 * 0.015), 0.015, True, True, True))
        for nm, bone, c, r, hot, red, in_lod1 in GL:
            if hi or in_lod1:
                # dorsal pores are what reads from the game camera: glint sprites; the lateral rows only in close-ups
                P.append(gland(nm, bone, c, r, C, hot=hot, red=red, glow=1.0 if hot else 0.75, glint=in_lod1,
                               intensity=1.0 if hot and not red else 0.6))
    # ---- legs
    for lg in LEGS:
        P.extend(leg_parts(lg, lod, C))
    return P


# ------------------------------------------------------------------ animation
GROUND_CLAMP = {'death', 'death2', 'death3', 'hit'}   # clips whose root is lifted by any remaining floor penetration
DEATHS = ('death', 'death2', 'death3')

CLIPS = [  # name, frames, loop, stride (m per loop, model scale 1), event frame, notes
    ('idle', 30, True, 0.0, 0, 'breathing, antenna sweeps, mandible chew; feet planted'),
    ('walk', 24, True, 0.90, 0, 'tripod gait, duty 0.62, body bob 2/cycle, roll, abdomen counter-sway'),
    ('run', 16, True, 1.60, 0, 'tripod gait, duty 0.42 (aerial phase), crouched, nose down, antennae swept back'),
    ('attack', 18, False, 0.0, 9, 'rear up, front legs raised, lunge 0.3 m, mandibles snap on the event frame'),
    ('hit', 10, False, 0.0, 1, 'recoil + roll away from the hit, legs splay, glands flare'),
    ('death', 36, False, 0.0, 35, 'recoil, flip onto the back, legs curl, 3 twitches, glands fade; last frame = corpse'),
    ('death2', 30, False, 0.0, 29, 'legs buckle, the body drops on its belly and slides, rolls a little, legs fold under, 2 kicks'),
    ('death3', 36, False, 0.0, 35, 'thrown back by the hit, spins half round while flipping over, legs curl and twitch'),
]


def _ant(st, a1y, a1p, a2y, a2p):
    for s in SIDES:
        st.set(f'ant.{SN[s]}.1', rz(-s * a1y) @ rx(a1p))
        st.set(f'ant.{SN[s]}.2', rz(-s * a2y) @ rx(a2p))


def _death_flip(st, f, spin=0.0, slide=0.0):
    K = [0, 1.0, 0.85, 0.6]
    k = K[f] if f < 4 else 0.0
    flip = smoothstep(3, 13, f)
    hop = math.sin(math.pi * min(max((f - 3) / 10, 0), 1))
    rho = math.pi * flip * 0.985
    cz, ea, eb = 0.29, 0.235, 0.165
    lift = roll_lift(rho, cz, ea, eb, flip) + 0.07 * hop
    thrown = smoothstep(1, 14, f)
    st.set('root', tr(-cz * math.sin(rho) - 0.12 * flip, -0.05 * flip - slide * thrown, lift) @ rz(spin * thrown) @ ry(rho))
    tw = sum(amp * bell(f, t0, 1.6) for t0, amp in ((18, 1.0), (24, 0.7), (30, 0.4)))
    st.set('thorax', tr(0, -0.06 * k, 0.03 * k) @ rx(10 * k * D2R) @ ry(-8 * tw * D2R))
    st.set('head', rx((14 * k - 22 * flip) * D2R) @ rz(10 * tw * D2R))
    st.set('abd.1', rx((-8 * k - 16 * flip + 6 * tw) * D2R))
    st.set('abd.2', rx((-24 * flip + 10 * tw) * D2R) @ rz(6 * tw * D2R))
    for s in SIDES:
        st.set(f'mand.{SN[s]}', rz(-s * (26 * k + 30 * flip - 20 * tw) * D2R))
    _ant(st, (12 * k + 20 * flip) * D2R, (-30 * k - 25 * flip + 15 * tw) * D2R, 18 * flip * D2R, (-35 * flip + 20 * tw) * D2R)
    tuck = smoothstep(1.5, 6, f)
    curl = smoothstep(11, 19, f)
    flail = math.sin(math.pi * min(max((f - 3) / 14, 0), 1)) * (0.35 + 0.65 * curl)
    for lg in LEGS:
        seed = lg.i * 1.7 + (lg.s + 1) * 2.3
        dp = lg.dead_params()
        twl = tw * (0.6 + 0.4 * math.sin(seed * 3.1)) * (1 if (lg.i + (lg.s > 0)) % 2 == 0 or f > 26 else 0.4)
        jitter = np.array([0.0, 0.5 * flail * math.sin(f * 1.9 + seed) + 0.45 * twl,
                           0.8 * flail * math.sin(f * 2.3 + seed * 1.3) - 0.7 * twl,
                           0.6 * flail * math.sin(f * 2.9 + seed) + 0.9 * twl])
        st.feet[lg.name] = ('mix2', lg.F0 + np.array([lg.s * 0.05, 0, 0]) * k, lg.tuck_params() + jitter * 0.5, tuck, dp + jitter, curl)
    fade = 1 - smoothstep(4, 30, f)
    flick = sum(0.9 * bell(f, t0, 0.8) for t0 in (18, 24, 30))
    st.glow.update(gland=max(0.06, (1.0 + 1.6 * k) * (0.08 + 0.92 * fade) + flick * (0.3 + 0.7 * fade)),
                   eye=max(0.05, 1 - smoothstep(2, 20, f)))


def _death_crumple(st, f):
    K = [0, 1.0, 0.8, 0.5]
    k = K[f] if f < 4 else 0.0
    drop = smoothstep(2, 9, f)
    slide = smoothstep(3, 14, f)
    roll = smoothstep(8, 18, f)
    tw = sum(amp * bell(f, t0, 1.3) for t0, amp in ((19, 1.0), (25, 0.6)))
    st.set('root', tr(0.02 * roll, 0.14 * slide, -0.14 * drop) @ rz(14 * D2R * slide) @ ry(-6 * D2R * roll))
    st.set('thorax', tr(0, -0.05 * k, 0.02 * k) @ rx((12 * k - 6 * drop) * D2R))
    st.set('head', rx((16 * k + 20 * drop) * D2R) @ rz(-8 * tw * D2R))
    st.set('abd.1', rx((-6 * k + 7 * drop) * D2R) @ rz(4 * tw * D2R))
    st.set('abd.2', rx((10 * drop - 6 * tw) * D2R) @ rz(-8 * roll * D2R))
    for s in SIDES:
        st.set(f'mand.{SN[s]}', rz(-s * (24 * k + 34 * drop - 12 * tw) * D2R))
    _ant(st, (10 * k + 26 * drop) * D2R, (-20 * k + 30 * drop) * D2R, 10 * drop * D2R, (22 * drop - 10 * tw) * D2R)
    buckle = smoothstep(1.5, 8, f)
    for lg in LEGS:
        seed = lg.i * 2.1 + (lg.s + 1) * 1.3
        kick = tw * (1.0 if (lg.i + (lg.s > 0)) % 2 else 0.35)
        jitter = np.array([0.0, 0.35 * kick * math.sin(seed), -0.55 * kick, 0.6 * kick])
        st.feet[lg.name] = ('mix', lg.F0 + np.array([lg.s * 0.06, 0, 0]) * k, lg.splay_params() + jitter, buckle)
    fade = 1 - smoothstep(3, 26, f)
    flick = sum(0.8 * bell(f, t0, 0.8) for t0 in (19, 25))
    st.glow.update(gland=max(0.06, (1.0 + 1.4 * k) * (0.08 + 0.92 * fade) + flick * (0.3 + 0.7 * fade)),
                   eye=max(0.05, 1 - smoothstep(2, 18, f)))


def clip_state(name, f, n):
    st = State()
    tau = f / n if name in ('idle', 'walk', 'run') else f / (n - 1)
    if name == 'idle':
        w = TWO * tau
        st.set('thorax', tr(0, 0, 0.006 * math.sin(w)) @ rx(1.0 * D2R * math.sin(w)) @ rz(3 * D2R * math.sin(w)))
        st.set('head', rz(7 * D2R * math.sin(w + 0.8)) @ rx(4 * D2R * math.sin(2 * w)))
        st.set('abd.1', rx(-2 * D2R * math.sin(w - 0.6)))
        st.set('abd.2', rx(-2.5 * D2R * math.sin(w - 1.2)) @ rz(2 * D2R * math.sin(w)))
        chew = max(0.0, math.sin(2 * w)) ** 2
        for s in SIDES:
            st.set(f'mand.{SN[s]}', rz(-s * (6 + 14 * chew) * D2R))
            st.set(f'ant.{SN[s]}.1', rz(-s * 10 * D2R * math.sin(w + s * 0.9)) @ rx(8 * D2R * math.sin(w + 1.5)))
            st.set(f'ant.{SN[s]}.2', rz(-s * 14 * D2R * math.sin(w + s * 0.9 - 0.7)) @ rx(-10 * D2R * math.sin(w + 0.8)))
        feet_planted(st, LEGS)
        st.glow.update(gland=0.8, pulse=0.2, wave=tau)
    elif name in ('walk', 'run'):
        run = name == 'run'
        w = TWO * tau
        duty, D, h = (0.42, 1.60, 0.13) if run else (0.62, 0.90, 0.09)
        bob = (0.02 if run else 0.012)
        zb = -bob * math.cos(2 * w) + (-0.03 if run else 0.0)
        st.set('thorax', tr(0, 0.0, zb) @ rz((2 if run else 3.5) * D2R * math.sin(w + 0.4)) @
               rx(((-6 if run else 0) + (1.5 if run else 1.2) * math.sin(2 * w + 0.6)) * D2R) @ ry((5 if run else 4) * D2R * math.sin(w)))
        st.set('head', rz(-(1.5 if run else 2.8) * D2R * math.sin(w + 0.4)) @ rx(((4 if run else 0) - 1.2 * math.sin(2 * w + 1.4)) * D2R))
        st.set('abd.1', rz(-(4 if run else 3) * D2R * math.sin(w - 0.5)) @ rx(((3 if run else 0) + 1.5 * math.sin(2 * w - 0.2)) * D2R))
        st.set('abd.2', rz(-(6 if run else 4.5) * D2R * math.sin(w - 1.2)) @ rx(2.0 * D2R * math.sin(2 * w - 0.9)))
        ch = (8 if run else 5) * D2R * (0.5 + 0.5 * math.sin(2 * w))
        for s in SIDES:
            st.set(f'mand.{SN[s]}', rz(-s * ch))
        if run:
            _ant(st, -18 * D2R + 3 * D2R * math.sin(w), -14 * D2R + 4 * D2R * math.sin(2 * w + 0.5),
                 -10 * D2R + 6 * D2R * math.sin(w - 0.8), -18 * D2R + 6 * D2R * math.sin(2 * w - 0.4))
        else:
            for s in SIDES:
                st.set(f'ant.{SN[s]}.1', rz(-s * 5 * D2R * math.sin(w + s * 0.7)) @ rx(5 * D2R * math.sin(2 * w + 0.5)))
                st.set(f'ant.{SN[s]}.2', rz(-s * 9 * D2R * math.sin(w + s * 0.7 - 0.9)) @ rx(-8 * D2R * math.sin(2 * w - 0.4)))
        feet_gait(st, LEGS, tau, duty, D, h, fb=0.05 if run else 0.0)
        st.glow.update(gland=0.85, pulse=0.15, wave=2 * tau)
    elif name == 'attack':
        t = tau
        up = smoothstep(0.0, 0.32, t) * (1 - smoothstep(0.38, 0.52, t))
        lunge = smoothstep(0.30, 0.50, t) * (1 - smoothstep(0.58, 1.0, t))
        snap = smoothstep(0.44, 0.50, t)
        rec = smoothstep(0.55, 1.0, t)
        st.set('root', tr(0, -0.06 * up + 0.30 * lunge, 0))
        st.set('thorax', tr(0, 0, 0.07 * up) @ rx((24 * up - 6 * lunge) * D2R))
        st.set('head', rx((14 * up - 4 * lunge) * D2R))
        st.set('abd.1', rx((16 * up - 4 * lunge) * D2R))
        st.set('abd.2', rx((12 * up - 2 * lunge) * D2R))
        mo = (36 * up) * (1 - snap) - 6 * snap * (1 - rec)
        for s in SIDES:
            st.set(f'mand.{SN[s]}', rz(-s * mo * D2R))
        _ant(st, 10 * D2R * up, (-25 * up - 10 * lunge) * D2R, 8 * D2R * up, (-20 * up - 15 * lunge) * D2R)
        for lg in LEGS:
            if lg.i == 0:
                st.feet[lg.name] = ('ik', lg.F0 + np.array([lg.s * -0.06, 0.12, 0.34]) * up + np.array([0, 0.36, 0.0]) * lunge)
            else:
                st.feet[lg.name] = ('ik', lg.F0)
        st.glow.update(gland=1.0 + 0.9 * up + 0.6 * lunge)
    elif name == 'hit':
        k = [0, 1.0, 0.86, 0.58, 0.28, 0.06, -0.1, -0.08, -0.03, 0.0][f]
        st.set('thorax', tr(0, -0.07 * k, 0.03 * k) @ rx(12 * k * D2R) @ ry(14 * k * D2R) @ rz(6 * k * D2R))
        st.set('head', rx(16 * k * D2R) @ rz(-8 * k * D2R))
        st.set('abd.1', rx(9 * k * D2R) @ rz(-6 * k * D2R))
        st.set('abd.2', rx(8 * k * D2R) @ rz(-8 * k * D2R))
        for s in SIDES:
            st.set(f'mand.{SN[s]}', rz(-s * 26 * k * D2R))
        _ant(st, 12 * k * D2R, -32 * k * D2R, 10 * k * D2R, -28 * k * D2R)
        feet_planted(st, LEGS, lambda lg: np.array([lg.s * 0.05, 0.0, 0.0]) * max(k, 0))
        st.glow.update(gland=1.0 + 1.6 * max(k, 0))
    elif name == 'death':
        _death_flip(st, f)
    elif name == 'death2':
        _death_crumple(st, f)
    elif name == 'death3':
        _death_flip(st, f, spin=-2.4, slide=0.38)
    return st
