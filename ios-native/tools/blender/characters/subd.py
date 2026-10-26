"""Sub-d hard-surface modelling for the marines (WP4 «Отряд»): quad CAGES subdivided by Blender's Catmull–Clark
(Subdivision modifier with edge creases) — the shipped LOW mesh is level 1 of a cage, the HIGH bake source level 3
plus the cage's panel seams — curved SECTOR SHELLS for limb armour, and plates / visors / strips CONFORMED onto a
finished surface by ray casting (they follow its curvature instead of sticking out as flat boxes).

All functions take / return numpy (V (n, 3), F [index lists]) in model space (game axes).
"""
import math

import bpy
import bmesh
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

_tmp = [0]


def _bm(V, F):
    bm = bmesh.new()
    vs = [bm.verts.new(tuple(map(float, v))) for v in V]
    for f in F:
        if len(set(f)) < 3:
            continue
        try:
            bm.faces.new([vs[i] for i in f])
        except ValueError:
            pass
    bm.normal_update()
    return bm


def _out(bm):
    bm.verts.index_update()
    V = np.array([v.co[:] for v in bm.verts]) if len(bm.verts) else np.zeros((0, 3))
    F = [[v.index for v in f.verts] for f in bm.faces]
    return V, F


def subd(V, F, level, crease_deg=55.0, crease=0.9, boundary_crease=0.0, extra=None, fix_normals=True):
    """Catmull–Clark `level` times; cage edges sharper than crease_deg get `crease` (hard rims), boundary edges
    `boundary_crease`; extra: {(i, j): crease} by cage vertex pairs."""
    if level <= 0:
        return np.asarray(V), [list(f) for f in F]
    bm = _bm(V, F)
    if fix_normals:
        bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    cl = bm.edges.layers.float.get('crease_edge') or bm.edges.layers.float.new('crease_edge')
    bm.verts.index_update()
    ex = {}
    if extra:
        for (i, j), c in extra.items():
            ex[frozenset((i, j))] = c
    for e in bm.edges:
        key = frozenset((e.verts[0].index, e.verts[1].index))
        if key in ex:
            e[cl] = ex[key]
        elif len(e.link_faces) == 2:
            a = e.link_faces[0].normal.angle(e.link_faces[1].normal, 0.0)
            e[cl] = crease if a > math.radians(crease_deg) else 0.0
        else:
            e[cl] = boundary_crease
    _tmp[0] += 1
    me = bpy.data.meshes.new(f'_subd{_tmp[0]}')
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(me.name, me)
    bpy.context.scene.collection.objects.link(ob)
    m = ob.modifiers.new('s', 'SUBSURF')
    m.levels = level
    m.render_levels = level
    m.use_creases = True
    m.quality = 3
    m.boundary_smooth = 'PRESERVE_CORNERS'
    dg = bpy.context.evaluated_depsgraph_get()
    ev = ob.evaluated_get(dg)
    em = ev.to_mesh()
    n = len(em.vertices)
    co = np.empty(n * 3, np.float32)
    em.vertices.foreach_get('co', co)
    Fo = [list(p.vertices) for p in em.polygons]
    ev.to_mesh_clear()
    bpy.data.objects.remove(ob)
    bpy.data.meshes.remove(me)
    return co.reshape(-1, 3).astype(np.float64), Fo


# ---------------------------------------------------------------- cages
def ring(points_xz, y):
    return np.array([(x, y, z) for x, z in points_xz])


def superellipse(a, b, n, e=2.6, cx=0.0, cz=0.0, front=0.0, back=0.0, start=0.0):
    """n points of |x/a|^e + |z/b|^e = 1 (counter-clockwise seen from +y, starting at +x); `front` / `back` push the
    z extremes (keel / spine)."""
    pts = []
    for k in range(n):
        t = 2 * math.pi * (k / n) + start
        c, s = math.cos(t), math.sin(t)
        x = a * math.copysign(abs(c) ** (2 / e), c)
        z = b * math.copysign(abs(s) ** (2 / e), s)
        if s > 0:
            z += front * (s ** 4)
        else:
            z -= back * (s ** 4)
        pts.append((cx + x, cz + z))
    return pts


def loft_cage(rings, cap0=True, cap1=True):
    """Rings (n, 3) bottom → top, same n; quads between, n-gon caps."""
    rs = [np.asarray(r, dtype=np.float64) for r in rings]
    n = len(rs[0])
    V = np.concatenate(rs)
    F = []
    for k in range(len(rs) - 1):
        for i in range(n):
            j = (i + 1) % n
            F.append([k * n + i, k * n + j, (k + 1) * n + j, (k + 1) * n + i])
    if cap0:
        F.append(list(range(n))[::-1])
    if cap1:
        F.append([(len(rs) - 1) * n + i for i in range(n)])
    return V, F


def grid_cage(nu, nv, fn):
    """A quad patch: fn(u, v) → point, u, v ∈ [0, 1] (open surface)."""
    V = [fn(i / nu, j / nv) for j in range(nv + 1) for i in range(nu + 1)]
    F = []
    for j in range(nv):
        for i in range(nu):
            a = j * (nu + 1) + i
            F.append([a, a + 1, a + nu + 2, a + nu + 1])
    return np.array(V, dtype=np.float64), F


def vertex_normals(V, F):
    """Area-weighted vertex normals in a fixed order (numpy: deterministic; bmesh's threaded normal update is not
    bit-stable between runs)."""
    V = np.asarray(V, dtype=np.float64)
    N = np.zeros_like(V)
    for f in F:
        P = V[f]
        n = np.zeros(3)
        for k in range(1, len(f) - 1):
            n += np.cross(P[k] - P[0], P[k + 1] - P[0])
        for i in f:
            N[i] += n
    L = np.linalg.norm(N, axis=1, keepdims=True)
    return N / np.maximum(L, 1e-12)


def boundary_loops(F):
    """Directed boundary edges (a, b) of a patch, in face order (edges used by one face only, as that face runs them)."""
    count = {}
    for f in F:
        for k in range(len(f)):
            a, b = f[k], f[(k + 1) % len(f)]
            key = (min(a, b), max(a, b))
            count[key] = count.get(key, 0) + 1
    out = []
    for f in F:
        for k in range(len(f)):
            a, b = f[k], f[(k + 1) % len(f)]
            if count[(min(a, b), max(a, b))] == 1:
                out.append((a, b))
    return out


def thicken(V, F, t, inward=True):
    """Solidify an open patch at cage level (quads kept): an offset copy along the vertex normals (inward = against
    them) + side walls along the boundary."""
    V = np.asarray(V, dtype=np.float64)
    N = vertex_normals(V, F)
    d = -t if inward else t
    n = len(V)
    V2 = np.concatenate([V, V + N * d])
    F2 = [list(f) for f in F] + [[i + n for i in f[::-1]] for f in F]
    for a, b in boundary_loops(F):
        F2.append([b, a, a + n, b + n])
    return V2, F2


def sector_shell(r0, r1, a0, a1, length, t, nu=6, nv=3, bulge=0.0, ridge=0.0, flare=0.0, y0=0.0, ecc=1.0):
    """Curved plate wrapping +y (a limb): radius r0 at y0 → r1 at y0 + length, angles a0 → a1 (deg; 0 = +z front,
    90 = +x), thickness t (inward). bulge: outward belly mid-length; ridge: a keel along the middle angle; flare:
    the bottom rim kicks out; ecc: z / x radius ratio."""
    am = 0.5 * (a0 + a1)

    def fn(u, v):
        a = math.radians(a0 + (a1 - a0) * u)
        r = r0 + (r1 - r0) * v + bulge * math.sin(math.pi * v) + flare * max(0.0, 0.25 - v) * 4
        r += ridge * max(0.0, 1.0 - abs((a0 + (a1 - a0) * u) - am) / max(1e-6, 0.5 * (a1 - a0))) ** 2
        return (r * math.sin(a), y0 + length * v, r * math.cos(a) * ecc)
    V, F = grid_cage(nu, nv, fn)
    return thicken(V, F, t)


def box_cage(sx, sy, sz, nx=1, ny=1, nz=1):
    """Axis box centred at the origin with nx × ny × nz face divisions (shape it with deform())."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co.x *= sx
        v.co.y *= sy
        v.co.z *= sz
    cuts = []
    for axis, n in ((0, nx), (1, ny), (2, nz)):
        if n > 1:
            edges = [e for e in bm.edges if abs((e.verts[0].co - e.verts[1].co)[axis]) > 1e-6]
            bmesh.ops.subdivide_edges(bm, edges=edges, cuts=n - 1, use_grid_fill=True)
    V, F = _out(bm)
    bm.free()
    return V, F


def deform(VF, fn):
    V, F = VF
    return np.array([fn(np.asarray(p)) for p in V]), F


def inset_seams(V, F, select, inset, depth):
    """HIGH cages: faces chosen by select(centre, normal, area) get an inset ring pushed in (a panel seam once
    subdivided)."""
    bm = _bm(V, F)
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    faces = [f for f in bm.faces if select(np.array(f.calc_center_median()[:]), np.array(f.normal[:]), f.calc_area())]
    for f in faces:
        n = f.normal.copy()
        bmesh.ops.inset_individual(bm, faces=[f], thickness=inset, depth=0.0, use_even_offset=True)
        bmesh.ops.inset_individual(bm, faces=[f], thickness=inset * 0.35, depth=0.0, use_even_offset=True)
        for v in f.verts:
            v.co -= n * depth * 0.2
    # the seam ring (between the two insets) goes in
    V2, F2 = _out(bm)
    bm.free()
    return V2, F2


# ---------------------------------------------------------------- conforming
class Surface:
    """Ray-cast target built from finished geometry (several meshes)."""

    def __init__(self, *meshes):
        Vs, Fs, off = [], [], 0
        for V, F in meshes:
            Vs.append(np.asarray(V))
            for f in F:
                if len(f) == 3:
                    Fs.append([i + off for i in f])
                else:
                    for k in range(1, len(f) - 1):
                        Fs.append([f[0] + off, f[k] + off, f[k + 1] + off])
            off += len(V)
        self.V = np.concatenate(Vs)
        self.tree = BVHTree.FromPolygons([tuple(map(float, v)) for v in self.V], Fs, all_triangles=True, epsilon=0.0)

    def lift(self, V, gap, out, reach=0.04):
        """Push the vertices of a shape laid on this surface out to at least `gap` above it (along the surface normal
        turned toward `out`): a coarse conformed plate's chords — and the sub-d that rounds it — dip under a convex
        surface, which then pokes through in blotches."""
        V = np.array(V, dtype=np.float64)
        out = np.asarray(out, dtype=np.float64)
        for i, p in enumerate(V):
            loc, n, _, dist = self.tree.find_nearest(Vector(tuple(map(float, p))), reach)
            if loc is None:
                continue
            n = np.array(n[:])
            if np.dot(n, out) < 0:
                n = -n
            h = float(np.dot(p - np.array(loc[:]), n))
            if h < gap:
                V[i] = p + n * (gap - h)
        return V

    def hit(self, origin, direction, maxd=1.0):
        loc, n, _, d = self.tree.ray_cast(Vector(tuple(map(float, origin))), Vector(tuple(map(float, direction))), maxd)
        if loc is None:
            return None, None
        return np.array(loc[:]), np.array(n[:])


def conform(surface, frame_m, outline, nu, nv, gap, thickness, fallback=0.05):
    """A plate on a surface: `outline(u, v)` → (a, b) plane coordinates (u, v ∈ [0, 1]) in the plane of frame_m
    (columns: a axis, b axis, the projection direction INTO the surface, origin); each point is cast along the
    projection direction onto the surface and lifted by `gap`, then thickened outward by `thickness`. Returns (V, F)
    or None when the plate misses the surface."""
    M = np.asarray(frame_m)
    A, B, D, O = M[:3, 0], M[:3, 1], M[:3, 2], M[:3, 3]
    pts, nrm = [], []
    for j in range(nv + 1):
        for i in range(nu + 1):
            a, b = outline(i / nu, j / nv)
            p0 = O + A * a + B * b - D * 0.05
            h, n = surface.hit(p0, D, 2.0)
            if h is None:
                return None
            if np.dot(n, D) > 0:
                n = -n
            pts.append(h + n * gap)
            nrm.append(n)
    pts, nrm = np.array(pts), np.array(nrm)
    # smooth the normals a little (plates stay flat-ish over small bumps)
    F = []
    for j in range(nv):
        for i in range(nu):
            a = j * (nu + 1) + i
            F.append([a, a + nu + 1, a + nu + 2, a + 1])
    top = pts + nrm * thickness
    n0 = len(pts)
    V = np.concatenate([pts, top])
    F2 = [[i + n0 for i in f[::-1]] for f in F] + F
    # side walls along the boundary
    bnd = []
    for i in range(nu):
        bnd.append((i, i + 1))
    for j in range(nv):
        bnd.append((j * (nu + 1) + nu, (j + 1) * (nu + 1) + nu))
    for i in range(nu, 0, -1):
        bnd.append((nv * (nu + 1) + i, nv * (nu + 1) + i - 1))
    for j in range(nv, 0, -1):
        bnd.append((j * (nu + 1), (j - 1) * (nu + 1)))
    for a, b in bnd:
        F2.append([a, b, b + n0, a + n0])
    return V, F2


def rect_outline(w, h, r=0.25, taper=0.0, skew=0.0):
    """Rounded-ish rectangle outline (corners pulled in by r of the half sizes), top width × (1 − taper)."""
    def fn(u, v):
        x = (u - 0.5) * w
        y = (v - 0.5) * h
        k = 1.0 - taper * v
        cu, cv = abs(u - 0.5) * 2, abs(v - 0.5) * 2
        pull = r * max(0.0, cu + cv - 1.0)
        return x * k * (1 - pull * 0.5) + skew * (v - 0.5) * h, y * (1 - pull * 0.5)
    return fn


def frame_at(origin, a_axis, b_axis, into):
    M = np.eye(4)
    a = np.asarray(a_axis, dtype=np.float64)
    a /= np.linalg.norm(a)
    d = np.asarray(into, dtype=np.float64)
    d /= np.linalg.norm(d)
    b = np.asarray(b_axis, dtype=np.float64)
    b = b - d * np.dot(b, d) - a * np.dot(b, a)
    b /= np.linalg.norm(b)
    M[:3, 0], M[:3, 1], M[:3, 2], M[:3, 3] = a, b, d, origin
    return M


def orient_out(V, F, inner):
    """Flip a patch's faces so their normals point away from `inner` (a point inside the limb / shoulder)."""
    V = np.asarray(V)
    c = V.mean(0)
    f = F[len(F) // 2]
    a, b_, cc = V[f[0]], V[f[1]], V[f[2]]
    n = np.cross(b_ - a, cc - a)
    if np.dot(n, np.mean(V[f], 0) - np.asarray(inner)) < 0:
        F = [list(x)[::-1] for x in F]
    return V, F


def rimmed(V, F, depth, inner=None):
    """Single-sided shell with an inward-folded rim of `depth` (the inside of a limb plate always faces the limb):
    the patch boundary gets one row of quads toward −normal. Half the triangles of a thickened shell."""
    if inner is not None:
        V, F = orient_out(V, F, inner)
    V = np.asarray(V, dtype=np.float64)
    N = vertex_normals(V, F)
    bnd = boundary_loops(F)
    verts = sorted(set([a for a, _ in bnd] + [b for _, b in bnd]))
    new = {v: len(V) + k for k, v in enumerate(verts)}
    V2 = np.concatenate([V, np.array([V[v] - N[v] * depth for v in verts])])
    F2 = [list(f) for f in F]
    for a, b in bnd:
        F2.append([b, a, new[a], new[b]])
    return V2, F2
