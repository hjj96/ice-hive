"""Read-back renders of the SHIPPED Threader files (Stage 2 B2): a fresh Blender process parses App/Resources/Creatures/
threader_{head,seg,node}.ihv with ihv.read() and rebuilds every mesh through ihv.rigid_row() (bone texture × rest — what
Swarm.metal vs_creature computes), lays the body out as B5 will (each segment on the chord of the body path between its
front and back attach points, the head on the chord to its neck, a node in its segment's transform), and renders with
Cycles (CPU, fixed threads) — game_camera.py's stand-in for fs_chitin.

  venv/bin/python checks/threader_readback.py parts  OUT_DIR   head / segment / node close-ups, LOD0-2 (model sheet)
  venv/bin/python checks/threader_readback.py strips OUT_DIR   every clip of the three files × 8 frames
  venv/bin/python checks/threader_readback.py body   OUT_DIR   the whole body along a curve over the Manifold's trunks
                                                               and island at the game camera (pitch 57°, yaw 45°, fov 40°,
                                                               iPhone 3× landscape pixels), its LOD strip, 100 % crops
Writes PNGs and <job>_sheet.png contact sheets into OUT_DIR.
"""
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), 'creatures'))
import bpy  # noqa: E402

import game_camera as G  # noqa: E402
import ihv  # noqa: E402

# the Threader's look for the stand-in material (B5 sets the real ones in its type table): a pearl-mauve rim, pearl sacs
G.RIM['threader'] = (0.70, 0.64, 0.88)
G.SAC['threader'] = (0.82, 0.76, 1.0)
FILES = ('threader_head', 'threader_seg', 'threader_node')
T0 = G.T0


def log(*a):
    G.log(*a)


CREATURES = os.environ.get('THREADER_DIR') or os.path.join(G.ROOT, 'App', 'Resources', 'Creatures')


def have(name):
    return os.path.exists(os.path.join(CREATURES, f'{name}.ihv'))


def load(name):
    return ihv.read(os.path.join(CREATURES, f'{name}.ihv'))


def clip(D, name):
    return next(c for c in D['clips'] if c['name'] == name)


def row_of(D, name, f=0):
    c = clip(D, name)
    return c['first'] + min(f, c['frames'] - 1)


def place(P, N, M):
    """game-space points / normals through a 4×4 game-space transform"""
    return P @ M[:3, :3].T + M[:3, 3], N @ M[:3, :3].T


def xform_of(pos, heading, pitch=0.0, scale=1.0):
    """a game-space instance transform like Swarm.metal placeOffset: heading about +y (atan2(dx, dz)), pitch nose-up"""
    c, s = math.cos(heading), math.sin(heading)
    cp, sp = math.cos(pitch), math.sin(pitch)
    ax = np.array([c, 0.0, -s])
    ay = np.array([-s * sp, cp, -c * sp])
    az = np.array([s * cp, sp, c * cp])
    M = np.eye(4)
    M[:3, 0], M[:3, 1], M[:3, 2] = ax * scale, ay * scale, az * scale
    M[:3, 3] = pos
    return M


def mesh(D, lod, row, name, mat, M=None, dead=0.0):
    xf = None if M is None else (lambda P, N, M=M: place(P, N, M))
    return G.mesh_from(D, D['lods'][lod], row, name, mat, xform=xf, dead=dead)


def glints(D, row, name, gm, M, min_r=0.02):
    xf = None if M is None else (lambda P, N, M=M: place(P, N, M))
    return G.glints_from(D, row, name, gm, xf, 1.0, min_r)


def pipe_obj(name, a, b, r=0.45, color=(0.06, 0.05, 0.045), seg=24):
    """a trunk pipe (game space, its TOP on the line a → b) — the read-back's stand-in for B5's runtime extrusion"""
    a, b = np.asarray(a, float), np.asarray(b, float)
    d = b - a
    L = np.linalg.norm(d)
    bpy.ops.mesh.primitive_cylinder_add(vertices=seg, radius=r, depth=L)
    ob = bpy.context.active_object
    ob.name = name
    mid = (a + b) / 2 - np.array([0, r, 0])
    ob.location = tuple(G.g2b(mid))
    from mathutils import Vector
    ob.rotation_euler = Vector(tuple(G.g2b(d / L))).to_track_quat('Z', 'Y').to_euler()
    m = bpy.data.materials.new(name + 'm')
    m.use_nodes = True
    bs = m.node_tree.nodes['Principled BSDF']
    bs.inputs['Base Color'].default_value = (*color, 1)
    bs.inputs['Metallic'].default_value = 0.7
    bs.inputs['Roughness'].default_value = 0.45
    ob.data.materials.append(m)
    bpy.ops.object.shade_smooth()
    return ob


def deck_obj(name, x0, z0, x1, z1, y=0.0, color=(0.035, 0.04, 0.05)):
    bpy.ops.mesh.primitive_plane_add(size=1.0)
    ob = bpy.context.active_object
    ob.name = name
    ob.scale = (x1 - x0, z1 - z0, 1)
    ob.location = tuple(G.g2b(np.array([(x0 + x1) / 2, y, (z0 + z1) / 2])))
    m = bpy.data.materials.new(name + 'm')
    m.use_nodes = True
    N, Lk = m.node_tree.nodes, m.node_tree.links
    bs = N['Principled BSDF']
    bs.inputs['Roughness'].default_value = 0.6
    bs.inputs['Metallic'].default_value = 0.4
    tc = N.new('ShaderNodeTexCoord')
    br = N.new('ShaderNodeTexBrick')
    br.inputs['Color1'].default_value = (*color, 1)
    br.inputs['Color2'].default_value = (*color, 1)
    br.inputs['Mortar'].default_value = (color[0] * 1.8, color[1] * 1.8, color[2] * 1.8, 1)
    br.inputs['Scale'].default_value = 1.0
    br.inputs['Mortar Size'].default_value = 0.01
    br.inputs['Brick Width'].default_value = 1.0
    br.inputs['Row Height'].default_value = 1.0
    br.offset = 0.0
    Lk.new(tc.outputs['Generated'], br.inputs['Vector'])
    sc = N.new('ShaderNodeMapping')
    sc.inputs['Scale'].default_value = (x1 - x0, z1 - z0, 1)
    Lk.new(tc.outputs['Generated'], sc.inputs['Vector'])
    Lk.new(sc.outputs['Vector'], br.inputs['Vector'])
    Lk.new(br.outputs['Color'], bs.inputs['Base Color'])
    ob.data.materials.append(m)
    return ob


def clear(prefix=('bug', 'glint')):
    for ob in list(bpy.data.objects):
        if ob.name.startswith(prefix):
            me = ob.data
            bpy.data.objects.remove(ob)
            if me is not None and me.users == 0:
                bpy.data.meshes.remove(me)


# ------------------------------------------------------------------ parts: the model sheet
def job_parts(out):
    files = []
    Ds = {n: load(n) for n in FILES if have(n)}
    views = [  # (file, clip, frame, lod, label, az, el, dist, target, pipe)
        ('threader_head', 'idle', 0, 0, 'head 3/4', 35, 20, 6.4, (0, 0.6, 0.7), True),
        ('threader_head', 'idle', 0, 0, 'head side', 90, 4, 6.6, (0, 0.6, 0.7), True),
        ('threader_head', 'idle', 0, 0, 'head front', 180, 10, 6.0, (0, 0.5, 0.6), True),
        ('threader_head', 'idle', 0, 0, 'head top', 0, 89.5, 6.4, (0, 0.5, 0.4), True),
        ('threader_head', 'idle', 0, 0, 'head game angle', 225, 57, 7.0, (0, 0.5, 0.4), True),
        ('threader_head', 'down', 20, 0, 'head down (weak point)', 30, 34, 6.2, (0, 0.5, 0.2), False),
        ('threader_seg', 'hold', 0, 0, 'segment 3/4', 35, 20, 4.6, (0, 0, 0.1), True),
        ('threader_seg', 'hold', 0, 0, 'segment side', 90, 4, 4.8, (0, 0, 0.1), True),
        ('threader_seg', 'hold', 0, 0, 'segment front', 180, 6, 4.6, (0, 0, 0.0), True),
        ('threader_seg', 'hold', 0, 0, 'segment top', 0, 89.5, 4.8, (0, 0, 0.0), True),
        ('threader_seg', 'hold', 0, 0, 'segment game angle', 225, 57, 5.2, (0, 0, 0.0), True),
        ('threader_seg', 'crawl', 0, 0, 'segment on the deck', 35, 20, 5.0, (0, 0, -0.2), False),
        ('threader_node', 'plated', 0, 0, 'node lit, plated', 35, 30, 3.4, (0, 0.85, -0.15), True),
        ('threader_node', 'open', 0, 0, 'node lit, open', 35, 30, 3.4, (0, 0.85, -0.15), True),
        ('threader_node', 'dark', 0, 0, 'node dark (popped)', 35, 30, 3.4, (0, 0.85, -0.15), True),
        ('threader_node', 'open', 0, 0, 'node lit, game angle', 225, 57, 4.0, (0, 0.75, -0.15), True),
        ('threader_head', 'idle', 0, 1, 'head LOD1', 35, 20, 6.4, (0, 0.6, 0.7), True),
        ('threader_head', 'idle', 0, 2, 'head LOD2', 35, 20, 6.4, (0, 0.6, 0.7), True),
        ('threader_seg', 'hold', 0, 1, 'segment LOD1', 35, 20, 4.6, (0, 0, 0.1), True),
        ('threader_seg', 'hold', 0, 2, 'segment LOD2', 35, 20, 4.6, (0, 0, 0.1), True),
        ('threader_node', 'open', 0, 1, 'node LOD1', 35, 30, 3.4, (0, 0.85, -0.15), True),
        ('threader_node', 'open', 0, 2, 'node LOD2', 35, 30, 3.4, (0, 0.85, -0.15), True),
        ('threader_node', 'plated', 0, 0, 'node lit, plated, game angle', 225, 57, 4.0, (0, 0.75, -0.15), True),
        ('threader_node', 'dark', 0, 0, 'node dark, game angle', 225, 57, 4.0, (0, 0.75, -0.15), True),
    ]
    for k, (fn, cn, fr, li, lab, az, el, dist, tgt, pipe) in enumerate(views):
        if fn not in Ds:
            continue
        D = Ds[fn]
        G.reset((480, 360), 32)
        G.studio(2.2)
        if pipe:
            pipe_obj('trunk', (0, 0, -4.0), (0, 0, 4.0))
            G.floor(30.0, grid=1.0)
            bpy.data.objects['Plane'].location.z = -5.0
        else:
            G.floor(30.0, grid=1.0)
            bpy.data.objects['Plane'].location.z = -0.6 if fn == 'threader_seg' else -0.5
        mat = G.material('chitin', 'threader', emit=6.0)
        if fn == 'threader_node':
            S = Ds.get('threader_seg')
            if S is not None:
                mesh(S, li, row_of(S, 'hold'), 'bugseg', G.material('chitin2', 'threader', emit=6.0))
        mesh(D, li, row_of(D, cn, fr), 'bug0', mat)
        cam = G.camera(G.orbit(G.g2b(np.array(tgt)), az, el, dist), G.g2b(np.array(tgt)), lens=50)
        p = os.path.join(out, f'parts_{k:02d}.png')
        G.render(p)
        bpy.data.objects.remove(cam)
        files.append((p, f'{lab} ({D["lods"][li]["triangle_count"]} tris)'))
        log('parts', lab)
    G.grid(files, os.path.join(out, 'parts_sheet.png'), 6, 'The Threader — read back from App/Resources/Creatures/threader_*.ihv (rigid path), Cycles')
    return files


# ------------------------------------------------------------------ strips: every clip × 8 frames
def job_strips(out, names=FILES):
    for fn in names:
        D = load(fn)
        S = load('threader_seg') if fn == 'threader_node' else None
        files = []
        for c in D['clips']:
            n = c['frames']
            fr = [round(k * n / 8) % n for k in range(8)] if c['loop'] else [round(k * (n - 1) / 7) for k in range(8)]
            loco = c['locomotion']
            span = c['stride'] if loco else 0.0
            for k, f in enumerate(fr):
                G.reset((300, 230), 16)
                G.studio(2.0)
                deck = c['name'] in ('crawl', 'stagger_low', 'death', 'death_dk', 'coil', 'down', 'recover', 'charge', 'strike_low') \
                    or (fn == 'threader_head' and c['name'] in ('strike',))
                if fn == 'threader_head' and c['name'] in ('down', 'recover', 'charge', 'strike_low', 'death'):
                    G.floor(30.0, grid=1.0)
                    bpy.data.objects['Plane'].location.z = -0.5
                elif fn == 'threader_seg' and c['name'] == 'coil':
                    G.floor(30.0, grid=1.0)
                    bpy.data.objects['Plane'].location.z = -2.0
                elif deck and fn != 'threader_head':
                    G.floor(30.0, grid=1.0)
                    bpy.data.objects['Plane'].location.z = -0.6
                else:
                    pipe_obj('trunk', (0, 0, -6.0), (0, 0, 6.0))
                    G.floor(30.0, grid=1.0)
                    bpy.data.objects['Plane'].location.z = -5.0
                mat = G.material('chitin', 'threader', emit=6.0)
                dz = span * f / n if loco else 0.0
                M = np.eye(4)
                M[2, 3] = dz
                if S is not None:
                    sc = c['name'] if c['name'] in ('stagger', 'death') else ('stagger' if c['name'] == 'stagger_dk' else
                                                                              'death' if c['name'] == 'death_dk' else 'hold')
                    sf = f if sc in ('stagger', 'death') else 0
                    mesh(S, 0, row_of(S, sc, sf), 'bugseg', G.material('chitin2', 'threader', emit=6.0), M=M)
                mesh(D, 0, c['first'] + f, 'bug0', mat, M=M)
                tg = np.array([0, 0.3 if fn != 'threader_head' else 0.6, (0.4 if fn == 'threader_head' else 0.1) + dz * 0 + span * 0.5])
                tg = np.array([0.0, 0.5 if fn == 'threader_head' else 0.2, span * 0.5 + (1.0 if fn == 'threader_head' else 0.0)])
                dist = {'threader_head': 9.0, 'threader_seg': 5.6, 'threader_node': 4.6}[fn] + span * 0.8
                cam = G.camera(G.orbit(G.g2b(tg), 62, 18, dist), G.g2b(tg), lens=50)
                p = os.path.join(out, f'strip_{fn}_{c["name"]}_{k}.png')
                G.render(p)
                bpy.data.objects.remove(cam)
                files.append((p, f'{fn[9:]} {c["name"]} f{f}'))
            log('strip', fn, c['name'])
        G.grid(files, os.path.join(out, f'strips_{fn}.png'), 8, f'{fn}: every clip × 8 frames (LOD0, read back from the ihv)')


# ------------------------------------------------------------------ body: the whole Threader at the game camera
def body_path(kind='trunks'):
    """a body path (game space, head first, 0.05 m steps) like B4's: 'trunks' — the head on trunk 3 (x = +3.5, along z)
    coming south over the island, the body behind it back round the crossing from trunk 1 (z = +3.5) and on along it;
    'coil' — the 2 m ring round a deck spot; 'deck' — the deck chase."""
    pts = []
    if kind == 'trunks':
        # the head at (3.5, 5, -1.0) heading -z (north); behind it the trunk back to the crossing (3.5, 5, 3.5) — a
        # rounded corner (B4's path is sharp there; the chords hide it) — then trunk 1 west to the ring
        for t in np.arange(0, 4.5, 0.05):
            pts.append((3.5, 5.0, -1.0 + t))
        for a in np.arange(0, math.pi / 2, 0.05 / 0.6):
            pts.append((3.5 - 0.6 + 0.6 * math.cos(a), 5.0, 3.5 - 0.6 + 0.6 * math.sin(a) + 0.0))
        for t in np.arange(0, 40, 0.05):
            pts.append((2.9 - t, 5.0, 3.5))
    elif kind == 'coil':
        cx, cz, r = 0.0, 0.0, 3.5
        for a in np.arange(0, 2 * math.pi, 0.05 / r):
            pts.append((cx + r * math.sin(-a), 2.0, cz + r * math.cos(-a)))
        for t in np.arange(0, 40, 0.05):
            pts.append((cx + 0.0, 2.0 + min(3.0, t * 0.6), cz + r + t))
    else:
        for t in np.arange(0, 40, 0.05):
            pts.append((2.0 * math.sin(t / 5.0), 0.6, -6.0 + t))
    return np.array(pts)


def at_arc(P, s):
    """the path point s m behind its first point (polyline arc length)"""
    d = np.r_[0, np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))]
    s = min(max(s, 0), d[-1])
    i = min(np.searchsorted(d, s), len(P) - 1)
    if i == 0:
        return P[0]
    t = (s - d[i - 1]) / max(d[i] - d[i - 1], 1e-9)
    return P[i - 1] * (1 - t) + P[i] * t


def chord(P, s_front, s_back):
    """an instance on the chord between two path points: (position = midpoint, heading, pitch)"""
    a, b = at_arc(P, s_front), at_arc(P, s_back)
    d = a - b
    hd = math.atan2(d[0], d[2])
    pitch = math.atan2(d[1], math.hypot(d[0], d[2]))
    return (a + b) / 2, hd, pitch


def lay_body(Ds, P, lod, mats, gm, seg_clip='hold', head_clip='sweep', node_clips=None, t=0.0, phase=True, prefix='bug'):
    """the Threader laid as B5 lays it: the head on the chord (head point → 1.2 m behind), segment j on the chord
    d ± 0.8 (d = 2 + (j - 1) × 1.6), node k in its segment's transform"""
    H, S, N = Ds['threader_head'], Ds['threader_seg'], Ds['threader_node']
    node_clips = node_clips or {}
    pos, hd, pitch = chord(P, 0.0, 1.2)
    head_pos = at_arc(P, 0.0)
    M = xform_of(head_pos, hd, pitch)
    c = clip(H, head_clip)
    f = int(t * 30) % c['frames'] if c['loop'] else min(int(t * 30), c['frames'] - 1)
    mesh(H, lod, c['first'] + f, f'{prefix}head', mats['head'], M=M)
    glints(H, c['first'] + f, f'glinthead', gm, M)
    cs = clip(S, seg_clip)
    for j in range(1, 19):
        d = 2.0 + (j - 1) * 1.6
        pos, hd, pitch = chord(P, d - 0.8, d + 0.8)
        M = xform_of(pos, hd, pitch)
        if cs['loop']:
            ph = (t * 30 / cs['frames'] + (0.13 * j if phase else 0.0)) % 1.0
            f = int(ph * cs['frames']) % cs['frames']
        else:
            f = min(int(t * 30), cs['frames'] - 1)
        mesh(S, lod, cs['first'] + f, f'{prefix}seg{j}', mats['seg'], M=M)
        if j in (3, 6, 9, 12, 15):
            nc = clip(N, node_clips.get(j, 'open'))
            nf = int(t * 30) % nc['frames'] if nc['loop'] else nc['frames'] - 1
            mesh(N, lod, nc['first'] + nf, f'{prefix}node{j}', mats['node'], M=M)
            glints(N, nc['first'] + nf, f'glintnode{j}', gm, M)


def arena(with_island=True):
    """the Manifold mock-up for the read-back: island deck 14 × 14 m at 0, pump housing block, ring segment, the four
    trunks at 5 m (their tops), the ring duct at 8 m (0.9 × 0.7)"""
    if with_island:
        deck_obj('island', -7, -7, 7, 7)
        deck_obj('ringS', -17, 13, 17, 17)
        deck_obj('ringE', 13, -13, 17, 13)
        deck_obj('bridgeE', 7, -1.5, 13, 1.5)
        deck_obj('bridgeS', -1.5, 7, 1.5, 13)
        bpy.ops.mesh.primitive_cube_add(size=1.0)
        pb = bpy.context.active_object
        pb.name = 'pump'
        pb.scale = (4, 4, 2.6)
        pb.location = (0, 0, 1.3)
        m = bpy.data.materials.new('pumpm'); m.use_nodes = True
        m.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.03, 0.035, 0.04, 1)
        pb.data.materials.append(m)
    for k in range(4):
        off = -3.5 if k in (0, 2) else 3.5
        if k < 2:
            pipe_obj(f'trunk{k}', (-17.5, 5, off), (17.5, 5, off))
        else:
            pipe_obj(f'trunk{k}', (off, 5, -17.5), (off, 5, 17.5))


def game_cam(target, W, H):
    pitch, yaw = math.radians(57), math.pi / 4
    dist = 10.8 / math.tan(math.radians(20))
    tg = np.asarray(target, float)
    cam_g = tg + np.array([math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch)]) * dist
    return G.camera(tuple(G.g2b(cam_g)), tuple(G.g2b(tg)), fov_v=40), cam_g


def lights_game(spot_at=(0, 0, 0), lantern=None, mood='show'):
    """'show': the forms lit for review — a cold moon, a warm key from the camera's side (a squad torch up high), the
    lure's own pale light; 'game': the game's darkness — a faint moon, one torch on the deck, the lure"""
    sp = np.asarray(spot_at, float)
    if mood == 'show':
        G.light('SUN', tuple(G.g2b(np.array([-25, 60, 35]))), (0, 0, 0), 1.1, (0.62, 0.72, 0.92), size=0.08)
        G.light('SPOT', tuple(G.g2b(sp + np.array([9.0, 11.0, 9.0]))), tuple(G.g2b(sp + np.array([0.0, 3.0, 0.0]))), 9000,
                (1.0, 0.9, 0.76), size=0.1, spot=0.8, blend=0.6)
    else:
        G.light('SUN', tuple(G.g2b(np.array([-25, 60, 35]))), (0, 0, 0), 0.25, (0.56, 0.67, 0.87), size=0.05)
        G.light('SPOT', tuple(G.g2b(sp + np.array([3.0, 1.4, 3.0]))), tuple(G.g2b(sp + np.array([-1.5, 0.0, -1.5]))), 2600,
                (1.0, 0.89, 0.73), size=0.05, spot=1.0, blend=0.5)
    if lantern is not None:
        G.light('POINT', tuple(G.g2b(np.asarray(lantern, float))), (0, 0, 0), 260, (0.92, 0.88, 1.0), size=0.15)


def lantern_pos(Ds, P, head_clip, t):
    """the world position of the head's `lantern` socket as lay_body places the head"""
    H = Ds['threader_head']
    pos, hd, pitch = chord(P, 0.0, 1.2)
    M = xform_of(at_arc(P, 0.0), hd, pitch)
    c = clip(H, head_clip)
    f = int(t * 30) % c['frames'] if c['loop'] else min(int(t * 30), c['frames'] - 1)
    so = next(x for x in H['sockets'] if x['name'] == 'lantern')
    p = ihv.rigid_row(H, H['lods'][0], c['first'] + f)[0][so['vid'][0]]
    return place(p[None], p[None], M)[0][0]


def job_body(out):
    Ds = {n: load(n) for n in FILES}
    W, H = 2532, 1170                  # iPhone 12 landscape drawable (3×)
    trunks = {3: 'plated', 6: 'plated', 9: 'open', 12: 'dark', 15: 'plated'}
    shots = [  # (name, path kind, look target, seg clip, head clip, node states, lod, t)
        ('body_trunks', 'trunks', (-3.0, 0.0, 1.0), 'hold', 'sweep', trunks, 0, 0.3),
        ('body_trunks_lod1', 'trunks', (-3.0, 0.0, 1.0), 'hold', 'sweep', trunks, 1, 0.3),
        ('body_trunks_lod2', 'trunks', (-3.0, 0.0, 1.0), 'hold', 'sweep', trunks, 2, 0.3),
        ('body_coil', 'coil', (0.0, 0.0, 2.5), 'coil', 'coil', {3: 'open', 6: 'open', 9: 'dark', 12: 'open', 15: 'open'}, 0, 0.5),
        ('body_deck', 'deck', (0.0, 0.0, 4.0), 'crawl', 'charge', {3: 'open', 6: 'dark', 9: 'dark', 12: 'open', 15: 'dark'}, 0, 0.2),
    ]
    only = os.environ.get('BODY_SHOTS')
    if only:
        shots = [x for x in shots if x[0] in only.split(',')]
    res = []
    for name, kind, tgt, sc, hc, nodes, lod, t in shots:
        G.reset((W, H), 24)
        w = bpy.context.scene.world.node_tree.nodes['Background']
        w.inputs[0].default_value = (0.03, 0.04, 0.065, 1)
        w.inputs[1].default_value = 0.5
        arena(with_island=True)
        game_cam(tgt, W, H)
        Pq = body_path(kind)
        lights_game(tgt, lantern=lantern_pos(Ds, Pq, hc, t))
        mats = {k: G.material(f'chitin_{k}', 'threader', emit=6.0) for k in ('head', 'seg', 'node')}
        gm = G.glint_material()
        gm.node_tree.nodes['Emission'].inputs['Color'].default_value = (0.9, 0.85, 1.0, 1)
        P = body_path(kind)
        lay_body(Ds, P, lod, mats, gm, seg_clip=sc, head_clip=hc, node_clips=nodes, t=t)
        p = os.path.join(out, f'{name}.png')
        G.render(p)
        res.append((p, name))
        log('body', name)
    # the LOD pop at the game camera: the trunks shot at LOD0 / LOD1 / LOD2, mean luma over the body's pixels (where any
    # LOD differs from another by more than 6 levels or from the darkest frame) and the mean |Δ| between neighbours
    from PIL import Image
    L = {}
    for k in (0, 1, 2):
        f = os.path.join(out, 'body_trunks' + ('' if k == 0 else f'_lod{k}') + '.png')
        if os.path.exists(f):
            L[k] = np.asarray(Image.open(f).convert('L')).astype(np.float64)
    if len(L) == 3:
        mask = (np.abs(L[0] - L[1]) > 6) | (np.abs(L[1] - L[2]) > 6) | (np.maximum(np.maximum(L[0], L[1]), L[2]) > 40)
        rep = dict(px=int(mask.sum()), mean=[float(L[k][mask].mean()) for k in (0, 1, 2)],
                   d01=float(np.abs(L[0] - L[1])[mask].mean()), d12=float(np.abs(L[1] - L[2])[mask].mean()))
        import json
        json.dump(rep, open(os.path.join(out, 'body_lods.json'), 'w'), indent=1)
        log(f"LODs at the game camera over {rep['px']} px: mean luma {rep['mean'][0]:.1f} / {rep['mean'][1]:.1f} / {rep['mean'][2]:.1f}, "
            f"|Δ| LOD0→1 {rep['d01']:.1f}, LOD1→2 {rep['d12']:.1f}")
    return res


if __name__ == '__main__':
    what, out = sys.argv[1], os.path.abspath(sys.argv[2])
    os.makedirs(out, exist_ok=True)
    if what == 'parts':
        job_parts(out)
    elif what == 'strips':
        job_strips(out, sys.argv[3:] or FILES)
    elif what == 'body':
        job_body(out)
    log('done')
