"""THE MANIFOLD's kit pieces (Stage 2 B2; design.md §1.5 «Arena: the Manifold»; B4's layout: Manifold.swift) — what the
station kit lacked for the Threader's arena, on the existing trim sheets (no new texture): pieces.py registers them.

The long runs stay runtime extrusions with the kit's UV rules (KitStore / OverheadKit, as R3's routes): B5 extrudes the
four TRUNK pipes (radius TRUNK_R, their TOP on the route line at 5 m — the line B4's Threader rides; pipes strip 0) and
the RING DUCT (0.9 × 0.7 m, its top on the route line at 8 m — R3's duct section). These pieces dress and join them:

  mf_trunk_band   a bolted clamp band round a trunk (every ~3.5 m: the joints between pipe lengths)
  mf_trunk_cross  the cross fitting where two trunks of the «#» cross at the same height (the four crossings, ±3.5 m)
  mf_trunk_elbow  a trunk's end at its abyss riser (±17.5 m): a 90° bend down into the abyss (the vertical pipe below it
                  is runtime: from x = +ELBOW_R, y = -TRUNK_R - ELBOW_R down)
  mf_trunk_post   the post on the catwalk ring carrying a trunk (the legs at ±15 m): base plate, column, knee braces and
                  a saddle under the pipe — for a 5 m trunk over its deck
  mf_riser_tee    the tee on a trunk's top where its riser pipe climbs to the ring duct (at the legs)
  mf_duct_corner  a corner of the ring duct (±16 m, 8 m): the turning box with its access hatch and the outlet down to the
                  duct mouth at the ring's corner (R3's oh_duct_mouth ends that drop)
  mf_duct_band    a stiffener frame round the ring duct (every ~2.5 m)
  mf_pump         a QUARTER of the pump housing (the island's 4 × 4 × 2.6 m cover): a pump unit on the roof, its intake down
                  the wall, hatches, hazard paint, an amber gauge — placed four times about the housing's centre
  mf_bridge_truss the under-truss of a radial bridge (6 m span, two per bridge, under its edges)

Origins (game space, x right, y up, z forward) — overhead pieces as R3's oh_* pieces: ON the route line (the top of the
pipe / duct), +x along the route (the cross: both axes; the elbow: +x = outward past the riser node; the corner: its two
arms along +x and +z). Deck pieces on the floor: mf_trunk_post under its trunk (+x along the trunk), mf_pump at the
housing's CENTRE (its quarter in +x +z), mf_bridge_truss at the bridge's island end on its edge line (+x along the bridge,
the truss under the deck). Dark kit steel, the frost flag on the tops, one light colour (small amber gauges) — the
overhead's rule (design §1.1.2).
"""
import math

import numpy as np

from kitgeo import (C, F_CHAMFER, F_FROST, F_HAZARD, F_STRIP, NONE, PANELS, PIPES, RAILS, Mat, Mesh, add_face, beam,
                    cbox, cylinder, lathe, T, _ccw)

TRUNK_R = 0.45          # the trunk pipe (the Threader's claws wrap a pipe of this radius: creatures/threader_common.py)
ELBOW_R = 0.9           # the bend radius of mf_trunk_elbow (to the pipe's axis)
TRUNK_Y = 5.0           # B4: Manifold.trunkY (route line = the pipe top); mf_trunk_post is built for it
DUCT_W, DUCT_H = 0.9, 0.7

STEEL = Mat(C['steelD'], 0.6, layer=PIPES, uv='strip', strip=6, flags=F_FROST)
FLANGE = Mat(C['steelD'], 0.65, layer=PIPES, uv='strip', strip=6, flags=F_FROST)
PIPE = Mat(0x5c4f3e, 0.7, layer=PIPES, uv='strip', strip=0, flags=F_FROST)          # the trunks' rusted steel
PANEL = Mat(C['steel'], 0.55, layer=PANELS, flags=F_FROST)
PANEL_D = Mat(C['steelD'], 0.55, layer=PANELS, flags=F_FROST)
GIRDER = Mat(C['girder'], 0.7, layer=RAILS, uv='strip', strip=1, flags=F_FROST)
COLUMN = Mat(C['support'], 0.6, layer=RAILS, uv='strip', strip=2, axis=(0, 1, 0), flags=F_FROST)
HAZARD = Mat(C['steelD'], 0.5, layer=RAILS, uv='strip', strip=5, axis=(1, 0, 0), flags=F_HAZARD)
FINS = Mat(C['steelD'], 0.6, layer=PIPES, uv='strip', strip=5, flags=F_FROST)
DUCT = Mat(C['steelD'], 0.55, layer=PANELS)


def amber(k=2.6):
    return Mat(C['amber'], 0.0, emis=k, layer=NONE, flags=F_STRIP)


def _frame(t, up=(0.0, 1.0, 0.0)):
    t = np.asarray(t, float) / np.linalg.norm(t)
    u = np.asarray(up, float)
    if abs(t @ u) > 0.95:
        u = np.array([1.0, 0.0, 0.0])
    a = np.cross(t, u)
    a /= np.linalg.norm(a)
    b = np.cross(t, a)
    return a, b


def sweep(path, r, sides, mat, cap0=False, cap1=False, phase=0.0):
    """a tube of radius r (a float or one per point) along a polyline (parallel-transport frames), the kit's strip uvs
    running along each face; caps optional"""
    P = [np.asarray(p, float) for p in path]
    R = r if isinstance(r, (list, tuple)) else [r] * len(P)
    m = Mesh()
    T_ = []
    for i in range(len(P)):
        a, b = P[max(i - 1, 0)], P[min(i + 1, len(P) - 1)]
        T_.append((b - a) / np.linalg.norm(b - a))
    a0, b0 = _frame(T_[0])
    frames = [(a0, b0)]
    for i in range(1, len(P)):
        a = frames[-1][0]
        a = a - T_[i] * (a @ T_[i])
        a /= np.linalg.norm(a)
        frames.append((a, np.cross(T_[i], a)))
    rings = []
    for i, p in enumerate(P):
        a, b = frames[i]
        ring = []
        for k in range(sides):
            ang = phase + 2 * math.pi * k / sides
            ring.append(m.add_vertex(p + R[i] * (math.cos(ang) * a + math.sin(ang) * b)))
        rings.append(ring)
    for i in range(len(P) - 1):
        for k in range(sides):
            k1 = (k + 1) % sides
            q = [rings[i][k], rings[i][k1], rings[i + 1][k1], rings[i + 1][k]]
            c = (m.V[q[0]] + m.V[q[2]]) / 2
            out = c - (P[i] + P[i + 1]) / 2
            add_face(m, _ccw(m, q, out), mat.but(axis=tuple((P[i + 1] - P[i]) / np.linalg.norm(P[i + 1] - P[i]))) if mat.uv == 'strip' else mat)
    if cap0:
        add_face(m, _ccw(m, list(rings[0]), -T_[0]), mat.but(uv='tile') if mat.uv == 'strip' else mat)
    if cap1:
        add_face(m, _ccw(m, list(rings[-1]), T_[-1]), mat.but(uv='tile') if mat.uv == 'strip' else mat)
    return m


def ring_x(x, r0, r1, w, sides, mat, y=-TRUNK_R):
    """a flat collar round the trunk's axis (along x) at x: inner radius r0, outer r1, width w — a lathe turned onto +x"""
    prof = [(r0, -w / 2), (r1, -w / 2 + 0.012), (r1, w / 2 - 0.012), (r0, w / 2)]
    m = lathe(prof, sides, mat, phase=math.pi / sides, cap_top=False)
    M = np.eye(4)
    M[:3, :3] = np.array([[0, 1, 0], [-1, 0, 0], [0, 0, 1]], dtype=np.float64)   # +y → +x
    M[:3, 3] = (x, y, 0.0)
    out = Mesh()
    return out.merge(m, M)


def bolts(centres, size, mat):
    m = Mesh()
    for c in centres:
        m.merge(cbox(size, size, size, 0.0, mat, center=tuple(c), bottom=True))
    return m


# ---------------------------------------------------------------- the trunks
def mf_trunk_band():
    """a bolted clamp band round a trunk pipe, its top on the route line (y = 0), across +x"""
    m = ring_x(0.0, TRUNK_R + 0.004, TRUNK_R + 0.035, 0.16, 16, FLANGE)
    cs = []
    for k in range(5):
        a = math.pi / 2 + 2 * math.pi * (k + 0.5) / 6          # (none on the crown: the Threader rides over it)
        cs.append((0.0, -TRUNK_R + (TRUNK_R + 0.04) * math.sin(a), (TRUNK_R + 0.04) * math.cos(a)))
    m.merge(bolts(cs, 0.045, STEEL))
    return m


def mf_trunk_cross():
    """the cross fitting of two trunks crossing at the same height: a chamfered hub on the pipes' axes, its top flush with
    the route line (the Threader crosses it), four flanged sockets ±x / ±z to 0.76 m (B5 ends the runtime pipes there),
    an inspection cap on top and a drain stub under it"""
    hy = -TRUNK_R
    m = cbox(1.12, 0.92, 1.12, 0.16, PANEL_D, center=(0.0, hy, 0.0))
    for ax in range(4):
        yaw = ax * math.pi / 2
        sock = ring_x(0.68, TRUNK_R - 0.02, TRUNK_R + 0.042, 0.16, 12, FLANGE, y=hy)
        cs = []
        for k in range(4):
            a = 2 * math.pi * (k + 0.5) / 4 + math.pi / 4 + 0.39          # (none on the crown)
            cs.append((0.72, hy + (TRUNK_R + 0.05) * math.sin(a), (TRUNK_R + 0.05) * math.cos(a)))
        sock.merge(bolts(cs, 0.045, STEEL))
        m.merge(sock, T(ry=yaw))
    # the inspection cap (flush: a low disc set into the hub's top) and the drain stub under the hub
    m.merge(lathe([(0.3, -0.0), (0.3, 0.012), (0.24, 0.024), (0.0, 0.024)], 10, PANEL), T(y=hy + 0.46 - 0.012))
    m.merge(cylinder(0.09, 0.3, 8, STEEL, axis='y'), T(y=hy - 0.6))
    m.merge(cbox(0.05, 0.04, 0.05, 0.0, amber(2.4), center=(0.45, hy + 0.2, 0.565), bottom=True))
    return m


def mf_trunk_elbow():
    """a trunk's end at its abyss riser: the pipe turns 90° down (bend radius ELBOW_R to the axis) past the route node;
    flanges at both ends and a riveted saddle band on the bend's top. The vertical pipe below (runtime) starts at
    (+ELBOW_R, -TRUNK_R - ELBOW_R)."""
    cx, cy = 0.0, -TRUNK_R - ELBOW_R
    path = []
    n = 8
    for i in range(n + 1):
        a = math.pi / 2 * i / n
        path.append((cx + ELBOW_R * math.sin(a), cy + ELBOW_R * math.cos(a), 0.0))
    path = [(-0.25, -TRUNK_R, 0.0)] + path + [(ELBOW_R, cy - 0.25, 0.0)]
    m = sweep(path, TRUNK_R, 12, PIPE)
    m.merge(ring_x(-0.1, TRUNK_R + 0.004, TRUNK_R + 0.04, 0.1, 12, FLANGE))
    low = ring_x(0.0, TRUNK_R + 0.004, TRUNK_R + 0.06, 0.1, 12, FLANGE, y=0.0)
    M = np.eye(4)
    M[:3, :3] = np.array([[0, -1, 0], [1, 0, 0], [0, 0, 1]], dtype=np.float64)    # +x → -y (the collar onto the riser)
    M[:3, 3] = (ELBOW_R, cy - 0.15, 0.0)
    m.merge(low, M)
    # the saddle band over the bend's crown (where a riser bracket would hold it)
    a = math.pi / 4
    c = (cx + ELBOW_R * math.sin(a), cy + ELBOW_R * math.cos(a))
    band = ring_x(0.0, TRUNK_R + 0.004, TRUNK_R + 0.035, 0.14, 12, STEEL, y=0.0)
    Mb = np.eye(4)
    ca, sa = math.cos(-a), math.sin(-a)
    Mb[:3, :3] = np.array([[ca, -sa, 0], [sa, ca, 0], [0, 0, 1]], dtype=np.float64)
    Mb[:3, 3] = (c[0], c[1], 0.0)
    m.merge(band, Mb)
    return m


def mf_trunk_post():
    """the post on the catwalk ring under a trunk (origin on the deck, the trunk's top TRUNK_Y up, +x along it): a base
    plate with hazard paint, a slim column (0.3 m: the ring stays walkable), two knee braces along the trunk, a saddle
    hugging the pipe's underside, an amber gauge on the column"""
    top = TRUNK_Y - 2 * TRUNK_R              # the pipe's underside
    m = cbox(0.8, 0.07, 0.8, 0.02, PANEL_D, center=(0.0, 0.035, 0.0))
    m.merge(cbox(0.42, 0.22, 0.42, 0.02, HAZARD, center=(0.0, 0.18, 0.0), bottom=False))
    m.merge(cbox(0.3, top - 0.55, 0.3, 0.03, COLUMN, center=(0.0, 0.29 + (top - 0.55) / 2, 0.0), bottom=False))
    # the saddle: a cross head and two cheeks round the pipe's lower half
    m.merge(cbox(0.9, 0.12, 0.5, 0.02, GIRDER, center=(0.0, top - 0.2, 0.0)))
    for sz in (-1, 1):
        m.merge(cbox(0.36, 0.42, 0.06, 0.01, STEEL, center=(0.0, top + 0.04, sz * (TRUNK_R * 0.86)), bottom=True))
    m.merge(cbox(0.36, 0.08, 0.62, 0.01, STEEL, center=(0.0, top - 0.1, 0.0)))
    # knee braces up to the saddle, along the trunk
    for sx in (-1, 1):
        m.merge(beam((0.0, top - 1.3, 0.0), (sx * 0.42, top - 0.25, 0.0), 0.09, 0.09, 0.0, GIRDER))
    m.merge(cbox(0.05, 0.09, 0.05, 0.0, amber(2.6), center=(0.0, 1.5, 0.175), bottom=True))
    return m


def mf_riser_tee():
    """the tee on a trunk's top at a ring post, where its riser pipe climbs to the ring duct: a collar round the trunk, a
    stub up from its crown (r 0.3, 0.38 m) ending in a flange (B5 runs the riser pipe from y = +0.38)"""
    m = ring_x(0.0, TRUNK_R + 0.004, TRUNK_R + 0.06, 0.62, 16, PANEL_D)
    m.merge(lathe([(0.3, -0.05), (0.3, 0.32), (0.37, 0.32), (0.37, 0.38), (0.0, 0.38)], 12, PIPE,
                  mats=[PIPE, FLANGE, FLANGE, FLANGE]))
    cs = [(0.335 * math.cos(2 * math.pi * k / 6), 0.39, 0.335 * math.sin(2 * math.pi * k / 6)) for k in range(6)]
    m.merge(bolts(cs, 0.04, STEEL))
    return m


# ---------------------------------------------------------------- the ring duct
def mf_duct_corner():
    """a corner of the ring duct (0.9 × 0.7, its top on the route line): the turning box joining an arm along +x and one
    along +z (B5 yaws it per corner so both arms run along the square), an access hatch on top, flanges on both arms, and
    under the box's inner side (+x +z: inside the square, between the arms) the outlet of the drop to the duct mouth
    (B4: 1.2 m in along the diagonal, 3.4 m down — R3's duct extrusion and oh_duct_mouth)"""
    w, h = DUCT_W, DUCT_H
    m = Mesh()
    m.merge(cbox(w + 0.12, h + 0.08, w + 0.12, 0.05, DUCT, center=(0.0, -h / 2, 0.0)))
    # the two arms' first 0.4 m (the runtime duct joins at 0.65)
    m.merge(cbox(0.45, h, w, 0.03, DUCT, center=(0.45 + 0.2, -h / 2, 0.0)))
    m.merge(cbox(w, h, 0.45, 0.03, DUCT, center=(0.0, -h / 2, 0.45 + 0.2)))
    for (cx, cz, along) in ((0.66, 0.0, 'x'), (0.0, 0.66, 'z')):
        if along == 'x':
            m.merge(cbox(0.07, h + 0.12, w + 0.12, 0.012, FLANGE, center=(cx, -h / 2, cz)))
        else:
            m.merge(cbox(w + 0.12, h + 0.12, 0.07, 0.012, FLANGE, center=(cx, -h / 2, cz)))
    # the access hatch, its hinge bar and a handle
    m.merge(cbox(0.62, 0.05, 0.62, 0.015, PANEL, center=(-0.02, 0.025, -0.02)))
    m.merge(cbox(0.06, 0.04, 0.5, 0.0, STEEL, center=(-0.33, 0.06, -0.02), bottom=False))
    m.merge(beam((0.1, 0.07, 0.18), (0.22, 0.07, 0.18), 0.03, 0.03, 0.0, STEEL))
    # the outlet down (toward the duct mouth): a flanged collar under the box's inner corner
    m.merge(cbox(0.6, 0.18, 0.6, 0.02, DUCT, center=(0.12, -h - 0.09, 0.12)))
    m.merge(cbox(0.68, 0.05, 0.68, 0.01, FLANGE, center=(0.12, -h - 0.17, 0.12)))
    m.merge(cbox(0.04, 0.06, 0.04, 0.0, amber(2.2), center=(0.36, -0.3, -w / 2 - 0.08), bottom=True))
    return m


def mf_duct_band():
    """a stiffener frame round the ring duct, its top 2 cm proud of the route line (the Threader rides over it)"""
    w, h, t = DUCT_W, DUCT_H, 0.05
    m = Mesh()
    m.merge(cbox(0.1, t, w + 2 * t, 0.0, STEEL, center=(0.0, t / 2 - 0.03, 0.0)))
    m.merge(cbox(0.1, t, w + 2 * t, 0.0, STEEL, center=(0.0, -h - t / 2, 0.0)))
    for sz in (-1, 1):
        m.merge(cbox(0.1, h + 2 * t, t, 0.0, STEEL, center=(0.0, -h / 2 - 0.015, sz * (w / 2 + t / 2))))
    return m


# ---------------------------------------------------------------- the island
def mf_pump():
    """a QUARTER of the pump housing (B4: the island's 4 × 4 × 2.6 m cover), origin at the housing's centre, the quarter in
    x 0…2, z 0…2: the block's two outer walls with hatch panels and hazard paint at the foot, the chamfered roof edge, a
    pump unit on the roof (a finned motor, its outlet elbow to the centre manifold), its intake pipe down the +z wall
    into the deck, a junction box and an amber gauge. Placed four times (yaw 0, 90, 180, 270°) it closes the block."""
    H = 2.6
    m = Mesh()
    # the walls (outer faces only: the inner seams of the four quarters never show) and the roof
    wall = PANEL_D
    q = [m.add_vertex(p) for p in ((2.0, 0.0, 0.0), (2.0, 0.0, 2.0), (2.0, H - 0.1, 2.0), (2.0, H - 0.1, 0.0))]
    add_face(m, _ccw(m, q, (1, 0, 0)), wall)
    q = [m.add_vertex(p) for p in ((0.0, 0.0, 2.0), (0.0, H - 0.1, 2.0), (2.0, H - 0.1, 2.0), (2.0, 0.0, 2.0))]
    add_face(m, _ccw(m, q, (0, 0, 1)), wall)
    # chamfered roof edge along the two outer sides, the roof plate
    q = [m.add_vertex(p) for p in ((2.0, H - 0.1, 0.0), (2.0, H - 0.1, 2.0), (1.9, H, 1.9), (1.9, H, 0.0))]
    add_face(m, _ccw(m, q, (1, 1, 0)), wall, F_CHAMFER)
    q = [m.add_vertex(p) for p in ((0.0, H - 0.1, 2.0), (0.0, H, 1.9), (1.9, H, 1.9), (2.0, H - 0.1, 2.0))]
    add_face(m, _ccw(m, q, (0, 1, 1)), wall, F_CHAMFER)
    q = [m.add_vertex(p) for p in ((1.9, H - 0.1, 2.0), (2.0, H - 0.1, 2.0), (1.9, H, 1.9))]
    add_face(m, _ccw(m, q, (1, 1, 1)), wall, F_CHAMFER)
    q = [m.add_vertex(p) for p in ((0.0, H, 0.0), (0.0, H, 1.9), (1.9, H, 1.9), (1.9, H, 0.0))]
    add_face(m, _ccw(m, q, (0, 1, 0)), PANEL)
    # hazard paint along the foot of both walls, hatch panels and their frames
    m.merge(cbox(0.06, 0.3, 2.0, 0.0, HAZARD.but(axis=(0, 0, 1)), center=(2.03, 0.15, 1.0), bottom=False))
    m.merge(cbox(2.0, 0.3, 0.06, 0.0, HAZARD, center=(1.0, 0.15, 2.03), bottom=False))
    m.merge(cbox(0.05, 1.3, 0.9, 0.02, PANEL, center=(2.03, 1.15, 0.85), bottom=False))
    m.merge(cbox(1.0, 1.1, 0.05, 0.02, PANEL, center=(0.9, 1.25, 2.03), bottom=False))
    # the roof: a plinth and the pump unit (a finned motor along +x at z 1.1, its outlet elbow toward the centre)
    m.merge(cbox(1.5, 0.12, 1.1, 0.02, PANEL_D, center=(1.05, H + 0.06, 1.05)))
    mot = cylinder(0.24, 1.1, 12, FINS, axis='x')
    m.merge(mot, T(1.15, H + 0.12 + 0.24, 1.1))
    m.merge(lathe([(0.28, -0.04), (0.28, 0.04), (0.0, 0.04)], 12, FLANGE), T(0.58, H + 0.36, 1.1) @ _rz(math.pi / 2))
    m.merge(lathe([(0.28, -0.04), (0.28, 0.04), (0.0, 0.04)], 12, FLANGE), T(1.72, H + 0.36, 1.1) @ _rz(-math.pi / 2))
    path = [(0.58, H + 0.36, 1.1), (0.35, H + 0.36, 1.1), (0.2, H + 0.33, 0.95), (0.12, H + 0.27, 0.6), (0.1, H + 0.24, 0.1)]
    m.merge(sweep(path, 0.13, 10, PIPE))
    m.merge(cbox(0.42, 0.26, 0.32, 0.03, PANEL, center=(1.45, H + 0.25, 0.42)))
    m.merge(cbox(0.05, 0.08, 0.05, 0.0, amber(2.8), center=(1.45, H + 0.28, 0.6), bottom=True))
    # the intake down the +z wall into the deck
    path = [(1.62, H + 0.22, 1.45), (1.62, H + 0.08, 1.9), (1.62, H - 0.2, 2.11), (1.62, 0.6, 2.11), (1.62, 0.15, 2.11)]
    m.merge(sweep(path, 0.1, 10, PIPE))
    for y in (0.7, 1.7):
        m.merge(cbox(0.3, 0.08, 0.1, 0.01, STEEL, center=(1.62, y, 2.06)))
    m.merge(lathe([(0.16, 0.0), (0.16, 0.07), (0.11, 0.1), (0.0, 0.1)], 10, FLANGE), T(1.62, 0.0, 2.11))
    return m


def _rz(a):
    c, s = math.cos(a), math.sin(a)
    M = np.eye(4)
    M[:3, :3] = np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]], dtype=np.float64)
    return M


def mf_bridge_truss():
    """the under-truss of a radial bridge (B4: 6 m from the island to the ring, 3 m wide): a Warren girder hung under one
    edge of the deck (origin on the floor at the island end, +x along the bridge, the truss 0.12–1.0 m under the deck)"""
    L = 6.0
    m = Mesh()
    m.merge(beam((0.0, -0.18, 0.0), (L, -0.18, 0.0), 0.14, 0.12, 0.01, GIRDER))
    m.merge(beam((0.3, -0.95, 0.0), (L - 0.3, -0.95, 0.0), 0.12, 0.1, 0.01, GIRDER))
    n = 6
    for k in range(n):
        x0, x1 = 0.3 + (L - 0.6) * k / n, 0.3 + (L - 0.6) * (k + 1) / n
        xm = (x0 + x1) / 2
        m.merge(beam((x0, -0.92, 0.0), (xm, -0.22, 0.0), 0.07, 0.07, 0.0, GIRDER))
        m.merge(beam((xm, -0.22, 0.0), (x1, -0.92, 0.0), 0.07, 0.07, 0.0, GIRDER))
    for x in (0.12, L - 0.12):
        m.merge(cbox(0.16, 0.85, 0.16, 0.015, GIRDER.but(axis=(0, 1, 0)), center=(x, -0.6, 0.0)))
    return m


PIECES = {
    'mf_trunk_band': (mf_trunk_band, 0, 'none', 200),
    'mf_trunk_cross': (mf_trunk_cross, 0, 'none', 700),
    'mf_trunk_elbow': (mf_trunk_elbow, 0, 'none', 500),
    'mf_trunk_post': (mf_trunk_post, 0, 'floor', 320),
    'mf_riser_tee': (mf_riser_tee, 0, 'none', 260),
    'mf_duct_corner': (mf_duct_corner, 0, 'none', 420),
    'mf_duct_band': (mf_duct_band, 0, 'none', 100),
    'mf_pump': (mf_pump, 0, 'floor', 700),
    'mf_bridge_truss': (mf_bridge_truss, 0, 'ceiling', 340),
}
