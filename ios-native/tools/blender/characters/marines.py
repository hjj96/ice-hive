"""The four marines (WP4 «Отряд»): a shared power-armour body + each class's silhouette kit and weapon, modelled as
sub-d cages (subd.py: Catmull–Clark with creased rims; LOW = level 1 ships, HIGH = level 3 + panel seams is the bake
source), curved sector shells on the limbs and plates / visors / strips conformed onto the finished surfaces, on the
shared skeleton's bind pose (skeleton.py). `build(cls, hi)` returns a Builder with the parts (model space, one bone
each, or a two-bone blend for hoses and the feed chute) and, when hi, the bake-only floaters (bolts, vents) and
paint decals.

Look (the user's blend: «Кристалл» readability on the plan's hard-surface marines — not faceted plastic toys):
smooth sculpted ceramic-grey plates with worn chamfers over a near-black flexible undersuit, gunmetal mechanics, ONE
saturated hue per class on the painted plates (pauldrons, helmet, knee / forearm plates), the visor and thin
emissive strips, so the class reads at 35–50 pt in the dark; and a silhouette per class, strongest from the game's
57° top-down camera (helmet, pauldrons, backpack, weapon):
  assault  angular helmet, T-visor, red crest; 3-lame shingled pauldrons; compact jump pack + antenna; pulse rifle
  pyro     round helmet, respirator snout + filters, round amber goggles; domed heat-shield pauldrons; TWIN fuel
           tanks with a hose to the flamer (finned flared nozzle, pilot light)
  cryo     glossy DOME visor with a glowing band; sleek pauldrons with glow lines; one big coolant tank with a glowing
           window; cryo projector with three glowing coils on weapon_aux (they spin)
  gunner   squared BUCKET helmet with a slit visor; huge 4-lame pauldrons; AMMO DRUM backpack, belt chute to the
           six-barrel rotary cannon (barrels on weapon_aux), top carry handle
Weapons are held on the marine's LEFT (+x), see skeleton.py.
"""
import math

import numpy as np

import motion
import skeleton as SK
from shapes import (ARMOUR, BRASS, DARK, GLASS, GLOW, HOT, LAMP, METAL, PAINT, SOLE, Part, R, S, T, bevel_mesh, bolt, cyl, frame,
                    lathe, merge, mirror_x, mm, prism, slots, xform)
from subd import (Surface, box_cage, conform, deform, frame_at, grid_cage, inset_seams, loft_cage, rect_outline, rimmed,
                  ring, sector_shell, subd, superellipse, thicken)


def wrap(r0, r1, a0, a1, length, depth, nu=4, nv=2, bulge=0.0, ridge=0.0, flare=0.0, y0=0.0):
    """A limb plate: a single-sided sector of a cone round local +y with an inward rim (see sector_shell)."""
    am = 0.5 * (a0 + a1)

    def fn(u, v):
        a = math.radians(a0 + (a1 - a0) * u)
        r = r0 + (r1 - r0) * v + bulge * math.sin(math.pi * v) + flare * max(0.0, 0.25 - v) * 4
        r += ridge * max(0.0, 1.0 - abs((a0 + (a1 - a0) * u) - am) / max(1e-6, 0.5 * (a1 - a0))) ** 2
        return (r * math.sin(a), y0 + length * v, r * math.cos(a))
    V, F = grid_cage(nu, nv, fn)
    return rimmed(V, F, depth, inner=(0.0, y0 + length * 0.5, 0.0))

def arc_profile(ctrl, r, keel=0.0, squash=1.0):
    """An armour cross-section: ctrl [(angle deg, radius multiplier)] — angle 0 = +z (front), 90 = +x — at base
    radius r; `keel` pushes the 0° point forward (a ridge down the front), `squash` scales z."""
    out = []
    for a, k in ctrl:
        rr = r * k + keel * max(0.0, 1.0 - abs(a) / 22.0)
        t = math.radians(a)
        out.append((rr * math.sin(t), rr * math.cos(t) * squash))
    return out


def densify(ctrl, k=2):
    """Insert k − 1 evenly spaced points between consecutive ctrl points (angle and multiplier interpolated): a cage
    dense enough to ship at sub-d level 0 (the HIGH bake source rounds it)."""
    out = []
    for i in range(len(ctrl) - 1):
        (a0, m0), (a1, m1) = ctrl[i], ctrl[i + 1]
        for j in range(k):
            t = j / k
            out.append((a0 + (a1 - a0) * t, m0 + (m1 - m0) * t))
    out.append(ctrl[-1])
    return out


def loft_shell(sections, depth, inner):
    """Open sections (lists of 3D points, same count, bottom → top) lofted into a quad patch, given an inward rim
    (rimmed): a hard-surface plate whose facets come from the sections' corners."""
    nu = len(sections[0]) - 1
    nv = len(sections) - 1
    V = np.array([p for sec in sections for p in sec], dtype=np.float64)
    F = []
    for j in range(nv):
        for i in range(nu):
            a = j * (nu + 1) + i
            F.append([a, a + 1, a + nu + 2, a + nu + 1])
    return rimmed(V, F, depth, inner=inner)


def limb_sections(spec, mirror=False):
    """spec: [(y, ctrl, r, keel, dx, dz)] in a limb frame (y along the limb) → 3D sections; mirror flips x (the right
    side)."""
    out = []
    for y, ctrl, r, keel, dx, dz in spec:
        pts = arc_profile(ctrl, r, keel)
        sec = [((-x if mirror else x) + (-dx if mirror else dx), y, z + dz) for x, z in pts]
        out.append(sec[::-1] if mirror else sec)
    return out


CLASSES = ['assault', 'pyro', 'cryo', 'gunner']
MR_INDEX = {c: k for k, c in enumerate(CLASSES)}
# the paint mask (ORM alpha): 0 the material's own colour, MARK_DARK a dark stencil / hazard stripe, MARK_CLASS the
# class hue (a blurred edge between the class hue and nothing passes through the dark band: a thin pinline)
MARK_DARK, MARK_CLASS = 0.5, 1.0

# sRGB colours; paint = class trim, glow = class laser (IceHiveCore Tuning CLASS_SPECS)
HUE = {'assault': 0xff2a22, 'pyro': 0xffa214, 'cryo': 0x30b4ff, 'gunner': 0x3cff58}
TRIM = {'assault': 0xb8322a, 'pyro': 0xd8901c, 'cryo': 0x3592c8, 'gunner': 0x47a538}


def rgb(h):
    return ((h >> 16) & 255, (h >> 8) & 255, h & 255)


def materials(cls):
    """slot → (sRGB albedo, roughness, metal, glow 0..1, flags). flags: bit0 class-hue strip / visor, bit1 emissive,
    bit2 painted armour (worn chamfers show steel), bit3 heats up under sustained fire."""
    return {
        ARMOUR: ((138, 142, 147), 0.42, 0.06, 0.0, 4),
        PAINT: (rgb(TRIM[cls]), 0.4, 0.05, 0.0, 4),
        DARK: ((42, 45, 50), 0.62, 0.0, 0.0, 0),
        METAL: ((70, 74, 80), 0.34, 0.85, 0.0, 0),
        GLOW: (rgb(HUE[cls]), 0.2, 0.0, 1.0, 3),
        GLASS: ((12, 34, 52), 0.05, 0.0, 0.14, 3),    # the cryo's dome / canister: dark glass with a faint inner glow
        SOLE: ((22, 22, 24), 0.85, 0.0, 0.0, 0),
        LAMP: ((255, 244, 222), 0.2, 0.0, 1.0, 2),
        BRASS: ((150, 112, 60), 0.34, 0.9, 0.0, 0),
        HOT: ((64, 67, 72), 0.32, 0.88, 0.0, 8),
    }


class Builder:
    def __init__(self, cls, hi):
        self.cls, self.hi = cls, hi
        self.P = SK.bind_positions(cls)
        self.parts = []
        self.floaters = []          # (mesh, bone, mat) — HIGH only, baked into the maps
        self.decals = []            # (mesh, bone, value) — HIGH only, paint mask (1 class hue, 0.5 light marking)
        self.done = {}              # finished surfaces by name (conform targets)
        self.done_idx = {}          # … and the index of their part
        self._surfs = {}
        self.floater_target = []    # per floater / decal: the part it was laid on (None: the bake picks the nearest)
        self.decal_target = []
        self._last_names = None

    def J(self, name):
        return self.P[SK.IDX[name]]

    @property
    def lv(self):
        return 3 if self.hi else 1

    def sd(self, VF, lo=1, hi=3, crease_deg=50.0, crease=0.85, seams=None, boundary=0.0):
        V, F = VF
        if self.hi and seams is not None:
            V, F = inset_seams(V, F, *seams)
        return subd(V, F, hi if self.hi else lo, crease_deg, crease, boundary)

    def add(self, name, bone, mat, VF, sharp=40.0, blend=None, keep=False):
        V, F = VF
        self._last_names = None
        self.parts.append(Part(name, bone, mat, V, F, sharp_deg=sharp, blend=blend))
        if keep:
            self.done[name] = (np.asarray(V), F)
            self.done_idx[name] = len(self.parts) - 1
        return V, F

    def _target(self, names):
        return self.done_idx.get(names[0]) if names else None

    def _float(self, VF, bone, mat, names=None):
        self.floaters.append((VF, bone, mat))
        self.floater_target.append(self._target(names))

    def _mark(self, VF, bone, value, names=None):
        self.decals.append((VF, bone, value))
        self.decal_target.append(self._target(names))

    def detail(self, VF, bone, mat=METAL):
        if self.hi and VF is not None:
            self._float(VF, bone, mat)

    def decal(self, VF, bone, value=1.0):
        if self.hi and VF is not None:
            self._mark(VF, bone, value, self._last_names)
        self._last_names = None

    def surface(self, *names):
        key = tuple(id(self.done[n][0]) for n in names)
        if key not in self._surfs:
            self._surfs[key] = Surface(*[self.done[n] for n in names])
        return self._surfs[key]

    def plate(self, names, origin, a_axis, b_axis, into, w, h, t, nu=4, nv=3, r=0.3, taper=0.0, gap=0.003,
              level=1, crease=0.75):
        """A plate conformed onto the named surfaces, its rim rounded by sub-d."""
        surf = self.surface(*names)
        VF = conform(surf, frame_at(np.asarray(origin, dtype=np.float64), a_axis, b_axis, into), rect_outline(w, h, r, taper),
                     nu, nv, gap, t)
        if VF is None:
            raise RuntimeError(f'{self.cls}: a plate missed {names} at {origin}')
        if level > 0:
            VF = subd(VF[0], VF[1], level + (1 if self.hi else 0), 50.0, crease)
        return surf.lift(VF[0], max(gap, 0.002), -np.asarray(into, dtype=np.float64)), VF[1]

    def sticker(self, names, origin, a_axis, b_axis, into, w, h, r=0.2, taper=0.0, nu=3, nv=2, t=0.0012):
        """A thin conformed shape (decal / glow strip / visor) — no sub-d."""
        self._last_names = names
        surf = self.surface(*names)
        return conform(surf, frame_at(np.asarray(origin, dtype=np.float64), a_axis, b_axis, into), rect_outline(w, h, r, taper),
                       nu, nv, 0.0008, t)

    # ------------------------------------------------------------ HIGH-only detail (baked into the maps)
    def panel(self, names, origin, a_axis, b_axis, into, w, h, bone, t=0.0035, r=0.22, taper=0.0, mat=ARMOUR, nu=3, nv=3):
        """A raised sub-panel (≈ 3.5 mm, chamfered) laid on a finished surface: the layered hard-surface look of the
        normal map. HIGH only."""
        if not self.hi:
            return
        surf = self.surface(*names)
        VF = conform(surf, frame_at(np.asarray(origin, dtype=np.float64), a_axis, b_axis, into), rect_outline(w, h, r, taper),
                     nu, nv, 0.0006, t)
        if VF is None:
            return
        VF = subd(VF[0], VF[1], 1, 50.0, 1.0)
        self._float(VF, bone, mat, names)

    def vents(self, names, origin, along, into, bone, count, length, width, gap, depth=0.004):
        """A row of vent slats on a finished surface (the surface point and normal under `origin`). HIGH only."""
        if not self.hi:
            return
        surf = self.surface(*names)
        into = np.asarray(into, dtype=np.float64)
        h, n = surf.hit(np.asarray(origin, dtype=np.float64) - into * 0.2, into, 0.6)
        if h is None:
            return
        if np.dot(n, into) > 0:
            n = -n
        self._float(slots(h, n, along, count, length, width, gap, depth), bone, METAL, names)

    def _rect(self, surf, origin, a, b, into, w, h, ang=0.0, skew=0.0, t=0.0012):
        a, b = np.asarray(a, dtype=np.float64), np.asarray(b, dtype=np.float64)
        ca, sa = math.cos(math.radians(ang)), math.sin(math.radians(ang))
        a2, b2 = a * ca + b * sa, -a * sa + b * ca
        return conform(surf, frame_at(np.asarray(origin, dtype=np.float64), a2, b2, into), rect_outline(w, h, 0.0, 0.0, skew),
                       2, 1, 0.0008, t)

    def stencil(self, names, origin, a_axis, b_axis, into, bone, text, size, value=0.5):
        """Stencil markings in the paint mask (MARK_DARK, MARK_CLASS): digits as seven bars, '^' a
        chevron, '-' a bar, '/' a hazard stripe; `size` = glyph height. HIGH only."""
        if not self.hi:
            return
        surf = self.surface(*names)
        a = np.asarray(a_axis, dtype=np.float64)
        a = a / np.linalg.norm(a)
        d = np.asarray(into, dtype=np.float64)
        d = d / np.linalg.norm(d)
        b = np.asarray(b_axis, dtype=np.float64)
        b = b - d * np.dot(b, d) - a * np.dot(b, a)
        b /= np.linalg.norm(b)
        o = np.asarray(origin, dtype=np.float64)
        H, W, th = size, size * 0.56, size * 0.19
        SEG = {'a': (0.0, 0.5, 1, 0), 'b': (0.5, 0.25, 0, 1), 'c': (0.5, -0.25, 0, 1), 'd': (0.0, -0.5, 1, 0),
               'e': (-0.5, -0.25, 0, 1), 'f': (-0.5, 0.25, 0, 1), 'g': (0.0, 0.0, 1, 0)}
        DIG = {'0': 'abcdef', '1': 'bc', '2': 'abged', '3': 'abgcd', '4': 'fgbc', '5': 'afgcd', '6': 'afgedc', '7': 'abc',
               '8': 'abcdefg', '9': 'abcdfg'}
        n = len(text)
        adv = W * 1.45
        x0 = -0.5 * adv * (n - 1)
        for k, ch in enumerate(text):
            cx = x0 + k * adv
            rects = []
            if ch in DIG:
                for sg in DIG[ch]:
                    sx, sy, horiz, vert = SEG[sg]
                    if horiz:
                        rects.append((cx + sx * W, sy * H, W, th, 0.0, 0.0))
                    else:
                        rects.append((cx + sx * W, sy * H, th, H * 0.5, 0.0, 0.0))
            elif ch == '^':
                rects.append((cx - W * 0.26, 0.0, W * 0.62, th * 1.3, 38.0, 0.0))
                rects.append((cx + W * 0.26, 0.0, W * 0.62, th * 1.3, -38.0, 0.0))
            elif ch == '-':
                rects.append((cx, 0.0, W, th * 1.2, 0.0, 0.0))
            elif ch == '/':
                rects.append((cx, 0.0, W * 0.45, H, 0.0, 0.6))
            elif ch == '|':
                rects.append((cx, 0.0, th * 1.4, H, 0.0, 0.0))
            for rx, ry, rw, rh, ang, sk in rects:
                VF = self._rect(surf, o + a * rx + b * ry, a, b, d, rw, rh, ang, sk)
                if VF is not None:
                    self._mark(VF, bone, value, names)

    def hazard(self, names, origin, a_axis, b_axis, into, bone, w, h, n=4, value=0.5):
        """Diagonal hazard stripes over a w × h band (every other stripe painted). HIGH only."""
        if not self.hi:
            return
        surf = self.surface(*names)
        a = np.asarray(a_axis, dtype=np.float64)
        a = a / np.linalg.norm(a)
        o = np.asarray(origin, dtype=np.float64)
        step = w / n
        for k in range(n):
            VF = self._rect(surf, o + a * ((k + 0.25 - 0.5 * n) * step), a, b_axis, into, step * 0.5, h, 0.0, 0.8)
            if VF is not None:
                self._mark(VF, bone, value, names)

    def ribs(self, M, profile, ys, bone, segs=12, a0=0.0, a1=360.0):
        """Ribbed undersuit: raised rings (r(y) from `profile`, a lathe in the limb frame M) at heights ys. HIGH only."""
        if not self.hi:
            return
        for y in ys:
            r = float(np.interp(y, [p[1] for p in profile], [p[0] for p in profile])) + 0.002
            ring_ = lathe([(r - 0.002, y - 0.005), (r + 0.003, y - 0.002), (r + 0.003, y + 0.002), (r - 0.002, y + 0.005)], segs,
                          a0, a1, cap0=False, cap1=False)
            self._float(xform(ring_, M), bone, DARK)

    def bolts_on(self, names, pts, into, bone, r=0.007):
        if not self.hi:
            return
        surf = self.surface(*names)
        for p in pts:
            h, n = surf.hit(np.asarray(p, dtype=np.float64) - np.asarray(into) * 0.2, np.asarray(into, dtype=np.float64), 0.5)
            if h is not None:
                if np.dot(n, into) > 0:
                    n = -n
                self._float(bolt(h, n, r=r), bone, METAL, names)


def se_ring(a, b, y, n=12, e=3.6, cz=0.0, front=0.0, back=0.0):
    return ring(superellipse(a, b, n, e, 0.0, cz, front, back), y)


# ================================================================ shared body
def ring_sections(spec, cx=0.0, cz=0.0, mirror=False):
    """Horizontal armour bands round the body: spec [(y, ctrl, r, keel, squash)] → sections about the vertical axis at
    (cx, cz) (angle 0 = front, 90 = +x)."""
    out = []
    for y, ctrl, r, keel, squash in spec:
        sec = [((-x if mirror else x) + cx, y, z + cz) for x, z in arc_profile(ctrl, r, keel, squash)]
        out.append(sec[::-1] if mirror else sec)
    return out


AB_CTRL = densify([(-104, 0.96), (-70, 1.0), (-34, 1.0), (0, 1.02), (34, 1.0), (70, 1.0), (104, 0.96)])
HIP_CTRL = densify([(46, 0.98), (70, 1.0), (96, 1.0), (122, 0.98), (146, 0.95)])
TASSET_CTRL = densify([(-50, 0.95), (-24, 1.0), (0, 1.03), (24, 1.0), (50, 0.95)])


def torso(b):
    c = b.cls
    # a power-armour cuirass: broad lats, a deep keeled chest, the upper back built up under the cowl
    rings = [se_ring(0.185, 0.13, 1.28, cz=0.015),
             se_ring(0.222, 0.158, 1.36, cz=0.025, front=0.03),
             se_ring(0.266, 0.165, 1.45, cz=0.025, front=0.05, back=0.012),
             se_ring(0.278, 0.162, 1.53, cz=0.012, front=0.04, back=0.026),
             se_ring(0.245, 0.148, 1.592, cz=0.0, front=0.016, back=0.024),
             se_ring(0.16, 0.115, 1.635, cz=-0.005)]
    cu = loft_cage(rings, cap0=False, cap1=False)
    seams = (lambda p, n, a: n[2] > 0.55 and 1.33 < p[1] < 1.58, 0.012, 0.005)
    cu = b.sd(cu, 1, 3, 28.0, 0.55, seams=seams, boundary=0.6)
    b.add('cuirass', 'chest', ARMOUR, cu, sharp=60.0, keep=True)
    for s in (1.0, -1.0):
        b.panel(['cuirass'], (s * 0.5, 1.42, 0.0), (0, 1, 0), (0, 0, 1), (-s, 0, 0), 0.16, 0.13, 'chest')
        b.panel(['cuirass'], (s * 0.5, 1.33, 0.02), (0, 1, 0), (0, 0, 1), (-s, 0, 0), 0.05, 0.1, 'chest', mat=METAL)
        b.vents(['cuirass'], (s * 0.19, 1.6, 0.5), (1, 0, 0), (0, -0.3, -1), 'chest', 3, 0.03, 0.008, 0.007)
    # pectoral plates, conformed to the cuirass: crisp-edged slabs that give the chest its mass, a gunmetal sternum
    # plate between them
    for s in (1.0, -1.0):
        pl = b.plate(['cuirass'], (s * 0.128, 1.47, 0.5), (1, 0, 0), (-s * 0.25, 1, 0.25), (0, 0, -1), 0.195, 0.165, 0.018, nu=2,
                     nv=2, r=0.16, taper=-0.2, gap=0.0055, crease=0.95)
        b.add('pec', 'chest', ARMOUR, pl, sharp=45.0, keep=True)
        b.panel(['pec'], (s * 0.13, 1.46, 0.5), (1, 0, 0), (-s * 0.25, 1, 0.25), (0, 0, -1), 0.13, 0.1, 'chest', taper=-0.2)
        if s < 0:
            b.stencil(['pec'], (-0.13, 1.52, 0.5), (1, 0, 0), (0, 1, 0.3), (0, 0, -1), 'chest', '0' + str(1 + MR_INDEX.get(c, 0)), 0.05, MARK_DARK)
        else:
            b.stencil(['pec'], (0.13, 1.41, 0.5), (1, 0, 0), (0, 1, 0.3), (0, 0, -1), 'chest', '^', 0.055, MARK_CLASS)
    st = b.plate(['cuirass'], (0.0, 1.45, 0.5), (1, 0, 0), (0, 1, 0), (0, 0, -1), 0.06, 0.2, 0.014, nu=1, nv=2, r=0.3,
                 taper=0.35, gap=0.004, crease=0.95)
    b.add('sternum', 'chest', METAL, st, sharp=45.0)
    b.decal(b.sticker(['cuirass'], (0.15, 1.575, 0.5), (1, 0, 0), (0, 1, 0.2), (0, 0, -1), 0.06, 0.016), 'chest', MARK_CLASS)
    b.decal(b.sticker(['cuirass'], (-0.15, 1.575, 0.5), (1, 0, 0), (0, 1, 0.2), (0, 0, -1), 0.06, 0.016), 'chest', MARK_DARK)
    b.bolts_on(['cuirass'], [(s * x, y, 0.4) for s in (1, -1) for x, y in ((0.045, 1.37), (0.21, 1.43), (0.2, 1.56))], (0, 0, -1), 'chest')
    # status lights on the left pec (the class hue): two short bars
    for k in range(2):
        led = b.sticker(['pec'], (0.075 + 0.045 * k, 1.53 - 0.004 * k, 0.5), (1, -0.2, 0), (0, 1, 0.3), (0, 0, -1), 0.032, 0.011, t=0.004)
        if led is not None:
            b.add('chest_glow', 'chest', GLOW, led)
    # back plate (the backpack mounts on it)
    bp = b.plate(['cuirass'], (0, 1.45, -0.5), (1, 0, 0), (0, 1, 0), (0, 0, 1), 0.4, 0.27, 0.024, nu=3, nv=2, r=0.3)
    b.add('backplate', 'chest', METAL, bp, sharp=55.0, keep=True)
    b.bolts_on(['backplate'], [(x, y, -0.4) for x in (-0.17, 0.17) for y in (1.34, 1.56)], (0, 0, 1), 'chest', r=0.008)
    # collar / gorget, and a cowl rising behind the neck (frames the helmet from the game camera)
    col = lathe([(0.11, 1.598), (0.165, 1.606), (0.178, 1.632), (0.168, 1.662), (0.13, 1.678), (0.104, 1.672)], 12)
    b.add('collar', 'chest', METAL, col, sharp=60.0)
    cw = wrap(0.178, 0.158, 112.0, 248.0, 0.105, 0.022, nu=8, nv=2, bulge=0.006, y0=1.6)
    b.add('cowl', 'chest', ARMOUR, b.sd(cw, 0, 3, 50.0, 0.8), sharp=55.0)
    # abdomen: a ribbed undersuit core with two overlapping faceted armour bands round the front and sides
    core = lathe([(0.15, 1.16), (0.168, 1.18), (0.16, 1.205), (0.172, 1.23), (0.163, 1.255), (0.174, 1.28), (0.16, 1.305)], 12)
    b.add('abdomen', 'spine2', DARK, xform(core, S(1.0, 1.0, 0.82)), sharp=70.0, keep=True)
    up = loft_shell(ring_sections([(1.205, AB_CTRL, 0.188, 0.006, 0.76), (1.25, AB_CTRL, 0.196, 0.012, 0.77),
                                   (1.3, AB_CTRL, 0.196, 0.01, 0.78)], cz=0.008), 0.022, (0.0, 1.25, 0.0))
    b.add('abband', 'spine2', ARMOUR, b.sd(up, 0, 3, 24.0, 0.8, seams=(lambda p, n, a: a > 0.0015, 0.006, 0.003)), sharp=40.0)
    rib = lathe([(0.142, 1.03), (0.166, 1.045), (0.156, 1.072), (0.17, 1.1), (0.158, 1.128), (0.166, 1.156), (0.144, 1.19)], 12)
    b.add('waist', 'spine1', DARK, xform(rib, S(1.0, 1.0, 0.84)), sharp=70.0, keep=True)
    lo = loft_shell(ring_sections([(1.12, AB_CTRL, 0.178, 0.006, 0.78), (1.165, AB_CTRL, 0.186, 0.012, 0.79),
                                   (1.215, AB_CTRL, 0.186, 0.01, 0.8)], cz=0.01), 0.022, (0.0, 1.17, 0.0))
    b.add('abplate', 'spine1', ARMOUR, b.sd(lo, 0, 3, 24.0, 0.8), sharp=40.0)
    sp = wrap(0.17, 0.168, 150.0, 210.0, 0.16, 0.02, nu=2, nv=2, y0=1.12)
    b.add('spineplate', 'spine2', METAL, b.sd(xform(sp, S(1.0, 1.0, 0.82)), 0, 2, 50.0, 0.85), sharp=55.0)
    neck = lathe([(0.088, 1.6), (0.08, 1.64), (0.086, 1.67), (0.078, 1.7), (0.07, 1.735)], 10)
    b.add('neck', 'neck', DARK, neck, sharp=70.0)


def pelvis(b):
    belt = loft_cage([se_ring(0.214, 0.15, 0.935, n=16, cz=0.0), se_ring(0.232, 0.163, 0.995, n=16, cz=0.005, front=0.012),
                      se_ring(0.222, 0.156, 1.055, n=16, cz=0.0)], cap0=True, cap1=True)
    belt = b.sd(belt, 0, 3, 50.0, 0.9)
    b.add('belt', 'pelvis', DARK, belt, sharp=60.0, keep=True)
    bk = box_cage(0.11, 0.07, 0.035)
    b.add('buckle', 'pelvis', METAL, xform(b.sd(bk, 1, 2, 40.0, 0.95), T(0, 0.995, 0.18)), sharp=45.0)
    # codpiece: a faceted shield with a keel, pointed at the bottom
    cp = grid_cage(4, 2, lambda u, v: ((u - 0.5) * 0.15 * (1 - 0.45 * (1 - v)), 0.82 + 0.15 * v,
                                       0.18 + 0.024 * (1 - abs(2 * u - 1)) - 0.028 * (1 - v)))
    cp = b.sd(rimmed(*cp, 0.026, inner=(0, 0.9, 0)), 0, 3, 30.0, 0.9)
    b.add('codpiece', 'pelvis', ARMOUR, cp, sharp=45.0)
    # hip plates (outer) and the rear plate: faceted, flared at the bottom
    for s in (1.0, -1.0):
        hp = loft_shell(ring_sections([(0.83, HIP_CTRL, 0.262, 0.0, 0.8), (0.93, HIP_CTRL, 0.252, 0.0, 0.8),
                                       (1.02, HIP_CTRL, 0.238, 0.0, 0.78)], mirror=(s < 0)), 0.024, (0.0, 0.93, 0.0))
        b.add('hip', 'pelvis', ARMOUR, b.sd(hp, 0, 3, 24.0, 0.85, seams=(lambda p, n, a: a > 0.002, 0.006, 0.003)), sharp=40.0, keep=True)
        b.panel(['hip'], (s * 0.5, 0.93, 0.0), (0, 1, 0), (0, 0, 1), (-s, 0, 0), 0.1, 0.11, 'pelvis')
        b.bolts_on(['hip'], [(s * 0.4, 1.0, z) for z in (-0.06, 0.06)], (-s, 0, 0), 'pelvis', r=0.006)
    rp = wrap(0.226, 0.212, 150.0, 210.0, 0.17, 0.024, nu=4, nv=2, y0=0.85)
    b.add('rearplate', 'pelvis', ARMOUR, b.sd(xform(rp, S(1.0, 1.0, 0.85)), 0, 3, 40.0, 0.9), sharp=45.0)
    # belt pouches: two at the back hips, a pair of magazine pouches on the gun side
    for s in (1.0, -1.0):
        po = box_cage(0.075, 0.085, 0.055)
        po = deform(po, lambda p: np.array([p[0], p[1], p[2] + 0.012 * (1 - (2 * p[0] / 0.075) ** 2)]))
        M = mm(T(s * 0.165, 0.985, -0.128), R('Y', s * 142.0))
        b.add('pouch', 'pelvis', DARK, xform(b.sd(po, 1, 2, 50.0, 0.8), M), sharp=55.0)
    for k in range(2):
        po = box_cage(0.05, 0.09, 0.045)
        po = deform(po, lambda p: np.array([p[0], p[1], p[2] + 0.008 * (1 - (2 * p[0] / 0.05) ** 2)]))
        M = mm(T(0.214 - 0.004 * k, 0.99, 0.085 - 0.058 * k), R('Y', 72.0 + 14.0 * k))
        b.add('magpouch', 'pelvis', DARK, xform(b.sd(po, 1, 2, 50.0, 0.8), M), sharp=55.0)
    # tassets: faceted front thigh plates hanging from the belt (they swing up with the thigh)
    for s, bone in ((1.0, 'tasset_L'), (-1.0, 'tasset_R')):
        j = b.J(bone)
        ts = loft_shell(ring_sections([(j[1] - 0.205, TASSET_CTRL, 0.112, 0.008, 1.0), (j[1] - 0.1, TASSET_CTRL, 0.117, 0.012, 1.0),
                                       (j[1] + 0.005, TASSET_CTRL, 0.112, 0.008, 1.0)], cx=j[0], cz=j[2] - 0.045), 0.024,
                        (j[0], j[1] - 0.1, j[2] - 0.1))
        ts = b.sd(ts, 0, 3, 24.0, 0.85, seams=(lambda p, n, a: a > 0.002, 0.006, 0.003))
        b.add('tasset', bone, PAINT if b.cls == 'gunner' else ARMOUR, ts, sharp=40.0, keep=True)
        b.panel(['tasset'], (j[0], j[1] - 0.1, 0.5), (1, 0, 0), (0, 1, 0), (0, 0, -1), 0.11, 0.13, bone, taper=0.2,
                mat=PAINT if b.cls == 'gunner' else ARMOUR)
        b.bolts_on(['tasset'], [(j[0] + xx, j[1] - 0.02, 0.4) for xx in (-0.05, 0.05)], (0, 0, -1), bone, r=0.006)


THIGH_CTRL = densify([(-64, 0.9), (-32, 1.0), (0, 1.03), (32, 1.0), (70, 1.0), (106, 0.97), (140, 0.9)])
GREAVE_CTRL = densify([(-122, 0.9), (-80, 1.0), (-36, 1.0), (0, 1.03), (36, 1.0), (80, 1.0), (122, 0.9)])


def shield_patch(w, h, d, ridge=0.0, nu=4, nv=4, point=0.35):
    """A domed shield (knee / elbow cop) facing +z: width w, height h, dome depth d, pointed top and bottom (`point`
    narrows them), a vertical ridge."""
    def fn(u, v):
        x = (u - 0.5) * w * (1.0 - point * abs(2 * v - 1) ** 1.5)
        y = (v - 0.5) * h
        ex, ey = 2 * x / w, 2 * y / h
        z = d * max(0.0, 1.0 - 0.55 * ex * ex - 0.45 * ey * ey) + ridge * max(0.0, 1.0 - abs(ex) * 2.2) * (1.0 - ey * ey)
        return (x, y, z)
    return grid_cage(nu, nv, fn)


def legs(b):
    for side, s in (('L', 1.0), ('R', -1.0)):
        hip, knee, ank, toe = b.J('thigh_' + side), b.J('shin_' + side), b.J('foot_' + side), b.J('toe_' + side)
        mir = s < 0
        F = frame(knee, hip - knee, (0, 0, 1))
        und = lathe([(0.086, 0.0), (0.099, 0.16), (0.106, 0.33), (0.096, 0.43)], 8)
        b.add('thigh_suit', 'thigh_' + side, DARK, xform(und, F), sharp=70.0)
        # cuisse: a faceted shell over the front and the outside (a keel down the front panel), flaring at the hip
        secs = limb_sections([(0.075, THIGH_CTRL, 0.106, 0.008, 0.0, 0.014),
                              (0.17, THIGH_CTRL, 0.123, 0.014, 0.004, 0.014),
                              (0.29, THIGH_CTRL, 0.131, 0.016, 0.008, 0.01),
                              (0.395, THIGH_CTRL, 0.136, 0.01, 0.012, 0.002)], mirror=mir)
        tp = loft_shell(secs, 0.026, (0.0, 0.2, 0.0))
        tp = b.sd(tp, 0, 3, 24.0, 0.8, seams=(lambda p, n, a: a > 0.0012, 0.007, 0.003))
        b.add('thigh_plate', 'thigh_' + side, ARMOUR, xform(tp, F), sharp=40.0, keep=True)
        fy, fx, fz = F[:3, 1], F[:3, 0], F[:3, 2]
        b.panel(['thigh_plate'], knee + fy * 0.24 + fz * 0.5, fy, fx, -fz, 0.17, 0.085, 'thigh_' + side, taper=0.15)
        b.panel(['thigh_plate'], knee + fy * 0.22 + (fx * s) * 0.5, fy, fz, -fx * s, 0.15, 0.07, 'thigh_' + side)
        b.bolts_on(['thigh_plate'], [knee + fy * yy + fx * xx + fz * 0.4 for yy in (0.12, 0.36) for xx in (-0.05, 0.05)], -fz, 'thigh_' + side, r=0.006)
        b.ribs(F, [(0.086, 0.0), (0.099, 0.16), (0.106, 0.33), (0.096, 0.43)], [0.1, 0.135, 0.17, 0.205, 0.24, 0.275, 0.31, 0.345], 'thigh_' + side, segs=8)
        # a strapped pouch on the outer thigh (gun side) / a knife sheath (the other side)
        if s > 0:
            po = box_cage(0.05, 0.12, 0.085)
            po = deform(po, lambda p: np.array([p[0] + 0.006 * (1 - (2 * p[2] / 0.085) ** 2), p[1], p[2]]))
            b.add('thigh_pouch', 'thigh_' + side, DARK, xform(b.sd(po, 1, 2, 50.0, 0.8), mm(F, T(0.152, 0.25, -0.012))), sharp=55.0)
            for yy in (0.215, 0.285):
                band = lathe([(0.134, yy - 0.008), (0.14, yy - 0.004), (0.14, yy + 0.004), (0.134, yy + 0.008)], 10, 40.0, 150.0, cap0=False, cap1=False)
                b.detail(xform(band, F), 'thigh_' + side, DARK)
        # knee cop (class paint): a domed shield with a ridge, pointed top and bottom
        kp = shield_patch(0.15, 0.175, 0.045, ridge=0.012, nu=6, nv=6)
        kp = b.sd(rimmed(*kp, 0.024, inner=(0.0, 0.0, -0.1)), 0, 3, 50.0, 0.85)
        b.add('knee', 'shin_' + side, PAINT, xform(kp, mm(T(knee[0], knee[1] - 0.012, knee[2] + 0.07), R('X', -8))), sharp=55.0)
        # greave: a faceted shell round the front and the sides, a keel down the shin, flared over the boot
        F2 = frame(ank, knee - ank, (0, 0, 1))
        secs = limb_sections([(0.062, GREAVE_CTRL, 0.106, 0.006, 0.0, 0.008),
                              (0.12, GREAVE_CTRL, 0.097, 0.012, 0.0, 0.008),
                              (0.245, GREAVE_CTRL, 0.109, 0.02, 0.0, 0.01),
                              (0.352, GREAVE_CTRL, 0.112, 0.016, 0.0, 0.006)], mirror=mir)
        sg = loft_shell(secs, 0.026, (0.0, 0.2, 0.0))
        sg = b.sd(sg, 0, 3, 24.0, 0.8, seams=(lambda p, n, a: a > 0.0012, 0.007, 0.003))
        b.add('shin', 'shin_' + side, ARMOUR, xform(sg, F2), sharp=40.0, keep=True)
        gy, gx, gz = F2[:3, 1], F2[:3, 0], F2[:3, 2]
        for xx in (-0.032, 0.032):
            b.panel(['shin'], ank + gy * 0.2 + gx * xx + gz * 0.5, gy, gx, -gz, 0.2, 0.034, 'shin_' + side, t=0.003)
        b.bolts_on(['shin'], [ank + gy * yy + gx * (s * 0.075) + gz * 0.3 for yy in (0.12, 0.3)], -gz - gx * s * 0.6, 'shin_' + side, r=0.006)
        b.stencil(['shin'], ank + gy * 0.27 + gx * (s * 0.5), gz, gy, -gx * s, 'shin_' + side,
                  '|' + str(1 + MR_INDEX.get(b.cls, 0)), 0.03, MARK_DARK)
        cf = wrap(0.094, 0.1, 124.0, 236.0, 0.27, 0.022, nu=5, nv=2, bulge=0.008, y0=0.075)
        b.add('calf', 'shin_' + side, METAL, xform(b.sd(cf, 0, 2, 50.0, 0.8), F2), sharp=55.0)
        b.decal(b.sticker(['shin'], ank + np.array([s * 0.0, 0.33, 0.3]), (1, 0, 0), (0, 1, 0), (0, 0, -1), 0.1, 0.026), 'shin_' + side, MARK_CLASS)
        # boot (foot bone): a sculpted shell with a raised heel counter, ankle guards, an armoured instep plate and a
        # heavy two-block sole; the toe cap and the forefoot sole ride the toe bone
        secs = []
        for zz, w, top, bot in ((-0.148, 0.062, 0.06, 0.035), (-0.09, 0.078, 0.07, 0.03), (-0.01, 0.083, 0.05, 0.03),
                                (0.07, 0.083, 0.0, 0.03), (0.14, 0.078, -0.044, 0.03)):
            yb, yt = bot - ank[1], top
            pts = superellipse(w, 0.5 * (yt - yb), 10, 3.2)
            secs.append(np.array([(px, 0.5 * (yb + yt) + pz, zz) for px, pz in pts]))
        bt = b.sd(loft_cage(secs), 0, 3, 40.0, 0.8)
        b.add('boot', 'foot_' + side, DARK, xform(bt, T(ank[0], ank[1], ank[2])), sharp=55.0, keep=True)
        for zz in (-0.02, 0.05):
            b.panel(['boot'], (ank[0], ank[1] + 0.3, ank[2] + zz), (1, 0, 0), (0, 0, 1), (0, -1, 0.3), 0.19, 0.026, 'foot_' + side, t=0.004, mat=DARK)
        ip = grid_cage(3, 3, lambda u, v: ((u - 0.5) * 0.15 * (1.0 - 0.25 * v), 0.065 - 0.115 * v + 0.02 * (1 - (2 * u - 1) ** 2),
                                            0.035 + 0.12 * v + 0.012 * (1 - (2 * u - 1) ** 2)))
        ip = b.sd(rimmed(*ip, 0.02, inner=(0.0, -0.06, 0.06)), 0, 3, 40.0, 0.85)
        b.add('instep', 'foot_' + side, ARMOUR, xform(ip, T(ank[0], ank[1], ank[2])), sharp=50.0)
        hc = wrap(0.074, 0.07, 125.0, 235.0, 0.11, 0.02, nu=4, nv=1, y0=-0.07)
        b.add('heel_guard', 'foot_' + side, ARMOUR, xform(b.sd(hc, 0, 2, 50.0, 0.8), T(ank[0], ank[1], ank[2] - 0.035)), sharp=55.0)
        disc = lathe([(0.0, 0.0), (0.04, 0.0), (0.042, 0.012), (0.0, 0.02)], 8)
        b.add('ankle_guard', 'foot_' + side, METAL, xform(disc, mm(T(ank[0] + s * 0.08, ank[1] + 0.004, ank[2] - 0.01), R('Z', -s * 90))), sharp=60.0)
        cuff = lathe([(0.088, 0.065), (0.097, 0.09), (0.095, 0.125), (0.086, 0.14)], 10)
        b.add('cuff', 'foot_' + side, METAL, xform(cuff, T(ank[0], ank[1], ank[2] - 0.012)), sharp=70.0)
        so = box_cage(0.168, 0.032, 0.15, 1, 1, 2)
        so = deform(so, lambda p: np.array([p[0] * (1.0 - 0.08 * max(0.0, -p[2]) / 0.075), p[1], p[2]]))
        b.add('sole', 'foot_' + side, SOLE, xform(b.sd(so, 0, 2, 50.0, 0.9), T(ank[0], 0.016, ank[2] - 0.075)), sharp=55.0)
        tc = box_cage(0.16, 0.075, 0.13, 2, 1, 2)
        tc = deform(tc, lambda p: np.array([p[0] * (1 - 0.18 * max(0, p[2]) / 0.065),
                                            p[1] - 0.28 * max(0, p[2]) * (p[1] + 0.0375) / 0.065 * 0.5 + 0.008 * (1 - (2 * p[0] / 0.16) ** 2), p[2]]))
        b.add('toecap', 'toe_' + side, PAINT if b.cls == 'cryo' else ARMOUR, xform(b.sd(tc, 0, 3, 40.0, 0.8), T(toe[0], 0.064, toe[2] + 0.03)), sharp=55.0)
        ts = box_cage(0.17, 0.03, 0.165, 1, 1, 2)
        ts = deform(ts, lambda p: np.array([p[0] * (1 - 0.15 * max(0, p[2]) / 0.08), p[1] + 0.25 * max(0.0, p[2] - 0.03) * (p[1] + 0.015) / 0.08, p[2]]))
        b.add('toesole', 'toe_' + side, SOLE, xform(b.sd(ts, 0, 2, 50.0, 0.9), T(toe[0], 0.015, toe[2] + 0.025)), sharp=55.0)


def hand_canonical(b, side):
    """A gloved fist round a 3 cm grip whose axis runs along x at (y −0.012, z 0.078) — canonical hand frame (x
    knuckle line, toward the thumb for the right hand; y back of the hand; z wrist → knuckles). Left = mirrored."""
    parts = []
    palm = box_cage(0.086, 0.042, 0.075)
    palm = xform(b.sd(palm, 1, 2, 50.0, 0.6), T(0, 0.002, 0.046))
    parts.append((palm, DARK))
    plate = box_cage(0.078, 0.012, 0.06)
    parts.append((xform(b.sd(plate, 1, 2, 50.0, 0.7), T(0, 0.027, 0.05)), METAL))
    c = np.array([0.0, -0.012, 0.078])
    for x in (-0.03, -0.01, 0.01, 0.03):
        pts = []
        for th in (5.0, 100.0, 200.0):
            a = math.radians(th)
            pts.append(c + np.array([x, 0.031 * math.cos(a), 0.031 * math.sin(a) + 0.006]))
        for k in range(len(pts) - 1):
            p0, p1 = pts[k], pts[k + 1]
            d = p1 - p0
            L = np.linalg.norm(d)
            seg = box_cage(0.018, L * 1.15, 0.018)
            seg = xform(seg, T(0, L * 0.5, 0))
            M = frame(p0, d, (0, 1, 0) if abs(d[1]) < 0.9 * L else (0, 0, 1))
            parts.append((xform(seg, M), DARK))
    tb = [np.array([0.045, -0.022, 0.035]), np.array([0.05, -0.04, 0.07]), np.array([0.035, -0.046, 0.1])]
    for k in range(2):
        d = tb[k + 1] - tb[k]
        L = np.linalg.norm(d)
        seg = xform(box_cage(0.021, L * 1.15, 0.02), T(0, L * 0.5, 0))
        parts.append((xform(seg, frame(tb[k], d, (0, 1, 0))), DARK))
    if side == 'L':
        parts = [(mirror_x(m), mat) for m, mat in parts]
    return parts


REREBRACE_CTRL = densify([(-112, 0.92), (-76, 1.0), (-36, 1.0), (0, 1.03), (36, 1.0), (76, 1.0), (112, 0.92)])
VAMBRACE_CTRL = densify([(-150, 0.94), (-112, 1.0), (-70, 1.0), (-30, 1.0), (0, 1.03), (30, 1.0), (70, 1.0), (112, 1.0), (150, 0.94)])


def arms(b):
    c = b.cls
    for side, s in (('L', 1.0), ('R', -1.0)):
        sh, el, wr = b.J('upperarm_' + side), b.J('forearm_' + side), b.J('hand_' + side)
        mir = s < 0
        out = np.array([s, 0.25, 0.0])
        F = frame(el, sh - el, out)
        ua_prof = [(0.076, -0.01), (0.084, 0.12), (0.088, 0.25), (0.08, 0.31)]
        b.add('upperarm', 'upperarm_' + side, DARK, xform(lathe(ua_prof, 8), F), sharp=70.0)
        b.ribs(F, ua_prof, [0.035, 0.05], 'upperarm_' + side, segs=10)
        # rerebrace: a faceted shell over the outside of the upper arm, flared at the elbow
        secs = limb_sections([(0.05, REREBRACE_CTRL, 0.094, 0.006, 0.0, 0.0), (0.14, REREBRACE_CTRL, 0.1, 0.012, 0.0, 0.0),
                              (0.235, REREBRACE_CTRL, 0.098, 0.01, 0.0, 0.0)], mirror=False)
        rb = loft_shell(secs, 0.022, (0.0, 0.14, 0.0))
        rb = b.sd(rb, 0, 3, 24.0, 0.85, seams=(lambda p, n, a: a > 0.0012, 0.006, 0.003))
        b.add('bicep', 'upperarm_' + side, ARMOUR, xform(rb, F), sharp=40.0, keep=True)
        ay, ax, az = F[:3, 1], F[:3, 0], F[:3, 2]
        b.panel(['bicep'], el + ay * 0.15 + az * 0.5, ay, ax, -az, 0.13, 0.07, 'upperarm_' + side)
        b.bolts_on(['bicep'], [el + ay * yy + ax * xx + az * 0.4 for yy in (0.07, 0.22) for xx in (-0.045, 0.045)], -az, 'upperarm_' + side, r=0.006)
        hub = lathe([(0.0, -0.085), (0.07, -0.07), (0.092, 0.0), (0.07, 0.07), (0.0, 0.085)], 6)
        b.add('hub', 'clav_' + side, METAL, xform(hub, mm(T(sh[0], sh[1], sh[2]), R('Z', 90))), sharp=70.0)  # (6 segs: under the pauldron)
        F2 = frame(wr, el - wr, out)
        bd = np.array([0.0, 0.0, -1.0]) + out * 0.35
        bd /= np.linalg.norm(bd)
        cop = shield_patch(0.1, 0.11, 0.035, ridge=0.01, nu=5, nv=5, point=0.3)
        cop = b.sd(rimmed(*cop, 0.018, inner=(0.0, 0.0, -0.1)), 0, 3, 50.0, 0.85)
        b.add('elbow', 'forearm_' + side, METAL, xform(cop, frame(el + bd * 0.07, -bd, (0, 1, 0)) @ R('X', 90)), sharp=55.0)
        # vambrace: a faceted shell nearly all round the forearm, a class-paint plate on its outer face, a wrist cuff
        secs = limb_sections([(0.03, VAMBRACE_CTRL, 0.08, 0.004, 0.0, 0.0), (0.11, VAMBRACE_CTRL, 0.089, 0.01, 0.0, 0.0),
                              (0.2, VAMBRACE_CTRL, 0.091, 0.01, 0.0, 0.0), (0.258, VAMBRACE_CTRL, 0.085, 0.006, 0.0, 0.0)], mirror=False)
        vb = loft_shell(secs, 0.02, (0.0, 0.14, 0.0))
        vb = b.sd(vb, 0, 3, 24.0, 0.85, seams=(lambda p, n, a: a > 0.0012, 0.006, 0.003))
        b.add('gauntlet', 'forearm_' + side, ARMOUR, xform(vb, F2), sharp=40.0, keep=True)
        vy, vx, vz = F2[:3, 1], F2[:3, 0], F2[:3, 2]
        b.panel(['gauntlet'], wr + vy * 0.14 - vz * 0.5, vy, vx, vz, 0.16, 0.06, 'forearm_' + side)
        b.panel(['gauntlet'], wr + vy * 0.14 + vx * 0.5, vy, vz, -vx, 0.16, 0.05, 'forearm_' + side)
        b.panel(['gauntlet'], wr + vy * 0.14 - vx * 0.5, vy, vz, vx, 0.16, 0.05, 'forearm_' + side)
        tp = b.plate(['gauntlet'], wr + (el - wr) * 0.52 + out * 0.4, (el - wr), np.cross(el - wr, out), -out, 0.17, 0.085, 0.012,
                     nu=2, nv=2, r=0.25, taper=0.1, gap=0.004, crease=0.95)
        b.add('gauntlet_plate', 'forearm_' + side, PAINT, tp, sharp=45.0)
        cuffr = lathe([(0.076, 0.0), (0.083, 0.008), (0.083, 0.03), (0.076, 0.036)], 10)
        b.add('wrist_cuff', 'forearm_' + side, METAL, xform(cuffr, F2), sharp=70.0)
        if side == 'L':
            wu = box_cage(0.062, 0.022, 0.08)
            wu = xform(b.sd(wu, 1, 2, 40.0, 0.95), mm(F2, T(-0.082, 0.13, 0.0), R('Z', -90)))
            b.add('wrist_unit', 'forearm_' + side, METAL, wu, sharp=45.0)
            scr = box_cage(0.038, 0.004, 0.05)
            b.add('wrist_glow', 'forearm_' + side, GLOW, xform(scr, mm(F2, T(-0.095, 0.13, 0.0), R('Z', -90))))
        Hq = motion.hand_bind_q(side)
        HM = np.eye(4)
        HM[:3, :3] = SK.qmat(Hq)
        HM[:3, 3] = wr
        HM = HM @ S(SK.HAND_SCALE)
        for m, mat in hand_canonical(b, side):
            b.add('hand', 'hand_' + side, mat, xform(m, HM), sharp=55.0)


# ================================================================ helmets
def crest(b, names, zs, w0, w1, h, x=0.0, lift=0.0):
    """A ridge along the top of a finished surface (front → back over the given z samples): trapezoid sections w0 at
    the base, w1 on top, h tall, standing on the surface hits straight below."""
    surf = b.surface(*names)
    secs = []
    for zz in zs:
        hit, _ = surf.hit(np.array([x, 2.4, zz]), np.array([0.0, -1.0, 0.0]), 1.2)
        if hit is None:
            continue
        y0 = hit[1] - 0.006 + lift
        secs.append(np.array([(x - w0 / 2, y0, zz), (x + w0 / 2, y0, zz), (x + w1 / 2, y0 + h, zz), (x - w1 / 2, y0 + h, zz)]))
    secs = secs[::-1]           # back → front, so the loft's caps face out
    return loft_cage(secs)


def side_plate(b, names, cy, cz, w, h, s, t=0.012, r=0.3, tilt=0.0):
    """A plate conformed onto the side (x sign s) of a finished surface: cheek guards, ear plates."""
    return b.plate(names, (s * 0.5, cy, cz), (0, 0, 1), (0, 1, tilt), (-s, 0, 0), w, h, t, nu=2, nv=2, r=r, gap=0.004, crease=0.95)


def helmet(b):
    c = b.cls
    if c == 'assault':
        # recon helmet: a long red skull with a gunmetal crest, a chevron faceplate with the glowing T, a jutting
        # vented jaw, light cheek guards, comms pods, a flared neck guard
        rings = [se_ring(0.088, 0.108, 1.668, e=3.0, n=10, cz=0.03, front=0.03),
                 se_ring(0.118, 0.138, 1.705, e=3.0, n=10, cz=0.032, front=0.05),
                 se_ring(0.136, 0.152, 1.758, e=3.0, n=10, cz=0.022, front=0.028),
                 se_ring(0.142, 0.158, 1.815, e=3.0, n=10, cz=0.012, front=0.034),
                 se_ring(0.13, 0.15, 1.875, e=3.0, n=10, cz=0.0, front=0.012),
                 se_ring(0.084, 0.104, 1.922, e=3.0, n=10, cz=-0.008)]
        hm = b.sd(loft_cage(rings, cap0=False, cap1=True), 1, 3, 30.0, 0.7, boundary=0.5)
        b.add('helmet', 'head', PAINT, hm, sharp=55.0, keep=True)
        fp = b.plate(['helmet'], (0, 1.754, 0.5), (1, 0, 0), (0, 1, 0), (0, 0, -1), 0.175, 0.162, 0.014, nu=4, nv=2, r=0.32,
                     taper=-0.34, gap=0.004, crease=0.95)
        b.add('faceplate', 'head', METAL, fp, sharp=45.0, keep=True)
        for (w, h, y, t, mat) in ((0.2, 0.04, 1.786, 0.003, DARK), (0.176, 0.022, 1.786, 0.006, GLOW),
                                  (0.05, 0.088, 1.737, 0.003, DARK), (0.026, 0.07, 1.737, 0.006, GLOW)):
            v = b.sticker(['faceplate'], (0, y, 0.4), (1, 0, 0), (0, 1, 0), (0, 0, -1), w, h, r=0.3, nu=3, nv=2, t=t)
            b.add('visor', 'head', mat, v)
        jaw = box_cage(0.09, 0.05, 0.06, 2, 1, 1)
        jaw = deform(jaw, lambda p: np.array([p[0] * (1 - 0.35 * (p[2] + 0.03) / 0.06), p[1] - 0.25 * (p[2] + 0.03) * (p[1] + 0.025) / 0.06, p[2]]))
        b.add('jaw', 'head', METAL, xform(b.sd(jaw, 1, 2, 40.0, 0.95), T(0, 1.69, 0.165)), sharp=45.0, keep=True)
        b.vents(['jaw'], (0.0, 1.69, 0.4), (1, 0, 0), (0, 0, -1), 'head', 4, 0.03, 0.009, 0.007)
        cr = crest(b, ['helmet'], [0.13, 0.07, 0.0, -0.07, -0.13, -0.17], 0.04, 0.018, 0.046)
        b.add('crest', 'head', METAL, b.sd(cr, 0, 2, 40.0, 1.0), sharp=45.0)
        for s in (1.0, -1.0):
            cg = side_plate(b, ['helmet'], 1.735, 0.035, 0.12, 0.085, s, tilt=0.15)
            b.add('cheek', 'head', ARMOUR, cg, sharp=45.0)
            em = lathe([(0.0, 0.0), (0.04, 0.0), (0.046, 0.016), (0.04, 0.03), (0.0, 0.032)], 8)
            b.add('ear', 'head', METAL, xform(em, mm(T(s * 0.138, 1.8, -0.02), R('Z', -s * 90))), sharp=70.0)
        ng = wrap(0.15, 0.17, 125.0, 235.0, 0.06, 0.018, nu=2, nv=1, flare=0.02, y0=1.66)
        b.add('neckguard', 'head', PAINT, b.sd(ng, 1, 2, 40.0, 0.85), sharp=50.0)
        b.add('lamp_house', 'head', METAL, xform(cyl(0.022, 0.055, 10), mm(T(-0.158, 1.795, 0.03), R('X', 90))), sharp=70.0)
        b.add('lamp', 'head', LAMP, xform(cyl(0.017, 0.006, 10), mm(T(-0.158, 1.795, 0.088), R('X', 90))))
        b.panel(['helmet'], (0.0, 1.86, 0.5), (1, 0, 0), (0, 1, -0.8), (0, -0.3, -1), 0.12, 0.05, 'head', mat=PAINT)
        for s in (1.0, -1.0):
            b.stencil(['helmet'], (s * 0.5, 1.86, -0.02), (0, 0, -s), (0, 1, 0), (-s, 0, 0), 'head', '1' if s > 0 else '-', 0.03, MARK_DARK)
            b.decal(b.sticker(['helmet'], (s * 0.1, 1.9, 0.0), (0, 0, 1), (1, 0, 0), (-s * 0.6, -1, 0), 0.16, 0.014), 'head', MARK_DARK)
    elif c == 'pyro':
        # fire-proof helmet over a full gas mask: an amber shell with a comb and a front peak, a dark rubber mask with
        # two round glowing lenses in steel rims, a respirator snout with its filter, side filters, a neck curtain
        rings = [se_ring(0.122, 0.128, 1.665, e=2.2, n=10, cz=0.0, back=0.03),
                 se_ring(0.142, 0.15, 1.715, e=2.2, n=10, cz=0.012, back=0.02),
                 se_ring(0.15, 0.16, 1.785, e=2.2, n=10, cz=0.016),
                 se_ring(0.14, 0.152, 1.855, e=2.2, n=10, cz=0.012),
                 se_ring(0.1, 0.112, 1.912, e=2.2, n=10, cz=0.004),
                 se_ring(0.045, 0.05, 1.938, e=2.2, n=10)]
        hm = b.sd(loft_cage(rings, cap0=False, cap1=True), 1, 3, 70.0, 0.0, boundary=0.5)
        b.add('helmet', 'head', PAINT, hm, sharp=70.0, keep=True)
        cr = crest(b, ['helmet'], [0.14, 0.07, 0.0, -0.07, -0.14], 0.034, 0.022, 0.034)
        b.add('crest', 'head', PAINT, b.sd(cr, 0, 2, 40.0, 1.0), sharp=45.0)
        pk = wrap(0.162, 0.19, -62.0, 62.0, 0.03, 0.014, nu=2, nv=1, y0=1.818)
        pk = deform(pk, lambda p: np.array([p[0], p[1] - 0.25 * max(0.0, p[2] - 0.12), p[2]]))
        b.add('peak', 'head', METAL, b.sd(pk, 1, 2, 40.0, 0.9), sharp=50.0)
        mk = grid_cage(3, 2, lambda u, v: ((u - 0.5) * 0.23 * (1 - 0.28 * (1 - v)), 1.67 + 0.15 * v,
                                           0.118 + 0.05 * math.cos((u - 0.5) * 2.6) + 0.02 * (1 - v)))
        mk = b.sd(rimmed(*mk, 0.03, inner=(0, 1.74, 0)), 1, 3, 40.0, 0.8)
        b.add('mask', 'head', DARK, mk, sharp=50.0, keep=True)
        for s in (1.0, -1.0):
            M = mm(T(s * 0.056, 1.778, 0.17), R('Y', s * 18.0), R('X', 90))
            rim = lathe([(0.03, -0.004), (0.046, -0.004), (0.049, 0.012), (0.04, 0.02)], 10, cap0=False, cap1=False)
            b.add('goggle_rim', 'head', METAL, xform(rim, M), sharp=70.0)
            b.add('goggle', 'head', GLOW, xform(lathe([(0.0, 0.004), (0.036, 0.004), (0.035, 0.012), (0.0, 0.015)], 10), M))
            fl = lathe([(0.0, 0.0), (0.028, 0.0), (0.032, 0.012), (0.032, 0.042), (0.0, 0.05)], 8)
            b.add('filter', 'head', BRASS, xform(fl, mm(T(s * 0.105, 1.69, 0.13), R('Z', -s * 60), R('X', 25))), sharp=70.0)
        sn = lathe([(0.0, 0.0), (0.04, 0.0), (0.046, 0.03), (0.04, 0.062), (0.0, 0.066)], 10)
        b.add('snout', 'head', METAL, xform(sn, mm(T(0, 1.69, 0.17), R('X', 62))), sharp=70.0, keep=True)
        b.add('snout_filter', 'head', BRASS, xform(lathe([(0.0, 0.0), (0.034, 0.0), (0.036, 0.028), (0.0, 0.03)], 10), mm(T(0, 1.664, 0.218), R('X', 62))), sharp=70.0)
        nc = wrap(0.15, 0.185, 120.0, 240.0, 0.07, 0.016, nu=2, nv=1, flare=0.02, y0=1.645)
        b.add('curtain', 'head', DARK, b.sd(nc, 1, 2, 40.0, 0.8), sharp=50.0)
        b.add('lamp_house', 'head', METAL, xform(cyl(0.022, 0.05, 10), mm(T(-0.158, 1.81, 0.04), R('X', 90))), sharp=70.0)
        b.add('lamp', 'head', LAMP, xform(cyl(0.017, 0.006, 10), mm(T(-0.158, 1.81, 0.093), R('X', 90))))
        b.vents(['snout'], (0.0, 1.66, 0.6), (1, 0, 0), (0, 0.4, -1), 'head', 3, 0.02, 0.006, 0.006)
        for s in (1.0, -1.0):
            b.stencil(['helmet'], (s * 0.5, 1.83, -0.03), (0, 0, -s), (0, 1, 0), (-s, 0, 0), 'head', '2', 0.032, MARK_DARK)
        b.hazard(['helmet'], (0.0, 1.9, -0.5), (1, 0, 0), (0, 0.5, -1), (0, -0.3, 1), 'head', 0.1, 0.03, 4, MARK_DARK)
    elif c == 'cryo':
        # cryo tech: a blue back shell with a ridge, a big dark glass dome over the face with a glowing band, a steel
        # frame ring, a chin guard, cooling pods with glowing rings at the ears
        rings = [se_ring(0.108, 0.118, 1.67, e=2.4, n=12, cz=-0.006), se_ring(0.138, 0.146, 1.72, e=2.4, n=12, cz=-0.004),
                 se_ring(0.148, 0.156, 1.79, e=2.4, n=12, cz=0.0), se_ring(0.14, 0.15, 1.86, e=2.4, n=12),
                 se_ring(0.1, 0.108, 1.915, e=2.4, n=12), se_ring(0.04, 0.044, 1.942, e=2.4, n=12)]
        hm = b.sd(loft_cage(rings, cap0=False, cap1=True), 1, 3, 70.0, 0.0, boundary=0.5)
        b.add('helmet', 'head', PAINT, hm, sharp=70.0, keep=True)
        prof = [(0.12, 1.69)] + [(0.152 * math.cos(math.radians(a)), 1.765 + 0.168 * math.sin(math.radians(a))) for a in (0, 20, 40, 60, 76)] + [(0.0, 1.935)]
        dome = lathe(prof, 12, -78.0, 78.0, cap0=False, cap1=False)
        b.add('dome', 'head', GLASS, xform(dome, T(0, 0, 0.028)), sharp=80.0, keep=True)
        # a steel cage bar over the glass, brow to crown (the diver's helmet look)
        cb = crest(b, ['dome'], [0.17, 0.12, 0.06, 0.0, -0.04], 0.026, 0.016, 0.014, lift=0.004)
        b.add('cage', 'head', METAL, b.sd(cb, 0, 2, 40.0, 1.0), sharp=45.0)
        vb = b.sticker(['dome'], (0, 1.8, 0.5), (1, 0, 0), (0, 1, 0), (0, 0, -1), 0.22, 0.02, r=0.2, nu=6, nv=1, t=0.003)
        b.add('visor', 'head', GLOW, vb)
        fr = lathe([(0.15, -0.012), (0.162, -0.008), (0.162, 0.008), (0.15, 0.012)], 12, -84.0, 84.0, cap0=False, cap1=False)
        b.add('dome_ring', 'head', METAL, xform(fr, mm(T(0, 1.765, 0.026), R('Y', 0.0), R('X', 90))), sharp=70.0)
        cg = grid_cage(2, 1, lambda u, v: ((u - 0.5) * 0.2, 1.665 + 0.045 * v, 0.13 + 0.03 * math.cos((u - 0.5) * 2.8)))
        b.add('chin', 'head', ARMOUR, b.sd(rimmed(*cg, 0.024, inner=(0, 1.68, 0)), 1, 2, 40.0, 0.85), sharp=50.0)
        cr = crest(b, ['helmet'], [-0.03, -0.08, -0.13, -0.16], 0.03, 0.018, 0.03)
        b.add('crest', 'head', METAL, b.sd(cr, 0, 2, 40.0, 1.0), sharp=45.0)
        for s in (1.0, -1.0):
            pod = lathe([(0.0, 0.0), (0.045, 0.0), (0.05, 0.02), (0.044, 0.04), (0.0, 0.042)], 10)
            M = mm(T(s * 0.142, 1.77, -0.03), R('Z', -s * 90))
            b.add('ear', 'head', METAL, xform(pod, M), sharp=70.0)
            b.add('ear_glow', 'head', GLOW, xform(lathe([(0.03, 0.04), (0.04, 0.04), (0.04, 0.046), (0.03, 0.046)], 10), M))
        b.add('lamp_house', 'head', METAL, xform(cyl(0.02, 0.05, 10), mm(T(-0.15, 1.83, 0.02), R('X', 90))), sharp=70.0)
        b.add('lamp', 'head', LAMP, xform(cyl(0.016, 0.006, 10), mm(T(-0.15, 1.83, 0.073), R('X', 90))))
        for s in (1.0, -1.0):
            b.stencil(['helmet'], (s * 0.5, 1.84, -0.07), (0, 0, -s), (0, 1, 0), (-s, 0, 0), 'head', '3', 0.03, MARK_DARK)
        b.panel(['helmet'], (0.0, 1.8, -0.5), (1, 0, 0), (0, 1, 0.3), (0, 0, 1), 0.16, 0.09, 'head', mat=PAINT)
    else:
        # heavy gunner: a squared great-helm with chamfered corners, a gunmetal brow plate over a narrow glowing slit,
        # a vertical ridge, a slotted jaw grille, light cheek plates with bolts
        rings = [se_ring(0.122, 0.124, 1.665, e=4.2, cz=0.012), se_ring(0.148, 0.152, 1.705, e=4.2, cz=0.014),
                 se_ring(0.157, 0.16, 1.8, e=4.2, cz=0.014, front=0.012), se_ring(0.152, 0.155, 1.88, e=4.2, cz=0.012),
                 se_ring(0.13, 0.132, 1.924, e=4.2, cz=0.01)]
        hm = b.sd(loft_cage(rings, cap0=False, cap1=True), 1, 3, 40.0, 0.9, boundary=0.5)
        b.add('helmet', 'head', PAINT, hm, sharp=45.0, keep=True)
        br = b.plate(['helmet'], (0, 1.84, 0.5), (1, 0, 0), (0, 1, 0), (0, 0, -1), 0.27, 0.05, 0.018, r=0.2, nu=4, nv=1, crease=0.95)
        b.add('brow', 'head', METAL, br, sharp=45.0)
        for (w, h, t, mat) in ((0.21, 0.036, 0.003, DARK), (0.19, 0.016, 0.006, GLOW)):
            b.add('visor', 'head', mat, b.sticker(['helmet'], (0, 1.796, 0.5), (1, 0, 0), (0, 1, 0), (0, 0, -1), w, h, r=0.2, nu=4, nv=1, t=t))
        gr = b.plate(['helmet'], (0, 1.718, 0.5), (1, 0, 0), (0, 1, 0), (0, 0, -1), 0.13, 0.08, 0.02, r=0.3, nu=2, nv=2, taper=0.25, crease=0.95)
        b.add('grille', 'head', METAL, gr, sharp=45.0, keep=True)
        b.vents(['grille'], (0, 1.718, 0.5), (1, 0, 0), (0, 0, -1), 'head', 5, 0.055, 0.008, 0.007)
        cr = crest(b, ['helmet'], [0.15, 0.09, 0.03, -0.03, -0.09, -0.15], 0.04, 0.026, 0.03)
        b.add('crest', 'head', METAL, b.sd(cr, 0, 2, 40.0, 1.0), sharp=45.0)
        for s in (1.0, -1.0):
            cg = side_plate(b, ['helmet'], 1.76, 0.02, 0.15, 0.12, s)
            b.add('cheek', 'head', ARMOUR, cg, sharp=45.0)
            b.bolts_on(['helmet'], [(s * 0.2, 1.72, z) for z in (-0.04, 0.08)] + [(s * 0.2, 1.81, z) for z in (-0.04, 0.08)], (-s, 0, 0), 'head', r=0.008)
            b.stencil(['helmet'], (s * 0.5, 1.885, 0.0), (0, 0, -s), (0, 1, 0), (-s, 0, 0), 'head', '4', 0.026, MARK_DARK)
        b.add('lamp_house', 'head', METAL, xform(cyl(0.024, 0.055, 10), mm(T(-0.17, 1.82, 0.04), R('X', 90))), sharp=70.0)
        b.add('lamp', 'head', LAMP, xform(cyl(0.019, 0.006, 10), mm(T(-0.17, 1.82, 0.098), R('X', 90))))


# ================================================================ pauldrons
def dome_patch(cx, s, rx, ry, rz, phi0, phi1, th0, th1, nu=5, nv=3):
    """Ellipsoid patch over a shoulder (x outward for side s): phi front ↔ back (deg), theta from high to low."""
    def fn(u, v):
        ph = math.radians(phi0 + (phi1 - phi0) * u)
        th = math.radians(th0 + (th1 - th0) * v)
        return (cx[0] + s * rx * math.cos(th) * math.cos(ph), cx[1] + ry * math.sin(th), cx[2] + rz * math.cos(th) * math.sin(ph))
    V, F = grid_cage(nu, nv, fn)
    if s < 0:
        F = [f[::-1] for f in F]
    return V, F


def pauldrons(b):
    """Shoulder shells capping the shoulder from just over the collar line down the outside of the upper arm (the dome
    centred a little outboard of the shoulder joint); assault / gunner add shingled lames below the cap."""
    c = b.cls
    for side, s in (('L', 1.0), ('R', -1.0)):
        bone = 'pauldron_' + side
        cx = b.J('upperarm_' + side) + np.array([s * 0.045, 0.006, -0.01])
        big = {'assault': 1.0, 'pyro': 1.0, 'cryo': 0.98, 'gunner': 1.16}[c]
        rx, ry, rz = 0.182 * big, 0.145 * big, 0.2 * big
        cap_lo = {'assault': 22.0, 'pyro': -20.0, 'cryo': 0.0, 'gunner': 30.0}[c]
        VF = dome_patch(cx, s, rx, ry, rz, 78.0, -78.0, 124.0, cap_lo, 5, 3)
        VF = b.sd(rimmed(*VF, 0.022, inner=cx), 1, 3, 50.0, 0.85)
        b.add('pauldron', bone, PAINT, VF, sharp=55.0, keep=True)
        cap_surface = ['pauldron']
        if c in ('assault', 'gunner'):
            n = 1 if c == 'assault' else 2
            for k in range(n):
                th0 = cap_lo + 10.0 - (26.0 if c == 'assault' else 32.0) * k
                th1 = th0 - 30.0
                g = 1.05 + 0.05 * k
                L = dome_patch(cx, s, rx * g, ry * g, rz * g, 74.0, -74.0, th0, th1, 8, 2)
                b.add('pauldron_lame', bone, PAINT, b.sd(rimmed(*L, 0.02, inner=cx), 0, 3, 50.0, 0.85), sharp=55.0)
            gl = dome_patch(cx, s, rx * g + 0.002, ry * g + 0.002, rz * g + 0.002, 60.0, -60.0, th1 + 7.0, th1 + 3.5, 6, 1)
            b.add('pauldron_glow', bone, GLOW, thicken(*gl, -0.004))
        elif c == 'pyro':
            rim = dome_patch(cx, s, rx + 0.008, ry + 0.008, rz + 0.008, 76.0, -76.0, cap_lo + 8.0, cap_lo - 4.0, 10, 1)
            b.add('pauldron_rim', bone, METAL, b.sd(rimmed(*rim, 0.024, inner=cx), 0, 2, 50.0, 0.8), sharp=55.0)
        else:
            gl = dome_patch(cx, s, rx + 0.002, ry + 0.002, rz + 0.002, 62.0, -62.0, cap_lo + 9.0, cap_lo + 5.0, 6, 1)
            b.add('pauldron_glow', bone, GLOW, thicken(*gl, -0.005))
        if c != 'pyro':
            # a raised gunmetal trim along the cap's lower edge (the classic armoured-shoulder rim)
            tr = dome_patch(cx, s, rx + 0.007, ry + 0.007, rz + 0.007, 80.0, -80.0, cap_lo + 6.5, cap_lo - 1.0, 10, 1)
            b.add('pauldron_trim', bone, METAL, b.sd(rimmed(*tr, 0.02, inner=cx), 0, 2, 50.0, 0.9), sharp=50.0)
        b.decal(b.sticker(cap_surface, cx + np.array([s * 0.05, 0.3, 0.0]), (0, 0, 1), (s, 0, 0), (-s * 0.35, -1, 0), 0.11, 0.022), bone, MARK_DARK)
        b.bolts_on(cap_surface, [cx + np.array([s * 0.03, 0.2, z]) for z in (-0.1, 0.1)], (0, -1, 0), bone)
        # rank chevrons and the squad number on the outer face, a raised panel on the cap
        out = np.array([s, 0.55, 0.0])
        b.stencil(cap_surface, cx + out * 0.4, (0, 0, -s), (0, 1, 0), -out, bone, '^^' if c == 'assault' else '^', 0.045, MARK_DARK)
        b.panel(cap_surface, cx + np.array([s * 0.02, 0.4, 0.0]), (0, 0, 1), (s, 0, 0), (-s * 0.3, -1, 0), 0.17, 0.08, bone, mat=PAINT)


# ================================================================ backpacks
def hose(b, pts, r, bone_a, bone_b, mat=DARK, segs=8):
    """A tube along pts (model space), skinned from bone_a (start) to bone_b (end) by arc length."""
    pts = [np.asarray(p, dtype=np.float64) for p in pts]
    P = []
    ext = [pts[0] * 2 - pts[1]] + pts + [pts[-1] * 2 - pts[-2]]
    for i in range(1, len(ext) - 2):
        p0, p1, p2, p3 = ext[i - 1], ext[i], ext[i + 1], ext[i + 2]
        for k in range(4):
            t = k / 4
            P.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (-p0 + 3 * p1 - 3 * p2 + p3) * t ** 3))
    P.append(pts[-1])
    rings = []
    for i, p in enumerate(P):
        d = (P[min(i + 1, len(P) - 1)] - P[max(i - 1, 0)])
        d /= np.linalg.norm(d)
        a = np.cross(d, (0.0, 1.0, 0.0) if abs(d[1]) < 0.9 else (1.0, 0.0, 0.0))
        a /= np.linalg.norm(a)
        c = np.cross(d, a)
        rr = r * (1.0 + (0.14 if (i % 2 == 0 and b.hi) else 0.0))
        rings.append([p + (a * math.cos(2 * math.pi * k / segs) + c * math.sin(2 * math.pi * k / segs)) * rr for k in range(segs)])
    V, F = loft_cage(rings, cap0=False, cap1=False)
    L = np.cumsum([0.0] + [np.linalg.norm(P[i + 1] - P[i]) for i in range(len(P) - 1)])
    wts = np.repeat(L / L[-1], segs)
    b.parts.append(Part('hose', bone_a, mat, V, F, sharp_deg=80.0, blend=(bone_b, np.clip((wts - 0.15) / 0.7, 0, 1))))


def backpack(b):
    c = b.cls
    bone = 'backpack'
    if c == 'assault':
        # jump pack: a tapered armoured shell with a gunmetal spine, two heavy thruster nacelles angled out at the
        # bottom, vents, a hazard band, the antenna on its mast
        bx = box_cage(0.34, 0.34, 0.15, 2, 2, 1)
        bx = deform(bx, lambda p: np.array([p[0] * (1 - 0.16 * (0.17 - p[1]) / 0.34), p[1], p[2] - 0.03 * (p[1] + 0.17) / 0.34]))
        bx = b.sd(bx, 1, 3, 40.0, 0.92, seams=(lambda p, n, a: n[2] < -0.6, 0.014, 0.005))
        b.add('pack', bone, ARMOUR, xform(bx, T(0, 1.44, -0.296)), sharp=50.0, keep=True)
        sp = box_cage(0.09, 0.36, 0.05, 1, 2, 1)
        sp = deform(sp, lambda p: np.array([p[0] * (1 - 0.3 * (p[2] + 0.025) / 0.05), p[1], p[2]]))
        b.add('pack_spine', bone, METAL, xform(b.sd(sp, 1, 2, 40.0, 0.95), T(0, 1.45, -0.385)), sharp=45.0)
        tp = box_cage(0.28, 0.05, 0.13)
        b.add('pack_top', bone, METAL, xform(b.sd(tp, 1, 2, 40.0, 0.9), T(0, 1.628, -0.3)), sharp=50.0)
        for s in (1.0, -1.0):
            nz = lathe([(0.066, -0.03), (0.074, 0.0), (0.078, 0.04), (0.07, 0.09), (0.06, 0.15)], 10, cap0=False, cap1=False)
            M = mm(T(s * 0.15, 1.33, -0.35), R('X', 160), R('Z', -s * 16))
            b.add('thruster', bone, METAL, xform(nz, M), sharp=70.0)
            b.add('thruster_glow', bone, GLOW, xform(lathe([(0.0, 0.0), (0.05, 0.0), (0.05, 0.006), (0.0, 0.006)], 8), mm(M, T(0, 0.03, 0))))
            col = lathe([(0.079, -0.004), (0.084, 0.004), (0.084, 0.02), (0.079, 0.026)], 10, cap0=False, cap1=False)
            b.add('thruster_ring', bone, PAINT, xform(col, mm(M, T(0, 0.03, 0))), sharp=70.0)
            b.vents(['pack'], (s * 0.5, 1.47, -0.3), (0, 1, 0), (-s, 0, 0), bone, 4, 0.08, 0.012, 0.014)
        b.add('pack_glow', bone, GLOW, xform(box_cage(0.03, 0.012, 0.008), T(0.1, 1.58, -0.378)))
        b.hazard(['pack'], (0.0, 1.31, -0.6), (1, 0, 0), (0, 1, 0), (0, 0, 1), bone, 0.22, 0.04, 6, MARK_DARK)
        b.stencil(['pack'], (-0.1, 1.56, -0.6), (-1, 0, 0), (0, 1, 0), (0, 0, 1), bone, '01', 0.045, MARK_DARK)
        a = b.J('antenna')
        b.add('antenna_base', 'antenna', METAL, xform(cyl(0.02, 0.045, 8), T(a[0], a[1] - 0.045, a[2])), sharp=70.0)
        b.add('antenna', 'antenna', METAL, xform(cyl(0.007, 0.44, 6, r1=0.004), T(a[0], a[1], a[2])), sharp=70.0)
        b.add('antenna_tip', 'antenna', GLOW, xform(cyl(0.013, 0.022, 8), T(a[0], a[1] + 0.44, a[2])))
    elif c == 'pyro':
        tz = -0.318
        for s in (1.0, -1.0):
            tk = lathe([(0.0, 1.18), (0.056, 1.184), (0.081, 1.212), (0.09, 1.256), (0.09, 1.6), (0.081, 1.645), (0.052, 1.674), (0.0, 1.68)], 9)
            b.add('tank', bone, PAINT, xform(tk, T(s * 0.108, 0, tz)), sharp=70.0, keep=True)
            b.hazard(['tank'], (s * 0.108, 1.45, tz - 0.5), (1, 0, 0), (0, 1, 0), (0, 0, 1), bone, 0.16, 0.06, 4, MARK_DARK)
            b.stencil(['tank'], (s * 0.108, 1.36, tz - 0.5), (-1, 0, 0), (0, 1, 0), (0, 0, 1), bone, '-0' + ('2' if s > 0 else '3'), 0.03, MARK_DARK)
            for y in (1.29, 1.53):
                band = lathe([(0.091, y), (0.098, y + 0.006), (0.098, y + 0.032), (0.091, y + 0.038)], 8)
                b.add('tank_band', bone, METAL, xform(band, T(s * 0.108, 0, tz)), sharp=70.0)
            b.decal(xform(box_cage(0.068, 0.11, 0.002), T(s * 0.108, 1.41, tz - 0.0905)), bone, MARK_DARK)
        b.add('valve', bone, BRASS, xform(cyl(0.027, 0.08, 10), mm(T(0, 1.695, tz), R('Z', 90), T(0, -0.04, 0))), sharp=70.0)
        b.add('pilot', bone, GLOW, xform(cyl(0.013, 0.022, 8), T(0.0, 1.705, tz + 0.03)))
        fr = box_cage(0.34, 0.4, 0.05, 2, 2, 1)
        b.add('tank_frame', bone, METAL, xform(b.sd(fr, 1, 2, 50.0, 0.85), T(0, 1.43, -0.222)), sharp=55.0)
        g = SK.WEAPON['pyro']['grip']
        hose(b, [(0.108, 1.195, tz - 0.015), (0.22, 1.06, -0.22), (0.32, 1.02, 0.0), (g[0] + 0.01, g[1] + 0.05, g[2] - 0.15)], 0.025, 'backpack', 'weapon')
    elif c == 'cryo':
        tz = -0.345
        tk = lathe([(0.0, 1.2), (0.08, 1.204), (0.114, 1.238), (0.128, 1.29), (0.128, 1.57), (0.114, 1.615), (0.08, 1.648), (0.0, 1.653)], 12)
        b.add('tank', bone, ARMOUR, xform(tk, T(0, 0, tz)), sharp=70.0, keep=True)
        for s in (1.0, -1.0):
            b.panel(['tank'], (s * 0.5, 1.43, tz), (0, 1, 0), (0, 0, 1), (-s, 0, 0), 0.2, 0.07, bone, mat=METAL)
        b.stencil(['tank'], (0.0, 1.31, tz - 0.5), (-1, 0, 0), (0, 1, 0), (0, 0, 1), bone, '-196', 0.028, MARK_DARK)
        win = lathe([(0.129, 1.33), (0.133, 1.336), (0.133, 1.54), (0.129, 1.546)], 12, 140, 220)
        b.add('tank_glow', bone, GLOW, xform(win, T(0, 0, tz)))
        for y in (1.28, 1.42, 1.57):
            fin = lathe([(0.126, y), (0.148, y + 0.004), (0.148, y + 0.018), (0.126, y + 0.022)], 12)
            b.add('fin', bone, METAL, xform(fin, T(0, 0, tz)), sharp=70.0)
        b.add('tank_cap', bone, METAL, xform(cyl(0.046, 0.055, 12), T(0, 1.648, tz)), sharp=70.0)
        mt = box_cage(0.27, 0.33, 0.05, 2, 2, 1)
        b.add('tank_mount', bone, METAL, xform(b.sd(mt, 1, 2, 50.0, 0.85), T(0, 1.42, -0.222)), sharp=55.0)
        g = SK.WEAPON['cryo']['grip']
        hose(b, [(0.07, 1.25, tz - 0.08), (0.21, 1.1, -0.26), (0.31, 1.08, -0.02), (g[0], g[1] + 0.07, g[2] - 0.16)], 0.023, 'backpack', 'weapon')
    else:  # gunner: ammo drum
        dz = -0.392
        dr = lathe([(0.0, -0.21), (0.15, -0.21), (0.172, -0.188), (0.172, 0.188), (0.15, 0.21), (0.0, 0.21)], 12)
        M = mm(T(0.0, 1.43, dz), R('Z', 90))
        b.add('drum', bone, PAINT, xform(dr, M), sharp=60.0, keep=True)
        b.stencil(['drum'], (0.0, 1.43, dz - 0.5), (-1, 0, 0), (0, 1, 0), (0, 0, 1), bone, '04', 0.06, MARK_DARK)
        b.hazard(['drum'], (0.0, 1.62, dz), (1, 0, 0), (0, 0, 1), (0, -1, 0), bone, 0.26, 0.06, 6, MARK_DARK)
        for x in (-0.135, 0.0, 0.135):
            band = lathe([(0.174, -0.016), (0.181, -0.011), (0.181, 0.011), (0.174, 0.016)], 12)
            b.add('drum_band', bone, METAL, xform(band, mm(T(x, 1.43, dz), R('Z', 90))), sharp=70.0)
        b.add('drum_hub', bone, METAL, xform(lathe([(0.0, 0.21), (0.08, 0.21), (0.068, 0.238), (0.0, 0.243)], 12), M), sharp=70.0)
        b.add('drum_glow', bone, GLOW, xform(box_cage(0.34, 0.013, 0.008), T(0, 1.606, dz - 0.012)))
        mt = box_cage(0.34, 0.34, 0.06, 2, 2, 1)
        b.add('drum_mount', bone, METAL, xform(b.sd(mt, 1, 2, 50.0, 0.85), T(0, 1.44, -0.215)), sharp=55.0)
        g = SK.WEAPON['gunner']['grip']
        hose(b, [(0.22, 1.36, dz), (0.32, 1.2, -0.22), (0.35, 1.12, -0.02), (g[0] + 0.085, g[1] + 0.09, g[2] + 0.05)], 0.034, 'backpack', 'weapon', mat=METAL, segs=6)


# ================================================================ weapons (weapon-local, placed at the grip)
def gun_prism(profile, width, x=0.0):
    """A weapon part drawn as its side silhouette [(z, y)] extruded `width` across (x): flat-shaded and crisp in the
    LOW mesh, its edges bevelled in the HIGH bake source (the classic low-poly gun with baked chamfers)."""
    V, F = prism(profile, width, axis='x')
    return xform((V, F), T(x, 0.0, 0.0))


def weapon(b):
    """Each class's weapon, oversized for the game camera (≈ 1.35× a realistic cross-section), the bore raised over the
    gauntleted fist; muzzles stay where the core spawns the bolts (≈ 0.95 m ahead of the feet in the stance). Bodies are
    side silhouettes extruded and bevelled (gun_prism); vents, rails, stencils and hazard stripes go into the maps."""
    c = b.cls
    g = np.asarray(SK.WEAPON[c]['grip'], dtype=np.float64)
    G = T(*g)
    bone = 'weapon'

    def add(name, mat, VF, bone_=bone, sharp=55.0, keep=False):
        return b.add(name, bone_, mat, xform(VF, G), sharp=sharp, keep=keep)

    def det(VF):
        b.detail(xform(VF, G), bone)

    def W(p):
        return np.asarray(p, dtype=np.float64) + g

    def hard(VF):
        # LOW: the flat-shaded silhouette; HIGH: the same with every edge chamfered 4 mm (baked as crisp highlights)
        return bevel_mesh(VF[0], VF[1], 0.004, 2, sharp_only_deg=20.0) if b.hi else VF

    def blk(sx, sy, sz, pos, n=(1, 1, 1), lo=1, hi=3, crease=0.85, fn=None, seams=None):
        VF = box_cage(sx, sy, sz, *n)
        if fn is not None:
            VF = deform(VF, fn)
        return xform(b.sd(VF, lo, hi, 50.0, crease, seams=seams), T(*pos))

    # pistol grip under the gun hand, tilted back
    add('grip', DARK, xform(hard(gun_prism([(0.028, 0.05), (-0.022, 0.05), (-0.034, -0.06), (-0.022, -0.075), (0.014, -0.07)], 0.04)),
                            R('X', -12)))
    sup = np.asarray(motion.GRIPS[c]['sup'])
    if c == 'assault':
        # bullpup pulse rifle: a long faceted receiver with a cheek rest, the magazine behind the grip, a vented
        # shroud, a muzzle brake, a holographic sight on a rail, an under-barrel launcher, glowing cells
        body = [(-0.34, 0.03), (-0.34, 0.135), (-0.27, 0.152), (-0.06, 0.152), (0.0, 0.162), (0.3, 0.156), (0.345, 0.138),
                (0.345, 0.05), (0.25, 0.04), (0.16, 0.034), (0.05, 0.046), (-0.05, 0.034), (-0.2, 0.024), (-0.3, 0.024)]
        add('receiver', ARMOUR, hard(gun_prism(body, 0.074)), keep=True)
        add('rail', METAL, hard(gun_prism([(-0.04, 0.16), (0.24, 0.16), (0.24, 0.172), (-0.04, 0.172)], 0.032)))
        shroud = lathe([(0.032, 0.0), (0.036, 0.012), (0.036, 0.25), (0.03, 0.27)], 8, cap0=False, cap1=False)
        add('shroud', METAL, xform(b.sd(shroud, 0, 2, 25.0, 0.9), mm(T(0, 0.092, 0.34), R('X', 90))), keep=True)
        add('barrel', HOT, xform(cyl(0.017, 0.06, 10), mm(T(0, 0.092, 0.605), R('X', 90))), sharp=70.0)
        add('muzzle', HOT, hard(gun_prism([(0.66, 0.064), (0.725, 0.068), (0.725, 0.116), (0.66, 0.12)], 0.052)), keep=True)
        add('mag', METAL, xform(hard(gun_prism([(-0.035, 0.0), (0.035, 0.0), (0.045, -0.12), (-0.025, -0.13)], 0.05)), T(0, 0.04, -0.15)))
        add('optic', METAL, hard(gun_prism([(0.0, 0.17), (0.12, 0.17), (0.12, 0.215), (0.085, 0.228), (0.02, 0.228), (0.0, 0.205)], 0.05)))
        add('optic_lens', GLOW, xform(box_cage(0.034, 0.03, 0.004), T(0, 0.205, 0.123)))
        add('launcher', METAL, xform(cyl(0.027, 0.2, 10), mm(T(0, 0.022, 0.355), R('X', 90))), sharp=70.0)
        add('launcher_cap', DARK, xform(cyl(0.023, 0.012, 10), mm(T(0, 0.022, 0.553), R('X', 90))), sharp=70.0)
        for s in (1.0, -1.0):
            add('cell_glow', GLOW, xform(box_cage(0.004, 0.012, 0.16), T(s * 0.038, 0.118, -0.12)))
        add('foregrip', DARK, xform(blk(0.034, 0.11, 0.04, (0, -0.012, 0), lo=1, hi=2, crease=0.6), mm(T(*sup), R('X', 6))))
        add('fg_mount', METAL, blk(0.062, 0.03, 0.05, (sup[0] + 0.022, 0.036, sup[2]), lo=1, hi=2))
        b.vents(['shroud'], W((0.0, 0.2, 0.47)), W((0.0, 0.0, 1.0)) - g, (0, -1, 0), bone, 6, 0.02, 0.016, 0.012)
        for s in (1.0, -1.0):
            b.vents(['muzzle'], W((s * 0.2, 0.092, 0.692)), (0, 0, 1), (-s, 0, 0), bone, 3, 0.03, 0.008, 0.008)
            b.panel(['receiver'], W((s * 0.2, 0.1, 0.12)), (0, 0, 1), (0, 1, 0), (-s, 0, 0), 0.2, 0.07, bone, mat=ARMOUR)
            b.stencil(['receiver'], W((s * 0.2, 0.07, -0.22)), (0, 0, s), (0, 1, 0), (-s, 0, 0), bone, '07', 0.03, MARK_DARK)
        b.hazard(['receiver'], W((0.0, 0.3, -0.31)), (0, 0, 1), (1, 0, 0), (0, -1, 0), bone, 0.06, 0.07, 3, MARK_DARK)
    elif c == 'pyro':
        # flamer «Факел»: a squat receiver, a pressurised fuel tank slung under it, a long barrel in a perforated heat
        # shield, a flared nozzle with the igniter and its pilot light, a pressure gauge
        by = 0.088
        body = [(-0.15, 0.04), (-0.15, 0.13), (-0.08, 0.15), (0.2, 0.15), (0.26, 0.125), (0.26, 0.05), (0.18, 0.035), (-0.06, 0.035)]
        add('body', METAL, hard(gun_prism(body, 0.1)), keep=True)
        add('barrel', METAL, xform(cyl(0.03, 0.4, 10), mm(T(0, by, 0.25), R('X', 90))), sharp=70.0)
        sh = lathe([(0.05, 0.0), (0.054, 0.015), (0.054, 0.22), (0.048, 0.24)], 8, cap0=False, cap1=False)
        add('heatshield', ARMOUR, xform(b.sd(sh, 0, 2, 25.0, 0.9), mm(T(0, by, 0.3), R('X', 90))), keep=True)
        nz = lathe([(0.04, 0.0), (0.044, 0.05), (0.058, 0.1), (0.07, 0.13), (0.062, 0.138), (0.05, 0.115), (0.036, 0.05),
                    (0.032, 0.0)], 12, cap0=False, cap1=False)
        add('nozzle', HOT, xform(nz, mm(T(0, by, 0.63), R('X', 90))), sharp=70.0)
        add('nozzle_glow', GLOW, xform(lathe([(0.0, 0.0), (0.036, 0.0), (0.036, 0.006), (0.0, 0.006)], 10), mm(T(0, by, 0.718), R('X', 90))))
        add('igniter', BRASS, blk(0.026, 0.026, 0.07, (0.0, by - 0.06, 0.725), lo=1, hi=2))
        add('pilot', LAMP, xform(cyl(0.009, 0.012, 8), mm(T(0.0, by - 0.054, 0.763), R('X', 90))))
        tank = lathe([(0.0, 0.0), (0.04, 0.0), (0.052, 0.02), (0.052, 0.26), (0.04, 0.28), (0.0, 0.28)], 10)
        add('canister', PAINT, xform(tank, mm(T(0, -0.016, 0.03), R('X', 90))), sharp=70.0, keep=True)
        for zz in (0.08, 0.24):
            add('tank_band', METAL, xform(lathe([(0.053, -0.008), (0.057, -0.004), (0.057, 0.004), (0.053, 0.008)], 10), mm(T(0, -0.016, zz), R('X', 90))), sharp=70.0)
        gauge = lathe([(0.0, 0.0), (0.024, 0.0), (0.027, 0.01), (0.0, 0.012)], 10)
        add('gauge', METAL, xform(gauge, mm(T(0.05, 0.12, 0.08), R('Z', -90))), sharp=70.0)
        add('handle', DARK, xform(blk(0.034, 0.11, 0.04, (0, -0.006, 0), lo=1, hi=2, crease=0.6), mm(T(*sup), R('X', -10))))
        add('handle_mount', METAL, blk(0.05, 0.045, 0.055, (sup[0] + 0.035, sup[1] + 0.05, sup[2]), lo=1, hi=2))
        add('strip', GLOW, xform(box_cage(0.004, 0.01, 0.14), T(0.051, 0.13, 0.08)))
        b.vents(['heatshield'], W((0.0, 0.3, 0.42)), (0, 0, 1), (0, -1, 0), bone, 7, 0.024, 0.014, 0.012)
        for s in (1.0, -1.0):
            b.vents(['heatshield'], W((s * 0.3, by, 0.42)), (0, 0, 1), (-s, 0, 0), bone, 7, 0.024, 0.014, 0.012)
            b.panel(['body'], W((s * 0.3, 0.095, 0.05)), (0, 0, 1), (0, 1, 0), (-s, 0, 0), 0.22, 0.07, bone, mat=METAL)
        b.hazard(['canister'], W((0.0, -0.2, 0.17)), (0, 0, 1), (1, 0, 0), (0, 1, 0), bone, 0.2, 0.05, 5, MARK_DARK)
    elif c == 'cryo':
        # cryo projector «Криолуч»: a sleek faceted body with heat-sink fins, a glowing coolant canister on top, the
        # emitter rod with three coils that spin (weapon_aux) and an emitter crown
        by = 0.08
        body = [(-0.25, 0.03), (-0.25, 0.1), (-0.14, 0.14), (0.1, 0.15), (0.28, 0.13), (0.32, 0.095), (0.3, 0.05),
                (0.16, 0.022), (0.05, 0.03), (-0.05, 0.02)]
        add('body', ARMOUR, hard(gun_prism(body, 0.1)), keep=True)
        add('barrel', HOT, xform(cyl(0.028, 0.42, 10), mm(T(0, by, 0.3), R('X', 90))), sharp=70.0)
        for z in (0.48, 0.56, 0.64):
            coil = lathe([(0.04, -0.011), (0.066, -0.011), (0.075, 0.0), (0.066, 0.011), (0.04, 0.011)], 10)
            b.add('coil', 'weapon_aux', GLOW, xform(coil, mm(G, T(0, by, z), R('X', 90))))
        add('emitter', HOT, xform(lathe([(0.0, 0.0), (0.042, 0.0), (0.05, 0.03), (0.034, 0.058), (0.0, 0.058)], 10), mm(T(0, by, 0.7), R('X', 90))), sharp=70.0)
        can = lathe([(0.0, 0.0), (0.034, 0.0), (0.04, 0.02), (0.04, 0.2), (0.034, 0.22), (0.0, 0.22)], 10)
        add('canister', GLASS, xform(can, mm(T(0, 0.19, -0.04), R('X', 90))), sharp=70.0)
        add('can_glow', GLOW, xform(box_cage(0.008, 0.012, 0.16), T(0.0, 0.232, 0.07)))
        for z in (0.0, 0.07, 0.14):
            add('fin', METAL, hard(gun_prism([(z - 0.012, 0.03), (z + 0.012, 0.03), (z + 0.012, 0.15), (z - 0.012, 0.15)], 0.15)))
        add('foregrip', DARK, xform(blk(0.034, 0.11, 0.04, (0, -0.012, 0), lo=1, hi=2, crease=0.6), T(*sup)))
        add('fg_mount', METAL, blk(0.056, 0.032, 0.05, (sup[0] + 0.022, 0.032, sup[2]), lo=1, hi=2))
        add('stock', ARMOUR, hard(gun_prism([(-0.4, 0.03), (-0.4, 0.12), (-0.25, 0.12), (-0.25, 0.04)], 0.056)))
        for s in (1.0, -1.0):
            b.panel(['body'], W((s * 0.3, 0.09, -0.12)), (0, 0, 1), (0, 1, 0), (-s, 0, 0), 0.18, 0.06, bone, mat=ARMOUR)
            b.stencil(['body'], W((s * 0.3, 0.06, 0.22)), (0, 0, s), (0, 1, 0), (-s, 0, 0), bone, '-3', 0.028, MARK_DARK)
    else:  # gunner: rotary cannon
        by = 0.1
        hs = [(-0.14, 0.01), (-0.14, 0.17), (-0.05, 0.2), (0.24, 0.2), (0.33, 0.16), (0.33, 0.03), (0.2, 0.0), (-0.02, 0.0)]
        add('housing', METAL, hard(gun_prism(hs, 0.16, x=-0.01)), keep=True)
        add('status', GLOW, xform(box_cage(0.004, 0.012, 0.16), T(0.071, by + 0.06, 0.06)))
        aux = np.asarray(SK.WEAPON[c]['aux']) - g
        for k in range(6):
            a = 2 * math.pi * k / 6
            bx, by_ = aux[0] + 0.05 * math.cos(a), aux[1] + 0.05 * math.sin(a)
            b.add('barrel', 'weapon_aux', HOT, xform(cyl(0.017, 0.56, 8), mm(G, T(bx, by_, 0.31), R('X', 90))), sharp=70.0)
        for z in (0.33, 0.57, 0.81):
            cl = lathe([(0.0, 0.0), (0.075, 0.0), (0.079, 0.014), (0.075, 0.028), (0.0, 0.028)], 10)
            b.add('clamp', 'weapon_aux', METAL, xform(cl, mm(G, T(aux[0], aux[1], z), R('X', 90))), sharp=70.0)
        b.add('spindle', 'weapon_aux', DARK, xform(cyl(0.026, 0.53, 8), mm(G, T(aux[0], aux[1], 0.31), R('X', 90))), sharp=70.0)
        mz = lathe([(0.06, 0.0), (0.079, 0.0), (0.082, 0.018), (0.079, 0.034), (0.06, 0.034)], 12, cap0=False, cap1=False)
        b.add('muzzle_ring', 'weapon_aux', HOT, xform(mz, mm(G, T(aux[0], aux[1], 0.84), R('X', 90))), sharp=70.0)
        sh = lathe([(0.095, 0.0), (0.1, 0.012), (0.1, 0.2), (0.094, 0.215)], 8, 300.0, 420.0, cap0=False, cap1=False)
        add('shroud', ARMOUR, xform(b.sd(sh, 0, 2, 25.0, 0.9), mm(T(aux[0], aux[1], 0.36), R('X', 90))), keep=True)
        add('motor', DARK, xform(cyl(0.05, 0.08, 10), mm(T(aux[0], aux[1], -0.21), R('X', 90))), sharp=70.0)
        add('handle', DARK, xform(cyl(0.019, 0.18, 10), mm(T(sup[0], sup[1], sup[2] - 0.09), R('X', 90))), sharp=70.0)
        for z in (-0.075, 0.075):
            add('handle_post', METAL, blk(0.028, 0.075, 0.028, (sup[0], sup[1] - 0.04, sup[2] + z), lo=1, hi=2))
        add('feed', METAL, blk(0.06, 0.075, 0.095, (0.088, by, 0.05), lo=1, hi=2))
        for s in (1.0, -1.0):
            b.vents(['housing'], W((s * 0.3, 0.1, 0.12)), (0, 0, 1), (-s, 0, 0), bone, 6, 0.08, 0.014, 0.014)
            b.stencil(['housing'], W((s * 0.3, 0.05, -0.08)), (0, 0, s), (0, 1, 0), (-s, 0, 0), bone, '04', 0.03, MARK_DARK)
        b.hazard(['housing'], W((-0.01, 0.4, 0.27)), (1, 0, 0), (0, 0, 1), (0, -1, 0), bone, 0.14, 0.05, 4, MARK_DARK)
    tx, ty = {'assault': (-0.066, 0.088), 'pyro': (-0.078, 0.1), 'cryo': (-0.07, 0.085), 'gunner': (-0.1, 0.11)}[c]
    add('torch', METAL, xform(cyl(0.026, 0.075, 10), mm(T(tx, ty, 0.3), R('X', 90))), sharp=70.0)
    add('torch_lens', LAMP, xform(cyl(0.021, 0.005, 10), mm(T(tx, ty, 0.375), R('X', 90))))


def build(cls, hi=False):
    b = Builder(cls, hi)
    torso(b)
    pelvis(b)
    legs(b)
    arms(b)
    helmet(b)
    pauldrons(b)
    backpack(b)
    weapon(b)
    return b


def sockets(cls):
    """Sockets (name, bone, offset in the bone's bind frame = model offset from the bone, identity bind rotation)."""
    g = motion.grip_frames(cls)
    out = []
    mz = np.asarray(motion.GRIPS[cls]['muzzle'], dtype=np.float64)
    out.append(('muzzle', 'weapon', mz))
    tx, ty = {'assault': (-0.066, 0.088), 'pyro': (-0.078, 0.1), 'cryo': (-0.07, 0.085), 'gunner': (-0.1, 0.11)}[cls]
    out.append(('torch', 'weapon', np.array([tx, ty, 0.385])))
    out.append(('eject', 'weapon', np.array([0.05, 0.1, 0.05])))
    for side in ('L', 'R'):
        off, q = g[side]
        m = SK.qmat(q)
        out.append((f'grip_{side}', 'weapon', off))
        out.append((f'grip_{side}_y', 'weapon', off + m[:, 1] * 0.1))
        out.append((f'grip_{side}_z', 'weapon', off + m[:, 2] * 0.1))
    # each hand's canonical frame at bind (y back of the hand, z wrist → knuckles): the app's grip IK lines it up
    # with the grip frames above
    for side in ('L', 'R'):
        m = SK.qmat(motion.hand_bind_q(side))
        out.append((f'hand_{side}_y', f'hand_{side}', m[:, 1] * 0.1))
        out.append((f'hand_{side}_z', f'hand_{side}', m[:, 2] * 0.1))
    out.append(('head_top', 'head', np.array([0.0, 0.26, 0.0])))
    out.append(('thrust', 'backpack', np.array([0.0, -0.13, -0.07])))
    return out
