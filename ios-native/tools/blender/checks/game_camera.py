"""Read-back renders of the SHIPPED creature files (WP3 «Рой»): a fresh Blender process parses App/Resources/Creatures/
<type>.ihv with ihv.read() and rebuilds a mesh per sampled row through ihv.rigid_row() (bone texture × rest position /
normal + glow table — exactly what Swarm.metal vs_creature computes), then renders with Cycles (CPU, fixed threads).

  venv/bin/python checks/game_camera.py sheet  OUT_DIR            model sheet: every type, LOD0 3/4 + side + top + game
                                                                   angle, LOD1 and LOD2 at the same 3/4 view
  venv/bin/python checks/game_camera.py strips OUT_DIR [type ...]  every clip × 8 frames (LOD0)
  venv/bin/python checks/game_camera.py game   OUT_DIR            the game camera (pitch 57°, yaw 45°, fov 40°, 29.7 m —
                                                                   MetalCamera) at an iPhone 17 Pro's 3× landscape
                                                                   pixels (1206 px tall): a mixed pack under a flashlight,
                                                                   LOD0 / LOD1 / LOD2, and the LOD1 → LOD2 pop: mean luma
                                                                   difference inside each bug's screen rect (gate ≤ 6)
Writes PNGs + <job>.json (sizes, pop numbers) into OUT_DIR; compose.py-style contact sheets as <job>_sheet.png.
"""
import json
import math
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..', '..'))      # ios-native/
sys.path.insert(0, os.path.dirname(HERE))
import bpy  # noqa: E402
from mathutils import Vector  # noqa: E402

import ihv  # noqa: E402

TYPES = ['runner', 'spitter', 'brute', 'boomer']
SCALE = dict(runner=0.8, spitter=1.02, brute=2.0, boomer=1.15)
THREADS = 3
T0 = time.time()


def log(*a):
    print(f'[{time.time() - T0:6.1f}s]', *a, flush=True)


def g2b(p):
    p = np.asarray(p, dtype=np.float64)
    return np.stack([-p[..., 0], p[..., 2], p[..., 1]], -1)


def srgb2lin(c):
    c = np.asarray(c, dtype=np.float64)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def reset(res, samples=24):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.device = 'CPU'
    sc.cycles.samples = samples
    sc.cycles.use_denoising = True
    sc.cycles.max_bounces = 4
    sc.cycles.seed = 1
    sc.render.threads_mode = 'FIXED'
    sc.render.threads = THREADS
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.render.resolution_percentage = 100
    sc.render.image_settings.file_format = 'PNG'
    sc.view_settings.view_transform = 'AgX'
    sc.view_settings.look = 'AgX - Medium High Contrast'
    w = bpy.data.worlds.new('w'); sc.world = w
    w.use_nodes = True
    w.node_tree.nodes['Background'].inputs[0].default_value = (0.012, 0.016, 0.024, 1)
    w.node_tree.nodes['Background'].inputs[1].default_value = 1.0
    return sc


RIM = dict(runner=(0.62, 0.14, 0.36), spitter=(0.42, 0.62, 0.06), brute=(0.78, 0.30, 0.07), boomer=(0.85, 0.46, 0.09))
SAC = dict(runner=(0.6, 0.05, 0.16), spitter=(0.42, 0.78, 0.05), brute=(0.7, 0.1, 0.2), boomer=(0.95, 0.4, 0.07))


def material(name, kind, emit=6.0, lambert=False):
    """Principled stand-in for fs_chitin: vertex albedo × AO, roughness, clear coat on the plates, pores / eyes / sacs
    emissive (the sac a dim inner glow), the type's Fresnel rim as a layer weight."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    N, L = nt.nodes, nt.links
    bsdf = N['Principled BSDF']
    def at(n):
        a = N.new('ShaderNodeAttribute'); a.attribute_name = n; return a
    a_col, a_ao, a_gl, a_r, a_cc, a_sac = at('albedo'), at('ao'), at('glow'), at('rough'), at('coat'), at('sac')
    mul = N.new('ShaderNodeMix'); mul.data_type = 'RGBA'; mul.blend_type = 'MULTIPLY'; mul.inputs['Factor'].default_value = 1.0
    L.new(a_col.outputs['Color'], mul.inputs[6]); L.new(a_ao.outputs['Fac'], mul.inputs[7])
    L.new(mul.outputs[2], bsdf.inputs['Base Color'])
    if lambert:
        bsdf.inputs['Roughness'].default_value = 1.0
        bsdf.inputs['Specular IOR Level'].default_value = 0.0
    else:
        L.new(a_r.outputs['Fac'], bsdf.inputs['Roughness'])
        L.new(a_cc.outputs['Fac'], bsdf.inputs['Coat Weight'])
        bsdf.inputs['Coat Roughness'].default_value = 0.12
    L.new(a_col.outputs['Color'], bsdf.inputs['Emission Color'])
    em = N.new('ShaderNodeMath'); em.operation = 'MULTIPLY'; em.inputs[1].default_value = emit
    L.new(a_gl.outputs['Fac'], em.inputs[0])
    L.new(em.outputs[0], bsdf.inputs['Emission Strength'])
    # rim: fresnel-weighted emission of the type's tint added with an Add Shader
    fr = N.new('ShaderNodeFresnel'); fr.inputs['IOR'].default_value = 1.08
    pw = N.new('ShaderNodeMath'); pw.operation = 'POWER'; pw.inputs[1].default_value = 1.6
    L.new(fr.outputs[0], pw.inputs[0])
    rim = N.new('ShaderNodeEmission'); rim.inputs['Color'].default_value = (*RIM[kind], 1)
    rs = N.new('ShaderNodeMath'); rs.operation = 'MULTIPLY'; rs.inputs[1].default_value = 0.9
    L.new(pw.outputs[0], rs.inputs[0]); L.new(rs.outputs[0], rim.inputs['Strength'])
    sac = N.new('ShaderNodeEmission'); sac.inputs['Color'].default_value = (*SAC[kind], 1)
    ss = N.new('ShaderNodeMath'); ss.operation = 'MULTIPLY'; ss.inputs[1].default_value = 0.45
    L.new(a_sac.outputs['Fac'], ss.inputs[0]); L.new(ss.outputs[0], sac.inputs['Strength'])
    add1 = N.new('ShaderNodeAddShader'); add2 = N.new('ShaderNodeAddShader')
    out = N['Material Output']
    L.new(bsdf.outputs[0], add1.inputs[0]); L.new(rim.outputs[0], add1.inputs[1])
    L.new(add1.outputs[0], add2.inputs[0]); L.new(sac.outputs[0], add2.inputs[1])
    L.new(add2.outputs[0], out.inputs['Surface'])
    return m


def mesh_from(D, lod, row, name, mat, xform=None, dead=0.0):
    n = lod['draw_vertex_count']
    P, Nn, G = (a[:n] for a in ihv.rigid_row(D, lod, row))
    if xform is not None:
        P, Nn = xform(P, Nn)
    Pb, Nb = g2b(P), g2b(Nn)
    V = lod['vertices'][:n]
    me = bpy.data.meshes.new(name)
    me.from_pydata(Pb.tolist(), [], lod['indices'].tolist())
    me.update()
    me.normals_split_custom_set_from_vertices((Nb / np.maximum(np.linalg.norm(Nb, axis=1, keepdims=True), 1e-9)).tolist())
    fl = V['material'][:, 3]
    pore = (fl & 3) > 0
    alb = srgb2lin(V['albedo_ao'][:, :3] / 255.0)
    if dead:
        lum = alb @ np.array([0.2126, 0.7152, 0.0722])
        alb = np.where(pore[:, None], alb, (alb * (1 - 0.7 * dead) + lum[:, None] * np.array([0.8, 0.72, 0.7]) * 0.7 * dead) * (1 - 0.38 * dead))
    me.attributes.new('albedo', 'FLOAT_COLOR', 'POINT').data.foreach_set('color', np.c_[alb, np.ones(n)].ravel())
    me.attributes.new('ao', 'FLOAT', 'POINT').data.foreach_set('value', V['albedo_ao'][:, 3] / 255.0)
    me.attributes.new('glow', 'FLOAT', 'POINT').data.foreach_set('value', V['material'][:, 0] / 255.0 * G * (1 - 0.85 * dead) * ((fl & 16) == 0))
    me.attributes.new('rough', 'FLOAT', 'POINT').data.foreach_set('value', V['material'][:, 1] / 255.0)
    me.attributes.new('coat', 'FLOAT', 'POINT').data.foreach_set('value', ((fl & 4) > 0) * 0.7 + 0.2)
    me.attributes.new('sac', 'FLOAT', 'POINT').data.foreach_set('value', ((fl & 16) > 0) * (0.35 + V['material'][:, 0] / 255.0 * G) * (1 - 0.9 * dead))
    me.materials.append(mat)
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def camera(loc, target, lens=None, fov_v=None):
    cd = bpy.data.cameras.new('cam')
    if fov_v:
        cd.sensor_fit = 'VERTICAL'; cd.angle = math.radians(fov_v)
    else:
        cd.lens = lens or 50
    cd.clip_start, cd.clip_end = 0.05, 400
    ob = bpy.data.objects.new('cam', cd)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = Vector(loc)
    ob.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
    bpy.context.scene.camera = ob
    return ob


def light(kind, loc, target, energy, color=(1, 1, 1), size=None, spot=None, blend=0.3):
    ld = bpy.data.lights.new(kind, kind)
    ld.energy = energy
    ld.color = color
    if size is not None:
        if kind == 'AREA':
            ld.size = size
        elif kind == 'SUN':
            ld.angle = size
        else:
            ld.shadow_soft_size = size
    if spot:
        ld.spot_size = spot; ld.spot_blend = blend
    ob = bpy.data.objects.new(kind, ld)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = Vector(loc)
    ob.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
    return ob


def floor(size=8.0, grid=0.25, base=(0.022, 0.026, 0.034), line=(0.05, 0.06, 0.075)):
    bpy.ops.mesh.primitive_plane_add(size=size, location=(0, 0, 0))
    ob = bpy.context.active_object
    m = bpy.data.materials.new('floor'); m.use_nodes = True
    N, L = m.node_tree.nodes, m.node_tree.links
    bsdf = N['Principled BSDF']
    bsdf.inputs['Roughness'].default_value = 0.6
    bsdf.inputs['Metallic'].default_value = 0.4
    tc = N.new('ShaderNodeTexCoord')
    br = N.new('ShaderNodeTexBrick')
    br.inputs['Color1'].default_value = (*base, 1); br.inputs['Color2'].default_value = (*base, 1)
    br.inputs['Mortar'].default_value = (*line, 1)
    br.inputs['Scale'].default_value = 1.0 / grid
    br.inputs['Mortar Size'].default_value = 0.012
    br.offset = 0.0
    br.inputs['Brick Width'].default_value = 1.0; br.inputs['Row Height'].default_value = 1.0
    L.new(tc.outputs['Object'], br.inputs['Vector'])
    L.new(br.outputs['Color'], bsdf.inputs['Base Color'])
    ob.data.materials.append(m)
    return ob


def render(path):
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)


def clear_bugs():
    for ob in list(bpy.data.objects):
        if ob.name.startswith('bug'):
            me = ob.data
            bpy.data.objects.remove(ob)
            bpy.data.meshes.remove(me)


def orbit(target, az, el, dist):
    a, e = math.radians(az), math.radians(el)
    return Vector(target) + Vector((math.sin(a) * math.cos(e), math.cos(a) * math.cos(e), math.sin(e))) * dist


def studio(k=1.0):
    light('AREA', (-1.6 * k, 1.8 * k, 2.4 * k), (0, 0, 0.3 * k), 260 * k * k, (1.0, 0.93, 0.84), size=1.2 * k)
    light('AREA', (1.8 * k, -2.0 * k, 1.2 * k), (0, 0, 0.3 * k), 200 * k * k, (0.55, 0.7, 1.0), size=0.8 * k)
    light('AREA', (2.0 * k, 1.5 * k, 0.6 * k), (0, 0, 0.2 * k), 25 * k * k, (0.6, 0.65, 0.8), size=2.0 * k)


def load(t):
    return ihv.read(os.path.join(ROOT, 'App', 'Resources', 'Creatures', f'{t}.ihv'))


def grid(items, out, cols, title='', pad=6):
    from PIL import Image, ImageDraw, ImageFont
    def font(sz):
        for p in ('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', '/usr/share/fonts/dejavu/DejaVuSans.ttf'):
            try:
                return ImageFont.truetype(p, sz)
            except OSError:
                pass
        return ImageFont.load_default()
    ims = [(Image.open(f).convert('RGB'), lab) for f, lab in items]
    w, h = ims[0][0].size
    rows = (len(ims) + cols - 1) // cols
    th = 34 if title else 0
    sheet = Image.new('RGB', (cols * w + (cols + 1) * pad, th + rows * h + (rows + 1) * pad), (14, 16, 20))
    d = ImageDraw.Draw(sheet)
    if title:
        d.text((pad + 4, 7), title, fill=(220, 225, 235), font=font(18))
    f = font(13)
    for i, (im, lab) in enumerate(ims):
        x = pad + (i % cols) * (w + pad)
        y = th + pad + (i // cols) * (h + pad)
        sheet.paste(im.resize((w, h)), (x, y))
        d.rectangle([x, y, x + d.textlength(lab, font=f) + 8, y + 18], fill=(0, 0, 0))
        d.text((x + 4, y + 2), lab, fill=(235, 235, 240), font=f)
    sheet.save(out)


# ------------------------------------------------------------------ jobs
def job_sheet(out, types):
    files = []
    for t in types:
        D = load(t)
        s = SCALE[t] / 0.8
        sc = reset((420, 320), 24)
        studio(s)
        floor(10.0 * s, grid=0.25 * s)
        mat = material('chitin', t, emit=6.0)
        idle = next(c for c in D['clips'] if c['name'] == 'idle')
        tgt = (0, -0.1 * s, 0.3 * s)
        views = [(0, '3/4', 35, 24, 2.7), (0, 'side', 90, 4, 2.8), (0, 'top', 0, 89.5, 3.0), (0, 'game angle', 45 + 180, 57, 3.0),
                 (1, 'LOD1 3/4', 35, 24, 2.7), (2, 'LOD2 3/4', 35, 24, 2.7)]
        for li, nm, az, el, dist in views:
            clear_bugs()
            L = D['lods'][li]
            sxf = (lambda P, N, s=s: (P * s, N))
            mesh_from(D, L, idle['first'], 'bug0', mat, xform=sxf)
            cam = camera(orbit(tgt, az, el, dist * s), tgt, lens=55)
            f = os.path.join(out, f'sheet_{t}_{len(files)}.png')
            render(f)
            bpy.data.objects.remove(cam)
            files.append((f, f'{t} {nm} ({L["triangle_count"]} tris)'))
        log('sheet', t)
    grid(files, os.path.join(out, 'sheet.png'), 6, 'Рой — read back from App/Resources/Creatures/*.ihv (rigid path), Cycles')
    return files


def job_strips(out, types):
    allf = []
    for t in types:
        D = load(t)
        s = SCALE[t] / 0.8
        files = []
        for c in D['clips']:
            sc = reset((260, 190), 16)
            studio(s)
            floor(12.0 * s, grid=0.25 * s)
            mat = material('chitin', t, emit=6.0)
            n = c['frames']
            fr = [round(k * n / 8) % n for k in range(8)] if c['loop'] else [round(k * (n - 1) / 7) for k in range(8)]
            loco = c['locomotion']
            span = c['stride'] * 0.88 if loco else 0.0
            tgt = (0, (-0.1 + span * 0.55) * s, 0.3 * s)
            dist = (3.2 + span * 1.25) * s
            dead = c['name'].startswith('death')
            for k, f in enumerate(fr):
                clear_bugs()
                dz = c['stride'] * f / n if loco else 0.0
                xf = (lambda P, N, dz=dz, s=s: ((P + np.array([0, 0, dz])) * s, N))
                mesh_from(D, D['lods'][0], c['first'] + f, 'bug0', mat, xform=xf, dead=(f / (n - 1)) if dead else 0.0)
                cam = camera(orbit(tgt, 62, 16, dist), tgt, lens=50)
                p = os.path.join(out, f"strip_{t}_{c['name']}_{k}.png")
                render(p)
                bpy.data.objects.remove(cam)
                files.append((p, f"{t} {c['name']} f{f}"))
            log('strip', t, c['name'])
        grid(files, os.path.join(out, f'strips_{t}.png'), 8, f'{t}: every clip × 8 frames (LOD0, read back from the ihv)')
        allf += files
    return allf


def job_game(out):
    """MetalCamera: pitch 57°, yaw 45°, fov 40° vertical, 10.8 m half height → camDist 29.67 m. A 3× landscape iPhone
    17 Pro drawable is 1206 px tall: render that density, crop a window around a mixed pack under one flashlight."""
    W, H = 2622, 1206
    win = (560, 420)
    pitch, yaw = math.radians(57), math.pi / 4
    dist = 10.8 / math.tan(math.radians(20))
    rng = np.random.default_rng(5)
    Ds = {t: load(t) for t in TYPES}
    pack = []
    for i in range(24):
        t = rng.choice(TYPES, p=[0.55, 0.18, 0.1, 0.17])
        for _ in range(200):
            x, z = rng.uniform(-3.4, 3.0), rng.uniform(-3.0, 2.6)
            r_ = 0.55 * SCALE[t] + 0.35
            if all((x - a) ** 2 + (z - b) ** 2 > (r_ + 0.55 * SCALE[u] + 0.1) ** 2 for a, b, u, *_ in pack):
                break
        hd = math.atan2(3.0 - x, 3.0 - z) + rng.normal(0, 0.4)
        clips = [c['name'] for c in Ds[t]['clips']]
        pick = rng.choice([c for c in clips if not c.startswith('death')] + [c for c in clips if c.startswith('death')][:1])
        pack.append((x, z, t, hd, pick, rng.random()))
    tg = np.array([0.0, 0.0, 0.0])
    cam_g = tg + np.array([math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch)]) * dist
    # screen projection of world points (pop rects)
    fwd = (tg - cam_g) / np.linalg.norm(tg - cam_g)
    right = np.cross(fwd, [0, 1, 0]); right /= np.linalg.norm(right)
    up = np.cross(right, fwd)
    f_px = H / 2 / math.tan(math.radians(20))

    def proj(p):
        d = p - cam_g
        z = d @ fwd
        return W / 2 + (d @ right) / z * f_px, H / 2 - (d @ up) / z * f_px
    res = {}
    for li in (0, 1, 2):
        sc = reset((W, H), 40)
        sc.render.use_border = True; sc.render.use_crop_to_border = True
        sc.render.border_min_x = 0.5 - win[0] / 2 / W; sc.render.border_max_x = 0.5 + win[0] / 2 / W
        sc.render.border_min_y = 0.5 - win[1] / 2 / H; sc.render.border_max_y = 0.5 + win[1] / 2 / H
        w = sc.world.node_tree.nodes['Background']
        w.inputs[0].default_value = (0.05, 0.07, 0.11, 1); w.inputs[1].default_value = 0.12
        floor(60.0, grid=1.0)
        camera(tuple(g2b(cam_g)), tuple(g2b(tg)), fov_v=40)
        light('SUN', tuple(g2b(np.array([-25, 60, 35]))), (0, 0, 0), 0.18, (0.56, 0.67, 0.87), size=0.05)
        mpos = np.array([3.6, 1.25, 3.6])
        light('SPOT', tuple(g2b(mpos)), tuple(g2b(np.array([-0.6, 0.0, -0.6]))), 1400, (1.0, 0.89, 0.73), size=0.05, spot=1.0, blend=0.5)
        mats = {t: material(f'chitin_{t}', t, emit=6.0) for t in TYPES}
        for i, (x, z, t, hd, pick, r) in enumerate(pack):
            D = Ds[t]
            s = SCALE[t]
            c_, sn = math.cos(hd), math.sin(hd)
            def xf(P, N, x=x, z=z, c_=c_, sn=sn, s=s):
                R = np.array([[c_, 0, sn], [0, 1, 0], [-sn, 0, c_]])
                return (P * s) @ R.T + np.array([x, 0, z]), N @ R.T
            cl = next(c for c in D['clips'] if c['name'] == pick)
            dead = pick.startswith('death')
            f = cl['frames'] - 1 if dead else int(r * 997) % cl['frames']
            mesh_from(D, D['lods'][min(li, len(D['lods']) - 1)], cl['first'] + f, f'bug{i}', mats[t], xform=xf, dead=1.0 if dead else 0.0)
        p = os.path.join(out, f'game_lod{li}.png')
        render(p)
        res[li] = p
        log('game', f'LOD{li}')
    # LOD1 → LOD2 pop: mean |Δ luma| inside each bug's screen rect (sRGB 0..255)
    from PIL import Image
    imgs = {li: np.asarray(Image.open(res[li]).convert('RGB')).astype(np.float64) for li in res}
    lum = {li: imgs[li] @ np.array([0.2126, 0.7152, 0.0722]) for li in imgs}
    ox, oy = W / 2 - win[0] / 2, H / 2 - win[1] / 2
    pops = []
    for x, z, t, hd, pick, r in pack:
        D = Ds[t]
        lo, hi = np.array(D['bounds'][0]), np.array(D['bounds'][1])
        s = SCALE[t]
        corners = np.array([[a, b, c] for a in (lo[0], hi[0]) for b in (0.0, hi[1]) for c in (lo[2], hi[2])]) * s
        c_, sn = math.cos(hd), math.sin(hd)
        R = np.array([[c_, 0, sn], [0, 1, 0], [-sn, 0, c_]])
        pts = [proj(p @ R.T + np.array([x, 0, z])) for p in corners]
        xs, ys = [p[0] - ox for p in pts], [p[1] - oy for p in pts]
        x0, x1 = int(max(0, min(xs))), int(min(win[0], max(xs)))
        y0, y1 = int(max(0, min(ys))), int(min(win[1], max(ys)))
        if x1 - x0 < 4 or y1 - y0 < 4:
            continue
        d = float(np.abs(lum[1][y0:y1, x0:x1] - lum[2][y0:y1, x0:x1]).mean())
        mean = float(lum[1][y0:y1, x0:x1].mean() - lum[2][y0:y1, x0:x1].mean())
        pops.append(dict(type=t, clip=pick, rect=[x0, y0, x1, y1], abs_diff=d, mean_diff=mean, px=int(max(x1 - x0, y1 - y0))))
    rep = dict(pop_mean_abs=float(np.mean([p['abs_diff'] for p in pops])), pop_max_mean_diff=float(max(abs(p['mean_diff']) for p in pops)),
               pop_worst_abs=float(max(p['abs_diff'] for p in pops)), bugs=pops)
    json.dump(rep, open(os.path.join(out, 'game.json'), 'w'), indent=1)
    log(f"LOD1→LOD2 pop: mean luma difference per bug rect max {rep['pop_max_mean_diff']:.2f} (gate ≤ 6), "
        f"mean |Δ| {rep['pop_mean_abs']:.2f}, worst |Δ| {rep['pop_worst_abs']:.2f}")
    grid([(res[0], 'LOD0'), (res[1], 'LOD1'), (res[2], 'LOD2')], os.path.join(out, 'game_sheet.png'), 3,
         'game camera (pitch 57°, yaw 45°, fov 40°) at 3× iPhone landscape pixels — LOD0 / LOD1 / LOD2')
    return rep


if __name__ == '__main__':
    what, out = sys.argv[1], os.path.abspath(sys.argv[2])
    os.makedirs(out, exist_ok=True)
    types = sys.argv[3:] or TYPES
    types = [t for t in types if os.path.exists(os.path.join(ROOT, 'App', 'Resources', 'Creatures', f'{t}.ihv'))]
    if what == 'sheet':
        job_sheet(out, types)
    elif what == 'strips':
        job_strips(out, types)
    elif what == 'game':
        job_game(out)
    log('done')
