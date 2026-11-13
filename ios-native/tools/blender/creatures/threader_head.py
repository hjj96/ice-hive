"""The Threader's HEAD (Stage 2 B2; design.md §1.5) — armoured and insect-like, from the Runner's family: a broad wedge
cranium under a serrated frost-rimmed shield that flares into spiked cheek plates, three pale ocelli a side, a pair of
big sickle MANDIBLES each SPLIT into two tines (they open sideways, never a round toothed maw), a swept CREST of stacked
frost plates over a soft pale membrane (the punish window's weak point: the crest lifts off it while the head is down;
it alone uses the glow table's eye channel, dark outside `down` / `recover`; the ocelli glow with the lantern's gland
channel),
and the LANTERN ORGAN — the two antennae fused into one ringed whip that rises from the brow, arches forward over the
jaws and hangs a pale pearl bulb in a cage of dark ribs (the spitter's acid lantern, in pearl): the lure that carries
the beam. A neck collar behind it meets segment 1.

Origin: the head point on the body path (B4's head position: on a trunk the pipe top; down on the deck 0.5 m above it;
in the deck chase 0.6 m above it); +Y forward. The BACK attach point is (0, -1.2, 0) (socket `back`, root bone): B5 lays
the head on the chord from bossBodyPoint(behind: 1.2) to the head point, so it meets segment 1's front attach. Every
bone from `head` down carries the swarm's head look group: B5 aims the lure with the per-instance head look yaw / pitch
(±0.8 rad) about the `neck` socket (0, -0.5, 0.5) and the `lantern` socket (the beam's origin, a glint) turns with it.

Skeleton (12 bones): root, thorax (the neck collar), head, crest, mand.L / mand.R, lure.1-3, lantern, palp.L / palp.R.
LOD0 ≤ 8000 / LOD1 ≤ 1200 / LOD2 ≤ 400 triangles (the boss gate). Clips (B4's modes): idle, sweep (the hunt: head low,
the lure swinging), strike (1.2 s: rears, then the drop — the slam on the last frame), down (2 s loop: lying, the crest
up off the glowing membrane, the lantern dim), recover, scream (and the stagger), coil, pull (clamped on a trunk,
wrenching), charge (P3, low and fast), strike_low (P3: 0.6 s), death (held), hit.
"""
import math

import numpy as np

import ihv
from geo import Part, cone, ellipsoid, octa, smoothstep, tube
from insect import D2R, F_EYE, F_GLAND, F_SAC, FPS, SIDES, SN, TWO, State, bone_frame, rx, ry, rz, sc3, socket_flags, tr
from threader_common import NECK_BACK, PAL, col, ramp, rime_crystals, spike, tergite

NAME = 'threader_head'
SCALE = 1.0
SWITCH_PX = (90.0, 20.0, 0.0)
LOD_TRIS = ihv.BOSS_LOD_TRIS
TRI_TARGET = (8000, 1200, 400)
FPS = FPS
LEGS = []

BULB_C = np.array([0.0, 2.16, 0.98])
BULB_R = np.array([0.17, 0.17, 0.22])
LURE = [(0.0, 0.62, 0.92), (0.0, 1.02, 1.36), (0.0, 1.62, 1.58), (0.0, 2.12, 1.42)]
LANTERN_TOP = (0.0, 2.15, 1.30)
# the head is authored at 1 and drawn ×1.35 about the neck pivot (B4's head circle is 1.1 m against the segment's 0.75: the
# boss's head must read bigger than its body); the neck collar (`thorax`) keeps the body's size to meet segment 1
HS = 1.35
NECK = np.array([0.0, -0.5, 0.5])
HEAD_BONES = {'head', 'crest', 'mand.L', 'mand.R', 'lure.1', 'lure.2', 'lure.3', 'lantern', 'palp.L', 'palp.R'}
HEAD_PLATE, HEAD_EDGE = 0x2a2034, 0x6e5c80      # the head's armour a step paler than the body's


def hs(p):
    return NECK + (np.asarray(p, dtype=np.float64) - NECK) * HS


def skeleton():
    B = []

    def add(name, parent, head, tail):
        if name in HEAD_BONES:
            head, tail = hs(head), hs(tail)
        B.append((name, parent, bone_frame(head, tail), float(np.linalg.norm(np.subtract(tail, head)))))
    add('root', None, (0, 0, 0), (0, 0.25, 0))
    add('thorax', 'root', (0, -1.2, 0.36), (0, -0.5, 0.4))
    add('head', 'thorax', (0, -0.5, 0.5), (0, 0.9, 0.5))
    add('crest', 'head', (0, 0.05, 1.0), (0, -0.8, 1.55))
    for s in SIDES:
        add(f'mand.{SN[s]}', 'head', (s * 0.46, 1.0, 0.32), (s * 0.28, 1.9, 0.28))
    add('lure.1', 'head', LURE[0], LURE[1])
    add('lure.2', 'lure.1', LURE[1], LURE[2])
    add('lure.3', 'lure.2', LURE[2], LURE[3])
    add('lantern', 'lure.3', LANTERN_TOP, (0.0, 2.17, 0.78))
    for s in SIDES:
        add(f'palp.{SN[s]}', 'head', (s * 0.30, 1.0, 0.2), (s * 0.36, 1.38, 0.13))
    return B


SHIELD = dict(y0=1.12, length=1.74, half=(0.42, 0.76), zt=(0.74, 0.88), rise=0.06, flare=0.10, keel=0.06)
NECK1 = dict(y0=-0.48, length=0.46, half=(0.64, 0.62), zt=(0.66, 0.64), rise=0.03, flare=0.04, keel=0.04)
NECK2 = dict(y0=-0.86, length=0.38, half=(0.58, 0.56), zt=(0.60, 0.60), rise=0.02, flare=0.04, keel=0.03)
EXTRA_SOCKETS = [('lantern', 'lantern', tuple(hs(BULB_C)), socket_flags(True, True, 0.18, 2.4)),
                 ('back', 'root', (0.0, -NECK_BACK, 0.0), 0),
                 ('mouth', 'head', tuple(hs((0.0, 1.75, 0.3))), 0),
                 ('crest', 'crest', tuple(hs((0.0, -0.78, 1.72))), 0),
                 ('weak', 'head', tuple(hs((0.0, -0.3, 0.95))), 0),
                 ('core', 'head', tuple(hs((0.0, 0.3, 0.55))), 0)]


def mandible(s, lod):
    """a sickle mandible SPLIT into two tines near its end (an upper tine branching up-forward), an inner tooth row,
    dark at the base, pale toward the points"""
    P = []
    bone = f'mand.{SN[s]}'
    path = [(s * 0.46, 1.0, 0.32), (s * 0.6, 1.3, 0.31), (s * 0.58, 1.6, 0.29), (s * 0.42, 1.85, 0.27), (s * 0.2, 2.02, 0.25),
            (s * 0.05, 2.08, 0.24)]
    if lod == 0:
        V, F = tube(path, [0.13, 0.12, 0.1, 0.075, 0.045, 0.0], 10, tip=True, flat=0.55)
        t = np.repeat(np.linspace(0, 1, 6), 8)[:len(V)]
        t = np.concatenate([t, np.ones(len(V) - len(t))])
        P.append(Part(bone, V, F, bone, PAL['mand'], rough=0.28, sharp_deg=55, vcolor=ramp(PAL['mand'], PAL['mand_tip'], t ** 1.8)))
        b = np.array(path[2]) * 0.4 + np.array(path[3]) * 0.6
        tine = [b, b + np.array([-s * 0.06, 0.16, 0.08]), b + np.array([-s * 0.13, 0.3, 0.12]), b + np.array([-s * 0.2, 0.38, 0.12])]
        V, F = tube(tine, [0.06, 0.045, 0.025, 0.0], 6, tip=True, flat=0.6)
        t = np.linspace(0, 1, len(V)) ** 1.4
        P.append(Part(bone + '.tine', V, F, bone, PAL['mand'], rough=0.28, sharp_deg=55, vcolor=ramp(PAL['mand'], PAL['mand_tip'], t)))
        for k, f in enumerate((0.2, 0.36, 0.52, 0.68)):
            i = int(f * (len(path) - 1))
            q = np.array(path[i]) * (1 - (f * (len(path) - 1) - i)) + np.array(path[min(i + 1, len(path) - 1)]) * (f * (len(path) - 1) - i)
            inward = np.array([-s, 0.15, -0.05])
            P.append(spike(f'{bone}.tooth{k}', bone, q, q + inward * (0.09 - 0.012 * k), 0.025, 4, c0=PAL['mand'], c1=PAL['mand_tip']))
    elif lod == 1:
        V, F = tube(path[::2] + [path[-1]], [0.12, 0.09, 0.04, 0.0], 4, tip=True, flat=0.55)
        t = np.linspace(0, 1, len(V)) ** 1.6
        P.append(Part(bone, V, F, bone, PAL['mand'], rough=0.3, sharp_deg=180, vcolor=ramp(PAL['mand'], PAL['mand_tip'], t)))
        b = np.array(path[3])
        V, F = cone(b, b + np.array([-s * 0.2, 0.36, 0.13]), 0.05, 3)
        P.append(Part(bone + '.tine', V, F, bone, PAL['mand'], rough=0.3, sharp_deg=180,
                      vcolor=ramp(PAL['mand'], PAL['mand_tip'], np.array([0, 0, 0, 1.0]))))
    else:
        V, F = tube([path[0], path[2], path[5]], [0.12, 0.07, 0.0], 3, tip=True, flat=0.6)
        t = np.linspace(0, 1, len(V)) ** 1.5
        P.append(Part(bone, V, F, bone, PAL['mand'], rough=0.3, sharp_deg=180, vcolor=ramp(PAL['mand'], PAL['mand_tip'], t)))
    return P


def lure(lod):
    """the fused antennal whip (three bones, ringed) and the lantern: a pearl bulb (SAC + gland: it glows from inside)
    in a cage of six dark ribs under a cap"""
    P = []
    rings = 5 if lod == 0 else 1
    for k in range(3):
        a, b = np.array(LURE[k]), np.array(LURE[k + 1])
        r0, r1 = (0.085, 0.07, 0.056)[k], (0.07, 0.056, 0.042)[k]
        if lod == 0:
            pts, rs = [], []
            for i in range(rings * 2 + 1):
                f = i / (rings * 2)
                pts.append(a + (b - a) * f + np.array([0, 0, 0.0]))
                rr = r0 + (r1 - r0) * f
                rs.append(rr * (1.18 if i % 2 == 1 else 1.0))
            V, F = tube(pts, rs, 8)
        else:
            V, F = tube([a, b], [r0, r1], 4 if lod == 1 else 3, cap0=False, cap1=False)
        t = np.linspace(0, 1, len(V))
        P.append(Part(f'lure.{k + 1}', V, F, f'lure.{k + 1}', PAL['leg_dist'], rough=0.4, sharp_deg=70,
                      vcolor=ramp(PAL['joint'], PAL['leg_dist'], t)))
    # the pedicel and the cap
    top = np.array(LANTERN_TOP)
    if lod < 2:
        V, F = tube([np.array(LURE[3]), top, top - np.array([0, 0, 0.06])], [0.034, 0.03, 0.06], 5 if lod == 0 else 3)
        P.append(Part('lantern.stem', V, F, 'lantern', PAL['rib'], rough=0.4, sharp_deg=80))
    nu, nv = ((16, 9), (8, 4), (5, 2))[lod]
    V, F = ellipsoid(tuple(BULB_C), tuple(BULB_R), nu, nv)
    hot = np.exp(-np.sum(((V - BULB_C) / (BULB_R * 0.9)) ** 2, axis=1) * 1.2)
    c = ramp(PAL['lantern'], PAL['lantern_hot'], 0.4 + 0.6 * hot)
    P.append(Part('gland.lantern', V, F, 'lantern', PAL['lantern'], glow=1.0, rough=0.22, smooth=True, sharp_deg=180, vcolor=c,
                  flags=F_GLAND | F_SAC))
    if lod == 0:
        for k in range(6):
            a = 2 * math.pi * k / 6 + 0.3
            pts = []
            for i in range(6):
                th = math.pi * (0.06 + 0.88 * i / 5)
                r = 1.0 + 0.05
                pts.append(BULB_C + np.array([math.cos(a) * BULB_R[0] * math.sin(th) * r, math.sin(a) * BULB_R[1] * math.sin(th) * r,
                                              BULB_R[2] * math.cos(th) * 1.04]))
            V, F = tube(pts, [0.016, 0.02, 0.02, 0.02, 0.018, 0.012], 4, cap0=False)
            P.append(Part(f'lantern.rib{k}', V, F, 'lantern', PAL['rib'], rough=0.4, sharp_deg=80))
        V, F = cone(BULB_C - np.array([0, 0, BULB_R[2] * 0.96]), BULB_C - np.array([0, 0, BULB_R[2] * 1.5]), 0.05, 5)
        P.append(Part('lantern.drip', V, F, 'lantern', PAL['rib'], rough=0.4, sharp_deg=80))
    elif lod == 1:
        for k in range(3):
            a = 2 * math.pi * k / 3 + 0.3
            pts = [BULB_C + np.array([math.cos(a) * BULB_R[0] * math.sin(th) * 1.06, math.sin(a) * BULB_R[1] * math.sin(th) * 1.06,
                                      BULB_R[2] * math.cos(th) * 1.04]) for th in (0.3, 1.57, 2.84)]
            V, F = tube(pts, [0.02, 0.022, 0.016], 3, cap0=False, cap1=False)
            P.append(Part(f'lantern.rib{k}', V, F, 'lantern', PAL['rib'], rough=0.4, sharp_deg=180))
    return P


def crest(lod):
    """the crest: three stacked swept-back frost plates (wedge blades with a serrated top edge, the rearmost tallest),
    rime along the tops; and under its base the soft pale membrane (eye-channel glow: it shows when the crest lifts)"""
    P = []
    blades = [((0.0, 0.32, 0.86), (0.0, -0.32, 1.32), 0.11), ((0.0, 0.05, 0.9), (0.0, -0.6, 1.56), 0.1),
              ((0.0, -0.22, 0.9), (0.0, -0.86, 1.76), 0.085)]
    for k, (a, b, w) in enumerate(blades):
        a, b = np.array(a), np.array(b)
        n = 7 if lod == 0 else 3
        top, bot = [], []
        for i in range(n + 1):
            f = i / n
            p = a + (b - a) * f
            lift = 0.18 * math.sin(math.pi * min(1, f * 1.15)) * (1 - 0.3 * f)
            ser = (0.05 if (i % 2 == 1 and lod == 0) else 0.0) * (1 - f)
            top.append(p + np.array([0, 0.03, lift + ser]))
            bot.append(a + (b - a) * f * 0.55 + np.array([0, -0.0, -0.06]) * (1 - f))
        V, F = [], []
        half = []
        for i in range(n + 1):
            ww = w * (1 - 0.85 * i / n)
            for x in (-ww, ww):
                V.append(top[i] + np.array([x * 0.25, 0, 0]))
                V.append(bot[i] + np.array([x, 0, 0]))
        # quads: each station has 4 verts (topL, botL, topR, botR)
        for i in range(n):
            o = 4 * i
            q = 4 * (i + 1)
            F.append((o + 0, o + 1, q + 1, q + 0))          # left flank
            F.append((o + 2, q + 2, q + 3, o + 3))          # right flank
            F.append((o + 0, q + 0, q + 2, o + 2))          # top edge
            F.append((o + 1, o + 3, q + 3, q + 1))          # underside
        F.append((0, 2, 3, 1))
        F.append((4 * n, 4 * n + 1, 4 * n + 3, 4 * n + 2))
        V = np.array(V)
        hgt = np.clip((V[:, 2] - 0.85) / 0.9, 0, 1)
        c = ramp(PAL['plate'], PAL['edge'], hgt * 0.8)
        topv = np.array([1, 0, 1, 0] * (n + 1), dtype=float)
        c = c * (1 - 0.55 * topv[:, None] * hgt[:, None]) + col(PAL['frost']) * 0.55 * topv[:, None] * hgt[:, None]
        P.append(Part(f'crest{k}', V, F, 'crest', PAL['plate'], rough=0.34, smooth=False, sharp_deg=30, vcolor=c, flags=4))
    if lod == 0:
        A = []
        for k, (a, b, w) in enumerate(blades):
            a, b = np.array(a), np.array(b)
            for f in (0.35, 0.62, 0.85):
                p = a + (b - a) * f + np.array([0, 0.03, 0.18 * math.sin(math.pi * min(1, f * 1.15)) * (1 - 0.3 * f)])
                A.append((p, (0.0, -0.3, 1.0)))
        P.append(rime_crystals('crest.rime', 'crest', A, seed=41, size=(0.04, 0.08)))
    # the sheath: a narrow frost plate on the crest bone lying over the membrane (it lifts with the crest)
    P.append(tergite('crest.sheath', 'crest', nv=(4 if lod == 0 else 1), serr=(0.03 if lod == 0 else 0.0), frost=0.35, thick=0.03,
                     lod=min(lod, 1), y0=0.32, length=1.1, half=(0.17, 0.22), zt=(0.935, 0.975), rise=0.02, flare=0.06, keel=0.025,
                     depth=0.38))
    # the membrane (on the head bone: the crest lifts off it)
    nu, nv = ((10, 4), (6, 2), (4, 1))[lod]
    V, F = ellipsoid((0.0, -0.25, 0.86), (0.13, 0.45, 0.07), nu, nv)      # (wholly under the sheath until the crest lifts)
    P.append(Part('membrane', V, F, 'head', PAL['membrane'], glow=0.7, rough=0.3, smooth=True, sharp_deg=180,
                  vcolor=np.tile(col(PAL['membrane']), (len(V), 1)), flags=F_EYE))
    return P


def build_parts(lod):
    P = []
    C = PAL
    # ---- the cranium and the gula
    nu, nv = ((20, 9), (8, 3), (6, 2))[lod]
    V, F = ellipsoid((0, 0.32, 0.5), (0.66, 0.9, 0.36), nu, nv, squash_bottom=0.72)
    P.append(Part('cranium', V, F, 'head', C['core'], rough=0.5, vcolor=ramp(C['belly'], C['core'], np.clip((V[:, 2] - 0.2) / 0.5, 0, 1))))
    if lod < 2:
        V, F = ellipsoid((0, 0.32, 0.26), (0.48, 0.7, 0.09), (12 if lod == 0 else 6), (3 if lod == 0 else 1), squash_bottom=0.6)
        P.append(Part('gula', V, F, 'head', C['belly'], rough=0.5))
    # ---- the shield and the neck collar
    if lod == 0:
        P.append(tergite('shield', 'head', nv=12, serr=0.07, frost=0.85, thick=0.05, plate_col=HEAD_PLATE, edge_col=HEAD_EDGE, **SHIELD))
        P.append(tergite('neck1', 'thorax', nv=3, serr=0.04, frost=0.4, thick=0.04, **NECK1))
        P.append(tergite('neck2', 'thorax', nv=2, serr=0.03, frost=0.3, thick=0.04, **NECK2))
        P.append(Part('neckcore', *ellipsoid((0, -0.8, 0.36), (0.5, 0.5, 0.26), 10, 4), 'thorax', C['core'], rough=0.55))
    elif lod == 1:
        P.append(tergite('shield', 'head', nv=3, serr=0.0, frost=0.6, thick=0.06, lod=1, plate_col=HEAD_PLATE, edge_col=HEAD_EDGE, **SHIELD))
        P.append(tergite('neck1', 'thorax', nv=1, serr=0.0, frost=0.2, thick=0.05, lod=1, **NECK1))
        P.append(Part('neckcore', *ellipsoid((0, -0.8, 0.36), (0.5, 0.5, 0.26), 5, 2), 'thorax', C['core'], rough=0.55))
    else:
        P.append(tergite('shield', 'head', nv=2, serr=0.0, frost=0.5, thick=0.07, lod=1, plate_col=HEAD_PLATE, edge_col=HEAD_EDGE, **SHIELD))
        P.append(Part('neckcore', *ellipsoid((0, -0.8, 0.4), (0.55, 0.5, 0.28), 4, 1), 'thorax', C['plate'], rough=0.5))
    # ---- the cheek plates: spiked corners at the rear sides (the silhouette from above)
    for s in SIDES:
        if lod == 0:
            V, F = ellipsoid((s * 0.62, -0.05, 0.42), (0.2, 0.5, 0.2), 8, 3)
            c = ramp(C['plate'], C['edge'], np.clip((V[:, 2] - 0.3) / 0.3, 0, 1) * 0.7)
            P.append(Part(f'gena.{SN[s]}', V, F, 'head', C['plate'], rough=0.36, vcolor=c, flags=4))
            P.append(spike(f'horn.{SN[s]}', 'head', np.array([s * 0.7, -0.42, 0.52]), np.array([s * 1.02, -0.92, 0.6]), 0.075, 5))
            P.append(spike(f'horn2.{SN[s]}', 'head', np.array([s * 0.72, 0.15, 0.46]), np.array([s * 0.98, 0.0, 0.38]), 0.05, 4))
        elif lod == 1:
            V, F = cone(np.array([s * 0.68, -0.4, 0.52]), np.array([s * 1.0, -0.9, 0.6]), 0.08, 3)
            P.append(Part(f'horn.{SN[s]}', V, F, 'head', C['keel'], rough=0.35, sharp_deg=180))
    # ---- the eyes: three pale ocelli a side under the shield's front edge
    if lod < 2:
        for s in SIDES:
            for k, (dy, dz, r) in enumerate(((0.0, 0.0, 0.055), (-0.14, 0.05, 0.045), (-0.1, -0.08, 0.035))):
                if lod == 1 and k > 0:
                    continue
                c = np.array([s * 0.55, 0.78 + dy, 0.6 + dz])
                V, F = octa(c, r, 0.8)
                P.append(Part(f'eye.{SN[s]}{k}', V, F, 'head', C['eye'], glow=0.75, rough=0.2, flags=F_GLAND,
                              vcolor=np.tile(col(C['eye']), (len(V), 1))))
    # ---- the front face (clypeus) between the mandible bases
    if lod == 0:
        V, F = ellipsoid((0, 1.0, 0.42), (0.36, 0.22, 0.16), 10, 3)
        P.append(Part('clypeus', V, F, 'head', C['plate'], rough=0.36, vcolor=ramp(C['plate'], C['edge'], np.clip((V[:, 1] - 0.9) / 0.3, 0, 1) * 0.6)))
        for s in SIDES:
            pv = [(s * 0.3, 1.0, 0.2), (s * 0.36, 1.2, 0.16), (s * 0.34, 1.36, 0.13)]
            V, F = tube(pv, [0.04, 0.03, 0.0], 5, tip=True)
            P.append(Part(f'palp.{SN[s]}', V, F, f'palp.{SN[s]}', C['joint'], rough=0.45, vcolor=ramp(C['joint'], C['claw'], np.linspace(0, 1, len(V)) ** 2)))
    P.extend(crest(lod))
    for s in SIDES:
        P.extend(mandible(s, lod))
    P.extend(lure(lod))
    for p in P:
        if p.bone in HEAD_BONES:
            p.V = hs(p.V)
    return P


# ------------------------------------------------------------------ animation
GROUND_CLAMP = set()
LOOPS = ('idle', 'sweep', 'down', 'coil', 'pull', 'charge')
DOWN_Z = -0.5           # the head lowered onto the deck (its point is 0.5 m above the deck while it is down)

CLIPS = [  # name, frames, loop, stride, event, notes
    ('idle', 60, True, 0.0, 0, 'breathing; the mandibles flex, the lantern swings on its whip, the crest ripples'),
    ('sweep', 90, True, 0.0, 0, 'the hunt: head low and forward, a slow sway, the lantern swinging behind it (B5 aims with the look yaw)'),
    ('strike', 37, False, 0.0, 36, 'B4\'s 1.2 s: rears up, mandibles spread, the crest flares, the lantern flares white; then the '
                                   'drop, nose down, the jaws snap on the last frame (the slam)'),
    ('down', 60, True, 0.0, 0, 'the punish window: lying on the deck, the crest lifted off the glowing membrane, jaws twitching, '
                               'the lantern dim on the deck'),
    ('recover', 24, False, 0.0, 23, 'heaves up off the deck, the crest slams shut, the jaws snap, the lantern relights'),
    ('scream', 45, False, 0.0, 6, 'the scream and stagger: thrown back, jaws spread wide, the crest flared, thrashing, the lantern '
                                  'flickering'),
    ('coil', 60, True, 0.0, 0, 'leading the coil: head low, jaws open and pulsing, the lantern pulled back and dim'),
    ('pull', 60, True, 0.0, 0, 'the pull-down: nose down, the jaws clamped on the trunk, wrenching side to side'),
    ('charge', 24, True, 0.0, 0, 'the deck chase: low, jaws wide and snapping, the lure streaming back'),
    ('strike_low', 19, False, 0.0, 18, 'P3\'s 0.6 s strike from low height: a quick rear and the snap'),
    ('death', 90, False, 0.0, 89, 'a last scream, the lantern flares and gutters out, collapses onto the deck, jaws slack; held'),
    ('hit', 10, False, 0.0, 1, 'a flinch'),
]


def _mand(st, gape):
    for s in SIDES:
        st.set(f'mand.{SN[s]}', rz(-s * gape * D2R))


def _palps(st, a):
    for s in SIDES:
        st.set(f'palp.{SN[s]}', rx(a * D2R) @ rz(-s * 0.5 * a * D2R))


def _lure(st, a1, a2, a3, yaw=0.0, swing=0.0, roll=0.0):
    """the whip: pitch per bone (+ = back toward the head), a yaw of the whole whip; the lantern's pendulum"""
    st.set('lure.1', rz(yaw * D2R) @ rx(a1 * D2R))
    st.set('lure.2', rx(a2 * D2R))
    st.set('lure.3', rx(a3 * D2R))
    st.set('lantern', rx(swing * D2R) @ rz(roll * D2R))


def _crest(st, lift):
    """+ lifts the crest off the membrane (more upright)"""
    st.set('crest', rx(lift * D2R))


def clip_state(name, f, n):
    st = State()
    tau = f / n if name in LOOPS else f / (n - 1)
    w = TWO * tau
    if name == 'idle':
        st.set('head', tr(0, 0, 0.02 * math.sin(w)) @ rx(2 * D2R * math.sin(w)) @ rz(3 * D2R * math.sin(w + 0.6)))
        _mand(st, 7 + 6 * math.sin(2 * w))
        _crest(st, 2 * math.sin(w + 1.0))
        _lure(st, 3 * math.sin(w), 4 * math.sin(w - 0.6), 5 * math.sin(w - 1.2), yaw=4 * math.sin(w + 0.3), swing=8 * math.sin(w - 1.6),
              roll=5 * math.sin(w - 0.9))
        _palps(st, 8 * math.sin(2 * w + 0.4))
        st.glow.update(gland=1.0, pulse=0.15, wave=tau, eye=0.0)
    elif name == 'sweep':
        sway = math.sin(w)
        st.set('head', rx(-3 * D2R) @ rz(9 * D2R * sway) @ tr(0, 0.05, 0.0))
        _mand(st, 13 + 6 * math.sin(2 * w))
        _crest(st, -3)
        _lure(st, -10 + 3 * math.sin(2 * w), -6, 4 + 3 * math.sin(2 * w - 0.5), yaw=-6 * math.sin(w - 0.7), swing=-9 * sway,
              roll=-8 * math.sin(w - 1.1))
        _palps(st, 10 * math.sin(2 * w))
        st.glow.update(gland=1.25, pulse=0.25, wave=tau * 2, eye=0.0)
    elif name == 'strike':
        up = smoothstep(0.0, 0.6, tau) * (1 - smoothstep(0.68, 0.86, tau))
        drop = smoothstep(0.68, 1.0, tau)
        snap = smoothstep(0.9, 1.0, tau)
        shiver = math.sin(f * 2.4) * smoothstep(0.3, 0.6, tau) * (1 - drop)
        st.set('root', tr(0, -0.25 * up + 0.3 * drop, 0.16 * up + DOWN_Z * drop))
        dive = math.sin(math.pi * drop) * (1 - snap)
        st.set('head', rx((26 * up - 28 * dive + 1.5 * drop + 2 * shiver) * D2R) @ rz(2 * shiver * D2R))
        _mand(st, 40 * up + 30 * drop * (1 - snap) - 4 * snap)
        _crest(st, 18 * up - 4 * drop)
        _lure(st, 24 * up - 10 * drop, 10 * up, 8 * up, swing=-20 * up + 25 * drop, roll=3 * shiver)
        _palps(st, 20 * up)
        st.glow.update(gland=1.0 + 2.6 * up + 1.2 * drop, pulse=0.2 * up, wave=tau * 3, eye=0.0)
    elif name == 'down':
        tw = math.sin(w * 2) * 0.5 + 0.5
        st.set('root', tr(0, 0.3, DOWN_Z))
        st.set('head', rx((1.5 + 1.5 * math.sin(w)) * D2R) @ ry(5 * D2R) @ tr(0, 0, 0.012 * math.sin(w)))
        _mand(st, 20 + 8 * max(0.0, math.sin(3 * w)) ** 3)
        _crest(st, 34 + 3 * math.sin(w))
        _lure(st, -9, -7, 16, swing=14, roll=6 * math.sin(w))
        _palps(st, 10 + 8 * tw)
        st.glow.update(gland=0.35 + 0.15 * max(0.0, math.sin(5 * w)) ** 6, pulse=0.0, wave=tau, eye=2.2 + 0.5 * math.sin(2 * w))
    elif name == 'recover':
        k = 1 - smoothstep(0.0, 0.75, tau)
        heave = math.sin(math.pi * min(1, tau / 0.7))
        st.set('root', tr(0, 0.3 * k, DOWN_Z * k + 0.12 * heave))
        st.set('head', rx((1.5 * k + 12 * heave) * D2R) @ ry(5 * k * D2R))
        _mand(st, 20 * k + 26 * heave * (1 - smoothstep(0.6, 0.85, tau)) - 3 * smoothstep(0.8, 1.0, tau))
        _crest(st, 34 * (1 - smoothstep(0.1, 0.45, tau)))
        _lure(st, -9 * k + 10 * heave, -7 * k, 16 * k, swing=14 * k - 10 * heave)
        st.glow.update(gland=0.35 + 0.8 * smoothstep(0.3, 0.9, tau), pulse=0.1, eye=2.2 * (1 - smoothstep(0.1, 0.45, tau)))
    elif name == 'scream':
        k = smoothstep(0.0, 0.12, tau) * (1 - smoothstep(0.7, 1.0, tau))
        thr = math.sin(f * 0.85) * k
        st.set('root', tr(0, -0.1 * k, 0.1 * k))
        st.set('head', rx(30 * k * D2R) @ rz(17 * thr * D2R) @ ry(6 * thr * D2R))
        _mand(st, 52 * k + 4 * math.sin(f * 2.2) * k)
        _crest(st, 26 * k)
        _lure(st, 18 * k, 8 * k * math.sin(f * 1.1), 10 * k, yaw=-14 * thr, swing=-24 * thr, roll=18 * thr)
        _palps(st, 26 * k)
        fl = abs(math.sin(f * 2.7)) * (0.5 + 0.5 * abs(math.sin(f * 0.61)))
        st.glow.update(gland=max(0.15, 1.0 + 1.6 * fl * k - 0.6 * k * (1 - fl)), pulse=0.0, eye=0.0)
    elif name == 'coil':
        st.set('head', rx(-18 * D2R) @ rz(5 * D2R * math.sin(w)) @ tr(0, 0.04, 0))
        _mand(st, 24 + 9 * math.sin(2 * w))
        _crest(st, 6)
        _lure(st, 16, 8, -4, swing=6 * math.sin(w - 1.2), roll=4 * math.sin(w))
        _palps(st, 12 * math.sin(2 * w + 1))
        st.glow.update(gland=0.45, pulse=0.15, wave=tau, eye=0.0)
    elif name == 'pull':
        yank = math.sin(w)
        st.set('root', tr(0, -0.08 * abs(yank), -0.06 * abs(yank)))
        st.set('head', rx((-10 - 3 * abs(yank)) * D2R) @ rz(11 * D2R * yank) @ ry(7 * D2R * yank))
        _mand(st, -3 + 2 * abs(yank))
        _crest(st, 20 + 6 * abs(yank))
        _lure(st, 10, 6, 6, yaw=-12 * yank, swing=-26 * yank, roll=22 * yank)
        _palps(st, -14)
        st.glow.update(gland=1.3, pulse=0.4, wave=tau * 2, eye=0.0)
    elif name == 'charge':
        st.set('head', rx(-7 * D2R) @ rz(4 * D2R * math.sin(w)) @ tr(0, 0.08, 0.0))
        _mand(st, 32 + 10 * math.sin(2 * w))
        _crest(st, -8)
        _lure(st, 28, 14, 10, swing=-18 + 6 * math.sin(2 * w), roll=4 * math.sin(w))
        _palps(st, 18)
        st.glow.update(gland=1.5, pulse=0.2, wave=tau * 2, eye=0.0)
    elif name == 'strike_low':
        up = smoothstep(0.0, 0.5, tau) * (1 - smoothstep(0.55, 0.8, tau))
        lunge = smoothstep(0.55, 1.0, tau)
        snap = smoothstep(0.85, 1.0, tau)
        st.set('root', tr(0, -0.15 * up + 0.42 * lunge, 0.08 * up))
        st.set('head', rx((16 * up - 7 * lunge) * D2R))
        _mand(st, 38 * (up + lunge) * (1 - snap) - 4 * snap)
        _crest(st, 10 * up)
        _lure(st, 20 * up + 18 * lunge, 8, 6, swing=-14 * up + 10 * lunge)
        st.glow.update(gland=1.4 + 1.6 * up, pulse=0.0, eye=0.0)
    elif name == 'death':
        sc = smoothstep(0, 6, f) * (1 - smoothstep(18, 30, f))
        col_ = smoothstep(20, 56, f)
        tw = math.exp(-((f - 62) / 2.5) ** 2)
        st.set('root', tr(0.05 * col_, 0.1 * col_, 0.12 * sc + (DOWN_Z - 0.08) * col_))
        st.set('head', rx((32 * sc + 2 * col_) * D2R) @ ry(7 * col_ * D2R) @ rz((10 * sc * math.sin(f * 0.9)) * D2R))
        _mand(st, 52 * sc + 10 * col_ * (1 - sc) + 6 * tw)
        _crest(st, 24 * sc - 8 * col_)
        _lure(st, 20 * sc - 10 * col_, 8 * sc - 9 * col_, 10 * col_, swing=-20 * sc + 18 * col_, roll=10 * sc * math.sin(f * 1.3))
        _palps(st, 24 * sc + 8 * col_)
        flick = abs(math.sin(f * 2.9)) * (1 - smoothstep(30, 66, f))
        g = 1.0 + 1.8 * sc
        g = g * (1 - smoothstep(26, 40, f)) + (0.15 + 1.0 * flick) * smoothstep(26, 40, f) * (1 - smoothstep(60, 72, f))
        st.glow.update(gland=max(0.0, g), pulse=0.0, eye=0.0)
    elif name == 'hit':
        k = [0, 1.0, 0.85, 0.6, 0.32, 0.1, -0.06, -0.05, -0.02, 0.0][f]
        st.set('head', rx(6 * k * D2R) @ rz(-5 * k * D2R))
        _mand(st, 7 + 12 * max(k, 0))
        _crest(st, 5 * k)
        _lure(st, 6 * k, 4 * k, 3 * k, swing=-8 * k)
        st.glow.update(gland=1.0 + 0.6 * max(k, 0), eye=0.0)
    return st
