"""Retarget of a sampled source skeleton (bvhsrc.load / load_glb_action) onto the shared 32-bone marine skeleton
(skeleton.py) — numpy only (it runs inside the Blender build process, but touches no bpy).

  Source      the sampled take, faced along +z (+x = its left) by its rest hips; optionally mirrored (left ↔ right)
  transfer    world-delta rotation transfer with a rest-frame alignment per target bone (handles the CMU splayed-leg
              rest and T- vs A-pose arms), pelvis path and the source's ankles / balls scaled by leg length, floor
              and ankle-height offset, relative to a root: a constant-velocity line (locomotion loops: planted feet
              then move at exactly −v, what the runtime's distance-driven phase expects), the first frame or the mean
  blade       the class's aim stance (motion.STYLE blade / hunch) over pelvis → spine → chest → neck
  warp        stride warp: the feet's horizontal offsets from the pelvis × w (a longer reach at the same cadence)
  direct      a forward / backward loop turned toward another travel direction: the legs follow the travel, the hips
              turn part of the way, spine and chest twist back to the aim
  plants      foot contacts from the scaled source balls (low and slow in the root-moving frame), cyclic for loops
  close_loop  the clip sampled with one extra frame (= the frame after the loop's end): the end-to-start residual
              spread linearly over the clip (rotations by slerp, positions by lerp), then the extra frame dropped
  finalize    target ankles (planted balls held at their contact average — the lock pass —, every sole on or above
              the deck, a planted sole's lowest point exactly on it), the pelvis lowered where a leg could not reach
              (IK error stays 0), 2-bone leg IK, the weapon carried by the chest at the stance offset and stabilised
              toward the aim, both hands on the grips by the rig's own 2-bone IK (motion.grip_frames,
              skeleton.solve_limb), pauldrons / tassets (motion.follow), ctrl = IK weights + plants
  Every step is a pure function of the samples: the build is deterministic (the md5 gate)."""
import numpy as np

import motion as MO
import skeleton as S
from skeleton import IDX, NAMES, PARENT, qaxis, qconj, qmul, qnorm, qrotate, qslerp

UPV = np.array([0.0, 1.0, 0.0])
QI = np.array([0.0, 0.0, 0.0, 1.0])

# target bone -> (source bone for the rotation, joint A, joint B for the rest primary direction, secondary hint)
MAP = {
    '100style': dict(
        pelvis=('Hips', 'Hips', 'Chest', 'left'), spine1=('Chest', 'Chest', 'Chest2', 'left'),
        spine2=('Chest2', 'Chest2', 'Chest3', 'left'), chest=('Chest4', 'Chest4', 'Neck', 'left'),
        neck=('Neck', 'Neck', 'Head', 'left'), head=('Head', 'Neck', 'Head', 'left'),
        clav_L=('LeftCollar', 'LeftCollar', 'LeftShoulder', 'fwd'), upperarm_L=('LeftShoulder', 'LeftShoulder', 'LeftElbow', 'fwd'),
        forearm_L=('LeftElbow', 'LeftElbow', 'LeftWrist', 'fwd'), hand_L=('LeftWrist', 'LeftElbow', 'LeftWrist', 'fwd'),
        clav_R=('RightCollar', 'RightCollar', 'RightShoulder', 'fwd'), upperarm_R=('RightShoulder', 'RightShoulder', 'RightElbow', 'fwd'),
        forearm_R=('RightElbow', 'RightElbow', 'RightWrist', 'fwd'), hand_R=('RightWrist', 'RightElbow', 'RightWrist', 'fwd'),
        thigh_L=('LeftHip', 'LeftHip', 'LeftKnee', 'left'), shin_L=('LeftKnee', 'LeftKnee', 'LeftAnkle', 'left'),
        foot_L=('LeftAnkle', 'LeftAnkle', 'LeftToe', 'left'), toe_L=('LeftToe', 'LeftAnkle', 'LeftToe', 'left'),
        thigh_R=('RightHip', 'RightHip', 'RightKnee', 'left'), shin_R=('RightKnee', 'RightKnee', 'RightAnkle', 'left'),
        foot_R=('RightAnkle', 'RightAnkle', 'RightToe', 'left'), toe_R=('RightToe', 'RightAnkle', 'RightToe', 'left'),
        _legs=dict(L=('LeftHip', 'LeftAnkle', 'LeftToe'), R=('RightHip', 'RightAnkle', 'RightToe')),
    ),
    'cmu': dict(
        pelvis=('Hips', 'Hips', 'Spine', 'left'), spine1=('LowerBack', 'Hips', 'Spine', 'left'),
        spine2=('Spine', 'Spine', 'Neck1', 'left'), chest=('Spine1', 'Spine', 'Neck1', 'left'),
        neck=('Neck', 'Neck', 'Head', 'left'), head=('Head', 'Neck1', 'Head', 'left'),
        clav_L=('LeftShoulder', 'LeftShoulder', 'LeftArm', 'fwd'), upperarm_L=('LeftArm', 'LeftArm', 'LeftForeArm', 'fwd'),
        forearm_L=('LeftForeArm', 'LeftForeArm', 'LeftHand', 'fwd'), hand_L=('LeftHand', 'LeftForeArm', 'LeftHand', 'fwd'),
        clav_R=('RightShoulder', 'RightShoulder', 'RightArm', 'fwd'), upperarm_R=('RightArm', 'RightArm', 'RightForeArm', 'fwd'),
        forearm_R=('RightForeArm', 'RightForeArm', 'RightHand', 'fwd'), hand_R=('RightHand', 'RightForeArm', 'RightHand', 'fwd'),
        thigh_L=('LeftUpLeg', 'LeftUpLeg', 'LeftLeg', 'left'), shin_L=('LeftLeg', 'LeftLeg', 'LeftFoot', 'left'),
        foot_L=('LeftFoot', 'LeftFoot', 'LeftToeBase', 'left'), toe_L=('LeftToeBase', 'LeftFoot', 'LeftToeBase', 'left'),
        thigh_R=('RightUpLeg', 'RightUpLeg', 'RightLeg', 'left'), shin_R=('RightLeg', 'RightLeg', 'RightFoot', 'left'),
        foot_R=('RightFoot', 'RightFoot', 'RightToeBase', 'left'), toe_R=('RightToeBase', 'RightFoot', 'RightToeBase', 'left'),
        _legs=dict(L=('LeftUpLeg', 'LeftFoot', 'LeftToeBase'), R=('RightUpLeg', 'RightFoot', 'RightToeBase')),
    ),
    'ual': dict(
        pelvis=('DEF-hips', 'DEF-hips', 'DEF-spine.001', 'left'), spine1=('DEF-spine.001', 'DEF-spine.001', 'DEF-spine.002', 'left'),
        spine2=('DEF-spine.002', 'DEF-spine.002', 'DEF-spine.003', 'left'), chest=('DEF-spine.003', 'DEF-spine.003', 'DEF-neck', 'left'),
        neck=('DEF-neck', 'DEF-neck', 'DEF-head', 'left'), head=('DEF-head', 'DEF-neck', 'DEF-head', 'left'),
        clav_L=('DEF-shoulder.L', 'DEF-shoulder.L', 'DEF-upper_arm.L', 'fwd'), upperarm_L=('DEF-upper_arm.L', 'DEF-upper_arm.L', 'DEF-forearm.L', 'fwd'),
        forearm_L=('DEF-forearm.L', 'DEF-forearm.L', 'DEF-hand.L', 'fwd'), hand_L=('DEF-hand.L', 'DEF-forearm.L', 'DEF-hand.L', 'fwd'),
        clav_R=('DEF-shoulder.R', 'DEF-shoulder.R', 'DEF-upper_arm.R', 'fwd'), upperarm_R=('DEF-upper_arm.R', 'DEF-upper_arm.R', 'DEF-forearm.R', 'fwd'),
        forearm_R=('DEF-forearm.R', 'DEF-forearm.R', 'DEF-hand.R', 'fwd'), hand_R=('DEF-hand.R', 'DEF-forearm.R', 'DEF-hand.R', 'fwd'),
        thigh_L=('DEF-thigh.L', 'DEF-thigh.L', 'DEF-shin.L', 'left'), shin_L=('DEF-shin.L', 'DEF-shin.L', 'DEF-foot.L', 'left'),
        foot_L=('DEF-foot.L', 'DEF-foot.L', 'DEF-toe.L', 'left'), toe_L=('DEF-toe.L', 'DEF-foot.L', 'DEF-toe.L', 'left'),
        thigh_R=('DEF-thigh.R', 'DEF-thigh.R', 'DEF-shin.R', 'left'), shin_R=('DEF-shin.R', 'DEF-shin.R', 'DEF-foot.R', 'left'),
        foot_R=('DEF-foot.R', 'DEF-foot.R', 'DEF-toe.R', 'left'), toe_R=('DEF-toe.R', 'DEF-foot.R', 'DEF-toe.R', 'left'),
        _legs=dict(L=('DEF-thigh.L', 'DEF-foot.L', 'DEF-toe.L'), R=('DEF-thigh.R', 'DEF-foot.R', 'DEF-toe.R')),
    ),
}
# (the clavicles are not transferred: the hands are on the weapon, and a free-arm swing's shoulder roll would pull
# the grips out of reach — they stay in the chest's frame as in the procedural stance; nor are the toes: a capture's
# toe joint is mostly marker noise and its rest differs per take — finalize keeps a planted boot's toe flat on the
# deck and lets a free one follow its foot)
BONES = [k for k in MAP['cmu'] if not k.startswith('_') and not k.startswith(('clav', 'toe'))]
TARGET_CHILD = dict(pelvis='spine1', spine1='spine2', spine2='chest', chest='neck', neck='head', clav_L='upperarm_L',
                    upperarm_L='forearm_L', forearm_L='hand_L', clav_R='upperarm_R', upperarm_R='forearm_R',
                    forearm_R='hand_R', thigh_L='shin_L', shin_L='foot_L', foot_L='toe_L', thigh_R='shin_R',
                    shin_R='foot_R', foot_R='toe_R')
UPPER = ('spine1', 'spine2', 'chest', 'neck', 'head', 'upperarm_L', 'forearm_L', 'hand_L', 'upperarm_R', 'forearm_R',
         'hand_R')
TOE_OFF = np.array(S.BONES[IDX['toe_L']][2]) - np.array(S.BONES[IDX['foot_L']][2])   # ankle → ball at bind
# sole corners of the boot (marines.py; the mesh's sole is ±0.09 wide): heel and ball relative to the ankle in the
# foot's frame, the toe cap's tip relative to the toe joint in the toe's frame (motion.floor_ankle, with the width)
SOLE_HEEL = [np.array([x, -0.112, -0.14]) for x in (-0.08, 0.08)]
SOLE_BALL = [TOE_OFF + np.array([x, -MO.BALL_Y, 0.0]) for x in (-0.08, 0.08)]
SOLE_TIP = [np.array([x, -MO.BALL_Y + 0.002, 0.105]) for x in (-0.08, 0.08)]


def unit(v):
    v = np.asarray(v, dtype=np.float64)
    return v / max(np.linalg.norm(v), 1e-12)


def frame(primary, hint):
    """Rotation matrix whose column 1 (y) is `primary` and column 0 (x) is `hint` made orthogonal."""
    y = unit(primary)
    x = np.asarray(hint, dtype=np.float64) - y * np.dot(hint, y)
    if np.linalg.norm(x) < 1e-6:
        x = np.cross(y, (0.0, 0.0, 1.0))
    x = unit(x)
    z = np.cross(x, y)
    return np.stack([x, y, z], 1)


def yaw_mat(a):
    c, s = np.cos(a), np.sin(a)
    return np.array([[c, 0.0, s], [0.0, 1.0, 0.0], [-s, 0.0, c]])


def yaw_q(a):
    return qaxis((0.0, 1.0, 0.0), a)


def qmul_n(a, b):
    """Row-wise quaternion product (n,4)·(n,4) or (4,)·(n,4), normalised."""
    return qnorm(qmul(np.asarray(a, dtype=np.float64), np.asarray(b, dtype=np.float64)))


def target_rest_dirs(cls):
    P = S.bind_positions(cls)
    d = {}
    for k, c in TARGET_CHILD.items():
        d[k] = unit(P[IDX[c]] - P[IDX[k]])
    d['head'] = np.array([0.0, 1.0, 0.0])
    d['hand_L'] = d['forearm_L']
    d['hand_R'] = d['forearm_R']
    d['toe_L'] = np.array([0.0, 0.0, 1.0])
    d['toe_R'] = np.array([0.0, 0.0, 1.0])
    return d


def _mirror_name(n):
    for a, b in (('Left', 'Right'), ('Right', 'Left'), ('.L', '.R'), ('.R', '.L')):
        if a in n:
            return n.replace(a, b)
    return n


class Source:
    """A sampled take faced along +z by its rest hips (+x = its left); `mirror`: reflected through its sagittal plane
    with left and right swapped (a left-foot-first clip becomes a right-foot one and vice versa)."""

    def __init__(self, d, kind, mirror=False):
        self.kind, self.M, self.fps = kind, MAP[kind], d['fps']
        names = d['names']
        ix = {n: k for k, n in enumerate(names)}
        legs = self.M['_legs']
        rp = d['rest_P']
        left = rp[ix[legs['L'][0]]] - rp[ix[legs['R'][0]]]
        left[1] = 0.0
        fwd = np.cross(unit(left), UPV)
        Y0 = yaw_mat(-np.arctan2(fwd[0], fwd[2]))
        R = np.einsum('ij,tnjk->tnik', Y0, d['R'])
        P = np.einsum('ij,tnj->tni', Y0, d['P'])
        rR = np.einsum('ij,njk->nik', Y0, d['rest_R'])
        rP = rp @ Y0.T
        if mirror:
            Mx = np.diag([-1.0, 1.0, 1.0])
            perm = np.array([ix.get(_mirror_name(n), k) for k, n in enumerate(names)])
            R = np.einsum('ij,tnjk,kl->tnil', Mx, R[:, perm], Mx)
            P = P[:, perm] * np.array([-1.0, 1.0, 1.0])
            rR = np.einsum('ij,njk,kl->nil', Mx, rR[perm], Mx)
            rP = rP[perm] * np.array([-1.0, 1.0, 1.0])
        self.R, self.P, self.rest_R, self.rest_P, self.ix = R, P, rR, rP, ix
        self.leg = 0.5 * sum(np.linalg.norm(rP[ix[legs[s][1]]] - rP[ix[legs[s][0]]]) for s in 'LR')

    def joint(self, name):
        return self.ix[name]

    def hips(self):
        legs = self.M['_legs']
        return 0.5 * (self.P[:, self.joint(legs['L'][0])] + self.P[:, self.joint(legs['R'][0])])

    def facing(self):
        """Per-frame facing yaw (rad) from the hip line."""
        legs = self.M['_legs']
        left = self.P[:, self.joint(legs['L'][0])] - self.P[:, self.joint(legs['R'][0])]
        return np.arctan2(-left[:, 2], left[:, 0])


class Take:
    """A clip being built: world rotations of the mapped target bones, pelvis joint path, the source's scaled ankles /
    balls (model space, relative to the root), root velocity, contacts."""

    def __init__(self, n, fps):
        self.n, self.fps = n, fps
        self.W = {}
        self.pelvis = np.zeros((n, 3))
        self.ankle = np.zeros((n, 2, 3))
        self.ball = np.zeros((n, 2, 3))
        self.vel = np.zeros(3)
        self.plant = np.zeros((n, 2))
        self.scale = 1.0
        self.aim = None             # per-frame aim yaw (rad) for the weapon's stabilisation; None = +z
        self.meta = {}

    def rows(self, sl):
        t = Take(len(range(self.n)[sl]), self.fps)
        t.W = {k: v[sl].copy() for k, v in self.W.items()}
        t.pelvis, t.ankle, t.ball, t.plant = self.pelvis[sl].copy(), self.ankle[sl].copy(), self.ball[sl].copy(), self.plant[sl].copy()
        t.vel, t.scale, t.meta = self.vel.copy(), self.scale, dict(self.meta)
        t.aim = None if self.aim is None else self.aim[sl].copy()
        return t


def transfer(src, cls, yaw=0.0, root='line'):
    """Source → Take (see the module docstring). `yaw`: extra rotation about +y of the whole take (its travel /
    facing onto +z); root 'line' | 'start' | 'mean'."""
    Ya = yaw_mat(yaw)
    R = np.einsum('ij,tnjk->tnik', Ya, src.R)
    P = np.einsum('ij,tnj->tni', Ya, src.P)
    n = len(R)
    restR, restP = src.rest_R, src.rest_P
    tdir = target_rest_dirs(cls)
    LEFT, FWD = np.array([1.0, 0.0, 0.0]), np.array([0.0, 0.0, 1.0])
    A = {}
    for tb in BONES:
        sb, ja, jb, hint = src.M[tb]
        h = LEFT if hint == 'left' else FWD
        sd = FWD.copy() if tb in ('toe_L', 'toe_R') else restP[src.joint(jb)] - restP[src.joint(ja)]
        A[tb] = frame(sd, h) @ frame(tdir[tb], h).T
    legs = src.M['_legs']
    bp = S.bind_positions(cls)
    s = np.linalg.norm(bp[IDX['foot_L']] - bp[IDX['thigh_L']]) / src.leg
    hipc = 0.5 * (P[:, src.joint(legs['L'][0])] + P[:, src.joint(legs['R'][0])])
    ankle = np.stack([P[:, src.joint(legs[sd][1])] for sd in 'LR'], 1)
    ball = np.stack([P[:, src.joint(legs[sd][2])] for sd in 'LR'], 1)
    floor = float(np.percentile(np.minimum(ankle[:, :, 1], ball[:, :, 1]).min(1), 3))
    src_ank_h = float(np.percentile(ankle[:, :, 1].ravel() - floor, 5))
    dy = bp[IDX['foot_L']][1] - s * src_ank_h
    tt = np.arange(n) / src.fps
    if root == 'line':
        A_ = np.c_[tt, np.ones(n)]
        cx = np.linalg.lstsq(A_, hipc[:, 0], rcond=None)[0]
        cz = np.linalg.lstsq(A_, hipc[:, 2], rcond=None)[0]
        rootp = np.stack([cx[0] * tt + cx[1], np.zeros(n), cz[0] * tt + cz[1]], 1)
        vel = np.array([cx[0], 0.0, cz[0]]) * s
    else:
        c = hipc[0] if root == 'start' else hipc.mean(0)
        rootp = np.tile(np.array([c[0], 0.0, c[2]]), (n, 1))
        vel = np.zeros(3)
    T = Take(n, src.fps)
    T.scale, T.vel = s, vel
    for tb in BONES:
        j = src.joint(src.M[tb][0])
        Dw = np.einsum('tij,kj->tik', R[:, j], restR[j])          # world delta from the source rest
        T.W[tb] = np.stack([S.mat2q(m) for m in np.einsum('tij,jk->tik', Dw, A[tb])])

    def scaled(X):
        Y = s * (X - rootp[:, None, :] if X.ndim == 3 else X - rootp)
        Y[..., 1] = s * (X[..., 1] - floor) + dy
        return Y

    hc = scaled(hipc)
    T.pelvis = hc + np.stack([qrotate(q, (0.0, 0.03, 0.0)) for q in T.W['pelvis']])
    T.ankle = scaled(ankle)
    T.ball = scaled(ball)
    return T


def blade(T, cls):
    """The class's aim stance over the mocap torso: pelvis → spine → chest bladed toward the gun side, the hunch."""
    st = MO.STYLE[cls]
    bl, hunch = st['blade'], 6.0 + st['hunch']
    for tb, fy, fx in (('pelvis', 0.35, 0.0), ('spine1', 0.57, 0.33), ('spine2', 0.78, 0.66), ('chest', 1.0, 1.0),
                       ('neck', 0.5, 0.5)):
        T.W[tb] = qmul_n(S.qeuler(y=bl * fy, x=hunch * fx), T.W[tb])


def _fwd_angles(Q, ref):
    """Yaw relative to ref and pitch (+ = down) of each world rotation's forward axis (rad)."""
    f = np.stack([qrotate(q, (0.0, 0.0, 1.0)) for q in Q])
    return wrap(np.arctan2(f[:, 0], f[:, 2]) - ref), np.arcsin(np.clip(-f[:, 1], -1.0, 1.0))


def posture(T, chest=None, head=None, ref=None):
    """Re-centre the torso / head of a take on the marine's posture, keeping the capture's motion around it:
    `chest` (deg, + = forward): the mean chest pitch moved there (spine1 / spine2 take 1/3, 2/3, neck, head and arms
    the whole); `head` (deg): the mean head pitch moved there and its mean yaw onto the facing (the actor's habit of
    watching the floor or looking over the shoulder at the travel goes; look-around and stabilisation stay). Pitch
    is about each frame's own left axis: `ref` = per-frame facing yaw (rad; default +z)."""
    n = T.n
    ref = np.zeros(n) if ref is None else np.asarray(ref, dtype=np.float64)
    axes = np.stack([np.cos(ref), np.zeros(n), -np.sin(ref)], 1)

    def turn_pitch(names_k, a):
        for tb, k in names_k:
            T.W[tb] = np.stack([qnorm(qmul(qaxis(axes[t], a * k), T.W[tb][t])) for t in range(n)])

    if chest is not None:
        _, p = _fwd_angles(T.W['chest'], ref)
        a = np.radians(chest) - float(np.mean(p))
        turn_pitch([('spine1', 1.0 / 3.0), ('spine2', 2.0 / 3.0), ('neck', 1.0), ('head', 1.0)]
                   + [(b, 1.0) for b in UPPER if b.startswith(('upperarm', 'forearm', 'hand'))] + [('chest', 1.0)], a)
    if head is not None:
        y, p = _fwd_angles(T.W['head'], ref)
        a = np.radians(head) - float(np.mean(p))
        turn_pitch([('neck', 0.5), ('head', 1.0)], a)
        my = float(np.angle(np.mean(np.exp(1j * y))))
        for tb, k in (('neck', 0.5), ('head', 1.0)):
            T.W[tb] = qmul_n(yaw_q(-my * k), T.W[tb])


def warp(T, w):
    """Stride warp: the feet's horizontal offsets from the pelvis × w; the root velocity × w."""
    if w == 1.0:
        return
    for X in (T.ankle, T.ball):
        for k in (0, 2):
            X[:, :, k] = T.pelvis[:, None, k] + (X[:, :, k] - T.pelvis[:, None, k]) * w
    T.vel = T.vel * w


def wrap(a):
    return (a + np.pi) % (2 * np.pi) - np.pi


def direct(T, phi, hip, face=0.0):
    """Turn the take by phi (rad, about +y) toward another travel direction, then turn the hips to `hip` and the upper
    body back to the aim (+z). `face`: the source's own facing relative to its travel (0 forward, π backward, ±π/2
    sideways), so after the turn the body faces phi + face. Pelvis → hip, spine1 / spine2 twist 1/3, 2/3 of the way
    back, chest and above face +z; the thighs keep half the hips' correction (knees between hips and travel)."""
    cur = phi + face
    Yq = yaw_q(phi)
    Ym = yaw_mat(phi)
    for tb in T.W:
        T.W[tb] = qmul_n(Yq, T.W[tb])
    T.pelvis = T.pelvis @ Ym.T
    T.ankle = np.einsum('ij,tsj->tsi', Ym, T.ankle)
    T.ball = np.einsum('ij,tsj->tsi', Ym, T.ball)
    T.vel = Ym @ T.vel
    h = wrap(hip)
    corr = {'pelvis': h - cur, 'spine1': h * 2.0 / 3.0 - cur, 'spine2': h / 3.0 - cur,
            'thigh_L': (h - cur) * 0.5, 'thigh_R': (h - cur) * 0.5}
    for tb in UPPER:
        if tb not in corr:
            corr[tb] = -cur
    for tb, a in corr.items():
        a = wrap(a)
        if abs(a) > 1e-9:
            T.W[tb] = qmul_n(yaw_q(a), T.W[tb])


def detect_plants(T, loop, h_tol=0.045, v_tol=0.45):
    """Contacts: ball low (within h_tol of its 5th-percentile height) and slow (< v_tol m/s) in the root-moving frame;
    one-frame blips removed (cyclically for loops)."""
    n = T.n
    tt = np.arange(n) / T.fps
    wb = T.ball + tt[:, None, None] * T.vel[None, None, :]
    spd = np.zeros((n, 2))
    if loop:
        nxt = np.roll(wb, -1, axis=0)
        nxt[-1] = wb[0] + T.vel * (n / T.fps)
        prv = np.roll(wb, 1, axis=0)
        prv[0] = wb[-1] - T.vel * (n / T.fps)
        spd = 0.5 * np.linalg.norm((nxt - prv)[:, :, [0, 2]], axis=2) * T.fps
    else:
        spd[1:] = np.linalg.norm(np.diff(wb[:, :, [0, 2]], axis=0), axis=2) * T.fps
        spd[0] = spd[1]
    hb = wb[:, :, 1]
    hmin = np.percentile(hb, 5, axis=0)
    c = ((hb < hmin[None, :] + h_tol) & (spd < v_tol)).astype(np.float64)
    for si in range(2):
        x = c[:, si]
        for t in range(n):
            a, b = (t - 1) % n, (t + 1) % n
            if not loop and (t == 0 or t == n - 1):
                continue
            if x[a] == x[b] != x[t]:
                x[t] = x[a]
    T.plant = c


def close_loop(T):
    """Spread the residual between the extra last frame and frame 0 over the clip, drop the extra frame."""
    n = T.n - 1
    u = np.arange(n) / n
    for tb, Q in T.W.items():
        dq = qmul(Q[n], qconj(Q[0]))
        if dq[3] < 0:
            dq = -dq
        inv = qconj(qnorm(dq))
        T.W[tb] = np.stack([qnorm(qmul(qslerp(QI, inv, u[t]), Q[t])) for t in range(n)])
    T.pelvis = T.pelvis[:n] - (T.pelvis[n] - T.pelvis[0])[None] * u[:, None]
    for key in ('ankle', 'ball'):
        X = getattr(T, key)
        setattr(T, key, X[:n] - (X[n] - X[0])[None] * u[:, None, None])
    T.plant = T.plant[:n]
    if T.aim is not None:
        T.aim = T.aim[:n]
    T.n = n


def rephase(T, side=0):
    """Roll a closed loop so that frame 0 is a touch-down of foot `side` (0 = left: MarineRig's phase convention);
    every per-frame quantity of a closed loop is periodic relative to its root."""
    c = T.plant[:, side] > 0.5
    starts = [t for t in range(T.n) if c[t] and not c[t - 1]]
    if not starts or starts[0] == 0:
        return 0
    k = starts[0]
    for tb in T.W:
        T.W[tb] = np.roll(T.W[tb], -k, axis=0)
    period = T.vel * (T.n / T.fps)
    # positions are root-relative, the root moving at vel: a frame moved from the front to the back of the loop sits
    # one period later on the root's line, so relative to the root it is unchanged
    T.pelvis = np.roll(T.pelvis, -k, axis=0)
    T.ankle = np.roll(T.ankle, -k, axis=0)
    T.ball = np.roll(T.ball, -k, axis=0)
    T.plant = np.roll(T.plant, -k, axis=0)
    if T.aim is not None:
        T.aim = np.roll(T.aim, -k, axis=0)
    del period
    return k


# ---------------------------------------------------------------- poses
def _pose(T, t, cls):
    p = S.Pose(cls)
    world = {}
    for k in range(S.NB):
        nm = NAMES[k]
        if nm in T.W:
            world[k] = T.W[nm][t]
        else:
            world[k] = world[PARENT[k]] if PARENT[k] >= 0 else QI
    for k in range(S.NB):
        nm = NAMES[k]
        if nm in T.W:
            par = PARENT[k]
            p.q[k] = qnorm(qmul(qconj(world[par]), world[k])) if par >= 0 else world[k]
    p.t[IDX['pelvis']] = T.pelvis[t]
    return p


def sole_low(ank, fq, tq):
    """Lowest sole corner of a boot (heel, under the ball, the toe cap's tip; both edges) for an ankle position and
    the foot / toe model-space rotations."""
    ball = ank + qrotate(fq, TOE_OFF)
    pts = [ank + qrotate(fq, v) for v in SOLE_HEEL + SOLE_BALL] + [ball + qrotate(tq, v) for v in SOLE_TIP]
    return min(float(q[1]) for q in pts)


def flat_toe(fq):
    """A planted boot's toe: flat on the deck when the heel is up (the toe bends at the ball), else with its foot."""
    f = qrotate(fq, (0.0, 0.0, 1.0))
    if f[1] >= 0.0:
        return fq
    return qnorm(qmul(S.qbetween(f, np.array([f[0], 0.0, f[2]])), fq))


def _cyclic_spans(c, loop):
    """[(t0, t1)] runs of c > 0.5; for loops a run may wrap (t1 > n)."""
    n = len(c)
    on = c > 0.5
    if not on.any():
        return []
    if on.all():
        return [(0, n)]
    spans = []
    start = 0
    if loop:
        start = int(np.argmin(on))          # a free frame: walk from there
    t = start
    end = start + n if loop else n
    while t < end:
        if on[t % n]:
            t0 = t
            while t < end and on[t % n]:
                t += 1
            spans.append((t0, t))
        else:
            t += 1
    return spans


def finalize(T, cls, loop, weapon=True, aim_stab=0.8, ramp=2, lock=True):
    """Take → [skeleton.Pose] + gate numbers (see the module docstring). Returns (poses, report)."""
    n, fps = T.n, T.fps
    tt = np.arange(n) / fps
    period = T.vel * (n / fps)
    poses = [_pose(T, t, cls) for t in range(n)]
    # FK foot / toe rotations of the transferred pose (the source's heel strike and toe-off)
    FQ = np.zeros((n, 2, 4))
    TQ = np.zeros((n, 2, 4))
    HIP = np.zeros((n, 2, 3))
    held = np.zeros((n, 2), dtype=bool)                      # planted or easing in / out of a plant
    for si in range(2):
        for t0, t1 in _cyclic_spans(T.plant[:, si], loop):
            for j in range(t0 - ramp, t1 + ramp):
                if loop or 0 <= j < n:
                    held[j % n, si] = True
    for t, p in enumerate(poses):
        WQ, WP = p.world()
        for si, sd in enumerate('LR'):
            FQ[t, si] = WQ[IDX['foot_' + sd]]
            TQ[t, si] = flat_toe(FQ[t, si]) if held[t, si] else FQ[t, si]
            HIP[t, si] = WP[IDX['thigh_' + sd]]
    # 1. raw ankle targets: the scaled source ankles, every sole on or above the deck
    ank = T.ankle.copy()
    for t in range(n):
        for si in range(2):
            lo = sole_low(ank[t, si], FQ[t, si], TQ[t, si])
            if lo < 0.0:
                ank[t, si, 1] -= lo
    report = dict(slide_src=slide_of(np.stack([ank[t] + np.stack([qrotate(FQ[t, s], TOE_OFF) for s in range(2)])
                                               for t in range(n)]), T.plant, T.vel, fps, loop))
    # 2. the lock pass: a planted ball held at its contact average (root-moving frame), its sole flat on the deck
    if lock:
        balls = ank + np.stack([[qrotate(FQ[t, s], TOE_OFF) for s in range(2)] for t in range(n)])
        wb = balls + tt[:, None, None] * T.vel[None, None, :]
        for si in range(2):
            for t0, t1 in _cyclic_spans(T.plant[:, si], loop):
                idx = np.arange(t0, t1)
                k = idx % n
                wrap = (idx // n)[:, None] * period[None, :]
                tgt = (wb[k, si] + wrap).mean(0)
                for j in range(t0 - ramp, t1 + ramp):
                    if not loop and (j < 0 or j >= n):
                        continue
                    kk = j % n
                    if (j < t0 or j >= t1) and T.plant[kk, si] > 0.5:
                        continue                                    # a ramp frame that is planted itself
                    off = (j // n) * period                         # this frame's world offset in the unrolled loop
                    w = 1.0
                    if j < t0:
                        w = (j - (t0 - ramp) + 1) / (ramp + 1)
                    elif j >= t1:
                        w = 1.0 - (j - t1 + 1) / (ramp + 1)
                    want = tgt - off - tt[kk] * T.vel
                    cur = balls[kk, si]
                    goal = cur + (want - cur) * w
                    a = goal - qrotate(FQ[kk, si], TOE_OFF)
                    # height: the lowest sole point on the deck while planted (eased in over the ramps)
                    a[1] -= sole_low(a, FQ[kk, si], TQ[kk, si]) * w
                    ank[kk, si] = a
        for t in range(n):
            for si in range(2):
                lo = sole_low(ank[t, si], FQ[t, si], TQ[t, si])
                if lo < 0.0:
                    ank[t, si, 1] -= lo
    # 3. reach: a free foot's target (and one easing in / out of a plant) is pulled into the leg's reach; where a
    #    planted foot is out of reach the pelvis comes down instead (smoothed, cyclic for loops) — the lock holds and
    #    the IK error stays 0
    reach = np.zeros(2)
    bp = S.bind_positions(cls)
    for si, sd in enumerate('LR'):
        reach[si] = (np.linalg.norm(bp[IDX['shin_' + sd]] - bp[IDX['thigh_' + sd]])
                     + np.linalg.norm(bp[IDX['foot_' + sd]] - bp[IDX['shin_' + sd]])) * 0.998
    need = np.zeros(n)
    for t in range(n):
        for si in range(2):
            h = ank[t, si] - HIP[t, si]
            if T.plant[t, si] < 0.5:                     # free, or easing in / out of a plant: pulled into reach
                d = np.linalg.norm(h)
                if d > reach[si] * 0.995:
                    ank[t, si] = HIP[t, si] + h * (reach[si] * 0.995 / d)
                continue
            dxz = h[0] ** 2 + h[2] ** 2
            if dxz >= reach[si] ** 2:
                need[t] = max(need[t], -h[1] + 0.02)
            else:
                need[t] = max(need[t], (-h[1]) - np.sqrt(reach[si] ** 2 - dxz))
    need = np.maximum(need, 0.0)
    report['pelvis_drop_m'] = 0.0
    if need.max() > 0:
        k = 3
        pad = np.concatenate([need[-k:], need, need[:k]]) if loop else np.concatenate([np.full(k, need[0]), need, np.full(k, need[-1])])
        mx = np.array([pad[i:i + 2 * k + 1].max() for i in range(n)])
        pad2 = np.concatenate([mx[-k:], mx, mx[:k]]) if loop else np.concatenate([np.full(k, mx[0]), mx, np.full(k, mx[-1])])
        ker = np.hanning(2 * k + 3)[1:-1]
        ker /= ker.sum()
        sm = np.array([np.dot(pad2[i:i + 2 * k + 1], ker) for i in range(n)])
        drop = np.maximum(sm, need) + np.where(need > 0, 0.002, 0.0)
        for t, p in enumerate(poses):
            p.t[IDX['pelvis']][1] -= drop[t]
        report['pelvis_drop_m'] = round(float(drop.max()), 4)
    # 4. leg IK to the final targets
    leg_err = 0.0
    for t, p in enumerate(poses):
        for si, sd in enumerate('LR'):
            WQ, WP = p.world()
            th, sh = IDX['thigh_' + sd], IDX['shin_' + sd]
            mid = 0.5 * (WP[th] + ank[t, si])
            pole = WP[sh] + (WP[sh] - mid) * 2.0 + np.array([0.0, 0.0, 0.02])
            e = S.solve_limb(p, 'thigh_' + sd, 'shin_' + sd, 'foot_' + sd, ank[t, si], pole, end_rot=FQ[t, si])
            leg_err = max(leg_err, e)
            # the toe: as planned, bent further up if its cap would dip under the deck
            tq = TQ[t, si]
            WQ, WP = p.world()
            tj = WP[IDX['toe_' + sd]]
            for _ in range(30):
                if min(float((tj + qrotate(tq, v))[1]) for v in SOLE_TIP) >= -1e-4:
                    break
                tq = qnorm(qmul(qaxis(qrotate(FQ[t, si], (1.0, 0.0, 0.0)), np.radians(-2.0)), tq))
            p.q[IDX['toe_' + sd]] = qnorm(qmul(qconj(FQ[t, si]), tq))
    report['ik_leg_m'] = leg_err
    report['slide_lock'] = slide_of(np.stack([ball_world(p) for p in poses]), T.plant, T.vel, fps, loop)
    report['contact_m'] = contact_err(poses, T.plant)
    # 5. weapon + hands, secondary armour, ctrl
    arm_err = 0.0
    for t, p in enumerate(poses):
        if weapon:
            aq = None if T.aim is None else yaw_q(T.aim[t])
            arm_err = max(arm_err, hold_weapon(p, cls, aim_stab, aq))
        MO.follow(p, 0.15)
        p.ctrl(1.0 if weapon else 0.0, 1.0 if weapon else 0.0, T.plant[t, 0], T.plant[t, 1], 1.0)
    report['ik_arm_m'] = arm_err
    return poses, report


def ball_world(p):
    WQ, WP = p.world()
    return np.stack([WP[IDX['toe_L']], WP[IDX['toe_R']]])


def slide_of(B, plant, vel, fps, loop):
    """Worst / mean horizontal drift of a planted ball over each contact (m), in the root-moving frame."""
    n = len(B)
    tt = np.arange(n) / fps
    period = vel * (n / fps)
    W = B + tt[:, None, None] * vel[None, None, :]
    worst, per = 0.0, []
    for si in range(2):
        for t0, t1 in _cyclic_spans(plant[:, si], loop):
            idx = np.arange(t0, t1)
            pts = W[idx % n, si] + (idx // n)[:, None] * period[None, :]
            m = float(np.max(np.linalg.norm((pts - pts[0])[:, [0, 2]], axis=1)))
            per.append(m)
            worst = max(worst, m)
    return dict(worst_m=round(worst, 5), mean_m=round(float(np.mean(per)) if per else 0.0, 5), contacts=len(per))


def contact_err(poses, plant):
    """Worst |lowest sole point| of a planted foot (m): 0 = the boot stands on the deck."""
    worst = 0.0
    for t, p in enumerate(poses):
        WQ, WP = p.world()
        for si, sd in enumerate('LR'):
            if plant[t, si] > 0.5:
                lo = sole_low(WP[IDX['foot_' + sd]], WQ[IDX['foot_' + sd]], WQ[IDX['toe_' + sd]])
                worst = max(worst, abs(lo))
    return round(worst, 5)


_STANCE_REL = {}


def stance_rel(cls):
    """The weapon's transform relative to the chest in the procedural aim stance (motion.stance)."""
    if cls not in _STANCE_REL:
        p = MO.build(cls, MO.stance(cls))
        WQ, WP = p.world()
        c, w = IDX['chest'], IDX['weapon']
        _STANCE_REL[cls] = (qrotate(qconj(WQ[c]), WP[w] - WP[c]), qmul(qconj(WQ[c]), WQ[w]))
    return _STANCE_REL[cls]


def hold_weapon(p, cls, aim_stab=0.8, aim_q=None):
    """The weapon rides the chest (stance offset) and is stabilised toward the aim; both hands IK onto the grips.
    Returns the worst hand reach error (m)."""
    WQ, WP = p.world()
    c = IDX['chest']
    rp, rq = stance_rel(cls)
    wp = WP[c] + qrotate(WQ[c], rp)
    carried = qmul(WQ[c], rq)
    aim = QI if aim_q is None else aim_q
    wq = qslerp(carried, aim, aim_stab)
    p.t[IDX['weapon']] = qrotate(qconj(WQ[c]), wp - WP[c])
    p.set_world_rot('weapon', wq, WQ)
    WQ, WP = p.world()
    grips = MO.grip_frames(cls)
    wqw, wpw = WQ[IDX['weapon']], WP[IDX['weapon']]
    poles = {'L': np.array([0.9, -0.6, -0.5]), 'R': np.array([-0.9, -0.7, -0.2])}
    err = 0.0
    for side in ('L', 'R'):
        off, gq = grips[side]
        tgt = wpw + qrotate(wqw, off)
        rot = qmul(qmul(wqw, gq), qconj(MO.hand_bind_q(side)))
        sh = WP[IDX['upperarm_' + side]]
        err = max(err, S.solve_limb(p, 'upperarm_' + side, 'forearm_' + side, 'hand_' + side, tgt, sh + poles[side],
                                    end_rot=rot))
        WQ, WP = p.world()
    return err
