"""Hard-surface primitives for the marines (WP4 «Отряд»), headless Blender (bmesh): chamfered frustum boxes, extruded
profiles, lathes, lofts and shells, each built at two detail levels from the same parameters — LOW (what ships: 1–2
chamfer segments) and HIGH (the bake source: rounder chamfers, inset panel grooves, bolt and vent floaters). A
`Part` is a mesh in MODEL space (game axes: x = the marine's left, y up, z forward) with a bone, a material slot
and per-face flags; `Body` collects the parts of one marine.

Everything is deterministic (no random calls without a fixed seed, sorted iteration).
"""
import math

import bpy  # noqa: F401  (bmesh needs bpy loaded first)
import bmesh
import numpy as np
from mathutils import Matrix, Vector

# material slots (marines.py MATERIALS gives colour / roughness / metal per class); HOT = gunmetal that glows with heat
# under sustained fire (barrels, muzzle brakes, the flamer's nozzle, the cryo emitter: vertex flag bit3)
ARMOUR, PAINT, DARK, METAL, GLOW, GLASS, SOLE, LAMP, BRASS, HOT = range(10)


class Part:
    def __init__(self, name, bone, mat, verts, faces, smooth=True, sharp_deg=40.0, blend=None):
        self.name, self.bone, self.mat = name, bone, mat
        self.verts = np.asarray(verts, dtype=np.float64)
        self.faces = [list(f) for f in faces]
        self.smooth = smooth
        self.sharp_deg = sharp_deg
        self.face_mat = [mat] * len(self.faces)
        self.blend = blend          # None (rigid) or (other bone, function(v) → weight of the other bone)

    def transformed(self, M):
        p = Part.__new__(Part)
        p.__dict__.update(self.__dict__)
        V = np.c_[self.verts, np.ones(len(self.verts))] @ np.asarray(M).T
        p.verts = V[:, :3]
        p.faces = [list(f) for f in self.faces]
        p.face_mat = list(self.face_mat)
        return p

    @property
    def tris(self):
        return sum(len(f) - 2 for f in self.faces)


# ---------------------------------------------------------------- matrices
def T(x=0.0, y=0.0, z=0.0):
    return np.array(Matrix.Translation((x, y, z)))


def R(axis, deg):
    return np.array(Matrix.Rotation(math.radians(deg), 4, axis))


def S(x=1.0, y=None, z=None):
    y = x if y is None else y
    z = x if z is None else z
    return np.diag([x, y, z, 1.0])


def frame(origin, ydir, zhint=(0, 0, 1)):
    """Matrix taking local (x, y, z) to model space with local +y along ydir (a limb) and local +z toward zhint."""
    y = np.asarray(ydir, dtype=np.float64)
    y /= np.linalg.norm(y)
    z = np.asarray(zhint, dtype=np.float64)
    z = z - y * np.dot(z, y)
    z /= np.linalg.norm(z)
    x = np.cross(y, z)
    M = np.eye(4)
    M[:3, 0], M[:3, 1], M[:3, 2], M[:3, 3] = x, y, z, origin
    return M


def mm(*ms):
    out = np.eye(4)
    for m in ms:
        out = out @ m
    return out


# ---------------------------------------------------------------- bmesh helpers
def _bm(verts, faces):
    bm = bmesh.new()
    vs = [bm.verts.new(tuple(v)) for v in verts]
    for f in faces:
        try:
            bm.faces.new([vs[i] for i in f])
        except ValueError:
            pass
    bm.normal_update()
    return bm


def _out(bm):
    bm.verts.index_update()
    V = np.array([v.co[:] for v in bm.verts])
    F = [[v.index for v in f.verts] for f in bm.faces]
    return V, F


def bevel_mesh(verts, faces, width, segs, profile=0.5, sharp_only_deg=None):
    """Chamfer the edges (all, or only those sharper than sharp_only_deg) of a closed mesh."""
    if width <= 0 or segs <= 0:
        return np.asarray(verts), faces
    bm = _bm(verts, faces)
    edges = list(bm.edges)
    if sharp_only_deg is not None:
        edges = [e for e in edges if len(e.link_faces) == 2
                 and e.link_faces[0].normal.angle(e.link_faces[1].normal, 0.0) > math.radians(sharp_only_deg)]
    bmesh.ops.bevel(bm, geom=edges, offset=width, offset_type='OFFSET', segments=segs, profile=profile,
                    affect='EDGES', clamp_overlap=True, harden_normals=False)
    V, F = _out(bm)
    bm.free()
    return V, F


def inset_panels(verts, faces, min_area, inset, depth, axis_dot=None):
    """HIGH detail: every face larger than min_area gets an inset panel pushed in by `depth` (a groove around it)."""
    bm = _bm(verts, faces)
    sel = [f for f in bm.faces if f.calc_area() > min_area]
    if axis_dot is not None:
        a = Vector(axis_dot[0])
        sel = [f for f in sel if f.normal.dot(a) > axis_dot[1]]
    for f in sel:
        r = bmesh.ops.inset_individual(bm, faces=[f], thickness=inset, depth=0.0, use_even_offset=True)
        # groove: the rim faces stay, the centre panel moves in and back out (a raised panel with a recessed seam)
        n = f.normal.copy()
        for v in f.verts:
            v.co -= n * depth
        r2 = bmesh.ops.inset_individual(bm, faces=[f], thickness=inset * 0.6, depth=0.0, use_even_offset=True)
        for v in f.verts:
            v.co += n * depth * 0.85
    bm.normal_update()
    V, F = _out(bm)
    bm.free()
    return V, F


# ---------------------------------------------------------------- primitives (local space)
def frustum(w0, d0, w1, d1, h, dx=0.0, dz=0.0, y0=0.0):
    """Box from a w0 × d0 bottom (at y0) to a w1 × d1 top at y0 + h, the top shifted by (dx, dz)."""
    b = [(-w0 / 2, y0, -d0 / 2), (w0 / 2, y0, -d0 / 2), (w0 / 2, y0, d0 / 2), (-w0 / 2, y0, d0 / 2)]
    t = [(-w1 / 2 + dx, y0 + h, -d1 / 2 + dz), (w1 / 2 + dx, y0 + h, -d1 / 2 + dz), (w1 / 2 + dx, y0 + h, d1 / 2 + dz),
         (-w1 / 2 + dx, y0 + h, d1 / 2 + dz)]
    V = b + t
    F = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]
    return np.array(V), F


def prism(profile, depth, axis='x', center=True):
    """Extrude a 2D polygon (counter-clockwise in its plane) by `depth`. axis x: profile in (z, y) extruded along
    x; axis z: profile in (x, y) along z; axis y: profile in (x, z) along y."""
    P = np.asarray(profile, dtype=np.float64)
    n = len(P)
    o = -depth / 2 if center else 0.0
    V = []
    for s in (o, o + depth):
        for a, b in P:
            if axis == 'x':
                V.append((s, b, a))
            elif axis == 'z':
                V.append((a, b, s))
            else:
                V.append((a, s, b))
    F = [list(range(n))[::-1], list(range(n, 2 * n))]
    for i in range(n):
        j = (i + 1) % n
        F.append([i, j, n + j, n + i])
    V = np.array(V)
    if axis == 'x':
        # (z, y) counter-clockwise seen from +x → caps need flipping for outward normals
        F = [f[::-1] for f in F]
    return V, F


def lathe(profile, segs, a0=0.0, a1=360.0, cap0=True, cap1=True, axis='y'):
    """Revolve [(r, h)] about +y (axis y) or +z (axis z): profile bottom → top. Partial sweeps are open."""
    P = np.asarray(profile, dtype=np.float64)
    full = abs(a1 - a0) >= 359.999
    na = segs if full else segs + 1
    V = []
    for i in range(na):
        a = math.radians(a0 + (a1 - a0) * i / segs)
        c, s = math.cos(a), math.sin(a)
        for r, h in P:
            if axis == 'y':
                V.append((r * s, h, r * c))
            else:
                V.append((r * c, r * s, h))
    m = len(P)
    F = []
    for i in range(segs):
        i2 = (i + 1) % na
        for k in range(m - 1):
            a, b, c2, d = i * m + k, i2 * m + k, i2 * m + k + 1, i * m + k + 1
            F.append([a, d, c2, b] if axis == 'y' else [a, b, c2, d])
    V = list(V)
    if full:
        if cap0 and P[0][0] > 1e-6:
            F.append([i * m for i in range(na)][::-1] if axis == 'y' else [i * m for i in range(na)])
            F[-1] = F[-1] if axis == 'y' else F[-1][::-1]
        if cap1 and P[-1][0] > 1e-6:
            F.append([i * m + m - 1 for i in range(na)] if axis == 'y' else [i * m + m - 1 for i in range(na)][::-1])
    return np.array(V), F


def loft(sections, cap0=True, cap1=True):
    """Sections: list of (n, 3) closed rings (same n, consistent winding), bottom → top."""
    secs = [np.asarray(s, dtype=np.float64) for s in sections]
    n = len(secs[0])
    V = np.concatenate(secs)
    F = []
    for k in range(len(secs) - 1):
        for i in range(n):
            j = (i + 1) % n
            F.append([k * n + i, k * n + j, (k + 1) * n + j, (k + 1) * n + i])
    if cap0:
        F.append(list(range(n))[::-1])
    if cap1:
        F.append([(len(secs) - 1) * n + i for i in range(n)])
    return V, F


def rrect(w, d, r, seg=2, cx=0.0, cz=0.0, y=0.0):
    """Rounded rectangle ring in the xz plane (counter-clockwise from +y), corner radius r."""
    pts = []
    corners = [(w / 2 - r, d / 2 - r, 0), (-w / 2 + r, d / 2 - r, 90), (-w / 2 + r, -d / 2 + r, 180), (w / 2 - r, -d / 2 + r, 270)]
    for x0, z0, a0 in corners:
        for i in range(seg + 1):
            a = math.radians(a0 + 90.0 * i / seg)
            pts.append((cx + x0 + r * math.cos(a), y, cz + z0 + r * math.sin(a)))
    return np.array(pts)


def shell(V, F, thickness):
    """Give an open surface a thickness along its vertex normals (solidify), outward = the original side."""
    bm = _bm(V, F)
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    res = bmesh.ops.solidify(bm, geom=list(bm.faces), thickness=thickness)
    V2, F2 = _out(bm)
    bm.free()
    return V2, F2


def cyl(r, h, segs=12, y0=0.0, r1=None):
    r1 = r if r1 is None else r1
    return lathe([(r, y0), (r1, y0 + h)], segs)


def merge(*meshes):
    V, F = [], []
    off = 0
    for v, f in meshes:
        V.append(np.asarray(v))
        F += [[i + off for i in face] for face in f]
        off += len(v)
    return np.concatenate(V), F


def xform(VF, M):
    V, F = VF
    V = np.c_[V, np.ones(len(V))] @ np.asarray(M).T
    return V[:, :3], F


def mirror_x(VF):
    V, F = VF
    V = np.asarray(V).copy()
    V[:, 0] *= -1
    return V, [f[::-1] for f in F]


# ---------------------------------------------------------------- detail floaters (HIGH only)
def bolt(p, n, r=0.008, h=0.004, segs=6):
    """A bolt head on a surface point p with normal n (floats on it; baked into the normal map)."""
    V, F = lathe([(r, 0.0), (r, h * 0.6), (r * 0.7, h)], segs)
    return xform((V, F), frame(np.asarray(p) + np.asarray(n) * 0.0005, n, (0.3, 0.7, 0.1) if abs(n[1]) < 0.9 else (1, 0, 0)))


def slots(p, n, along, count, length, width, gap, depth=0.004):
    """A row of vent slots (raised frames) on a surface."""
    n = np.asarray(n, dtype=np.float64)
    a = np.asarray(along, dtype=np.float64)
    a = a - n * np.dot(a, n)
    a /= np.linalg.norm(a)
    b = np.cross(n, a)
    out = []
    for i in range(count):
        c = np.asarray(p) + a * ((i - (count - 1) / 2) * (width + gap))
        V, F = frustum(width, length, width * 0.7, length * 0.85, depth)
        M = np.eye(4)
        M[:3, 0], M[:3, 1], M[:3, 2], M[:3, 3] = a, n, b, c - n * depth * 0.6
        out.append(xform((V, F), M))
    return merge(*out)
