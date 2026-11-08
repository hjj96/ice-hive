"""The marines' action clips from motion capture (feel build A3): staggers, the knock-down and its get-up, going
down, lying wounded, the revive, deaths, the revive helper and the ability casts — retargeted with rtg like the
locomotion (mocap/clips.py), but one-shot, chained from more than one take where the free data needs it, with the
weapon handled per clip and the body kept above the deck.

  segment     a source range sampled at 30 fps of the GAME clock (`rate` > 1 plays the capture faster), faced so its
              facing at a chosen time is +z, rooted at its first frame's hips (the app takes the clip's travel into the
              marine's visual offset, MarineRig `rootOff`)
  chain       two segments joined: the second turned and moved onto the first one's last pelvis, crossfaded over a few
              frames (a fall into the get-up of another take)
  hull        every armour point of the pose (mocap/hull.json: the bind-space extremes of the LOD0 mesh per bone) kept
              above the deck — the body is lifted before the legs are solved (a lying marine's chest plate is thicker
              than an actor's chest), so the planted boots still stand on the deck
  weapon      'carry': chest-carried, both hands on the grips (stumbling with the rifle up); 'low': chest-carried
              muzzle-down, only the gun hand on it (the support hand throws, works, gestures); 'hand': it rides the
              gun hand (falls, lying, getting up — the free arm breaks the fall); 'drop': in the gun hand until a frame,
              then it falls and lies on the deck beside the body (a death); a weapon that would sink into the deck turns
              up about the hand
  ctrl        IK weights (gun / support hand) and the visor glow keyed per clip; the foot plants of the take

Clip conventions (MarineRig reads them): frame 0's pelvis sits over the model origin; a clip that ends upright ends
faced along its last pelvis heading (the app turns the legs' frame by it); lying states share one orientation — on
the back, head toward −z, feet toward +z (down ends there, downed / revive / death start there)."""
import json
import os

import numpy as np

import motion as MO
import skeleton as S
from skeleton import IDX, qaxis, qconj, qmul, qnorm, qrotate, qslerp

from . import rtg

HERE = os.path.dirname(os.path.abspath(__file__))
_HULL = None


def hull():
    """bone index → (k, 3) bind-space armour points (mocap/hull.json)."""
    global _HULL
    if _HULL is None:
        h = json.load(open(os.path.join(HERE, 'hull.json')))
        _HULL = {IDX[k]: np.array(v, dtype=np.float64) for k, v in h.items() if k in IDX}
    return _HULL


def hull_min(p, skip=('weapon', 'weapon_aux')):
    """Lowest armour point of a pose (m) and the bone carrying it (the antenna, a whip on a spring in the app, never
    counts)."""
    WQ, WP = p.world()
    lo, at = 9.0, -1
    for k, pts in hull().items():
        if S.NAMES[k] in skip or S.NAMES[k] == 'antenna':
            continue
        y = WP[k][1] + np.array([qrotate(WQ[k], v)[1] for v in pts])
        m = float(y.min())
        if m < lo:
            lo, at = m, k
    return lo, at


# ---------------------------------------------------------------- takes
def heading(q):
    """Yaw of a pelvis rotation's left (+x) axis turned to its facing (the hip line's normal), rad."""
    left = qrotate(q, (1.0, 0.0, 0.0))
    return float(np.arctan2(-left[2], left[0]))


def segment(cls, take, t0, t1, rate=1.0, face=0.0, turn=0.0, mirror=False):
    """A source range (original-take seconds) as a Take at 30 fps of the game clock; its facing at `face` (s from t0,
    or 'end') onto +z, then turned by `turn` deg; rooted at the first frame's hips."""
    from . import clips as C
    n = max(2, int(round((t1 - t0) / rate * 30.0)) + 1)
    times = t0 + np.arange(n) * (rate / 30.0)
    d, kind = C.load(take, times)
    d['fps'] = 30.0
    src = rtg.Source(d, kind, mirror=mirror)
    f = np.unwrap(src.facing())
    i = n - 1 if face == 'end' else min(n - 1, int(round(float(face) / rate * 30.0)))
    T = rtg.transfer(src, cls, yaw=-float(f[i]) + np.radians(turn), root='start')
    T.meta['source'] = [dict(take=take, t0=round(t0, 4), t1=round(t1, 4), rate=rate, mirror=mirror)]
    return T


def turn_take(T, a, about=None):
    """Turn a take by a (rad) about +y through `about` (xz; default the origin)."""
    c = np.zeros(3) if about is None else np.array([about[0], 0.0, about[1]])
    Yq, Ym = rtg.yaw_q(a), rtg.yaw_mat(a)
    for k in T.W:
        T.W[k] = rtg.qmul_n(Yq, T.W[k])
    T.pelvis = (T.pelvis - c) @ Ym.T + c
    T.ankle = np.einsum('ij,tsj->tsi', Ym, T.ankle - c) + c
    T.ball = np.einsum('ij,tsj->tsi', Ym, T.ball - c) + c


def shift_take(T, d):
    T.pelvis = T.pelvis + d
    T.ankle = T.ankle + d
    T.ball = T.ball + d


def chain(A, B, xf=6, align=True):
    """A then B: B turned (pelvis heading) and moved (pelvis xz) onto A's last frame, the two crossfaded over xf frames
    (A's last xf frames blend into B's first ones)."""
    if align:
        turn_take(B, heading(A.W['pelvis'][-1]) - heading(B.W['pelvis'][0]))
        d = A.pelvis[-1] - B.pelvis[0]
        d[1] = 0.0
        shift_take(B, d)
    xf = max(1, min(xf, A.n - 1, B.n - 1))
    n = A.n + B.n - xf
    T = rtg.Take(n, A.fps)
    T.scale, T.vel = A.scale, np.zeros(3)
    w = 0.5 - 0.5 * np.cos(np.pi * (np.arange(xf) + 1) / (xf + 1))
    for k in A.W:
        mid = np.stack([qslerp(A.W[k][A.n - xf + i], B.W[k][i], w[i]) for i in range(xf)])
        T.W[k] = np.concatenate([A.W[k][:A.n - xf], mid, B.W[k][xf:]])
    for key in ('pelvis', 'ankle', 'ball', 'plant'):
        a, b = getattr(A, key), getattr(B, key)
        ww = w.reshape((-1,) + (1,) * (a.ndim - 1))
        mid = a[A.n - xf:] + (b[:xf] - a[A.n - xf:]) * ww
        if key == 'plant':
            mid = np.round(mid)
        setattr(T, key, np.concatenate([a[:A.n - xf], mid, b[xf:]]))
    T.meta = dict(A.meta)
    T.meta['source'] = A.meta.get('source', []) + B.meta.get('source', [])
    return T


UPPER_BODY = ('spine2', 'chest', 'neck', 'head', 'clav_L', 'clav_R', 'upperarm_L', 'upperarm_R', 'pauldron_L', 'pauldron_R',
              'backpack')
LOWER_SKIP = ('weapon', 'weapon_aux', 'hand_L', 'hand_R', 'forearm_L', 'forearm_R', 'foot_L', 'foot_R', 'toe_L', 'toe_R')


def _ease_need(need, k=3):
    n = len(need)
    pad = np.concatenate([np.full(k, need[0]), need, np.full(k, need[-1])])
    mx = np.array([pad[i:i + 2 * k + 1].max() for i in range(n)])
    pad2 = np.concatenate([np.full(k, mx[0]), mx, np.full(k, mx[-1])])
    ker = np.hanning(2 * k + 3)[1:-1]
    ker /= ker.sum()
    return np.maximum(np.array([np.dot(pad2[i:i + 2 * k + 1], ker) for i in range(n)]), need)


def _tilt(T, t, a):
    """Turn the upper body (spine1 and everything above it) of frame t by a (rad) about the pelvis' left axis."""
    left = qrotate(T.W['pelvis'][t], (1.0, 0.0, 0.0))
    left[1] = 0.0
    L = np.linalg.norm(left)
    if L < 1e-6:
        return
    q = qaxis(left / L, a)
    for k in rtg.UPPER:
        T.W[k][t] = qnorm(qmul(q, T.W[k][t]))


def lift_body(T, cls, clearance=0.004):
    """Keep the armour of a lying / kneeling pose above the deck — the backpack under a marine on his back props the
    shoulders up (the upper body turns up about the hips, the head hanging back a little), what is still under the
    deck (a knee pad, the hips) lifts the pelvis (the legs then reach down to the capture's feet); both eased (a
    running max, then a Hann blur) so the body never pops. Returns the largest pelvis lift (m)."""
    n = T.n
    tilt = np.zeros(n)
    keys = sorted(set(list(range(0, n, 3)) + [n - 1]))     # solved on every third frame, interpolated between
    for t in keys:
        p = rtg._pose(T, t, cls)
        WQ, WP = p.world()
        lo_up = min(WP[IDX[b]][1] + min(qrotate(WQ[IDX[b]], v)[1] for v in hull()[IDX[b]]) for b in UPPER_BODY)
        if lo_up >= clearance or WP[IDX['chest']][1] > 0.75:
            continue
        # the cheapest (pelvis lift, turn) that clears the upper body: for a few lifts, the smallest turn either way
        # (a bisection on the angle); a centimetre of lift costs as much as 2.5° of turn
        def low_at(a, h):
            _tilt(T, t, a)
            T.pelvis[t, 1] += h
            q = rtg._pose(T, t, cls)
            WQ2, WP2 = q.world()
            T.pelvis[t, 1] -= h
            _tilt(T, t, -a)
            return min(WP2[IDX[b]][1] + min(qrotate(WQ2[IDX[b]], v)[1] for v in hull()[IDX[b]]) for b in UPPER_BODY)
        best, cost = 0.0, 1e9
        for h in (0.0, 0.04, 0.08, 0.12, 0.16, 0.2, 0.25, 0.3):
            if low_at(0.0, h) >= clearance:
                if h * 100 * 2.5 < cost:
                    best, cost = 0.0, h * 100 * 2.5
                break
            for sign in (1.0, -1.0):
                hi = np.radians(55.0)
                if low_at(sign * hi, h) < clearance:
                    continue
                lo_a = 0.0
                for _ in range(10):
                    mid = 0.5 * (lo_a + hi)
                    if low_at(sign * mid, h) >= clearance:
                        hi = mid
                    else:
                        lo_a = mid
                c = h * 100 * 2.5 + np.degrees(hi)
                if c < cost:
                    best, cost = sign * hi, c
        if best:
            _tilt(T, t, best)
        tilt[t] = best
    # smooth the tilt over time (it was set on the key frames): re-apply the interpolated, eased curve
    if np.abs(tilt).max() > 0:
        for t in keys:
            _tilt(T, t, -tilt[t])
        tilt = np.interp(np.arange(n), keys, tilt[keys])
        sm = np.sign(tilt) * _ease_need(np.abs(tilt), 2)
        for t in range(n):
            _tilt(T, t, sm[t])
    need = np.zeros(n)
    for t in range(n):
        lo, _ = hull_min(rtg._pose(T, t, cls), skip=LOWER_SKIP)
        need[t] = max(0.0, clearance - lo)
    if need.max() <= 0:
        return 0.0
    lift = _ease_need(need)
    T.pelvis[:, 1] += lift
    return float(lift.max())


def drop_drift(T, keep=0.0):
    """Remove the take's horizontal travel beyond `keep` m, eased over the frames where no foot is planted (a fall's
    flight, a roll): the marine falls where it stands instead of sliding out of its spot."""
    d = T.pelvis[-1] - T.pelvis[0]
    d[1] = 0.0
    L = float(np.linalg.norm(d))
    if L <= keep + 1e-6:
        return
    free = 1.0 - np.maximum(T.plant[:, 0], T.plant[:, 1])
    if free.sum() < 1:
        free = np.ones(T.n)
    c = np.cumsum(free) / free.sum()
    off = -d * (1.0 - keep / L)
    sh = c[:, None] * off[None]
    T.pelvis = T.pelvis + sh
    T.ankle = T.ankle + sh[:, None, :]
    T.ball = T.ball + sh[:, None, :]


# ---------------------------------------------------------------- weapon
def weapon_from_hand(cls, WQ, WP):
    """The weapon placement that puts the gun hand's grip where the gun hand is (its rotation, its wrist)."""
    off, gq = MO.grip_frames(cls)['L']
    hq = WQ[IDX['hand_L']]
    wq = qnorm(qmul(qmul(hq, MO.hand_bind_q('L')), qconj(gq)))
    wp = WP[IDX['hand_L']] - qrotate(wq, off)
    return wp, wq


def place_weapon(p, wp, wq):
    WQ, WP = p.world()
    c = IDX['chest']
    p.t[IDX['weapon']] = qrotate(qconj(WQ[c]), wp - WP[c])
    p.set_world_rot('weapon', wq, WQ)


def grip_hands(p, cls, sides):
    """Hands onto their grips of the placed weapon (the rig's own 2-bone IK); the worst reach error (m)."""
    WQ, WP = p.world()
    grips = MO.grip_frames(cls)
    wqw, wpw = WQ[IDX['weapon']], WP[IDX['weapon']]
    poles = {'L': np.array([0.9, -0.6, -0.5]), 'R': np.array([-0.9, -0.7, -0.2])}
    err = 0.0
    for side in sides:
        off, gq = grips[side]
        tgt = wpw + qrotate(wqw, off)
        rot = qmul(qmul(wqw, gq), qconj(MO.hand_bind_q(side)))
        sh = WP[IDX['upperarm_' + side]]
        err = max(err, S.solve_limb(p, 'upperarm_' + side, 'forearm_' + side, 'hand_' + side, tgt, sh + poles[side],
                                    end_rot=rot))
        WQ, WP = p.world()
    return err


def weapon_clear(p, cls, pivot):
    """Turn a weapon that sinks into the deck up about `pivot` (the gun hand's grip) until it clears."""
    for _ in range(40):
        lift = MO.weapon_floor_lift(cls, p, clearance=0.045)
        if lift <= 0:
            return
        WQ, WP = p.world()
        k = IDX['weapon']
        fwd = qrotate(WQ[k], (0.0, 0.0, 1.0))
        ax = np.cross(fwd, (0.0, 1.0, 0.0))
        if np.linalg.norm(ax) < 1e-4:
            ax = np.array([1.0, 0.0, 0.0])
        ax = ax / np.linalg.norm(ax)
        dq = qaxis(ax, np.radians(6.0))           # turns the muzzle toward +y
        wq = qnorm(qmul(dq, WQ[k]))
        wp = pivot + qrotate(dq, WP[k] - pivot)
        place_weapon(p, wp, wq)


LOW_Q = S.qeuler(x=38.0, y=-22.0)       # 'low': muzzle down and across the body, the gun hand at the hip


def ground_rest(cls, x=0.42, z=0.05, yaw=8.0):
    """The weapon lying on its side on the deck at (x, z) of the model frame (the gun side of a marine on its back),
    muzzle toward yaw (deg about +y from +z)."""
    q = qnorm(qmul(rtg.yaw_q(np.radians(yaw)), S.qeuler(z=84.0)))
    lo, hi = (np.asarray(v, dtype=np.float64) for v in MO.WEAPON_BOX[cls])
    m = S.qmat(q)
    ymin = min(float((m @ np.array([cx, cy, cz]))[1]) for cx in (lo[0], hi[0]) for cy in (lo[1], hi[1]) for cz in (lo[2], hi[2]))
    return np.array([x, 0.006 - ymin, z]), q


def placement(p, cls, mode, ground):
    """(wp, wq, gripping hands) of a weapon mode on the pose as it stands (its hands from the capture)."""
    WQ, WP = p.world()
    c = IDX['chest']
    if mode in ('carry', 'low'):
        rp, rq = rtg.stance_rel(cls)
        if mode == 'low':
            piv = MO.grip_frames(cls)['L'][0]
            rq2 = qmul(LOW_Q, rq)
            rp = rp + qrotate(rq, piv) - qrotate(rq2, piv)
            rq = rq2
        return WP[c] + qrotate(WQ[c], rp), qmul(WQ[c], rq), (('L', 'R') if mode == 'carry' else ('L',))
    if mode == 'hand':
        wp, wq = weapon_from_hand(cls, WQ, WP)
        return wp, wq, ('L',)
    return ground[0], ground[1], ()


def weapon_pass(poses, cls, modes, wx=8, ground=None):
    """Place the weapon and solve the hands per frame. `modes`: [(frame, mode)] — 'carry' (chest, both hands), 'low'
    (chest, muzzle down, the gun hand), 'hand' (rides the gun hand), 'ground' (lying on the deck at `ground`); a change
    blends over `wx` frames (into 'ground' with an accelerating fall). Returns the worst arm IK error (m)."""
    err = 0.0
    g = ground or ground_rest(cls)
    for t, p in enumerate(poses):
        i = max(k for k in range(len(modes)) if modes[k][0] <= t)
        f0, m1 = modes[i]
        wp, wq, hands = placement(p, cls, m1, g)
        if i > 0 and t < f0 + wx:
            m0 = modes[i - 1][1]
            u = (t - f0 + 1) / (wx + 1)
            e = u * u if m1 == 'ground' else u * u * (3 - 2 * u)
            wp0, wq0, h0 = placement(p, cls, m0, g)
            wp, wq = wp0 + (wp - wp0) * e, qslerp(wq0, wq, min(1.0, e * 1.15) if m1 == 'ground' else e)
            hands = tuple(h for h in h0 if h in hands) if m1 != 'ground' else ()
            if m0 == 'ground':
                hands = ()
        place_weapon(p, wp, wq)
        if m1 != 'ground' or t < f0 + wx:
            # a weapon in the hand (or on its way) never sinks into the deck: turned up about the hand, then lifted
            weapon_clear(p, cls, p.world()[1][IDX['hand_L']])
            lift = MO.weapon_floor_lift(cls, p, clearance=0.045)
            if lift > 0:
                WQ, WP = p.world()
                place_weapon(p, WP[IDX['weapon']] + np.array([0.0, lift, 0.0]), WQ[IDX['weapon']])
        if hands:
            err = max(err, grip_hands(p, cls, hands))
    return err


# ---------------------------------------------------------------- curves
def curve(keys, n, default=1.0):
    """Piecewise smoothstep through (frame, value) keys (frames may be fractions of the clip, 0…1, when ≤ 1.0 floats
    are given with `frac`)."""
    if not keys:
        return np.full(n, default)
    out = np.zeros(n)
    for t in range(n):
        if t <= keys[0][0]:
            out[t] = keys[0][1]
            continue
        for i in range(len(keys) - 1):
            (f0, v0), (f1, v1) = keys[i], keys[i + 1]
            if f0 <= t <= f1:
                u = (t - f0) / max(1e-9, f1 - f0)
                out[t] = v0 + (v1 - v0) * u * u * (3 - 2 * u)
                break
        else:
            out[t] = keys[-1][1]
    return out


# ---------------------------------------------------------------- one action
def build_action(cls, A):
    """One action clip from its table entry → (poses, report)."""
    segs = A['segs']
    T = segment(cls, *segs[0][:3], **segs[0][3] if len(segs[0]) > 3 else {})
    for s in segs[1:]:
        B = segment(cls, *s[:3], **s[3] if len(s) > 3 else {})
        T = chain(T, B, xf=A.get('xf', 6))
    if A.get('post_turn'):
        turn_take(T, np.radians(A['post_turn']))
    loop = A.get('loop', False)
    if loop:
        rtg.close_loop(T)                    # (the segment's last sample is the frame after the loop's end)
    rtg.detect_plants(T, loop=loop, h_tol=0.03, v_tol=0.3)
    T.plant[T.pelvis[:, 1] < 0.62] = 0.0     # sitting, kneeling low, lying: no foot is planted (no lock, no plant curve)
    if 'keep' in A:
        drop_drift(T, A['keep'])
    if A.get('blade'):
        rtg.blade(T, cls)
    lift = lift_body(T, cls)
    modes = A.get('weapon', 'carry')
    if isinstance(modes, str):
        modes = [(0, modes)]
    poses, rep = rtg.finalize(T, cls, loop=loop, weapon=False)
    n = len(poses)
    g = ground_rest(cls, *A['ground']) if 'ground' in A else ground_rest(cls)
    if A.get('ground_end'):
        # (a fall: the rifle lies by where the body ends up — the app moves the clip's travel into the visual offset
        # at its end, and the lying clips after it put the rifle at the same spot of their own frame)
        e = poses[-1].t[IDX['pelvis']]
        g = (g[0] + np.array([e[0], 0.0, e[2]]), g[1])
    arm = weapon_pass(poses, cls, modes, wx=A.get('wx', 8), ground=g)
    # what the finished poses still put under the deck (hands and the weapon included): a residual lift of the pelvis
    resid = np.zeros(n)
    for t, p in enumerate(poses):
        # (a planted boot stands on the deck by the lock pass; a free one — lying, kneeling — counts with its hull: the
        # heel cup and the toe cap reach past the sole corners the retarget checks)
        planted = T.plant[t].max() > 0.5
        lo, _ = hull_min(p, skip=('weapon', 'weapon_aux') + (('foot_L', 'foot_R', 'toe_L', 'toe_R') if planted else ()))
        # (the hull is 14 extremes per bone: the mesh dips 1–3 cm past it where a plate lies on the deck)
        resid[t] = max(0.0, (0.035 if p.world()[1][IDX['pelvis']][1] < 0.55 else 0.004) - lo)
    if resid.max() > 0:
        k = 2
        pad = np.concatenate([np.full(k, resid[0]), resid, np.full(k, resid[-1])])
        r2 = np.array([pad[i:i + 2 * k + 1].max() for i in range(n)])
        for t, p in enumerate(poses):
            p.t[IDX['pelvis']][1] += r2[t]
    gun = curve(A.get('ik_gun', []), n, 1.0)
    sup = curve(A.get('ik_sup', []), n, 1.0 if modes[0][1] == 'carry' else 0.0)
    vis = curve(A.get('visor', []), n, 1.0)
    for t, p in enumerate(poses):
        MO.follow(p, 0.15)
        p.ctrl(gun[t], sup[t], T.plant[t, 0], T.plant[t, 1], vis[t])
    rep.update(ik_arm_m=arm, lift_m=round(lift, 4), resid_lift_m=round(float(resid.max()), 4), frames=n,
               source=T.meta.get('source'))
    return poses, rep
