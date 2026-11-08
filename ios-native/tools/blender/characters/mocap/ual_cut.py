"""Authoring tool (feel build A3): export the Quaternius Universal Animation Library actions the clips use (CC0) from
the library's glTF (the Godot-standard Rigify build, `ual1_rigify.glb`) into small BVH files in sources/
(ual_<action>.bvh, the 53 bones of its armature at its own 24 fps) — the build then reads them like the CMU takes
(bvhsrc.load, the 'ual' bone map of rtg); the 6.7 MB glTF itself is never committed.

  venv/bin/python -B characters/mocap/ual_cut.py PATH/ual1_rigify.glb"""
import hashlib
import json
import os
import sys

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
ACTIONS = ['Death01', 'Fixing_Kneeling']


def main(glb):
    man_p = os.path.join(HERE, 'sources', 'manifest.json')
    man = json.load(open(man_p))
    for a in ACTIONS:
        bpy.ops.wm.read_factory_settings(use_empty=True)
        bpy.ops.import_scene.gltf(filepath=glb)
        arm = [o for o in bpy.context.scene.objects if o.type == 'ARMATURE'][0]
        act = bpy.data.actions[a]
        if arm.animation_data is None:
            arm.animation_data_create()
        arm.animation_data.action = act
        if hasattr(arm.animation_data, 'action_slot') and act.slots:
            arm.animation_data.action_slot = act.slots[0]
        f0, f1 = (int(round(x)) for x in act.frame_range)
        for o in bpy.context.scene.objects:
            o.select_set(o == arm)
        bpy.context.view_layer.objects.active = arm
        take = 'ual_' + a.lower()
        out = os.path.join(HERE, 'sources', take + '.bvh')
        bpy.ops.export_anim.bvh(filepath=out, frame_start=f0, frame_end=f1, rotate_mode='NATIVE', root_transform_only=True)
        n = f1 - f0 + 1
        fps = bpy.context.scene.render.fps / bpy.context.scene.render.fps_base
        man[take] = dict(file=take + '.bvh', first=0, frame_time=round(1.0 / fps, 7), frames=n, of=n,
                         original=f'ual1_rigify.glb#{a}', t0=0.0)
        print(take, n, 'frames', os.path.getsize(out), 'bytes', hashlib.sha256(open(out, 'rb').read()).hexdigest()[:16])
    json.dump(man, open(man_p, 'w'), indent=1, sort_keys=True)


if __name__ == '__main__':
    main(sys.argv[sys.argv.index('--') + 1] if '--' in sys.argv else sys.argv[1])
