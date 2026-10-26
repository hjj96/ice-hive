"""Marine build (WP4 «Отряд»; headless Blender, pip bpy 5.2.2 / Python 3.13):

  venv/bin/python characters/build_marines.py OUTDIR [--bake] [--classes assault,pyro] [--previews DIR]

For each class:
 1. marines.build(cls, hi=False / True): the shipped LOW parts and the HIGH bake source, both in the shared
    skeleton's bind pose; Blender objects per region (body, head, pauldrons, hands, backpack, weapon), game → Blender
    axes (X = −x, Y = z, Z = y);
 2. one UV atlas for all LOW regions (smart project, islands averaged, the head / chest / pauldrons given more texels,
    packed with a margin);
 3. --bake (an authoring step: Cycles bakes are not bit-stable between hosts): each region's HIGH parts → its LOW
    object: tangent-space normal 1024², ambient occlusion (0.12 m), roughness / metal with worn chamfers (an
    emission bake of the high materials: Bevel-node edge mask × noise), and the paint mask of the decal floaters
    (1 = class hue, 0.5 = light marking); written as 8-bit PNGs to characters/bake_src/ with the fingerprint of the
    LOW geometry + UVs they were baked for (bake.json). A normal build reads those and refuses a stale bake;
 4. export: corner-split skinned vertices (game space; MikkTSpace tangents of the atlas; v flipped to Metal's
    top-left origin), material colour / glow / flags per vertex, one bone per rigid part (hoses blend two), the
    clip tracks of motion.all_clips, sockets → OUTDIR/marine_<cls>.ihv (IHV1 v2 skinned);
then all classes' maps as two texture arrays (layer = class index): OUTDIR/marine_normal.iht (1024², ASTC 6×6,
normal mode) and OUTDIR/marine_orm.iht (512², ASTC 6×6: AO, roughness, metal, paint) — and
OUTDIR/characters_build.json (triangles, sizes, foot drift per locomotion clip, IK reach error per clip).
Deterministic: fixed seeds / threads, sorted output, maps from the committed 8-bit bake.
"""
import hashlib
import json
import math
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import bpy  # noqa: E402  (before bmesh)
import bmesh  # noqa: E402

import ihv  # noqa: E402
import iht  # noqa: E402
import marines as MR  # noqa: E402
import motion  # noqa: E402
import shapes  # noqa: E402
import skeleton as SK  # noqa: E402

T0 = time.time()
NRM_SIZE = 1024
ORM_SIZE = 512
BAKE_SRC = os.path.join(HERE, 'bake_src')
THREADS = 3
# the floor gate: no clip may put a skinned vertex deeper than this under the deck (the sole's chamfer, a plate's rim
# pressed into the grating — the deck's own grid bevels hide that much)
FLOOR_GATE = -0.02
REGIONS = ['body', 'head', 'pauldron', 'hands', 'pack', 'weapon']
# texel share per region (relative scale of its islands before packing)
REGION_SCALE = {'body': 1.0, 'head': 1.45, 'pauldron': 1.25, 'hands': 0.8, 'pack': 0.9, 'weapon': 1.1}


def log(*a):
    print(f'[{time.time() - T0:6.1f}s]', *a, flush=True)


def g2b(a):
    a = np.asarray(a, dtype=np.float64)
    return np.stack([-a[..., 0], a[..., 2], a[..., 1]], -1)


def b2g(a):
    a = np.asarray(a, dtype=np.float64)
    return np.stack([-a[..., 0], a[..., 2], a[..., 1]], -1)


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


def region_of(bone):
    if bone in ('weapon', 'weapon_aux'):
        return 'weapon'
    if bone in ('backpack', 'antenna'):
        return 'pack'
    if bone == 'head':
        return 'head'
    if bone.startswith('pauldron'):
        return 'pauldron'
    if bone.startswith('hand'):
        return 'hands'
    return 'body'


# ---------------------------------------------------------------- parts → Blender objects
def make_object(name, items, smooth_angle=None):
    """items: [(V (game), F, bone idx, mat, sharp_deg, blend (other bone idx, per-vertex weight) | None, decal value)]."""
    bm = bmesh.new()
    lay_bone = bm.faces.layers.int.new('bone')
    lay_mat = bm.faces.layers.int.new('mat')
    lay_dec = bm.faces.layers.float.new('decal')
    vb = bm.verts.layers.int.new('bone2')
    vw = bm.verts.layers.float.new('w2')
    for V, F, bone, mat, sharp, blend, dec in items:
        Vb = g2b(V)
        vs = [bm.verts.new(tuple(p)) for p in Vb]
        if blend is not None:
            ob, w = blend
            for v, wi in zip(vs, w):
                v[vb] = ob
                v[vw] = float(wi)
        else:
            for v in vs:
                v[vb] = bone
                v[vw] = 0.0
        new_faces = []
        for f in F:
            if len(set(f)) < 3:
                continue
            try:
                fa = bm.faces.new([vs[i] for i in f])
            except ValueError:
                continue
            fa[lay_bone] = bone
            fa[lay_mat] = mat
            fa[lay_dec] = dec
            fa.smooth = True
            new_faces.append(fa)
        if new_faces:
            bmesh.ops.recalc_face_normals(bm, faces=new_faces)
            # hard edges: sharper than the part's angle
            edges = set()
            for fa in new_faces:
                for e in fa.edges:
                    edges.add(e)
            for e in edges:
                if len(e.link_faces) == 2:
                    a = e.link_faces[0].normal.angle(e.link_faces[1].normal, 0.0)
                    e.smooth = a < math.radians(sharp)
                else:
                    e.smooth = False
    ngons = [f for f in bm.faces if len(f.verts) > 4]
    if ngons:
        bmesh.ops.triangulate(bm, faces=ngons, quad_method='BEAUTY', ngon_method='BEAUTY')
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def objects_for(b, tag, with_details):
    groups = {r: [] for r in REGIONS}
    for p in b.parts:
        bl = None
        if p.blend is not None:
            bl = (SK.IDX[p.blend[0]], p.blend[1])
        groups[region_of(p.bone)].append((p.verts, p.faces, SK.IDX[p.bone], p.mat, p.sharp_deg, bl, 0.0))
    if with_details:
        for (V, F), bone, mat in b.floaters:
            groups[region_of(bone)].append((V, F, SK.IDX[bone], mat, 50.0, None, 0.0))
    objs = {}
    for r in REGIONS:
        if groups[r]:
            objs[r] = make_object(f'{tag}_{r}', groups[r])
    decals = {}
    if with_details:
        dg = {r: [] for r in REGIONS}
        for (V, F), bone, val in b.decals:
            dg[region_of(bone)].append((V, F, SK.IDX[bone], shapes.PAINT, 80.0, None, float(val)))
        for r in REGIONS:
            if dg[r]:
                decals[r] = make_object(f'{tag}_{r}_decal', dg[r])
    return objs, decals


def add_weighted_normals(ob):
    m = ob.modifiers.new('wn', 'WEIGHTED_NORMAL')
    m.keep_sharp = True
    m.mode = 'FACE_AREA'
    m.weight = 50


# ---------------------------------------------------------------- UV atlas
def unwrap(objs):
    for o in bpy.data.objects:
        o.select_set(False)
    for r in REGIONS:
        if r in objs:
            o = objs[r]
            o.data.uv_layers.new(name='uv')
            o.select_set(True)
    bpy.context.view_layer.objects.active = objs['body']
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(58), island_margin=0.0, area_weight=0.0, correct_aspect=True,
                             scale_to_bounds=False)
    bpy.ops.uv.select_all(action='SELECT')
    bpy.ops.uv.average_islands_scale()
    bpy.ops.object.mode_set(mode='OBJECT')
    for r, o in objs.items():
        k = REGION_SCALE[r]
        uv = o.data.uv_layers['uv'].data
        a = np.empty(len(uv) * 2, np.float32)
        uv.foreach_get('uv', a)
        uv.foreach_set('uv', (a * k).astype(np.float32))
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.select_all(action='SELECT')
    bpy.ops.uv.pack_islands(udim_source='CLOSEST_UDIM', rotate=True, margin=0.003)
    bpy.ops.object.mode_set(mode='OBJECT')


# ---------------------------------------------------------------- bake
def bake_material(img):
    m = bpy.data.materials.new('bake_target')
    m.use_nodes = True
    tn = m.node_tree.nodes.new('ShaderNodeTexImage')
    tn.image = img
    m.node_tree.nodes.active = tn
    return m


def high_material(cls, kind):
    """Emission material of the HIGH parts for the property bake: R roughness, G metal (worn chamfers on painted
    armour show steel), B 0; kind 'decal': R = the decal's paint value (face attribute 'decal')."""
    mats = MR.materials(cls)
    out = []
    for slot in range(len(mats)):
        alb, rough, metal, glow, flags = mats[slot]
        m = bpy.data.materials.new(f'hp_{kind}_{slot}')
        m.use_nodes = True
        N, L = m.node_tree.nodes, m.node_tree.links
        for n in list(N):
            N.remove(n)
        o = N.new('ShaderNodeOutputMaterial')
        em = N.new('ShaderNodeEmission')
        L.new(em.outputs[0], o.inputs[0])
        if kind == 'decal':
            at = N.new('ShaderNodeAttribute')
            at.attribute_name = 'decal'
            at.attribute_type = 'GEOMETRY'
            comb = N.new('ShaderNodeCombineXYZ')
            L.new(at.outputs['Fac'], comb.inputs[0])
            L.new(comb.outputs[0], em.inputs['Color'])
        else:
            painted = (flags & 4) != 0
            bev = N.new('ShaderNodeBevel')
            bev.samples = 8
            bev.inputs['Radius'].default_value = 0.006
            geo = N.new('ShaderNodeNewGeometry')
            dot = N.new('ShaderNodeVectorMath')
            dot.operation = 'DOT_PRODUCT'
            L.new(bev.outputs[0], dot.inputs[0])
            L.new(geo.outputs['Normal'], dot.inputs[1])
            edge = N.new('ShaderNodeMapRange')       # 1 - dot: 0.002 → 0, 0.04 → 1
            edge.inputs['From Min'].default_value = 0.998
            edge.inputs['From Max'].default_value = 0.96
            L.new(dot.outputs['Value'], edge.inputs['Value'])
            noise = N.new('ShaderNodeTexNoise')
            noise.inputs['Scale'].default_value = 38.0
            noise.inputs['Detail'].default_value = 4.0
            tc = N.new('ShaderNodeTexCoord')
            L.new(tc.outputs['Object'], noise.inputs['Vector'])
            nmap = N.new('ShaderNodeMapRange')
            nmap.inputs['From Min'].default_value = 0.42
            nmap.inputs['From Max'].default_value = 0.6
            L.new(noise.outputs['Fac'], nmap.inputs['Value'])
            wear = N.new('ShaderNodeMath')
            wear.operation = 'MULTIPLY'
            wear.use_clamp = True
            L.new(edge.outputs['Result'], wear.inputs[0])
            L.new(nmap.outputs['Result'], wear.inputs[1])
            # roughness: the slot's, ±0.06 of the noise, worn edges smoother
            rn = N.new('ShaderNodeMapRange')
            rn.inputs['To Min'].default_value = rough - 0.06
            rn.inputs['To Max'].default_value = rough + 0.06
            L.new(noise.outputs['Fac'], rn.inputs['Value'])
            rmix = N.new('ShaderNodeMix')
            rmix.data_type = 'FLOAT'
            L.new(wear.outputs[0] if painted else edge.outputs['Result'], rmix.inputs['Factor'])
            L.new(rn.outputs['Result'], rmix.inputs['A'])
            rmix.inputs['B'].default_value = 0.26 if painted else max(0.12, rough - 0.12)
            mmix = N.new('ShaderNodeMix')
            mmix.data_type = 'FLOAT'
            L.new(wear.outputs[0], mmix.inputs['Factor'])
            mmix.inputs['A'].default_value = metal
            mmix.inputs['B'].default_value = 0.9 if painted else metal
            comb = N.new('ShaderNodeCombineXYZ')
            L.new(rmix.outputs['Result'], comb.inputs[0])
            L.new(mmix.outputs['Result'], comb.inputs[1])
            L.new(comb.outputs[0], em.inputs['Color'])
        out.append(m)
    return out


def assign_slots(ob, mats):
    ob.data.materials.clear()
    for m in mats:
        ob.data.materials.append(m)
    lay = ob.data.attributes['mat'].data
    a = np.empty(len(lay), np.int32)
    lay.foreach_get('value', a)
    ob.data.polygons.foreach_set('material_index', a)


def bake_class(cls, lo, hi, dec):
    sc = bpy.context.scene
    w = bpy.data.worlds.new('w')
    sc.world = w
    w.use_nodes = True
    w.light_settings.distance = 0.07
    imgs = {}
    for k, size in (('NORMAL', NRM_SIZE), ('AO', NRM_SIZE), ('EMIT', NRM_SIZE), ('DECAL', NRM_SIZE)):
        im = bpy.data.images.new(f'{cls}_{k}', size, size, alpha=False, float_buffer=True)
        im.colorspace_settings.name = 'Non-Color'
        imgs[k] = im
    hp_props = high_material(cls, 'props')
    hp_decal = high_material(cls, 'decal')
    for kind in ('NORMAL', 'AO', 'EMIT', 'DECAL'):
        tgt = bake_material(imgs[kind])
        for r, o in lo.items():
            o.data.materials.clear()
            o.data.materials.append(tgt)
        first = True
        for r in REGIONS:
            if r not in lo:
                continue
            if kind == 'DECAL':
                srcs = [dec[r]] if r in dec else []
                for o in srcs:
                    assign_slots(o, hp_decal)
            else:
                srcs = [hi[r]] if r in hi else []
                for o in srcs:
                    assign_slots(o, hp_props)
            if not srcs and kind != 'DECAL':
                continue
            for o in bpy.data.objects:
                o.select_set(False)
            for o in srcs:
                o.select_set(True)
            lo[r].select_set(True)
            bpy.context.view_layer.objects.active = lo[r]
            if not srcs:
                continue
            sc.cycles.samples = {'NORMAL': 4, 'AO': 64, 'EMIT': 4, 'DECAL': 1}[kind]
            kw = dict(normal_space='TANGENT') if kind == 'NORMAL' else {}
            t = time.time()
            bpy.ops.object.bake(type='EMIT' if kind == 'DECAL' else kind, use_selected_to_active=True,
                                cage_extrusion=0.008, max_ray_distance=0.016, margin=6, use_clear=first, **kw)
            first = False
            log(f'{cls}: {kind} {r} {time.time() - t:.1f}s')
    out = {}
    for k, im in imgs.items():
        a = np.empty(im.size[0] * im.size[1] * 4, np.float32)
        im.pixels.foreach_get(a)
        out[k] = a.reshape(im.size[1], im.size[0], 4)[::-1].copy()      # Metal row order
    return out


# ---------------------------------------------------------------- export
def fingerprint(lo):
    h = hashlib.md5()
    for r in REGIONS:
        if r not in lo:
            continue
        me = lo[r].data
        co = np.empty(len(me.vertices) * 3, np.float32)
        me.vertices.foreach_get('co', co)
        uv = np.empty(len(me.loops) * 2, np.float32)
        me.uv_layers['uv'].data.foreach_get('uv', uv)
        lv = np.empty(len(me.loops), np.int32)
        me.loops.foreach_get('vertex_index', lv)
        h.update(np.round(co, 5).tobytes())
        h.update(np.round(uv, 5).tobytes())
        h.update(lv.tobytes())
    return h.hexdigest()


def export_vertices(cls, lo):
    """Corner-split skinned vertices of all LOW regions: SKINNED_DTYPE array, triangle indices (u16 / u32)."""
    mats = MR.materials(cls)
    dg = bpy.context.evaluated_depsgraph_get()
    verts = {}
    V = []
    I = []
    for r in REGIONS:
        if r not in lo:
            continue
        ob = lo[r]
        ev = ob.evaluated_get(dg)
        me = ev.to_mesh()
        me.calc_tangents(uvmap='uv')
        bone = np.empty(len(me.polygons), np.int32)
        me.attributes['bone'].data.foreach_get('value', bone)
        mat = np.empty(len(me.polygons), np.int32)
        me.attributes['mat'].data.foreach_get('value', mat)
        b2 = np.empty(len(me.vertices), np.int32)
        me.attributes['bone2'].data.foreach_get('value', b2)
        w2 = np.empty(len(me.vertices), np.float32)
        me.attributes['w2'].data.foreach_get('value', w2)
        co = np.empty(len(me.vertices) * 3, np.float32)
        me.vertices.foreach_get('co', co)
        co = b2g(co.reshape(-1, 3))
        cn = np.empty(len(me.loops) * 3, np.float32)
        me.corner_normals.foreach_get('vector', cn)
        cn = b2g(cn.reshape(-1, 3))
        tg = np.empty(len(me.loops) * 3, np.float32)
        me.loops.foreach_get('tangent', tg)
        tg = b2g(tg.reshape(-1, 3))
        bs = np.empty(len(me.loops), np.float32)
        me.loops.foreach_get('bitangent_sign', bs)
        uv = np.empty(len(me.loops) * 2, np.float32)
        me.uv_layers['uv'].data.foreach_get('uv', uv)
        uv = uv.reshape(-1, 2)
        lv = np.empty(len(me.loops), np.int32)
        me.loops.foreach_get('vertex_index', lv)
        me.calc_loop_triangles()
        for tri in me.loop_triangles:
            pi = tri.polygon_index
            idx = []
            for li in tri.loops:
                vi = lv[li]
                m = int(mat[pi])
                alb, rough, metal, glow, flags = mats[m]
                bo = int(bone[pi])
                ob2, wt = int(b2[vi]), float(w2[vi])
                key = (r, vi, tuple(np.round(cn[li], 4)), tuple(np.round(uv[li], 5)), m, bo)
                k = verts.get(key)
                if k is None:
                    k = len(V)
                    verts[key] = k
                    V.append((co[vi], cn[li], tg[li], bs[li], (uv[li][0], 1.0 - uv[li][1]), alb, glow, flags, bo, ob2, wt))
                idx.append(k)
            I.append(idx)
        ev.to_mesh_clear()
    n = len(V)
    out = np.zeros(n, ihv.SKINNED_DTYPE)
    for i, (p, nr, tg, bs, uvv, alb, glow, flags, bo, ob2, wt) in enumerate(V):
        out[i]['rest'][:3] = p
        nn = nr / max(np.linalg.norm(nr), 1e-9)
        out[i]['nrm'][:3] = ihv.snorm8(nn)
        out[i]['nrm'][3] = flags
        t = tg - nn * np.dot(tg, nn)
        t /= max(np.linalg.norm(t), 1e-9)
        out[i]['tan'][:3] = ihv.snorm8(t)
        out[i]['tan'][3] = 127 if bs >= 0 else -127
        out[i]['uv'] = uvv
        out[i]['albedo'][:3] = alb
        out[i]['albedo'][3] = int(round(glow * 255))
        w = int(round(wt * 255))
        if w <= 0 or ob2 == bo:
            out[i]['bones'] = (bo, 0, 0, 0)
            out[i]['weights'] = (255, 0, 0, 0)
        else:
            a, bw = (bo, 255 - w), (ob2, w)
            first, second = (a, bw) if a[1] >= bw[1] else (bw, a)
            out[i]['bones'] = (first[0], second[0], 0, 0)
            out[i]['weights'] = (first[1], second[1], 0, 0)
    return out, np.asarray(I, dtype=np.int64).ravel()


def tracks_for(cls):
    clips, drift, ik = motion.all_clips(cls)
    rows, recs = [], []
    first = 0
    for c in clips:
        for p in c.poses:
            rows.append(p.track_row())
        recs.append(dict(name=c.name, first=first, frames=len(c.poses), loop=c.loop, stride=c.stride))
        first += len(c.poses)
    return np.stack(rows), recs, drift, ik


def write_bake(cls, maps, fp):
    from PIL import Image
    os.makedirs(BAKE_SRC, exist_ok=True)
    n = maps['NORMAL'][..., :3]
    Image.fromarray(np.clip(np.round(n * 255), 0, 255).astype(np.uint8), 'RGB').save(os.path.join(BAKE_SRC, f'{cls}_normal.png'))
    def down(a):
        return 0.25 * (a[0::2, 0::2] + a[1::2, 0::2] + a[0::2, 1::2] + a[1::2, 1::2])
    orm = np.zeros((NRM_SIZE, NRM_SIZE, 4), np.float32)
    orm[..., 0] = maps['AO'][..., 0]
    orm[..., 1] = maps['EMIT'][..., 0]
    orm[..., 2] = maps['EMIT'][..., 1]
    orm[..., 3] = maps['DECAL'][..., 0]
    orm = down(orm)
    Image.fromarray(np.clip(np.round(orm * 255), 0, 255).astype(np.uint8), 'RGBA').save(os.path.join(BAKE_SRC, f'{cls}_orm.png'))
    bj = os.path.join(BAKE_SRC, 'bake.json')
    J = json.load(open(bj)) if os.path.exists(bj) else {}
    J[cls] = fp
    json.dump(J, open(bj, 'w'), indent=1, sort_keys=True)


def read_bake(cls, fp):
    from PIL import Image
    bj = os.path.join(BAKE_SRC, 'bake.json')
    if not os.path.exists(bj):
        raise SystemExit(f'no committed bake (characters/bake_src): run build.sh --bake-characters')
    J = json.load(open(bj))
    if J.get(cls) != fp:
        raise SystemExit(f'{cls}: characters/bake_src was baked for other geometry / UVs: run build.sh --bake-characters')
    n = np.asarray(Image.open(os.path.join(BAKE_SRC, f'{cls}_normal.png')).convert('RGB'), dtype=np.float32) / 255.0
    n = n * 2.0 - 1.0
    n /= np.maximum(np.linalg.norm(n, axis=2, keepdims=True), 1e-6)
    orm = np.asarray(Image.open(os.path.join(BAKE_SRC, f'{cls}_orm.png')).convert('RGBA'), dtype=np.float32) / 255.0
    return n.astype(np.float32), orm


def flat_maps():
    n = np.zeros((NRM_SIZE, NRM_SIZE, 3), np.float32)
    n[..., 2] = 1.0
    orm = np.zeros((ORM_SIZE, ORM_SIZE, 4), np.float32)
    orm[..., 0] = 1.0
    orm[..., 1] = 0.5
    return n, orm


def main():
    args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else sys.argv[1:]
    out = args[0]
    bake = '--bake' in args
    noflat = '--flat' not in args
    classes = MR.CLASSES
    if '--classes' in args:
        classes = args[args.index('--classes') + 1].split(',')
    os.makedirs(out, exist_ok=True)
    report = dict(classes={}, gates=dict(foot_drift_m={}, ik_err_m={}))
    normals, orms = [], []
    for cls in MR.CLASSES:
        if cls not in classes:
            # (a partial build for look-dev: flat maps for the classes left out)
            n, orm = flat_maps()
            normals.append(n)
            orms.append(orm)
            continue
        reset()
        lob = MR.build(cls, hi=False)
        lo, _ = objects_for(lob, 'lo', False)
        for o in lo.values():
            add_weighted_normals(o)
        unwrap(lo)
        fp = fingerprint(lo)
        tris = sum(len(p.vertices) - 2 for o in lo.values() for p in o.data.polygons)
        log(f'{cls}: low {tris} triangles, fingerprint {fp[:8]}')
        if bake:
            hib = MR.build(cls, hi=True)
            hi, dec = objects_for(hib, 'hi', True)
            htris = sum(len(p.vertices) - 2 for o in hi.values() for p in o.data.polygons)
            log(f'{cls}: high {htris} triangles, {len(hib.floaters)} floaters, {len(hib.decals)} decals')
            maps = bake_class(cls, lo, hi, dec)
            write_bake(cls, maps, fp)
        if noflat:
            n, orm = read_bake(cls, fp)
        else:
            n, orm = flat_maps()
        normals.append(n)
        orms.append(orm)
        V, I = export_vertices(cls, lo)
        tracks, recs, drift, ik = tracks_for(cls)
        P = None
        D = dict(bones=[(nm, par) for nm, par, _ in SK.BONES])
        bind = SK.bind_local(cls)
        rest = [((0.0, 0.0, 0.0, 1.0), tuple(bind[k])) for k in range(SK.NB)]
        # bounds over every frame (the CPU reference of the app's skinning)
        D.update(dict(bone_rest=rest, tracks=tracks.astype(np.float32)))
        lod = dict(vertices=V)
        lo_min, lo_max = np.full(3, np.inf), np.full(3, -np.inf)
        # floor clearance: the lowest skinned vertex of each clip (a prone / kneeling armour plate must not sink into
        # the deck: gate ≥ −1.5 cm, the sole's chamfer and the deck's own bevel hide that much)
        floor = {}
        for r in recs:
            ymin = np.inf
            for row in range(r['first'], r['first'] + r['frames']):
                Pp, _ = ihv.skin_row(D, lod, row)
                lo_min = np.minimum(lo_min, Pp.min(0))
                lo_max = np.maximum(lo_max, Pp.max(0))
                ymin = min(ymin, float(Pp[:, 1].min()))
            floor[r['name']] = ymin
        socks = [(nm, [], SK.IDX[bone], 0, tuple(float(x) for x in off)) for nm, bone, off in MR.sockets(cls)]
        path = os.path.join(out, f'marine_{cls}.ihv')
        size = ihv.write(path, motion.FPS, recs, [dict(vertices=V, indices=I, draw_vertex_count=len(V), switch_px=0.0,
                                                    bounds=(lo_min, lo_max))],
                         [(nm, par) for nm, par, _ in SK.BONES], socks, tracks=tracks, bone_rest=rest, version=2)
        log(f'{cls}: {path} {size} bytes, {len(V)} vertices, {len(I) // 3} triangles, {len(recs)} clips, {len(tracks)} frames')
        report['classes'][cls] = dict(triangles=len(I) // 3, vertices=len(V), bytes=size, frames=len(tracks),
                                      clips=[r['name'] for r in recs], bounds=[lo_min.round(3).tolist(), lo_max.round(3).tolist()])
        for k, v in drift.items():
            report['gates']['foot_drift_m'][f'{cls}/{k}'] = round(float(v), 5)
        for k, v in ik.items():
            report['gates']['ik_err_m'][f'{cls}/{k}'] = round(float(v), 6)
        report['gates'].setdefault('floor_min_y_m', {})
        for k, v in floor.items():
            report['gates']['floor_min_y_m'][f'{cls}/{k}'] = round(v, 4)
        worst = min(floor.items(), key=lambda kv: kv[1])
        log(f'{cls}: lowest vertex {worst[1] * 100:.1f} cm in {worst[0]}; IK worst {max(ik.values()) * 1000:.1f} mm; '
            f'drift worst {max(drift.values()) * 100:.2f} cm')
        if worst[1] < FLOOR_GATE:
            raise SystemExit(f'{cls}: {worst[0]} puts a vertex {-worst[1] * 100:.1f} cm under the deck (gate {-FLOOR_GATE * 100:.1f} cm)')
    if len(normals) == len(MR.CLASSES):
        nl = iht.encode_layers([np.dstack([n, np.ones(n.shape[:2])]) for n in normals], 3, 'normal')
        iht.write(os.path.join(out, 'marine_normal.iht'), 3, NRM_SIZE, NRM_SIZE, nl, flags=iht.FL_NORMAL | iht.FL_ARRAY)
        ol = iht.encode_layers(orms, 3, 'data')
        iht.write(os.path.join(out, 'marine_orm.iht'), 3, ORM_SIZE, ORM_SIZE, ol, flags=iht.FL_ARRAY)
        log('textures written')
    json.dump(report, open(os.path.join(out, 'characters_build.json'), 'w'), indent=1, sort_keys=True)
    log('done')


if __name__ == '__main__':
    main()
