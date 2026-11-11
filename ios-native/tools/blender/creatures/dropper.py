"""Dropper («Капельщик») — the overhead's own bug (Stage 1 R4; design.md §1.1.3): a flat, long body (≈ 1.6 m with its
tail forceps) between a silverfish and an earwig, TEN hooked legs splayed wide with high knees, pale frost-crusted back
plates (the only pale bug: its rim is bone-white in the renderer), two pin-prick eyes in the hive's pink-white (its only
glints), curved fangs, long feelers and a pair of hooked tail forceps.

It rides ON TOP of the routes (a bug under a cable is invisible from the 57° camera). Its telegraph is the COIL: the
front third arches up and curls down over the route's edge in an S-curve toward its landing ring, the fangs open, the
front legs reach down and the eyes flare; then the DROP (a dive, legs flung forward), the PIN (beside a marine: the
front raised into it, the forelegs hooked in, the fangs gnawing, the rear braced) and the STRUGGLE (a thrash while it is
shot off or the marine fights it).

Skeleton (42 bones): root, thorax (leg pairs 1–3), head (fangs, feelers), abd.1 (leg pairs 4–5 pose in ITS frame:
`DLeg.body`, build.py's per-leg body hook), abd.2, abd.3 (tail forceps). Every leg bone is parented to the thorax (the
renderer's head / abdomen look groups stay the head and the plated abdomen). LOD0 ≤ 3000 / LOD1 ≤ 450 / LOD2 ≤ 150.
Clips: idle (perched) / walk / run (a metachronal wave down the ten legs with a silverfish wriggle) / attack / hit /
coil / drop / pin / struggle / death / death_burn / death_frost. Instance scale 1.0 (BUG_SPECS). See insect.py.
"""
import math

import numpy as np

from geo import Part, cone, ellipsoid, octa, smoothstep, tube
from insect import (D2R, FPS, SIDES, SN, TWO, Leg, State, bell, blob, bone_frame, col_ramp, gait_foot, gen_death_burn,
                    gen_death_frost, gland, plate, roll_lift, rx, ry, rz, skeleton_legs, tr)

NAME = 'dropper'
SCALE = 1.0
SWITCH_PX = (80.0, 16.0, 0.0)

# pale bone plates with frost-white rims over a near-black core; dark legs with pale hooks; pink-white eyes
PAL = dict(plate=0x6f685e, edge=0xd8d2c6, keel=0x48423c, core=0x161312, belly=0x2a2320, leg=0x221c1c, leg_dist=0x4a423c,
           joint=0x342c2a, claw=0xd4cabe, mand=0x3a2a28, mand_tip=0xeee2d8, ant=0x26201e, ant_tip=0x9a9088,
           gland=0xff6f9a, gland_hot=0xfff2f7, gland_red=0xe0183a, eye=0xffdbe8)

PAIRS = 5
HIP_Y = (0.40, 0.25, 0.10, -0.06, -0.22)


class DLeg(Leg):
    """One of the Dropper's ten legs: pair k (0 front … 4 back). `i` is the insect helpers' role (front / middle / back);
    the rear two pairs pose in abd.1's frame (`body`)."""
    def __init__(self, k, s, C, H, F0, L, beta=28.0):
        i = 0 if k == 0 else (2 if k == PAIRS - 1 else 1)
        super().__init__(i, s, C, H, F0, L, beta=beta, tripod=(k + (s > 0)) % 2)
        self.k = k
        self.name = f'leg.{k + 1}.{SN[s]}'
        self.body = 'thorax' if k < 3 else 'abd.1'
        # its place in the metachronal wave (a ripple from the tail forward, the two sides half a cycle apart)
        self.wave = ((PAIRS - 1 - k) * 0.16 + (0.5 if s > 0 else 0.0)) % 1.0


def _legs():
    out = []
    for k in range(PAIRS):
        for s in SIDES:
            y = HIP_Y[k]
            out.append(DLeg(k, s, C=(s * 0.08, y, 0.10), H=(s * 0.135, y, 0.115),
                            F0=(s * (0.56, 0.62, 0.64, 0.62, 0.56)[k], y + (0.16, 0.06, -0.02, -0.10, -0.18)[k], 0.0),
                            L=((0.27, 0.29, 0.30, 0.30, 0.29)[k], (0.31, 0.33, 0.34, 0.34, 0.33)[k], 0.12)))
    return out


LEGS = _legs()


def skeleton():
    B = []

    def add(name, parent, head, tail, zhint=(0, 0, 1)):
        B.append((name, parent, bone_frame(head, tail, zhint), float(np.linalg.norm(np.subtract(tail, head)))))
    add('root', None, (0, 0, 0), (0, 0.25, 0))
    add('thorax', 'root', (0, 0.08, 0.13), (0, 0.48, 0.13))
    add('head', 'thorax', (0, 0.48, 0.13), (0, 0.74, 0.12))
    for s in SIDES:
        add(f'fang.{SN[s]}', 'head', (s * 0.065, 0.68, 0.085), (s * 0.03, 0.85, 0.07))
        add(f'ant.{SN[s]}', 'head', (s * 0.05, 0.70, 0.13), (s * 0.40, 1.12, 0.15))
    add('abd.1', 'thorax', (0, 0.08, 0.135), (0, -0.26, 0.135))
    add('abd.2', 'abd.1', (0, -0.26, 0.13), (0, -0.56, 0.12))
    add('abd.3', 'abd.2', (0, -0.56, 0.12), (0, -0.80, 0.11))
    for s in SIDES:
        add(f'cerc.{SN[s]}', 'abd.3', (s * 0.04, -0.74, 0.12), (s * 0.16, -1.04, 0.17))
    skeleton_legs(B, LEGS)
    return B


# body plates (y0 = front edge, a = (front, back) half widths, b = (front, back) half heights, zc, bone) — flat and long
THORAX = [(0.50, (0.13, 0.155), (0.06, 0.066), 0.130), (0.36, (0.155, 0.165), (0.066, 0.07), 0.130),
          (0.22, (0.165, 0.175), (0.07, 0.072), 0.130)]
TERGITES = [(0.08, (0.175, 0.18), (0.072, 0.07), 0.132, 'abd.1'), (-0.07, (0.18, 0.172), (0.07, 0.066), 0.130, 'abd.1'),
            (-0.22, (0.172, 0.155), (0.066, 0.06), 0.127, 'abd.2'), (-0.37, (0.155, 0.13), (0.06, 0.054), 0.123, 'abd.2'),
            (-0.52, (0.13, 0.10), (0.054, 0.046), 0.119, 'abd.3'), (-0.65, (0.10, 0.065), (0.046, 0.036), 0.114, 'abd.3')]
EYES = [(-1, 0.666, 0.147), (1, 0.664, 0.147)]
EXTRA_SOCKETS = [('mouth', 'head', (0, 0.84, 0.08), 0), ('core', 'thorax', (0, 0.25, 0.15), 0), ('back', 'abd.1', (0, -0.08, 0.22), 0)]


def _leg_parts(lg, lod):
    """LOD0: coxa knob, bowed femur, knee, tibia, a spur, hooked tarsus (≈ 100 triangles). LOD1: three open 3-sided
    prisms (15). LOD2: an open femur prism + one tapered tibia-to-foot prism (9)."""
    C = PAL
    P = []
    p = lg.rest[0]
    H, K, A, F, n = lg.fk(p)
    if lod == 0:
        P.append(Part(lg.name + '.coxa', *octa((lg.C + lg.H) / 2, 0.034, 0.8), 'thorax', C['joint'], rough=0.45))
        mid = (H + K) / 2 + np.cross(n, (K - H) / np.linalg.norm(K - H)) * -0.016
        V, Fc = tube([H, (H + mid) / 2, mid, K], [0.024, 0.031, 0.031, 0.022], 5, flat=0.8, up=n)
        t = np.repeat(np.linspace(0, 1, 4), 5)[:len(V)]
        t = np.concatenate([t, np.zeros(len(V) - len(t))])
        P.append(Part(lg.name + '.femur', V, Fc, lg.name + '.femur', C['leg'], rough=0.42, vcolor=col_ramp(len(V), C['leg'], C['joint'], t * 0.6)))
        P.append(Part(lg.name + '.knee', *octa(K, 0.024), lg.name + '.femur', C['joint'], rough=0.35))
        V, Fc = tube([K, (K + A) / 2, A], [0.020, 0.017, 0.013], 4, up=n)
        t = np.repeat(np.linspace(0, 1, 3), 4)
        t = np.concatenate([t, np.zeros(len(V) - len(t))])
        P.append(Part(lg.name + '.tibia', V, Fc, lg.name + '.tibia', C['leg'], rough=0.45, vcolor=col_ramp(len(V), C['leg'], C['leg_dist'], t)))
        dA = (A - K) / np.linalg.norm(A - K)
        b = K + (A - K) * 0.7
        P.append(Part(lg.name + '.spur', *cone(b, b + np.cross(n, dA) * 0.035 + dA * 0.02, 0.008, 3), lg.name + '.tibia', C['claw'], rough=0.4))
        # the tarsus ends in a point ON the foot (its lowest vertex: the planted contact the gait keeps still), and a pale
        # barb curls up and out from it (the «hooked legs»)
        V, Fc = tube([A, A + (F - A) * 0.55, F], [0.013, 0.010, 0.0], 4, up=n, tip=True)
        P.append(Part(lg.name + '.tarsus', V, Fc, lg.name + '.tarsus', C['leg_dist'], rough=0.4, sharp_deg=95,
                      vcolor=col_ramp(len(V), C['leg_dist'], C['claw'], np.linspace(0, 1, len(V)) ** 2)))
        out = np.array([math.cos(p[0]), math.sin(p[0]), 0.0])
        b0 = F + (A - F) * 0.18 + [0, 0, 0.004]
        P.append(Part(lg.name + '.hook', *cone(b0, b0 + out * 0.034 + [0, 0, 0.03], 0.007, 3), lg.name + '.tarsus', C['claw'], rough=0.35))
    elif lod == 1:
        for a, b, r0, r1, nm, c in ((H, K, 0.028, 0.022, 'femur', C['leg']), (K, A, 0.019, 0.013, 'tibia', C['leg']),
                                    (A, F, 0.012, 0.0, 'tarsus', C['leg_dist'])):
            V, Fc = tube([a, b], [r0, r1], 3, up=n, cap0=False, cap1=False, tip=(nm == 'tarsus'), phase=math.pi / 2)
            P.append(Part(f'{lg.name}.{nm}', V, Fc, f'{lg.name}.{nm}', c, rough=0.5, sharp_deg=180))
    else:
        V, Fc = tube([H, K], [0.03, 0.022], 3, up=n, cap0=False, cap1=False, phase=math.pi / 2)
        P.append(Part(f'{lg.name}.femur', V, Fc, f'{lg.name}.femur', C['leg'], rough=0.5, sharp_deg=180))
        V, Fc = tube([K, F], [0.02, 0.0], 3, up=n, cap0=False, tip=True, phase=math.pi / 2)
        P.append(Part(f'{lg.name}.tibia', V, Fc, f'{lg.name}.tibia', C['leg_dist'], rough=0.5, sharp_deg=180))
    return P


def build_parts(lod):
    P = []
    C = PAL
    hi = lod == 0
    # ---- head: a low wedge under a frost-rimmed shield, two pin-prick eyes, curved fangs, long feelers
    if hi:
        P.append(Part('head.core', *ellipsoid((0, 0.62, 0.10), (0.095, 0.13, 0.048), 10, 4, squash_bottom=0.8), 'head', C['core'], rough=0.5))
        P.append(plate('head.shield', 'head', 6, 3, C, y0=0.76, length=0.27, a=(0.06, 0.125), b=(0.03, 0.06), zc=0.105,
                       theta_deg=100, thick=0.01, bulge=0.05, ridge=0.012, flare=0.12, serr=0.02))
    elif lod == 1:
        P.append(blob('head.core', 'head', (0, 0.62, 0.11), (0.11, 0.14, 0.055), 5, 2, C['plate'], C['core'], rough=0.4))
    else:
        P.append(blob('head.core', 'head', (0, 0.62, 0.11), (0.11, 0.15, 0.06), 4, 1, C['plate'], C['core'], rough=0.4))
    for s in SIDES:
        path = [(s * 0.068, 0.68, 0.086), (s * 0.10, 0.75, 0.08), (s * 0.078, 0.815, 0.075), (s * 0.025, 0.855, 0.07)]
        if hi:
            V, F = tube(path, [0.022, 0.018, 0.012, 0.0], 5, tip=True, flat=0.6)
            t = np.repeat(np.linspace(0, 1, 4), 5)[:len(V)]
            t = np.concatenate([t, np.ones(len(V) - len(t))])
            P.append(Part(f'fang.{SN[s]}', V, F, f'fang.{SN[s]}', C['mand'], rough=0.28, sharp_deg=60,
                          vcolor=col_ramp(len(V), C['mand'], C['mand_tip'], t ** 1.5)))
        elif lod == 1:
            P.append(Part(f'fang.{SN[s]}', *cone(path[0], path[3], 0.02, 3), f'fang.{SN[s]}', C['mand'], rough=0.3, sharp_deg=180,
                          vcolor=col_ramp(4, C['mand'], C['mand_tip'], np.array([0, 0, 0, 1.0]))))
        ant = [(s * 0.05, 0.70, 0.13), (s * 0.16, 0.86, 0.16), (s * 0.29, 1.01, 0.17), (s * 0.40, 1.12, 0.15)]
        if hi:
            V, F = tube(ant, [0.011, 0.009, 0.007, 0.0], 4, tip=True)
            P.append(Part(f'ant.{SN[s]}', V, F, f'ant.{SN[s]}', C['ant'], rough=0.45, sharp_deg=95,
                          vcolor=col_ramp(len(V), C['ant'], C['ant_tip'], np.linspace(0, 1, len(V)))))
        elif lod == 1:
            P.append(Part(f'ant.{SN[s]}', *tube([ant[0], ant[3]], [0.01, 0.0], 3, tip=True, cap0=False), f'ant.{SN[s]}', C['ant'],
                          sharp_deg=180))
    # ---- thorax: a flat core under three overlapping frost-rimmed plates
    if hi:
        P.append(Part('thorax.core', *ellipsoid((0, 0.30, 0.115), (0.14, 0.23, 0.055), 10, 4, squash_bottom=0.9), 'thorax', C['belly'], rough=0.55))
        for k, (y0, a, b, zc) in enumerate(THORAX):
            P.append(plate(f'notum{k}', 'thorax', 8, 2, C, y0=y0, length=0.17, a=a, b=b, zc=zc, theta_deg=124, thick=0.011,
                           bulge=0.05, ridge=0.016, flare=0.12, serr=0.02, skirt=0.12))
    elif lod == 1:
        P.append(Part('thorax.core', *ellipsoid((0, 0.30, 0.115), (0.14, 0.23, 0.055), 6, 3), 'thorax', C['belly'], rough=0.55))
        P.append(plate('notum', 'thorax', 3, 1, C, y0=0.50, length=0.45, a=(0.13, 0.175), b=(0.06, 0.072), zc=0.13, theta_deg=118,
                       thick=0.012, bulge=0.05, ridge=0.0, flare=0.0))
    else:
        P.append(blob('thorax.core', 'thorax', (0, 0.29, 0.125), (0.17, 0.24, 0.075), 4, 1, 0x8a8478, C['belly'], rough=0.4))
    # ---- abdomen: three flat cores under six overlapping tergites, tapering to the tail forceps
    if hi:
        for nm, bone, c, r in (('abd.core1', 'abd.1', (0, -0.09, 0.118), (0.16, 0.20, 0.055)),
                               ('abd.core2', 'abd.2', (0, -0.38, 0.113), (0.13, 0.19, 0.05)),
                               ('abd.core3', 'abd.3', (0, -0.64, 0.108), (0.08, 0.15, 0.038))):
            P.append(Part(nm, *ellipsoid(c, r, 10, 4, squash_bottom=0.9), bone, C['belly'], rough=0.55))
        for k, (y0, a, b, zc, bone) in enumerate(TERGITES):
            P.append(plate(f'tergite{k}', bone, 8 if k < 4 else 6, 2, C, y0=y0, length=0.17, a=a, b=b, zc=zc, theta_deg=124, thick=0.011,
                           bulge=0.05, ridge=0.016, flare=0.12, serr=0.025, skirt=0.12))
    elif lod == 1:
        P.append(Part('abd.core1', *ellipsoid((0, -0.15, 0.118), (0.16, 0.24, 0.055), 6, 2), 'abd.1', C['belly'], rough=0.55))
        P.append(Part('abd.core2', *ellipsoid((0, -0.5, 0.11), (0.12, 0.26, 0.045), 6, 2), 'abd.2', C['belly'], rough=0.55))
        P.append(plate('tergiteA', 'abd.1', 3, 1, C, y0=0.08, length=0.34, a=(0.175, 0.17), b=(0.072, 0.066), zc=0.13, theta_deg=118,
                       thick=0.012, bulge=0.04, ridge=0.0, flare=0.0))
        P.append(plate('tergiteB', 'abd.2', 3, 1, C, y0=-0.26, length=0.52, a=(0.165, 0.07), b=(0.064, 0.038), zc=0.12, theta_deg=118,
                       thick=0.012, bulge=0.04, ridge=0.0, flare=0.0))
    else:
        P.append(blob('abd.core1', 'abd.1', (0, -0.12, 0.125), (0.18, 0.22, 0.075), 4, 1, 0x8a8478, C['belly'], rough=0.4))
        P.append(blob('abd.core2', 'abd.2', (0, -0.48, 0.115), (0.13, 0.26, 0.06), 4, 1, 0x7e786e, C['belly'], rough=0.4))
    # ---- the tail forceps: two hooked cerci curving in at the tips
    for s in SIDES:
        path = [(s * 0.04, -0.72, 0.12), (s * 0.12, -0.86, 0.14), (s * 0.165, -0.98, 0.165), (s * 0.13, -1.07, 0.19)]
        if hi:
            V, F = tube(path, [0.022, 0.017, 0.011, 0.0], 5, tip=True, flat=0.75)
            t = np.repeat(np.linspace(0, 1, 4), 5)[:len(V)]
            t = np.concatenate([t, np.ones(len(V) - len(t))])
            P.append(Part(f'cerc.{SN[s]}', V, F, f'cerc.{SN[s]}', C['keel'], rough=0.3, sharp_deg=70,
                          vcolor=col_ramp(len(V), C['keel'], C['claw'], t ** 1.4)))
        elif lod == 1:
            P.append(Part(f'cerc.{SN[s]}', *cone(path[0], path[3], 0.02, 3), f'cerc.{SN[s]}', C['keel'], rough=0.3, sharp_deg=180))
    # ---- the two pin-prick eyes: pink-white, its only glints (sockets on every LOD from LOD0's)
    if lod < 2:
        for s, y, z in EYES:
            P.append(gland(f'gland.eye{SN[s]}', 'head', (s * 0.046, y, z), 0.015, C, hot=True, glow=1.0, glint=True, intensity=1.6))
    for lg in LEGS:
        P.extend(_leg_parts(lg, lod))
    return P


# ------------------------------------------------------------------ animation
GROUND_CLAMP = {'death', 'hit', 'death_burn', 'death_frost'}
DEATHS = ('death', 'death_burn', 'death_frost')
LOOPS = ('idle', 'walk', 'run', 'pin', 'struggle')

CLIPS = [  # name, frames, loop, stride, event, notes
    ('idle', 30, True, 0.0, 0, 'perched: pressed flat, feelers sweeping, fangs twitching, the forceps swaying; feet planted'),
    ('walk', 20, True, 0.85, 0, 'crawl: a metachronal wave down the ten legs (duty 0.62), a silverfish wriggle'),
    ('run', 14, True, 1.40, 0, 'scuttle: the wave faster (duty 0.44), lower, a stronger wriggle, feelers swept back'),
    ('attack', 16, False, 0.0, 8, 'the front third rears and strikes, fangs snap on the event frame'),
    ('hit', 10, False, 0.0, 1, 'recoil and roll away, legs splay, the eyes flare'),
    ('coil', 18, False, 0.0, 17, 'the telegraph: the back arches, the front third curls down over the edge (an S), fangs open, '
                                 'forelegs reach down, the eyes flare; holds its last frame'),
    ('drop', 10, False, 0.0, 9, 'the dive: straightened, the legs flung forward and out, fangs wide, forceps up'),
    ('pin', 24, True, 0.0, 0, 'beside a marine: the front raised into it, forelegs hooked in, fangs gnawing twice a loop, rear braced'),
    ('struggle', 16, True, 0.0, 0, 'shot at or fought while pinning: the body whips side to side, the legs flail'),
    ('death', 30, False, 0.0, 29, 'thrown over onto its back, the ten legs curling, two twitches; last frame = corpse'),
    ('death_burn', 30, False, 0.0, 29, 'burned: writhes, spins onto its back, legs curl tight, twitches'),
    ('death_frost', 24, False, 0.0, 23, 'frozen stiff: two shudders, tips over sideways like a statue'),
]


def _parts(st, k, clack):
    """fangs gape (and clack), feelers up and forward, forceps open — for a threat amount k (deaths)"""
    for s in SIDES:
        st.set(f'fang.{SN[s]}', rz(s * (30 * k - 16 * clack * k) * D2R))
        st.set(f'ant.{SN[s]}', rz(-s * 10 * k * D2R) @ rx(14 * k * D2R))
        st.set(f'cerc.{SN[s]}', rz(-s * 14 * k * D2R) @ rx(10 * k * D2R))


def _fangs(st, gape):
    for s in SIDES:
        st.set(f'fang.{SN[s]}', rz(s * gape * D2R))


def _feelers(st, yaw, pitch):
    for s in SIDES:
        st.set(f'ant.{SN[s]}', rz(-s * yaw) @ rx(pitch))


def _forceps(st, spread, lift):
    for s in SIDES:
        st.set(f'cerc.{SN[s]}', rz(-s * spread) @ rx(lift))


def _wave_feet(st, tau, duty, D, h):
    """every leg on the metachronal wave: stride D per loop, stance duty, step height h (planted feet stay planted)"""
    stroke = D * duty
    for lg in LEGS:
        st.feet[lg.name] = ('ik', gait_foot(tau, lg, duty, stroke, h, phase=lg.wave))


def _params(lg, fwd, f1, f2, f3):
    """explicit joint params off the rest pose: yaw `fwd` toward the head (rad), femur / tibia / tarsus pitches (deg)"""
    r = lg.rest[0]
    return np.array([r[0] + lg.s * fwd, math.radians(f1), math.radians(f2), math.radians(f3)])


def _blendp(a, b, w):
    out = a.copy()
    out[0] = a[0] + ((b[0] - a[0] + math.pi) % (2 * math.pi) - math.pi) * w
    out[1:] = a[1:] * (1 - w) + b[1:] * w
    return out


def _wriggle(st, w, amp, lowz=0.0):
    """the silverfish wriggle: a travelling yaw wave down the body (thorax ↔ abdomen ↔ tail)"""
    st.set('thorax', tr(0, 0, lowz - 0.004 * math.cos(2 * w)) @ rz(amp * D2R * math.sin(w)))
    st.set('head', rz(-amp * 0.8 * D2R * math.sin(w - 0.6)))
    st.set('abd.1', rz(-amp * 1.1 * D2R * math.sin(w - 0.9)))
    st.set('abd.2', rz(-amp * 1.2 * D2R * math.sin(w - 1.7)))
    st.set('abd.3', rz(-amp * 1.4 * D2R * math.sin(w - 2.5)))


def _coil(st, f, n):
    """the telegraph: the front arches up and curls down over the edge in an S; the rear legs keep their grip"""
    t = f / (n - 1)
    a = smoothstep(0.0, 0.75, t)
    tremble = math.sin(f * 2.7) * smoothstep(0.3, 0.6, t)
    # the front pitches down over the edge about the waist (the thorax's head), the abdomen stays level on the route (abd.1
    # is the thorax's child: it counter-rotates; its x axis is −X, so −35° here is +35° of world pitch back), the waist the
    # highest point: the arch
    st.set('thorax', tr(0, 0.04 * a, 0.03 * a) @ rx((-38 * a + 2 * tremble) * D2R))
    st.set('abd.1', rx((-35 * a - 2 * tremble) * D2R))
    st.set('head', rx((-30 * a) * D2R) @ rz(3 * tremble * D2R))       # and curls further: the S
    st.set('abd.2', rx(6 * a * D2R))
    st.set('abd.3', rx(10 * a * D2R))
    _fangs(st, 34 * a + 6 * tremble)
    _feelers(st, -6 * a * D2R, -28 * a * D2R)
    _forceps(st, 18 * a * D2R, 22 * a * D2R)
    for lg in LEGS:
        if lg.k <= 2:
            # the forelegs let go and reach down over the edge toward the ring (the third pair half way)
            reach = _params(lg, 0.55 if lg.k == 0 else 0.25, -20 if lg.k < 2 else 10, -95, -110 if lg.k < 2 else -80)
            st.feet[lg.name] = ('p', _blendp(lg.rest[0], reach, a * (1.0 if lg.k < 2 else 0.6)))
        else:
            st.feet[lg.name] = ('ik', lg.F0 + np.array([lg.s * -0.04, 0.03, 0.0]) * a)
    st.glow.update(gland=1.0 + 1.6 * a, pulse=0.3 * a, wave=t * 3, eye=1.0 + 1.2 * a)


def _drop(st, f, n):
    t = f / (n - 1)
    st.set('root', tr(0, 0, 0))
    st.set('thorax', rx(8 * D2R) @ tr(0, 0, 0.02))
    st.set('head', rx(10 * D2R))
    st.set('abd.1', rx(4 * D2R))
    st.set('abd.2', rx(8 * D2R * (1 - t)))
    st.set('abd.3', rx(14 * D2R * (1 - t)))
    _fangs(st, 40)
    _feelers(st, -14 * D2R, -20 * D2R)
    _forceps(st, 24 * D2R, 28 * D2R)
    for lg in LEGS:
        # flung forward and out, splayed for the grab (the forelegs highest)
        st.feet[lg.name] = ('p', _params(lg, (0.5, 0.35, 0.15, 0.0, -0.15)[lg.k], (18, 12, 6, 2, -4)[lg.k], -38 - 6 * lg.k, -55))
    st.glow.update(gland=2.2, pulse=0.2, eye=2.0)


def _pin(st, f, n):
    """beside its marine: the front raised into it (fangs at hip height), forelegs hooked in, gnawing twice a loop; rear braced"""
    tau = f / n
    w = TWO * tau
    gnaw = max(0.0, math.sin(2 * w))
    lift = 42 + 3 * math.sin(2 * w + 0.4)
    st.set('thorax', tr(0, 0.06, 0.05) @ rx(lift * D2R) @ rz(4 * D2R * math.sin(w + 0.7)))
    st.set('abd.1', rx((lift - 2) * D2R) @ rz(2 * D2R * math.sin(w)))
    st.set('head', rx((10 - 6 * gnaw) * D2R) @ rz(5 * D2R * math.sin(2 * w)))
    st.set('abd.2', rx(-4 * D2R) @ rz(-3 * D2R * math.sin(w - 0.5)))
    st.set('abd.3', rx(-8 * D2R) @ rz(-5 * D2R * math.sin(w - 1.2)))
    _fangs(st, 30 - 26 * gnaw)
    _feelers(st, 12 * D2R, 16 * D2R + 5 * D2R * math.sin(w))
    _forceps(st, (10 + 6 * math.sin(w)) * D2R, 12 * D2R)
    for lg in LEGS:
        if lg.k <= 1:
            # hooked into the marine: reaching forward (level in the world: the body is pitched up 42°), curled in, working
            jit = 4 * math.sin(w * 2 + lg.k + (0 if lg.s > 0 else 1.6))
            st.feet[lg.name] = ('p', _params(lg, 0.6 - 0.2 * lg.k, -6 - 14 * lg.k + jit, -30 - 20 * lg.k + jit, -70))
        elif lg.k == 2:
            st.feet[lg.name] = ('p', _params(lg, 0.1, -30, -95, -95))
        else:
            st.feet[lg.name] = ('ik', lg.F0 + np.array([lg.s * 0.04, -0.03, 0.0]))
    st.glow.update(gland=1.6 + 0.4 * gnaw, pulse=0.3, wave=tau * 2, eye=1.6)


def _struggle(st, f, n):
    tau = f / n
    w = TWO * tau
    st.set('root', rz(14 * D2R * math.sin(w)))
    lift = 26 + 6 * math.sin(2 * w)
    st.set('thorax', tr(0, 0.04, 0.04) @ rx(lift * D2R) @ rz(10 * D2R * math.sin(w + 0.5)))
    st.set('abd.1', rx((lift - 4) * D2R) @ rz(-12 * D2R * math.sin(w - 0.6)))
    st.set('head', rx(10 * D2R * math.sin(2 * w + 0.3)) @ rz(-12 * D2R * math.sin(w + 1.1)))
    st.set('abd.2', rz(-16 * D2R * math.sin(w - 1.3)))
    st.set('abd.3', rz(-20 * D2R * math.sin(w - 2.0)) @ rx(-10 * D2R))
    _fangs(st, 20 + 18 * max(0.0, math.sin(3 * w)))
    _feelers(st, 16 * D2R * math.sin(w), 20 * D2R)
    _forceps(st, (16 + 10 * math.sin(2 * w)) * D2R, 20 * D2R)
    for lg in LEGS:
        seed = lg.k * 1.3 + (1.7 if lg.s > 0 else 0.0)
        flail = math.sin(w * 2 + seed)
        if lg.k <= 2:
            # the forelegs flail in the air (the front is raised), clear of the deck
            st.feet[lg.name] = ('p', _params(lg, 0.15 * flail, 18 + 14 * flail, -40 + 16 * math.sin(w * 2 + seed + 1), -55))
        else:
            # the rear braced on the deck, scrabbling
            st.feet[lg.name] = ('ik', lg.F0 + np.array([lg.s * 0.03 * flail, 0.04 * math.sin(w * 2 + seed + 0.5), 0.0]))
    st.glow.update(gland=2.0, pulse=0.6, wave=tau * 3, eye=2.0)


def _death_flip(st, f):
    K = [0, 1.0, 0.8, 0.5]
    k = K[f] if f < 4 else 0.0
    flip = smoothstep(2, 12, f)
    rho = math.pi * flip * 0.98
    cz, ea, eb = 0.13, 0.18, 0.08
    lift = roll_lift(rho, cz, ea, eb, flip) + 0.05 * math.sin(math.pi * min(max((f - 2) / 10, 0), 1))
    st.set('root', tr(-cz * math.sin(rho) - 0.1 * flip, -0.04 * flip, lift) @ rz(0.5 * flip) @ ry(rho))
    tw = sum(a * bell(f, t0, 1.5) for t0, a in ((16, 1.0), (22, 0.6)))
    st.set('thorax', tr(0, -0.04 * k, 0.02 * k) @ rx((10 * k - 12 * flip) * D2R) @ rz(8 * tw * D2R))
    st.set('head', rx((12 * k - 18 * flip) * D2R))
    st.set('abd.1', rx((-6 * k - 10 * flip + 6 * tw) * D2R))
    st.set('abd.2', rx((-14 * flip + 8 * tw) * D2R) @ rz(-6 * tw * D2R))
    st.set('abd.3', rx((-20 * flip + 10 * tw) * D2R))
    _fangs(st, 24 * k + 30 * flip - 14 * tw)
    _feelers(st, (10 * k + 18 * flip) * D2R, (-20 * flip + 10 * tw) * D2R)
    _forceps(st, (10 + 16 * flip) * D2R, (14 * flip - 8 * tw) * D2R)
    curl = smoothstep(8, 18, f)
    for lg in LEGS:
        seed = lg.k * 1.9 + (lg.s + 1) * 1.3
        jit = np.array([0.0, 0.4 * tw * math.sin(seed), -0.6 * tw, 0.7 * tw])
        # (planted only on the first frame: the recoil and the flip of a long body would overreach a planted foot)
        st.feet[lg.name] = ('mix2', lg.F0, lg.tuck_params() + jit * 0.5, 1.0 if f >= 1 else 0.0, lg.dead_params() + jit, curl)
    st.glow.update(gland=max(0.05, 1.6 * (1 - smoothstep(2, 22, f)) + 0.6 * tw), eye=max(0.04, 1 - smoothstep(2, 16, f)))


def clip_state(name, f, n):
    st = State()
    tau = f / n if name in LOOPS else f / (n - 1)
    w = TWO * tau
    if name == 'idle':
        st.set('thorax', tr(0, 0, 0.003 * math.sin(w)) @ rz(2 * D2R * math.sin(w)))
        st.set('head', rz(5 * D2R * math.sin(w + 0.8)) @ rx(3 * D2R * math.sin(2 * w)))
        st.set('abd.1', rz(-2 * D2R * math.sin(w - 0.5)))
        st.set('abd.2', rz(-3 * D2R * math.sin(w - 1.1)))
        st.set('abd.3', rz(-4 * D2R * math.sin(w - 1.7)) @ rx(3 * D2R * math.sin(2 * w)))
        _fangs(st, 6 + 10 * max(0.0, math.sin(2 * w)) ** 2)
        for s in SIDES:
            st.set(f'ant.{SN[s]}', rz(-s * 12 * D2R * math.sin(w + s * 0.9)) @ rx(8 * D2R * math.sin(w + 1.5)))
            st.set(f'cerc.{SN[s]}', rz(-s * 6 * D2R * math.sin(w + s * 0.6 + 1)) @ rx(4 * D2R * math.sin(2 * w)))
        for lg in LEGS:
            st.feet[lg.name] = ('ik', lg.F0)
        st.glow.update(gland=0.9, pulse=0.15, wave=tau, eye=1.0)
    elif name in ('walk', 'run'):
        run = name == 'run'
        duty, D, h = (0.44, 1.40, 0.13) if run else (0.62, 0.85, 0.09)
        _wriggle(st, w, 6.5 if run else 5, -0.02 if run else 0.0)
        _fangs(st, 8 + 4 * math.sin(2 * w))
        _feelers(st, (-14 if run else -4) * D2R + 4 * D2R * math.sin(w), (-10 if run else 0) * D2R + 5 * D2R * math.sin(2 * w + 0.4))
        _forceps(st, 6 * D2R * math.sin(w - 2.8), (6 if run else 3) * D2R)
        _wave_feet(st, tau, duty, D, h)
        st.glow.update(gland=0.95, pulse=0.1, wave=2 * tau)
    elif name == 'attack':
        t = tau
        up = smoothstep(0.0, 0.32, t) * (1 - smoothstep(0.4, 0.55, t))
        lunge = smoothstep(0.3, 0.5, t) * (1 - smoothstep(0.6, 1.0, t))
        snap = smoothstep(0.44, 0.5, t)
        rec = smoothstep(0.56, 1.0, t)
        st.set('root', tr(0, 0.22 * lunge, 0))
        st.set('thorax', tr(0, 0, 0.05 * up) @ rx((20 * up - 4 * lunge) * D2R))
        st.set('head', rx((10 * up - 6 * lunge) * D2R))
        st.set('abd.1', rx((18 * up - 3 * lunge) * D2R))
        _fangs(st, 38 * up * (1 - snap) - 6 * snap * (1 - rec))
        _feelers(st, 8 * D2R * up, -20 * D2R * up)
        _forceps(st, 10 * D2R * up, 14 * D2R * up)
        for lg in LEGS:
            if lg.k == 0:
                st.feet[lg.name] = ('p', _blendp(lg.rest[0], _params(lg, 0.35, 30, -40, -70), up + lunge))
            else:
                st.feet[lg.name] = ('ik', lg.F0)
        st.glow.update(gland=1.0 + 0.8 * up + 0.6 * lunge, eye=1.0 + 0.6 * up)
    elif name == 'hit':
        k = [0, 1.0, 0.86, 0.58, 0.28, 0.06, -0.1, -0.08, -0.03, 0.0][f]
        st.set('thorax', tr(0, -0.05 * k, 0.02 * k) @ rx(10 * k * D2R) @ ry(12 * k * D2R) @ rz(6 * k * D2R))
        st.set('head', rx(12 * k * D2R) @ rz(-8 * k * D2R))
        st.set('abd.1', rx(6 * k * D2R) @ rz(-6 * k * D2R))
        st.set('abd.2', rz(-8 * k * D2R))
        st.set('abd.3', rz(-10 * k * D2R))
        _fangs(st, 26 * k)
        _feelers(st, 10 * k * D2R, -24 * k * D2R)
        _forceps(st, 14 * k * D2R, 10 * k * D2R)
        for lg in LEGS:
            st.feet[lg.name] = ('ik', lg.F0 + np.array([lg.s * 0.04, 0.0, 0.0]) * max(k, 0))
        st.glow.update(gland=1.0 + 1.4 * max(k, 0), eye=1.0 + 1.0 * max(k, 0))
    elif name == 'coil':
        _coil(st, f, n)
    elif name == 'drop':
        _drop(st, f, n)
    elif name == 'pin':
        _pin(st, f, n)
    elif name == 'struggle':
        _struggle(st, f, n)
    elif name == 'death':
        _death_flip(st, f)
    elif name == 'death_burn':
        gen_death_burn(st, f, LEGS, _parts, 0.13, 0.18, 0.08)
        # a long body: a milder curl of the abdomen than the shared writhe (that one, made for a short runner, stood the
        # Dropper's tail up in the air as a corpse) — its writhe and twitches, a third of the curl
        writhe = 1 - smoothstep(6, 14, f)
        flip = smoothstep(6, 16, f)
        tw = sum(a * bell(f, t0, 1.2) for t0, a in ((17, 1.0), (21, 0.8), (26, 0.55), (31, 0.3)))
        st.set('abd.1', rx((-10 * math.sin(f * 1.5 + 1) * writhe - 10 * flip + 6 * tw) * D2R))
        st.set('abd.2', rx((-10 * flip + 8 * tw) * D2R) @ rz(8 * tw * D2R))
        st.set('abd.3', rx((-6 * flip + 6 * tw) * D2R))
        # (the legs go straight into the writhe — no planted IK while the long body spins: every leg reaches)
        for lg in LEGS:
            c = st.feet[lg.name]
            if c[0] == 'mix2':
                st.feet[lg.name] = ('mix2', c[1], c[2], 1.0, c[4], c[5])
    elif name == 'death_frost':
        gen_death_frost(st, f, LEGS, _parts, 0.13, 0.18, 0.08, rho_max=1.45)
    return st
