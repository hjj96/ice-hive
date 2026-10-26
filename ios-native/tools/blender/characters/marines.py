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
from shapes import (ARMOUR, BRASS, DARK, GLASS, GLOW, HOT, LAMP, METAL, PAINT, SOLE, Part, R, S, T, bolt, cyl, frame,
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

CLASSES = ['assault', 'pyro', 'cryo', 'gunner']

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
        GLASS: ((22, 64, 92), 0.06, 0.0, 0.16, 3),    # the cryo's dome / canister: dark glass with a faint inner glow
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
        self.parts.append(Part(name, bone, mat, V, F, sharp_deg=sharp, blend=blend))
        if keep:
            self.done[name] = (np.asarray(V), F)
        return V, F

    def detail(self, VF, bone, mat=METAL):
        if self.hi and VF is not None:
            self.floaters.append((VF, bone, mat))

    def decal(self, VF, bone, value=1.0):
        if self.hi and VF is not None:
            self.decals.append((VF, bone, value))

    def surface(self, *names):
        return Surface(*[self.done[n] for n in names])

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
        surf = self.surface(*names)
        return conform(surf, frame_at(np.asarray(origin, dtype=np.float64), a_axis, b_axis, into), rect_outline(w, h, r, taper),
                       nu, nv, 0.0008, t)

    def bolts_on(self, names, pts, into, bone, r=0.007):
        if not self.hi:
            return
        surf = self.surface(*names)
        for p in pts:
            h, n = surf.hit(np.asarray(p, dtype=np.float64) - np.asarray(into) * 0.2, np.asarray(into, dtype=np.float64), 0.5)
            if h is not None:
                if np.dot(n, into) > 0:
                    n = -n
                self.floaters.append((bolt(h, n, r=r), bone, METAL))


def se_ring(a, b, y, n=12, e=3.6, cz=0.0, front=0.0, back=0.0):
    return ring(superellipse(a, b, n, e, 0.0, cz, front, back), y)


# ================================================================ shared body
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
    seams = (lambda p, n, a: n[2] > 0.55 and 1.33 < p[1] < 1.58, 0.012, 0.004)
    cu = b.sd(cu, 1, 3, 28.0, 0.55, seams=seams, boundary=0.6)
    b.add('cuirass', 'chest', ARMOUR, cu, sharp=60.0, keep=True)
    # pectoral plates, conformed to the cuirass: big slabs that give the chest its mass
    for s in (1.0, -1.0):
        pl = b.plate(['cuirass'], (s * 0.122, 1.47, 0.5), (1, 0, 0), (-s * 0.25, 1, 0.25), (0, 0, -1), 0.205, 0.17, 0.02, nu=2,
                     nv=2, r=0.14, taper=-0.18, gap=0.0055)
        b.add('pec', 'chest', ARMOUR, pl, sharp=55.0)
        b.decal(b.sticker(['cuirass'], (s * 0.15, 1.565, 0.5), (1, 0, 0), (0, 1, 0.2), (0, 0, -1), 0.05, 0.02), 'chest', 0.5)
    b.bolts_on(['cuirass'], [(s * x, y, 0.4) for s in (1, -1) for x, y in ((0.06, 1.38), (0.21, 1.43))], (0, 0, -1), 'chest')
    # under-collar glow strips (the class hue)
    for s in (1.0, -1.0):
        st = b.sticker(['cuirass'], (s * 0.165, 1.578, 0.5), (1, -0.35 * s, 0), (0, 1, 0.3), (0, 0, -1), 0.085, 0.012, t=0.004)
        b.add('chest_glow', 'chest', GLOW, st)
    # back plate (the backpack mounts on it)
    bp = b.plate(['cuirass'], (0, 1.45, -0.5), (1, 0, 0), (0, 1, 0), (0, 0, 1), 0.4, 0.27, 0.024, nu=3, nv=2, r=0.3)
    b.add('backplate', 'chest', METAL, bp, sharp=55.0)
    # collar / gorget, and a cowl rising behind the neck (frames the helmet from the game camera)
    col = lathe([(0.11, 1.598), (0.165, 1.606), (0.178, 1.632), (0.168, 1.662), (0.13, 1.678), (0.104, 1.672)], 12)
    b.add('collar', 'chest', METAL, col, sharp=60.0)
    cw = wrap(0.178, 0.158, 112.0, 248.0, 0.105, 0.022, nu=4, nv=1, bulge=0.006, y0=1.6)
    b.add('cowl', 'chest', ARMOUR, b.sd(cw, 1, 3, 50.0, 0.8), sharp=55.0)
    # abdomen band (spine2), ribbed waist (spine1) with its front plate
    ab = loft_cage([se_ring(0.176, 0.128, 1.17, cz=0.01), se_ring(0.194, 0.143, 1.23, cz=0.016, front=0.016),
                    se_ring(0.186, 0.137, 1.295, cz=0.012)], cap0=False, cap1=False)
    ab = b.sd(ab, 1, 3, 70.0, 0.0, seams=(lambda p, n, a: n[2] > 0.6, 0.01, 0.004), boundary=0.6)
    b.add('abdomen', 'spine2', ARMOUR, ab, sharp=60.0, keep=True)
    rib = lathe([(0.142, 1.03), (0.166, 1.045), (0.156, 1.072), (0.17, 1.1), (0.158, 1.128), (0.166, 1.156), (0.144, 1.19)], 12)
    b.add('waist', 'spine1', DARK, xform(rib, S(1.0, 1.0, 0.84)), sharp=70.0, keep=True)
    abp = b.plate(['waist'], (0, 1.11, 0.5), (1, 0, 0), (0, 1, 0), (0, 0, -1), 0.2, 0.11, 0.022, nu=2, nv=2, r=0.4)
    b.add('abplate', 'spine1', ARMOUR, abp, sharp=55.0)
    neck = lathe([(0.088, 1.6), (0.08, 1.64), (0.086, 1.67), (0.078, 1.7), (0.07, 1.735)], 10)
    b.add('neck', 'neck', DARK, neck, sharp=70.0)


def pelvis(b):
    belt = loft_cage([se_ring(0.214, 0.15, 0.935, cz=0.0), se_ring(0.232, 0.163, 0.995, cz=0.005, front=0.012),
                      se_ring(0.222, 0.156, 1.055, cz=0.0)], cap0=True, cap1=True)
    belt = b.sd(belt, 1, 3, 50.0, 0.9)
    b.add('belt', 'pelvis', DARK, belt, sharp=60.0, keep=True)
    bk = box_cage(0.12, 0.08, 0.04)
    b.add('buckle', 'pelvis', METAL, xform(b.sd(bk, 1, 2), T(0, 0.99, 0.18)), sharp=50.0)
    # codpiece: a curved shield
    cp = grid_cage(2, 2, lambda u, v: ((u - 0.5) * 0.17 * (1 - 0.35 * (1 - v)), 0.82 + 0.15 * v,
                                       0.185 + 0.02 * math.cos((u - 0.5) * 2.2) - 0.03 * (1 - v)))
    cp = b.sd(rimmed(*cp, 0.03, inner=(0, 0.9, 0)), 1, 3, 50.0, 0.8)
    b.add('codpiece', 'pelvis', ARMOUR, cp, sharp=55.0)
    # hip plates (outer) and the rear plate, curved round the pelvis
    for s in (1.0, -1.0):
        hp = wrap(0.258, 0.238, 42.0, 138.0, 0.19, 0.024, nu=2, nv=2, flare=0.014, y0=0.845)
        hp = (hp[0] * np.array([s, 1, 1]), hp[1] if s > 0 else [f[::-1] for f in hp[1]])
        hp = b.sd(hp, 1, 3, 50.0, 0.8)
        b.add('hip', 'pelvis', ARMOUR, hp, sharp=55.0)
    rp = wrap(0.222, 0.21, 145.0, 215.0, 0.16, 0.024, nu=2, nv=2, y0=0.855)
    b.add('rearplate', 'pelvis', ARMOUR, b.sd(rp, 1, 3, 50.0, 0.8), sharp=55.0)
    # belt pouches at the back hips
    for s in (1.0, -1.0):
        po = box_cage(0.075, 0.085, 0.055)
        po = deform(po, lambda p: np.array([p[0], p[1], p[2] + 0.012 * (1 - (2 * p[0] / 0.075) ** 2)]))
        M = mm(T(s * 0.165, 0.985, -0.128), R('Y', s * 142.0))
        b.add('pouch', 'pelvis', DARK, xform(b.sd(po, 1, 2, 50.0, 0.8), M), sharp=55.0)
    # tassets: front thigh plates hanging from the belt
    for s, bone in ((1.0, 'tasset_L'), (-1.0, 'tasset_R')):
        j = b.J(bone)
        ts = grid_cage(2, 2, lambda u, v, j=j: (j[0] + (u - 0.5) * 0.17 * (0.85 + 0.15 * v), j[1] - 0.2 + 0.2 * v,
                                                j[2] + 0.065 + 0.028 * math.cos((u - 0.5) * 2.4) + 0.022 * (1 - v)))
        ts = b.sd(rimmed(*ts, 0.026, inner=(j[0], j[1] - 0.1, j[2] - 0.1)), 1, 3, 50.0, 0.8)
        b.add('tasset', bone, PAINT if b.cls == 'gunner' else ARMOUR, ts, sharp=55.0)


def legs(b):
    for side, s in (('L', 1.0), ('R', -1.0)):
        hip, knee, ank, toe = b.J('thigh_' + side), b.J('shin_' + side), b.J('foot_' + side), b.J('toe_' + side)
        F = frame(knee, hip - knee, (0, 0, 1))
        und = lathe([(0.08, 0.0), (0.09, 0.18), (0.095, 0.36), (0.087, 0.42)], 8)
        b.add('thigh_suit', 'thigh_' + side, DARK, xform(und, F), sharp=70.0)
        # thigh armour wraps the front and the outside, down over the top of the knee pad
        a0, a1 = (-65.0, 135.0) if s > 0 else (-135.0, 65.0)
        tp = wrap(0.104, 0.132, a0, a1, 0.36, 0.026, nu=4, nv=2, bulge=0.018, y0=0.035)
        tp = b.sd(tp, 1, 3, 50.0, 0.85, seams=(lambda p, n, a: a > 0.004, 0.008, 0.003))
        b.add('thigh_plate', 'thigh_' + side, ARMOUR, xform(tp, F), sharp=55.0, keep=True)
        # knee pad (class paint): a big domed, pointed cap
        kp = box_cage(0.135, 0.155, 0.06, 1, 2, 1)
        kp = deform(kp, lambda p: np.array([p[0] * (1 - 0.3 * max(0, -p[1]) / 0.078), p[1],
                                            p[2] + 0.04 * (1 - (2 * p[0] / 0.135) ** 2) * (1 - (p[1] / 0.078) ** 2)]))
        kp = b.sd(kp, 1, 3, 55.0, 0.7)
        b.add('knee', 'shin_' + side, PAINT, xform(kp, T(knee[0], knee[1] - 0.008, knee[2] + 0.098)), sharp=55.0)
        # shin guard: front keel, flared at the ankle, reaching up behind the knee pad
        F2 = frame(ank, knee - ank, (0, 0, 1))
        sg = wrap(0.098, 0.118, -112.0, 112.0, 0.335, 0.026, nu=4, nv=2, ridge=0.02, flare=0.018, y0=0.045)
        sg = b.sd(sg, 1, 3, 50.0, 0.85, seams=(lambda p, n, a: a > 0.004, 0.008, 0.003))
        b.add('shin', 'shin_' + side, ARMOUR, xform(sg, F2), sharp=55.0, keep=True)
        cf = wrap(0.088, 0.098, 120.0, 240.0, 0.27, 0.022, nu=2, nv=1, y0=0.06)
        b.add('calf', 'shin_' + side, METAL, xform(b.sd(cf, 1, 2, 50.0, 0.8), F2), sharp=55.0)
        st = b.sticker(['shin'], ank + np.array([s * 0.05, 0.2, 0.3]), (0, 1, 0), (s, 0, 0), (0, 0, -1), 0.21, 0.018, t=0.004)
        b.add('shin_glow', 'shin_' + side, GLOW, st)
        b.decal(b.sticker(['shin'], ank + np.array([-s * 0.022, 0.32, 0.3]), (1, 0, 0), (0, 1, 0), (0, 0, -1), 0.055, 0.075), 'shin_' + side, 1.0)
        # boot (foot bone): a sculpted shell, sole; toe cap on the toe bone
        secs = []
        for z, w, top in ((-0.14, 0.066, 0.045), (-0.068, 0.08, 0.064), (0.06, 0.082, -0.0), (0.135, 0.076, -0.036)):
            yb, yt = 0.026 - ank[1], top
            pts = superellipse(w, 0.5 * (yt - yb), 8, 3.0)
            secs.append(np.array([(px, 0.5 * (yb + yt) + pz, z) for px, pz in pts]))
        bt = b.sd(loft_cage(secs), 1, 3, 55.0, 0.75)
        b.add('boot', 'foot_' + side, ARMOUR, xform(bt, T(ank[0], ank[1], ank[2])), sharp=55.0)
        cuff = lathe([(0.085, 0.07), (0.094, 0.095), (0.092, 0.13), (0.083, 0.145)], 10)
        b.add('cuff', 'foot_' + side, METAL, xform(cuff, T(ank[0], ank[1], ank[2] - 0.01)), sharp=70.0)
        so = box_cage(0.172, 0.03, 0.3, 1, 1, 2)
        b.add('sole', 'foot_' + side, SOLE, xform(b.sd(so, 0, 2, 50.0, 0.9), T(ank[0], 0.015, ank[2] + 0.0)), sharp=55.0)
        tc = box_cage(0.158, 0.078, 0.14, 1, 1, 2)
        tc = deform(tc, lambda p: np.array([p[0] * (1 - 0.2 * max(0, p[2]) / 0.07), p[1] - 0.25 * max(0, p[2]) * (p[1] + 0.039) / 0.07 * 0.5, p[2]]))
        b.add('toecap', 'toe_' + side, PAINT if b.cls == 'cryo' else ARMOUR, xform(b.sd(tc, 1, 3, 55.0, 0.75), T(toe[0], 0.05, toe[2] + 0.028)), sharp=55.0)
        ts = box_cage(0.168, 0.024, 0.14)
        b.add('toesole', 'toe_' + side, SOLE, xform(b.sd(ts, 0, 2, 50.0, 0.9), T(toe[0], 0.012, toe[2] + 0.032)), sharp=55.0)


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


def arms(b):
    c = b.cls
    for side, s in (('L', 1.0), ('R', -1.0)):
        sh, el, wr = b.J('upperarm_' + side), b.J('forearm_' + side), b.J('hand_' + side)
        out = np.array([s, 0.25, 0.0])
        F = frame(el, sh - el, out)
        ua = lathe([(0.072, -0.01), (0.08, 0.12), (0.084, 0.25), (0.078, 0.31)], 8)
        b.add('upperarm', 'upperarm_' + side, DARK, xform(ua, F), sharp=70.0)
        bp = wrap(0.089, 0.098, -118.0, 118.0, 0.2, 0.024, nu=4, nv=2, bulge=0.01, y0=0.068)
        b.add('bicep', 'upperarm_' + side, ARMOUR, xform(b.sd(bp, 1, 3, 50.0, 0.85), F), sharp=55.0)
        hub = lathe([(0.0, -0.085), (0.07, -0.07), (0.092, 0.0), (0.07, 0.07), (0.0, 0.085)], 6)
        b.add('hub', 'clav_' + side, METAL, xform(hub, mm(T(sh[0], sh[1], sh[2]), R('Z', 90))), sharp=70.0)  # (6 segs: under the pauldron)
        F2 = frame(wr, el - wr, out)
        bd = np.array([0.0, 0.0, -1.0]) + out * 0.35
        bd /= np.linalg.norm(bd)
        cop = lathe([(0.0, 0.0), (0.048, 0.009), (0.076, 0.04), (0.081, 0.07)], 10)
        b.add('elbow', 'forearm_' + side, METAL, xform(cop, frame(el + bd * 0.084, -bd, (0, 1, 0))), sharp=70.0)
        # gauntlets: big flared forearm armour in the class paint (they frame the weapon from the game camera)
        g = wrap(0.078, 0.09, -152.0, 152.0, 0.235, 0.024, nu=4, nv=2, bulge=0.01, flare=0.018, y0=0.02)
        g = b.sd(g, 1, 3, 50.0, 0.85, seams=(lambda p, n, a: a > 0.003, 0.007, 0.003))
        b.add('gauntlet', 'forearm_' + side, PAINT, xform(g, F2), sharp=55.0, keep=True)
        st = b.sticker(['gauntlet'], wr + (el - wr) * 0.45 + out * 0.4, (el - wr), np.cross(el - wr, out), -out, 0.15, 0.013, t=0.004)
        if st is not None:
            b.add('wrist_glow', 'forearm_' + side, GLOW, st)
        if side == 'L':
            wu = box_cage(0.06, 0.02, 0.075)
            wu = xform(b.sd(wu, 1, 2, 50.0, 0.8), mm(F2, T(-0.075, 0.13, 0.0), R('Z', -90)))
            b.add('wrist_unit', 'forearm_' + side, METAL, wu, sharp=55.0)
        Hq = motion.hand_bind_q(side)
        HM = np.eye(4)
        HM[:3, :3] = SK.qmat(Hq)
        HM[:3, 3] = wr
        HM = HM @ S(SK.HAND_SCALE)
        for m, mat in hand_canonical(b, side):
            b.add('hand', 'hand_' + side, mat, xform(m, HM), sharp=55.0)


# ================================================================ helmets
def helmet(b):
    c = b.cls
    if c == 'assault':
        rings = [se_ring(0.086, 0.11, 1.665, e=3.0, n=10, cz=0.03, front=0.04), se_ring(0.114, 0.138, 1.705, e=3.0, n=10, cz=0.03, front=0.042),
                 se_ring(0.134, 0.15, 1.762, e=3.0, n=10, cz=0.02, front=0.016), se_ring(0.14, 0.154, 1.815, e=3.0, n=10, cz=0.012, front=0.03),
                 se_ring(0.124, 0.142, 1.876, e=3.0, n=10, cz=0.0), se_ring(0.08, 0.098, 1.922, e=3.0, n=10, cz=-0.006)]
        hm = b.sd(loft_cage(rings, cap0=False, cap1=True), 1, 3, 30.0, 0.6, boundary=0.5)
        b.add('helmet', 'head', PAINT, hm, sharp=60.0, keep=True)
        # a gunmetal faceplate (wide at the brow, narrow at the chin) with the T-visor cut into it
        fp = b.plate(['helmet'], (0, 1.752, 0.5), (1, 0, 0), (0, 1, 0), (0, 0, -1), 0.17, 0.165, 0.012, nu=4, nv=2, r=0.3,
                     taper=-0.32, gap=0.004)
        b.add('faceplate', 'head', METAL, fp, sharp=55.0, keep=True)
        for (w, h, y, t, mat) in ((0.2, 0.042, 1.783, 0.003, DARK), (0.18, 0.027, 1.783, 0.006, GLOW),
                                  (0.052, 0.088, 1.735, 0.003, DARK), (0.034, 0.072, 1.735, 0.006, GLOW)):
            v = b.sticker(['faceplate'], (0, y, 0.4), (1, 0, 0), (0, 1, 0), (0, 0, -1), w, h, r=0.3, nu=3, nv=2, t=t)
            b.add('visor', 'head', mat, v)
        # crest fin (gunmetal over the red helmet: the assault's signature from the game camera)
        cr = box_cage(0.036, 0.055, 0.29, 1, 1, 3)
        cr = deform(cr, lambda p: np.array([p[0] * (1 - 0.5 * max(0, p[1]) / 0.0275), p[1] + 0.032 * math.cos(p[2] * 6) - 0.03 * max(0, -p[2]) * 3, p[2]]))
        b.add('crest', 'head', METAL, xform(b.sd(cr, 1, 3, 50.0, 0.7), T(0, 1.935, 0.0)), sharp=55.0)
        for s in (1.0, -1.0):
            em = lathe([(0.0, 0.0), (0.042, 0.0), (0.048, 0.018), (0.04, 0.034), (0.0, 0.036)], 8)
            b.add('ear', 'head', METAL, xform(em, mm(T(s * 0.13, 1.79, 0.005), R('Z', -s * 90))), sharp=70.0)
        b.add('lamp_house', 'head', METAL, xform(cyl(0.022, 0.055, 10), mm(T(-0.155, 1.795, 0.03), R('X', 90))), sharp=70.0)
        b.add('lamp', 'head', LAMP, xform(cyl(0.017, 0.006, 10), mm(T(-0.155, 1.795, 0.088), R('X', 90))))
        for s in (1.0, -1.0):
            b.decal(b.sticker(['helmet'], (s * 0.1, 1.9, 0.0), (0, 0, 1), (1, 0, 0), (-s * 0.6, -1, 0), 0.16, 0.02), 'head', 1.0)
    elif c == 'pyro':
        rings = [se_ring(0.112, 0.118, 1.665, e=2.0, n=10, cz=0.02), se_ring(0.138, 0.15, 1.72, e=2.0, n=10, cz=0.025, front=0.01),
                 se_ring(0.145, 0.158, 1.79, e=2.0, n=10, cz=0.02), se_ring(0.135, 0.148, 1.86, e=2.0, n=10, cz=0.012),
                 se_ring(0.095, 0.106, 1.912, e=2.0, n=10, cz=0.004), se_ring(0.04, 0.045, 1.935, e=2.0, n=10)]
        hm = b.sd(loft_cage(rings, cap0=False, cap1=True), 1, 3, 70.0, 0.0, boundary=0.5)
        b.add('helmet', 'head', PAINT, hm, sharp=70.0, keep=True)
        band = lathe([(0.15, 1.81), (0.158, 1.818), (0.157, 1.835), (0.149, 1.842)], 18, 205, 515)
        b.add('band', 'head', METAL, xform(band, T(0, 0, 0.02)), sharp=70.0)
        sn = box_cage(0.11, 0.075, 0.07, 2, 1, 1)
        sn = deform(sn, lambda p: np.array([p[0] * (1 - 0.25 * (p[2] + 0.035) / 0.07), p[1], p[2]]))
        b.add('snout', 'head', METAL, xform(b.sd(sn, 1, 3, 50.0, 0.7), T(0, 1.705, 0.165)), sharp=55.0)
        b.detail(slots(np.array([0, 1.705, 0.2]), (0, 0, 1), (1, 0, 0), 4, 0.04, 0.008, 0.006), 'head')
        for s in (1.0, -1.0):
            fl = lathe([(0.0, 0.0), (0.03, 0.0), (0.034, 0.014), (0.034, 0.048), (0.0, 0.058)], 10)
            b.add('filter', 'head', BRASS, xform(fl, mm(T(s * 0.078, 1.69, 0.18), R('Z', -s * 55), R('X', 20))), sharp=70.0)
            rim = lathe([(0.032, -0.005), (0.052, -0.005), (0.054, 0.022), (0.043, 0.03)], 8)
            b.add('goggle_rim', 'head', METAL, xform(rim, mm(T(s * 0.06, 1.795, 0.146), R('X', 90))), sharp=70.0)
            b.add('goggle', 'head', GLOW, xform(lathe([(0.0, 0.0), (0.042, 0.0), (0.041, 0.009), (0.0, 0.013)], 10), mm(T(s * 0.06, 1.795, 0.162), R('X', 90))))
        b.decal(b.sticker(['helmet'], (0, 1.9, 0.0), (0, 0, 1), (1, 0, 0), (0, -1, 0), 0.2, 0.03), 'head', 0.5)
    elif c == 'cryo':
        inner = lathe([(0.098, 1.665), (0.118, 1.69), (0.12, 1.735)], 14)
        b.add('helmet_base', 'head', PAINT, xform(inner, T(0, 0, 0.01)), sharp=70.0)
        prof = [(0.118, 1.72)] + [(0.154 * math.cos(math.radians(a)), 1.765 + 0.172 * math.sin(math.radians(a))) for a in (0, 18, 36, 54, 72, 84)] + [(0.0, 1.938)]
        dome = lathe(prof, 20)
        b.add('dome', 'head', GLASS, xform(dome, T(0, 0, 0.02)), sharp=80.0, keep=True)
        vb = b.sticker(['dome'], (0, 1.795, 0.5), (1, 0, 0), (0, 1, 0), (0, 0, -1), 0.24, 0.028, r=0.2, nu=6, nv=1, t=0.003)
        b.add('visor', 'head', GLOW, vb)
        ring_ = lathe([(0.112, 1.705), (0.158, 1.712), (0.163, 1.728), (0.158, 1.742), (0.12, 1.748)], 20)
        b.add('dome_ring', 'head', METAL, xform(ring_, T(0, 0, 0.02)), sharp=70.0)
        rg = lathe([(0.162, 1.731), (0.166, 1.735), (0.162, 1.739)], 20)
        b.add('ring_glow', 'head', GLOW, xform(rg, T(0, 0, 0.02)))
        bm_ = box_cage(0.13, 0.1, 0.07)
        b.add('helmet_pack', 'head', PAINT, xform(b.sd(bm_, 1, 3, 50.0, 0.7), T(0, 1.77, -0.155)), sharp=55.0)
        b.add('lamp_house', 'head', METAL, xform(cyl(0.02, 0.05, 10), mm(T(-0.145, 1.745, 0.04), R('X', 90))), sharp=70.0)
        b.add('lamp', 'head', LAMP, xform(cyl(0.016, 0.006, 10), mm(T(-0.145, 1.745, 0.093), R('X', 90))))
    else:  # gunner: squared bucket
        rings = [se_ring(0.128, 0.13, 1.665, e=3.4, cz=0.012), se_ring(0.15, 0.154, 1.7, e=3.4, cz=0.014),
                 se_ring(0.155, 0.158, 1.8, e=3.4, cz=0.014, front=0.01), se_ring(0.152, 0.154, 1.89, e=3.4, cz=0.012),
                 se_ring(0.13, 0.13, 1.925, e=3.4, cz=0.01)]
        hm = b.sd(loft_cage(rings, cap0=False, cap1=True), 1, 3, 50.0, 0.85, boundary=0.5)
        b.add('helmet', 'head', PAINT, hm, sharp=55.0, keep=True)
        br = b.plate(['helmet'], (0, 1.835, 0.5), (1, 0, 0), (0, 1, 0), (0, 0, -1), 0.25, 0.045, 0.016, r=0.2, nu=4, nv=1)
        b.add('brow', 'head', METAL, br, sharp=55.0)
        for (w, h, t, mat) in ((0.2, 0.04, 0.003, DARK), (0.18, 0.024, 0.006, GLOW)):
            b.add('visor', 'head', mat, b.sticker(['helmet'], (0, 1.792, 0.5), (1, 0, 0), (0, 1, 0), (0, 0, -1), w, h, r=0.2, nu=4, nv=1, t=t))
        gr = b.plate(['helmet'], (0, 1.715, 0.5), (1, 0, 0), (0, 1, 0), (0, 0, -1), 0.08, 0.075, 0.018, r=0.3, nu=2, nv=2)
        b.add('grille', 'head', METAL, gr, sharp=55.0)
        b.detail(slots(np.array([0, 1.715, 0.19]), (0, 0, 1), (0, 1, 0), 5, 0.055, 0.007, 0.006), 'head')
        b.add('lamp_house', 'head', METAL, xform(cyl(0.024, 0.055, 10), mm(T(-0.168, 1.82, 0.04), R('X', 90))), sharp=70.0)
        b.add('lamp', 'head', LAMP, xform(cyl(0.019, 0.006, 10), mm(T(-0.168, 1.82, 0.098), R('X', 90))))
        b.decal(b.sticker(['helmet'], (0, 1.9, 0.0), (0, 0, 1), (1, 0, 0), (0, -1, 0), 0.22, 0.03), 'head', 0.5)


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
            n = 2
            for k in range(n):
                th0 = cap_lo + 10.0 - (26.0 if c == 'assault' else 32.0) * k
                th1 = th0 - 30.0
                g = 1.05 + 0.05 * k
                L = dome_patch(cx, s, rx * g, ry * g, rz * g, 74.0, -74.0, th0, th1, 3, 1)
                b.add('pauldron_lame', bone, PAINT, b.sd(rimmed(*L, 0.02, inner=cx), 1, 3, 50.0, 0.85), sharp=55.0)
            gl = dome_patch(cx, s, rx * g + 0.002, ry * g + 0.002, rz * g + 0.002, 60.0, -60.0, th1 + 7.0, th1 + 3.5, 6, 1)
            b.add('pauldron_glow', bone, GLOW, thicken(*gl, -0.004))
        elif c == 'pyro':
            rim = dome_patch(cx, s, rx + 0.008, ry + 0.008, rz + 0.008, 76.0, -76.0, cap_lo + 8.0, cap_lo - 4.0, 4, 1)
            b.add('pauldron_rim', bone, METAL, b.sd(rimmed(*rim, 0.024, inner=cx), 1, 2, 50.0, 0.8), sharp=55.0)
        else:
            gl = dome_patch(cx, s, rx + 0.002, ry + 0.002, rz + 0.002, 62.0, -62.0, cap_lo + 9.0, cap_lo + 5.0, 6, 1)
            b.add('pauldron_glow', bone, GLOW, thicken(*gl, -0.005))
        b.decal(b.sticker(cap_surface, cx + np.array([s * 0.05, 0.3, 0.0]), (0, 0, 1), (s, 0, 0), (-s * 0.35, -1, 0), 0.11, 0.035), bone, 0.5)
        b.bolts_on(cap_surface, [cx + np.array([s * 0.03, 0.2, z]) for z in (-0.1, 0.1)], (0, -1, 0), bone)


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
        bx = box_cage(0.36, 0.34, 0.16, 2, 2, 1)
        bx = deform(bx, lambda p: np.array([p[0] * (1 - 0.12 * (p[1] + 0.17) / 0.34), p[1], p[2] - 0.024 * (p[1] + 0.17) / 0.34]))
        bx = b.sd(bx, 1, 3, 50.0, 0.85, seams=(lambda p, n, a: n[2] < -0.6, 0.012, 0.004))
        b.add('pack', bone, ARMOUR, xform(bx, T(0, 1.44, -0.296)), sharp=55.0)
        tp = box_cage(0.26, 0.056, 0.12)
        b.add('pack_top', bone, METAL, xform(b.sd(tp, 1, 2, 50.0, 0.8), T(0, 1.628, -0.3)), sharp=55.0)
        for s in (1.0, -1.0):
            nz = lathe([(0.06, 0.0), (0.067, 0.029), (0.058, 0.063), (0.051, 0.138)], 10, cap0=False, cap1=False)
            M = mm(T(s * 0.13, 1.31, -0.35), R('X', 165), R('Z', -s * 12))
            b.add('thruster', bone, METAL, xform(nz, M), sharp=70.0)
            b.add('thruster_glow', bone, GLOW, xform(lathe([(0.0, 0.0), (0.046, 0.0), (0.046, 0.006), (0.0, 0.006)], 8), mm(M, T(0, 0.022, 0))))
        b.detail(slots(np.array([0, 1.46, -0.378]), (0, 0, -1), (1, 0, 0), 7, 0.13, 0.013, 0.012), bone)
        b.add('pack_glow', bone, GLOW, xform(box_cage(0.24, 0.013, 0.008), T(0, 1.58, -0.378)))
        a = b.J('antenna')
        b.add('antenna_base', 'antenna', METAL, xform(cyl(0.02, 0.045, 8), T(a[0], a[1] - 0.045, a[2])), sharp=70.0)
        b.add('antenna', 'antenna', METAL, xform(cyl(0.007, 0.44, 6, r1=0.004), T(a[0], a[1], a[2])), sharp=70.0)
        b.add('antenna_tip', 'antenna', GLOW, xform(cyl(0.013, 0.022, 8), T(a[0], a[1] + 0.44, a[2])))
    elif c == 'pyro':
        tz = -0.318
        for s in (1.0, -1.0):
            tk = lathe([(0.0, 1.18), (0.056, 1.184), (0.081, 1.212), (0.09, 1.256), (0.09, 1.6), (0.081, 1.645), (0.052, 1.674), (0.0, 1.68)], 9)
            b.add('tank', bone, PAINT, xform(tk, T(s * 0.108, 0, tz)), sharp=70.0, keep=(s > 0))
            for y in (1.29, 1.53):
                band = lathe([(0.091, y), (0.098, y + 0.006), (0.098, y + 0.032), (0.091, y + 0.038)], 8)
                b.add('tank_band', bone, METAL, xform(band, T(s * 0.108, 0, tz)), sharp=70.0)
            b.decal(xform(box_cage(0.068, 0.11, 0.002), T(s * 0.108, 1.41, tz - 0.0905)), bone, 0.5)
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
def weapon(b):
    """Each class's weapon, oversized for the game camera (≈ 1.35× a realistic cross-section), the bore raised over the
    gauntleted fist; muzzles stay where the core spawns the bolts (≈ 0.95 m ahead of the feet in the stance)."""
    c = b.cls
    g = np.asarray(SK.WEAPON[c]['grip'], dtype=np.float64)
    G = T(*g)
    bone = 'weapon'

    def add(name, mat, VF, bone_=bone, sharp=55.0):
        b.add(name, bone_, mat, xform(VF, G), sharp=sharp)

    def det(VF):
        b.detail(xform(VF, G), bone)

    def blk(sx, sy, sz, pos, n=(1, 1, 1), lo=1, hi=3, crease=0.85, fn=None, seams=None):
        VF = box_cage(sx, sy, sz, *n)
        if fn is not None:
            VF = deform(VF, fn)
        return xform(b.sd(VF, lo, hi, 50.0, crease, seams=seams), T(*pos))

    # pistol grip under the gun hand, tilted back
    add('grip', DARK, xform(blk(0.04, 0.12, 0.056, (0, -0.006, 0), lo=1, hi=2, crease=0.6), R('X', -15)))
    sup = np.asarray(motion.GRIPS[c]['sup'])
    if c == 'assault':
        by = 0.088
        add('receiver', METAL, blk(0.094, 0.125, 0.44, (0, by, 0.02), (1, 2, 3),
                                   fn=lambda p: np.array([p[0] * (1 - 0.15 * max(0, p[1]) / 0.0625), p[1], p[2]]),
                                   seams=(lambda p, n, a: abs(n[0]) > 0.8, 0.008, 0.003)))
        add('shroud', ARMOUR, blk(0.086, 0.094, 0.33, (0, by + 0.004, 0.38), (1, 1, 3),
                                  fn=lambda p: np.array([p[0] * (1 - 0.1 * (p[2] + 0.165) / 0.33), p[1] * (1 - 0.15 * (p[2] + 0.165) / 0.33), p[2]])))
        det(slots(np.array([0.043, by + 0.004, 0.38]), (1, 0, 0), (0, 0, 1), 7, 0.045, 0.012, 0.024))
        det(slots(np.array([-0.043, by + 0.004, 0.38]), (-1, 0, 0), (0, 0, 1), 7, 0.045, 0.012, 0.024))
        add('barrel', HOT, xform(cyl(0.021, 0.13, 12), mm(T(0, by, 0.53), R('X', 90))), sharp=70.0)
        add('muzzle', HOT, blk(0.062, 0.062, 0.085, (0, by, 0.668), (1, 1, 2), lo=1, hi=2))
        det(slots(np.array([0.031, by, 0.668]), (1, 0, 0), (0, 0, 1), 3, 0.04, 0.01, 0.01))
        det(slots(np.array([-0.031, by, 0.668]), (-1, 0, 0), (0, 0, 1), 3, 0.04, 0.01, 0.01))
        add('launcher', METAL, xform(cyl(0.03, 0.24, 12), mm(T(0, 0.016, 0.3), R('X', 90))), sharp=70.0)
        add('launcher_cap', DARK, xform(cyl(0.024, 0.012, 12), mm(T(0, 0.016, 0.54), R('X', 90))), sharp=70.0)
        add('stock', ARMOUR, blk(0.064, 0.125, 0.2, (0, 0.066, -0.28), (1, 2, 2),
                                 fn=lambda p: np.array([p[0], p[1] - 0.4 * max(0, -p[2] - 0.02) * (p[1] + 0.06), p[2]])))
        add('mag', METAL, xform(blk(0.05, 0.16, 0.08, (0, -0.07, 0), (1, 2, 1), lo=1, hi=2,
                                    fn=lambda p: np.array([p[0], p[1], p[2] + 0.12 * (p[1] + 0.08) ** 2])), mm(T(0, 0.03, 0.11), R('X', 10))))
        add('optic', METAL, blk(0.05, 0.056, 0.14, (0, by + 0.088, 0.08), (1, 1, 2), lo=1, hi=2))
        add('optic_lens', GLOW, xform(cyl(0.017, 0.004, 12), mm(T(0, by + 0.09, 0.151), R('X', 90))))
        for s in (1.0, -1.0):
            add('cell_glow', GLOW, blk(0.006, 0.016, 0.3, (s * 0.047, by + 0.012, 0.14), lo=0, hi=0))
        add('foregrip', DARK, xform(blk(0.036, 0.11, 0.042, (0, -0.012, 0), lo=1, hi=2, crease=0.6), mm(T(*sup), R('X', 6))))
        add('fg_mount', METAL, blk(0.066, 0.036, 0.05, (sup[0] + 0.022, 0.036, sup[2]), lo=1, hi=2))
    elif c == 'pyro':
        by = 0.088
        body = lathe([(0.0, -0.14), (0.056, -0.14), (0.07, -0.11), (0.07, 0.42), (0.058, 0.45), (0.0, 0.45)], 12)
        add('body', METAL, xform(body, mm(T(0, by, 0), R('X', 90))), sharp=70.0)
        for z in (0.465, 0.515, 0.565):
            fin = lathe([(0.05, 0.0), (0.09, 0.004), (0.09, 0.018), (0.05, 0.022)], 8)
            add('fin', METAL, xform(fin, mm(T(0, by, z), R('X', 90))), sharp=70.0)
        nz = lathe([(0.04, 0.0), (0.044, 0.08), (0.06, 0.15), (0.072, 0.2), (0.062, 0.208), (0.052, 0.18), (0.038, 0.1),
                    (0.033, 0.0)], 16, cap0=False, cap1=False)
        add('nozzle', HOT, xform(nz, mm(T(0, by, 0.55), R('X', 90))), sharp=70.0)
        add('nozzle_glow', GLOW, xform(lathe([(0.0, 0.0), (0.038, 0.0), (0.038, 0.006), (0.0, 0.006)], 12), mm(T(0, by, 0.718), R('X', 90))))
        add('igniter', BRASS, blk(0.028, 0.028, 0.075, (0.0, by - 0.062, 0.725), lo=1, hi=2))
        add('pilot', LAMP, xform(cyl(0.009, 0.012, 8), mm(T(0.0, by - 0.056, 0.765), R('X', 90))))
        can = lathe([(0.0, 0.0), (0.044, 0.0), (0.05, 0.022), (0.05, 0.28), (0.044, 0.3), (0.0, 0.3)], 12)
        add('canister', PAINT, xform(can, mm(T(0, -0.014, 0.035), R('X', 90))), sharp=70.0)
        add('handle', DARK, xform(blk(0.036, 0.11, 0.042, (0, -0.006, 0), lo=1, hi=2, crease=0.6), mm(T(*sup), R('X', -10))))
        add('handle_mount', METAL, blk(0.05, 0.045, 0.055, (sup[0] + 0.035, sup[1] + 0.05, sup[2]), lo=1, hi=2))
        det(slots(np.array([0.07, by, 0.2]), (1, 0, 0), (0, 0, 1), 6, 0.05, 0.01, 0.022))
        add('strip', GLOW, blk(0.006, 0.012, 0.22, (0.069, by + 0.026, 0.2), lo=0, hi=0))
    elif c == 'cryo':
        by = 0.08
        add('body', ARMOUR, blk(0.11, 0.13, 0.46, (0, by - 0.012, 0.07), (1, 2, 3),
                                fn=lambda p: np.array([p[0] * (1 - 0.12 * max(0, p[1]) / 0.065), p[1], p[2]]),
                                seams=(lambda p, n, a: abs(n[0]) > 0.8, 0.01, 0.003)))
        add('barrel', HOT, xform(cyl(0.03, 0.42, 14), mm(T(0, by, 0.29), R('X', 90))), sharp=70.0)
        for z in (0.48, 0.56, 0.64):
            coil = lathe([(0.04, -0.011), (0.066, -0.011), (0.075, 0.0), (0.066, 0.011), (0.04, 0.011)], 12)
            b.add('coil', 'weapon_aux', GLOW, xform(coil, mm(G, T(0, by, z), R('X', 90))))
        add('emitter', HOT, xform(lathe([(0.0, 0.0), (0.042, 0.0), (0.048, 0.034), (0.03, 0.058), (0.0, 0.058)], 12), mm(T(0, by, 0.7), R('X', 90))), sharp=70.0)
        can = lathe([(0.0, 0.0), (0.036, 0.0), (0.04, 0.022), (0.04, 0.22), (0.036, 0.24), (0.0, 0.24)], 12)
        add('canister', GLASS, xform(can, mm(T(0, by + 0.083, -0.03), R('X', 90))), sharp=70.0)
        add('can_glow', GLOW, blk(0.009, 0.013, 0.18, (0.0, by + 0.124, 0.09), lo=0, hi=0))
        for z in (0.05, 0.12, 0.19):
            add('fin', METAL, blk(0.15, 0.085, 0.014, (0, by - 0.01, z), lo=1, hi=2))
        add('foregrip', DARK, xform(blk(0.036, 0.11, 0.042, (0, -0.012, 0), lo=1, hi=2, crease=0.6), T(*sup)))
        add('fg_mount', METAL, blk(0.056, 0.036, 0.05, (sup[0] + 0.022, 0.032, sup[2]), lo=1, hi=2))
        add('stock', ARMOUR, blk(0.056, 0.1, 0.15, (0, by - 0.02, -0.24), (1, 1, 2), lo=1, hi=3))
    else:  # gunner: rotary cannon
        by = 0.1
        add('housing', METAL, blk(0.16, 0.175, 0.46, (-0.01, by, 0.1), (1, 2, 3),
                                  fn=lambda p: np.array([p[0], p[1] * (1 - 0.1 * (p[2] + 0.23) / 0.46), p[2]]),
                                  seams=(lambda p, n, a: abs(n[0]) > 0.8, 0.012, 0.004)))
        det(slots(np.array([0.07, by, 0.1]), (1, 0, 0), (0, 0, 1), 8, 0.1, 0.012, 0.024))
        add('status', GLOW, blk(0.006, 0.016, 0.2, (0.071, by + 0.042, 0.06), lo=0, hi=0))
        aux = np.asarray(SK.WEAPON[c]['aux']) - g
        for k in range(6):
            a = 2 * math.pi * k / 6
            bx, by_ = aux[0] + 0.05 * math.cos(a), aux[1] + 0.05 * math.sin(a)
            b.add('barrel', 'weapon_aux', HOT, xform(cyl(0.017, 0.56, 8), mm(G, T(bx, by_, 0.31), R('X', 90))), sharp=70.0)
        for z in (0.33, 0.57, 0.81):
            cl = lathe([(0.0, 0.0), (0.075, 0.0), (0.079, 0.014), (0.075, 0.028), (0.0, 0.028)], 10)
            b.add('clamp', 'weapon_aux', METAL, xform(cl, mm(G, T(aux[0], aux[1], z), R('X', 90))), sharp=70.0)
        b.add('spindle', 'weapon_aux', DARK, xform(cyl(0.026, 0.53, 8), mm(G, T(aux[0], aux[1], 0.31), R('X', 90))), sharp=70.0)
        mz = lathe([(0.06, 0.0), (0.079, 0.0), (0.082, 0.018), (0.079, 0.034), (0.06, 0.034)], 14, cap0=False, cap1=False)
        b.add('muzzle_ring', 'weapon_aux', HOT, xform(mz, mm(G, T(aux[0], aux[1], 0.84), R('X', 90))), sharp=70.0)
        add('handle', DARK, xform(cyl(0.019, 0.18, 10), mm(T(sup[0], sup[1], sup[2] - 0.09), R('X', 90))), sharp=70.0)
        for z in (-0.075, 0.075):
            add('handle_post', METAL, blk(0.028, 0.075, 0.028, (sup[0], sup[1] - 0.04, sup[2] + z), lo=1, hi=2))
        add('feed', METAL, blk(0.06, 0.075, 0.095, (0.088, by, 0.05), lo=1, hi=2))
        add('rear', METAL, blk(0.06, 0.13, 0.11, (0, by, -0.135), (1, 1, 1), lo=1, hi=2))
    tx, ty = {'assault': (-0.066, 0.088), 'pyro': (-0.078, 0.1), 'cryo': (-0.07, 0.085), 'gunner': (-0.1, 0.11)}[c]
    add('torch', METAL, xform(cyl(0.026, 0.075, 12), mm(T(tx, ty, 0.3), R('X', 90))), sharp=70.0)
    add('torch_lens', LAMP, xform(cyl(0.021, 0.005, 12), mm(T(tx, ty, 0.375), R('X', 90))))


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
