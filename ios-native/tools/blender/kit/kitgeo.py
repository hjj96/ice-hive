"""Station-kit geometry (pure numpy): chamfered hard-surface primitives with per-face material attributes and trim-sheet
UVs, in GAME space (metres, x right, y up, z forward). build_kit.py turns the parts into Blender objects (AO atlas
bake, the editable .blend) and exports them from Blender as IHK1 pieces.

A Part is a list of faces; every face carries:
  tint   sRGB hex albedo               metal  0..1               emis  HDR emissive strength (× tint)
  layer  trim sheet (TRIM_* below; NONE = none)                   flags ihk.F_* bits
  uv     per-corner trim uv (Metal convention: v down), from the face's UV rule (tile / strip)
  smooth True: smooth-shaded (round parts, snow, ice)
The trim sheets (trims.py bakes them): 2 m × 2 m per texture at 1024², so DENSITY = 0.5 uv per metre:
  0 GRATINGS  tiling deck grating (1 m tiles, bars alternating direction)
  1 PANELS    tiling hull plates (four 1 m plate types: bolted, inset, tread, vented)
  2 RAILS     8 horizontal strips (0.25 m tall each, tiling along u): skirt band, girder web, column face, rail bar,
              tread nosing, hazard band, chequer plate, brushed steel
  3 PIPES     8 strips: pipe, corrugated hose, cable bundle, lattice angle, vent slots, housing fins, bolted flange,
              rubber
"""
import math

import numpy as np

DENSITY = 0.5
GRATINGS, PANELS, RAILS, PIPES = 0, 1, 2, 3
NONE = 255
LAYER_NAMES = ['gratings', 'panels', 'rails', 'pipes']
STRIPS = {
    RAILS: ['skirt', 'girder', 'column', 'railbar', 'nosing', 'hazard', 'chequer', 'brushed'],
    PIPES: ['pipe', 'hose', 'cables', 'lattice', 'vent', 'fins', 'flange', 'rubber'],
}
STRIP_H = 1.0 / 8.0

F_SNOW, F_ICE, F_HAZARD, F_CHAMFER, F_FROST, F_STRIP, F_PAINT = 1, 2, 4, 8, 16, 32, 64

# palette (sRGB): crisp's hard-surface steels kept dark (horror's deep blacks), class-free station accents
C = dict(
    steel=0x46515c, steelD=0x29313a, steelL=0x6a7784, rail=0x73808c, girder=0x1f262e, support=0x1a2129,
    deck=0x3d4651, plate=0x434c57, teal=0x2af5e0, cyan=0x38d8ff, amber=0xffa21a, red=0xff2a3a, green=0x3dff9a,
    orange=0xff5a1a, white=0xeef6ff, crateA=0x5d6b48, crateB=0x3f587a, crateC=0x8a5726, dark=0x0d1115,
    snow=0xc6d2df, ice=0x9fc4dc, label=0xcfc6ad,
)


class Face:
    __slots__ = ('idx', 'tint', 'metal', 'emis', 'layer', 'flags', 'uv', 'smooth')

    def __init__(self, idx, tint, metal, emis, layer, flags, uv, smooth):
        self.idx = idx
        self.tint = tint
        self.metal = metal
        self.emis = emis
        self.layer = layer
        self.flags = flags
        self.uv = uv
        self.smooth = smooth


class Mesh:
    """Vertices + faces (CCW seen from outside)."""

    def __init__(self):
        self.V = []
        self.faces = []

    def add_vertex(self, p):
        self.V.append(np.asarray(p, dtype=np.float64))
        return len(self.V) - 1

    def tris(self):
        return sum(len(f.idx) - 2 for f in self.faces)

    def merge(self, other, M=None):
        """Append another mesh, optionally transformed by a 4×4 matrix (uv rules are re-evaluated on the moved faces
        only for 'tile' faces, so planar mapping stays in world-aligned axes; strip uvs move with the part)."""
        base = len(self.V)
        for p in other.V:
            q = p if M is None else (M[:3, :3] @ p + M[:3, 3])
            self.V.append(q)
        for f in other.faces:
            self.faces.append(Face([i + base for i in f.idx], f.tint, f.metal, f.emis, f.layer, f.flags, f.uv, f.smooth))
        return self

    def array(self):
        return np.array(self.V)


# ---------------------------------------------------------------- material helper
class Mat:
    def __init__(self, tint, metal=0.6, emis=0.0, layer=PANELS, flags=0, uv='tile', strip=None, smooth=False, axis=None):
        self.tint, self.metal, self.emis, self.layer, self.flags = tint, metal, emis, layer, flags
        self.uv, self.strip, self.smooth, self.axis = uv, strip, smooth, axis

    def but(self, **kw):
        m = Mat(self.tint, self.metal, self.emis, self.layer, self.flags, self.uv, self.strip, self.smooth, self.axis)
        for k, v in kw.items():
            setattr(m, k, v)
        return m


def _normal(P):
    n = np.zeros(3)
    for i in range(len(P)):
        n += np.cross(P[i], P[(i + 1) % len(P)])
    ln = np.linalg.norm(n)
    return n / ln if ln > 1e-12 else np.array([0.0, 1.0, 0.0])


def tile_uv(P, n):
    """World-aligned planar projection (2 m per tile); v grows downward on vertical faces."""
    a = int(np.argmax(np.abs(n)))
    if a == 1:      # floor / ceiling: u = x, v = z
        return [(p[0] * DENSITY, p[2] * DENSITY) for p in P]
    if a == 0:      # facing ±x: u along z, v down
        s = 1.0 if n[0] > 0 else -1.0
        return [(-s * p[2] * DENSITY, -p[1] * DENSITY) for p in P]
    s = 1.0 if n[2] > 0 else -1.0
    return [(s * p[0] * DENSITY, -p[1] * DENSITY) for p in P]


def strip_uv(P, n, layer, strip, axis):
    """u along `axis` (unit vector) at the trim density; v across the face mapped onto strip `strip` (0..7) of the
    layer, with a 1/16 inset so bilinear / mips stay inside the strip."""
    axis = np.asarray(axis, dtype=np.float64)
    across = np.cross(n, axis)
    if np.linalg.norm(across) < 1e-6:
        across = np.cross(n, np.array([0.0, 1.0, 0.0]) if abs(n[1]) < 0.9 else np.array([1.0, 0.0, 0.0]))
    across /= np.linalg.norm(across)
    t = np.array([p @ across for p in P])
    lo, hi = t.min(), t.max()
    span = max(hi - lo, 1e-6)
    v0 = strip * STRIP_H
    pad = STRIP_H / 16.0
    return [(float(p @ axis) * DENSITY, v0 + pad + (STRIP_H - 2 * pad) * float((ti - lo) / span)) for p, ti in zip(P, t)]


def add_face(mesh, idx, mat, flags_extra=0):
    P = [mesh.V[i] for i in idx]
    n = _normal(P)
    if mat.layer == NONE:
        uv = [(0.0, 0.0)] * len(P)
    elif mat.uv == 'strip':
        uv = strip_uv(P, n, mat.layer, mat.strip, mat.axis if mat.axis is not None else _long_axis(P))
    else:
        uv = tile_uv(P, n)
    mesh.faces.append(Face(list(idx), mat.tint, mat.metal, mat.emis, mat.layer, mat.flags | flags_extra, uv, mat.smooth))


def _long_axis(P):
    P = np.array(P)
    ext = P.max(0) - P.min(0)
    a = np.zeros(3)
    a[int(np.argmax(ext))] = 1.0
    return a


# ---------------------------------------------------------------- primitives
def cbox(w, h, d, c, mat, chamfer_mat=None, center=(0, 0, 0), bottom=True):
    """Chamfered box (flat): 6 faces, 12 edge chamfers (flag F_CHAMFER: worn bright edge), 8 corner triangles.
    centre = box centre."""
    m = Mesh()
    hx, hy, hz = w / 2, h / 2, d / 2
    c = min(c, hx * 0.49, hy * 0.49, hz * 0.49)
    cx, cy, cz = center
    cm = chamfer_mat or mat
    if c <= 1e-6:       # plain box: 6 faces (5 without the bottom)
        P = {}
        for sx in (-1, 1):
            for sy in (-1, 1):
                for sz in (-1, 1):
                    P[(sx, sy, sz)] = m.add_vertex((hx * sx + cx, hy * sy + cy, hz * sz + cz))
        for ax in range(3):
            for s in (-1, 1):
                if ax == 1 and s == -1 and not bottom:
                    continue
                o1, o2 = [o for o in range(3) if o != ax]
                q = []
                for a, b in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
                    sg = [0, 0, 0]
                    sg[ax], sg[o1], sg[o2] = s, a, b
                    q.append(P[tuple(sg)])
                add_face(m, _ccw(m, q, _axis_vec(ax, s)), mat)
        return m
    # vertex for (corner signs sx, sy, sz) and which axis it is pulled in on: 24 vertices
    V = {}
    for sx in (-1, 1):
        for sy in (-1, 1):
            for sz in (-1, 1):
                for ax in range(3):
                    p = [hx * sx, hy * sy, hz * sz]
                    # pulled in along the other two axes by c: the vertex lying on face `ax`
                    for o in range(3):
                        if o != ax:
                            p[o] -= c * (sx, sy, sz)[o]
                    V[(sx, sy, sz, ax)] = m.add_vertex((p[0] + cx, p[1] + cy, p[2] + cz))
    # faces
    for ax in range(3):
        for s in (-1, 1):
            if ax == 1 and s == -1 and not bottom:
                continue
            o1, o2 = [o for o in range(3) if o != ax]
            corners = []
            for a, b in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
                sg = [0, 0, 0]
                sg[ax] = s
                sg[o1] = a
                sg[o2] = b
                corners.append(V[(sg[0], sg[1], sg[2], ax)])
            add_face(m, _ccw(m, corners, _axis_vec(ax, s)), mat)
    # edge chamfers: for each edge (two axes fixed signs), quad between the two faces' vertices
    for ax in range(3):            # edge runs along axis ax
        o1, o2 = [o for o in range(3) if o != ax]
        for s1 in (-1, 1):
            for s2 in (-1, 1):
                q = []
                for t in (-1, 1):
                    for face_ax in (o1, o2):
                        sg = [0, 0, 0]
                        sg[ax] = t
                        sg[o1] = s1
                        sg[o2] = s2
                        q.append(V[(sg[0], sg[1], sg[2], face_ax)])
                quad = [q[0], q[1], q[3], q[2]]
                out = np.zeros(3)
                out[o1] = s1
                out[o2] = s2
                if not bottom and ((o1 == 1 and s1 == -1) or (o2 == 1 and s2 == -1)):
                    continue
                add_face(m, _ccw(m, quad, out), cm, F_CHAMFER)
    # corner triangles
    for sx in (-1, 1):
        for sy in (-1, 1):
            for sz in (-1, 1):
                if not bottom and sy == -1:
                    continue
                tri = [V[(sx, sy, sz, 0)], V[(sx, sy, sz, 1)], V[(sx, sy, sz, 2)]]
                add_face(m, _ccw(m, tri, np.array([sx, sy, sz], dtype=np.float64)), cm, F_CHAMFER)
    return m


def _axis_vec(ax, s):
    v = np.zeros(3)
    v[ax] = s
    return v


def _ccw(m, idx, out):
    """Order a convex polygon counter-clockwise seen from `out`."""
    P = np.array([m.V[i] for i in idx])
    c = P.mean(0)
    n = np.asarray(out, dtype=np.float64)
    n = n / np.linalg.norm(n)
    a = P[0] - c
    a -= n * (a @ n)
    a /= max(np.linalg.norm(a), 1e-12)
    b = np.cross(n, a)
    ang = [math.atan2((p - c) @ b, (p - c) @ a) for p in P]
    order = sorted(range(len(idx)), key=lambda k: ang[k])
    return [idx[k] for k in order]


def transform(mesh, M):
    out = Mesh()
    return out.merge(mesh, M)


def T(x=0.0, y=0.0, z=0.0, ry=0.0, s=1.0):
    c, sn = math.cos(ry), math.sin(ry)
    M = np.eye(4)
    M[:3, :3] = np.array([[c, 0, sn], [0, 1, 0], [-sn, 0, c]]) * s
    M[:3, 3] = (x, y, z)
    return M


def beam(p0, p1, w, h, c, mat, chamfer_mat=None):
    """Chamfered box of cross-section w (horizontal) × h (vertical) between two points; strip uvs run along it."""
    p0 = np.asarray(p0, dtype=np.float64)
    p1 = np.asarray(p1, dtype=np.float64)
    d = p1 - p0
    L = np.linalg.norm(d)
    ax = d / L
    b = cbox(L, h, w, c, mat.but(axis=(1, 0, 0)) if mat.uv == 'strip' else mat,
             (chamfer_mat or mat).but(axis=(1, 0, 0)) if (chamfer_mat or mat).uv == 'strip' else chamfer_mat)
    # frame: x' = ax, y' = up-ish, z' = x' × y'
    up = np.array([0.0, 1.0, 0.0])
    if abs(ax @ up) > 0.95:
        up = np.array([1.0, 0.0, 0.0])
    zz = np.cross(ax, up)
    zz /= np.linalg.norm(zz)
    yy = np.cross(zz, ax)
    M = np.eye(4)
    M[:3, 0], M[:3, 1], M[:3, 2] = ax, yy, zz
    M[:3, 3] = (p0 + p1) / 2
    return transform(b, M)


def lathe(profile, seg, mat, phase=0.0, cap_top=True, smooth=False, mats=None):
    """Revolve [(r, y)] (bottom to top) around +y with `seg` sides. mats: optional per-band Mat (len(profile)-1).
    A point with r = 0 closes the solid."""
    m = Mesh()
    rings = []
    for (r, y) in profile:
        if r <= 1e-9:
            rings.append([m.add_vertex((0.0, y, 0.0))])
            continue
        ring = []
        for k in range(seg):
            a = phase + 2 * math.pi * k / seg
            ring.append(m.add_vertex((r * math.cos(a), y, -r * math.sin(a))))
        rings.append(ring)
    for b in range(len(rings) - 1):
        A, B = rings[b], rings[b + 1]
        mt = mats[b] if mats else mat
        (r0, y0), (r1, y1) = profile[b], profile[b + 1]
        if len(A) == 1 and len(B) == 1:
            continue
        for k in range(seg):
            k1 = (k + 1) % seg
            if len(A) == 1:
                tri = [A[0], B[k1], B[k]] if y1 >= y0 else [A[0], B[k], B[k1]]
                add_face(m, _ccw(m, tri, _band_normal(m, tri, y1 > y0)), mt)
            elif len(B) == 1:
                tri = [A[k], A[k1], B[0]]
                add_face(m, _ccw(m, tri, _band_normal(m, tri, y1 > y0, top=True)), mt)
            else:
                q = [A[k], A[k1], B[k1], B[k]]
                P = np.array([m.V[i] for i in q])
                c = P.mean(0)
                outward = np.array([c[0], 0.0, c[2]])
                if np.linalg.norm(outward) < 1e-9:
                    outward = np.array([0.0, 1.0, 0.0])
                # band normal: outward radial for walls, ±y for flat rings
                if abs(y1 - y0) < 1e-9:
                    o = np.array([0.0, 1.0 if r1 < r0 else -1.0, 0.0])
                else:
                    o = outward / np.linalg.norm(outward) + np.array([0.0, (r0 - r1) / abs(y1 - y0), 0.0])
                flags = F_CHAMFER if (abs(y1 - y0) > 1e-9 and abs(r1 - r0) > 1e-9 and 0.3 < abs(r0 - r1) / abs(y1 - y0) < 3.5) else 0
                add_face(m, _ccw(m, q, o), mt, flags)
    if cap_top and len(rings[-1]) > 1:
        add_face(m, _ccw(m, list(rings[-1]), (0, 1, 0)), mats[-1] if mats else mat)
    return m


def _band_normal(m, tri, up, top=False):
    P = np.array([m.V[i] for i in tri])
    c = P.mean(0)
    return np.array([c[0], 1.0 if (top or up) else -1.0, c[2]])


def cylinder(r, length, seg, mat, axis='x', cap=True, phase=None):
    """Prism of `seg` sides along an axis, centred at the origin (pipes, bars); smooth when mat.smooth."""
    prof = [(0.0, -length / 2), (r, -length / 2), (r, length / 2), (0.0, length / 2)] if cap else \
        [(r, -length / 2), (r, length / 2)]
    m = lathe(prof, seg, mat, phase=math.pi / seg if phase is None else phase, cap_top=False)
    if axis == 'x':
        M = np.eye(4)
        M[:3, :3] = np.array([[0, 1, 0], [-1, 0, 0], [0, 0, 1]], dtype=np.float64)     # +y -> +x
        return transform(m, M)
    if axis == 'z':
        M = np.eye(4)
        M[:3, :3] = np.array([[1, 0, 0], [0, 0, -1], [0, 1, 0]], dtype=np.float64)     # +y -> +z
        return transform(m, M)
    return m


def icicle(x, z, length, r, mat, seg=5, rot=0.0):
    """Tapered pyramid hanging from y = 0 down to -length (tip slightly off-axis)."""
    m = Mesh()
    top = [m.add_vertex((x + r * math.cos(rot + 2 * math.pi * k / seg), 0.0, z - r * math.sin(rot + 2 * math.pi * k / seg)))
           for k in range(seg)]
    mid = [m.add_vertex((x + 0.55 * r * math.cos(rot + 0.3 + 2 * math.pi * k / seg), -0.45 * length,
                         z - 0.55 * r * math.sin(rot + 0.3 + 2 * math.pi * k / seg))) for k in range(seg)]
    tip = m.add_vertex((x + 0.15 * r, -length, z))
    for k in range(seg):
        k1 = (k + 1) % seg
        q = [top[k], top[k1], mid[k1], mid[k]]
        P = np.array([m.V[i] for i in q])
        o = P.mean(0) - np.array([x, P.mean(0)[1] + 0.2, z])
        add_face(m, _ccw(m, q, o), mat)
        tri = [mid[k], mid[k1], tip]
        P = np.array([m.V[i] for i in tri])
        o = P.mean(0) - np.array([x, -length * 0.4, z])
        add_face(m, _ccw(m, tri, o), mat)
    add_face(m, _ccw(m, top, (0, 1, 0)), mat)
    return m


def mound(length, width, height, mat, nu=14, nv=6, seed=0, tilt=0.0):
    """A low snow drift banked against a railing: a soft ridge along x (length) on a flat base at y = -0.015, its crest
    nearer the -z side (the rail; tilt 0..1 = how wind-packed), an irregular outline (no lens / saucer shape)."""
    R = np.random.RandomState(seed)
    wob = R.uniform(-1, 1, nu + 1)
    m = Mesh()
    grid = []
    for i in range(nu + 1):
        u = i / nu
        row = []
        # footprint: rounded ends, a wobbling width
        env = max(0.18, math.sin(math.pi * u) ** 0.45) * (1.0 + 0.22 * wob[i])
        for j in range(nv + 1):
            v = j / nv
            x = (u - 0.5) * length
            z = (v - 0.5) * width * env
            # crest at v ≈ 0.3 (rail side), a gentle tail toward the deck
            t = v / 0.3 if v < 0.3 else (1.0 - v) / 0.7
            prof = math.sin(0.5 * math.pi * max(0.0, min(1.0, t))) ** (1.2 - 0.5 * tilt)
            hgt = height * min(1.0, env) ** 1.3 * prof * (0.8 + 0.4 * R.rand())
            edge = i in (0, nu) or j in (0, nv)
            y = -0.015 if edge else max(-0.015, hgt)
            row.append(m.add_vertex((x, y, z)))
        grid.append(row)
    for i in range(nu):
        for j in range(nv):
            q = [grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1]]
            add_face(m, _ccw(m, q, (0, 1, 0)), mat)
    return m
