"""Environment probe of «Кельвин-9» (WP2 «Свет и воздух»): a 64² RGBA16F cube with 5 GGX-prefiltered mips, baked
headless with Cycles from a small procedural, emission-only (pre-lit) station surround, written as IHE1 for EnvProbe.swift.

  venv/bin/python env/bake_probe.py ../../App/Resources/Env/station_probe.ihe [--preview probe.png] [--samples 64]

(run from ios-native/tools/blender with the pipeline's venv: pip bpy 5.2.2, Python 3.13; ~15 s on 3 CPU threads.)

The scene is what a marine's chest sees on a deck of the station at night, in the blend's light discipline: a near-black
cold void with a faint moon patch through the roof, the dark grated deck under the probe with railings and teal walkway
edge strips (crisp's readability language), teal lamp heads on posts, a few sodium and red warning lamps on far masts,
piers sinking into the navy abyss with red running lights deep below. Radiance is in the game's linear units (the
deck's moonlight ≈ 0.01). Everything is built from code so an artist can open the saved scene (--blend out.blend), move
lamps or drop kit pieces in, and re-run with --from-blend.

Cube layout (Metal / D3D / GL): faces +X −X +Y −Y +Z −Z in GAME axes (y up); face texel (s, t), t from the top row:
  +X (1, −v, −u)  −X (−1, −v, u)  +Y (u, 1, v)  −Y (u, −1, −v)  +Z (u, −v, 1)  −Z (−u, −v, −1),  u = 2s − 1, v = 2t − 1.
Blender is z-up: game (x, y, z) = Blender (x, z, −y).
Mips: 0 = the render box-filtered to 64², m ≥ 1 = GGX lobe (N = V = R) of roughness m / 4 over a 32² source cube.
File (little-endian): "IHE1", u32 size, u32 mips, u32 format (1 = RGBA16F), u32 faces (6), 12 reserved bytes, then mip-major,
face-minor texels. Deterministic: fixed seed, samples, thread count; float16 output (md5-stable across runs).
"""
import math
import os
import struct
import sys
import tempfile
import time

import numpy as np

T0 = time.time()
SIZE, MIPS, SRC = 64, 5, 32   # output face size, mip count, source cube size for the prefilter
RENDER = 128                  # rendered face size (box-filtered to SIZE)


def log(*a):
    print(f'[{time.time() - T0:6.1f}s]', *a, flush=True)


def arg(name, default=None):
    if name in sys.argv:
        i = sys.argv.index(name)
        return sys.argv[i + 1] if i + 1 < len(sys.argv) else default
    return default


OUT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 and not sys.argv[1].startswith('--') else os.path.abspath('station_probe.ihe')
SAMPLES = int(arg('--samples', '32'))

# ---------------------------------------------------------------- cube conventions (game axes)
FACES = [
    lambda u, v: (np.ones_like(u), -v, -u),
    lambda u, v: (-np.ones_like(u), -v, u),
    lambda u, v: (u, np.ones_like(u), v),
    lambda u, v: (u, -np.ones_like(u), -v),
    lambda u, v: (u, -v, np.ones_like(u)),
    lambda u, v: (-u, -v, -np.ones_like(u)),
]


def face_dirs(n):
    """Unit directions (6, n, n, 3) of every texel centre, game axes."""
    c = (np.arange(n) + 0.5) / n * 2 - 1
    u, v = np.meshgrid(c, c)            # u along s (columns), v along t (rows, top first)
    out = np.empty((6, n, n, 3))
    for f in range(6):
        x, y, z = FACES[f](u, v)
        d = np.stack([x, y, z], -1)
        out[f] = d / np.linalg.norm(d, axis=-1, keepdims=True)
    return out


def texel_solid_angle(n):
    """Solid angle of every texel of an n² face (same for all faces)."""
    e = np.linspace(-1, 1, n + 1)
    def a(x, y): return np.arctan2(x * y, np.sqrt(x * x + y * y + 1))
    X0, Y0 = np.meshgrid(e[:-1], e[:-1]); X1, Y1 = np.meshgrid(e[1:], e[1:])
    return a(X0, Y0) - a(X0, Y1) - a(X1, Y0) + a(X1, Y1)


# ---------------------------------------------------------------- the scene (Cycles)
def build_scene():
    import bpy
    from mathutils import Vector
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.device = 'CPU'
    sc.cycles.samples = SAMPLES
    sc.cycles.seed = 7
    sc.cycles.use_denoising = False
    sc.cycles.use_adaptive_sampling = False   # adaptive sampling stops per pixel on noise estimates: not repeatable
    sc.cycles.max_bounces = 0                  # emission only (see surf_mat)
    sc.render.threads_mode = 'FIXED'
    sc.render.threads = 3
    sc.render.resolution_x = RENDER
    sc.render.resolution_y = RENDER
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = False
    sc.view_settings.view_transform = 'Standard'
    sc.render.image_settings.file_format = 'OPEN_EXR'
    sc.render.image_settings.color_depth = '32'
    sc.render.image_settings.exr_codec = 'NONE'
    col = sc.collection
    world = bpy.data.worlds.new('void')
    world.use_nodes = True
    world.node_tree.nodes['Background'].inputs['Color'].default_value = (0, 0, 0, 1)
    sc.world = world

    def G(x, y, z):   # game axes -> Blender
        return Vector((x, -z, y))

    def emit_mat(name, rgb, strength=1.0):
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        N = m.node_tree.nodes
        for n in list(N):
            if n.type != 'OUTPUT_MATERIAL':
                N.remove(n)
        e = N.new('ShaderNodeEmission')
        e.inputs['Color'].default_value = (*rgb, 1)
        e.inputs['Strength'].default_value = strength
        m.node_tree.links.new(e.outputs[0], N['Material Output'].inputs['Surface'])
        return m

    def surf_mat(name, rgb, rough, metal, lit=0.05):
        """A pre-lit surface: emission = albedo × the irradiance it gets out there (moonlight + the lamps around).
        Emission only, so the bake is repeatable: Cycles' light sampling on lit surfaces differs run to run (the asset
        gate wants an identical md5), and a 64² prefiltered probe cannot show the difference."""
        return emit_mat(name, tuple(c * lit for c in rgb), 1.0)

    def box(name, c, s, mat):
        bpy.ops.mesh.primitive_cube_add(size=1, location=G(*c))
        o = bpy.context.active_object
        o.name = name
        o.scale = (s[0], s[2], s[1])   # game (x, y, z) extents -> Blender (x, y=z, z=y)
        o.data.materials.append(mat)
        return o

    def ball(name, c, r, mat):
        bpy.ops.mesh.primitive_uv_sphere_add(radius=r, location=G(*c), segments=16, ring_count=8)
        o = bpy.context.active_object
        o.name = name
        o.data.materials.append(mat)
        return o

    # the void: an inward sky dome with a vertical gradient (near-black zenith, a cold band at the horizon, navy abyss)
    bpy.ops.mesh.primitive_uv_sphere_add(radius=400, location=(0, 0, 0), segments=64, ring_count=32)
    dome = bpy.context.active_object
    dome.name = 'void'
    m = bpy.data.materials.new('void')
    m.use_nodes = True
    N, L = m.node_tree.nodes, m.node_tree.links
    for n in list(N):
        if n.type != 'OUTPUT_MATERIAL':
            N.remove(n)
    tc = N.new('ShaderNodeTexCoord'); sep = N.new('ShaderNodeSeparateXYZ'); ramp = N.new('ShaderNodeValToRGB'); em = N.new('ShaderNodeEmission')
    mr = N.new('ShaderNodeMapRange')
    mr.inputs['From Min'].default_value = -400; mr.inputs['From Max'].default_value = 400
    L.new(tc.outputs['Object'], sep.inputs[0]); L.new(sep.outputs['Z'], mr.inputs['Value']); L.new(mr.outputs[0], ramp.inputs[0])
    cr = ramp.color_ramp
    cr.elements[0].position = 0.0; cr.elements[0].color = (0.0025, 0.0045, 0.0085, 1)     # straight down: the abyss
    cr.elements[1].position = 1.0; cr.elements[1].color = (0.0018, 0.0026, 0.0048, 1)     # zenith
    e = cr.elements.new(0.42); e.color = (0.006, 0.011, 0.018, 1)                       # haze under the horizon
    e = cr.elements.new(0.5); e.color = (0.010, 0.018, 0.026, 1)                        # the cold horizon band
    e = cr.elements.new(0.62); e.color = (0.004, 0.007, 0.012, 1)
    L.new(ramp.outputs['Color'], em.inputs['Color']); em.inputs['Strength'].default_value = 1.0
    L.new(em.outputs[0], N['Material Output'].inputs['Surface'])
    dome.data.materials.append(m)
    # the moon through the roof (the frame's moonDir): a faint cold patch
    md = np.array([-25.0, 60.0, 35.0]); md /= np.linalg.norm(md)
    ball('moon', tuple(md * 300), 26, emit_mat('moon', (0.30, 0.38, 0.52), 0.55))
    # the deck under the probe (probe = a marine's chest, 1.6 m up), its railings and teal edge strips
    steel = surf_mat('deck', (0.07, 0.08, 0.09), 0.62, 0.45, lit=0.09)
    rail = surf_mat('rail', (0.10, 0.11, 0.12), 0.45, 0.7, lit=0.07)
    box('deck', (0, -1.65, 0), (14, 0.1, 9), steel)
    for z in (-4.5, 4.5):
        box('rail', (0, -0.6, z), (14, 0.06, 0.06), rail)
        box('rail_low', (0, -1.1, z), (14, 0.04, 0.04), rail)
        box('strip', (0, -1.58, z * 0.985), (14, 0.025, 0.05), emit_mat('teal', (0.08, 0.95, 0.78), 2.2))
        for x in np.arange(-6.5, 7, 1.6):
            box('post', (float(x), -1.1, z), (0.06, 1.0, 0.06), rail)
    # lamp posts with teal heads along the walkway, sodium / red warning lamps on far masts
    for i, (x, z) in enumerate([(-5.5, -4.2), (5.5, -4.2), (-5.5, 4.2), (5.5, 4.2)]):
        box('lamp_post', (x, -0.1, z), (0.1, 3.0, 0.1), rail)
        box('lamp_head', (x, 1.45, z * 0.94), (0.5, 0.08, 0.25), emit_mat(f'lamp{i}', (0.15, 1.0, 0.85), 6.0))
    for i, (x, y, z, warm) in enumerate([(22, 6, -18, True), (-26, 4, 14, True), (30, 9, 20, False), (-18, 11, -30, False), (8, 3, 34, True)]):
        box('mast', (x, y - 9, z), (0.4, 18, 0.4), rail)
        ball(f'mast_lamp{i}', (x, y, z), 0.45, emit_mat(f'mast{i}', (1.0, 0.45, 0.12) if warm else (1.0, 0.08, 0.04), 18.0 if warm else 14.0))
    # piers sinking into the abyss, with red running lights deep below
    pier = surf_mat('pier', (0.05, 0.055, 0.06), 0.7, 0.3)
    rng = np.random.default_rng(11)
    for i in range(14):
        a = i / 14 * 2 * math.pi + 0.2
        r = 9 + (i % 4) * 5
        x, z = math.cos(a) * r, math.sin(a) * r
        box('pier', (x, -22, z), (1.0, 40, 1.0), pier)
        ball(f'run{i}', (x + 0.6, -8 - rng.uniform(0, 26), z), 0.25, emit_mat(f'run{i}', (1.0, 0.06, 0.03) if i % 3 else (1.0, 0.42, 0.1), 22.0))
    # far station blocks on the horizon with a few lit windows
    blk = surf_mat('block', (0.04, 0.045, 0.05), 0.8, 0.2)
    for i in range(9):
        a = i / 9 * 2 * math.pi + 0.5
        r = 55 + (i % 3) * 18
        x, z = math.cos(a) * r, math.sin(a) * r
        h = 10 + (i % 4) * 7
        box('block', (x, h / 2 - 12, z), (9, h, 9), blk)
        box('window', (x * 0.93, h * 0.6 - 12, z * 0.93), (2.5, 0.6, 0.3), emit_mat(f'win{i}', (0.2, 0.85, 0.9) if i % 2 else (1.0, 0.6, 0.25), 3.0))
    if arg('--blend'):
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(arg('--blend')))
    return sc


def render_faces(sc):
    """Render the six cube faces (Blender perspective cameras, 90°) and resample them into Metal's face layout."""
    import bpy
    from mathutils import Matrix, Vector
    cam_data = bpy.data.cameras.new('probe')
    cam_data.type = 'PERSP'
    cam_data.angle = math.pi / 2
    cam_data.sensor_fit = 'HORIZONTAL'
    cam_data.clip_start = 0.05
    cam_data.clip_end = 2000
    cam = bpy.data.objects.new('probe', cam_data)
    sc.collection.objects.link(cam)
    sc.camera = cam
    dirs = face_dirs(RENDER)
    faces = np.zeros((6, RENDER, RENDER, 3))
    tmp = tempfile.mkdtemp(prefix='probe')
    # each face's forward / up in game axes; the image is mapped generically (no hand-made flips)
    fwd = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)]
    up = [(0, 1, 0), (0, 1, 0), (0, 0, -1), (0, 0, 1), (0, 1, 0), (0, 1, 0)]
    def b(v): return Vector((v[0], -v[2], v[1]))
    for f in range(6):
        F, U = b(fwd[f]), b(up[f])
        R = F.cross(U)
        cam.matrix_world = Matrix(((R.x, U.x, -F.x, 0), (R.y, U.y, -F.y, 0), (R.z, U.z, -F.z, 0), (0, 0, 0, 1)))
        path = os.path.join(tmp, f'f{f}.exr')
        sc.render.filepath = path
        bpy.ops.render.render(write_still=True)
        img = bpy.data.images.load(path)
        px = np.array(img.pixels[:], dtype=np.float64).reshape(RENDER, RENDER, 4)[::-1, :, :3]   # top row first
        bpy.data.images.remove(img)
        # where does each Metal texel of face f look in this camera image?
        d = dirs[f]
        dg = np.stack([d[..., 0], -d[..., 2], d[..., 1]], -1)       # game -> Blender
        Fv, Rv, Uv = np.array(F), np.array(R), np.array(U)
        z = dg @ Fv
        x = (dg @ Rv) / z
        y = -(dg @ Uv) / z
        s = np.clip(((x + 1) / 2 * RENDER).astype(int), 0, RENDER - 1)
        t = np.clip(((y + 1) / 2 * RENDER).astype(int), 0, RENDER - 1)
        faces[f] = px[t, s]
        log(f'face {f} rendered, mean {faces[f].mean():.4f} max {faces[f].max():.2f}')
    return faces


def downsample(faces, n):
    k = faces.shape[1] // n
    return faces.reshape(6, n, k, n, k, 3).mean(axis=(2, 4))


def prefilter(src, n, rough):
    """GGX (N = V = R) convolution of the source cube into an n² cube."""
    m = src.shape[1]
    sd = face_dirs(m).reshape(-1, 3)
    sw = np.tile(texel_solid_angle(m).reshape(-1), 6)
    sc = src.reshape(-1, 3)
    out_d = face_dirs(n).reshape(-1, 3)
    a = max(rough * rough, 1e-3)
    a2 = a * a
    out = np.zeros((out_d.shape[0], 3))
    for i in range(0, out_d.shape[0], 512):
        R = out_d[i:i + 512]
        nl = np.clip(R @ sd.T, 0, 1)                        # N·L with N = R
        noh = np.sqrt((1 + nl) / 2)                         # H between N and L
        den = noh * noh * (a2 - 1) + 1
        D = a2 / (math.pi * den * den)
        w = D * nl * sw / (4 * np.maximum(noh, 1e-4))      # pdf of L for a GGX lobe ∝ D·NoH / (4·VoH), VoH = NoH
        w = np.where(nl > 0, w, 0)
        out[i:i + 512] = (w @ sc) / np.maximum(w.sum(axis=1, keepdims=True), 1e-9)
    return out.reshape(6, n, n, 3)


def main():
    sc = build_scene()
    faces = render_faces(sc)
    mips = [downsample(faces, SIZE)]
    src = downsample(faces, SRC)
    for m in range(1, MIPS):
        mips.append(prefilter(src, SIZE >> m, m / (MIPS - 1)))
        log(f'mip {m} ({SIZE >> m}²) roughness {m / (MIPS - 1):.2f}')
    blob = bytearray(b'IHE1' + struct.pack('<IIII', SIZE, MIPS, 1, 6) + bytes(12))
    for m in mips:
        rgba = np.concatenate([m, np.ones(m.shape[:-1] + (1,))], -1).astype(np.float16)
        blob += rgba.tobytes()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'wb') as f:
        f.write(blob)
    log(f'wrote {OUT} ({len(blob)} bytes)')
    if arg('--preview'):
        from PIL import Image
        cross = np.zeros((3 * SIZE, 4 * SIZE, 3))
        at = {0: (1, 2), 1: (1, 0), 2: (0, 1), 3: (2, 1), 4: (1, 1), 5: (1, 3)}
        for f, (r, c) in at.items():
            cross[r * SIZE:(r + 1) * SIZE, c * SIZE:(c + 1) * SIZE] = mips[0][f]
        disp = np.clip((cross * 8) ** (1 / 2.2), 0, 1)
        Image.fromarray((disp * 255).astype(np.uint8)).resize((8 * SIZE, 6 * SIZE), Image.NEAREST).save(arg('--preview'))
        log('preview', arg('--preview'))


if __name__ == '__main__':
    main()
