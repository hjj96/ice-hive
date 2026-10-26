"""The marines' shared skeleton (WP4 «Отряд») — numpy only, no Blender: bone table, bind pose, quaternion helpers,
forward kinematics and the analytic 2-bone IK every clip and the app's MarineRig use.

GAME SPACE (ihv.py): metres, y up, the marine faces +z, origin on the deck between the feet. +x is the marine's LEFT
side: the core spawns bolts at muzzle = feet + aim·0.95 + left·0.22 (IceHiveCore muzzlePosition), so every weapon is
shouldered on the left (gun hand = hand_L on the rear grip, support hand = hand_R on the foregrip).

BIND POSE: every bone's rest rotation is the identity (its local axes are the model axes), so a bone's bind
transform is a pure translation and the inverse bind matrix is −position. Arms hang in a 50° A-pose, legs straight;
the weapon sits where it is held in the aim stance (in front of the chest), so nothing touches in the bind pose
(clean high → low bakes).

32 bones (one 512-byte track row: 32 × half4 rotation + half4 translation): the deforming skeleton, the weapon and
its spinning part, secondary armour (pauldrons, tassets, backpack, antenna) and `ctrl`, a curve carrier with no
vertices: its translation holds the per-frame IK weight of the gun hand (x) and support hand (y) and the plant weight
of the left foot (z); its translation w (the track's scale slot) the plant weight of the right foot; its rotation x
the visor glow multiplier (1 = lit; death fades it). The app reads them per frame (MarineRig.swift).
"""
import numpy as np

# name, parent, bind position (model space)
BONES = [
    ('root', -1, (0.0, 0.0, 0.0)),
    ('pelvis', 0, (0.0, 1.00, 0.0)),
    ('spine1', 1, (0.0, 1.12, -0.012)),
    ('spine2', 2, (0.0, 1.25, -0.016)),
    ('chest', 3, (0.0, 1.38, -0.012)),
    ('neck', 4, (0.0, 1.62, -0.005)),
    ('head', 5, (0.0, 1.705, 0.02)),
    ('clav_L', 4, (0.075, 1.565, -0.012)),
    ('upperarm_L', 7, (0.255, 1.545, -0.02)),
    ('forearm_L', 8, None),          # filled from the A-pose below
    ('hand_L', 9, None),
    ('clav_R', 4, (-0.075, 1.565, -0.012)),
    ('upperarm_R', 11, (-0.255, 1.545, -0.02)),
    ('forearm_R', 12, None),
    ('hand_R', 13, None),
    ('thigh_L', 1, (0.12, 0.97, 0.0)),
    ('shin_L', 15, (0.125, 0.53, 0.022)),
    ('foot_L', 16, (0.13, 0.115, -0.018)),
    ('toe_L', 17, (0.13, 0.035, 0.150)),
    ('thigh_R', 1, (-0.12, 0.97, 0.0)),
    ('shin_R', 19, (-0.125, 0.53, 0.022)),
    ('foot_R', 20, (-0.13, 0.115, -0.018)),
    ('toe_R', 21, (-0.13, 0.035, 0.150)),
    ('weapon', 4, None),             # per class (the gun hand's grip in the aim stance)
    ('weapon_aux', 23, None),        # per class: gunner barrels, cryo coils, pyro igniter
    ('pauldron_L', 7, (0.265, 1.625, -0.02)),
    ('pauldron_R', 11, (-0.265, 1.625, -0.02)),
    ('backpack', 4, (0.0, 1.43, -0.215)),
    ('antenna', 27, (0.135, 1.655, -0.33)),
    ('tasset_L', 1, (0.125, 1.005, 0.115)),
    ('tasset_R', 1, (-0.125, 1.005, 0.115)),
    ('ctrl', 0, (0.0, 0.0, 0.0)),
]
NAMES = [b[0] for b in BONES]
IDX = {n: k for k, n in enumerate(NAMES)}
PARENT = [b[1] for b in BONES]
NB = len(BONES)
assert NB == 32

UPPERARM, FOREARM, HAND = 0.30, 0.285, 0.105
ARM_DOWN = np.radians(50.0)          # A-pose: the arms 50° below the horizontal, slightly forward
HAND_SCALE = 1.12                    # the gauntleted fists (marines.hand_canonical) and their grip offsets (motion.grip_frames)


def arm_dirs(side):
    """Bind directions of the upper arm and the forearm (the elbow bent 14° forward, so the bend plane is defined)."""
    s = 1.0 if side == 'L' else -1.0
    d1 = np.array([s * np.cos(ARM_DOWN), -np.sin(ARM_DOWN), 0.05])
    d1 /= np.linalg.norm(d1)
    a = np.radians(14.0)
    d2 = d1 * np.cos(a) + np.array([0.0, 0.0, 1.0]) * np.sin(a)
    d2 -= 0.0
    d2 /= np.linalg.norm(d2)
    return d1, d2


def _arm(side):
    s = 1.0 if side == 'L' else -1.0
    sh = np.array([s * 0.255, 1.545, -0.02])
    d1, d2 = arm_dirs(side)
    el = sh + d1 * UPPERARM
    wr = el + d2 * FOREARM
    return el, wr


# per-class weapon bind (the gun hand's grip point in the aim stance) and its aux part, both model space
# (the weapons ride low, at the chest / hip, bore ≈ 1.2 m: the core's muzzle is 0.95 m ahead, 0.22 m left and the
# effects emit at 1.15–1.2 m)
WEAPON = {
    'assault': dict(grip=(0.215, 1.15, 0.24), aux=(0.215, 1.215, 0.60)),
    'pyro':    dict(grip=(0.235, 1.075, 0.19), aux=(0.225, 1.155, 0.90)),
    'cryo':    dict(grip=(0.22, 1.13, 0.22), aux=(0.22, 1.21, 0.62)),
    'gunner':  dict(grip=(0.26, 1.04, 0.13), aux=(0.245, 1.14, 0.60)),
}


def bind_positions(cls):
    """(32, 3) model-space bind positions of every bone for a class (the weapon differs)."""
    P = np.zeros((NB, 3))
    elL, wrL = _arm('L')
    elR, wrR = _arm('R')
    fill = {'forearm_L': elL, 'hand_L': wrL, 'forearm_R': elR, 'hand_R': wrR,
            'weapon': WEAPON[cls]['grip'], 'weapon_aux': WEAPON[cls]['aux']}
    for k, (n, _, p) in enumerate(BONES):
        P[k] = fill[n] if n in fill else p
    return P


def bind_local(cls):
    """Bone-local bind translations (rotations are all identity)."""
    P = bind_positions(cls)
    return np.array([P[k] - (P[PARENT[k]] if PARENT[k] >= 0 else 0.0) for k in range(NB)])


# ---------------------------------------------------------------- quaternions (x, y, z, w), Hamilton, like ihv._qmat
def qmul(a, b):
    ax, ay, az, aw = a[..., 0], a[..., 1], a[..., 2], a[..., 3]
    bx, by, bz, bw = b[..., 0], b[..., 1], b[..., 2], b[..., 3]
    return np.stack([aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
                     aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz], -1)


def qconj(q):
    return q * np.array([-1.0, -1.0, -1.0, 1.0])


def qnorm(q):
    return q / np.maximum(np.linalg.norm(q, axis=-1, keepdims=True), 1e-12)


def qaxis(axis, ang):
    a = np.asarray(axis, dtype=np.float64)
    a = a / max(np.linalg.norm(a), 1e-12)
    s = np.sin(ang * 0.5)
    return np.array([a[0] * s, a[1] * s, a[2] * s, np.cos(ang * 0.5)])


def qeuler(x=0.0, y=0.0, z=0.0, order='YXZ'):
    """Degrees; applied in `order` (intrinsic, first letter outermost): YXZ = yaw, then pitch, then roll."""
    q = np.array([0.0, 0.0, 0.0, 1.0])
    ax = {'X': (1, 0, 0), 'Y': (0, 1, 0), 'Z': (0, 0, 1)}
    ang = {'X': x, 'Y': y, 'Z': z}
    for c in order:
        q = qmul(q, qaxis(ax[c], np.radians(ang[c])))
    return q


def qmat(q):
    x, y, z, w = qnorm(np.asarray(q, dtype=np.float64))
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def mat2q(m):
    """Rotation matrix → unit quaternion (x, y, z, w), w ≥ 0."""
    t = np.trace(m)
    if t > 0:
        s = np.sqrt(t + 1.0) * 2
        q = np.array([(m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s, 0.25 * s])
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = np.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        q = np.array([0.25 * s, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s, (m[2, 1] - m[1, 2]) / s])
    elif m[1, 1] > m[2, 2]:
        s = np.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        q = np.array([(m[0, 1] + m[1, 0]) / s, 0.25 * s, (m[1, 2] + m[2, 1]) / s, (m[0, 2] - m[2, 0]) / s])
    else:
        s = np.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
        q = np.array([(m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, 0.25 * s, (m[1, 0] - m[0, 1]) / s])
    q = qnorm(q)
    return -q if q[3] < 0 else q


def qrotate(q, v):
    return qmat(q) @ np.asarray(v, dtype=np.float64)


def qslerp(a, b, t):
    a, b = qnorm(a), qnorm(b)
    d = float(np.dot(a, b))
    if d < 0:
        b, d = -b, -d
    if d > 0.9995:
        return qnorm(a + (b - a) * t)
    th = np.arccos(d)
    return (np.sin((1 - t) * th) * a + np.sin(t * th) * b) / np.sin(th)


def qbetween(u, v):
    """Shortest-arc rotation taking direction u onto v."""
    u = np.asarray(u, dtype=np.float64) / max(np.linalg.norm(u), 1e-12)
    v = np.asarray(v, dtype=np.float64) / max(np.linalg.norm(v), 1e-12)
    d = float(np.dot(u, v))
    if d < -0.999999:
        a = np.cross(u, (1.0, 0.0, 0.0))
        if np.linalg.norm(a) < 1e-6:
            a = np.cross(u, (0.0, 1.0, 0.0))
        return qaxis(a, np.pi)
    c = np.cross(u, v)
    return qnorm(np.array([c[0], c[1], c[2], 1.0 + d]))


# ---------------------------------------------------------------- pose
class Pose:
    """Bone-local rotations (32, 4) and translations (32, 3), starting at the bind pose of a class."""

    def __init__(self, cls):
        self.cls = cls
        self.bind = bind_local(cls)
        self.q = np.tile(np.array([0.0, 0.0, 0.0, 1.0]), (NB, 1))
        self.t = self.bind.copy()
        self.s = np.ones(NB)                 # the track's w slot (ctrl: right-foot plant)
        self.ctrl(1.0, 1.0, 0.0, 0.0, 1.0)

    def copy(self):
        p = Pose.__new__(Pose)
        p.cls, p.bind, p.q, p.t, p.s = self.cls, self.bind, self.q.copy(), self.t.copy(), self.s.copy()
        return p

    def ctrl(self, ik_gun, ik_sup, plant_l, plant_r, visor):
        k = IDX['ctrl']
        self.t[k] = (ik_gun, ik_sup, plant_l)
        self.s[k] = plant_r
        self.q[k] = (visor, 0.0, 0.0, 1.0)   # not a rotation: a curve (never normalised by the app)

    def rot(self, name, q):
        self.q[IDX[name]] = qnorm(q)

    def turn(self, name, q):
        """Pre-multiply a bone's local rotation (rotate about the parent's axes)."""
        k = IDX[name]
        self.q[k] = qnorm(qmul(q, self.q[k]))

    def world(self):
        """Model-space rotations (32, 4) and positions (32, 3)."""
        WQ = np.zeros((NB, 4))
        WP = np.zeros((NB, 3))
        for k in range(NB):
            p = PARENT[k]
            q = self.q[k] if NAMES[k] != 'ctrl' else np.array([0.0, 0.0, 0.0, 1.0])
            if p < 0:
                WQ[k] = qnorm(q)
                WP[k] = self.t[k]
            else:
                WQ[k] = qnorm(qmul(WQ[p], q))
                WP[k] = WP[p] + qrotate(WQ[p], self.t[k])
        return WQ, WP

    def set_world_rot(self, name, wq, WQ=None):
        """Give bone `name` the model-space rotation wq (its parent's from WQ / a fresh FK)."""
        if WQ is None:
            WQ, _ = self.world()
        k = IDX[name]
        p = PARENT[k]
        self.q[k] = qnorm(qmul(qconj(WQ[p]), wq)) if p >= 0 else qnorm(wq)

    def track_row(self):
        """(32, 2, 4): rotation xyzw, translation xyz + w (scale slot)."""
        r = np.zeros((NB, 2, 4))
        r[:, 0] = self.q
        r[:, 1, :3] = self.t
        r[:, 1, 3] = self.s
        return r


def two_bone(A, B, C, T, pole, l1=None, l2=None):
    """Analytic 2-bone IK: joints A (root), B (middle), C (end) and a target T; the middle joint bends toward `pole`.
    Returns the new B, C positions (C = T when reachable) and the reach error (m)."""
    A, B, C, T, pole = (np.asarray(v, dtype=np.float64) for v in (A, B, C, T, pole))
    l1 = np.linalg.norm(B - A) if l1 is None else l1
    l2 = np.linalg.norm(C - B) if l2 is None else l2
    v = T - A
    d0 = np.linalg.norm(v)
    d = np.clip(d0, abs(l1 - l2) + 1e-4, l1 + l2 - 1e-4)
    err = max(0.0, d0 - (l1 + l2 - 1e-4)) + max(0.0, abs(l1 - l2) + 1e-4 - d0)
    dirv = v / max(d0, 1e-9)
    ca = np.clip((l1 * l1 + d * d - l2 * l2) / (2 * l1 * d), -1, 1)
    pv = pole - A
    perp = pv - dirv * np.dot(pv, dirv)
    if np.linalg.norm(perp) < 1e-6:
        perp = np.cross(dirv, (1.0, 0.0, 0.0))
    perp /= np.linalg.norm(perp)
    Bn = A + dirv * (l1 * ca) + perp * (l1 * np.sqrt(1 - ca * ca))
    Cn = A + dirv * d
    return Bn, Cn, err


def aim_bone(pose, name, child_name, target_dir, WQ, WP):
    """Rotate bone `name` (shortest arc, in model space) so its child joint points along target_dir."""
    k, c = IDX[name], IDX[child_name]
    cur = WP[c] - WP[k]
    dq = qbetween(cur, target_dir)
    pose.set_world_rot(name, qmul(dq, WQ[k]), WQ)


def solve_limb(pose, a, b, c, target, pole, end_rot=None):
    """2-bone IK on bones a → b → c (c's origin is the end joint) to `target`; optional model-space rotation of c.
    Returns the reach error."""
    WQ, WP = pose.world()
    A, B, C = WP[IDX[a]], WP[IDX[b]], WP[IDX[c]]
    Bn, Cn, err = two_bone(A, B, C, target, pole)
    # upper bone: rotate so that its child lands on Bn while the bend plane holds the pole (two shortest arcs: the
    # bone direction, then a twist about it bringing the old bend plane onto the new one)
    n_old = np.cross(B - A, C - B)
    q1 = qbetween(B - A, Bn - A)
    n_mid = qrotate(q1, n_old)
    n_new = np.cross(Bn - A, Cn - Bn)
    axis = (Bn - A) / np.linalg.norm(Bn - A)
    if np.linalg.norm(n_mid) > 1e-6 and np.linalg.norm(n_new) > 1e-6:
        u = n_mid - axis * np.dot(n_mid, axis)
        w = n_new - axis * np.dot(n_new, axis)
        if np.linalg.norm(u) > 1e-6 and np.linalg.norm(w) > 1e-6:
            u /= np.linalg.norm(u)
            w /= np.linalg.norm(w)
            ang = np.arctan2(np.dot(np.cross(u, w), axis), np.dot(u, w))
            q1 = qmul(qaxis(axis, ang), q1)
    pose.set_world_rot(a, qmul(q1, WQ[IDX[a]]), WQ)
    WQ, WP = pose.world()
    aim_bone(pose, b, c, Cn - WP[IDX[b]], WQ, WP)
    if end_rot is not None:
        WQ, WP = pose.world()
        pose.set_world_rot(c, end_rot, WQ)
    WQ, WP = pose.world()
    return float(np.linalg.norm(WP[IDX[c]] - target)) if err == 0 else err
