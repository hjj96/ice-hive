"""Game-camera read-back of the Manifold (Stage 2 B2): a fresh Blender process builds B4's arena layout (Manifold.swift:
the 14 × 14 m island, the pump housing, the 4 m catwalk ring at 13–17 m, four 3 m radial bridges, the four trunks of
the «#» at 5 m, the ring duct at 8 m, four duct mouths) out of the SHIPPED kit — App/Resources/Kit/station.ihk with its
trim sheets and AO atlas (readback_kit.py's material) — placing the mf_* pieces as B5 would, the long runs (the trunk
pipes, the duct, the decks) as runtime extrusions on the same trim rules (kitgeo), and lays the SHIPPED Threader
(threader_readback.py) along the trunks. Cycles, CPU, fixed threads.

  venv/bin/python checks/manifold_readback.py OUT_DIR [--samples 24]
Writes manifold_game.png (the game camera: pitch 57°, yaw 45°, fov 40°, iPhone 12 3× landscape 2532 × 1170),
manifold_wide.png (the whole arena), manifold_close.png (a crossing, a ring post and the body gripping the trunk).
"""
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, TOOLS)
sys.path.insert(0, os.path.join(TOOLS, 'kit'))
import bpy  # noqa: E402
from mathutils import Matrix  # noqa: E402

import game_camera as G  # noqa: E402
import ihk  # noqa: E402
import iht  # noqa: E402
import kitgeo  # noqa: E402
import manifold as MF  # noqa: E402
import readback_kit as RK  # noqa: E402
import threader_readback as TR  # noqa: E402

KIT = os.path.join(G.ROOT, 'App', 'Resources', 'Kit')
C4 = np.array([[-1, 0, 0, 0], [0, 0, 1, 0], [0, 1, 0, 0], [0, 0, 0, 1]], dtype=np.float64)    # game ↔ Blender
# B4's numbers (IceHiveCore/Manifold.swift)
TRUNK_Y, DUCT_Y, DUCT_HALF, OFF, RISER, LEG = 5.0, 8.0, 16.0, 3.5, 17.5, 15.0
MOUTH = 14.8


def game_xform(t, yaw=0.0):
    c, s = math.cos(yaw), math.sin(yaw)
    M = np.eye(4)
    M[:3, :3] = np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])
    M[:3, 3] = t
    return M


def set_game(ob, M):
    ob.matrix_world = Matrix((C4 @ M @ C4).tolist())


class Kit:
    """the shipped kit: pieces by name, materials per trim layer (with the AO atlas for pieces, without for runtime
    geometry — fs_level's AO strength 0)"""

    def __init__(self):
        self.D = ihk.read(os.path.join(KIT, 'station.ihk'))
        TN = iht.read(os.path.join(KIT, 'trim_normal.iht'))
        TO = iht.read(os.path.join(KIT, 'trim_orm.iht'))
        TA = iht.read(os.path.join(KIT, 'kit_ao.iht'))
        ao = RK.image('ao', iht.decode_level(TA, 0, 0))
        self.mats, self.flat = {}, {}
        for l in range(TN['layers']):
            n_img, o_img = RK.image(f'n{l}', iht.decode_level(TN, l, 0)), RK.image(f'o{l}', iht.decode_level(TO, l, 0))
            self.mats[l] = RK.material_for(l, n_img, o_img, ao)
            self.flat[l] = RK.material_for(l, n_img, o_img, None)
        self.mats[255] = RK.material_for(None, None, None, ao)
        self.flat[255] = RK.material_for(None, None, None, None)
        self.pieces = {p['name']: p for p in self.D['pieces']}
        self.n = 0

    def place(self, name, t, yaw=0.0):
        self.n += 1
        ob = RK.piece_object(self.pieces[name], self.mats, f'kit{self.n}_{name}')
        set_game(ob, game_xform(np.asarray(t, float), yaw))
        return ob

    def runtime(self, mesh, name, M=None):
        """a kitgeo Mesh (runtime extrusion: the trunk pipes, the duct, the decks) → an object with its trim uvs"""
        mesh = kitgeo.Mesh().merge(mesh)
        V = np.array(mesh.V)
        tris, uvs, fl = [], [], []
        for f in mesh.faces:
            for k in range(1, len(f.idx) - 1):
                tris.append((f.idx[0], f.idx[k], f.idx[k + 1]))
                uvs.append((f.uv[0], f.uv[k], f.uv[k + 1]))
                fl.append(f)
        me = bpy.data.meshes.new(name)
        me.from_pydata(G.g2b(V).tolist(), [], tris)
        tl = me.uv_layers.new(name='trim')
        tl.data.foreach_set('uv', np.array([[u, 1.0 - v] for tri in uvs for (u, v) in tri]).ravel())
        me.uv_layers.new(name='ao')
        tint = np.array([RK.srgb2lin(np.array([(f.tint >> 16) & 255, (f.tint >> 8) & 255, f.tint & 255]) / 255.0) for f in fl])
        ca = me.color_attributes.new('tint', 'FLOAT_COLOR', 'CORNER')
        ca.data.foreach_set('color', np.concatenate([np.repeat(tint, 3, axis=0), np.ones((3 * len(fl), 1))], 1).ravel())
        for nm, vals in (('emis', [f.emis for f in fl]), ('metal', [f.metal for f in fl])):
            at = me.attributes.new(nm, 'FLOAT', 'CORNER')
            at.data.foreach_set('value', np.repeat(np.array(vals, float), 3))
        keys = sorted(self.flat)
        for k in keys:
            me.materials.append(self.flat[k])
        me.polygons.foreach_set('material_index', [keys.index(f.layer if f.layer in self.flat else 255) for f in fl])
        me.polygons.foreach_set('use_smooth', [f.smooth for f in fl])
        ob = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(ob)
        if M is not None:
            set_game(ob, M)
        return ob


def deck(K, x0, z0, x1, z1, name):
    m = kitgeo.Mesh()
    q = [m.add_vertex(p) for p in ((x0, 0, z0), (x1, 0, z0), (x1, 0, z1), (x0, 0, z1))]
    kitgeo.add_face(m, kitgeo._ccw(m, q, (0, 1, 0)), kitgeo.Mat(0x4b5664, 0.3, layer=kitgeo.GRATINGS))
    # the riveted skirt band round its edge (WorldLevel's edge, simplified) with the cyan strip in its groove
    for (a, b) in (((x0, z0), (x1, z0)), ((x1, z0), (x1, z1)), ((x1, z1), (x0, z1)), ((x0, z1), (x0, z0))):
        m.merge(kitgeo.beam((a[0], -0.16, a[1]), (b[0], -0.16, b[1]), 0.06, 0.3, 0.01,
                            kitgeo.Mat(0x29313a, 0.75, layer=kitgeo.RAILS, uv='strip', strip=0)))
    return K.runtime(m, name)


def trunk_run(K, a, b, name):
    """a runtime trunk pipe whose TOP runs a → b (game, y = the route line)"""
    a, b = np.asarray(a, float), np.asarray(b, float)
    d = b - a
    L = float(np.linalg.norm(d))
    cyl = kitgeo.cylinder(MF.TRUNK_R, L, 16, MF.PIPE.but(smooth=True), axis='x', cap=False)
    yaw = math.atan2(-d[2], d[0])
    M = game_xform((a + b) / 2 - np.array([0, MF.TRUNK_R, 0]), yaw)
    return K.runtime(cyl, name, M)


def duct_run(K, a, b, name):
    a, b = np.asarray(a, float), np.asarray(b, float)
    m = kitgeo.beam(a - np.array([0, MF.DUCT_H / 2, 0]), b - np.array([0, MF.DUCT_H / 2, 0]), MF.DUCT_W, MF.DUCT_H, 0.05, MF.DUCT)
    return K.runtime(m, name)


def manifold(K):
    """B4's arena out of the kit"""
    deck(K, -7, -7, 7, 7, 'island')
    for (x0, z0, x1, z1) in ((-17, -17, 17, -13), (-17, 13, 17, 17), (-17, -13, -13, 13), (13, -13, 17, 13)):
        deck(K, x0, z0, x1, z1, f'ring{x0}{z0}')
    bridges = ((7, -1.5, 13, 1.5), (-13, -1.5, -7, 1.5), (-1.5, 7, 1.5, 13), (-1.5, -13, 1.5, -7))
    for (x0, z0, x1, z1) in bridges:
        deck(K, x0, z0, x1, z1, f'bridge{x0}{z0}')
        along_x = (x1 - x0) > (z1 - z0)
        for side in (-1, 1):
            if along_x:
                xs = (x0, x1) if x0 > 0 else (x1, x0)
                K.place('mf_bridge_truss', (xs[0], 0.0, side * 1.4), 0.0 if x0 > 0 else math.pi)
            else:
                zs = (z0, z1) if z0 > 0 else (z1, z0)
                K.place('mf_bridge_truss', (side * 1.4, 0.0, zs[0]), -math.pi / 2 if z0 > 0 else math.pi / 2)
    for k in range(4):
        K.place('mf_pump', (0, 0, 0), k * math.pi / 2)
    # the trunks: 0 / 1 along x at z ∓3.5, 2 / 3 along z at x ∓3.5; each from riser to riser, broken at the crossings
    xs = [-RISER, -OFF - 0.68, -OFF + 0.68, OFF - 0.68, OFF + 0.68, RISER]
    for k in range(4):
        off = -OFF if k in (0, 2) else OFF
        P = (lambda u, off=off: (u, TRUNK_Y, off)) if k < 2 else (lambda u, off=off: (off, TRUNK_Y, u))
        yaw = 0.0 if k < 2 else -math.pi / 2
        for i in range(0, len(xs), 2):
            trunk_run(K, P(xs[i]), P(xs[i + 1]), f'trunk{k}_{i}')
        for u in np.arange(-LEG + 1.75, LEG, 3.5):
            if min(abs(u - OFF), abs(u + OFF)) > 1.0 and abs(abs(u) - LEG) > 0.6:
                K.place('mf_trunk_band', P(u), yaw)
        for s in (-1, 1):
            pp = np.array(P(s * LEG), float)
            pp[1] = 0.0
            K.place('mf_trunk_post', pp, yaw)
            K.place('mf_riser_tee', P(s * LEG), yaw)
            # the elbow at the riser: +x outward
            K.place('mf_trunk_elbow', P(s * RISER), (0.0 if s > 0 else math.pi) + yaw)
            # the vertical pipe down into the abyss from the elbow
            e = np.array(P(s * RISER), float) + (np.array([s * MF.ELBOW_R, 0, 0]) if k < 2 else np.array([0, 0, s * MF.ELBOW_R]))
            top = e - np.array([0, MF.TRUNK_R + MF.ELBOW_R + 0.25, 0])
            cyl = kitgeo.cylinder(MF.TRUNK_R, 30.0, 14, MF.PIPE.but(smooth=True), axis='y', cap=False)
            K.runtime(cyl, f'riser{k}{s}', game_xform(top - np.array([0, 15.0, 0])))
            # the riser pipe from the tee up to the duct
            leg = np.array(P(s * LEG), float)
            duct_pt = leg * (DUCT_HALF / LEG)
            duct_pt[1] = DUCT_Y - MF.DUCT_H
            K.runtime(MF.sweep([leg + np.array([0, 0.38, 0]), duct_pt], 0.3, 12, MF.PIPE), f'rpipe{k}{s}')
    for cx in (-OFF, OFF):
        for cz in (-OFF, OFF):
            K.place('mf_trunk_cross', (cx, TRUNK_Y, cz))
    # the ring duct: the square at ±16, 8 m; corners, runs, bands; the drops to the mouths
    h = DUCT_HALF
    corners = [((-h, -h), 0.0), ((h, -h), -math.pi / 2), ((h, h), math.pi), ((-h, h), math.pi / 2)]
    for (cx, cz), yaw in corners:
        K.place('mf_duct_corner', (cx, DUCT_Y, cz), yaw)
    for i in range(4):
        (ax, az), _ = corners[i]
        (bx, bz), _ = corners[(i + 1) % 4]
        d = np.array([bx - ax, 0, bz - az]) / (2 * h)
        a = np.array([ax, DUCT_Y, az]) + d * 0.66
        b = np.array([bx, DUCT_Y, bz]) - d * 0.66
        duct_run(K, a, b, f'duct{i}')
        yaw = math.atan2(-d[2], d[0])
        for t in np.arange(1.6, 2 * h - 1.6, 2.5):
            K.place('mf_duct_band', np.array([ax, DUCT_Y, az]) + d * t, yaw)
    for sx, sz in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
        top = np.array([sx * (h - 0.6), DUCT_Y - MF.DUCT_H - 0.2, sz * (h - 0.6)])
        mouth = np.array([sx * MOUTH, 4.6, sz * MOUTH])
        duct_run(K, top + np.array([0, MF.DUCT_H / 2, 0]), mouth + np.array([0, 0.0, 0]), f'drop{sx}{sz}')
        K.place('oh_duct_mouth', mouth, math.atan2(sz, -sx))


def main():
    args = sys.argv[1:]
    out = os.path.abspath(args[0])
    samples = int(args[args.index('--samples') + 1]) if '--samples' in args else 24
    os.makedirs(out, exist_ok=True)
    Ds = {n: TR.load(n) for n in TR.FILES}
    W, H = 2532, 1170
    shots = [  # name, camera kind, target, path, seg clip, head clip, nodes, t
        ('manifold_game', 'game', (-1.5, 0.0, 1.5), 'trunks', 'hold', 'sweep', {3: 'plated', 6: 'plated', 9: 'open', 12: 'plated', 15: 'dark'}, 0.4),
        ('manifold_wide', 'wide', (0.0, 0.0, 0.0), 'trunks', 'hold', 'sweep', {3: 'plated', 6: 'plated', 9: 'open', 12: 'plated', 15: 'dark'}, 0.4),
        ('manifold_close', 'close', (3.5, 4.0, 1.2), 'trunks', 'grip', 'idle', {3: 'plated', 6: 'open', 9: 'open', 12: 'plated', 15: 'dark'}, 0.2),
    ]
    for name, kind, tgt, pk, sc, hc, nodes, t in shots:
        G.reset((W, H), samples)
        bpy.context.scene.view_settings.view_transform = 'AgX'
        w = bpy.context.scene.world.node_tree.nodes['Background']
        w.inputs[0].default_value = (0.012, 0.018, 0.03, 1)
        w.inputs[1].default_value = 0.6
        K = Kit()
        manifold(K)
        P = TR.body_path(pk)
        mats = {k: G.material(f'chitin_{k}', 'threader', emit=6.0) for k in ('head', 'seg', 'node')}
        gm = G.glint_material()
        gm.node_tree.nodes['Emission'].inputs['Color'].default_value = (0.9, 0.85, 1.0, 1)
        TR.lay_body(Ds, P, 0, mats, gm, seg_clip=sc, head_clip=hc, node_clips=nodes, t=t)
        tg = np.asarray(tgt, float)
        if kind == 'game':
            TR.game_cam(tg, W, H)
        elif kind == 'wide':
            pitch, yaw = math.radians(57), math.pi / 4
            cam = tg + np.array([math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch)]) * 62.0
            G.camera(tuple(G.g2b(cam)), tuple(G.g2b(tg)), fov_v=40)
        else:
            cam = tg + np.array([7.0, 3.2, 7.5])
            G.camera(tuple(G.g2b(cam)), tuple(G.g2b(tg)), fov_v=40)
        TR.lights_game(tg if kind != 'wide' else (0, 0, 0), lantern=TR.lantern_pos(Ds, P, hc, t))
        # the duct mouths' amber grid lights, a lamp on the ring (the station's light language)
        for sx, sz in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            G.light('POINT', tuple(G.g2b(np.array([sx * 14.0, 4.2, sz * 14.0]))), (0, 0, 0), 120, (1.0, 0.6, 0.15), size=0.2)
        p = os.path.join(out, f'{name}.png')
        G.render(p)
        G.log('manifold', name)
    G.log('done')


if __name__ == '__main__':
    main()
