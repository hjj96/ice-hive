"""THE THREADER (Stage 2 B2; design.md §1.5) — the shared body plan of the second Kelvin-9 boss: a 30 m segmented hive
creature threaded through the Manifold's pipe trunks. An original bug from the Runner's family (dark wet plum chitin,
pale rims, pink-white hive pores — here frost-crusted plates and pearl lantern light): an armoured insect head with
forked mandibles that open SIDEWAYS (never a round toothed maw), a swept crest and a lantern organ — the two antennae
fused into one ringed whip that arches forward over the jaws and hangs a pale bulb in a cage of dark ribs (the
spitter's acid lantern, in pearl) —, 18 frost-plated body segments, each gripping the pipe with ONE pair of long hooked
legs, and five lantern nodes (glowing sacs under hinged frost shutters on the back of segments 3 / 6 / 9 / 12 / 15).

Three IHV1 files (rigid, bone texture — Swarm/IHVLoader.swift reads them as it reads the bugs):
  threader_head  the head + neck collar (its `head` bone and children carry the look group: B5 aims the lantern with
                 the swarm's head look yaw / pitch about the `neck` socket)
  threader_seg   ONE body segment, drawn 18 times along the body path
  threader_node  a lantern node, drawn in its segment's model space (the same instance transform as the segment)
Each is built by build.py from its own module (threader_head.py, threader_seg.py, threader_node.py); this file holds
what they share: the palette, the hooked leg (a 3-D two-bone IK with an explicit tarsus direction, so the claw can
wrap UNDER a pipe), the trunk pipe the legs grip, the frost crust, and the segment body's shudder / death motion
(the node replays it, so a node never parts from its segment).

MODEL SPACE (Blender: X side, Y forward, Z up; game = (-X, Z, Y)). The origin of every file is a point ON THE BODY
PATH — B4's simulation puts the path on the route line, which R3 defines as the TOP of what the bugs ride: the top of
a trunk pipe (5 m), the top of the ring duct (8 m); on the deck (P3) the path runs 0.6 m above the deck, in the coil
2 m above it. So the segment's belly rests on the pipe top at the origin, its legs wrap down round a pipe of radius
PIPE_R whose axis runs along +Y at z = -PIPE_R; the deck clips plant the feet DECK_Z below the origin, the coil clip
COIL_Z below it.
"""
import math

import numpy as np

from geo import Part, cone, ellipsoid, hex2rgb, octa, shell_plate, smoothstep, tube
from insect import D2R, F_EDGE, LEG_ID, SN, mat, rx, ry, rz, tr

# ------------------------------------------------------------------ the numbers B4's simulation sets (read-only)
SEGMENTS = 18                # THREADER_SEGMENTS
SPACING = 1.6                # BossChainSpec.spacing: segment j sits lead + (j - 1) × spacing behind the head
LEAD = 2.0                   # BossChainSpec.lead
NODE_SEGMENTS = (3, 6, 9, 12, 15)
HALF = SPACING / 2           # a segment's front / back attach points: ±0.8 m along its own +Y (the chord's ends)
NECK_BACK = LEAD - HALF      # the head's back attach point: 1.2 m behind the head point (meets segment 1's front)
PIPE_R = 0.45                # the Manifold trunk pipe (the kit's mf_trunk_* pieces): its top on the route line
DECK_Z = -0.6                # the deck under the path in the deck chase (P3: path y = deck + 0.6)
COIL_Z = -2.0                # the deck under the coil's ring (path y = deck + 2)

# ------------------------------------------------------------------ palette (sRGB): the Runner's family, frost-plated
PAL = dict(plate=0x22182a, edge=0x56426a, keel=0x2f2238, core=0x140e17, belly=0x34162a,
           leg=0x1c1420, leg_dist=0x3a2a42, joint=0x382842, claw=0xa89fb4,
           frost=0x9ea8b8, frost_hi=0xc4ccd8,            # rime crust: capped ≤ 0.6 linear (no white ghosts in a beam)
           mand=0x2c2032, mand_tip=0xd4cadc,
           lantern=0xf0e8ff, lantern_hot=0xffffff, rib=0x261c2e, vein=0x5e4a78,
           sac=0xe6d8ff, sac_hot=0xfff6ff, husk=0x1a121e, husk_vein=0x3a2440,
           gland=0xff6f9a, gland_hot=0xfff2f7, gland_red=0xe0183a, eye=0xffc0d6, membrane=0xffc4dc)


def col(h):
    return hex2rgb(h)


def ramp(c0, c1, t):
    a, b = col(c0), col(c1)
    t = np.clip(np.asarray(t, float), 0, 1)[:, None]
    return a * (1 - t) + b * t


def nrm(v):
    v = np.asarray(v, dtype=np.float64)
    n = np.linalg.norm(v)
    return v / n if n > 1e-12 else v


# ------------------------------------------------------------------ the hooked leg
class HookLeg:
    """A hooked leg: hip H (body rest space), femur L1, tibia L2, tarsus L3. Posed by a 3-D two-bone IK from the hip to
    the ankle with a knee POLE, the tarsus along an explicit direction ending on the foot target — insect.Leg's planar
    IK holds the tarsus at a fixed angle onto the deck; this one lets the claw wrap under a pipe, plant on the deck or
    hang. Params p (12,) = knee, ankle, foot, leg-plane normal (body rest space); build.py only needs rest, fk, frames
    and the module's leg_body_targets()."""

    def __init__(self, i, s, H, F0, T0, P0, L, body='thorax'):
        self.i, self.s = i, s
        self.name = f'leg.{LEG_ID[i]}.{SN[s]}'
        self.H = np.asarray(H, float)
        self.C = self.H.copy()
        self.L = tuple(L)
        self.F0, self.T0, self.P0 = np.asarray(F0, float), nrm(T0), nrm(P0)
        self.body = body
        self.tripod = 0 if s < 0 else 1
        self.rest = self.solve(self.F0, self.T0, self.P0)

    def solve(self, F, tdir, pole):
        L1, L2, L3 = self.L
        t = nrm(tdir)
        A = np.asarray(F, float) - L3 * t
        d = A - self.H
        r = float(np.linalg.norm(d))
        rmax = (L1 + L2) * 0.999
        err = max(0.0, r - rmax)
        rc = min(max(r, abs(L1 - L2) + 1e-3), rmax)
        dh = d / max(r, 1e-9)
        a = (L1 * L1 - L2 * L2 + rc * rc) / (2 * rc)
        h = math.sqrt(max(L1 * L1 - a * a, 0.0))
        p = nrm(pole)
        q = p - dh * float(p @ dh)
        if np.linalg.norm(q) < 1e-6:
            q = np.cross(dh, (1.0, 0.0, 0.0))
        q = nrm(q)
        K = self.H + a * dh + h * q
        A2 = self.H + rc * dh
        F2 = A2 + L3 * t
        n = nrm(np.cross(dh, q))
        return np.concatenate([K, A2, F2, n]), err

    def fk(self, p):
        K, A, F, n = np.asarray(p, float).reshape(4, 3)
        return self.H, K, A, F, n

    def frames(self, p):
        H, K, A, F, n = self.fk(p)
        out = []
        for a, b in ((H, K), (K, A), (A, F)):
            y = nrm(b - a)
            x = nrm(n - y * float(n @ y))
            out.append(mat(x, y, np.cross(x, y), a))
        return out


def leg_body_targets(lg, cmd, Binv):
    """build.py hook: a leg drive → body-rest-space params and the IK reach error.
    ('hook', foot, tarsus dir, pole) in model space · ('p', params) explicit."""
    if cmd[0] == 'p':
        return cmd[1], 0.0
    R = Binv[:3, :3]
    F = (Binv @ np.append(cmd[1], 1.0))[:3]
    return lg.solve(F, R @ np.asarray(cmd[2], float), R @ np.asarray(cmd[3], float))


def pipe_point(theta, s, r=PIPE_R + 0.005, y=0.0):
    """a point on the trunk pipe's surface `theta` rad round from its top on side s (+1 right, -1 left)"""
    return np.array([s * r * math.sin(theta), y, -PIPE_R + r * math.cos(theta)])


def pipe_tangent(theta, s):
    """the direction a claw follows round the pipe at `theta` (further round: down and inward under it)"""
    return np.array([s * math.cos(theta), 0.0, -math.sin(theta)])


# ------------------------------------------------------------------ geometry helpers
def plate(name, bone, nu, nv, rough=0.36, vflags=F_EDGE, frost_rim=0.0, **kw):
    """an arched frost plate (geo.shell_plate): dark plum chitin, a paler mauve rim, a darker keel, the inner surface in
    the body's core colour; frost_rim > 0 crusts the rear rim pale (rime caught on the overlapping edge)."""
    V, F = shell_plate(nu=nu, nv=nv, **kw)
    n = (nu + 1) * (nv + 1)
    u = np.tile(np.linspace(-1, 1, nu + 1), nv + 1)
    v = np.repeat(np.linspace(0, 1, nv + 1), nu + 1)
    u, v = np.concatenate([u, u]), np.concatenate([v, v])
    inner = np.concatenate([np.zeros(n), np.ones(n)])
    edge = np.clip(np.maximum((np.abs(u) - 0.6) / 0.4, (v - 0.6) / 0.4), 0, 1) ** 1.5 * min(1.0, (nu - 1) / 10.0)
    keel = np.clip(1 - np.abs(u) * 4, 0, 1) * (1 - inner)
    c = ramp(PAL['plate'], PAL['edge'], edge * (1 - inner) * 0.85)
    c = c * (1 - keel[:, None] * 0.3) + col(PAL['keel']) * keel[:, None] * 0.3
    if frost_rim > 0:
        fr = np.clip((v - 0.72) / 0.28, 0, 1) * np.clip(1.2 - np.abs(u) * 0.9, 0, 1) * (1 - inner) * frost_rim
        c = c * (1 - fr[:, None]) + col(PAL['frost']) * fr[:, None]
    c = np.where(inner[:, None] > 0, col(PAL['core']), c)
    return Part(name, V, F, bone, PAL['plate'], rough=rough, smooth=True, sharp_deg=42, vcolor=c, flags=vflags)


def crust(name, bone, y0, length, a, b, zc, th0, th1, nu, nv, lift=0.012, jag=0.03, seed=1, flare=0.0, ridge=0.0,
          rough=0.72, c0=None, c1=None):
    """a rime crust: a jagged pale skin over part of an arched plate (angles th0..th1 deg from the top, v along the
    plate front → back), thicker toward the rear rim; closed (outer + inner + rim) so it never shows a hole."""
    rng = np.random.default_rng(seed)
    c0 = PAL['frost'] if c0 is None else c0
    c1 = PAL['frost_hi'] if c1 is None else c1
    V, F, C = [], [], []
    idx = {}
    for s, inner in ((0, False), (1, True)):
        for j in range(nv + 1):
            for i in range(nu + 1):
                v = j / nv
                t = math.radians(th0 + (th1 - th0) * i / nu)
                av = a[0] + (a[1] - a[0]) * v
                bv = b[0] + (b[1] - b[0]) * v
                rr = 1.0 + flare * max(0.0, v - 0.6) / 0.4
                k = 0.0 if inner else lift + jag * (0.35 + 0.65 * v) * rng.random() * (1.0 if 0 < i < nu and 0 < j < nv else 0.25)
                z = zc + (bv * rr + k) * math.cos(t) + ridge * max(0.0, 1 - abs(t) / 0.5) * math.sin(math.pi * v)
                x = (av * rr + k) * math.sin(t)
                idx[(s, i, j)] = len(V)
                V.append((x, y0 - v * length, z))
                C.append(0.0 if inner else min(1.0, 0.25 + 0.75 * v * rng.random() + 0.35 * (k / max(jag, 1e-6))))
    for j in range(nv):
        for i in range(nu):
            o = [idx[(0, i, j)], idx[(0, i + 1, j)], idx[(0, i + 1, j + 1)], idx[(0, i, j + 1)]]
            F.append((o[0], o[3], o[2], o[1]))
            n_ = [idx[(1, i, j)], idx[(1, i + 1, j)], idx[(1, i + 1, j + 1)], idx[(1, i, j + 1)]]
            F.append((n_[0], n_[1], n_[2], n_[3]))
    ring = [(i, 0) for i in range(nu)] + [(nu, j) for j in range(nv)] + [(i, nv) for i in range(nu, 0, -1)] + \
           [(0, j) for j in range(nv, 0, -1)]
    for k in range(len(ring)):
        p, q = ring[k], ring[(k + 1) % len(ring)]
        F.append((idx[(0, p[0], p[1])], idx[(0, q[0], q[1])], idx[(1, q[0], q[1])], idx[(1, p[0], p[1])]))
    V = np.array(V)
    c = ramp(c0, c1, np.array(C))
    return Part(name, V, F, bone, c0, rough=rough, smooth=True, sharp_deg=55, vcolor=c, flags=F_EDGE)


def spike(name, bone, base, tip, r, sides=5, c0=None, c1=None, rough=0.32):
    """a tapered spike, dark at the base, pale toward the point (frost on the tip)"""
    V, F = cone(base, tip, r, sides)
    t = np.zeros(len(V))
    t[-1] = 1.0
    c = ramp(PAL['keel'] if c0 is None else c0, PAL['frost_hi'] if c1 is None else c1, t)
    return Part(name, V, F, bone, PAL['keel'], rough=rough, smooth=True, sharp_deg=50, vcolor=c)


def hook_leg_parts(lg, lod, thick=1.0):
    """the leg's mesh in its REST pose (the grip): LOD0 coxa, a bowed ridged femur, the knee with an up-spike, a long
    tibia with inner spines, the ankle and the HOOK — a claw in three curved sections that follows the pipe's round and
    ends in a pale point (its lowest vertex: the foot's contact point for build.py's drift check). LOD1: three open
    3-sided prisms + a 2-section hook. LOD2: two prisms (femur, tibia + tarsus) — 12 triangles."""
    P = []
    H, K, A, F, n = lg.fk(lg.rest[0])
    k = thick
    s = lg.s
    if lod == 0:
        P.append(Part(lg.name + '.coxa', *ellipsoid((H + np.array([-s * 0.05, 0, 0.06])), (0.09 * k, 0.1 * k, 0.06 * k), 7, 3),
                      'thorax', PAL['joint'], rough=0.45))
        side = nrm(np.cross(n, nrm(K - H)))
        mid = (H + K) / 2 + side * 0.035 * k
        V, Fc = tube([H, H + (mid - H) * 0.5, mid, K], [0.062 * k, 0.078 * k, 0.074 * k, 0.055 * k], 7, flat=0.78, up=n)
        t = np.repeat(np.linspace(0, 1, 4), 7)[:len(V)]
        t = np.concatenate([t, np.zeros(len(V) - len(t))])
        P.append(Part(lg.name + '.femur', V, Fc, lg.name + '.femur', PAL['leg'], rough=0.4, vcolor=ramp(PAL['leg'], PAL['joint'], t * 0.6)))
        # a ridge plate along the femur's top (catches the rim light: the high knees read at phone size)
        rv = [H + (K - H) * f + nrm(np.cross(nrm(K - H), n)) * -0.0 + np.array([0, 0, 0.055 * k]) for f in (0.15, 0.55, 0.95)]
        V, Fc = tube(rv, [0.03 * k, 0.034 * k, 0.02 * k], 4, flat=0.5, up=(0, 1, 0))
        P.append(Part(lg.name + '.ridge', V, Fc, lg.name + '.femur', PAL['edge'], rough=0.34, sharp_deg=60))
        P.append(Part(lg.name + '.knee', *ellipsoid(K, (0.06 * k, 0.06 * k, 0.06 * k), 7, 3), lg.name + '.femur', PAL['joint'], rough=0.35))
        P.append(spike(lg.name + '.kspike', lg.name + '.femur', K + np.array([0, -0.02, 0.04]), K + np.array([s * 0.06, -0.16, 0.2]) * k,
                       0.03 * k, 4))
        side = nrm(np.cross(n, nrm(A - K)))
        mid = (K + A) / 2 + side * -0.04 * k
        V, Fc = tube([K, K + (mid - K) * 0.6, mid, A], [0.05 * k, 0.046 * k, 0.04 * k, 0.03 * k], 6, up=n)
        t = np.repeat(np.linspace(0, 1, 4), 6)[:len(V)]
        t = np.concatenate([t, np.zeros(len(V) - len(t))])
        P.append(Part(lg.name + '.tibia', V, Fc, lg.name + '.tibia', PAL['leg'], rough=0.42, vcolor=ramp(PAL['leg'], PAL['leg_dist'], t)))
        dA = nrm(A - K)
        inward = nrm(np.cross(n, dA)) * -1.0
        if inward[0] * s > 0:
            inward = -inward
        for f in (0.45, 0.68, 0.86):
            b = K + (A - K) * f
            P.append(spike(lg.name + f'.spine{f}', lg.name + '.tibia', b, b + inward * 0.07 * k - dA * 0.03 * k, 0.014 * k, 3,
                           c0=PAL['leg_dist'], c1=PAL['claw']))
        P.append(Part(lg.name + '.ankle', *octa(A, 0.04 * k), lg.name + '.tibia', PAL['joint'], rough=0.35))
        # the hook: three sections bending further round than the straight tarsus bone (it follows the pipe's round)
        ax = nrm(F - A)
        bend = nrm(np.cross(n, ax))
        if bend[0] * s > 0:
            bend = -bend
        path = [A, A + ax * 0.36 * lg.L[2] + bend * -0.035, A + ax * 0.72 * lg.L[2] + bend * -0.03, F]
        V, Fc = tube(path, [0.034 * k, 0.03 * k, 0.022 * k, 0.0], 5, up=n, tip=True)
        t = np.linspace(0, 1, len(V)) ** 1.6
        P.append(Part(lg.name + '.tarsus', V, Fc, lg.name + '.tarsus', PAL['leg_dist'], rough=0.36, sharp_deg=95,
                      vcolor=ramp(PAL['leg_dist'], PAL['claw'], t)))
        # a barb on the hook's back
        b0 = A + ax * 0.5 * lg.L[2]
        P.append(spike(lg.name + '.barb', lg.name + '.tarsus', b0, b0 - bend * 0.06 * k - ax * 0.04 * k, 0.012 * k, 3,
                       c0=PAL['leg_dist'], c1=PAL['claw']))
    elif lod == 1:
        for a, b, r0, r1, nm, c in ((H, K, 0.07, 0.055, 'femur', PAL['leg']), (K, A, 0.05, 0.032, 'tibia', PAL['leg'])):
            V, Fc = tube([a, b], [r0 * k, r1 * k], 3, up=n, cap0=False, cap1=False, phase=math.pi / 2)
            P.append(Part(f'{lg.name}.{nm}', V, Fc, f'{lg.name}.{nm}', c, rough=0.5, sharp_deg=180))
        ax = nrm(F - A)
        bend = nrm(np.cross(n, ax))
        if bend[0] * lg.s > 0:
            bend = -bend
        V, Fc = tube([A, A + ax * 0.55 * lg.L[2] - bend * 0.03, F], [0.032 * k, 0.022 * k, 0.0], 3, up=n, cap0=False, tip=True,
                     phase=math.pi / 2)
        t = np.linspace(0, 1, len(V)) ** 1.5
        P.append(Part(f'{lg.name}.tarsus', V, Fc, f'{lg.name}.tarsus', PAL['leg_dist'], rough=0.5, sharp_deg=180,
                      vcolor=ramp(PAL['leg_dist'], PAL['claw'], t)))
    else:
        V, Fc = tube([H, K], [0.075 * k, 0.05 * k], 3, up=n, cap0=False, cap1=False, phase=math.pi / 2)
        P.append(Part(f'{lg.name}.femur', V, Fc, f'{lg.name}.femur', PAL['leg'], rough=0.5, sharp_deg=180))
        V, Fc = tube([K, A, F], [0.05 * k, 0.03 * k, 0.0], 3, up=n, cap0=False, tip=True, phase=math.pi / 2)
        t = np.linspace(0, 1, len(V)) ** 2
        P.append(Part(f'{lg.name}.tibia', V, Fc, f'{lg.name}.tibia', PAL['leg_dist'], rough=0.5, sharp_deg=180,
                      vcolor=ramp(PAL['leg'], PAL['claw'], t)))
    return P


# ------------------------------------------------------------------ the body's shudder and death (seg + node share them)
def body_stagger(f, n):
    """the scream's shudder down the body (the node replays it): a hard roll / bob that dies out over the clip; the
    plates bristle (pitch), the grip clenches (k, 0..1, for the legs)."""
    t = f / (n - 1)
    env = (1 - smoothstep(0.0, 1.0, t)) * smoothstep(0.0, 0.06, t)
    roll = 11 * env * math.sin(f * 1.35)
    bob = 0.05 * env * abs(math.sin(f * 0.68))
    pitch = 4 * env * math.sin(f * 0.9 + 0.7)
    M = tr(0, 0, bob) @ ry(roll * D2R) @ rx(pitch * D2R)
    return M, env


def body_death(f, n):
    """the death on the deck (P3 — the Threader dies in its last phase, on the deck): two spasms, the body sags onto
    the deck (DECK_Z under the path: the belly lands ~0.1 m above it) and rolls over a little; (pose, collapse 0..1)."""
    sp = sum(a * math.exp(-((f - c) / 2.2) ** 2) for c, a in ((5, 1.0), (13, 0.7)))
    sag = smoothstep(10, 34, f)
    roll = 4 * smoothstep(16, 40, f) + 4 * sp * math.sin(f * 1.7)
    # the belly (0.04 over the path at rest) comes down onto the deck DECK_Z under the path, settling 4 cm above it
    drop = (DECK_Z + 0.04) * sag
    M = tr(0.04 * sag, 0, drop + 0.05 * sp) @ ry(roll * D2R) @ rx((4 * sp - 5 * sag) * D2R)
    return M, sag

# ------------------------------------------------------------------ the sculpted frost plate (tergite) and rime
def tergite_profile(v, zt, half, keel=0.07, depth=1.0):
    """half cross-section (x >= 0) of a Threader tergite at v (0 front → 1 rear): the keel, the dorsal field, a raised
    lateral keel, the flange sloping down and out to a thick rim — (x, z) pairs from the midline out (depth scales the
    drops: a narrow plate is shallower)."""
    d = depth
    return [(0.0, zt + keel), (0.07 * half, zt + 0.018 * d), (0.36 * half, zt - 0.025 * d), (0.55 * half, zt - 0.008 * d),
            (0.66 * half, zt - 0.06 * d), (0.8 * half, zt - 0.15 * d), (0.92 * half, zt - 0.25 * d), (half, zt - 0.33 * d)]


def tergite(name, bone, y0, length, half=(0.74, 0.8), zt=(0.66, 0.71), nv=6, rise=0.07, flare=0.07, serr=0.06, thick=0.045,
            frost=0.0, keel=0.07, lod=0, seed=3, depth=1.0, plate_col=None, edge_col=None):
    """an arched frost plate with a sculpted cross-section (tergite_profile): a closed solid (outer, inner, rim); the
    rear quarter rises and flares (it overlaps the next segment's collar), its rim is serrated; dark plum chitin, the
    keels and the rim a step paler, the rear rim rimed pale (frost > 0)."""
    rng = np.random.default_rng(seed)
    prof0 = tergite_profile(0.0, 0.0, 1.0, keel, depth)
    nh = len(prof0) - 1 if lod == 0 else 3
    if lod == 0:
        pick = list(range(len(prof0)))
    else:
        pick = [0, 3, 5, 7]
    ncol = 2 * len(pick) - 1
    V, F, Cc = [], [], []
    idx = {}
    for sh in (0, 1):
        for j in range(nv + 1):
            v = j / nv
            h = half[0] + (half[1] - half[0]) * v
            z0 = zt[0] + (zt[1] - zt[0]) * v
            fl = max(0.0, v - 0.7) / 0.3
            h *= 1.0 + flare * fl
            z0 += rise * fl * fl
            prof = tergite_profile(v, z0, h, keel, depth)
            row = [prof[k] for k in pick]
            pts = [(-x, z) for x, z in reversed(row[1:])] + row
            for i, (x, z) in enumerate(pts):
                y = y0 - v * length
                if j == nv and serr > 0 and i % 2 == 1:
                    y -= serr * (0.6 + 0.4 * (1 - abs(x) / h))
                if sh == 1:
                    z -= thick
                    x *= 1 - thick / max(h, 1e-3) * 0.6
                idx[(sh, i, j)] = len(V)
                V.append((x, y, z))
                ax = abs(x) / h
                keelk = max(0.0, 1 - ax * 9) + max(0.0, 1 - abs(ax - 0.57) * 12) * 0.8
                rim = max(0.0, (ax - 0.86) / 0.14) + max(0.0, (v - 0.82) / 0.18)
                pc, ec = col(plate_col or PAL['plate']), col(edge_col or PAL['edge'])
                c = pc * (1 - min(1, 0.55 * keelk + 0.7 * rim)) + ec * min(1, 0.55 * keelk + 0.7 * rim)
                if frost > 0 and sh == 0:
                    fr = frost * max(0.0, (v - 0.84) / 0.16) ** 0.7 * (0.55 + 0.45 * rng.random()) * (1.0 if ax < 0.95 else 0.5)
                    fr += frost * 0.3 * max(0.0, 1 - abs(ax - 0.55) * 14) * (0.3 + 0.7 * v)
                    fr = min(1.0, fr)
                    c = c * (1 - fr) + col(PAL['frost']) * fr
                if sh == 1:
                    c = col(PAL['core'])
                Cc.append(c)
    for j in range(nv):
        for i in range(ncol - 1):
            o = [idx[(0, i, j)], idx[(0, i + 1, j)], idx[(0, i + 1, j + 1)], idx[(0, i, j + 1)]]
            F.append((o[0], o[3], o[2], o[1]))          # outer faces up / out (geo.shell_plate's winding)
            q = [idx[(1, i, j)], idx[(1, i + 1, j)], idx[(1, i + 1, j + 1)], idx[(1, i, j + 1)]]
            F.append((q[0], q[1], q[2], q[3]))
    ring = [(i, 0) for i in range(ncol - 1)] + [(ncol - 1, j) for j in range(nv)] + [(i, nv) for i in range(ncol - 1, 0, -1)] + \
           [(0, j) for j in range(nv, 0, -1)]
    for k in range(len(ring)):
        p, q = ring[k], ring[(k + 1) % len(ring)]
        F.append((idx[(0, p[0], p[1])], idx[(0, q[0], q[1])], idx[(1, q[0], q[1])], idx[(1, p[0], p[1])]))
    V = np.array(V)
    return Part(name, V, F, bone, PAL['plate'], rough=0.36, smooth=True, sharp_deg=38, vcolor=np.array(Cc), flags=F_EDGE)


def rime_crystals(name, bone, anchors, seed=5, size=(0.05, 0.12), lod=0):
    """hoarfrost: small jagged pale crystals (5-sided spikes leaning back) at anchor points (x, y, z, normal) — clumped
    along a plate's rear rim and keels; one closed part."""
    rng = np.random.default_rng(seed)
    V, F, C = [], [], []
    for (p, n) in anchors:
        p, n = np.asarray(p, float), nrm(n)
        h = size[0] + (size[1] - size[0]) * rng.random()
        r = h * (0.55 + 0.25 * rng.random())
        lean = nrm(n + np.array([rng.normal(0, 0.3), -0.9 - 0.4 * rng.random(), rng.normal(0, 0.15)]))
        tip = p + lean * h
        a = nrm(np.cross(n, (0.0, 1.0, 0.0)) if abs(n[1]) < 0.9 else np.cross(n, (1.0, 0.0, 0.0)))
        b = np.cross(n, a)
        sides = 4 if lod else 5
        base = len(V)
        for k in range(sides):
            t = 2 * math.pi * (k + rng.random() * 0.3) / sides
            V.append(p + (a * math.cos(t) + b * math.sin(t)) * r * (0.75 + 0.5 * rng.random()) - n * 0.01)
            C.append(0.15 + 0.3 * rng.random())
        V.append(tip)
        C.append(0.85 + 0.15 * rng.random())
        for k in range(sides):
            F.append((base + k, base + (k + 1) % sides, base + sides))
        F.append(tuple(base + k for k in reversed(range(sides))))
    return Part(name, np.array(V), F, bone, PAL['frost'], rough=0.62, smooth=True, sharp_deg=70,
                vcolor=ramp(PAL['frost'], PAL['frost_hi'], np.array(C)), flags=F_EDGE)

