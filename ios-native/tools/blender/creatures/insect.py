"""Shared body plan of the hive's insects (WP3 «Рой»): skeleton helpers, the three-segment leg with analytic IK / FK,
the tripod gait, the clip state, glands and carapace plates. Pure numpy (no bpy): build.py turns a creature
definition (runner.py, spitter.py, brute.py, boomer.py) into a rigged, keyed Blender scene and bakes it into IHV1.

Blender coordinates: X side (+X = right side, s = +1), Y forward (nose +Y), Z up, metres, origin on the ground under
the body centre. Every creature has a `root` bone (whole-body motion: lunge, flip) and a `thorax` bone that carries
the legs; leg bones are named `leg.<F|M|B>.<L|R>.<femur|tibia|tarsus>` and posed by IK in thorax space.

Vertex flags (IHV1 rigid vertex material.w): bit0 gland · bit1 eye · bit2 carapace edge · bit3 socket point ·
bit4 SAC (translucent acid / gas sac: Swarm.metal lights it from inside) — bit4 is creature content, documented here
and in SwarmTypes.h.
Socket flags (IHV1 socket record): bit0 GLINT (the gland is also drawn as a glint sprite, Swarm.metal
vs_swarm_glint), bit1 hot (pink-white core) else dim (red), bits 8–15 the gland radius in mm, bits 16–23 the glint
intensity × 100; non-gland sockets (mouth, core, sac, spit) carry 0.
"""
import math

import numpy as np

from geo import Part, cone, ellipsoid, hex2rgb, octa, shell_plate, smoothstep, tube

FPS = 30
SIDES = (-1, 1)                     # -1 = L (-X), +1 = R (+X)
SN = {-1: 'L', 1: 'R'}
LEG_ID = ('F', 'M', 'B')            # front, middle, back

F_GLAND, F_EYE, F_EDGE, F_SOCKET, F_SAC = 1, 2, 4, 8, 16
S_GLINT, S_HOT = 1, 2
D2R = math.pi / 180
TWO = 2 * math.pi


def socket_flags(glint, hot, radius, intensity):
    return ((S_GLINT if glint else 0) | (S_HOT if hot else 0) | (int(round(min(255, radius * 1000))) << 8)
            | (int(round(min(255, intensity * 100))) << 16))


def _n(v):
    v = np.asarray(v, dtype=np.float64)
    return v / np.linalg.norm(v)


def mat(x, y, z, o):
    M = np.eye(4)
    M[:3, 0], M[:3, 1], M[:3, 2], M[:3, 3] = x, y, z, o
    return M


def bone_frame(head, tail, zhint=(0, 0, 1)):
    y = _n(np.asarray(tail, float) - np.asarray(head, float))
    x = np.cross(y, zhint)
    if np.linalg.norm(x) < 1e-6:
        x = np.cross(y, (0, 1, 0))
    x = _n(x)
    z = np.cross(x, y)
    return mat(x, y, z, head)


def rx(a):
    c, s = math.cos(a), math.sin(a)
    M = np.eye(4); M[1, 1], M[1, 2], M[2, 1], M[2, 2] = c, -s, s, c; return M


def ry(a):
    c, s = math.cos(a), math.sin(a)
    M = np.eye(4); M[0, 0], M[0, 2], M[2, 0], M[2, 2] = c, s, -s, c; return M


def rz(a):
    c, s = math.cos(a), math.sin(a)
    M = np.eye(4); M[0, 0], M[0, 1], M[1, 0], M[1, 1] = c, -s, s, c; return M


def tr(x, y, z):
    M = np.eye(4); M[:3, 3] = (x, y, z); return M


def sc3(x, y, z):
    M = np.eye(4); M[0, 0], M[1, 1], M[2, 2] = x, y, z; return M


def bell(x, c, w):
    return math.exp(-((x - c) / w) ** 2)


# ------------------------------------------------------------------ legs: rest layout + analytic IK / FK
class Leg:
    """Three-segment insect leg in BODY (thorax-rest) space: hip H, femur L1 up/out, tibia L2 down, tarsus L3 at the
    fixed angle beta off vertical onto the ground. ik(foot) -> (psi, phi1, phi2, phi3); fk -> joints."""
    def __init__(self, i, s, C, H, F0, L, beta=25.0, tripod=None, fore=False):
        self.i, self.s = i, s
        self.name = f'leg.{LEG_ID[i]}.{SN[s]}'
        self.C = np.asarray(C, float)          # coxa base on the body (geometry only)
        self.H = np.asarray(H, float)          # hip joint
        self.F0 = np.asarray(F0, float)        # rest foot on the ground
        self.L = tuple(L)
        self.beta = math.radians(beta)
        self.fore = fore                       # a crusher forelimb (brute): thicker, club claw
        self.tripod = tripod if tripod is not None else (0 if (i, s) in ((0, -1), (1, 1), (2, -1)) else 1)
        self.rest = self.ik(self.F0)

    def ik(self, F, beta=None):
        beta = self.beta if beta is None else beta
        L1, L2, L3 = self.L
        d = F - self.H
        psi = math.atan2(d[1], d[0])
        fu, fw = math.hypot(d[0], d[1]), d[2]
        phi3 = -(math.pi / 2 - beta)
        au, aw = fu - L3 * math.cos(phi3), fw - L3 * math.sin(phi3)
        r = math.hypot(au, aw)
        rmax = (L1 + L2) * 0.999
        err = max(0.0, r - rmax)
        r = min(max(r, abs(L1 - L2) + 1e-3), rmax)
        base = math.atan2(aw, au)
        phi1 = base + math.acos(max(-1, min(1, (L1 * L1 + r * r - L2 * L2) / (2 * L1 * r))))
        ku, kw = L1 * math.cos(phi1), L1 * math.sin(phi1)
        au2, aw2 = r * math.cos(base), r * math.sin(base)
        phi2 = math.atan2(aw2 - kw, au2 - ku)
        return np.array([psi, phi1, phi2, phi3]), err

    def fk(self, p):
        psi, p1, p2, p3 = p
        L1, L2, L3 = self.L
        d = np.array([math.cos(psi), math.sin(psi), 0.0])
        z = np.array([0, 0, 1.0])
        K = self.H + L1 * (math.cos(p1) * d + math.sin(p1) * z)
        A = K + L2 * (math.cos(p2) * d + math.sin(p2) * z)
        F = A + L3 * (math.cos(p3) * d + math.sin(p3) * z)
        n = np.cross(z, d)
        return self.H, K, A, F, n

    def frames(self, p):
        H, K, A, F, n = self.fk(p)
        out = []
        for a, b in ((H, K), (K, A), (A, F)):
            y = _n(b - a)
            out.append(mat(n, y, np.cross(n, y), a))
        return out

    def tuck_params(self):
        """folded like a jackknife against the body side (while the bug rolls over)"""
        return np.array([self.rest[0][0], math.radians(72), math.radians(-112), math.radians(-62)])

    def dead_params(self):
        """curled up toward the belly (a corpse on its back: legs folded over the underside)"""
        r = self.rest[0].copy()
        fwd = (0.30, 0.0, -0.30)[self.i]
        return np.array([r[0] + self.s * fwd, math.radians(-30), math.radians(-150), math.radians(118)])

    def crumple_params(self):
        """buckled under the body (a corpse lying on its belly): femur flat out, tibia folded back under"""
        r = self.rest[0].copy()
        return np.array([r[0] + self.s * (0.25, 0.05, -0.2)[self.i], math.radians(4), math.radians(-128), math.radians(-150)])


def skeleton_legs(B, legs, parent='thorax'):
    """append femur / tibia / tarsus bones of every leg (rest = the leg's rest IK pose), parented to `parent`."""
    for lg in legs:
        fr = lg.frames(lg.rest[0])
        H, K, A, F, n = lg.fk(lg.rest[0])
        for nm, M, (a, b), par in zip(('femur', 'tibia', 'tarsus'), fr, ((H, K), (K, A), (A, F)),
                                      (parent, lg.name + '.femur', lg.name + '.tibia')):
            B.append((f'{lg.name}.{nm}', par, M, float(np.linalg.norm(b - a))))


# ------------------------------------------------------------------ the clip state
class State:
    """Local (basis) transforms for the procedural bones + leg drives for one frame."""
    def __init__(self):
        self.basis = {}          # bone -> 4x4 basis (in the bone's own rest frame)
        self.feet = {}           # leg name -> ('ik', target model space) | ('p', params) | ('mix2', target, pa, wa, pb, wb)
        self.glow = dict(gland=1.0, pulse=0.0, wave=0.0, eye=1.0)   # keyed as rig custom props glow_*

    def set(self, bone, M):
        self.basis[bone] = M


def gait_foot(tau, lg, duty, stroke, h):
    """tripod gait: foot target in model space at loop phase tau (0..1); planted (z = 0) for `duty` of the loop and
    moving back at exactly stroke / duty per loop — the clip's stride, so a phase driven by distance plants the feet."""
    p = (tau + 0.5 * lg.tripod) % 1.0
    if p < duty:
        y = stroke / 2 - stroke * (p / duty)
        z = 0.0
    else:
        s = (p - duty) / (1 - duty)
        y = -stroke / 2 + stroke * smoothstep(0, 1, s)
        z = h * math.sin(math.pi * s) * (1.0 + 0.3 * math.sin(math.pi * s))
    return lg.F0 + np.array([lg.s * (-0.03 if z > 0 else 0.0) * min(1, z / max(h, 1e-6)), y, z])


def leg_body_targets(lg, cmd, Binv):
    """Resolve a leg drive to body-space params; returns (params, ik_error)."""
    if cmd[0] == 'ik':
        T = Binv @ np.append(cmd[1], 1.0)
        return lg.ik(T[:3])
    if cmd[0] == 'p':
        return cmd[1], 0.0
    T = Binv @ np.append(cmd[1], 1.0)
    p0, e = lg.ik(T[:3])
    if cmd[0] == 'mix2':
        pa = blend(p0, cmd[2], cmd[3])
        return blend(pa, cmd[4], cmd[5]), e * (1 - cmd[3])
    w = cmd[3]
    return blend(p0, cmd[2], w), e * (1 - w)


def blend(p0, p1, w):
    p1 = p1.copy()
    p1[0] = p0[0] + (p1[0] - p0[0] + math.pi) % (2 * math.pi) - math.pi
    return p0 * (1 - w) + p1 * w


def roll_lift(rho, cz, ea, eb, flip):
    """height the root must rise so a body of elliptic cross-section (centre height cz, half width ea, half height eb)
    rolled by rho about its long axis rests on the ground instead of sinking into it."""
    low = cz * math.cos(rho) - math.sqrt((ea * math.sin(rho)) ** 2 + (eb * math.cos(rho)) ** 2)
    return max(0.0, -low - 0.008 * flip)


# ------------------------------------------------------------------ parts
def col_ramp(n, c0, c1, t):
    a, b = hex2rgb(c0), hex2rgb(c1)
    t = np.clip(np.asarray(t, float), 0, 1)[:, None]
    return a * (1 - t) + b * t


def plate(name, bone, nu, nv, pal, rough=0.34, **kw):
    """Arched carapace plate (geo.shell_plate) coloured dark in the middle, paler toward the rim, with a darker keel;
    the inner surface takes the body's core colour."""
    V, F = shell_plate(nu=nu, nv=nv, **kw)
    n = (nu + 1) * (nv + 1)
    u = np.tile(np.linspace(-1, 1, nu + 1), nv + 1)
    v = np.repeat(np.linspace(0, 1, nv + 1), nu + 1)
    u, v = np.concatenate([u, u]), np.concatenate([v, v])
    inner = np.concatenate([np.zeros(n), np.ones(n)])
    edge = np.clip(np.maximum((np.abs(u) - 0.55) / 0.45, (v - 0.55) / 0.45), 0, 1) ** 1.5
    keel = np.clip(1 - np.abs(u) * 4, 0, 1) * (1 - inner)
    col = col_ramp(len(V), pal['plate'], pal['edge'], edge * (1 - inner) * 0.85)
    col = col * (1 - keel[:, None] * 0.35) + hex2rgb(pal['keel']) * keel[:, None] * 0.35
    col = np.where(inner[:, None] > 0, hex2rgb(pal['core']), col)
    return Part(name, V, F, bone, pal['plate'], rough=rough, smooth=True, sharp_deg=40, vcolor=col, flags=F_EDGE)


def gland(name, bone, c, r, pal, hot=True, red=False, glow=1.0, sz=0.75, glint=True, intensity=1.0):
    """an octahedral pore with a hot core on its +z apex; its centre is a socket (glint sprite when `glint`)."""
    V, F = octa(c, r, sz)
    col = np.tile(hex2rgb(pal['gland_red'] if red else pal['gland']), (len(V), 1))
    if hot:
        col[-2] = hex2rgb(pal['gland_hot'])
    sf = socket_flags(glint, hot and not red, r, intensity)
    return Part(name, V, F, bone, pal['gland'], glow=glow, rough=0.4, smooth=True, sharp_deg=180, vcolor=col,
                flags=F_GLAND, gland_centers=[(np.asarray(c, float), sf)])


def eye(name, bone, c, r, pal, glow=0.75):
    return Part(name, *octa(c, r), bone, pal['eye'], glow=glow, rough=0.2, flags=F_EYE)


def leg_parts(lg, lod, pal, thick=1.0, claw=None):
    """LOD0: coxa, bowed femur, knee, tibia with spurs, ankle, hooked tarsus. LOD1: three 3-sided prisms.
    LOD2: three open 3-sided prisms (15 triangles a leg). The coxa rides on the thorax (no bone of its own)."""
    P = []
    p = lg.rest[0]
    H, K, A, F, n = lg.fk(p)
    k = thick
    if lod == 0:
        P.append(Part(lg.name + '.coxa', *tube([lg.C, (lg.C + lg.H) / 2 + [0, 0, 0.01], lg.H], [0.042 * k, 0.044 * k, 0.036 * k], 6),
                      'thorax', pal['joint'], rough=0.45))
        mid = (H + K) / 2 + np.cross(n, _n(K - H)) * -0.018 * k
        path = [H, H + (mid - H) * 0.5, mid, K]
        V, Fc = tube(path, [0.030 * k, 0.040 * k, 0.041 * k, 0.028 * k], 6, flat=0.82, up=n)
        t = np.repeat(np.linspace(0, 1, 4), 6)[:len(V)]
        t = np.concatenate([t, np.zeros(len(V) - len(t))])
        P.append(Part(lg.name + '.femur', V, Fc, lg.name + '.femur', pal['leg'], rough=0.42, vcolor=col_ramp(len(V), pal['leg'], pal['joint'], t * 0.6)))
        P.append(Part(lg.name + '.knee', *ellipsoid(K, (0.027 * k, 0.027 * k, 0.027 * k), 6, 3), lg.name + '.femur', pal['joint'], rough=0.35))
        mid = (K + A) / 2 + np.cross(n, _n(A - K)) * -0.012 * k
        V, Fc = tube([K, mid, A], [0.026 * k, 0.022 * k, 0.017 * k], 5, up=n)
        t = np.repeat(np.linspace(0, 1, 3), 5)
        t = np.concatenate([t, np.zeros(len(V) - len(t))])
        P.append(Part(lg.name + '.tibia', V, Fc, lg.name + '.tibia', pal['leg'], rough=0.45, vcolor=col_ramp(len(V), pal['leg'], pal['leg_dist'], t)))
        dirA = _n(A - K)
        inward = np.cross(n, dirA)
        for f in (0.62, 0.84):
            b = K + (A - K) * f
            P.append(Part(lg.name + f'.spur{f}', *cone(b, b + inward * 0.04 * k + dirA * 0.02 * k, 0.009 * k, 3), lg.name + '.tibia', pal['claw'], rough=0.4))
        P.append(Part(lg.name + '.ankle', *octa(A, 0.021 * k), lg.name + '.tibia', pal['joint'], rough=0.35))
        hook = F + np.array([math.cos(p[0]), math.sin(p[0]), 0]) * 0.025 * k + [0, 0, 0.012]
        V, Fc = tube([A, A + (F - A) * 0.55, F + [0, 0, 0.01], hook], [0.017 * k, 0.012 * k, 0.009 * k, 0.0], 4, up=n, tip=True)
        t = np.linspace(0, 1, len(V))
        P.append(Part(lg.name + '.tarsus', V, Fc, lg.name + '.tarsus', pal['leg_dist'], rough=0.4, sharp_deg=95,
                      vcolor=col_ramp(len(V), pal['leg_dist'], pal['claw'], t ** 2)))
        if claw is not None:
            P.extend(claw(lg, H, K, A, F, n, lod))
    else:
        caps = lod == 1
        for a, b, r0, r1, nm, c in ((H, K, 0.034 * k, 0.026 * k, 'femur', pal['leg']), (K, A, 0.024 * k, 0.016 * k, 'tibia', pal['leg']),
                                    (A, F, 0.015 * k, 0.0, 'tarsus', pal['leg_dist'])):
            V, Fc = tube([a, b], [r0, r1], 3, up=n, cap0=False, cap1=False, tip=(nm == 'tarsus'), phase=math.pi / 2)
            # 3-sided prisms are shaded smooth (sharp_deg 180): faceted they flash as pale sticks at game scale
            P.append(Part(f'{lg.name}.{nm}', V, Fc, f'{lg.name}.{nm}', c, rough=0.5, sharp_deg=180))
        if claw is not None and caps:
            P.extend(claw(lg, H, K, A, F, n, lod))
    return P


def surface_z(parts, x, y):
    """Highest z where the vertical line through (x, y) meets any face of parts (numpy ray cast)."""
    best = -np.inf
    for p in parts:
        T = np.array([(f[0], f[i], f[i + 1]) for f in p.F for i in range(1, len(f) - 1)])
        A, B, Cc = p.V[T[:, 0]], p.V[T[:, 1]], p.V[T[:, 2]]
        e0, e1 = B - A, Cc - A
        qx, qy = x - A[:, 0], y - A[:, 1]
        den = e0[:, 0] * e1[:, 1] - e1[:, 0] * e0[:, 1]
        ok = np.abs(den) > 1e-12
        den = np.where(ok, den, 1.0)
        u = (qx * e1[:, 1] - e1[:, 0] * qy) / den
        w = (e0[:, 0] * qy - qx * e0[:, 1]) / den
        hit = ok & (u >= -1e-9) & (w >= -1e-9) & (u + w <= 1 + 1e-9)
        if hit.any():
            best = max(best, float((A[:, 2] + u * e0[:, 2] + w * e1[:, 2])[hit].max()))
    assert np.isfinite(best), f'no carapace under ({x:.3f}, {y:.3f})'
    return best


def two_tone(V, c_top, c_bot, z0, z1):
    """vertex colours blending the belly colour (below z0) into the back colour (above z1)."""
    t = np.clip((V[:, 2] - z0) / max(z1 - z0, 1e-6), 0, 1)
    return col_ramp(len(V), c_bot, c_top, t)


def blob(name, bone, c, r, nu, nv, c_top, c_bot, rough=0.5, squash_bottom=1.0, rxa=0.0, flags=0, glow=0.0, sharp=80.0):
    V, F = ellipsoid(c, r, nu, nv, rx=rxa, squash_bottom=squash_bottom)
    col = two_tone(V, c_top, c_bot, c[2] - r[2] * 0.3, c[2] + r[2] * 0.5)
    return Part(name, V, F, bone, c_top, rough=rough, vcolor=col, flags=flags, glow=glow, sharp_deg=sharp)


# ------------------------------------------------------------------ common leg drives
def feet_planted(st, legs, offset=None):
    for lg in legs:
        st.feet[lg.name] = ('ik', lg.F0 + (offset(lg) if offset else 0.0))


def feet_gait(st, legs, tau, duty, D, h, fb=0.0):
    """every leg on the tripod gait of stride D per loop (stance duty, step height h); fb splays front / back feet."""
    stroke = D * duty
    for lg in legs:
        st.feet[lg.name] = ('ik', gait_foot(tau, lg, duty, stroke, h) + np.array([0, (-fb if lg.i == 0 else fb if lg.i == 2 else 0), 0]))
