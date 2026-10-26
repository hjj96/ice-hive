"""Procedural mesh primitives (pure numpy) for the Ice Hive asset pipeline.

Every builder returns a Part: vertices (n,3) float64, faces (list of int tuples, CCW seen from outside),
plus per-part metadata the assembler turns into Blender attributes / vertex groups.
Coordinates are Blender's: X = side, Y = forward (nose), Z = up, metres.
"""
import math
import numpy as np


class Part:
    def __init__(self, name, V, F, bone, color, glow=0.0, rough=0.5, flags=0, smooth=True, sharp_deg=80.0,
                 vcolor=None, gland_centers=None):
        self.name = name
        self.V = np.asarray(V, dtype=np.float64).reshape(-1, 3)
        self.F = [tuple(int(i) for i in f) for f in F]
        self.bone = bone
        self.color = color            # base sRGB hex (int) or (r,g,b) 0..1 sRGB
        self.vcolor = vcolor          # optional per-vertex sRGB (n,3) overriding color
        self.glow = glow              # 0..1 emissive strength of this part
        self.rough = rough
        self.flags = flags            # bit0 gland, bit1 eye, bit2 claw / edge
        self.smooth = smooth
        self.sharp_deg = sharp_deg
        self.gland_centers = gland_centers or []

    def tris(self):
        return sum(len(f) - 2 for f in self.F)


def hex2rgb(h):
    return np.array([(h >> 16) & 255, (h >> 8) & 255, h & 255], dtype=np.float64) / 255.0


def _norm(v):
    n = np.linalg.norm(v)
    return v / n if n > 1e-12 else v


def _perp_frame(t, up):
    up = np.asarray(up, dtype=np.float64)
    n1 = np.cross(up, t)
    if np.linalg.norm(n1) < 1e-6:
        n1 = np.cross(np.array([1.0, 0, 0]), t)
    n1 = _norm(n1)
    n2 = _norm(np.cross(t, n1))
    return n1, n2


def tube(path, radii, sides, up=(0, 0, 1), cap0=True, tip=False, cap1=True, phase=0.0, flat=1.0):
    """Loft a (possibly elliptic: radii (m,2)) cross-section along a polyline with parallel-transport frames.
    tip=True: the last point becomes a single apex vertex (pointed end). flat scales the n2 radius."""
    P = np.asarray(path, dtype=np.float64)
    m = len(P)
    R = np.asarray(radii, dtype=np.float64)
    if R.ndim == 1:
        R = np.stack([R, R * flat], axis=1)
    T = []
    for i in range(m):
        a = P[max(i - 1, 0)]
        b = P[min(i + 1, m - 1)]
        T.append(_norm(b - a))
    n1, n2 = _perp_frame(T[0], up)
    frames = [(n1, n2)]
    for i in range(1, m):
        # parallel transport: rotate previous n1 by the minimal rotation T[i-1] -> T[i]
        t0, t1 = T[i - 1], T[i]
        n1p = frames[-1][0]
        n1p = _norm(n1p - t1 * np.dot(n1p, t1))
        frames.append((n1p, _norm(np.cross(t1, n1p))))
    V, F = [], []
    rings = m - 1 if tip else m
    for i in range(rings):
        n1, n2 = frames[i]
        for k in range(sides):
            a = 2 * math.pi * k / sides + phase
            V.append(P[i] + R[i, 0] * math.cos(a) * n1 + R[i, 1] * math.sin(a) * n2)
    for i in range(rings - 1):
        for k in range(sides):
            a0 = i * sides + k
            a1 = i * sides + (k + 1) % sides
            b0 = a0 + sides
            b1 = a1 + sides
            F.append((a0, a1, b1, b0))
    if tip:
        V.append(P[-1])
        ap = len(V) - 1
        base = (rings - 1) * sides
        for k in range(sides):
            F.append((base + k, base + (k + 1) % sides, ap))
    elif cap1:
        base = (rings - 1) * sides
        F.append(tuple(base + k for k in range(sides)))
    if cap0:
        F.append(tuple(k for k in reversed(range(sides))))
    return np.array(V), F


def ellipsoid(c, r, nu=10, nv=6, rx=0.0, squash_bottom=1.0):
    """UV ellipsoid, nv latitude rings between the poles, nu segments. rx: rotation about X (radians)."""
    c = np.asarray(c, dtype=np.float64)
    V = [np.array([0, 0, 1.0])]
    for j in range(1, nv + 1):
        th = math.pi * j / (nv + 1)
        for k in range(nu):
            ph = 2 * math.pi * k / nu
            V.append(np.array([math.sin(th) * math.cos(ph), math.sin(th) * math.sin(ph), math.cos(th)]))
    V.append(np.array([0, 0, -1.0]))
    V = np.array(V) * np.asarray(r, dtype=np.float64)
    V[:, 2] = np.where(V[:, 2] < 0, V[:, 2] * squash_bottom, V[:, 2])
    if rx:
        cr, sr = math.cos(rx), math.sin(rx)
        y, z = V[:, 1].copy(), V[:, 2].copy()
        V[:, 1] = y * cr - z * sr
        V[:, 2] = y * sr + z * cr
    V = V + c
    F = []
    for k in range(nu):
        F.append((0, 1 + k, 1 + (k + 1) % nu))
    for j in range(nv - 1):
        for k in range(nu):
            a0 = 1 + j * nu + k
            a1 = 1 + j * nu + (k + 1) % nu
            F.append((a0, a0 + nu, a1 + nu, a1))
    last = len(V) - 1
    base = 1 + (nv - 1) * nu
    for k in range(nu):
        F.append((base + k, last, base + (k + 1) % nu))
    return V, F


def octa(c, r, sz=1.0):
    c = np.asarray(c, dtype=np.float64)
    V = np.array([[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]], dtype=np.float64) * r
    V[:, 2] *= sz
    F = [(0, 2, 4), (2, 1, 4), (1, 3, 4), (3, 0, 4), (2, 0, 5), (1, 2, 5), (3, 1, 5), (0, 3, 5)]
    return V + c, F


def tetra(c, r):
    c = np.asarray(c, dtype=np.float64)
    V = np.array([[1, 1, 1], [1, -1, -1], [-1, 1, -1], [-1, -1, 1]], dtype=np.float64) * (r / math.sqrt(3))
    F = [(0, 1, 2), (0, 3, 1), (0, 2, 3), (1, 3, 2)]
    return V + c, F


def shell_plate(y0, length, a, b, zc, theta_deg, nu, nv, thick, bulge=0.0, ridge=0.0, flare=0.0, lift=0.0, serr=0.0, skirt=0.0):
    """Arched carapace plate (tergite): a slice of an elliptic cylinder shell around the body axis (Y).
    a, b: (front, back) half-width / half-height of the outer surface. u across (theta), v along (front->back).
    Closed solid: outer + inner surface + rim. bulge: convexity along v; ridge: central keel height;
    flare: rear edge flips up/out (overlapping roof-tile look); lift: whole plate z offset at the rear."""
    th = math.radians(theta_deg)
    def surf(u, v, inner):
        t = u * th
        av = a[0] + (a[1] - a[0]) * v
        bv = b[0] + (b[1] - b[0]) * v
        bb = bulge * math.sin(math.pi * min(max(v, 0), 1))
        rr = 1.0 + bb + flare * max(0.0, v - 0.6) / 0.4 + skirt * max(0.0, abs(u) - 0.55) / 0.45
        x = (av * rr - (thick if inner else 0)) * math.sin(t)
        z = (bv * rr - (thick if inner else 0)) * math.cos(t)
        z += ridge * max(0.0, 1.0 - abs(u) * 3.0) * math.sin(math.pi * v) * (0.0 if inner else 1.0)
        z += lift * v
        y = y0 - v * length
        if serr and v >= 1.0:                      # serrated trailing edge: every other rim vertex is a point
            i = int(round((u + 1) / 2 * nu))
            y -= serr * (1.0 if i % 2 == 1 else 0.0) * (0.6 + 0.4 * (1 - abs(u)))
        return np.array([x, y, zc + z])
    V, F = [], []
    idx = {}
    for s, inner in ((0, False), (1, True)):
        for j in range(nv + 1):
            for i in range(nu + 1):
                idx[(s, i, j)] = len(V)
                V.append(surf(-1 + 2 * i / nu, j / nv, inner))
    for j in range(nv):
        for i in range(nu):
            o = [idx[(0, i, j)], idx[(0, i + 1, j)], idx[(0, i + 1, j + 1)], idx[(0, i, j + 1)]]
            F.append((o[0], o[3], o[2], o[1]))          # outer faces point away from the axis
            n = [idx[(1, i, j)], idx[(1, i + 1, j)], idx[(1, i + 1, j + 1)], idx[(1, i, j + 1)]]
            F.append((n[0], n[1], n[2], n[3]))
    # rim: walk the boundary of the (u,v) grid
    ring = [(i, 0) for i in range(nu)] + [(nu, j) for j in range(nv)] + [(i, nv) for i in range(nu, 0, -1)] + [(0, j) for j in range(nv, 0, -1)]
    for k in range(len(ring)):
        p, q = ring[k], ring[(k + 1) % len(ring)]
        F.append((idx[(0, p[0], p[1])], idx[(0, q[0], q[1])], idx[(1, q[0], q[1])], idx[(1, p[0], p[1])]))
    return np.array(V), F


def cone(base, apex, r, sides=4, up=(0, 0, 1)):
    base = np.asarray(base, dtype=np.float64)
    apex = np.asarray(apex, dtype=np.float64)
    return tube([base, apex], [r, 0.0], sides, up=up, tip=True, cap0=True)


def merge(parts):
    V, F, off = [], [], 0
    for v, f in parts:
        V.append(v)
        F.extend(tuple(i + off for i in face) for face in f)
        off += len(v)
    return np.concatenate(V), F


def smoothstep(e0, e1, x):
    t = min(max((x - e0) / (e1 - e0), 0.0), 1.0)
    return t * t * (3 - 2 * t)
