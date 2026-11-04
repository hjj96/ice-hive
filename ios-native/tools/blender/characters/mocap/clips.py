"""The marines' motion-capture clips (feel build A1): which source range becomes which clip, and how.

Every job samples a committed source range (sources/, SOURCES.md) with Blender's importer (bvhsrc) and retargets it
(rtg) for one class; the source samples are shared by the four classes. Clip names and conventions are MarineRig's
(motion.py's docstring): 30 fps, loops close, locomotion phase 0 = left foot touch-down, a locomotion clip's stride
is the distance per loop and its duration × the game speed = its stride (walk 1.5 m/s, run 5.3 m/s), so the app's
distance-driven phase plays it at the cadence it was cut for.

  idle / idle_b   ready stances (CMU 77_03, CMU 140_07): weight shifts and look-around, loops picked by a pose-distance
                  search; the app gives each marine its own variant and phase (four never match)
  walk_<d>        f: CMU 35_01; b: 100STYLE Neutral BW; l / r: 100STYLE Neutral SW (+ mirror); diagonals: the
                  forward / backward cycle turned 45° (hips part of the way, the chest back on the aim)
  run_<d>         f: CMU 09_01, stride-warped; b: the same cycle played backward (a back-pedal: free data has no fast
                  backward run); l / r and diagonals: the forward / backward cycle turned 45° / 90° (hips turn, the
                  legs run their own way, spine and chest twist back to the aim)
  turn_l / turn_r CMU 69_16 / 69_18: a 90° turn on the spot (for the runtime's upper / lower body split)
Everything else (dash, fire, flinch, down, downed, revive, death) stays procedural in motion.py."""
import json
import os

import numpy as np

import motion as MO
import skeleton as S

from . import bvhsrc
from . import rtg

HERE = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.environ.get('MOCAP_SRC_DIR', os.path.join(HERE, 'sources'))
CMU_SCALE = 0.05644          # cgspeed CMU units → m (inches × 0.45 / 0.254 … the study's calibrated leg length)
STYLE_SCALE = 0.01           # 100STYLE: cm
HEAD_PITCH = 5.0             # deg, the head's mean pitch in locomotion (eyes on the aim)
IDLE_CHEST = 6.0             # deg, the mean chest pitch of a ready stance before the stance hunch (captures crouch to 40°+)
WALK_V = MO.GAIT['walk']['speed']
RUN_V = MO.GAIT['run']['speed']

# a take is named <library>_<take>: cmu_35_01 (CMU, cgspeed BVH), style_neutral_bw (100STYLE), ual_... (Quaternius);
# its committed cut is sources/<take>.bvh, the cut's first frame time in the original take in sources/manifest.json
# (clip times below are times of the ORIGINAL take)
KINDS = {'cmu': ('cmu', CMU_SCALE), 'style': ('100style', STYLE_SCALE), 'ual': ('ual', 1.0)}


def kind_of(take):
    return KINDS[take.split('_')[0]]


def manifest():
    p = os.path.join(SRC_DIR, 'manifest.json')
    return json.load(open(p)) if os.path.exists(p) else {}


def take_path(take):
    """(path, offset): the committed cut and its start time in the original take (s)."""
    m = manifest().get(take, {})
    return os.path.join(SRC_DIR, m.get('file', take + '.bvh')), float(m.get('t0', 0.0))


def load(take, times):
    kind, scale = kind_of(take)
    path, off = take_path(take)
    return bvhsrc.load(path, scale, times=np.asarray(times, dtype=np.float64) - off), kind


def load_all(take, fps):
    kind, scale = kind_of(take)
    path, off = take_path(take)
    d = bvhsrc.load(path, scale, fps_out=fps)
    return d, kind, off


# ---------------------------------------------------------------- locomotion cycles
def contacts(src, P=None):
    """Left / right ball contact flags of a whole sampled take (its own frame rate)."""
    legs = src.M['_legs']
    P = src.P if P is None else P
    ball = np.stack([P[:, src.joint(legs[sd][2])] for sd in 'LR'], 1)
    fps = src.fps
    k = max(1, int(round(fps / 30.0)))
    spd = np.zeros(ball.shape[:2])
    spd[k:] = np.linalg.norm(ball[k:, :, [0, 2]] - ball[:-k, :, [0, 2]], axis=2) * fps / k
    spd[:k] = spd[k]
    h = ball[:, :, 1]
    hmin = np.percentile(h, 5, axis=0)
    c = (h < hmin[None] + 0.04 * src.leg / 0.86) & (spd < 0.5 * src.leg / 0.86)
    g = int(0.1 * fps)
    for si in range(2):
        x = c[:, si].copy()
        for val in (False, True):           # fill gaps < 0.1 s, then drop contacts < 0.1 s
            t = 0
            while t < len(x):
                if x[t] == val:
                    t0 = t
                    while t < len(x) and x[t] == val:
                        t += 1
                    if t - t0 < g and (val or (t0 > 0 and t < len(x))):
                        x[t0:t] = not val
                else:
                    t += 1
        c[:, si] = x
    return c


def find_cycle(take, mirror=False, reverse=False, pick=0, cycles=1, fps=60.0, foot='L'):
    """Authoring: the source times (original take) of a cycle — `foot` touch-down to its next one after mirroring /
    reversal (a cycle cut at the right foot is re-phased to the left touch-down by the build). The build never
    searches: CYCLES pins what this found, so a change here cannot silently change a clip."""
    d, kind, off = load_all(take, fps)
    src = rtg.Source(d, kind, mirror=mirror)
    P = src.P[::-1] if reverse else src.P
    c = contacts(src, P)
    fi = 0 if foot == 'L' else 1
    st = [t for t in range(1, len(c)) if c[t, fi] and not c[t - 1, fi]]
    if len(st) < cycles + 1:
        raise SystemExit(f'{take}: only {len(st)} {foot} contacts')
    i = min(pick, len(st) - cycles - 1)
    a, b = st[i], st[i + cycles]
    n_src = len(src.P)
    if reverse:
        a, b = n_src - 1 - a, n_src - 1 - b
    return round(a / fps + off, 4), round(b / fps + off, 4)


class Cycle:
    """One locomotion cycle of a take between two source times (original take; t0 > t1 plays it backward): its
    travel yaw, its facing relative to the travel, its natural stride (m, after the leg-length scale)."""

    def __init__(self, take, t0, t1, mirror=False, n=24):
        self.take, self.t0, self.t1, self.mirror = take, float(t0), float(t1), mirror
        self.reverse = t1 < t0
        d, kind = load(take, self.times(n))
        d['fps'] = n / abs(self.t1 - self.t0)
        src = rtg.Source(d, kind, mirror=mirror)
        self.kind = kind
        hip = src.hips()
        tr = hip[-1] - hip[0]
        self.yaw = float(np.arctan2(-tr[0], tr[2]))          # travel → +z
        fm = float(np.angle(np.mean(np.exp(1j * src.facing()[:-1]))))
        self.face = float(rtg.wrap(fm - np.arctan2(tr[0], tr[2])))   # its facing relative to its travel
        bp = S.bind_positions('assault')
        self.length = float(np.linalg.norm(tr[[0, 2]]) * np.linalg.norm(bp[IDX_FOOT] - bp[IDX_THIGH]) / src.leg)
        self.duration = abs(self.t1 - self.t0)

    def times(self, n):
        """n + 1 samples from touch-down to touch-down (the extra one closes the loop)."""
        return self.t0 + (self.t1 - self.t0) * np.arange(n + 1) / n


IDX_FOOT, IDX_THIGH = S.IDX['foot_L'], S.IDX['thigh_L']


def loco(cls, cyc, v, stride, theta=0.0, hip=None):
    """A locomotion loop from a cycle: n frames at 30 fps with n = stride / v, stride-warped to exactly v × n / 30,
    travelling toward theta (deg relative to the aim: 0 forward, + toward the marine's left, 180 backward), the hips
    at `hip` (deg; None = as the source holds them relative to its travel), the chest on the aim."""
    n = max(8, int(round(stride / v * 30.0)))
    d, kind = load(cyc.take, cyc.times(n))
    d['fps'] = 30.0
    src = rtg.Source(d, kind, mirror=cyc.mirror)
    T = rtg.transfer(src, cls, yaw=cyc.yaw, root='line')
    rtg.detect_plants(T, loop=False)            # on the source's own motion (before the warp distorts it)
    # the head watches the aim, not the floor or the travel (the take is still faced along its travel here: the
    # facing is cyc.face)
    rtg.posture(T, head=HEAD_PITCH, ref=np.full(T.n, cyc.face))
    rtg.blade(T, cls)
    speed = float(np.linalg.norm(T.vel))
    rtg.warp(T, v / max(speed, 1e-6))
    th = np.radians(theta)
    rtg.direct(T, th, th + cyc.face if hip is None else np.radians(hip), face=cyc.face)
    rtg.close_loop(T)
    shift = rtg.rephase(T, 0)
    poses, rep = rtg.finalize(T, cls, loop=True)
    rep['rephase'] = shift
    rep.update(stride=round(v * n / 30.0, 4), speed=v, warp=round(v / max(speed, 1e-6), 4), frames=n,
               source=dict(take=cyc.take, t0=round(cyc.t0, 4), t1=round(cyc.t1, 4), mirror=cyc.mirror, reverse=cyc.reverse,
                           face_deg=round(float(np.degrees(cyc.face)), 1)))
    return poses, v * n / 30.0, rep


# ---------------------------------------------------------------- idle loops, segments
def idle_window(take, lmin, lmax, tmin, tmax, fps=15.0):
    """The best-closing window of a standing take (pose distance of hip-relative joints, hip height, velocity)."""
    d, kind, off = load_all(take, fps)
    src = rtg.Source(d, kind)
    P = src.P
    hip = src.hips()
    F = (P - hip[:, None, :]).reshape(len(P), -1)
    F = np.c_[F, hip[:, 1:2] * 3.0]
    n = len(P)
    best = (1e9, 0, 0)
    a0 = int(max(0.0, tmin - off) * fps)
    a1 = min(n, int((tmax - off) * fps)) if tmax else n
    for a in range(a0, a1):
        for b in range(a + int(lmin * fps), min(a1 - 1, a + int(lmax * fps) + 1)):
            e = float(np.linalg.norm(F[a] - F[b])) + 0.02 * float(np.linalg.norm(F[a + 1] - F[a] - (F[b + 1] - F[b])))
            if e < best[0]:
                best = (e, a, b)
    e, a, b = best
    return a / fps + off, b / fps + off, e


def idle(cls, take, t0, t1, mirror=False):
    n = int(round((t1 - t0) * 30.0))
    times = t0 + (t1 - t0) * np.arange(n + 1) / n
    d, kind = load(take, times)
    d['fps'] = 30.0
    src = rtg.Source(d, kind, mirror=mirror)
    yaw = -float(np.mean(np.unwrap(src.facing())))
    T = rtg.transfer(src, cls, yaw=yaw, root='mean')
    rtg.posture(T, chest=IDLE_CHEST, head=HEAD_PITCH)
    rtg.blade(T, cls)
    rtg.close_loop(T)
    rtg.detect_plants(T, loop=True, h_tol=0.03, v_tol=0.25)
    poses, rep = rtg.finalize(T, cls, loop=True)
    rep.update(source=dict(take=take, t0=round(t0, 4), t1=round(t1, 4), mirror=mirror))
    return poses, rep


def turn(cls, take, t0, t1):
    """A turn on the spot: faced along +z at its start, the weapon carried round with the hips' (smoothed) turn."""
    n = int(round((t1 - t0) * 30.0))
    times = t0 + np.arange(n) / 30.0
    d, kind = load(take, times)
    d['fps'] = 30.0
    src = rtg.Source(d, kind)
    f = np.unwrap(src.facing())
    yaw = -float(f[0])
    T = rtg.transfer(src, cls, yaw=yaw, root='start')
    a = f - f[0]
    k = np.hanning(9)[1:-1]
    k /= k.sum()
    ref = np.convolve(np.r_[np.full(3, a[0]), a, np.full(3, a[-1])], k, mode='valid')
    rtg.posture(T, chest=IDLE_CHEST, head=HEAD_PITCH, ref=ref)
    rtg.blade(T, cls)
    rtg.detect_plants(T, loop=False, h_tol=0.03, v_tol=0.3)
    # the weapon rides the chest (stance relation, no stabilisation): it turns with the body
    poses, rep = rtg.finalize(T, cls, loop=False, aim_stab=0.0)
    rep.update(turn_deg=round(float(np.degrees(a[-1])), 1), source=dict(take=take, t0=round(t0, 4), t1=round(t1, 4)))
    return poses, rep


# ---------------------------------------------------------------- the clip table
# cycles (class-independent): take, source times (original take; t0 > t1 = played backward), mirror — pinned from
# find_cycle (the comment: its arguments)
CYCLES = {
    'walk_f': dict(take='cmu_35_01', t0=1.3167, t1=2.4167),                     # find_cycle(pick=1)
    'walk_b': dict(take='style_neutral_bw', t0=0.6, t1=1.7833),                 # foot='R'
    'walk_r': dict(take='style_neutral_sw', t0=0.7667, t1=2.0167),              # foot='R'
    'walk_l': dict(take='style_neutral_sw', t0=0.7667, t1=2.0167, mirror=True),
    'run_f': dict(take='cmu_09_01', t0=0.05, t1=0.75),
    'run_b': dict(take='cmu_09_01', t0=0.85, t1=0.1167),                        # reverse=True: a back-pedal
}
# locomotion clip → (cycle, game speed m/s, stride m, travel deg (+ = toward the marine's left), hips deg or None)
# strides: forward ones ≈ the capture's × 1.09 (walk) / × 1.18 (run); the slow side / back walks warped × 1.2–1.4 and
# played faster; diagonals / side runs share their base cycle's stride and cadence
LOCO = {
    'walk_f': ('walk_f', WALK_V, 1.5, 0.0, None),
    'walk_fl': ('walk_f', WALK_V, 1.5, 45.0, 20.0),
    'walk_l': ('walk_l', WALK_V, 0.85, 90.0, None),
    'walk_bl': ('walk_b', WALK_V, 1.0, 135.0, -20.0),
    'walk_b': ('walk_b', WALK_V, 1.0, 180.0, None),
    'walk_br': ('walk_b', WALK_V, 1.0, -135.0, 20.0),
    'walk_r': ('walk_r', WALK_V, 0.85, -90.0, None),
    'walk_fr': ('walk_f', WALK_V, 1.5, -45.0, -20.0),
    'run_f': ('run_f', RUN_V, 3.0, 0.0, None),
    'run_fl': ('run_f', RUN_V, 3.0, 45.0, 22.0),
    'run_l': ('run_f', RUN_V, 3.0, 90.0, 50.0),
    'run_bl': ('run_b', RUN_V, 3.0, 135.0, -22.0),
    'run_b': ('run_b', RUN_V, 3.0, 180.0, None),
    'run_br': ('run_b', RUN_V, 3.0, -135.0, 22.0),
    'run_r': ('run_f', RUN_V, 3.0, -90.0, -50.0),
    'run_fr': ('run_f', RUN_V, 3.0, -45.0, -22.0),
}
# idle loops: (take, window search (min, max length s, from, to) — the window found is pinned here so a change of
# the search cannot silently change the clip)
IDLES = {
    'idle': ('cmu_77_03', (3.2, 7.6)),
    'idle_b': ('cmu_77_05', (1.0, 4.133333)),
}
TURNS = {
    'turn_l': ('cmu_69_16', (1.55, 3.25)),
    'turn_r': ('cmu_69_18', (2.55, 4.0)),
}
_CYC = {}


def cycle(name):
    if name not in _CYC:
        _CYC[name] = Cycle(**CYCLES[name])
    return _CYC[name]


def build(cls, name):
    """One mocap clip of a class: (poses, loop, stride, report)."""
    if name in LOCO:
        cn, v, stride, theta, hip = LOCO[name]
        poses, st, rep = loco(cls, cycle(cn), v, stride, theta, hip)
        return poses, True, st, rep
    if name in IDLES:
        take, (t0, t1) = IDLES[name]
        poses, rep = idle(cls, take, t0, t1)
        return poses, True, 0.0, rep
    if name in TURNS:
        take, (t0, t1) = TURNS[name]
        poses, rep = turn(cls, take, t0, t1)
        return poses, False, 0.0, rep
    raise KeyError(name)


def names():
    return list(IDLES) + list(LOCO) + list(TURNS)


def used_ranges():
    """take → [(t0, t1)] original-take time ranges every clip samples (for sources/ and SOURCES.md)."""
    out = {}
    for cn in CYCLES:
        c = cycle(cn)
        out.setdefault(c.take, []).append((min(c.t0, c.t1), max(c.t0, c.t1)))
    for take, (t0, t1) in list(IDLES.values()) + list(TURNS.values()):
        out.setdefault(take, []).append((t0, t1))
    return out
