"""Game-camera read-back of the SHIPPED station kit (never the source scene): a fresh Blender process parses
App/Resources/Kit/station.ihk (ihk.read) and the trim / AO textures (iht.read + astcenc decode), rebuilds every piece
with its uv0 / uv1, normals, tint, metal, emission and flags, lays them out on a strip of grating deck and renders it
with Cycles from the game camera (pitch 57°, yaw 45°, fov 50) under one warm flashlight and faint moonlight — the
blend's darkness, at 3× iPhone pixel density for the crops.

  venv/bin/python readback_kit.py App/Resources/Kit previews/ [--samples 48] [--res 1206]
Outputs previews/kit_readback.png (+ kit_readback_crop.png, 100 % crop of the hero row).
"""
import math
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bpy  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402

import ihk  # noqa: E402
import iht  # noqa: E402

T0 = time.time()


def log(*a):
    print(f'[{time.time() - T0:6.1f}s]', *a, flush=True)


def g2b(a):
    a = np.asarray(a, dtype=np.float64)
    return np.stack([-a[..., 0], a[..., 2], a[..., 1]], -1)


def srgb2lin(c):
    c = np.asarray(c, dtype=np.float64)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def image(name, rgba, colorspace='Non-Color'):
    h, w = rgba.shape[:2]
    im = bpy.data.images.new(name, w, h, alpha=True, float_buffer=False)
    im.colorspace_settings.name = colorspace
    px = (rgba[::-1].astype(np.float32) / 255.0).ravel()        # Blender rows bottom-up
    im.pixels.foreach_set(px)
    im.pack()
    return im


def material_for(layer, nrm_img, orm_img, ao_img):
    """Principled approximation of fs_level: tint (colour attribute) × AO (uv1 atlas) × trim AO; roughness / metal from
    the ORM layer; tangent normal from the trim layer (x in rgb, y in alpha → rebuild z)."""
    m = bpy.data.materials.new(f'kit_L{layer}' + ('' if ao_img is not None else '_noao'))
    m.use_nodes = True
    N, L = m.node_tree.nodes, m.node_tree.links
    b = N['Principled BSDF']
    tint = N.new('ShaderNodeAttribute')
    tint.attribute_name = 'tint'
    em = N.new('ShaderNodeAttribute')
    em.attribute_name = 'emis'
    metal = N.new('ShaderNodeAttribute')
    metal.attribute_name = 'metal'
    base = tint.outputs['Color']
    if ao_img is not None:          # the pieces' uv1 atlas (runtime geometry has none: fs_level's AO strength 0)
        uv1 = N.new('ShaderNodeUVMap')
        uv1.uv_map = 'ao'
        aot = N.new('ShaderNodeTexImage')
        aot.image = ao_img
        L.new(uv1.outputs['UV'], aot.inputs['Vector'])
        mul = N.new('ShaderNodeMix')
        mul.data_type = 'RGBA'
        mul.blend_type = 'MULTIPLY'
        mul.inputs['Factor'].default_value = 1.0
        L.new(tint.outputs['Color'], mul.inputs[6])
        L.new(aot.outputs['Color'], mul.inputs[7])
        base = mul.outputs[2]
    if layer is not None:
        uv0 = N.new('ShaderNodeUVMap')
        uv0.uv_map = 'trim'
        tn = N.new('ShaderNodeTexImage')
        tn.image = nrm_img
        to = N.new('ShaderNodeTexImage')
        to.image = orm_img
        for t in (tn, to):
            t.extension = 'REPEAT'
            L.new(uv0.outputs['UV'], t.inputs['Vector'])
        # normal: x = r, y = alpha → (x, y, sqrt(1 - x² - y²)) in 0..1 encoding
        sx = N.new('ShaderNodeSeparateColor')
        L.new(tn.outputs['Color'], sx.inputs['Color'])
        comb = N.new('ShaderNodeCombineColor')
        L.new(sx.outputs['Red'], comb.inputs['Red'])
        L.new(tn.outputs['Alpha'], comb.inputs['Green'])
        comb.inputs['Blue'].default_value = 1.0
        nm = N.new('ShaderNodeNormalMap')
        nm.uv_map = 'trim'
        L.new(comb.outputs['Color'], nm.inputs['Color'])
        L.new(nm.outputs['Normal'], b.inputs['Normal'])
        so = N.new('ShaderNodeSeparateColor')
        L.new(to.outputs['Color'], so.inputs['Color'])
        mul2 = N.new('ShaderNodeMix')
        mul2.data_type = 'RGBA'
        mul2.blend_type = 'MULTIPLY'
        mul2.inputs['Factor'].default_value = 1.0
        L.new(base, mul2.inputs[6])
        L.new(so.outputs['Red'], mul2.inputs[7])
        base = mul2.outputs[2]
        L.new(so.outputs['Green'], b.inputs['Roughness'])
        mm = N.new('ShaderNodeMath')
        mm.operation = 'MULTIPLY'
        L.new(so.outputs['Blue'], mm.inputs[0])
        L.new(metal.outputs['Fac'], mm.inputs[1])
        L.new(mm.outputs[0], b.inputs['Metallic'])
    else:
        b.inputs['Roughness'].default_value = 0.6
        L.new(metal.outputs['Fac'], b.inputs['Metallic'])
    L.new(base, b.inputs['Base Color'])
    L.new(tint.outputs['Color'], b.inputs['Emission Color'])
    L.new(em.outputs['Fac'], b.inputs['Emission Strength'])
    return m


def piece_object(P, mats, name):
    V = P['vertices']
    I = P['indices']
    pos = g2b(V['pos'][:, :3].astype(np.float64))
    me = bpy.data.meshes.new(name)
    me.from_pydata(pos.tolist(), [], I.tolist())
    nl = len(me.loops)
    vidx = np.empty(nl, np.int64)
    me.loops.foreach_get('vertex_index', vidx)
    uv0 = V['uv0'].astype(np.float64)[vidx]
    uv1 = V['uv1'].astype(np.float64)[vidx] / 65535.0
    t = me.uv_layers.new(name='trim')
    t.data.foreach_set('uv', np.stack([uv0[:, 0], 1.0 - uv0[:, 1]], 1).ravel())
    a = me.uv_layers.new(name='ao')
    a.data.foreach_set('uv', np.stack([uv1[:, 0], 1.0 - uv1[:, 1]], 1).ravel())
    tint = srgb2lin(V['tint'][:, :3].astype(np.float64) / 255.0)
    flags = V['extra'][:, 2].astype(int)
    tint = np.where((flags & ihk.F_SNOW)[:, None] > 0, [0.55, 0.6, 0.66], tint)
    tint = np.where((flags & ihk.F_ICE)[:, None] > 0, [0.06, 0.09, 0.12], tint)
    ca = me.color_attributes.new('tint', 'FLOAT_COLOR', 'POINT')
    ca.data.foreach_set('color', np.concatenate([tint, np.ones((len(V), 1))], 1).ravel())
    for nm, vals in (('emis', V['extra'][:, 0].astype(np.float64) / 32.0), ('metal', V['tint'][:, 3].astype(np.float64) / 255.0)):
        at = me.attributes.new(nm, 'FLOAT', 'POINT')
        at.data.foreach_set('value', vals)
    # material per triangle from its first corner's layer
    layer = V['extra'][:, 1].astype(int)[I[:, 0]]
    keys = sorted(mats)
    for k in keys:
        me.materials.append(mats[k])
    me.polygons.foreach_set('material_index', [keys.index(l if l in mats else 255) for l in layer])
    nrm = g2b(V['nrm'][:, :3].astype(np.float64) / 127.0)
    me.normals_split_custom_set_from_vertices(nrm.tolist())
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def main():
    args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else sys.argv[1:]
    kit_dir, out = os.path.abspath(args[0]), os.path.abspath(args[1])
    samples = int(args[args.index('--samples') + 1]) if '--samples' in args else 48
    res = int(args[args.index('--res') + 1]) if '--res' in args else 1206
    os.makedirs(out, exist_ok=True)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.device = 'CPU'
    sc.cycles.samples = samples
    sc.cycles.use_denoising = True
    sc.render.threads_mode = 'FIXED'
    sc.render.threads = 3
    sc.view_settings.view_transform = 'AgX'
    sc.render.resolution_x = sc.render.resolution_y = res
    D = ihk.read(os.path.join(kit_dir, 'station.ihk'))
    TN = iht.read(os.path.join(kit_dir, 'trim_normal.iht'))
    TO = iht.read(os.path.join(kit_dir, 'trim_orm.iht'))
    TA = iht.read(os.path.join(kit_dir, 'kit_ao.iht'))
    ao_img = image('ao', iht.decode_level(TA, 0, 0))
    mats = {}
    for l in range(TN['layers']):
        mats[l] = material_for(l, image(f'n{l}', iht.decode_level(TN, l, 0)), image(f'o{l}', iht.decode_level(TO, l, 0)), ao_img)
    mats[255] = material_for(None, None, None, ao_img)
    log(f'decoded {TN["layers"]} trim layers + AO atlas')
    # deck strip (gratings, uv = world xz / 2 m) under a grid of the pieces
    names = [p['name'] for p in D['pieces'] if p['name'] != 'beacon_head']
    cols = 5
    sp = 4.0
    rows = (len(names) + cols - 1) // cols
    W, H = cols * sp + 2, rows * sp + 2
    deck = bpy.data.meshes.new('deck')
    x0, z0 = -sp, -sp
    gpos = [(x0, 0, z0), (x0, 0, z0 + H), (x0 + W, 0, z0 + H), (x0 + W, 0, z0)]
    deck.from_pydata(g2b(np.array(gpos)).tolist(), [], [(0, 1, 2, 3)])
    t = deck.uv_layers.new(name='trim')
    t.data.foreach_set('uv', np.array([[p[0] * 0.5, 1.0 - p[2] * 0.5] for p in gpos]).ravel())
    deck.uv_layers.new(name='ao')
    ca = deck.color_attributes.new('tint', 'FLOAT_COLOR', 'POINT')
    ca.data.foreach_set('color', np.tile(np.concatenate([srgb2lin(np.array([0x2b, 0x33, 0x3c]) / 255.0), [1.0]]), 4))
    for nm, v in (('emis', 0.0), ('metal', 0.75)):
        at = deck.attributes.new(nm, 'FLOAT', 'POINT')
        at.data.foreach_set('value', [v] * 4)
    deck.materials.append(material_for(0, bpy.data.images['n0'], bpy.data.images['o0'], None))
    dob = bpy.data.objects.new('deck', deck)
    sc.collection.objects.link(dob)
    byname = {p['name']: p for p in D['pieces']}
    for k, n in enumerate(names):
        ob = piece_object(byname[n], mats, n)
        x, z = (k % cols) * sp, (k // cols) * sp
        y = 0.0
        if n.startswith('icicles') or n == 'support_cap' or n == 'pipe_bracket':
            y = 1.2
        ob.location = Vector(g2b(np.array([x, y, z])).tolist())
    # lights: a warm flashlight from behind the camera side, faint cold moonlight, a cold dark world
    w = bpy.data.worlds.new('w')
    sc.world = w
    w.use_nodes = True
    w.node_tree.nodes['Background'].inputs[0].default_value = (0.006, 0.009, 0.016, 1)
    cx, cz = (cols - 1) * sp / 2, (rows - 1) * sp / 2
    ld = bpy.data.lights.new('flash', 'SPOT')
    ld.energy = 9000
    ld.spot_size = math.radians(58)
    ld.spot_blend = 0.45
    ld.color = (1.0, 0.92, 0.8)
    ld.shadow_soft_size = 0.05
    fl = bpy.data.objects.new('flash', ld)
    sc.collection.objects.link(fl)
    fl.location = Vector(g2b(np.array([cx + 7.0, 6.0, cz + 7.0])).tolist())
    fl.rotation_euler = (Vector(g2b(np.array([cx, 0.0, cz])).tolist()) - fl.location).to_track_quat('-Z', 'Y').to_euler()
    md = bpy.data.lights.new('moon', 'SUN')
    md.energy = 0.25
    md.color = (0.55, 0.66, 0.87)
    mo = bpy.data.objects.new('moon', md)
    sc.collection.objects.link(mo)
    mo.rotation_euler = (math.radians(40), 0, math.radians(-30))
    # game camera: pitch 57°, yaw 45° (camera at +x +z looking toward -x -z), fov 50
    cd = bpy.data.cameras.new('cam')
    cd.angle = math.radians(50)
    cam = bpy.data.objects.new('cam', cd)
    sc.collection.objects.link(cam)
    dist = max(W, H) * 1.05
    pitch = math.radians(57)
    tgt = np.array([cx, 0.0, cz])
    eye = tgt + np.array([math.cos(pitch) * math.sin(math.radians(45)), math.sin(pitch), math.cos(pitch) * math.cos(math.radians(45))]) * dist
    cam.location = Vector(g2b(eye).tolist())
    cam.rotation_euler = (Vector(g2b(tgt).tolist()) - cam.location).to_track_quat('-Z', 'Y').to_euler()
    sc.camera = cam
    p = os.path.join(out, 'kit_readback.png')
    sc.render.filepath = p
    t = time.time()
    bpy.ops.render.render(write_still=True)
    log(f'rendered {p} ({res}², {samples} samples) in {time.time() - t:.1f}s')


main()
