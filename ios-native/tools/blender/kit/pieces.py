"""The station kit's authored pieces (game space, origin on the floor under the piece, +z = front, y up).

Each entry: name → (builder, flags, occluder, triangle budget). WorldLevel places them from the level layout; the long
runs (deck slabs, skirts, rails, girders, supports, pipes, edge strips, stairs) are extruded at runtime from the same
trim-sheet rules (kitgeo.py) because their lengths come from the layout.
  occluder: 'floor' (stands on a deck: the AO bake puts a ground plane under it), 'ceiling' (hangs under a deck),
            'none'
  budget: plan §2 — props 40–200 triangles; the hero beacon mast and the lift pad get more.
Style (the user's blend): crisp «Кристалл» bevelled hard surface — dark steel, chamfers that catch the flashlight,
one saturated light colour per element, used sparingly; frost's icicle fringes and LOW drifts (placed inside the
railings by WorldLevel); horror's darkness (dark albedos, the emissive bits are the only self-lit things).
"""
import math

import numpy as np

from kitgeo import (C, F_CHAMFER, F_FROST, F_ICE, F_PAINT, F_SNOW, F_STRIP, GRATINGS, NONE, PANELS, PIPES, RAILS, Mat,
                    Mesh, beam, cbox, cylinder, icicle, lathe, mound, transform, T)

P_LIFT, P_DYNAMIC = 1, 2

STEEL = Mat(C['steel'], 0.55, layer=PANELS)
STEEL_D = Mat(C['steelD'], 0.55, layer=PANELS)
STEEL_L = Mat(C['steelL'], 0.7, layer=RAILS, uv='strip', strip=7)
COLUMN = Mat(C['steel'], 0.55, layer=RAILS, uv='strip', strip=2, axis=(0, 1, 0))
RUBBER = Mat(C['dark'], 0.0, layer=PIPES, uv='strip', strip=7)


def light(col, k=3.0, paint=False):
    return Mat(col, 0.0, emis=k, layer=NONE, flags=F_STRIP | (F_PAINT if paint else 0))


# ---------------------------------------------------------------- crates: cargo modules
def crate(w, d):
    """w × 1 m × d module (WorldLevel scales y to the layout height): painted shell (F_PAINT: the placement picks
    olive / navy / rust), bright steel corner posts and rims, a pale label band, a status LED on the front."""
    h = 1.0
    m = Mesh()
    shell = Mat(0x808080, 0.25, layer=PANELS, flags=F_PAINT | F_FROST)
    m.merge(cbox(w - 0.14, h - 0.06, d - 0.14, 0.05, shell, center=(0, h / 2, 0), bottom=False))
    post = Mat(C['steelL'], 0.7, layer=RAILS, uv='strip', strip=7, axis=(0, 1, 0))
    for sx in (-1, 1):
        for sz in (-1, 1):
            m.merge(cbox(0.12, h, 0.12, 0.0, post, center=(sx * (w / 2 - 0.08), h / 2, sz * (d / 2 - 0.08)), bottom=False))
    rim = Mat(C['steelL'], 0.7, layer=RAILS, uv='strip', strip=6, flags=F_FROST)
    m.merge(cbox(w - 0.03, 0.07, d - 0.03, 0.02, rim, center=(0, h - 0.035, 0)))
    m.merge(cbox(w - 0.03, 0.07, d - 0.03, 0.02, STEEL_D, center=(0, 0.035, 0), bottom=False))
    m.merge(cbox(w - 0.11, 0.1, d - 0.11, 0.0, Mat(C['label'], 0.1, layer=PANELS), center=(0, h * 0.62, 0), bottom=False))
    m.merge(cbox(0.12, 0.05, 0.03, 0.0, light(C['green'], 3.0, paint=False), center=(w * 0.22, h * 0.4, d / 2 - 0.055)))
    return m


# ---------------------------------------------------------------- pillars: octagon columns with teal strips
def pillar():
    prof = [(0.55, 0.0), (0.55, 0.25), (0.46, 0.32), (0.42, 0.32), (0.42, 3.5), (0.5, 3.58), (0.5, 3.75), (0.0, 3.75)]
    base = Mat(C['steelD'], 0.7, layer=PANELS)
    mats = [base, base.but(flags=F_FROST), base, COLUMN, STEEL, STEEL.but(flags=F_FROST), STEEL.but(flags=F_FROST)]
    m = lathe(prof, 8, STEEL, phase=math.pi / 8, mats=mats)
    for k in range(4):
        a = k * math.pi / 2 + math.pi / 4
        s = cbox(0.06, 2.6, 0.03, 0.0, light(C['teal'], 3.0), bottom=False)
        m.merge(s, T(math.cos(a) * 0.405, 1.9, -math.sin(a) * 0.405, ry=a + math.pi / 2))
    return m


def rail_post():
    m = cbox(0.09, 1.1, 0.09, 0.018, Mat(C['steelL'], 0.7, layer=RAILS, uv='strip', strip=7, axis=(0, 1, 0)),
             center=(0, 0.55, 0), bottom=False)
    m.merge(cbox(0.17, 0.05, 0.17, 0.015, STEEL_D.but(flags=F_FROST), center=(0, 0.025, 0), bottom=False))
    return m


def lamp_post():
    """3.2 m post on the railing line, an arm over the deck (+z) and a lamp housing with a lens (F_PAINT: teal /
    green per placement)."""
    post = Mat(C['steelL'], 0.7, layer=RAILS, uv='strip', strip=2, axis=(0, 1, 0))
    m = cbox(0.16, 3.2, 0.16, 0.03, post, center=(0, 1.6, 0), bottom=False)
    m.merge(cbox(0.24, 0.08, 0.24, 0.02, STEEL_D, center=(0, 0.04, 0), bottom=False))
    m.merge(beam((0, 3.12, 0.0), (0, 3.12, 0.85), 0.1, 0.1, 0.02, STEEL_L))
    m.merge(cbox(0.3, 0.14, 0.42, 0.03, Mat(C['steelD'], 0.65, layer=PIPES, uv='strip', strip=5, flags=F_FROST),
                 center=(0, 3.05, 0.85)))
    # lens: a lit band under the housing, 1 cm proud of it on every side, so the gameplay camera (57° down) sees the
    # glowing rim; its bottom face lights the deck in the read-back
    m.merge(cbox(0.32, 0.05, 0.44, 0.0, light(C['teal'], 4.5, paint=True), center=(0, 2.955, 0.85)))
    return m


def vent():
    m = cbox(1.6, 0.12, 1.6, 0.04, Mat(C['steelD'], 0.65, layer=PANELS, flags=F_FROST), center=(0, 0.06, 0), bottom=False)
    for k in range(-2, 3):
        m.merge(cbox(1.2, 0.05, 0.12, 0.01, Mat(C['orange'], 0.3, emis=1.4, layer=PIPES, uv='strip', strip=4,
                                                 flags=F_STRIP), center=(0, 0.12, k * 0.26), bottom=False))
    return m


# ---------------------------------------------------------------- beacon: lattice mast, dish, warning lamps
def beacon_mast():
    """The hero prop: a 12-sided plinth with an amber ring, a 4-leg lattice mast tapering to 3.4 m, a dish on an arm
    and red warning lamps at the top corners. The rotating head (beacon_head) rides on top (dynamic, state colour)."""
    m = Mesh()
    plinth = [(1.75, 0.0), (1.75, 0.18), (1.6, 0.3), (1.3, 0.3), (1.3, 0.38), (0.0, 0.38)]
    pm = Mat(C['steel'], 0.6, layer=PANELS)
    m.merge(lathe(plinth, 12, pm, mats=[pm, pm.but(flags=F_FROST), pm.but(flags=F_FROST), pm, pm.but(flags=F_FROST)]))
    ring = lathe([(1.5, 0.3), (1.5, 0.315), (1.42, 0.315), (1.42, 0.3)], 24, light(C['amber'], 3.0), cap_top=False)
    m.merge(ring)
    leg = Mat(C['steelL'], 0.7, layer=PIPES, uv='strip', strip=3)
    brace = Mat(C['steel'], 0.65, layer=PIPES, uv='strip', strip=3)
    y0, y1 = 0.38, 3.4
    r0, r1 = 0.48, 0.2
    corners = [(1, 1), (-1, 1), (-1, -1), (1, -1)]

    def at(k, t):
        sx, sz = corners[k % 4]
        r = r0 + (r1 - r0) * t
        return np.array([sx * r, y0 + (y1 - y0) * t, sz * r])
    for k in range(4):
        m.merge(beam(at(k, 0), at(k, 1), 0.08, 0.08, 0.015, leg))
        # amber light strip on the leg's outer side (the mast reads as a lit structure at gameplay size)
        sx, sz = corners[k % 4]
        out = np.array([sx, 0.0, sz]) * (0.045 / math.sqrt(2))
        m.merge(beam(at(k, 0.08) + out, at(k, 0.9) + out, 0.022, 0.022, 0.0, light(C['amber'], 2.6)))
    secs = [0.0, 0.34, 0.68, 1.0]
    for k in range(4):
        for s in range(3):
            a, b = secs[s], secs[s + 1]
            m.merge(beam(at(k, a), at(k + 1, b), 0.035, 0.035, 0.0, brace))
            m.merge(beam(at(k + 1, a), at(k, b), 0.035, 0.035, 0.0, brace))
        for s in (1, 2, 3):
            m.merge(beam(at(k, secs[s]), at(k + 1, secs[s]), 0.045, 0.045, 0.0, brace))
    # top deck of the mast
    m.merge(cbox(0.56, 0.06, 0.56, 0.015, STEEL_D.but(flags=F_FROST), center=(0, y1 + 0.03, 0)))
    # dish on an arm (faces +z, tilted up)
    dish = Mesh()
    prof = [(0.0, 0.0), (0.18, 0.012), (0.36, 0.05), (0.52, 0.11), (0.55, 0.13), (0.5, 0.135), (0.34, 0.08), (0.16, 0.04),
            (0.0, 0.03)]
    dm = Mat(C['steelL'], 0.6, layer=PANELS)
    dish.merge(lathe(prof, 14, dm, cap_top=False))
    dish.merge(cylinder(0.025, 0.36, 6, STEEL_D, axis='y').merge(Mesh()), T(0, 0.2, 0))
    tilt = math.radians(62)
    R = np.eye(4)
    R[:3, :3] = np.array([[1, 0, 0], [0, math.cos(tilt), -math.sin(tilt)], [0, math.sin(tilt), math.cos(tilt)]])
    D = T(0.0, 2.55, 0.62) @ R
    m.merge(dish, D)
    m.merge(beam((0, 2.5, 0.25), (0, 2.55, 0.6), 0.06, 0.06, 0.01, STEEL_L))
    # warning lamps at the top corners
    for k in range(4):
        p = at(k, 1.0)
        m.merge(cbox(0.07, 0.07, 0.07, 0.0, light(C['red'], 4.0), center=(p[0] * 1.15, y1 + 0.1, p[2] * 1.15), bottom=False))
    # cables from the plinth to the deck
    for k in range(3):
        a = k * 2.1 + 0.4
        m.merge(beam((math.cos(a) * 1.0, 0.36, math.sin(a) * 1.0), (math.cos(a) * 2.3, 0.04, math.sin(a) * 2.3), 0.07, 0.06,
                     0.015, Mat(C['dark'], 0.0, layer=PIPES, uv='strip', strip=2)))
    return m


def beacon_head():
    """The rotating lamp on the mast top (drawn per frame: rotation + the beacon's state colour on the lens)."""
    prof = [(0.2, 0.0), (0.24, 0.05), (0.24, 0.08), (0.2, 0.08), (0.2, 0.24), (0.24, 0.24), (0.24, 0.28), (0.16, 0.34),
            (0.0, 0.34)]
    hm = Mat(C['steelD'], 0.65, layer=PIPES, uv='strip', strip=5)
    lens = Mat(0xffffff, 0.0, emis=3.5, layer=NONE, flags=F_STRIP | F_PAINT)
    m = lathe(prof, 10, hm, phase=0.0, mats=[hm, hm, hm, lens, hm, hm, hm, hm.but(flags=F_FROST)])
    # reflector fin (reads as a rotating shutter)
    m.merge(cbox(0.03, 0.14, 0.3, 0.0, STEEL_L, center=(0, 0.16, 0.0), bottom=False))
    return m


# ---------------------------------------------------------------- lift
def lift_pad():
    prof = [(1.85, 0.0), (1.85, 0.08), (1.7, 0.14), (1.5, 0.14), (1.48, 0.12), (1.38, 0.12), (1.36, 0.14), (0.0, 0.14)]
    pm = Mat(C['steel'], 0.6, layer=PANELS)
    m = lathe(prof, 20, pm, mats=[pm, pm.but(flags=F_FROST), pm.but(flags=F_FROST), pm, pm, pm, Mat(0x1a3b44, 0.4, layer=PANELS)])
    m.merge(lathe([(1.475, 0.121), (1.385, 0.121)], 20, light(C['teal'], 3.0), cap_top=False))
    for k in range(6):
        b = k / 6 * 2 * math.pi
        m.merge(cbox(0.14, 0.04, 0.14, 0.0, light(C['green'], 3.0), center=(math.cos(b) * 1.62, 0.16, math.sin(b) * 1.62),
                     bottom=False))
    return m


def lift_hub():
    hm = Mat(C['steelL'], 0.7, layer=PANELS)
    m = lathe([(1.1, 0.0), (1.1, 0.35), (0.9, 0.5), (0.0, 0.5)], 16, hm, mats=[hm, hm.but(flags=F_FROST), hm.but(flags=F_FROST)])
    m.merge(lathe([(1.02, 0.43), (0.95, 0.43)], 32, light(C['teal'], 3.0), cap_top=False))
    return m


# ---------------------------------------------------------------- frost: icicle fringes, low drifts
def icicles(seed, n):
    R = np.random.RandomState(seed)
    ice = Mat(C['ice'], 0.0, layer=NONE, flags=F_ICE, smooth=True)
    m = Mesh()
    # thin ice lip along the edge
    m.merge(cbox(1.0, 0.03, 0.05, 0.0, ice.but(smooth=False), center=(0, -0.015, 0), bottom=True))
    xs = np.sort(R.uniform(-0.46, 0.46, n))
    for k, x in enumerate(xs):
        L = 0.16 + 0.5 * R.rand() ** 1.3
        r = 0.022 + 0.026 * (L / 0.66) + 0.006 * R.rand()
        m.merge(icicle(float(x), float(R.uniform(-0.012, 0.012)), float(L), float(r), ice, seg=5, rot=float(R.rand() * 6.28)))
    return m


def drift(length, width, height, seed, tilt):
    snow = Mat(C['snow'], 0.0, layer=NONE, flags=F_SNOW, smooth=True)
    return mound(length, width, height, snow, nu=12, nv=6, seed=seed, tilt=tilt)


# ---------------------------------------------------------------- small structure
def support_cap():
    """Collar where a support column meets the deck underside (hangs from y = 0 down)."""
    m = cbox(1.0, 0.45, 1.0, 0.06, Mat(C['girder'], 0.7, layer=RAILS, uv='strip', strip=1), center=(0, -0.225, 0))
    m.merge(cbox(0.86, 0.18, 0.86, 0.04, STEEL_D, center=(0, -3.0, 0)))
    return m


def pad_light():
    return cbox(0.2, 0.06, 0.2, 0.015, light(C['amber'], 3.0), center=(0, 0.03, 0), bottom=False)


def pipe_bracket():
    br = Mat(C['steelD'], 0.6, layer=PIPES, uv='strip', strip=6)
    m = cbox(0.08, 0.9, 0.06, 0.0, br, center=(0, -0.45, 0))
    m.merge(cbox(0.08, 0.06, 0.4, 0.0, br, center=(0, -0.25, 0.17)))
    m.merge(cbox(0.08, 0.06, 0.4, 0.0, br, center=(0, -0.62, 0.17)))
    return m


PIECES = {
    'crate_1x1': (lambda: crate(1.0, 1.0), 0, 'floor', 240),
    'crate_2x1': (lambda: crate(2.0, 1.0), 0, 'floor', 240),
    'crate_2x2': (lambda: crate(2.0, 2.0), 0, 'floor', 240),
    'pillar': (pillar, 0, 'floor', 200),
    'rail_post': (rail_post, 0, 'floor', 60),
    'lamp_post': (lamp_post, 0, 'floor', 200),
    'vent': (vent, 0, 'floor', 200),
    'beacon_mast': (beacon_mast, 0, 'floor', 1500),
    'beacon_head': (beacon_head, P_DYNAMIC, 'none', 200),
    'lift_pad': (lift_pad, P_LIFT, 'floor', 400),
    'lift_hub': (lift_hub, P_LIFT, 'floor', 200),
    'icicles_a': (lambda: icicles(11, 7), 0, 'ceiling', 200),
    'icicles_b': (lambda: icicles(23, 5), 0, 'ceiling', 200),
    'icicles_c': (lambda: icicles(37, 7), 0, 'ceiling', 200),
    'drift_a': (lambda: drift(2.0, 0.56, 0.15, 3, 0.6), 0, 'floor', 200),
    'drift_b': (lambda: drift(2.7, 0.7, 0.19, 5, 0.8), 0, 'floor', 200),
    'drift_c': (lambda: drift(1.4, 0.46, 0.11, 7, 0.4), 0, 'floor', 200),
    'support_cap': (support_cap, 0, 'ceiling', 120),
    'pad_light': (pad_light, 0, 'floor', 40),
    'pipe_bracket': (pipe_bracket, 0, 'none', 60),
}
