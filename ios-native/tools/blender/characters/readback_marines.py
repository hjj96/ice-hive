"""Read-back renders of the SHIPPED marines (never the source scene): a fresh Blender process parses
App/Resources/Characters/marine_<cls>.ihv (ihv.read: skinned vertices, bones, clip tracks, sockets) and the two
texture arrays (iht.read + astcenc decode), poses the mesh with the CPU reference of the app's skinning
(ihv.skin_row) and renders it in Cycles under the blend's light: deep dark, one warm flashlight key, a cold rim, the
class hue glowing from visors and strips.

  venv/bin/python characters/readback_marines.py RESDIR OUTDIR [sheet] [strips] [game] [--samples 32]
    sheet   OUTDIR/marine_sheet.png  — every class front 3/4, back 3/4, side, and a close-up of the helmet + weapon
    strips  OUTDIR/marine_strips.png — 8-frame strips of run, strafe, fire, dash, flinch, down → downed, revive,
            death, the gunner's barrel spin
    game    OUTDIR/marine_game.png   — the squad at the game camera (pitch 57°, yaw 45°, fov 40) at iPhone 3× pixels,
            phone-size and 100 % crops
Material: base colour = vertex albedo (+ the paint mask's class hue / light markings, worn steel on painted
chamfers) × baked AO; roughness / metal from the ORM array; the tangent-space normal array; emission = albedo × glow.
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
from mathutils import Euler, Matrix, Vector  # noqa: E402

import ihv  # noqa: E402
import iht  # noqa: E402

T0 = time.time()
CLASSES = ['assault', 'pyro', 'cryo', 'gunner']
CLASSES_SHOWN = CLASSES
TITLES = {'assault': 'ШТУРМОВИК', 'pyro': 'ОГНЕМЁТЧИК', 'cryo': 'КРИОТЕХНИК', 'gunner': 'ПУЛЕМЁТЧИК'}
HUE = {'assault': 0xff2a22, 'pyro': 0xffa214, 'cryo': 0x30b4ff, 'gunner': 0x3cff58}
TRIM = {'assault': 0xb8322a, 'pyro': 0xd8901c, 'cryo': 0x3592c8, 'gunner': 0x47a538}


def log(*a):
    print(f'[{time.time() - T0:6.1f}s]', *a, flush=True)


def lin(h):
    c = np.array([(h >> 16) & 255, (h >> 8) & 255, h & 255], dtype=np.float64) / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def g2b(a):
    a = np.asarray(a, dtype=np.float64)
    return np.stack([-a[..., 0], a[..., 2], a[..., 1]], -1)


def reset(samples):
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
    sc.render.film_transparent = False
    w = bpy.data.worlds.new('w')
    sc.world = w
    w.use_nodes = True
    bg = w.node_tree.nodes['Background']
    bg.inputs[0].default_value = (0.008, 0.011, 0.018, 1)
    bg.inputs[1].default_value = 1.0
    return sc


def image(name, rgba, colorspace='Non-Color'):
    h, w = rgba.shape[:2]
    im = bpy.data.images.new(name, w, h, alpha=True, float_buffer=False)
    im.colorspace_settings.name = colorspace
    im.pixels.foreach_set((rgba[::-1].astype(np.float32) / 255.0).ravel())
    im.pack()
    return im


class Assets:
    """The shipped data as numpy arrays (Blender images are made per scene: every render starts from a factory
    scene)."""

    def __init__(self, res, classes):
        self.classes = [c for c in classes if os.path.exists(os.path.join(res, f'marine_{c}.ihv'))]
        self.D = {c: ihv.read(os.path.join(res, f'marine_{c}.ihv')) for c in self.classes}
        self.nrm_px, self.orm_px = {}, {}
        pn, po = os.path.join(res, 'marine_normal.iht'), os.path.join(res, 'marine_orm.iht')
        N = iht.read(pn) if os.path.exists(pn) else None
        O = iht.read(po) if os.path.exists(po) else None
        for c in self.classes:
            k = CLASSES.index(c)
            if N is not None:
                n = iht.decode_level(N, k, 0)
                x = n[..., 0].astype(np.float64) / 255.0 * 2 - 1
                y = n[..., 3].astype(np.float64) / 255.0 * 2 - 1
                z = np.sqrt(np.clip(1 - x * x - y * y, 0, 1))
                img = np.dstack([(x * 0.5 + 0.5) * 255, (y * 0.5 + 0.5) * 255, (z * 0.5 + 0.5) * 255, np.full(x.shape, 255)])
                self.nrm_px[c] = np.clip(img, 0, 255).astype(np.uint8)
            else:
                f = np.zeros((4, 4, 4), np.uint8)
                f[..., :] = (128, 128, 255, 255)
                self.nrm_px[c] = f
            if O is not None:
                self.orm_px[c] = iht.decode_level(O, k, 0)
            else:
                f = np.zeros((4, 4, 4), np.uint8)
                f[..., :] = (255, 128, 0, 0)
                self.orm_px[c] = f

    def nrm(self, c):
        return bpy.data.images.get(f'n_{c}') or image(f'n_{c}', self.nrm_px[c])

    def orm(self, c):
        return bpy.data.images.get(f'o_{c}') or image(f'o_{c}', self.orm_px[c])

    def clip(self, cls, name):
        for c in self.D[cls]['clips']:
            if c['name'] == name:
                return c
        raise KeyError(name)


def material(A, cls):
    m = bpy.data.materials.new(f'marine_{cls}')
    m.use_nodes = True
    N, L = m.node_tree.nodes, m.node_tree.links
    b = N['Principled BSDF']
    uv = N.new('ShaderNodeUVMap')
    uv.uv_map = 'uv'
    tn = N.new('ShaderNodeTexImage')
    tn.image = A.nrm(cls)
    to = N.new('ShaderNodeTexImage')
    to.image = A.orm(cls)
    L.new(uv.outputs[0], tn.inputs[0])
    L.new(uv.outputs[0], to.inputs[0])
    nm = N.new('ShaderNodeNormalMap')
    nm.uv_map = 'uv'
    L.new(tn.outputs['Color'], nm.inputs['Color'])
    L.new(nm.outputs[0], b.inputs['Normal'])
    sep = N.new('ShaderNodeSeparateColor')
    L.new(to.outputs['Color'], sep.inputs[0])
    L.new(sep.outputs[1], b.inputs['Roughness'])
    L.new(sep.outputs[2], b.inputs['Metallic'])
    col = N.new('ShaderNodeAttribute')
    col.attribute_name = 'albedo'
    glow = N.new('ShaderNodeAttribute')
    glow.attribute_name = 'glow'
    paintf = N.new('ShaderNodeAttribute')
    paintf.attribute_name = 'painted'
    # paint mask (ORM alpha): 0.5 light marking, 1 class hue
    pa = to.outputs['Alpha']
    mk = N.new('ShaderNodeMapRange')
    mk.inputs['From Min'].default_value = 0.3
    mk.inputs['From Max'].default_value = 0.45
    L.new(pa, mk.inputs['Value'])
    mk2 = N.new('ShaderNodeMapRange')
    mk2.inputs['From Min'].default_value = 0.62
    mk2.inputs['From Max'].default_value = 0.8
    L.new(pa, mk2.inputs['Value'])
    mix1 = N.new('ShaderNodeMix')
    mix1.data_type = 'RGBA'
    L.new(mk.outputs[0], mix1.inputs['Factor'])
    L.new(col.outputs['Color'], mix1.inputs[6])
    mix1.inputs[7].default_value = (0.72, 0.72, 0.7, 1)
    mix2 = N.new('ShaderNodeMix')
    mix2.data_type = 'RGBA'
    L.new(mk2.outputs[0], mix2.inputs['Factor'])
    L.new(mix1.outputs[2], mix2.inputs[6])
    t = lin(TRIM[cls])
    mix2.inputs[7].default_value = (t[0], t[1], t[2], 1)
    # worn steel on painted chamfers: metal from the ORM where the vertex says "painted"
    wear = N.new('ShaderNodeMath')
    wear.operation = 'MULTIPLY'
    L.new(sep.outputs[2], wear.inputs[0])
    L.new(paintf.outputs['Fac'], wear.inputs[1])
    mix3 = N.new('ShaderNodeMix')
    mix3.data_type = 'RGBA'
    L.new(wear.outputs[0], mix3.inputs['Factor'])
    L.new(mix2.outputs[2], mix3.inputs[6])
    mix3.inputs[7].default_value = (0.55, 0.56, 0.58, 1)
    ao = N.new('ShaderNodeMix')
    ao.data_type = 'RGBA'
    ao.blend_type = 'MULTIPLY'
    ao.inputs['Factor'].default_value = 0.6      # (in the game the baked AO darkens the ambient only)
    L.new(mix3.outputs[2], ao.inputs[6])
    L.new(sep.outputs[0], ao.inputs[7])
    L.new(ao.outputs[2], b.inputs['Base Color'])
    L.new(col.outputs['Color'], b.inputs['Emission Color'])
    em = N.new('ShaderNodeMath')
    em.operation = 'MULTIPLY'
    L.new(glow.outputs['Fac'], em.inputs[0])
    em.inputs[1].default_value = 9.0
    L.new(em.outputs[0], b.inputs['Emission Strength'])
    return m


def posed_object(A, cls, clip, t, name, loc=(0, 0, 0), yaw=0.0, aux=0.0):
    """The class's mesh posed at clip time t (s) (track row interpolation like the app), as a Blender object."""
    D = A.D[cls]
    L0 = D['lods'][0]
    c = A.clip(cls, clip)
    n = c['frames']
    if c['loop']:
        p = (t * c['fps'] / n % 1.0) * n
        r0 = int(p) % n
        r1 = (r0 + 1) % n
    else:
        p = min(t * c['fps'], n - 1)
        r0 = int(p)
        r1 = min(r0 + 1, n - 1)
    f = p - int(p)
    T = D['tracks']
    row = T[c['first'] + r0] * (1 - f) + T[c['first'] + r1] * f
    if aux:
        k = [b[0] for b in D['bones']].index('weapon_aux')
        a = math.radians(aux)
        q = row[k, 0]
        row[k, 0] = (q[0] * math.cos(a / 2) + 0, q[1] * math.cos(a / 2), q[2] * math.cos(a / 2) + q[3] * math.sin(a / 2), q[3] * math.cos(a / 2) - q[2] * math.sin(a / 2))
    D2 = dict(D)
    D2['tracks'] = row[None]
    P, Nn = ihv.skin_row(D2, L0, 0)
    V = L0['vertices']
    I = L0['indices']
    me = bpy.data.meshes.new(name)
    me.from_pydata(g2b(P).tolist(), [], I.tolist())
    me.update()
    uv = me.uv_layers.new(name='uv')
    corner_v = np.empty(len(me.loops), np.int32)
    me.loops.foreach_get('vertex_index', corner_v)
    uvv = V['uv'].astype(np.float64)[corner_v]
    uvv[:, 1] = 1.0 - uvv[:, 1]
    uv.data.foreach_set('uv', uvv.astype(np.float32).ravel())
    me.normals_split_custom_set_from_vertices(g2b(Nn).tolist())
    for poly in me.polygons:
        poly.use_smooth = True
    ca = me.color_attributes.new('albedo', 'BYTE_COLOR', 'POINT')
    alb = np.c_[V['albedo'][:, :3].astype(np.float64) / 255.0, np.ones(len(V))]
    ca.data.foreach_set('color_srgb', alb.astype(np.float32).ravel())
    ga = me.attributes.new('glow', 'FLOAT', 'POINT')
    ga.data.foreach_set('value', (V['albedo'][:, 3].astype(np.float32) / 255.0))
    pf = me.attributes.new('painted', 'FLOAT', 'POINT')
    pf.data.foreach_set('value', ((V['nrm'][:, 3].astype(np.int32) & 4) > 0).astype(np.float32))
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    ob.data.materials.append(material(A, cls) if f'marine_{cls}' not in bpy.data.materials else bpy.data.materials[f'marine_{cls}'])
    ob.location = loc
    ob.rotation_euler = (0, 0, math.radians(yaw))
    return ob


def deck(size=30.0, z=0.0):
    bpy.ops.mesh.primitive_plane_add(size=size, location=(0, 0, z))
    ob = bpy.context.active_object
    m = bpy.data.materials.new('deck')
    m.use_nodes = True
    N, L = m.node_tree.nodes, m.node_tree.links
    b = N['Principled BSDF']
    tc = N.new('ShaderNodeTexCoord')
    br = N.new('ShaderNodeTexBrick')
    br.inputs['Scale'].default_value = 1.0
    br.inputs['Mortar Size'].default_value = 0.03
    br.inputs['Brick Width'].default_value = 1.0
    br.inputs['Row Height'].default_value = 1.0
    br.offset = 0.0
    br.inputs['Color1'].default_value = (0.05, 0.055, 0.065, 1)
    br.inputs['Color2'].default_value = (0.045, 0.05, 0.06, 1)
    br.inputs['Mortar'].default_value = (0.012, 0.013, 0.016, 1)
    L.new(tc.outputs['Object'], br.inputs['Vector'])
    L.new(br.outputs['Color'], b.inputs['Base Color'])
    b.inputs['Roughness'].default_value = 0.42
    b.inputs['Metallic'].default_value = 0.6
    ob.data.materials.append(m)
    return ob


def lights(key_from=(-2.5, 3.2, 3.2), key=420.0, rim=160.0, fill=0.05, aim=(0.0, 0.0, 1.0)):
    """Warm flashlight key (a spot), cold rim from behind, faint cold fill — the blend's light."""
    sc = bpy.context.scene
    ld = bpy.data.lights.new('key', 'SPOT')
    ld.energy = key
    ld.color = (1.0, 0.89, 0.73)
    ld.spot_size = math.radians(60)
    ld.spot_blend = 0.6
    ld.shadow_soft_size = 0.08
    k = bpy.data.objects.new('key', ld)
    sc.collection.objects.link(k)
    k.location = key_from
    k.rotation_euler = (Vector(aim) - Vector(key_from)).to_track_quat('-Z', 'Y').to_euler()
    lr = bpy.data.lights.new('rim', 'AREA')
    lr.energy = rim
    lr.color = (0.55, 0.75, 1.0)
    lr.size = 1.5
    r = bpy.data.objects.new('rim', lr)
    sc.collection.objects.link(r)
    r.location = (2.0, -2.5, 3.0)
    r.rotation_euler = (Vector((0, 0, 1.0)) - Vector((2.0, -2.5, 3.0))).to_track_quat('-Z', 'Y').to_euler()
    lf = bpy.data.lights.new('fill', 'SUN')
    lf.energy = fill
    lf.color = (0.6, 0.7, 1.0)
    f = bpy.data.objects.new('fill', lf)
    sc.collection.objects.link(f)
    f.rotation_euler = (math.radians(40), 0, math.radians(200))


def camera(loc, target, lens=50.0, ortho=None):
    sc = bpy.context.scene
    cd = bpy.data.cameras.new('cam')
    cd.lens = lens
    if ortho:
        cd.type = 'ORTHO'
        cd.ortho_scale = ortho
    cd.clip_end = 200
    c = bpy.data.objects.new('cam', cd)
    sc.collection.objects.link(c)
    c.location = loc
    c.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
    sc.camera = c
    return c


def render(path, w, h):
    sc = bpy.context.scene
    sc.render.resolution_x = w
    sc.render.resolution_y = h
    sc.render.resolution_percentage = 100
    sc.render.filepath = path
    t = time.time()
    bpy.ops.render.render(write_still=True)
    log(f'rendered {os.path.basename(path)} {w}×{h} in {time.time() - t:.1f}s')


def g(x, y, z):
    """game → Blender point."""
    return (-x, z, y)


def sheet(A, out, samples):
    tiles = []
    views = [('front', (1.6, 1.3, 3.0), 18.0), ('back', (-1.4, 1.5, -3.0), 18.0), ('side', (-3.2, 1.2, 0.4), 0.0)]
    for cls in CLASSES_SHOWN:
        for vname, eye, _ in views:
            reset(samples)
            deck()
            lights(key_from=g(*(np.array(eye) * 0.9 + np.array([0, 1.6, 0]))))
            posed_object(A, cls, 'idle', 0.0, cls)
            camera(g(*eye), g(0.0, 1.05, 0.15), lens=55)
            p = os.path.join(out, f'_sheet_{cls}_{vname}.png')
            render(p, 520, 700)
            tiles.append(p)
        # close-up: helmet + weapon
        reset(samples)
        deck()
        lights(key_from=g(-0.6, 2.4, 2.6), key=180.0)
        posed_object(A, cls, 'idle', 0.0, cls)
        camera(g(1.05, 1.62, 1.75), g(0.12, 1.38, 0.3), lens=50)
        p = os.path.join(out, f'_sheet_{cls}_close.png')
        render(p, 520, 700)
        tiles.append(p)
    compose_sheet(tiles, os.path.join(out, 'marine_sheet.png'))


def font(size):
    from PIL import ImageFont
    for p in [os.path.join(HERE, '..', '..', '..', 'App', 'Resources', 'Fonts', 'Oswald-SemiBold.ttf'),
              '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf']:
        p = os.path.normpath(p)
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def compose_sheet(tiles, path):
    from PIL import Image, ImageDraw
    cols, w, h = 4, 520, 700
    rows = len(CLASSES_SHOWN)
    S = Image.new('RGB', (cols * w, rows * (h + 50) + 60), (8, 10, 14))
    d = ImageDraw.Draw(S)
    d.text((16, 14), 'ЛЕДЯНОЙ УЛЕЙ · ОТРЯД — модели из отгруженных файлов (IHV1 skinned + IHT1), Cycles', fill=(230, 235, 240), font=font(28))
    for r, cls in enumerate(CLASSES_SHOWN):
        hu = HUE[cls]
        d.text((16, 60 + r * (h + 50) + 8), TITLES[cls] + '   ' + 'анфас · спина · профиль · крупно', fill=((hu >> 16) & 255, (hu >> 8) & 255, hu & 255), font=font(28))
        for c in range(cols):
            im = Image.open(tiles[r * cols + c]).convert('RGB')
            S.paste(im, (c * w, 60 + r * (h + 50) + 48))
    S.save(path)
    log(f'sheet → {path}')


STRIPS = [
    ('assault', 'run_f', 8, 'Штурмовик · бег вперёд (фаза по пройденному пути, стопы стоят)'),
    ('pyro', 'run_l', 8, 'Огнемётчик · бег боком (8 направлений, корпус держит прицел)'),
    ('assault', 'fire', 6, 'Штурмовик · отдача выстрела (корпус — плечи — оружие)'),
    ('gunner', 'fire', 6, 'Пулемётчик · огонь: дрожь ротора через корпус, стволы крутятся'),
    ('pyro', 'fire', 6, 'Огнемётчик · огонь: давление струи, раскачка сопла'),
    ('gunner', 'run_fr', 8, 'Пулемётчик · бег по диагонали, стволы крутятся'),
    ('cryo', 'dash_f', 8, 'Криотехник · рывок: присед — толчок — приземление'),
    ('assault', 'flinch_f', 6, 'Штурмовик · попадание спереди'),
    ('gunner', 'down', 8, 'Пулемётчик · ранен: колени — на колени — ничком'),
    ('pyro', 'downed', 8, 'Огнемётчик · ползёт на месте (тянется рукой, толкается коленом)'),
    ('cryo', 'revive', 8, 'Криотехник · подъём: на четвереньки — колено — в стойку'),
    ('assault', 'death', 8, 'Штурмовик · гибель: судорога, оружие выскальзывает, визор гаснет'),
]


def strips(A, out, samples):
    """Each strip: the clip's frames posed side by side in one scene (4 m apart), each rendered as its own tile with
    its own camera and flashlight key (3/4 from the weapon side), so every frame reads at ≈ 400 px tall."""
    from PIL import Image, ImageDraw
    TW, TH = 300, 440
    rows = []
    for cls, clip, n, title in STRIPS:
        if cls not in CLASSES_SHOWN:
            continue
        reset(samples)
        deck(80.0)
        c = A.clip(cls, clip)
        dur = c['duration'] if c['frames'] > 1 else 0.0
        add = clip in ('fire', 'flinch_f', 'flinch_b')
        gap = 4.0
        prone = clip in ('down', 'downed', 'revive', 'death')
        for k in range(n):
            t = dur * k / (n - 1 if not c['loop'] else n)
            if add:
                t = dur * k / (n - 1)
            aux = (k * 40.0) if cls == 'gunner' else 0.0
            posed_object(A, cls, clip, t, f'{cls}_{k}', loc=g((k - (n - 1) / 2) * gap, 0, 0), yaw=0.0, aux=aux)
        tiles = []
        for k in range(n):
            x = (k - (n - 1) / 2) * gap
            for o in [o for o in bpy.context.scene.objects if o.type in ('LIGHT', 'CAMERA')]:
                bpy.data.objects.remove(o)
            lights(key_from=g(x - 1.2, 3.4, 3.0), key=380.0, rim=150.0, aim=g(x, 0.9, 0.0))
            for o in bpy.context.scene.objects:
                if o.type == 'LIGHT' and o.name.startswith('rim'):
                    o.location = g(x - 2.0, 3.0, -2.5)
            if prone:
                camera(g(x + 2.2, 2.0, 2.9), g(x + 0.05, 0.4, -0.25), lens=40)
            else:
                # 3/4 from the weapon side, framing the marine head to boots (recoil and stride read)
                camera(g(x + 2.55, 1.5, 2.05), g(x + 0.1, 0.98, 0.15), lens=55)
            pth = os.path.join(out, f'_strip_{cls}_{clip}_{k}.png')
            render(pth, TW, TH)
            tiles.append(pth)
        strip = Image.new('RGB', (TW * n, TH), (8, 10, 14))
        for k, pth in enumerate(tiles):
            strip.paste(Image.open(pth).convert('RGB'), (k * TW, 0))
        sp = os.path.join(out, f'_strip_{cls}_{clip}.png')
        strip.save(sp)
        for pth in tiles:
            os.remove(pth)
        rows.append((sp, title, cls, TW * n))
    W = max(r[3] for r in rows) if rows else 1800
    S = Image.new('RGB', (W, len(rows) * (TH + 44) + 60), (8, 10, 14))
    d = ImageDraw.Draw(S)
    d.text((16, 14), 'ЛЕДЯНОЙ УЛЕЙ · ОТРЯД — анимационные полосы из отгруженных дорожек клипов (кадры слева направо)', fill=(230, 235, 240), font=font(28))
    for r, (p, title, cls, _) in enumerate(rows):
        hu = HUE[cls]
        d.text((16, 60 + r * (TH + 44) + 6), title, fill=((hu >> 16) & 255, (hu >> 8) & 255, hu & 255), font=font(26))
        S.paste(Image.open(p).convert('RGB'), (0, 60 + r * (TH + 44) + 40))
    S.save(os.path.join(out, 'marine_strips.png'))
    log('strips → marine_strips.png')


def game_view(A, out, samples):
    """The squad at the game camera: pitch 57°, yaw 45°, fov 40, the landscape phone's 10.8 m half height, 3× px."""
    reset(samples)
    deck(80.0)
    sc = bpy.context.scene
    lights(key_from=g(0.0, 2.0, -3.0), key=500.0, rim=120.0)
    pos = [(-1.6, 0.0, 0.4, 'run_f', 0.1), (0.0, 0.0, 0.0, 'idle', 0.0), (1.5, 0.0, -0.6, 'fire', 0.05), (3.0, 0.0, 0.5, 'run_l', 0.2)]
    for (x, _, z, clip, t), cls in zip(pos, CLASSES):
        if cls not in CLASSES_SHOWN:
            continue
        posed_object(A, cls, clip, t, cls, loc=g(x, 0, z), yaw=30.0)
    pitch, yaw = math.radians(57), math.radians(45)
    dist = 10.8 / math.tan(math.radians(20))
    f = np.array([0.7, 0.0, 0.0])
    eye = f + np.array([math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch)]) * dist
    cam = camera(g(*eye), g(*f))
    cam.data.sensor_fit = 'VERTICAL'
    cam.data.angle_y = math.radians(40)
    render(os.path.join(out, 'marine_game.png'), 2622, 1206)


def main():
    args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else sys.argv[1:]
    res, out = args[0], args[1]
    samples = int(args[args.index('--samples') + 1]) if '--samples' in args else 32
    os.makedirs(out, exist_ok=True)
    reset(samples)
    classes = args[args.index('--classes') + 1].split(',') if '--classes' in args else CLASSES
    A = Assets(res, classes)
    global CLASSES_SHOWN
    CLASSES_SHOWN = A.classes
    skip = set()
    for k in ('--samples', '--classes'):
        if k in args:
            skip.add(args[args.index(k) + 1])
    what = [a for a in args[2:] if not a.startswith('--') and a not in skip]
    if not what or 'sheet' in what:
        sheet(A, out, samples)
    if not what or 'strips' in what:
        strips(A, out, samples)
    if not what or 'game' in what:
        game_view(A, out, samples)


if __name__ == '__main__':
    main()
