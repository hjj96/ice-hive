"""Look-dev previews of the marine SOURCE (WP4 «Отряд»): builds marines.build(cls) straight from the catalogue (no
UV, bake, clips or export) and renders it in Cycles with plain slot materials, so a modelling change can be judged in
about a minute per class. The shipped files are judged with readback_marines.py.

  venv/bin/python characters/preview_marines.py OUT.png [--classes assault,pyro] [--hi] [--samples 16]
        [--views front,back,side,close,top] [--size 420x600] [--pose stance|bind|<clip>:<frame>]

Each row is one class; --hi renders the HIGH bake source (seams, bolts, vents, decals) instead of the shipped LOW.
"""
import math
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import bpy  # noqa: E402
from mathutils import Vector  # noqa: E402

import build_marines as BM  # noqa: E402
import marines as MR  # noqa: E402
import motion  # noqa: E402
import skeleton as SK  # noqa: E402

T0 = time.time()


def log(*a):
    print(f'[{time.time() - T0:6.1f}s]', *a, flush=True)


def g(x, y, z):
    return (-x, z, y)


def lin(c):
    c = np.asarray(c, dtype=np.float64) / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def scene(samples):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.device = 'CPU'
    sc.cycles.samples = samples
    sc.cycles.use_denoising = True
    sc.cycles.seed = 0
    sc.render.threads_mode = 'FIXED'
    sc.render.threads = 3
    sc.view_settings.view_transform = 'AgX'
    sc.view_settings.look = 'AgX - Medium High Contrast'
    w = bpy.data.worlds.new('w')
    sc.world = w
    w.use_nodes = True
    bg = w.node_tree.nodes['Background']
    bg.inputs[0].default_value = (0.012, 0.016, 0.026, 1)
    bg.inputs[1].default_value = 1.0
    return sc


def slot_materials(cls):
    out = []
    for slot, (alb, rough, metal, glow, flags) in sorted(MR.materials(cls).items()):
        m = bpy.data.materials.new(f'slot{slot}')
        m.use_nodes = True
        b = m.node_tree.nodes['Principled BSDF']
        c = lin(alb)
        b.inputs['Base Color'].default_value = (c[0], c[1], c[2], 1)
        b.inputs['Roughness'].default_value = rough
        b.inputs['Metallic'].default_value = metal
        if glow > 0:
            b.inputs['Emission Color'].default_value = (c[0], c[1], c[2], 1)
            b.inputs['Emission Strength'].default_value = 9.0 * glow
        if flags & 4:
            b.inputs['Coat Weight'].default_value = 0.35
            b.inputs['Coat Roughness'].default_value = 0.18
        out.append((slot, m))
    return out


def deck():
    bpy.ops.mesh.primitive_plane_add(size=30.0)
    ob = bpy.context.active_object
    m = bpy.data.materials.new('deck')
    m.use_nodes = True
    N, L = m.node_tree.nodes, m.node_tree.links
    b = N['Principled BSDF']
    br = N.new('ShaderNodeTexBrick')
    br.inputs['Scale'].default_value = 1.0
    br.inputs['Mortar Size'].default_value = 0.03
    br.inputs['Color1'].default_value = (0.05, 0.055, 0.065, 1)
    br.inputs['Color2'].default_value = (0.045, 0.05, 0.06, 1)
    br.inputs['Mortar'].default_value = (0.012, 0.013, 0.016, 1)
    tc = N.new('ShaderNodeTexCoord')
    L.new(tc.outputs['Object'], br.inputs['Vector'])
    L.new(br.outputs['Color'], b.inputs['Base Color'])
    b.inputs['Roughness'].default_value = 0.42
    b.inputs['Metallic'].default_value = 0.6
    ob.data.materials.append(m)


def light(kind, name, energy, color, loc, aim, size=None, spot=None):
    sc = bpy.context.scene
    ld = bpy.data.lights.new(name, kind)
    ld.energy = energy
    ld.color = color
    if size is not None:
        if kind == 'AREA':
            ld.size = size
        else:
            ld.shadow_soft_size = size
    if spot is not None:
        ld.spot_size = math.radians(spot)
        ld.spot_blend = 0.6
    o = bpy.data.objects.new(name, ld)
    sc.collection.objects.link(o)
    o.location = loc
    o.rotation_euler = (Vector(aim) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()


def camera(loc, target, lens=50.0):
    sc = bpy.context.scene
    cd = bpy.data.cameras.new('cam')
    cd.lens = lens
    c = bpy.data.objects.new('cam', cd)
    sc.collection.objects.link(c)
    c.location = loc
    c.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
    sc.camera = c
    return c


VIEWS = {
    # name: (eye (game), target (game), lens, key from (game))
    'front': ((1.6, 1.3, 3.0), (0.0, 1.0, 0.15), 52, (1.0, 3.2, 3.2)),
    'back': ((-1.5, 1.5, -3.0), (0.0, 1.05, 0.0), 52, (-1.0, 3.2, -2.6)),
    'side': ((3.3, 1.25, 0.3), (0.0, 1.0, 0.1), 52, (2.6, 3.0, 1.6)),
    'close': ((1.05, 1.66, 1.6), (0.1, 1.42, 0.3), 50, (-0.4, 2.6, 2.6)),
    'top': ((4.2, 7.4, 4.2), (0.15, 0.9, 0.15), 70, (0.5, 3.4, -2.5)),
    'legs': ((1.0, 0.75, 1.75), (0.0, 0.55, 0.05), 45, (1.4, 2.6, 2.6)),
    'torso': ((0.9, 1.45, 1.75), (0.0, 1.3, 0.1), 45, (-0.6, 2.8, 2.6)),
    'backc': ((-0.9, 1.6, -1.8), (0.0, 1.3, -0.1), 45, (-1.2, 2.8, -2.2)),
    'game': ((5.6, 9.2, 5.6), (0.15, 0.9, 0.15), 120, (0.5, 3.4, -2.5)),
    'head': ((0.55, 1.86, 0.95), (0.0, 1.76, 0.05), 50, (-0.5, 2.6, 2.2)),
    'headb': ((-0.6, 1.95, -0.9), (0.0, 1.72, -0.05), 50, (0.5, 2.8, -2.2)),
    'gun': ((-0.35, 1.45, 1.2), (0.2, 1.17, 0.45), 45, (-0.8, 2.6, 2.0)),
}


def posed(b, cls, pose_name):
    """Move every part (rigid, or the two-bone blend of a hose) from the bind pose into a stance pose: 'stance' = the
    aim stance every clip starts from, 'bind' = leave it."""
    if pose_name == 'bind':
        return b
    if pose_name == 'stance':
        p = motion.build(cls, motion.stance(cls))
    else:
        clip, _, frame = pose_name.partition(':')
        clips, _, _ = motion.all_clips(cls)
        c = [c for c in clips if c.name == clip][0]
        p = c.poses[int(frame or 0)]
    WQ, WP = p.world()
    bind = SK.bind_positions(cls)
    M = {}
    for k in range(SK.NB):
        m = np.eye(4)
        r = SK.qmat(WQ[k])
        m[:3, :3] = r
        m[:3, 3] = WP[k] - r @ bind[k]
        M[k] = m

    def tf(V, bone, blend=None):
        V = np.asarray(V, dtype=np.float64)
        H = np.c_[V, np.ones(len(V))]
        A = H @ M[SK.IDX[bone]].T
        if blend is None:
            return A[:, :3]
        B = H @ M[SK.IDX[blend[0]]].T
        w = np.asarray(blend[1], dtype=np.float64)[:, None]
        return (A * (1 - w) + B * w)[:, :3]

    for part in b.parts:
        part.verts = tf(part.verts, part.bone, part.blend)
    b.floaters = [((tf(V, bone), F), bone, mat) for (V, F), bone, mat in b.floaters]
    b.decals = [((tf(V, bone), F), bone, val) for (V, F), bone, val in b.decals]
    return b


def render_class(cls, hi, views, size, samples, out_dir, pose_name='stance'):
    tiles = []
    b = posed(MR.build(cls, hi=hi), cls, pose_name)
    tris = sum(p.tris for p in b.parts)
    log(f'{cls}: {"HIGH" if hi else "LOW"} {tris} triangles in {len(b.parts)} parts')
    for v in views:
        scene(samples)
        deck()
        objs, decals = BM.objects_for(b, 'p', hi)
        mats = slot_materials(cls)
        marks = []
        for name, col in (('mark_dark', (0.02, 0.022, 0.025)), ('mark_light', (0.5, 0.5, 0.48))):
            m = bpy.data.materials.new(name)
            m.use_nodes = True
            m.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = col + (1,)
            marks.append(m)
        for o in list(objs.values()) + list(decals.values()):
            BM.add_weighted_normals(o)
            o.data.materials.clear()
            for _, m in mats:
                o.data.materials.append(m)
            for m in marks:
                o.data.materials.append(m)
            lay = o.data.attributes['mat'].data
            a = np.empty(len(lay), np.int32)
            lay.foreach_get('value', a)
            if o.name.endswith('_decal'):
                dv = np.empty(len(lay), np.float32)
                o.data.attributes['decal'].data.foreach_get('value', dv)
                a = np.where(dv < 0.75, len(mats), a).astype(np.int32)
            o.data.polygons.foreach_set('material_index', a)
        eye, tgt, lens, key = VIEWS[v]
        light('SPOT', 'key', 420.0, (1.0, 0.89, 0.73), g(*key), g(*tgt), size=0.08, spot=60)
        light('AREA', 'rim', 170.0, (0.55, 0.75, 1.0), g(-eye[0] * 0.8, 3.0, -eye[2] * 0.9), g(*tgt), size=1.5)
        light('SUN', 'fill', 0.06, (0.6, 0.7, 1.0), (0, 0, 10), (0, 0, 0))
        camera(g(*eye), g(*tgt), lens)
        sc = bpy.context.scene
        sc.render.resolution_x, sc.render.resolution_y = size
        sc.render.resolution_percentage = 100
        p = os.path.join(out_dir, f'_pv_{cls}_{v}.png')
        sc.render.filepath = p
        bpy.ops.render.render(write_still=True)
        tiles.append(p)
    log(f'{cls}: rendered {len(views)} views')
    return tiles, tris


def main():
    args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else sys.argv[1:]
    out = args[0]
    classes = args[args.index('--classes') + 1].split(',') if '--classes' in args else MR.CLASSES
    views = args[args.index('--views') + 1].split(',') if '--views' in args else ['front', 'back', 'side', 'close', 'top']
    samples = int(args[args.index('--samples') + 1]) if '--samples' in args else 16
    size = tuple(int(x) for x in args[args.index('--size') + 1].split('x')) if '--size' in args else (420, 600)
    hi = '--hi' in args
    pose_name = args[args.index('--pose') + 1] if '--pose' in args else 'stance'
    out_dir = os.path.dirname(os.path.abspath(out))
    from PIL import Image, ImageDraw
    rows = []
    for cls in classes:
        rows.append((cls,) + render_class(cls, hi, views, size, samples, out_dir, pose_name))
    W, H = size
    S = Image.new('RGB', (W * len(views), (H + 30) * len(rows)), (8, 10, 14))
    d = ImageDraw.Draw(S)
    for r, (cls, tiles, tris) in enumerate(rows):
        d.text((8, r * (H + 30) + 8), f'{cls} {"HIGH" if hi else "LOW"} {tris} tris', fill=(230, 235, 240))
        for c, p in enumerate(tiles):
            S.paste(Image.open(p).convert('RGB'), (c * W, r * (H + 30) + 30))
            os.remove(p)
    S.save(out)
    log(f'→ {out}')


if __name__ == '__main__':
    main()
