"""Station kit build (headless Blender, pip bpy 5.2.2 / Python 3.13):

  venv/bin/python kit/build_kit.py OUTDIR [--from-blend kit_src.blend] [--previews DIR]

1. every piece of pieces.PIECES is built from kitgeo primitives (game space) into a Blender object (Blender space:
   X = -x, Y = z, Z = y) carrying its material attributes as face attributes (tint, metal, emis, layer, flags) and
   two UV maps: `trim` (uv0, the trim-sheet rule; Blender v = 1 - Metal v) and `ao`;
2. the `ao` maps of all pieces are unwrapped (smart project) and packed into ONE atlas, and Cycles bakes ambient
   occlusion into it (each piece alone over its own ground / ceiling plane, 0.6 m reach);
3. OUTDIR/kit_src.blend is saved (the editable source: an artist moves vertices or repaints face attributes there and
   re-exports with --from-blend, which skips steps 1–2's geometry and keeps the saved UVs and atlas);
4. the pieces are exported FROM THE BLENDER MESHES (corner normals, MikkTSpace tangents of `trim`, both UV maps,
   the face attributes) into OUTDIR/station.ihk, and the atlas into OUTDIR/kit_ao.iht (ASTC 6×6 + mips).
Deterministic: fixed seeds, fixed thread count, sorted output; two clean builds give identical bytes (build.sh
--verify checks it).
"""
import json
import math
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import bpy  # noqa: E402

import ihk  # noqa: E402
import iht  # noqa: E402
import kitgeo  # noqa: E402
import pieces  # noqa: E402

T0 = time.time()
AO_SIZE = 1024
AO_SAMPLES = 96
AO_DIST = 0.6
THREADS = 3
GRID = 9.0          # metres between pieces in the bake scene (no cross-occlusion)


def log(*a):
    print(f'[{time.time() - T0:6.1f}s]', *a, flush=True)


def g2b(p):
    return (-p[0], p[2], p[1])


def b2g(a):
    """(n, 3) Blender → game."""
    return np.stack([-a[:, 0], a[:, 2], a[:, 1]], 1)


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.device = 'CPU'
    sc.cycles.seed = 0
    sc.cycles.use_animated_seed = False
    sc.render.threads_mode = 'FIXED'
    sc.render.threads = THREADS
    return sc


# ---------------------------------------------------------------- 1. kitgeo → Blender objects
def triangulate_ngons(mesh):
    """Fan-split faces of more than 4 corners (MikkTSpace tangents need triangles / quads); convex faces only."""
    out = []
    for f in mesh.faces:
        if len(f.idx) <= 4:
            out.append(f)
            continue
        for k in range(1, len(f.idx) - 1):
            out.append(kitgeo.Face([f.idx[0], f.idx[k], f.idx[k + 1]], f.tint, f.metal, f.emis, f.layer, f.flags,
                                   [f.uv[0], f.uv[k], f.uv[k + 1]], f.smooth))
    mesh.faces = out
    return mesh


def make_object(name, mesh, loc):
    mesh = triangulate_ngons(mesh)
    V = [g2b(p) for p in mesh.V]
    F = [f.idx for f in mesh.faces]
    me = bpy.data.meshes.new(name)
    me.from_pydata(V, [], F)
    me.validate(clean_customdata=False)
    assert len(me.polygons) == len(F), f'{name}: {len(me.polygons)} polygons from {len(F)} faces'
    for nm, typ in (('tint', 'INT'), ('layer', 'INT'), ('flags', 'INT'), ('metal', 'FLOAT'), ('emis', 'FLOAT')):
        me.attributes.new(nm, typ, 'FACE')
    me.attributes['tint'].data.foreach_set('value', [f.tint for f in mesh.faces])
    me.attributes['layer'].data.foreach_set('value', [f.layer for f in mesh.faces])
    me.attributes['flags'].data.foreach_set('value', [f.flags for f in mesh.faces])
    me.attributes['metal'].data.foreach_set('value', [f.metal for f in mesh.faces])
    me.attributes['emis'].data.foreach_set('value', [f.emis for f in mesh.faces])
    me.polygons.foreach_set('use_smooth', [f.smooth for f in mesh.faces])
    trim = me.uv_layers.new(name='trim')
    uv = []
    for p, f in zip(me.polygons, mesh.faces):
        assert p.loop_total == len(f.uv)
        for (u, v) in f.uv:
            uv += [u, 1.0 - v]
    trim.data.foreach_set('uv', uv)
    me.uv_layers.new(name='ao')
    # hard edges between smooth faces of different parts (caps of round parts stay crisp)
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = loc
    return ob


def occluder(name, ctx, ob):
    lo = np.min([v[:] for v in ob.bound_box], 0)
    hi = np.max([v[:] for v in ob.bound_box], 0)
    sx, sy = (hi[0] - lo[0]) + 2.0, (hi[1] - lo[1]) + 2.0
    bpy.ops.mesh.primitive_plane_add(size=1.0, location=(ob.location[0], ob.location[1], ob.location[2]))
    pl = bpy.context.active_object
    pl.name = name + '.occ'
    pl.scale = (sx, sy, 1.0)
    if ctx == 'ceiling':
        pl.location.z += 0.002
    else:
        pl.location.z -= 0.002
    return pl


def build_scene():
    objs = {}
    occs = []
    names = sorted(pieces.PIECES)
    cols = 5
    for k, name in enumerate(names):
        fn, pflags, ctx, budget = pieces.PIECES[name]
        m = fn()
        loc = ((k % cols) * GRID, (k // cols) * GRID, 0.0)
        ob = make_object(name, m, loc)
        ob['piece_flags'] = int(pflags)
        ob['budget'] = int(budget)
        objs[name] = ob
        if ctx in ('floor', 'ceiling'):
            occs.append(occluder(name, ctx, ob))
    return objs, occs


# ---------------------------------------------------------------- 2. AO atlas
def unwrap_ao(objs):
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    for o in objs.values():
        o.data.uv_layers.active = o.data.uv_layers['ao']
        o.select_set(True)
    first = objs[sorted(objs)[0]]
    bpy.context.view_layer.objects.active = first
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=0.0, area_weight=0.0, correct_aspect=True,
                             scale_to_bounds=False)
    bpy.ops.uv.pack_islands(udim_source='CLOSEST_UDIM', rotate=False, margin=0.004)
    bpy.ops.object.mode_set(mode='OBJECT')


def bake_ao(objs):
    sc = bpy.context.scene
    w = bpy.data.worlds.new('w')
    sc.world = w
    w.use_nodes = True
    w.light_settings.distance = AO_DIST
    img = bpy.data.images.new('kit_ao', AO_SIZE, AO_SIZE, alpha=False, float_buffer=True)
    img.colorspace_settings.name = 'Non-Color'
    mat = bpy.data.materials.new('ao_bake')
    mat.use_nodes = True
    tn = mat.node_tree.nodes.new('ShaderNodeTexImage')
    tn.image = img
    mat.node_tree.nodes.active = tn
    for o in objs.values():
        o.data.materials.clear()
        o.data.materials.append(mat)
        o.data.uv_layers.active = o.data.uv_layers['ao']
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    for o in objs.values():
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[sorted(objs)[0]]
    sc.cycles.samples = AO_SAMPLES
    t = time.time()
    bpy.ops.object.bake(type='AO', margin=6, use_clear=True)
    log(f'baked AO atlas {AO_SIZE}² ({AO_SAMPLES} samples) in {time.time() - t:.1f}s')
    a = np.empty(AO_SIZE * AO_SIZE * 4, np.float32)
    img.pixels.foreach_get(a)
    return a.reshape(AO_SIZE, AO_SIZE, 4)[::-1, :, 0].copy()        # Metal row order (top first)


# ---------------------------------------------------------------- 4. export
def export_piece(ob):
    me = ob.data
    me.calc_loop_triangles()
    me.calc_tangents(uvmap='trim')
    nl = len(me.loops)
    co = np.empty(len(me.vertices) * 3, np.float64)
    me.vertices.foreach_get('co', co)
    co = co.reshape(-1, 3)
    vidx = np.empty(nl, np.int64)
    me.loops.foreach_get('vertex_index', vidx)
    cn = np.empty(nl * 3, np.float64)
    me.corner_normals.foreach_get('vector', cn) if hasattr(me, 'corner_normals') else me.loops.foreach_get('normal', cn)
    tg = np.empty(nl * 3, np.float64)
    me.loops.foreach_get('tangent', tg)
    sg = np.empty(nl, np.float64)
    me.loops.foreach_get('bitangent_sign', sg)
    uv0 = np.empty(nl * 2, np.float64)
    me.uv_layers['trim'].data.foreach_get('uv', uv0)
    uv1 = np.empty(nl * 2, np.float64)
    me.uv_layers['ao'].data.foreach_get('uv', uv1)
    uv0 = uv0.reshape(-1, 2)
    uv1 = uv1.reshape(-1, 2)
    # face attributes → per loop
    npoly = len(me.polygons)
    lstart = np.empty(npoly, np.int64)
    ltot = np.empty(npoly, np.int64)
    me.polygons.foreach_get('loop_start', lstart)
    me.polygons.foreach_get('loop_total', ltot)
    poly_of_loop = np.repeat(np.arange(npoly), ltot)
    att = {}
    for nm, dt in (('tint', np.int64), ('layer', np.int64), ('flags', np.int64), ('metal', np.float64), ('emis', np.float64)):
        a = np.empty(npoly, np.int32 if dt is np.int64 else np.float32)
        me.attributes[nm].data.foreach_get('value', a)
        att[nm] = a.astype(dt)[poly_of_loop]
    tint = np.stack([(att['tint'] >> 16) & 255, (att['tint'] >> 8) & 255, att['tint'] & 255], 1) / 255.0
    pos = b2g(co[vidx])
    nrm = b2g(cn.reshape(-1, 3))
    tan = b2g(tg.reshape(-1, 3))
    layer = att['layer']
    # untextured faces: a plain tangent so the normal stays the vertex normal
    tan = np.where((layer == kitgeo.NONE)[:, None] & (np.linalg.norm(tan, axis=1) < 0.5)[:, None], [1.0, 0.0, 0.0], tan)
    V = ihk.pack_vertices(pos, nrm, tan, sg, np.stack([uv0[:, 0], 1.0 - uv0[:, 1]], 1),
                          np.stack([uv1[:, 0], 1.0 - uv1[:, 1]], 1), tint, att['metal'], att['emis'], layer, att['flags'],
                          ao=255)
    # weld identical corners (byte-exact) into shared vertices, deterministic first-seen order
    raw = V.view(np.dtype((np.void, V.dtype.itemsize)))
    _, first, inv = np.unique(raw, return_index=True, return_inverse=True)
    order = np.argsort(first, kind='stable')
    remap = np.empty_like(order)
    remap[order] = np.arange(len(order))
    Vu = V[first[order]]
    tri = np.empty(len(me.loop_triangles) * 3, np.int64)
    me.loop_triangles.foreach_get('loops', tri)
    idx = remap[inv.ravel()][tri]
    me.free_tangents()
    lo = Vu['pos'][:, :3].astype(np.float64).min(0)
    hi = Vu['pos'][:, :3].astype(np.float64).max(0)
    a = uv1
    ao_rect = (float(a[:, 0].min()), float(1 - a[:, 1].max()), float(a[:, 0].max()), float(1 - a[:, 1].min()))
    return dict(name=ob.name, vertices=Vu, indices=idx, flags=int(ob.get('piece_flags', 0)), ao_rect=ao_rect,
                budget=int(ob.get('budget', 200)), bounds=(lo.tolist(), hi.tolist()))


def encode_ao(ao, path):
    img = np.zeros(ao.shape + (4,), np.float32)
    img[..., 0] = img[..., 1] = img[..., 2] = np.clip(ao, 0, 1)
    img[..., 3] = 1.0
    levels = iht.encode_layers([img], 3, 'data')
    return iht.write(path, 3, AO_SIZE, AO_SIZE, levels)


def main():
    args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else sys.argv[1:]
    out = os.path.abspath(args[0])
    os.makedirs(out, exist_ok=True)
    src_blend = args[args.index('--from-blend') + 1] if '--from-blend' in args else None
    prev = os.path.abspath(args[args.index('--previews') + 1]) if '--previews' in args else None
    report = dict(pieces={}, log=[])
    if src_blend:
        bpy.ops.wm.open_mainfile(filepath=src_blend)
        objs = {o.name: o for o in bpy.data.objects if 'piece_flags' in o}
        img = bpy.data.images['kit_ao']
        a = np.empty(AO_SIZE * AO_SIZE * 4, np.float32)
        img.pixels.foreach_get(a)
        ao = a.reshape(AO_SIZE, AO_SIZE, 4)[::-1, :, 0].copy()
        log(f'opened {src_blend}: {len(objs)} pieces')
    else:
        reset()
        objs, occs = build_scene()
        log(f'built {len(objs)} pieces, {sum(len(o.data.polygons) for o in objs.values())} polygons')
        unwrap_ao(objs)
        ao = bake_ao(objs)
        img = bpy.data.images['kit_ao']
        img.pack()
        bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out, 'kit_src.blend'), compress=True)
        log('saved kit_src.blend')
    exported = [export_piece(objs[n]) for n in sorted(objs)]
    size = ihk.write(os.path.join(out, 'station.ihk'), exported, layer_count=4, ao_size=AO_SIZE,
                     trim_density=kitgeo.DENSITY, kit_name='station')
    log(f'wrote station.ihk: {size} bytes, {len(exported)} pieces, '
        f'{sum(len(p["indices"]) // 3 for p in exported)} triangles, {sum(len(p["vertices"]) for p in exported)} vertices')
    asz = encode_ao(ao, os.path.join(out, 'kit_ao.iht'))
    log(f'wrote kit_ao.iht: {asz} bytes (ASTC 6x6, {AO_SIZE}², mips)')
    for p in exported:
        report['pieces'][p['name']] = dict(triangles=len(p['indices']) // 3, vertices=len(p['vertices']),
                                           budget=p['budget'], flags=p['flags'], bounds=p['bounds'])
    report['ao'] = dict(size=AO_SIZE, samples=AO_SAMPLES, distance=AO_DIST, mean=float(ao.mean()))
    with open(os.path.join(out, 'kit_build.json'), 'w') as f:
        json.dump(report, f, indent=1, sort_keys=True)
    if prev:
        os.makedirs(prev, exist_ok=True)
        from PIL import Image
        Image.fromarray(np.clip(ao * 255, 0, 255).astype(np.uint8)).resize((512, 512), Image.LANCZOS).save(
            os.path.join(prev, 'kit_ao.png'))
    log('done')


main()
