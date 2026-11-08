"""Headless Blender reader of the mocap sources: imports a BVH with Blender's own importer (io_anim_bvh) or one action
of a glTF (io_scene_gltf2), samples the evaluated armature at given times and returns, per source joint, world
rotations (3×3) and joint positions in GAME space (metres, y up), plus the rest pose.

Game ← Blender: (x, y, z)_game = (−X, Z, Y)_blender (ihv.py convention). Samples are cached per (file, times) for the
life of the process: the four classes retarget the same source samples."""
import hashlib
import math

import bpy
import numpy as np

G = np.array([[-1.0, 0.0, 0.0], [0.0, 0.0, 1.0], [0.0, 1.0, 0.0]])     # blender -> game (det +1)
_CACHE = {}


def to_game_rot(M3):
    return G @ M3 @ G.T


def frame_time(path):
    with open(path) as fh:
        for line in fh:
            if line.strip().startswith('Frame Time:'):
                return float(line.split()[-1])
    raise SystemExit(f'{path}: no Frame Time')


def _key(path, scale, times, extra=''):
    h = hashlib.md5(np.ascontiguousarray(np.asarray(times, dtype=np.float64)).tobytes()).hexdigest()
    return (path, float(scale), h, extra)


def _sample(arm, times, f0, src_fps, fmax):
    names = [b.name for b in arm.data.bones]
    MW = np.array(arm.matrix_world)
    sc = bpy.context.scene
    times = np.minimum(np.asarray(times, dtype=np.float64), fmax)
    R = np.zeros((len(times), len(names), 3, 3))
    P = np.zeros((len(times), len(names), 3))
    for i, t in enumerate(times):
        fr = f0 + t * src_fps
        fi = int(math.floor(fr + 1e-9))
        sc.frame_set(fi, subframe=float(min(max(fr - fi, 0.0), 0.999999)))
        for j, pb in enumerate(arm.pose.bones):
            M = MW @ np.array(pb.matrix)
            R[i, j] = to_game_rot(M[:3, :3])
            P[i, j] = G @ M[:3, 3]
    return R, P


def _rest(arm):
    names = [b.name for b in arm.data.bones]
    parent = [names.index(b.parent.name) if b.parent else -1 for b in arm.data.bones]
    MW = np.array(arm.matrix_world)
    rest_R = np.stack([to_game_rot(MW[:3, :3] @ np.array(b.matrix_local)[:3, :3]) for b in arm.data.bones])
    rest_P = np.stack([G @ (MW @ np.r_[np.array(b.head_local), 1.0])[:3] for b in arm.data.bones])
    return names, parent, rest_R, rest_P


def duration(path):
    """Length of a BVH take (s) from its header."""
    with open(path) as fh:
        for line in fh:
            if line.strip().startswith('Frames:'):
                n = int(line.split()[-1])
                break
    return (n - 1) * frame_time(path)


def load(path, scale, times=None, fps_out=30.0, z_up=False):
    """dict(names, parent, rest_R, rest_P, R (n,J,3,3), P (n,J,3), fps, src_fps, duration). `times` (s from the first
    frame of the file) default: the whole take at fps_out. `z_up`: a file written by Blender's own BVH exporter (its
    Z-up axes: the Quaternius cuts of ual_cut.py), read without the Y-up conversion."""
    src_dt = frame_time(path)
    dur = duration(path)
    if times is None:
        times = np.arange(0.0, dur + 1e-9, 1.0 / fps_out)
    k = _key(path, scale, times, 'z' if z_up else '')
    if k in _CACHE:
        return dict(_CACHE[k])
    bpy.ops.wm.read_factory_settings(use_empty=True)
    fwd, up = ('Y', 'Z') if z_up else ('-Z', 'Y')
    bpy.ops.import_anim.bvh(filepath=path, global_scale=scale, rotate_mode='NATIVE', axis_forward=fwd, axis_up=up,
                            update_scene_fps=False, update_scene_duration=False, use_fps_scale=False)
    arm = [o for o in bpy.context.scene.objects if o.type == 'ARMATURE'][0]
    f0 = int(round(arm.animation_data.action.frame_range[0]))
    names, parent, rest_R, rest_P = _rest(arm)
    R, P = _sample(arm, times, f0, 1.0 / src_dt, dur)
    d = dict(names=names, parent=parent, rest_R=rest_R, rest_P=rest_P, R=R, P=P, fps=fps_out, src_fps=1.0 / src_dt,
             duration=dur)
    _CACHE[k] = d
    return dict(d)


def load_glb_action(path, action_name, times=None, fps_out=30.0):
    """One action of a glTF (Quaternius UAL, Rigify DEF- skeleton) sampled like load()."""
    k = _key(path, 1.0, times if times is not None else [], action_name)
    if k in _CACHE:
        return dict(_CACHE[k])
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=path)
    arm = [o for o in bpy.context.scene.objects if o.type == 'ARMATURE'][0]
    act = bpy.data.actions[action_name]
    if arm.animation_data is None:
        arm.animation_data_create()
    arm.animation_data.action = act
    if hasattr(arm.animation_data, 'action_slot') and act.slots:
        arm.animation_data.action_slot = act.slots[0]
    f0, f1 = act.frame_range
    sc = bpy.context.scene
    src_fps = sc.render.fps / sc.render.fps_base
    dur = (f1 - f0) / src_fps
    if times is None:
        times = np.arange(0.0, dur + 1e-9, 1.0 / fps_out)
    names, parent, rest_R, rest_P = _rest(arm)
    R, P = _sample(arm, times, f0, src_fps, dur)
    d = dict(names=names, parent=parent, rest_R=rest_R, rest_P=rest_P, R=R, P=P, fps=fps_out, src_fps=src_fps,
             duration=dur)
    _CACHE[k] = d
    return dict(d)
