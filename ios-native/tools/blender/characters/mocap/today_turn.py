"""Before / after reference (the feel build's comparisons): the pre-A2 runtime 'turn' (numpy port of MarineRig.update's
relevant parts): no turn clip — the whole body yaws rigidly to the
smoothed aim (k = 22 / s, WorldSquad aimVis), the idle clip keeps playing, planted balls stay locked in the world and
re-step (0.2 s, 9 cm lift, smoothstep) when the clip's ball is > 0.32 m from the lock, the pelvis drops (<= 7 cm) to keep
them in reach. Returns per-frame (track row in model space, model yaw)."""
import numpy as np

import skeleton as S
from skeleton import IDX, qaxis, qrotate


def yaw_q(a):
    return qaxis((0.0, 1.0, 0.0), a)


def run(idle_row_fn, n, dt, yaw_from, yaw_to, t_turn=0.2, cls='assault'):
    yaw = yaw_from
    lock = [None, None]
    step = [1.0, 1.0]
    sfrom = [None, None]
    drop = 0.0
    out = []
    clock = 0.0
    for f in range(n):
        t = f * dt
        target = yaw_from if t < t_turn else yaw_to
        yaw += (target - yaw) * min(1.0, 22.0 * dt)
        clock += dt
        row = idle_row_fn(clock).astype(np.float64)
        p = S.Pose(cls)
        p.q = row[:, 0].copy()
        p.t = row[:, 1, :3].copy()
        p.s = row[:, 1, 3].copy()
        WQ, WP = p.world()
        R = yaw_q(yaw)
        Rinv = yaw_q(-yaw)
        targets = [None, None]
        need = 0.0
        for si, sd in enumerate('LR'):
            ballM = WP[IDX['toe_' + sd]]
            ballW = qrotate(R, ballM)
            if lock[si] is None:
                lock[si] = ballW.copy()
            if step[si] >= 1.0:
                if np.linalg.norm((lock[si] - ballW)[[0, 2]]) > 0.32:
                    sfrom[si] = lock[si].copy()
                    step[si] = 0.0
            tgt = lock[si]
            if step[si] < 1.0:
                step[si] = min(1.0, step[si] + dt / 0.2)
                e = step[si] * step[si] * (3 - 2 * step[si])
                goal = np.array([ballW[0], lock[si][1], ballW[2]])
                tgt = sfrom[si] + (goal - sfrom[si]) * e + np.array([0.0, 0.09 * np.sin(np.pi * step[si]), 0.0])
                if step[si] >= 1.0:
                    lock[si] = goal
            tm = qrotate(Rinv, tgt)
            off = WP[IDX['toe_' + sd]] - WP[IDX['foot_' + sd]]
            ank = tm - off
            hip = WP[IDX['thigh_' + sd]]
            reach = (np.linalg.norm(WP[IDX['shin_' + sd]] - hip) + np.linalg.norm(WP[IDX['foot_' + sd]] - WP[IDX['shin_' + sd]])) * 0.995
            h = ank - hip
            dxz = h[0] ** 2 + h[2] ** 2
            if dxz < reach * reach:
                need = max(need, (-h[1]) - np.sqrt(reach * reach - dxz))
            else:
                need = max(need, 0.07)
            targets[si] = ank
        drop = min(0.07, max(need, drop - dt * 0.35))
        if drop > 1e-4:
            p.t[IDX['pelvis']] = p.t[IDX['pelvis']] - np.array([0.0, drop, 0.0])
        WQ, WP = p.world()
        for si, sd in enumerate('LR'):
            th, sh = IDX['thigh_' + sd], IDX['shin_' + sd]
            mid = 0.5 * (WP[th] + targets[si])
            pole = WP[sh] + (WP[sh] - mid) * 2.0 + np.array([0.0, 0.0, 0.05])
            S.solve_limb(p, 'thigh_' + sd, 'shin_' + sd, 'foot_' + sd, targets[si], pole, end_rot=WQ[IDX['foot_' + sd]])
            WQ, WP = p.world()
        out.append((p.track_row(), yaw))
    return out
