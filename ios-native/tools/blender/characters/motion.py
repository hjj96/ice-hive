"""The marines' clips (WP4 «Отряд») — numpy only. Every frame is built from a POSE SPEC (the pelvis and chest in model
space, the head, the weapon, and IK targets for the hands and feet), so planted feet stay on the deck and the hands
stay on the grips by construction; specs of one-shot clips are keyframed and interpolated, locomotion is a
parametric gait. Each class gets its own copy of every clip (its weapon hold, its gait style) in its own file.

Clip list (30 fps, one track row per frame; names match MarineRig.swift):
  idle                 loop  2 s   breathing, weight shift, weapon sway, look-around
  walk_<d> / run_<d>   loops       8 directions d ∈ f fl l bl b br r fr relative to the aim (l = toward +x, the
                                   marine's left); one phase convention (0 = left foot touch-down, 0.5 = right), stride
                                   in the clip record (m per loop): the app advances the phase by distance / stride
  dash_f/_b/_l/_r      one-shot    crouch → boost (feet off the deck) → land → settle
  fire                 additive    per weapon: rifle kick (one-shot, retriggered per shot), rotary judder, flamer push,
                                   cryo hum (loops) — the delta from its frame 0
  flinch_f / flinch_b  additive    a hit from the front / from behind
  down                 one-shot    knees buckle → kneel → fall prone (holds)
  downed               loop  2 s   prone crawl in place (the support arm reaches and pulls, the legs push)
  revive               one-shot    prone → hands and knees → kneel → stand (the app scrubs it by revive progress)
  death                one-shot    from prone: the last spasm, the weapon slides away, the visor goes dark (holds)
The ctrl bone carries the IK weights (gun hand, support hand), the foot plant weights and the visor glow.
"""
import numpy as np

import skeleton as S
from skeleton import IDX, Pose, qaxis, qbetween, qconj, qeuler, qmat, qmul, qnorm, qrotate, qslerp, solve_limb

FPS = 30.0
UP = np.array([0.0, 1.0, 0.0])
Q0 = np.array([0.0, 0.0, 0.0, 1.0])
LEG = 0.44 + 0.415        # thigh + shin (bind ≈)
BALL_Y = 0.035            # toe joint height on a flat foot
DIRS = {'f': 0.0, 'fl': 45.0, 'l': 90.0, 'bl': 135.0, 'b': 180.0, 'br': -135.0, 'r': -90.0, 'fr': -45.0}

# gait style per class (the gunner carries the heaviest kit, the pyro hunches over the flamer)
STYLE = {
    'assault': dict(width=0.135, low=0.0, lean=1.0, bob=1.0, blade=22.0, hunch=0.0),
    'pyro':    dict(width=0.145, low=0.012, lean=1.12, bob=1.05, blade=18.0, hunch=4.0),
    'cryo':    dict(width=0.13, low=0.0, lean=0.9, bob=0.9, blade=20.0, hunch=0.0),
    'gunner':  dict(width=0.16, low=0.03, lean=0.8, bob=1.25, blade=12.0, hunch=2.0),
}
# (stance length = duty × stride must stay inside the leg's reach: 0.86 m hip → ankle, the heel lifting at toe-off)
GAIT = {
    'walk': dict(frames=30, speed=1.5, duty=0.58, front=0.5, lift=0.085, bob=0.02, sway=0.022, roll=3.0, twist=6.0,
                 lean=4.0, low=0.055, heel=26.0),
    'run':  dict(frames=18, speed=5.3, duty=0.27, front=0.44, lift=0.26, bob=0.036, sway=0.010, roll=4.0, twist=9.0,
                 lean=10.0, low=0.10, heel=40.0),
}

# ---------------------------------------------------------------- grips: where the hands hold each weapon
# weapon-local (the weapon bone sits on the gun hand's grip; its axes are the model axes in the aim stance):
# centre of each grip, its axis (the fist's knuckle line), the support hand's kind ('vertical' foregrip / 'top' handle)
GRIPS = {
    'assault': dict(sup=(-0.045, 0.01, 0.145), gun_axis=(0, 1, -0.27), sup_axis=(0, 1, 0.12), kind='vertical', muzzle=(0.0, 0.088, 0.715)),
    'pyro':    dict(sup=(-0.095, 0.06, 0.17), gun_axis=(0, 1, -0.3), sup_axis=(0, 1, 0.2), kind='vertical', muzzle=(0.0, 0.088, 0.765)),
    'cryo':    dict(sup=(-0.055, 0.015, 0.15), gun_axis=(0, 1, -0.27), sup_axis=(0, 1, 0.1), kind='vertical', muzzle=(0.0, 0.08, 0.765)),
    'gunner':  dict(sup=(-0.07, 0.25, 0.17), gun_axis=(0, 1, -0.2), sup_axis=(0, 0, 1), kind='top', muzzle=(-0.015, 0.1, 0.88)),
}


def norm(v):
    v = np.asarray(v, dtype=np.float64)
    return v / max(np.linalg.norm(v), 1e-12)


def frame_q(x, y, z):
    """Rotation whose columns are the given (orthonormalised) axes."""
    z = norm(z)
    x = norm(np.asarray(x) - z * np.dot(x, z))
    y = np.cross(z, x)
    return S.mat2q(np.stack([x, y, z], 1))


def ease(t):
    t = np.clip(t, 0.0, 1.0)
    return t * t * (3 - 2 * t)


def ease_out(t):
    t = np.clip(t, 0.0, 1.0)
    return 1 - (1 - t) ** 3


# ---------------------------------------------------------------- the hands
def hand_bind_q(side):
    """Bind orientation of a hand's canonical frame (x knuckle line — thumb side for the right hand, little finger
    side for the left —, y the back of the hand, z wrist → knuckles) in the A-pose."""
    s = 1.0 if side == 'L' else -1.0
    _, d2 = S.arm_dirs(side)
    z = d2
    y = norm(np.array([s, 0.25, -0.1]) - z * np.dot(np.array([s, 0.25, -0.1]), z))
    x = np.cross(y, z)
    return S.mat2q(np.stack([x, y, z], 1))


def grip_frames(cls):
    """Weapon-local wrist position and canonical-frame rotation of each hand on its grip (gun hand L, support R)."""
    g = GRIPS[cls]
    out = {}
    # gun hand: fist round the pistol grip, knuckle line down the grip (x = −axis for the left hand), forearm from the
    # left shoulder (the stance puts it ≈ 0.4 m behind and 0.35 m above the grip)
    ax = norm(g['gun_axis'])
    fwd = norm(np.array([-0.05, -0.35, 1.0]))
    z = norm(fwd - ax * np.dot(fwd, ax))
    x = -ax
    y = np.cross(z, x)
    q = S.mat2q(np.stack([x, y, z], 1))
    hs = S.HAND_SCALE
    out['L'] = (np.zeros(3) - z * 0.078 * hs + y * 0.012 * hs, q)
    # support hand: from the right shoulder, across the body
    c = np.asarray(g['sup'], dtype=np.float64)
    if g['kind'] == 'vertical':
        ax = norm(g['sup_axis'])
        fwd = norm(np.array([0.62, -0.38, 0.68]))
        z = norm(fwd - ax * np.dot(fwd, ax))
        x = ax
        y = np.cross(z, x)
    else:   # top handle along the barrel, the hand over it, palm down
        ax = norm(g['sup_axis'])
        y = np.array([0.0, 1.0, 0.15])           # back of the hand up
        z0 = norm(np.array([0.55, -0.75, 0.2]))  # forearm comes down onto the handle from the right shoulder
        z = norm(z0 - ax * np.dot(z0, ax))
        x = ax
        y = np.cross(z, x)
    q = S.mat2q(np.stack([x, y, z], 1))
    out['R'] = (c - z * 0.078 * hs + y * 0.014 * hs, q)
    return out


# ---------------------------------------------------------------- pose specs
class Spec:
    """Everything that defines a frame, in model space."""

    def __init__(self):
        self.pelvis_p = np.array([0.0, 1.0, 0.0])
        self.pelvis_q = Q0.copy()
        self.chest_q = Q0.copy()      # model-space chest rotation
        self.spine_k = (0.33, 0.66)   # how far spine1 / spine2 go from the pelvis toward the chest rotation
        self.head_q = Q0.copy()       # model space
        self.weapon_p = None          # None: carried in the stance relation to the chest
        self.weapon_q = Q0.copy()
        self.weapon_mode = 'world'    # 'world': weapon_p / weapon_q (None = the stance's); 'hand': the gun hand's
                                      # wrist / hand_q targets carry the weapon (prone, crawling)
        self.wrist = {'L': None, 'R': None}
        self.hand_q = {'L': None, 'R': None}
        self.elbow_pole = {'L': np.array([0.9, -0.6, -0.5]), 'R': np.array([-0.9, -0.7, -0.2])}
        self.ik = {'L': 1.0, 'R': 1.0}    # 1: on the grip, 0: the spec's own wrist target
        self.ankle = {'L': None, 'R': None}
        self.foot_q = {'L': Q0.copy(), 'R': Q0.copy()}
        self.knee_pole = {'L': np.array([0.15, 0.0, 1.0]), 'R': np.array([-0.15, 0.0, 1.0])}
        self.toe = {'L': 0.0, 'R': 0.0}   # toe bend (deg, + = toes up relative to the foot)
        self.plant = {'L': 1.0, 'R': 1.0}
        self.visor = 1.0
        self.aux = 0.0                    # weapon_aux rotation about its forward axis (deg)
        self.pauldron = 0.15
        self.extra = {}                   # name → local rotation (antenna, backpack…)

    def copy(self):
        s = Spec.__new__(Spec)
        for k, v in self.__dict__.items():
            if isinstance(v, dict):
                s.__dict__[k] = {a: (b.copy() if isinstance(b, np.ndarray) else b) for a, b in v.items()}
            elif isinstance(v, np.ndarray):
                s.__dict__[k] = v.copy()
            else:
                s.__dict__[k] = v
        return s


def lerp_spec(a, b, t):
    """Blend two specs (positions lerp, rotations slerp, weights lerp)."""
    t = float(t)
    s = a.copy()

    def mix(x, y):
        if x is None or y is None:
            return y if t >= 0.5 else x
        if isinstance(x, tuple):
            return tuple(mix(u, v) for u, v in zip(x, y))
        x = np.asarray(x, dtype=np.float64)
        y = np.asarray(y, dtype=np.float64)
        if x.shape == (4,):
            return qslerp(x, y, t)
        return x + (y - x) * t

    for k, v in a.__dict__.items():
        w = b.__dict__[k]
        if isinstance(v, dict):
            s.__dict__[k] = {n: (mix(v[n], w[n]) if not isinstance(v[n], float) else v[n] + (w[n] - v[n]) * t) for n in v}
        elif isinstance(v, (float, int)) and not isinstance(v, bool):
            s.__dict__[k] = v + (w - v) * t
        elif isinstance(v, np.ndarray) or isinstance(v, tuple) or v is None:
            s.__dict__[k] = mix(v, w)
    return s


def stance(cls, crouch=0.0):
    """The aim stance: pelvis bladed toward the gun side, chest turned so the support shoulder comes forward, the
    weapon level along +z, feet staggered (gun-side foot back)."""
    st = STYLE[cls]
    s = Spec()
    s.pelvis_p = np.array([0.0, 1.0 - 0.035 - st['low'] - crouch, -0.01])
    s.pelvis_q = qeuler(y=st['blade'] * 0.35)
    s.chest_q = qeuler(y=st['blade'], x=6.0 + st['hunch'])
    s.head_q = qeuler(y=0.0, x=4.0)
    s.ankle['L'] = np.array([0.155, 0.115, -0.085])
    s.ankle['R'] = np.array([-0.145, 0.115, 0.075])
    s.foot_q['L'] = qeuler(y=16.0)
    s.foot_q['R'] = qeuler(y=4.0)
    s.knee_pole['L'] = np.array([0.25, 0.0, 1.0])
    s.knee_pole['R'] = np.array([-0.1, 0.0, 1.0])
    return s


# weapon in the stance: where the class's bind puts it, level
def stance_weapon(cls):
    return np.asarray(S.WEAPON[cls]['grip'], dtype=np.float64), Q0.copy()


def build(cls, spec, report=None, floor=True):
    """Spec → Pose (FK + IK). `report`: list collecting the IK reach errors (m). A weapon that would sink into the deck
    (a fall, the crawl, a dropped gun) is lifted by rebuilding with the gun hand / the weapon raised."""
    rep = []
    p = _build(cls, spec, rep)
    if floor and spec.weapon_p is not None or floor and spec.weapon_mode == 'hand':
        lift = weapon_floor_lift(cls, p)
        if lift > 0:
            s2 = spec.copy()
            if s2.weapon_mode == 'hand':
                s2.wrist['L'] = s2.wrist['L'] + np.array([0.0, lift, 0.0])
            else:
                s2.weapon_p = s2.weapon_p + np.array([0.0, lift, 0.0])
            rep = []
            p = _build(cls, s2, rep)
    if report is not None:
        report.extend(rep)
    return p


def _build(cls, spec, report=None):
    p = Pose(cls)
    # pelvis, spine, chest, neck / head (model-space targets → local)
    p.t[IDX['pelvis']] = spec.pelvis_p - p.t[IDX['root']]
    p.q[IDX['pelvis']] = qnorm(spec.pelvis_q)
    WQ, WP = p.world()
    k1, k2 = spec.spine_k
    p.set_world_rot('spine1', qslerp(spec.pelvis_q, spec.chest_q, k1), WQ)
    WQ, WP = p.world()
    p.set_world_rot('spine2', qslerp(spec.pelvis_q, spec.chest_q, k2), WQ)
    WQ, WP = p.world()
    p.set_world_rot('chest', spec.chest_q, WQ)
    WQ, WP = p.world()
    p.set_world_rot('neck', qslerp(spec.chest_q, spec.head_q, 0.45), WQ)
    WQ, WP = p.world()
    p.set_world_rot('head', spec.head_q, WQ)
    WQ, WP = p.world()
    grips = grip_frames(cls)
    c = IDX['chest']
    sides = ('L', 'R')
    if spec.weapon_mode == 'hand':
        # the gun hand goes to its own target and the weapon follows it (its grip in the fist)
        sh = WP[IDX['upperarm_L']]
        err = solve_limb(p, 'upperarm_L', 'forearm_L', 'hand_L', spec.wrist['L'], sh + spec.elbow_pole['L'],
                         end_rot=spec.hand_q['L'])
        if report is not None:
            report.append(('arm_L', err))
        WQ, WP = p.world()
        off, gq = grips['L']
        wq = qmul(qmul(WQ[IDX['hand_L']], hand_bind_q('L')), qconj(gq))
        wp = WP[IDX['hand_L']] - qrotate(wq, off)
        sides = ('R',)
    elif spec.weapon_p is None:
        wp, wq = stance_weapon(cls)
    else:
        wp, wq = spec.weapon_p, spec.weapon_q
    p.t[IDX['weapon']] = qrotate(qconj(WQ[c]), wp - WP[c])
    p.set_world_rot('weapon', wq, WQ)
    p.q[IDX['weapon_aux']] = qaxis((0, 0, 1), np.radians(spec.aux))
    WQ, WP = p.world()
    # hands: on the grips (IK) or on the spec's own targets
    wqw, wpw = WQ[IDX['weapon']], WP[IDX['weapon']]
    for side in sides:
        off, gq = grips[side]
        on = spec.ik[side]
        tgt_g = wpw + qrotate(wqw, off)
        rot_g = qmul(qmul(wqw, gq), qconj(hand_bind_q(side)))
        if spec.wrist[side] is None or on >= 0.999:
            tgt, rot = tgt_g, rot_g
        else:
            rot_s = spec.hand_q[side] if spec.hand_q[side] is not None else rot_g
            tgt = spec.wrist[side] + (tgt_g - spec.wrist[side]) * on
            rot = qslerp(rot_s, rot_g, on)
        sh = WP[IDX['upperarm_' + side]]
        pole = sh + spec.elbow_pole[side]
        err = solve_limb(p, 'upperarm_' + side, 'forearm_' + side, 'hand_' + side, tgt, pole, end_rot=rot)
        if report is not None and on >= 0.999:
            report.append(('arm_' + side, err))
    # legs
    for side in ('L', 'R'):
        WQ, WP = p.world()
        hip = WP[IDX['thigh_' + side]]
        a = spec.ankle[side]
        if a is None:
            continue
        a = floor_ankle(a, spec.foot_q[side], spec.toe[side])
        d = np.linalg.norm(a - hip)
        pole = (hip + a) * 0.5 + spec.knee_pole[side]
        err = solve_limb(p, 'thigh_' + side, 'shin_' + side, 'foot_' + side, a, pole, end_rot=spec.foot_q[side])
        if report is not None:
            report.append(('leg_' + side, err if d < LEG + 0.01 else err))
        p.q[IDX['toe_' + side]] = qeuler(x=-spec.toe[side])
    # secondary armour: pauldrons follow the upper arms, tassets the thighs (the app redoes this after its own IK)
    follow(p, spec.pauldron)
    for n, q in spec.extra.items():
        p.q[IDX[n]] = qnorm(q)
    p.ctrl(spec.ik['L'], spec.ik['R'], spec.plant['L'], spec.plant['R'], spec.visor)
    return p


def floor_ankle(a, fq, toe=0.0):
    """The deck is a floor: a foot pivots on its ball (toes rolled under, a kneel, a fall) instead of sinking into it —
    the ankle rises until the soles of the boot (under the heel, the ball and the bent toe's tip) clear the deck."""
    a = np.asarray(a, dtype=np.float64)
    ball = a + qrotate(fq, np.array([0.0, -0.08, 0.168]))
    qt = qmul(fq, qeuler(x=-toe))
    pts = [a + qrotate(fq, np.array([0.0, -0.112, -0.14])),          # heel sole
           ball + qrotate(fq, np.array([0.0, -BALL_Y, 0.0])),        # sole under the ball
           ball + qrotate(qt, np.array([0.0, -BALL_Y + 0.004, 0.1]))]  # sole under the toe's tip
    lift = max(0.0, -min(p[1] for p in pts))
    return a + np.array([0.0, lift, 0.0]) if lift > 0 else a


# weapon-local bounds of each class's weapon (marines.weapon, the torch and the support grip included): a weapon in a
# fall / crawl / drop must not sink into the deck
WEAPON_BOX = {
    'assault': ((-0.095, -0.13, -0.38), (0.055, 0.21, 0.72)),
    'pyro':    ((-0.115, -0.075, -0.14), (0.095, 0.19, 0.77)),
    'cryo':    ((-0.098, -0.075, -0.32), (0.078, 0.205, 0.77)),
    'gunner':  ((-0.13, -0.075, -0.2), (0.125, 0.275, 0.88)),
}


def weapon_floor_lift(cls, p, clearance=0.006):
    """How far the posed weapon's lowest corner is under `clearance` above the deck (0 when clear)."""
    WQ, WP = p.world()
    k = IDX['weapon']
    lo, hi = (np.asarray(v, dtype=np.float64) for v in WEAPON_BOX[cls])
    m = qmat(WQ[k])
    ymin = 9.0
    for cx in (lo[0], hi[0]):
        for cy in (lo[1], hi[1]):
            for cz in (lo[2], hi[2]):
                ymin = min(ymin, float(WP[k][1] + (m @ np.array([cx, cy, cz]))[1]))
    return max(0.0, clearance - ymin)


FOLLOW = [('pauldron_L', 'upperarm_L', 0.4), ('pauldron_R', 'upperarm_R', 0.4),
          ('tasset_L', 'thigh_L', 0.55), ('tasset_R', 'thigh_R', 0.55)]


def follow(p, k_pauldron=0.15):
    """Secondary armour: pauldrons take a fraction of the upper arm's SWING away from its bind direction (no twist);
    tassets lift with a thigh swinging forward (one swinging back leaves them hanging). The app does the same after
    its IK (MarineRig.swift)."""
    bind = p.bind
    for dst, src, k in FOLLOW:
        q = p.q[IDX[src]]
        if dst.startswith('pauldron'):
            child = IDX['forearm_' + src[-1]]
            d0 = bind[child]
            d1 = qrotate(q, d0)
            p.q[IDX[dst]] = qslerp(Q0, qbetween(d0, d1), k_pauldron)
        else:
            fwd = qrotate(q, (0.0, -1.0, 0.0))
            lift = max(0.0, np.arctan2(fwd[2], -fwd[1]))
            p.q[IDX[dst]] = qaxis((1, 0, 0), -lift * k)


# ---------------------------------------------------------------- clips
class Clip:
    def __init__(self, name, poses, loop, stride=0.0, event=None, additive=False):
        self.name, self.poses, self.loop, self.stride, self.event, self.additive = name, poses, loop, stride, event, additive


def left_of(v):
    return np.array([v[2], 0.0, -v[0]])


def idle(cls, report):
    n = 60
    poses = []
    base = stance(cls)
    for k in range(n):
        u = k / n
        s = base.copy()
        b = np.sin(2 * np.pi * u)
        b2 = np.sin(4 * np.pi * u + 0.7)
        s.pelvis_p = s.pelvis_p + np.array([0.008 * np.sin(2 * np.pi * u + 1.1), 0.004 * b, 0.0])
        s.chest_q = qmul(s.chest_q, qeuler(x=0.9 * b, z=0.5 * np.sin(2 * np.pi * u + 1.1)))
        s.head_q = qeuler(y=5.0 * np.sin(2 * np.pi * u + 0.3) + 2.0 * b2, x=4.0 + 1.5 * np.sin(2 * np.pi * u + 2.0))
        wp, wq = stance_weapon(cls)
        s.weapon_p = wp + np.array([0.003 * b2, 0.004 * b, 0.002 * np.sin(2 * np.pi * u + 2.2)])
        s.weapon_q = qeuler(x=-0.6 * b, y=0.5 * np.sin(2 * np.pi * u + 0.4))
        s.extra['antenna'] = qeuler(x=2.0 * np.sin(2 * np.pi * u - 0.6), z=1.5 * np.sin(4 * np.pi * u))
        poses.append(build(cls, s, report))
    return Clip('idle', poses, True)


def gait(cls, kind, dname, report, drift):
    """One locomotion loop: kind walk / run, direction dname (relative to the aim)."""
    G, st = GAIT[kind], STYLE[cls]
    n, v, duty = G['frames'], G['speed'], G['duty']
    T = n / FPS
    stride = v * T
    th = np.radians(DIRS[dname])
    dirv = np.array([np.sin(th), 0.0, np.cos(th)])
    back = abs(DIRS[dname]) >= 135.0
    legdir = -dirv if back else dirv
    tb = DIRS[dname] - 180.0 * np.sign(DIRS[dname]) if back else DIRS[dname]
    hipyaw = np.clip(tb * 0.45, -40.0, 40.0)
    base = stance(cls)
    front = duty * stride * G['front']
    backd = duty * stride - front
    width = st['width'] * (1.0 if kind == 'walk' else 0.85)
    poses = []
    plant_hist = {'L': [], 'R': []}
    for k in range(n):
        u = k / n
        s = base.copy()
        # pelvis: height (pelvis drop on contact for the walk, compression at mid-stance for the run), sway, roll, twist
        if kind == 'walk':
            bob = G['bob'] * st['bob'] * np.cos(4 * np.pi * (u - 0.3))
        else:
            bob = -G['bob'] * st['bob'] * np.cos(4 * np.pi * (u - duty * 0.5))
        sway = G['sway'] * np.cos(2 * np.pi * (u - 0.25))
        roll = G['roll'] * np.sin(2 * np.pi * (u - 0.25))
        twist = -G['twist'] * np.cos(2 * np.pi * u)
        lean = G['lean'] * st['lean'] * (-0.35 if back else 1.0)
        lean_q = qaxis(np.cross(UP, dirv), np.radians(lean))
        s.pelvis_p = np.array([0.0, 1.0 - G['low'] - st['low'] + bob, -0.01]) + left_of(legdir) * sway
        yaw_q = qeuler(y=hipyaw + twist)
        s.pelvis_q = qmul(lean_q, qmul(yaw_q, qaxis(legdir, np.radians(roll))))
        # upper body: the stance's blade, leaning with the gait, the twist counter-rotated away
        s.chest_q = qmul(lean_q, qeuler(y=st['blade'] - 0.12 * twist, x=6.0 + st['hunch'], z=-0.4 * roll))
        s.head_q = qeuler(y=0.0, x=4.0 - 0.6 * lean)
        # weapon rides the chest with a little lag on the bob
        wp, wq = stance_weapon(cls)
        lag = -0.25 * (bob - 0.0)
        s.weapon_p = wp + np.array([0.0, lag * 0.5, -0.004 * abs(np.sin(2 * np.pi * u))])
        s.weapon_q = qeuler(x=-1.2 * np.sin(4 * np.pi * (u - 0.1)) * (1.0 if kind == 'run' else 0.5), y=0.6 * np.sin(2 * np.pi * u))
        # feet
        for side, off in (('L', 0.0), ('R', 0.5)):
            sgn = 1.0 if side == 'L' else -1.0
            ph = (u - off) % 1.0
            lat = left_of(legdir) * width * sgn
            if ph < duty:
                x = front - stride * ph
                ball = lat + dirv * x + np.array([0.0, BALL_Y, 0.0])
                heel = G['heel'] * ease((ph / duty - 0.6) / 0.4) if not back else 0.0
                plant = 1.0
                lift_s = None
            else:
                ss = (ph - duty) / (1.0 - duty)
                m = -stride * (1.0 - duty)
                h00, h10, h01, h11 = 2 * ss ** 3 - 3 * ss ** 2 + 1, ss ** 3 - 2 * ss ** 2 + ss, -2 * ss ** 3 + 3 * ss ** 2, ss ** 3 - ss ** 2
                x = h00 * (-backd) + h10 * m + h01 * front + h11 * m
                hgt = G['lift'] * np.sin(np.pi * ss) ** 0.8
                if kind == 'run':
                    hgt *= 1.0 + 0.35 * np.sin(np.pi * min(1.0, ss * 1.6))
                ball = lat + dirv * x + np.array([0.0, BALL_Y + hgt, 0.0])
                # toes down off the deck, level mid-swing, toes up before a walking heel strike
                heel = G['heel'] * (1 - ease(ss / 0.45)) * (0.0 if back else 1.0) + (8.0 * ease((ss - 0.6) / 0.4) if back else 0.0)
                if kind == 'walk' and not back:
                    heel -= 10.0 * ease((ss - 0.55) / 0.25) * (1.0 - ease((ss - 0.82) / 0.18))
                plant = 0.0
                lift_s = ss
            yaw = np.degrees(np.arctan2(legdir[0], legdir[2])) + 9.0 * sgn
            fq = qmul(qeuler(y=yaw), qeuler(x=heel))
            # ankle from the ball and the foot pitch; heel lifts further when the leg cannot reach (deck stays flat)
            hip = s.pelvis_p + qrotate(s.pelvis_q, np.array([sgn * 0.12, -0.03, 0.01]))
            if heel < 0:
                # toes up: the boot's heel (≈ 0.31 m behind the ball) would dip under the deck
                ball = ball + np.array([0.0, 0.31 * np.sin(np.radians(-heel)), 0.0])
            ank = None
            pitch = heel
            for extra in np.linspace(0.0, 60.0, 61):
                fq2 = qmul(qeuler(y=yaw), qeuler(x=heel + extra))
                a = ball + qrotate(fq2, np.array([0.0, 0.08, -0.168]))
                if np.linalg.norm(a - hip) < LEG - 0.004 or extra >= 60.0:
                    ank, fq, pitch = a, fq2, heel + extra
                    break
            s.ankle[side] = ank
            s.foot_q[side] = fq
            s.knee_pole[side] = legdir * 1.0 + left_of(legdir) * 0.18 * sgn
            # toes stay flat on the deck through toe-off (bent up by the heel lift) and only point down mid-swing
            tb = 0.97 if plant > 0 else 0.97 - 0.67 * ease(lift_s / 0.35)
            s.toe[side] = max(0.0, pitch) * tb
            s.plant[side] = plant
            plant_hist[side].append((k, plant, ball, lift_s))
        s.extra['antenna'] = qeuler(x=-6.0 * bob / max(G['bob'], 1e-6) * 0.5 - (4.0 if kind == 'run' else 1.0),
                                    z=3.0 * np.sin(2 * np.pi * u))
        s.extra['backpack'] = qeuler(x=-1.2 * bob / max(G['bob'], 1e-6))
        poses.append(build(cls, s, report))
    # gate: planted toes stay put in the world while the body moves at the clip speed
    worst = 0.0
    for side in ('L', 'R'):
        start = None
        first = plant_hist[side][0]
        for k, pl, _, _ in plant_hist[side] + [(n,) + first[1:]]:
            WQ, WP = poses[k % n].world()
            wpos = WP[IDX['toe_' + side]] + dirv * v * (k / FPS)
            if pl > 0.5:
                if start is None:
                    start = wpos
                worst = max(worst, float(np.linalg.norm((wpos - start)[[0, 2]])))
            else:
                start = None
    drift[f'{kind}_{dname}'] = worst
    return Clip(f'{kind}_{dname}', poses, True, stride=stride)


def bake_hand_keys(cls, keys):
    """Keys whose weapon rides in the gun hand ('hand' mode) become 'world' keys with that weapon placement and the
    gun hand on its grip, so keyed interpolation moves the weapon smoothly between any two keys."""
    out = []
    for f, s in keys:
        if s.weapon_mode == 'hand':
            p = build(cls, s)
            WQ, WP = p.world()
            s = s.copy()
            s.weapon_mode = 'world'
            s.weapon_p = WP[IDX['weapon']].copy()
            s.weapon_q = WQ[IDX['weapon']].copy()
            s.ik = dict(s.ik)
            s.ik['L'] = 1.0
        elif s.weapon_p is None:
            s = s.copy()
            s.weapon_p, s.weapon_q = stance_weapon(cls)
        out.append((f, s))
    return out


def keyed(cls, name, keys, n, loop=False, report=None, additive=False, easing=None):
    """keys: [(frame, spec)] — specs eased between keys (smoothstep unless `easing`), the last held."""
    keys = bake_hand_keys(cls, keys)
    poses = []
    for k in range(n):
        for i in range(len(keys) - 1):
            f0, s0 = keys[i]
            f1, s1 = keys[i + 1]
            if f0 <= k <= f1:
                t = (k - f0) / max(1e-9, (f1 - f0))
                e = easing[i] if easing is not None else ease
                s = lerp_spec(s0, s1, e(t))
                break
        else:
            s = keys[-1][1]
        poses.append(build(cls, s, report))
    return Clip(name, poses, loop, additive=additive)


def hand_rot(side, x, y, z):
    """World delta rotation of a hand whose canonical frame (x knuckle line, y back of the hand, z wrist → knuckles)
    should line up with the given axes."""
    return qmul(frame_q(x, y, z), qconj(hand_bind_q(side)))


def carried(cls, s, pivot, dq):
    """The stance weapon carried with a torso rotation dq about `pivot` (dash leans, flinches): position follows,
    the muzzle re-levels half way."""
    wp, wq = stance_weapon(cls)
    s.weapon_p = pivot + qrotate(dq, wp - pivot)
    s.weapon_q = qslerp(Q0, dq, 0.5)
    return s


def dash(cls, d, report):
    """Dash toward d (f, b, l, r), 16 frames: anticipation crouch 0–2, boost 3–7 (feet off the deck, body along the
    dash), land 8–10, settle 11–15."""
    st = stance(cls)
    dv = {'f': np.array([0, 0, 1.0]), 'b': np.array([0, 0, -1.0]), 'l': np.array([1.0, 0, 0]), 'r': np.array([-1.0, 0, 0])}[d]
    ax = np.cross(UP, dv)
    lean = {'f': 30.0, 'b': -14.0, 'l': 22.0, 'r': 22.0}[d]
    piv = st.pelvis_p.copy()
    crouch = st.copy()
    q = qaxis(ax, np.radians(lean * 0.45))
    crouch.pelvis_p = st.pelvis_p + np.array([0, -0.1, 0]) - dv * 0.04
    crouch.chest_q = qmul(q, st.chest_q)
    crouch.pelvis_q = qmul(qaxis(ax, np.radians(lean * 0.25)), st.pelvis_q)
    crouch.head_q = qeuler(x=2.0)
    carried(cls, crouch, piv, q)
    crouch.weapon_p = crouch.weapon_p + np.array([0, -0.1, 0]) - dv * 0.04
    boost = st.copy()
    q = qaxis(ax, np.radians(lean))
    up = np.array([0, 0.05, 0]) + dv * 0.05
    boost.pelvis_p = st.pelvis_p + up
    boost.pelvis_q = qmul(q, st.pelvis_q)
    boost.chest_q = qmul(qaxis(ax, np.radians(lean * 1.08)), st.chest_q)
    boost.head_q = qmul(qaxis(ax, np.radians(-lean * 0.55)), qeuler(x=3.0))
    carried(cls, boost, piv, qaxis(ax, np.radians(lean * 1.08)))
    boost.weapon_p = boost.weapon_p + up
    lat = left_of(dv)
    hipL = boost.pelvis_p + qrotate(boost.pelvis_q, np.array([0.12, -0.03, 0.0]))
    hipR = boost.pelvis_p + qrotate(boost.pelvis_q, np.array([-0.12, -0.03, 0.0]))
    # trailing leg stretched back along the boost, leading knee driven up toward the dash
    tr = 'L' if d in ('f', 'r') else 'R'
    ld = 'R' if tr == 'L' else 'L'
    hips = {'L': hipL, 'R': hipR}
    boost.ankle[tr] = hips[tr] + qrotate(q, np.array([0.0, -0.735, 0.0])) - dv * 0.2
    boost.ankle[ld] = hips[ld] + qrotate(q, np.array([0.0, -0.5, 0.0])) + dv * 0.22
    boost.foot_q[tr] = qmul(qaxis(ax, np.radians(lean - 35.0)), qeuler(y=8.0 if tr == 'L' else -8.0))
    boost.foot_q[ld] = qmul(qaxis(ax, np.radians(lean * 0.4)), qeuler(y=8.0 if ld == 'L' else -8.0))
    for sd in ('L', 'R'):
        boost.knee_pole[sd] = dv * 0.7 + np.array([0.0, -0.1, 0.6]) + (np.array([0.2, 0, 0]) if sd == 'L' else np.array([-0.2, 0, 0]))
    boost.plant = {'L': 0.0, 'R': 0.0}
    land = st.copy()
    q = qaxis(ax, np.radians(lean * 0.3))
    land.pelvis_p = st.pelvis_p + np.array([0, -0.11, 0])
    land.chest_q = qmul(q, st.chest_q)
    land.pelvis_q = qmul(qaxis(ax, np.radians(lean * 0.2)), st.pelvis_q)
    carried(cls, land, piv, q)
    land.weapon_p = land.weapon_p + np.array([0, -0.1, 0])
    land.ankle['L'] = st.ankle['L'] - dv * 0.1 + lat * 0.03
    land.ankle['R'] = st.ankle['R'] + dv * 0.1 - lat * 0.03
    land.head_q = qeuler(x=8.0)
    keys = [(0, st), (2, crouch), (4, boost), (7, boost), (9, land), (15, st)]
    clip = keyed(cls, f'dash_{d}', keys, 16, report=report,
                 easing=[ease, ease_out, lambda t: t, ease, ease])
    for k, p in enumerate(clip.poses):
        pl = 1.0 if (k <= 1 or k >= 9) else 0.0
        t = p.t[IDX['ctrl']]
        p.ctrl(t[0], t[1], pl, pl, 1.0)
    return clip


def fire(cls, report):
    """Additive weapon layer (delta from frame 0). Rifle: a kick through chest, shoulders and gun per shot (one-shot,
    retriggered); the rotary cannon judders, the flamer pushes back and wobbles, the cryo projector hums (loops)."""
    st = stance(cls)
    wp, wq = stance_weapon(cls)
    piv = st.pelvis_p + np.array([0.0, 0.45, 0.0])
    if cls == 'assault':
        # a hard, short kick: the peak on the first frame (33 ms), a small overshoot past rest, settled by 0.2 s
        prof = [0.0, 1.0, 0.58, 0.2, -0.06, 0.0]
        poses = []
        for a in prof:
            s = st.copy()
            dq = qeuler(x=-4.4 * a, y=-2.0 * a)
            s.chest_q = qmul(dq, st.chest_q)
            carried(cls, s, piv, dq)
            s.weapon_p = s.weapon_p + np.array([0.006 * a, 0.024 * a, -0.075 * a])
            s.weapon_q = qmul(qeuler(x=-9.5 * a, y=1.4 * a), s.weapon_q)
            s.head_q = qeuler(x=4.0 - 3.0 * a)
            s.pelvis_p = st.pelvis_p + np.array([0, -0.004 * max(a, 0.0), -0.012 * a])
            poses.append(build(cls, s, report))
        return Clip('fire', poses, False, additive=True)
    n = 6 if cls == 'gunner' else 12
    poses = []
    for k in range(n):
        u = k / n
        s = st.copy()
        push = 0.0 if k == 0 else 1.0
        if cls == 'gunner':
            j = np.array([np.sin(2 * np.pi * u * 2 + 0.3), np.sin(2 * np.pi * u * 3), np.sin(2 * np.pi * u + 1.0)])
            # the rotary leans the whole body back into its push and judders through chest, shoulders and gun
            dq = qeuler(x=(-3.6 + 0.9 * j[2]) * push, y=0.6 * j[0] * push)
            s.chest_q = qmul(dq, st.chest_q)
            carried(cls, s, piv, dq)
            s.weapon_p = s.weapon_p + np.array([0.008 * j[0], 0.009 * j[1], -0.032]) * push
            s.weapon_q = qmul(qeuler(x=-2.4 * j[1] * push, y=1.5 * j[0] * push), s.weapon_q)
            s.pelvis_p = st.pelvis_p + np.array([0, -0.006 * push, -0.024 * push])
        else:
            w = np.sin(2 * np.pi * u)
            tr = np.sin(2 * np.pi * u * 3) if cls == 'cryo' else np.sin(2 * np.pi * u * 2)
            amp = 0.003 if cls == 'cryo' else 0.006
            dq = qeuler(x=(-1.6 if cls == 'pyro' else -0.8) * push)
            s.chest_q = qmul(dq, st.chest_q)
            carried(cls, s, piv, dq)
            s.weapon_p = s.weapon_p + np.array([amp * tr, amp * w, -0.024 if cls == 'pyro' else -0.012]) * push
            s.weapon_q = qmul(qeuler(x=((-1.8 if cls == 'pyro' else -0.6) + (1.0 if cls == 'pyro' else 0.3) * w) * push,
                                     y=(0.8 if cls == 'pyro' else 0.25) * tr * push), s.weapon_q)
        poses.append(build(cls, s, report))
    return Clip('fire', poses, True, additive=True)


def flinch(cls, d, report):
    """Additive hit reaction: from the front the torso is thrown back and the head snaps, from behind it lurches."""
    st = stance(cls)
    a = -1.0 if d == 'f' else 1.0
    hit = st.copy()
    dq = qeuler(x=(9.0 if d == 'f' else 11.0) * a, z=-4.0 * a)
    hit.chest_q = qmul(dq, st.chest_q)
    hit.pelvis_q = qmul(qeuler(x=4.0 * a), st.pelvis_q)
    hit.pelvis_p = st.pelvis_p + np.array([0.0, -0.025, 0.03 * a])
    hit.head_q = qeuler(x=4.0 + 18.0 * a, y=-7.0)
    carried(cls, hit, st.pelvis_p + np.array([0, 0.45, 0]), dq)
    hit.weapon_p = hit.weapon_p + np.array([0.0, 0.02, 0.015 * a])
    keys = [(0, st), (2, hit), (4, hit), (9, st)]
    return keyed(cls, f'flinch_{d}', keys, 10, report=report, additive=True,
                 easing=[ease_out, lambda t: t, ease])


def prone(cls, phase=0.0, reach=0.0):
    """Lying prone along +z on the armour's front plates, head up; the gun hand keeps the weapon on its side on the
    deck by the head (the weapon rides the hand), the support arm on the deck (reach 0…1 pulls it forward), one knee
    drawn up by the crawl phase."""
    s = Spec()
    sp = np.sin(phase)
    s.pelvis_p = np.array([0.0, 0.24 + 0.025 * reach, -0.3])
    s.pelvis_q = qmul(qeuler(y=3.0 * sp), qmul(qeuler(x=88.0), qeuler(z=4.0 * reach)))
    s.chest_q = qmul(qeuler(y=-3.0 * sp), qmul(qeuler(x=78.0 - 10.0 * reach), qeuler(z=-5.0 * reach)))
    s.spine_k = (0.4, 0.72)
    s.head_q = qmul(qeuler(y=6.0 * np.sin(phase * 0.5)), qeuler(x=34.0 - 10.0 * reach))
    # gun hand on the deck beside the head, the weapon lying on its side, muzzle forward
    s.weapon_mode = 'hand'
    s.wrist['L'] = np.array([0.33, 0.105, 0.42 + 0.04 * reach])
    s.hand_q['L'] = hand_rot('L', x=(0.0, 0.0, -1.0), y=(1.0, 0.0, 0.0), z=(0.0, -1.0, 0.0))
    s.hand_q['L'] = hand_rot('L', x=(0.2, 0.0, -1.0), y=(0.25, 1.0, 0.0), z=(1.0, -0.15, 0.25))
    s.elbow_pole['L'] = np.array([0.7, 0.3, -0.4])
    s.ik = {'L': 1.0, 'R': 0.0}
    s.wrist['R'] = np.array([-0.3, 0.075, 0.42 + 0.34 * reach])
    s.hand_q['R'] = hand_rot('R', x=(1.0, 0.0, 0.0), y=(0.0, 1.0, 0.0), z=(0.1, 0.0, 1.0))
    s.elbow_pole['R'] = np.array([-0.9, 0.4, -0.2])
    # legs: an army crawl — the knee of the pushing leg swings out to the side (it bends in the deck's plane, never
    # down into it), the toes dig in (feet steep, the ankle high enough that the toe cap rests on the deck)
    kL = 0.5 + 0.5 * sp
    kR = 0.5 - 0.5 * sp
    s.ankle['L'] = np.array([0.2 + 0.2 * kL, 0.2, -1.1 + 0.3 * kL])
    s.ankle['R'] = np.array([-0.2 - 0.2 * kR, 0.2, -1.1 + 0.3 * kR])
    s.foot_q['L'] = qmul(qeuler(y=10.0 + 25.0 * kL), qeuler(x=78.0))
    s.foot_q['R'] = qmul(qeuler(y=-10.0 - 25.0 * kR), qeuler(x=78.0))
    s.knee_pole['L'] = np.array([1.0, 0.08, 0.2])
    s.knee_pole['R'] = np.array([-1.0, 0.08, 0.2])
    s.toe = {'L': 66.0, 'R': 66.0}
    s.plant = {'L': 0.0, 'R': 0.0}
    s.pauldron = 0.25
    s.visor = 0.75
    return s


def kneel_both(cls):
    """On both knees, slumped forward (the fall's middle)."""
    s = Spec()
    s.pelvis_p = np.array([0.0, 0.63, -0.06])
    s.pelvis_q = qeuler(x=14.0)
    s.chest_q = qeuler(x=34.0, z=-6.0, y=8.0)
    s.head_q = qeuler(x=30.0, z=8.0)
    s.weapon_mode = 'hand'
    s.wrist['L'] = np.array([0.3, 0.62, 0.3])
    s.hand_q['L'] = hand_rot('L', x=(0.1, -1.0, 0.3), y=(1.0, 0.0, 0.2), z=(-0.1, -0.35, 1.0))
    s.elbow_pole['L'] = np.array([0.8, -0.3, -0.4])
    s.ik = {'L': 1.0, 'R': 0.0}
    s.wrist['R'] = np.array([-0.26, 0.5, 0.36])
    s.hand_q['R'] = hand_rot('R', x=(1.0, 0.0, 0.0), y=(0.0, 0.3, -1.0), z=(0.0, -1.0, -0.3))
    s.elbow_pole['R'] = np.array([-0.9, -0.4, -0.2])
    for sd, sg in (('L', 1.0), ('R', -1.0)):
        s.ankle[sd] = np.array([0.14 * sg, 0.2, -0.42])
        s.foot_q[sd] = qeuler(x=84.0, y=6.0 * sg)
        s.knee_pole[sd] = np.array([0.1 * sg, -0.4, 1.0])
        s.toe[sd] = 66.0
    s.plant = {'L': 0.0, 'R': 0.0}
    s.visor = 0.9
    return s


def down(cls, report):
    """Hit down: the knees buckle (0–5), both knees hit the deck (5–12), he falls forward onto the support hand
    (12–20) and lies prone (20–27, held)."""
    st = stance(cls)
    buckle = st.copy()
    dq = qeuler(x=24.0, z=-9.0)
    buckle.pelvis_p = st.pelvis_p + np.array([0.0, -0.2, -0.05])
    buckle.chest_q = qmul(dq, st.chest_q)
    buckle.head_q = qeuler(x=30.0, z=10.0)
    carried(cls, buckle, st.pelvis_p + np.array([0, 0.45, 0]), dq)
    buckle.weapon_p = buckle.weapon_p + np.array([0.03, -0.24, -0.06])
    buckle.weapon_q = qmul(qeuler(x=28.0, z=-18.0), buckle.weapon_q)
    buckle.ik = {'L': 1.0, 'R': 0.0}
    buckle.wrist['R'] = np.array([-0.2, 0.92, 0.22])
    buckle.hand_q['R'] = hand_rot('R', x=(1.0, 0.0, 0.0), y=(0.0, 0.4, -1.0), z=(0.0, -1.0, -0.4))
    kn = kneel_both(cls)
    pr = prone(cls)
    mid = lerp_spec(bake_hand_keys(cls, [(0, kn)])[0][1], bake_hand_keys(cls, [(0, pr)])[0][1], 0.6)
    mid.wrist['R'] = np.array([-0.28, 0.115, 0.5])
    mid.pelvis_p = mid.pelvis_p + np.array([0, 0.08, 0])
    keys = [(0, st), (5, buckle), (12, kn), (19, mid), (27, pr)]
    return keyed(cls, 'down', keys, 28, report=report, easing=[ease_out, ease, ease, ease_out])


def downed(cls, report):
    """Prone crawl in place, 2 s (two pulls): the support arm reaches and drags, the knees push alternately, the
    head comes up; the visor flickers."""
    n = 60
    poses = []
    for k in range(n):
        u = k / n
        ph = 4 * np.pi * u
        reach = 0.5 + 0.5 * np.sin(ph - 0.8)
        s = prone(cls, phase=ph, reach=reach)
        s.visor = 0.72 + 0.18 * np.sin(6 * np.pi * u) * np.sin(2 * np.pi * u + 0.5)
        poses.append(build(cls, s, report))
    return Clip('downed', poses, True)


def revive(cls, report):
    """Prone (0) → hands and knees (12) → kneeling on the gun-side knee, weapon coming up (24) → rising (34) → the
    aim stance (44). The app scrubs it by the revive progress, then plays the rest once revived."""
    pr = prone(cls)
    hk = Spec()
    hk.pelvis_p = np.array([0.0, 0.65, -0.34])
    hk.pelvis_q = qeuler(x=38.0)
    hk.chest_q = qeuler(x=64.0)
    hk.head_q = qeuler(x=22.0)
    hk.weapon_mode = 'hand'
    hk.wrist['L'] = np.array([0.3, 0.105, 0.34])
    hk.hand_q['L'] = pr.hand_q['L']
    hk.elbow_pole['L'] = np.array([0.8, 0.3, -0.3])
    hk.ik = {'L': 1.0, 'R': 0.0}
    hk.wrist['R'] = np.array([-0.27, 0.075, 0.36])
    hk.hand_q['R'] = pr.hand_q['R']
    hk.elbow_pole['R'] = np.array([-0.9, 0.3, -0.2])
    for sd, sg in (('L', 1.0), ('R', -1.0)):
        hk.ankle[sd] = np.array([0.15 * sg, 0.2, -0.86])
        hk.foot_q[sd] = qeuler(x=84.0, y=6.0 * sg)
        hk.knee_pole[sd] = np.array([0.15 * sg, -0.5, 1.0])
        hk.toe[sd] = 66.0
    hk.plant = {'L': 0.0, 'R': 0.0}
    hk.visor = 0.9
    kneel = stance(cls)
    kneel.pelvis_p = np.array([0.03, 0.66, -0.12])
    kneel.pelvis_q = qeuler(x=6.0, y=8.0)
    kneel.chest_q = qeuler(x=14.0, y=STYLE[cls]['blade'] * 0.7)
    kneel.head_q = qeuler(x=6.0)
    wp, wq = stance_weapon(cls)
    kneel.weapon_p = wp + np.array([-0.02, -0.36, -0.1])
    kneel.weapon_q = qeuler(x=14.0)
    kneel.ik = {'L': 1.0, 'R': 1.0}
    kneel.ankle['L'] = np.array([0.16, 0.2, -0.55])
    kneel.foot_q['L'] = qeuler(x=84.0, y=10.0)
    kneel.toe['L'] = 66.0
    kneel.knee_pole['L'] = np.array([0.05, -1.0, 0.3])
    kneel.ankle['R'] = np.array([-0.15, 0.115, 0.3])
    kneel.foot_q['R'] = qeuler(y=-4.0)
    kneel.knee_pole['R'] = np.array([-0.05, 0.4, 1.0])
    kneel.plant = {'L': 0.0, 'R': 1.0}
    kneel.visor = 1.0
    st = stance(cls)
    rise = lerp_spec(kneel, st, 0.55)
    rise.pelvis_p = rise.pelvis_p + np.array([0.0, -0.04, 0.02])
    rise.foot_q['L'] = qeuler(x=30.0, y=10.0)
    keys = [(0, pr), (12, hk), (24, kneel), (34, rise), (44, st)]
    return keyed(cls, 'revive', keys, 45, report=report)


def death(cls, report):
    """From prone: a last spasm (0–6), the arms give, he rolls onto the gun-side shoulder, the weapon slides out of
    the hand, the visor goes dark (6–30, held)."""
    pr = prone(cls)
    spasm = prone(cls, phase=0.6, reach=0.8)
    spasm.head_q = qeuler(x=44.0, z=12.0)
    spasm.visor = 0.95
    limp = prone(cls)
    limp.pelvis_p = limp.pelvis_p + np.array([0.0, 0.01, 0.0])
    limp.pelvis_q = qmul(qeuler(x=90.0), qeuler(z=-10.0))
    limp.chest_q = qmul(qeuler(x=90.0), qeuler(z=-18.0))
    limp.head_q = qeuler(x=80.0, z=-26.0, y=18.0)
    limp.weapon_mode = 'world'
    wl = bake_hand_keys(cls, [(0, pr)])[0][1]
    limp.weapon_p = wl.weapon_p + np.array([0.16, 0.02, 0.12])
    limp.weapon_q = qmul(qeuler(y=-24.0), wl.weapon_q)
    limp.ik = {'L': 0.0, 'R': 0.0}
    limp.wrist['L'] = np.array([0.36, 0.075, 0.3])
    limp.hand_q['L'] = hand_rot('L', x=(0.0, 0.0, -1.0), y=(0.3, 1.0, 0.0), z=(1.0, -0.2, 0.2))
    limp.wrist['R'] = np.array([-0.4, 0.075, 0.36])
    limp.elbow_pole['R'] = np.array([-0.9, 0.5, 0.0])
    limp.ankle['L'] = np.array([0.3, 0.2, -1.04])
    limp.ankle['R'] = np.array([-0.26, 0.2, -1.08])
    limp.foot_q['L'] = qmul(qeuler(y=30.0), qeuler(x=74.0))
    limp.foot_q['R'] = qmul(qeuler(y=-14.0), qeuler(x=80.0))
    limp.visor = 0.0
    fade = lerp_spec(bake_hand_keys(cls, [(0, spasm)])[0][1], limp, 0.5)
    fade.visor = 0.3
    keys = [(0, pr), (6, spasm), (16, fade), (30, limp), (39, limp)]
    return keyed(cls, 'death', keys, 40, report=report, easing=[ease_out, ease, ease_out, ease])


ORDER = (['idle'] + [f'walk_{d}' for d in DIRS] + [f'run_{d}' for d in DIRS]
         + ['dash_f', 'dash_b', 'dash_l', 'dash_r', 'fire', 'flinch_f', 'flinch_b', 'down', 'downed', 'revive', 'death'])


def all_clips(cls):
    """Every clip of a class in file order, plus the gate numbers: foot drift per locomotion clip (m per stride) and
    the worst IK reach error per clip (m)."""
    clips, drift, ik = [], {}, {}
    for name in ORDER:
        rep = []
        if name == 'idle':
            c = idle(cls, rep)
        elif name.startswith('walk_') or name.startswith('run_'):
            kind, d = name.split('_')
            c = gait(cls, kind, d, rep, drift)
        elif name.startswith('dash_'):
            c = dash(cls, name[5:], rep)
        elif name == 'fire':
            c = fire(cls, rep)
        elif name.startswith('flinch_'):
            c = flinch(cls, name[7:], rep)
        else:
            c = {'down': down, 'downed': downed, 'revive': revive, 'death': death}[name](cls, rep)
        clips.append(c)
        ik[name] = max([e for _, e in rep] + [0.0])
    return clips, drift, ik
