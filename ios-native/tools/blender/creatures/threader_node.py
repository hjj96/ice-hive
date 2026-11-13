"""A LANTERN NODE of the Threader (Stage 2 B2; design.md §1.5 «five lantern nodes (glowing sacs)»; B4: on segments 3 / 6 /
9 / 12 / 15, ×1.5 with their own 8 % pools, «behind their frost plates» up on the trunks in P1 / P2, exposed in P3) —
drawn in ITS SEGMENT'S MODEL SPACE: the same instance transform as threader_seg (and the same `thorax` bone, so the
segment's shudder and death, replayed here, keep it seated).

A pale pearl lantern sac (translucent: the SAC + gland flags, glowing from inside, five dark veins — the spitter's acid
lantern in pearl) bulges out of the middle of the segment's back under two hinged FROST SHUTTERS (rime-edged plates like
closed elytra): closed (`plated`) they leave a slit along the top where the light leaks — and the glint socket `sac`
shines through it —, open (`open`) they stand up at the sides and the whole bulb shows. Popped: the shutters slam open,
the bulb swells, flashes and bursts down into a torn dark HUSK (`pop`, held), then `dark`: the husk, the shutters
drooping, a dying ember flicker.

Skeleton (5 bones): root, thorax (= the segment's body bone), sac (the bulb: it scales into the husk), shut.L / shut.R
(hinged along the lateral keels, ±0.40 m, 0.72 m up). LOD0 ≤ 1000 / LOD1 ≤ 250 / LOD2 ≤ 100 triangles. Clips: plated /
open / pop / dark / stagger / stagger_dk / death / death_dk (the last four replay the segment's body motion: B5 starts
them with the segment's own stagger / death). Glow table (the gland channel): plated 0.8, open 1.4, pop flash 3.5, dark
0.03 — the lit / dark emission B5 gets without any parameter of its own (the instance glow boost adds on top).
"""
import math

import numpy as np

import ihv
from geo import Part, ellipsoid, smoothstep
from insect import D2R, F_GLAND, F_SAC, FPS, SIDES, SN, TWO, State, bone_frame, ry, sc3, socket_flags, tr
from threader_common import PAL, body_death, body_stagger, col, nrm, ramp, rime_crystals

NAME = 'threader_node'
SCALE = 1.0
SWITCH_PX = (24.0, 8.0, 0.0)
LOD_TRIS = ihv.BOSS_LOD_TRIS
TRI_TARGET = (1000, 250, 100)
FPS = FPS
LEGS = []

BULB_C = np.array([0.0, -0.15, 0.78])
BULB_R = np.array([0.36, 0.55, 0.26])
SAC_PIVOT = (0.0, -0.15, 0.70)
HINGE_X, HINGE_Z = 0.40, 0.72
SH_Y = (0.40, -0.66)


def skeleton():
    B = []

    def add(name, parent, head, tail):
        B.append((name, parent, bone_frame(head, tail), float(np.linalg.norm(np.subtract(tail, head)))))
    add('root', None, (0, 0, 0), (0, 0.25, 0))
    add('thorax', 'root', (0, 0, 0.36), (0, 0.9, 0.36))
    add('sac', 'thorax', SAC_PIVOT, (0, -0.15, 1.05))
    for s in SIDES:
        add(f'shut.{SN[s]}', 'thorax', (s * HINGE_X, SH_Y[0], HINGE_Z), (s * HINGE_X, SH_Y[1], HINGE_Z))
    return B


EXTRA_SOCKETS = [('sac', 'sac', (0.0, -0.15, 1.02), socket_flags(True, True, 0.12, 1.6)),
                 ('core', 'thorax', tuple(BULB_C), 0)]


def bulb(lod):
    nu, nv = ((14, 8), (8, 4), (6, 2))[lod]
    V, F = ellipsoid(tuple(BULB_C), tuple(BULB_R), nu, nv)
    # five dark veins along the bulb (the cage family), a hot crown on top
    ang = np.arctan2(V[:, 0] - BULB_C[0], (V[:, 2] - BULB_C[2]) + 1e-9)
    vein = np.zeros(len(V))
    if lod < 2:
        for a0 in (-1.1, -0.55, 0.0, 0.55, 1.1):
            vein = np.maximum(vein, np.clip(1 - np.abs(ang - a0) / (0.11 if lod == 0 else 0.16), 0, 1))
    top = np.clip((V[:, 2] - BULB_C[2]) / BULB_R[2], 0, 1)
    c = ramp(PAL['sac'], PAL['sac_hot'], top ** 2)
    c = c * (1 - 0.85 * vein[:, None]) + col(PAL['vein']) * 0.85 * vein[:, None]
    return Part('gland.sac', V, F, 'sac', PAL['sac'], glow=1.0, rough=0.25, smooth=True, sharp_deg=180, vcolor=c,
                flags=F_GLAND | F_SAC)


def husk(lod):
    """the burst sac: a torn, deflated dark membrane lying in the opened plates (inside the lit bulb, so the bulb
    collapsing into it is the pop)"""
    nu, nv = ((10, 4), (6, 2), (4, 1))[lod]
    V, F = ellipsoid((0.0, -0.15, 0.72), (0.31, 0.47, 0.1), nu, nv)
    rng = np.random.default_rng(9)
    jag = (rng.random(len(V)) - 0.5) * 0.05
    V[:, 2] += jag * (V[:, 2] > 0.72)
    t = np.clip((V[:, 2] - 0.66) / 0.14, 0, 1) * (0.4 + 0.6 * rng.random(len(V)))
    return Part('husk', V, F, 'thorax', PAL['husk'], rough=0.7, smooth=True, sharp_deg=60, vcolor=ramp(PAL['husk'], PAL['husk_vein'], t))


def shutter(s, lod):
    """a hinged frost shutter: an elliptic shell from its hinge (the lateral keel) up over the bulb to the midline, with
    a slit left at the top; dark plum outside, a pale rim, rime along the closing edge"""
    nu, nv = ((6, 5), (3, 2), (2, 1))[lod]
    rx, rz, th = 0.42, 0.40, 0.03
    V, F, C = [], [], []
    idx = {}
    for sh in (0, 1):
        for j in range(nv + 1):
            v = j / nv
            y = SH_Y[0] + (SH_Y[1] - SH_Y[0]) * v
            taper = 0.78 + 0.22 * math.sin(math.pi * v)
            for i in range(nu + 1):
                phi = math.radians(90 - 84 * i / nu)          # 90° = the hinge at the side, 6° = near the top
                r = 1.0 - (th / rx if sh else 0.0)
                x = s * rx * r * math.sin(phi) * (taper if i > 0 else 1.0)
                z = HINGE_Z + rz * r * math.cos(phi) * (taper if i > 0 else 1.0)
                idx[(sh, i, j)] = len(V)
                V.append((x, y, z))
                e = max(i / nu - 0.7, 0) / 0.3
                rim = max(0.0, 1 - min(v, 1 - v) * 7)
                c = col(PAL['plate']) * (1 - 0.6 * rim) + col(PAL['edge']) * 0.6 * rim
                c = c * (1 - 0.75 * e) + col(PAL['frost']) * 0.75 * e
                C.append(col(PAL['core']) if sh else c)
    for j in range(nv):
        for i in range(nu):
            o = [idx[(0, i, j)], idx[(0, i + 1, j)], idx[(0, i + 1, j + 1)], idx[(0, i, j + 1)]]
            q = [idx[(1, i, j)], idx[(1, i + 1, j)], idx[(1, i + 1, j + 1)], idx[(1, i, j + 1)]]
            if s < 0:
                F.append((o[0], o[1], o[2], o[3])); F.append((q[0], q[3], q[2], q[1]))
            else:
                F.append((o[0], o[3], o[2], o[1])); F.append((q[0], q[1], q[2], q[3]))
    ring = [(i, 0) for i in range(nu)] + [(nu, j) for j in range(nv)] + [(i, nv) for i in range(nu, 0, -1)] + \
           [(0, j) for j in range(nv, 0, -1)]
    for k in range(len(ring)):
        p, q = ring[k], ring[(k + 1) % len(ring)]
        f = (idx[(0, p[0], p[1])], idx[(0, q[0], q[1])], idx[(1, q[0], q[1])], idx[(1, p[0], p[1])])
        F.append(f[::-1] if s < 0 else f)
    return Part(f'shut.{SN[s]}', np.array(V), F, f'shut.{SN[s]}', PAL['plate'], rough=0.36, smooth=True, sharp_deg=45,
                vcolor=np.array(C), flags=4)


def build_parts(lod):
    P = [bulb(lod), husk(lod)]
    for s in SIDES:
        P.append(shutter(s, lod))
        if lod == 0:
            # rime along the shutter's closing edge and its outer face
            A = []
            for k, v in enumerate((0.15, 0.36, 0.58, 0.8)):
                y = SH_Y[0] + (SH_Y[1] - SH_Y[0]) * v
                taper = 0.78 + 0.22 * math.sin(math.pi * v)
                phi = math.radians(14 + 10 * (k % 2))
                A.append(((s * 0.42 * math.sin(phi) * taper, y, HINGE_Z + 0.40 * math.cos(phi) * taper), (s * math.sin(phi), 0, math.cos(phi))))
            P.append(rime_crystals(f'rime.{SN[s]}', f'shut.{SN[s]}', A, seed=31 + s, size=(0.04, 0.075)))
    return P


# ------------------------------------------------------------------ animation
GROUND_CLAMP = set()
LOOPS = ('plated', 'open', 'dark')
OPEN = 76.0          # deg: the shutters stand up at the sides
DROOP = 52.0         # deg: hanging open over a dead husk

CLIPS = [  # name, frames, loop, stride, event, notes
    ('plated', 60, True, 0.0, 0, 'lit behind its closed frost shutters: light leaks from the slit, the bulb breathes'),
    ('open', 60, True, 0.0, 0, 'exposed: the shutters stand open, the whole bulb glows and pulses'),
    ('pop', 30, False, 0.0, 6, 'popped: the shutters slam open, the bulb swells and flashes, bursts into the husk; held'),
    ('dark', 60, True, 0.0, 0, 'the dark husk: shutters drooping open, a dying ember flicker'),
    ('stagger', 45, False, 0.0, 0, 'lit, the segment\'s scream shudder: the shutters rattle, the light flickers'),
    ('stagger_dk', 45, False, 0.0, 0, 'dark, the segment\'s scream shudder'),
    ('death', 60, False, 0.0, 59, 'lit, the segment\'s death: the light dies, the shutters slump open; held'),
    ('death_dk', 60, False, 0.0, 59, 'dark, the segment\'s death; held'),
]


def _shut(st, ang_open):
    """both shutters `ang_open` degrees open (0 closed)"""
    for s in SIDES:
        st.set(f'shut.{SN[s]}', ry(-s * ang_open * D2R))


def _sac(st, k):
    st.set('sac', sc3(k, k, k))


def clip_state(name, f, n):
    st = State()
    tau = f / n if name in LOOPS else f / (n - 1)
    w = TWO * tau
    if name == 'plated':
        _shut(st, 1.5 + 1.5 * math.sin(w))
        _sac(st, 1.0 + 0.03 * math.sin(w))
        st.glow.update(gland=0.8, pulse=0.22, wave=tau, eye=1.0)
    elif name == 'open':
        _shut(st, OPEN + 3 * math.sin(w + 0.5))
        _sac(st, 1.0 + 0.05 * math.sin(w))
        st.glow.update(gland=1.4, pulse=0.35, wave=tau, eye=1.0)
    elif name == 'pop':
        snap = smoothstep(0, 3, f)
        fall = smoothstep(8, 22, f)
        _shut(st, 98 * snap * (1 - fall) + DROOP * fall)
        swell = 1.0 + 0.3 * smoothstep(0, 5, f)
        burst = smoothstep(5, 9, f)
        _sac(st, swell * (1 - burst) + 0.06 * burst)
        g = 3.5 * smoothstep(0, 4, f) * (1 - burst) + 1.0 * (1 - smoothstep(0, 1, f)) + 0.3 * burst * (1 - smoothstep(9, 20, f))
        st.glow.update(gland=max(0.03, g), pulse=0.0, eye=1.0)
    elif name == 'dark':
        _shut(st, DROOP + 2 * math.sin(w + 1.1))
        _sac(st, 0.06)
        st.glow.update(gland=0.03 + 0.03 * max(0.0, math.sin(3 * w)) ** 4, pulse=0.0, eye=1.0)
    elif name in ('stagger', 'stagger_dk'):
        M, env = body_stagger(f, n)
        st.set('thorax', M)
        if name == 'stagger':
            _shut(st, 2 + 9 * env * abs(math.sin(f * 1.9)))
            _sac(st, 1.0 + 0.06 * env)
            st.glow.update(gland=max(0.1, 0.9 + 0.7 * env * math.sin(f * 2.3)), pulse=0.2, eye=1.0)
        else:
            _shut(st, DROOP + 10 * env * math.sin(f * 1.7))
            _sac(st, 0.06)
            st.glow.update(gland=0.03, pulse=0.0, eye=1.0)
    elif name in ('death', 'death_dk'):
        M, sag = body_death(f, n)
        st.set('thorax', M)
        if name == 'death':
            _shut(st, 40 * smoothstep(8, 30, f))
            _sac(st, 1.0 - 0.15 * smoothstep(10, 40, f))
            st.glow.update(gland=max(0.02, 1.2 * (1 - smoothstep(4, 32, f)) + 0.6 * math.exp(-((f - 14) / 2.0) ** 2)), pulse=0.0,
                           eye=1.0)
        else:
            _shut(st, DROOP + 8 * smoothstep(8, 30, f))
            _sac(st, 0.06)
            st.glow.update(gland=0.02, pulse=0.0, eye=1.0)
    return st
