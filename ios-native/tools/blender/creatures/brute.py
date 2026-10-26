"""Brute («Громила») — the armoured charger: a dozer-blade shield, crusher forelimbs with bone clubs, a heavy body.

Frost's silhouette kept at the game's envelope (instance scale 2.0): a wide pronotum shield sloping forward over a
small head with crushing mandibles and ember eyes, a spiked lip, three heavy tergites, a dim translucent underbelly
between the legs, two thick crusher forelimbs (bone clubs) and four hind legs. Clips: idle / walk / run (heavy trot)
/ charge (the core's 12.5 m/s ram: head down, shield forward) / wind (the 0.8 s wind-up: rears back, scrapes, lowers
the shield) / attack (forelimb slam) / hit / death (collapses forward onto the shield) / death2 (topples on its side).
"""
import math

import numpy as np

from geo import Part, cone, ellipsoid, smoothstep, tube
from insect import (D2R, F_GLAND, F_SAC, FPS, SIDES, SN, TWO, Leg, State, bell, blob, bone_frame, col_ramp, eye, feet_gait,
                    feet_planted, gland, leg_parts, plate, roll_lift, rx, ry, rz, skeleton_legs, surface_z, tr)

NAME = 'brute'
SCALE = 2.0
SWITCH_PX = (80.0, 16.0, 0.0)

PAL = dict(plate=0x161b26, edge=0x3d4a5e, keel=0x252c3a, core=0x0e1016, belly=0x2a1820, leg=0x141820, leg_dist=0x262b38,
           joint=0x2e3444, claw=0xc8b8a6, mand=0x2c2a30, mand_tip=0xd8c8b4, ant=0x1c2028, ant_tip=0x4a5468,
           gland=0xff3c7a, gland_hot=0xffc6dc, gland_red=0xe0183a, eye=0xff7a20, sac=0x7a1830, bone=0xc8b8a6)

BODY_Z = 0.42


def _legs():
    spec = [  # (H y, F0 x, F0 y, L1, L2, L3)
        (0.34, 0.66, 0.86, 0.52, 0.50, 0.15),
        (0.06, 0.78, 0.06, 0.40, 0.44, 0.13),
        (-0.20, 0.66, -0.62, 0.40, 0.45, 0.13),
    ]
    out = []
    for i, (hy, fx, fy, l1, l2, l3) in enumerate(spec):
        for s in SIDES:
            out.append(Leg(i, s, C=(s * 0.2, hy, BODY_Z - 0.04), H=(s * 0.3, hy, BODY_Z - 0.06), F0=(s * fx, fy, 0.0),
                           L=(l1, l2, l3), beta=24.0, fore=(i == 0)))
    return out


LEGS = _legs()


def skeleton():
    B = []

    def add(name, parent, head, tail, zhint=(0, 0, 1)):
        B.append((name, parent, bone_frame(head, tail, zhint), float(np.linalg.norm(np.subtract(tail, head)))))
    z = BODY_Z
    add('root', None, (0, 0, 0), (0, 0.3, 0))
    add('thorax', 'root', (0, -0.1, z), (0, 0.45, z))
    add('head', 'thorax', (0, 0.48, z - 0.12), (0, 0.72, z - 0.16))
    for s in SIDES:
        add(f'mand.{SN[s]}', 'head', (s * 0.08, 0.66, z - 0.2), (s * 0.1, 0.86, z - 0.24))
    add('abd.1', 'thorax', (0, -0.12, z + 0.02), (0, -0.48, z + 0.0))
    add('abd.2', 'abd.1', (0, -0.48, z), (0, -0.86, z - 0.06))
    skeleton_legs(B, LEGS)
    return B


EXTRA_SOCKETS = [('mouth', 'head', (0, 0.84, BODY_Z - 0.24), 0), ('core', 'thorax', (0, 0.1, BODY_Z + 0.14), 0),
                 ('shield', 'thorax', (0, 0.5, BODY_Z + 0.32), 0), ('back', 'abd.1', (0, -0.4, BODY_Z + 0.24), 0)]


def _club(lg, H, K, A, F, n, lod):
    """the crusher forelimb's bone club: two hooked blades at the foot (fore legs only)"""
    if not lg.fore:
        return []
    d = np.array([math.cos(lg.rest[0][0]), math.sin(lg.rest[0][0]), 0.0])
    P = []
    sides = 4 if lod == 0 else 3
    for k, (fw, up, r) in enumerate(((0.16, 0.05, 0.05), (0.1, 0.12, 0.035))):
        b = A + (F - A) * 0.6
        tip = b + d * fw + np.array([0, 0, up]) + np.cross(n, d) * (0.04 if k else -0.02)
        P.append(Part(f'{lg.name}.club{k}', *cone(b, tip, r, sides), f'{lg.name}.tarsus', PAL['bone'], rough=0.35))
    if lod == 0:   # armour plate on the forearm
        mid = (K + A) / 2
        P.append(blob(f'{lg.name}.guard', f'{lg.name}.tibia', mid + np.array([0, 0, 0.04]), (0.09, 0.09, 0.17), 6, 3,
                      PAL['edge'], PAL['plate'], rough=0.35))
    return P


def build_parts(lod):
    P = []
    hi = lod == 0
    C = PAL
    z = BODY_Z
    # ---- thorax core + the dozer shield (sloping forward: lifted at the rear) + its spiked lip
    if lod < 2:
        P.append(blob('thorax.core', 'thorax', (0, 0.14, z - 0.02), (0.28, 0.34, 0.19), (12, 6)[lod], (6, 3)[lod], C['belly'], C['core'], rough=0.5))
        if hi:
            P.append(plate('shield', 'thorax', 12, 4, C, y0=0.66, length=0.66, a=(0.54, 0.52), b=(0.36, 0.38), zc=z, theta_deg=128,
                           thick=0.03, bulge=0.12, ridge=0.05, flare=0.12, lift=0.1, serr=0.03, skirt=0.1))
        else:   # LOD1: the shield as a smooth dome (a 4-facet shell plate flashes as a flat grey panel at game size)
            P.append(blob('shield', 'thorax', (0, 0.33, z + 0.05), (0.56, 0.4, 0.36), 8, 3, C['edge'], C['plate'], rough=0.34,
                          squash_bottom=0.35))
        if hi:
            P.append(plate('shield.lip', 'thorax', 12, 1, dict(C, plate=C['edge'], edge=C['claw']), y0=0.74, length=0.1, a=(0.56, 0.55),
                           b=(0.33, 0.35), zc=z - 0.02, theta_deg=132, thick=0.03, bulge=0.0, ridge=0.0, flare=0.0))
            for k in range(9):
                tt = -1.05 + k / 8 * 2.1
                x, zz = math.sin(tt) * 0.56, z - 0.02 + math.cos(tt) * 0.33
                b = np.array([x, 0.72, zz])
                P.append(Part(f'lipspike{k}', *cone(b, b + [x * 0.18, 0.16, -0.08 * math.cos(tt)], 0.035, 4), 'thorax',
                              C['bone'] if k % 2 else C['edge'], rough=0.35))
            for k in range(3):   # keel horns on the shield
                b = np.array([0, 0.42 - k * 0.2, z + 0.38 + k * 0.02])
                P.append(Part(f'horn{k}', *cone(b, b + [0, -0.06, 0.12 - k * 0.02], 0.045 - k * 0.008, 5), 'thorax', C['bone'], rough=0.3))
    else:
        # LOD2: the shield's value (LOD1's dome is the paler edge tone) and the tergites' plate → edge average on top
        P.append(blob('thorax.core', 'thorax', (0, 0.2, z + 0.06), (0.52, 0.5, 0.32), 6, 2, 0x323d52, C['belly'], rough=0.4))
    # ---- head under the shield, crushing mandibles, ember eyes
    hc = (0, 0.62, z - 0.16)
    if lod < 2:
        P.append(blob('head', 'head', hc, (0.17, 0.15, 0.12), (12, 5)[lod], (6, 2)[lod], C['plate'], C['core'], rough=0.4))
    else:
        P.append(blob('head', 'head', hc, (0.18, 0.16, 0.12), 4, 1, C['plate'], C['core'], rough=0.4))
    for s in SIDES:
        path = [(s * 0.08, 0.68, z - 0.2), (s * 0.15, 0.78, z - 0.22), (s * 0.12, 0.88, z - 0.25), (s * 0.03, 0.93, z - 0.26)]
        if hi:
            V, F = tube(path, [0.045, 0.04, 0.028, 0.0], 6, tip=True, flat=0.6)
            P.append(Part(f'mand.{SN[s]}', V, F, f'mand.{SN[s]}', C['mand'], rough=0.3,
                          vcolor=col_ramp(len(V), C['mand'], C['mand_tip'], np.clip(np.linspace(0, 1, len(V)) ** 1.5, 0, 1)), sharp_deg=60))
            for k, (dx, dy, dz, r) in enumerate(((0.11, 0.70, -0.1, 0.026), (0.15, 0.66, -0.12, 0.02))):
                P.append(eye(f'eye.{SN[s]}{k}', 'head', (s * dx, dy, z + dz), r, C, glow=0.95))
        elif lod == 1:
            V, F = tube([path[0], path[2], path[3]], [0.045, 0.028, 0.0], 3, tip=True, flat=0.6)
            P.append(Part(f'mand.{SN[s]}', V, F, f'mand.{SN[s]}', C['mand'], rough=0.3, sharp_deg=180))
            P.append(eye(f'eye.{SN[s]}', 'head', (s * 0.12, 0.69, z - 0.11), 0.028, C, glow=0.95))
        else:
            P.append(Part(f'mand.{SN[s]}', *cone(path[0], path[3], 0.045, 3), f'mand.{SN[s]}', C['mand'], rough=0.3, sharp_deg=180))
    # ---- abdomen: three heavy tergites, a dim translucent underbelly
    TG = [(-0.08, (0.44, 0.44), (0.27, 0.27), z + 0.02), (-0.34, (0.42, 0.36), (0.26, 0.23), z + 0.0), (-0.58, (0.34, 0.22), (0.22, 0.15), z - 0.04)]
    if lod < 2:
        P.append(blob('abd.core1', 'abd.1', (0, -0.3, z - 0.02), (0.34, 0.3, 0.2), (10, 5)[lod], (5, 2)[lod], C['belly'], C['core'], rough=0.5))
        P.append(blob('abd.core2', 'abd.2', (0, -0.62, z - 0.06), (0.26, 0.24, 0.16), (10, 5)[lod], (5, 2)[lod], C['belly'], C['core'], rough=0.5))
        use = TG if hi else TG[:2]
        for k, (y0, a, b, zc) in enumerate(use):
            P.append(plate(f'tergite{k}', 'abd.1' if k < 2 else 'abd.2', (10, 3)[lod], (2, 1)[lod], C, y0=y0, length=(0.28, 0.4)[lod] if k < 2 else 0.3,
                           a=a, b=b, zc=zc, theta_deg=120, thick=0.024, bulge=0.06, ridge=(0.04, 0.0)[lod], flare=(0.1, 0.0)[lod],
                           serr=(0.03, 0.0)[lod], skirt=(0.1, 0.0)[lod]))
            if hi:
                bt = np.array([0, y0 - 0.2, zc + b[1] + 0.03])
                P.append(Part(f'dspike{k}', *cone(bt, bt + [0, -0.1, 0.08], 0.035, 4), 'abd.1' if k < 2 else 'abd.2', C['bone'], rough=0.3))
        V, F = ellipsoid((0, -0.26, z - 0.18), (0.24, 0.36, 0.1), (10, 6)[lod], (5, 2)[lod])
        P.append(Part('belly.sac', V, F, 'abd.1', C['sac'], glow=0.1, rough=0.3, flags=F_SAC, sharp_deg=180))
    else:
        P.append(blob('abd', 'abd.1', (0, -0.4, z), (0.36, 0.42, 0.22), 4, 2, 0x252d3e, C['belly'], rough=0.4))
    # ---- pores along the plate seams (asymmetric)
    if lod < 2:
        seat = [p for p in P if p.name.startswith(('shield', 'tergite'))]
        pores = [(0.22, 0.30, 0.03, True), (-0.18, 0.18, 0.026, True), (0.34, 0.12, 0.022, True), (-0.36, 0.1, 0.024, True),
                 (0.08, -0.20, 0.028, True), (-0.22, -0.38, 0.024, True), (0.26, -0.50, 0.022, True), (-0.04, -0.66, 0.02, True),
                 (0.40, 0.34, 0.018, False), (-0.10, 0.48, 0.016, False)]
        for k, (x, y, r, hot) in enumerate(pores):
            if not hi and (not hot or k > 5):
                continue
            bone = 'thorax' if y > -0.1 else ('abd.1' if y > -0.5 else 'abd.2')
            zz = surface_z(seat, x, y) - 0.2 * r
            P.append(gland(f'gland.{k}', bone, (x, y, zz), r, C, hot=hot, red=not hot, glow=1.0 if hot else 0.7, glint=hot,
                           intensity=1.0 if hot else 0.6))
    # ---- legs (the forelimbs are crushers)
    for lg in LEGS:
        P.extend(leg_parts(lg, lod, C, thick=2.8 if lg.fore else 1.8, claw=_club))
    return P


# ------------------------------------------------------------------ animation
GROUND_CLAMP = {'death', 'death2', 'hit', 'attack', 'wind'}
CLIPS = [
    ('idle', 36, True, 0.0, 0, 'heavy breathing, the shield sways, mandibles grind, the forelimbs shift weight'),
    ('walk', 32, True, 0.72, 0, 'heavy tripod gait, duty 0.66, big bob, shield rolls'),
    ('run', 24, True, 1.15, 0, 'heavy trot, duty 0.52'),
    ('charge', 16, True, 1.9, 0, 'the ram: head down, shield forward, legs driving, duty 0.4'),
    ('wind', 24, False, 0.0, 23, 'the 0.8 s wind-up: rears back, scrapes the deck twice, lowers the shield'),
    ('attack', 20, False, 0.0, 11, 'forelimbs rise and slam down on the event frame, the body drops behind them'),
    ('hit', 8, False, 0.0, 1, 'a small heavy flinch'),
    ('death', 36, False, 0.0, 35, 'legs buckle, collapses forward onto the shield, rear settles, a roll, twitches'),
    ('death2', 36, False, 0.0, 35, 'topples onto its side, legs curl, twitches, the eyes go out'),
]


def _mands(st, a):
    for s in SIDES:
        st.set(f'mand.{SN[s]}', rz(-s * a * D2R))


def _death_fwd(st, f):
    k = [0, 1.0, 0.8, 0.5][f] if f < 4 else 0.0
    buckle = smoothstep(2, 12, f)
    nose = smoothstep(4, 14, f)
    roll = smoothstep(10, 20, f)
    tw = sum(a * bell(f, t0, 1.5) for t0, a in ((20, 1.0), (27, 0.6), (32, 0.35)))
    st.set('root', tr(0.03 * roll, 0.1 * nose, -0.2 * buckle) @ rx(-7 * D2R * nose) @ ry(12 * D2R * roll))
    st.set('thorax', tr(0, -0.04 * k, 0.03 * k) @ rx((8 * k) * D2R))
    st.set('head', rx((12 * k + 18 * nose) * D2R) @ rz(6 * tw * D2R))
    st.set('abd.1', rx((-6 * k + 10 * nose - 4 * tw) * D2R))
    st.set('abd.2', rx((14 * nose) * D2R) @ rz(5 * tw * D2R))
    _mands(st, 18 * k + 30 * nose - 14 * tw)
    for lg in LEGS:
        kick = tw * (1.0 if (lg.i + (lg.s > 0)) % 2 else 0.35)
        jitter = np.array([0.0, 0.25 * kick, -0.45 * kick, 0.5 * kick])
        st.feet[lg.name] = ('mix', lg.F0 + np.array([lg.s * 0.05, 0, 0]) * k, lg.splay_params() + jitter, buckle)
    fade = 1 - smoothstep(4, 30, f)
    st.glow.update(gland=max(0.05, (1.0 + 1.2 * k) * (0.08 + 0.92 * fade) + 0.7 * bell(f, 20, 0.8) * fade),
                   eye=max(0.05, 1 - smoothstep(3, 22, f)))


def _death_side(st, f):
    k = [0, 1.0, 0.8, 0.5][f] if f < 4 else 0.0
    top = smoothstep(4, 16, f)
    rho = 1.45 * top
    lift = roll_lift(rho, BODY_Z * 0.9, 0.5, 0.32, top)
    tw = sum(a * bell(f, t0, 1.4) for t0, a in ((21, 1.0), (27, 0.7), (32, 0.4)))
    st.set('root', tr(-0.2 * math.sin(rho), 0.02 * top, lift - 0.12 * top) @ ry(rho))
    st.set('thorax', tr(0, -0.05 * k, 0.02 * k) @ rx(8 * k * D2R) @ ry(-6 * tw * D2R))
    st.set('head', rx((10 * k + 14 * top) * D2R) @ rz(-12 * top * D2R))
    st.set('abd.1', rx((-8 * top + 5 * tw) * D2R) @ rz(8 * top * D2R))
    st.set('abd.2', rx((-10 * top) * D2R))
    _mands(st, 20 * k + 26 * top - 12 * tw)
    tuck = smoothstep(1.5, 5, f)
    curl = smoothstep(8, 20, f)
    for lg in LEGS:
        seed = lg.i * 1.7 + (lg.s + 1) * 2.3
        twl = tw * (0.6 + 0.4 * math.sin(seed * 3.1))
        jitter = np.array([0.0, 0.3 * twl, -0.5 * twl, 0.6 * twl])
        st.feet[lg.name] = ('mix2', lg.F0 + np.array([lg.s * 0.05, 0, 0]) * k, lg.crumple_params() + jitter * 0.5, tuck,
                            lg.dead_params() + jitter, curl)
    fade = 1 - smoothstep(4, 30, f)
    st.glow.update(gland=max(0.05, (1.0 + 1.2 * k) * (0.08 + 0.92 * fade) + 0.6 * bell(f, 21, 0.8) * fade),
                   eye=max(0.05, 1 - smoothstep(3, 24, f)))


def clip_state(name, f, n):
    st = State()
    tau = f / n if name in ('idle', 'walk', 'run', 'charge') else f / (n - 1)
    if name == 'idle':
        w = TWO * tau
        st.set('thorax', tr(0, 0, 0.012 * math.sin(w)) @ rx(1.5 * D2R * math.sin(w)) @ ry(2.5 * D2R * math.sin(w + 0.6)))
        st.set('head', rz(6 * D2R * math.sin(w + 0.8)) @ rx(3 * D2R * math.sin(2 * w)))
        st.set('abd.1', rx(-2 * D2R * math.sin(w - 0.6)))
        st.set('abd.2', rx(-2.5 * D2R * math.sin(w - 1.2)))
        _mands(st, 8 + 12 * max(0.0, math.sin(2 * w)) ** 2)
        feet_planted(st, LEGS, lambda lg: np.array([0, 0.03 * math.sin(w + lg.s), 0.04 * max(0, math.sin(w + lg.s * 1.5))]) if lg.fore else 0.0)
        st.glow.update(gland=0.8, pulse=0.25, wave=tau)
    elif name in ('walk', 'run', 'charge'):
        w = TWO * tau
        duty, D, h, bob, pitch = {'walk': (0.66, 0.72, 0.1, 0.025, 0), 'run': (0.52, 1.15, 0.14, 0.04, -4),
                                  'charge': (0.4, 1.9, 0.16, 0.05, -6)}[name]
        zb = -bob * math.cos(2 * w) - (0.06 if name == 'charge' else 0.0)
        st.set('thorax', tr(0, 0, zb) @ rz(4 * D2R * math.sin(w + 0.4)) @ rx((pitch + 2 * math.sin(2 * w + 0.6)) * D2R) @ ry(5 * D2R * math.sin(w)))
        st.set('head', rx((-pitch * 0.5 - 2 * math.sin(2 * w + 1.4)) * D2R) @ rz(-3 * D2R * math.sin(w + 0.4)))
        st.set('abd.1', rz(-4 * D2R * math.sin(w - 0.5)) @ rx((2 + 2 * math.sin(2 * w - 0.2)) * D2R))
        st.set('abd.2', rz(-5 * D2R * math.sin(w - 1.2)) @ rx(2.5 * D2R * math.sin(2 * w - 0.9)))
        _mands(st, (16 if name == 'charge' else 6) + 6 * (0.5 + 0.5 * math.sin(2 * w)))
        feet_gait(st, LEGS, tau, duty, D, h, fb=0.04 if name != 'walk' else 0.0)
        st.glow.update(gland=0.9 if name != 'charge' else 1.4, pulse=0.2, wave=2 * tau)
    elif name == 'wind':
        t = tau
        rear = smoothstep(0.0, 0.35, t) * (1 - smoothstep(0.7, 0.95, t))
        lower = smoothstep(0.7, 0.95, t)
        scrape = math.sin(math.pi * 2 * min(1, max(0, (t - 0.2) / 0.5))) * (0.2 < t < 0.7)
        st.set('root', tr(0, -0.1 * rear - 0.04 * lower, 0))
        st.set('thorax', tr(0, 0, 0.05 * rear) @ rx((16 * rear - 4 * lower) * D2R))
        st.set('head', rx((10 * rear - 8 * lower) * D2R))
        st.set('abd.1', rx((8 * rear) * D2R))
        _mands(st, 10 + 34 * rear + 16 * lower)
        for lg in LEGS:
            off = np.zeros(3)
            if lg.fore and lg.s > 0:
                off = np.array([0.0, -0.22 * scrape, 0.08 * max(0.0, math.sin(math.pi * 4 * t))])
            elif lg.fore:
                off = np.array([0.0, 0.05 * rear, 0.0])
            st.feet[lg.name] = ('ik', lg.F0 + off + np.array([0, -0.05 * rear, 0]))
        st.glow.update(gland=1.0 + 1.4 * smoothstep(0.3, 1.0, t), pulse=0.3, wave=t * 3, eye=1.0 + 0.8 * lower)
    elif name == 'attack':
        t = tau
        up = smoothstep(0.0, 0.45, t) * (1 - smoothstep(0.5, 0.58, t))
        slam = smoothstep(0.5, 0.58, t) * (1 - smoothstep(0.65, 1.0, t))
        st.set('root', tr(0, 0.06 * slam - 0.05 * up, 0))
        st.set('thorax', tr(0, 0, 0.12 * up - 0.02 * slam) @ rx((22 * up - 3 * slam) * D2R))
        st.set('head', rx((8 * up - 10 * slam) * D2R))
        st.set('abd.1', rx((10 * up) * D2R))
        _mands(st, 30 * up)
        for lg in LEGS:
            if lg.fore:
                st.feet[lg.name] = ('ik', lg.F0 + np.array([lg.s * -0.1, 0.0, 0.5]) * up + np.array([0, 0.16, 0]) * slam)
            else:
                st.feet[lg.name] = ('ik', lg.F0 + np.array([0, 0.04 * up, 0]))
        st.glow.update(gland=1.0 + 1.0 * up + 0.8 * slam)
    elif name == 'hit':
        k = [0, 1.0, 0.7, 0.35, 0.1, -0.05, -0.03, 0.0][f]
        st.set('thorax', tr(0, -0.04 * k, 0.015 * k) @ rx(5 * k * D2R) @ ry(6 * k * D2R))
        st.set('head', rx(8 * k * D2R))
        st.set('abd.1', rx(4 * k * D2R))
        _mands(st, 8 + 16 * k)
        feet_planted(st, LEGS)
        st.glow.update(gland=1.0 + 1.2 * max(k, 0))
    elif name == 'death':
        _death_fwd(st, f)
    elif name == 'death2':
        _death_side(st, f)
    return st
