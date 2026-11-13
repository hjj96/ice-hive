"""The Threader's body SEGMENT (Stage 2 B2; design.md §1.5) — one file, drawn 18 times along the body path (B4: segment
j at lead + (j - 1) × spacing = 2 + (j - 1) × 1.6 m behind the head). A frost-plated arthropod segment from the
Runner's family: a dark plum core under one big arched tergite whose flared, serrated rear rim overlaps the next
segment's narrow front collar (laid along a curve the 18 read as one body), rime crusted along that rear rim and the
keel (the pale band that reads at phone size), two hooked spines, lateral spurs, dim spiracle pores — and ONE pair of
long hooked legs (femur up and out to a spiked knee, a long spined tibia, a curved claw) that grips the trunk pipe:
the claws wrap under a pipe of radius PIPE_R whose top is the origin.

Origin: the chord's midpoint on the body path (see threader_common); +Y forward. The segment's FRONT attach point is
(0, +0.8, 0), its BACK attach (0, -0.8, 0) — sockets `front` / `back` on the root bone (they never move): B5 lays segment
j on the chord between bossBodyPoint(behind: d - 0.8) and (d + 0.8), d = 2 + (j - 1) × 1.6, so neighbours share their
joint points on any curve. The body bone (`thorax`) never moves in the loops (grip, crawl, hold, coil): a node drawn
with the same transform stays seated; only the shudder (stagger*) and the death move it, and the node file replays
exactly that motion.

Skeleton (8 bones): root, thorax, leg.F.L / leg.F.R (femur, tibia, tarsus). LOD0 ≤ 2000 / LOD1 ≤ 450 / LOD2 ≤ 150
triangles (inside the boss gate — ihv.BOSS_LOD_TRIS — and the Threader's drawn total, gates.py BOSS_DRAWN).
Clips: hold / grip (the grip-crawl along a pipe, a locomotion loop: phase from the distance) / crawl (the deck chase:
feet on the deck 0.6 m down, locomotion) / coil (the 2 m ring: legs braced to the deck) / stagger (on a pipe) /
stagger_low (on the deck) / death (on the deck, held). Instance scale 1.0.
"""
import math

import numpy as np

import ihv
from geo import Part, ellipsoid, octa, smoothstep
from insect import F_GLAND, FPS, SIDES, SN, TWO, State, bone_frame, skeleton_legs
from threader_common import (COIL_Z, DECK_Z, HALF, PAL, PIPE_R, HookLeg, body_death, body_stagger, col, hook_leg_parts,
                             leg_body_targets, nrm, pipe_point, pipe_tangent, ramp, rime_crystals, spike, tergite,
                             tergite_profile)

NAME = 'threader_seg'
SCALE = 1.0
SWITCH_PX = (60.0, 14.0, 0.0)
LOD_TRIS = ihv.BOSS_LOD_TRIS
TRI_TARGET = (2000, 450, 150)      # this part's own budget inside the boss gate (drawn 18 times)
FPS = FPS

HIP = np.array([0.62, 0.02, 0.10])
LEN = (0.70, 0.98, 0.46)
THETA = math.radians(132)          # the claw tip's place round the pipe from its top, gripping
POLE = (1.0, 0.0, 0.12)            # the knee: out (the femur runs out under the flange)


def _legs():
    out = []
    for s in SIDES:
        H = HIP * np.array([s, 1, 1])
        out.append(HookLeg(0, s, H, pipe_point(THETA, s, y=HIP[1]), pipe_tangent(THETA, s), (s * POLE[0], POLE[1], POLE[2]), LEN))
    return out


LEGS = _legs()
THORAX_REST = bone_frame((0, 0, 0.36), (0, 0.9, 0.36))


def skeleton():
    B = []

    def add(name, parent, head, tail):
        B.append((name, parent, bone_frame(head, tail), float(np.linalg.norm(np.subtract(tail, head)))))
    add('root', None, (0, 0, 0), (0, 0.25, 0))
    add('thorax', 'root', (0, 0, 0.36), (0, 0.9, 0.36))
    skeleton_legs(B, LEGS)
    return B


# ---------------------------------------------------------------- the plates
TERG = dict(y0=0.50, length=1.52, half=(0.74, 0.80), zt=(0.64, 0.70), rise=0.07, flare=0.07, keel=0.07)
COLL = dict(y0=0.98, length=0.56, half=(0.52, 0.58), zt=(0.50, 0.55), rise=0.0, flare=0.0, keel=0.03)


def terg_point(spec, u, v):
    """a point of a tergite's OUTER surface (u -1 left … 1 right across, v 0 front … 1 rear) and its outward normal —
    the crystals and spines sit on it"""
    def at(u, v):
        h = spec['half'][0] + (spec['half'][1] - spec['half'][0]) * v
        z0 = spec['zt'][0] + (spec['zt'][1] - spec['zt'][0]) * v
        fl = max(0.0, v - 0.7) / 0.3
        h *= 1.0 + spec['flare'] * fl
        z0 += spec['rise'] * fl * fl
        prof = tergite_profile(v, z0, h, spec['keel'])
        x = abs(u) * h
        for (x0, z0_), (x1, z1) in zip(prof[:-1], prof[1:]):
            if x <= x1 + 1e-9:
                t = (x - x0) / max(x1 - x0, 1e-9)
                return np.array([math.copysign(x, u), spec['y0'] - v * spec['length'], z0_ + (z1 - z0_) * t])
        return np.array([math.copysign(prof[-1][0], u), spec['y0'] - v * spec['length'], prof[-1][1]])
    p = at(u, v)
    du = at(min(u + 0.02, 1), v) - at(max(u - 0.02, -1), v)
    dv = at(u, min(v + 0.02, 1)) - at(u, max(v - 0.02, 0))
    n = nrm(np.cross(dv, du))
    if n[2] < -0.2:
        n = -n
    return p, n


def _rime(lod, seed=21):
    """hoarfrost along the flared rear rim (the pale band that reads at phone size), up the lateral keels, a little on
    the keel"""
    rng = np.random.default_rng(seed)
    A = []
    nrim = 9 if lod == 0 else 5
    for k in range(nrim):
        u = -0.9 + 1.8 * (k + 0.3 + 0.4 * rng.random()) / nrim
        v = 0.9 + 0.07 * rng.random()
        A.append(terg_point(TERG, u, v))
    if lod == 0:
        for s in (-1, 1):
            for v in (0.48, 0.7):
                A.append(terg_point(TERG, s * (0.55 + 0.02 * rng.random()), v + 0.04 * rng.random()))
    return rime_crystals('rime', 'thorax', A, seed=seed, size=(0.045, 0.09) if lod == 0 else (0.08, 0.12), lod=lod)


def _rim_band(lod, seed=23):
    """a continuous jagged rime skin along the flared rear rim (v 0.86 → 0.99) — the pale band that marks every segment
    at phone size"""
    rng = np.random.default_rng(seed)
    nu, nv = (16, 2) if lod == 0 else (6, 1)
    V, F, Cc = [], [], []
    idx = {}
    for sh in (0, 1):
        for j in range(nv + 1):
            for i in range(nu + 1):
                u = -0.97 + 1.94 * i / nu
                v = 0.86 + 0.13 * j / nv
                p, n = terg_point(TERG, u, v)
                edge = i in (0, nu) or j in (0, nv)
                k = 0.004 if sh else (0.012 if edge else 0.02 + 0.035 * rng.random())
                idx[(sh, i, j)] = len(V)
                V.append(p + n * k)
                Cc.append(0.0 if sh else 0.3 + 0.7 * rng.random())
    for j in range(nv):
        for i in range(nu):
            o = [idx[(0, i, j)], idx[(0, i + 1, j)], idx[(0, i + 1, j + 1)], idx[(0, i, j + 1)]]
            F.append((o[0], o[3], o[2], o[1]))
            q = [idx[(1, i, j)], idx[(1, i + 1, j)], idx[(1, i + 1, j + 1)], idx[(1, i, j + 1)]]
            F.append((q[0], q[1], q[2], q[3]))
    ring = [(i, 0) for i in range(nu)] + [(nu, j) for j in range(nv)] + [(i, nv) for i in range(nu, 0, -1)] + \
           [(0, j) for j in range(nv, 0, -1)]
    for k in range(len(ring)):
        p, q = ring[k], ring[(k + 1) % len(ring)]
        F.append((idx[(0, p[0], p[1])], idx[(0, q[0], q[1])], idx[(1, q[0], q[1])], idx[(1, p[0], p[1])]))
    return Part('rimband', np.array(V), F, 'thorax', PAL['frost'], rough=0.7, smooth=True, sharp_deg=60,
                vcolor=ramp(PAL['frost'], PAL['frost_hi'], np.array(Cc)), flags=4)


EXTRA_SOCKETS = [('front', 'root', (0, HALF, 0), 0), ('back', 'root', (0, -HALF, 0), 0), ('core', 'thorax', (0, 0, 0.42), 0),
                 ('dust', 'thorax', (0, -0.45, 0.8), 0)] + \
                [(f'hook.{SN[lg.s]}', f'{lg.name}.tarsus', tuple(lg.fk(lg.rest[0])[3]), 0) for lg in LEGS]


def build_parts(lod):
    P = []
    C = PAL
    if lod == 0:
        # the soft core and the belly plate that rests on the pipe
        P.append(Part('core', *ellipsoid((0, -0.05, 0.3), (0.55, 0.95, 0.24), 12, 5), 'thorax', C['core'], rough=0.55))
        V, F = ellipsoid((0, -0.04, 0.1), (0.4, 0.8, 0.085), 10, 3, squash_bottom=0.6)
        P.append(Part('belly', V, F, 'thorax', C['belly'], rough=0.5, vcolor=ramp(C['belly'], C['core'], (V[:, 2] - 0.02) / 0.17)))
        P.append(tergite('tergite', 'thorax', nv=7, serr=0.06, frost=0.8, thick=0.045, **TERG))
        P.append(tergite('collar', 'thorax', nv=2, serr=0.0, frost=0.0, thick=0.035, **COLL))
        P.append(_rime(0))
        P.append(_rim_band(0))
        for s in SIDES:
            # two hooked spines on the rear rim, a spur at each flange's rear corner (the serrated outline from above)
            p0, n0 = terg_point(TERG, s * 0.12, 0.9)
            P.append(spike(f'dspine.{SN[s]}', 'thorax', p0 - n0 * 0.01, p0 + np.array([s * 0.05, -0.3, 0.22]), 0.05, 5))
            p1, n1 = terg_point(TERG, s * 0.985, 0.9)
            P.append(spike(f'spur.{SN[s]}', 'thorax', p1, p1 + np.array([s * 0.22, -0.26, -0.04]), 0.045, 4, c1=C['claw']))
            # dim spiracle pores under the flange (the hive's pink; no glint — the five nodes are the body's lights)
            sp = np.array([s * 0.6, -0.32, 0.22])
            V, F = octa(sp, 0.03, 0.75)
            P.append(Part(f'gland.sp{SN[s]}', V, F, 'thorax', C['gland_red'], glow=0.7, rough=0.4, smooth=True, sharp_deg=180,
                          vcolor=np.tile(col(C['gland_red']), (len(V), 1)), flags=F_GLAND))
    elif lod == 1:
        P.append(Part('core', *ellipsoid((0, -0.05, 0.3), (0.55, 0.92, 0.23), 6, 3), 'thorax', C['core'], rough=0.55))
        P.append(tergite('tergite', 'thorax', nv=2, serr=0.0, frost=0.55, thick=0.05, lod=1, **TERG))
        P.append(tergite('collar', 'thorax', nv=1, serr=0.0, frost=0.0, thick=0.04, lod=1, **COLL))
        P.append(_rime(1))
        P.append(_rim_band(1))
    else:
        P.append(tergite('tergite', 'thorax', nv=1, serr=0.0, frost=0.22, thick=0.06, lod=1, **TERG))
        P.append(Part('core', *ellipsoid((0, 0.0, 0.3), (0.5, 0.95, 0.25), 4, 1), 'thorax', C['core'], rough=0.5))
    for lg in LEGS:
        P.extend(hook_leg_parts(lg, lod, thick=1.4))
    return P


# ------------------------------------------------------------------ animation
GROUND_CLAMP = set()
LOOPS = ('hold', 'grip', 'crawl', 'coil')
GRIP = dict(duty=0.5, stroke=1.1)              # stride = stroke / duty = 2.2 m per loop
CRAWL = dict(duty=0.52, stroke=1.14, x=1.8, h=0.26)
STRIDE_GRIP = GRIP['stroke'] / GRIP['duty']
STRIDE_CRAWL = CRAWL['stroke'] / CRAWL['duty']
# (Stage 2 B2: where the feet stand in each clip, for build.py's planted-foot drift check — a pipe of this radius whose
# top is the origin, or a deck this far under it)
CONTACT = {'hold': ('pipe', PIPE_R + 0.005), 'grip': ('pipe', PIPE_R + 0.005), 'stagger': ('pipe', PIPE_R + 0.005),
           'crawl': ('ground', DECK_Z), 'stagger_low': ('ground', DECK_Z), 'death': ('ground', DECK_Z),
           'coil': ('ground', COIL_Z)}

CLIPS = [  # name, frames, loop, stride (m per loop), event frame, notes
    ('hold', 60, True, 0.0, 0, 'gripping a pipe, still: the claws clench and ease, the knees breathe'),
    ('grip', 24, True, STRIDE_GRIP, 0, 'the grip-crawl along a pipe: the two claws alternate (half a loop apart) — hooked under '
                                       'the pipe in stance, unhooked up and out in the swing; phase from the distance'),
    ('crawl', 22, True, STRIDE_CRAWL, 0, 'the deck chase: feet on the deck 0.6 m under the path, body high on the arched legs'),
    ('coil', 60, True, 0.0, 0, 'the coil ring 2 m up: the legs braced down to the deck, a slow squeeze in the knees'),
    ('stagger', 45, False, 0.0, 0, 'the scream on a pipe: the body shudders and rolls, the claws clench, the knees jerk up'),
    ('stagger_low', 45, False, 0.0, 0, 'the same shudder on the deck (feet planted 0.6 m down)'),
    ('death', 60, False, 0.0, 59, 'on the deck: two spasms, the legs let go and curl over, the body drops and rolls; held'),
]


def _grip_cmd(lg, th=THETA, r=PIPE_R + 0.005, y=0.0, open_=0.0, pole_up=0.0):
    F = pipe_point(th, lg.s, r, HIP[1] + y)
    T = nrm(pipe_tangent(th, lg.s) * (1 - open_) + np.array([lg.s * 0.25, 0, -0.97]) * open_)
    return ('hook', F, T, (lg.s * POLE[0], 0.0, POLE[2] + pole_up))


def _deck_cmd(lg, x, y, z, pole_up=0.0):
    return ('hook', np.array([lg.s * x, HIP[1] + y, z]), (lg.s * 0.26, 0.0, -0.966), (lg.s, 0.0, 0.5 + pole_up))


def _body_pose(M):
    """model-space deformation of the thorax for a basis M (root at rest)"""
    return THORAX_REST @ M @ np.linalg.inv(THORAX_REST)


def clip_state(name, f, n):
    st = State()
    tau = f / n if name in LOOPS else f / (n - 1)
    w = TWO * tau
    if name == 'hold':
        for lg in LEGS:
            ph = 0.0 if lg.s < 0 else 1.9
            st.feet[lg.name] = _grip_cmd(lg, th=THETA + math.radians(3.5) * math.sin(w + ph), pole_up=0.08 * math.sin(w + ph + 0.6))
        st.glow.update(gland=0.7, pulse=0.15, wave=tau)
    elif name == 'grip':
        d, sk = GRIP['duty'], GRIP['stroke']
        for lg in LEGS:
            p = (tau + 0.5 * lg.tripod) % 1.0
            if p < d:
                st.feet[lg.name] = _grip_cmd(lg, y=sk / 2 - sk * p / d)
            else:
                q = (p - d) / (1 - d)
                e = math.sin(math.pi * q)
                y = -sk / 2 + sk * smoothstep(0, 1, q)
                st.feet[lg.name] = _grip_cmd(lg, th=THETA - math.radians(46) * e, r=PIPE_R + 0.005 + 0.32 * e, y=y, open_=0.8 * e,
                                             pole_up=0.45 * e)
        st.glow.update(gland=0.75, pulse=0.2, wave=2 * tau)
    elif name == 'crawl':
        d, sk, x, h = CRAWL['duty'], CRAWL['stroke'], CRAWL['x'], CRAWL['h']
        for lg in LEGS:
            p = (tau + 0.5 * lg.tripod) % 1.0
            if p < d:
                st.feet[lg.name] = _deck_cmd(lg, x, sk / 2 - sk * p / d, DECK_Z)
            else:
                q = (p - d) / (1 - d)
                e = math.sin(math.pi * q)
                st.feet[lg.name] = _deck_cmd(lg, x - 0.12 * e, -sk / 2 + sk * smoothstep(0, 1, q), DECK_Z + h * e, pole_up=0.3 * e)
        st.glow.update(gland=0.8, pulse=0.25, wave=2 * tau)
    elif name == 'coil':
        for lg in LEGS:
            ph = 0.0 if lg.s < 0 else 0.7
            st.feet[lg.name] = ('hook', np.array([lg.s * 0.95, HIP[1] + 0.04, COIL_Z]), (lg.s * 0.26, 0.0, -0.966),
                                (lg.s, 0.0, 0.35 + 0.12 * math.sin(w + ph)))
        st.glow.update(gland=1.0, pulse=0.35, wave=2 * tau)
    elif name in ('stagger', 'stagger_low'):
        M, env = body_stagger(f, n)
        st.set('thorax', M)
        for lg in LEGS:
            jerk = env * (0.6 + 0.4 * math.sin(f * 0.9 + (0 if lg.s < 0 else 1.3)))
            if name == 'stagger':
                st.feet[lg.name] = _grip_cmd(lg, th=THETA + math.radians(8) * env, pole_up=0.45 * jerk)
            else:
                st.feet[lg.name] = _deck_cmd(lg, CRAWL['x'], 0.0, DECK_Z, pole_up=0.4 * jerk)
        st.glow.update(gland=1.0 + 1.4 * env, pulse=0.4 * env, wave=tau * 4)
    elif name == 'death':
        M, sag = body_death(f, n)
        st.set('thorax', M)
        Bp = _body_pose(M)
        let_go = smoothstep(6, 26, f)
        for lg in LEGS:
            planted = np.array([lg.s * CRAWL['x'], HIP[1], DECK_Z])
            # curled over the side of the fallen body (moves with it)
            tw = sum(a * math.exp(-((f - c) / 1.8) ** 2) for c, a in ((30, 1.0), (38, 0.6), (47, 0.35)))
            curl_b = np.array([lg.s * (0.74 + 0.05 * tw), HIP[1] + 0.12 * lg.s * tw, 0.72 + 0.06 * tw])
            curl = (Bp @ np.append(curl_b, 1.0))[:3]
            F = planted * (1 - let_go) + curl * let_go
            T = nrm(np.array([lg.s * 0.26, 0, -0.966]) * (1 - let_go) + np.array([-lg.s * 0.7, 0.0, -0.4]) * let_go)
            st.feet[lg.name] = ('hook', F, T, (lg.s, 0.0, 0.5 + 1.6 * let_go))
        st.glow.update(gland=max(0.04, 1.0 * (1 - smoothstep(4, 40, f))), pulse=0.0, eye=1.0)
    return st
