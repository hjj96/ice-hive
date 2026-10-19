"""Station trim sheets (headless Blender + Cycles bakes):

  venv/bin/python kit/trims.py OUTDIR [--previews DIR] [--res 1024]

Four 2 m × 2 m sheets (kitgeo.LAYER_NAMES) are modelled as high-poly relief over the XY plane (Z = height, the top
surface at Z = 0, features within +1.5 cm / -8 cm) and baked onto a flat low-poly plane:
  NORMAL (tangent space, OpenGL green = +V), AO, ROUGHNESS, and one EMIT pass carrying metal (R) and rime
  receptivity (G: up-facing tops of bars, rims and bolts — where WorldLevel's frost mask may lay rime).
Packed per layer: normal xyz → trim_normal.iht (ASTC 5×5, X in rgb / Y in alpha), ORM + rime → trim_orm.iht
(ASTC 6×6: R AO, G roughness (Toksvig-raised in the mips), B metal, A rime); both 2D arrays of 4 layers with full
mip chains. Metal row order: image row 0 = the top of the sheet (Blender Y = 2).
Strip sheets (RAILS, PIPES): 8 strips of 0.25 m (Metal v ∈ [k/8, (k+1)/8] ↔ Blender Y ∈ [2-(k+1)/4, 2-k/4]), each
tiling along X; the relief stays clear of the strip borders so mips do not bleed.
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
import bmesh  # noqa: E402  (after bpy: bpy puts Blender's modules on the path)

import iht  # noqa: E402
import kitgeo  # noqa: E402

T0 = time.time()
THREADS = 3
SIZE = 2.0          # metres per sheet


def log(*a):
    print(f'[{time.time() - T0:6.1f}s]', *a, flush=True)


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.device = 'CPU'
    sc.cycles.seed = 0
    sc.render.threads_mode = 'FIXED'
    sc.render.threads = THREADS
    return sc


# ---------------------------------------------------------------- materials
MATS = {}


def mat(name, rough, metal, rime=0.0, grime=0.25):
    """Principled material; roughness carries wear noise + crevice grime; emission carries (metal, rime·up, 0) for
    the EMIT bake (the emission is switched on only for that bake)."""
    if name in MATS:
        return MATS[name]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    N, L = m.node_tree.nodes, m.node_tree.links
    b = N['Principled BSDF']
    b.inputs['Base Color'].default_value = (0.3, 0.32, 0.35, 1)
    b.inputs['Metallic'].default_value = metal
    tc = N.new('ShaderNodeTexCoord')
    nz = N.new('ShaderNodeTexNoise')
    nz.inputs['Scale'].default_value = 7.0
    nz.inputs['Detail'].default_value = 5.0
    mp = N.new('ShaderNodeMapping')
    mp.inputs['Scale'].default_value = (1.0, 5.0, 1.0)
    L.new(tc.outputs['Object'], mp.inputs[0])
    L.new(mp.outputs[0], nz.inputs['Vector'])
    ao = N.new('ShaderNodeAmbientOcclusion')
    ao.samples = 8
    ao.inputs['Distance'].default_value = 0.025
    inv = N.new('ShaderNodeMath')
    inv.operation = 'SUBTRACT'
    inv.inputs[0].default_value = 1.0
    L.new(ao.outputs['AO'], inv.inputs[1])
    gr = N.new('ShaderNodeMath')
    gr.operation = 'MULTIPLY'
    gr.inputs[1].default_value = grime
    L.new(inv.outputs[0], gr.inputs[0])
    rr = N.new('ShaderNodeMapRange')
    rr.inputs['To Min'].default_value = rough - 0.1
    rr.inputs['To Max'].default_value = rough + 0.1
    L.new(nz.outputs['Fac'], rr.inputs['Value'])
    add = N.new('ShaderNodeMath')
    add.operation = 'ADD'
    add.use_clamp = True
    L.new(rr.outputs['Result'], add.inputs[0])
    L.new(gr.outputs[0], add.inputs[1])
    L.new(add.outputs[0], b.inputs['Roughness'])
    # emission (EMIT bake): R = metal, G = rime · smoothstep(0.6, 0.95, N.z)
    geo = N.new('ShaderNodeNewGeometry')
    sep = N.new('ShaderNodeSeparateXYZ')
    L.new(geo.outputs['Normal'], sep.inputs[0])
    up = N.new('ShaderNodeMapRange')
    up.interpolation_type = 'SMOOTHSTEP'
    up.inputs['From Min'].default_value = 0.6
    up.inputs['From Max'].default_value = 0.95
    L.new(sep.outputs['Z'], up.inputs['Value'])
    rm = N.new('ShaderNodeMath')
    rm.operation = 'MULTIPLY'
    rm.inputs[1].default_value = rime
    L.new(up.outputs['Result'], rm.inputs[0])
    comb = N.new('ShaderNodeCombineXYZ')
    comb.inputs['X'].default_value = metal
    L.new(rm.outputs[0], comb.inputs['Y'])
    L.new(comb.outputs[0], b.inputs['Emission Color'])
    b.inputs['Emission Strength'].default_value = 0.0
    MATS[name] = m
    return m


def emission(on):
    for m in MATS.values():
        m.node_tree.nodes['Principled BSDF'].inputs['Emission Strength'].default_value = 1.0 if on else 0.0


# ---------------------------------------------------------------- high-poly builders (one bmesh per material)
class Sheet:
    def __init__(self, name):
        self.name = name
        self.parts = {}         # material name -> bmesh

    def bm(self, m):
        if m.name not in self.parts:
            self.parts[m.name] = (m, bmesh.new())
        return self.parts[m.name][1]

    def box(self, m, x0, x1, y0, y1, z0, z1):
        b = self.bm(m)
        r = bmesh.ops.create_cube(b, size=1.0)
        vs = r['verts']
        bmesh.ops.scale(b, vec=(x1 - x0, y1 - y0, z1 - z0), verts=vs)
        bmesh.ops.translate(b, vec=((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), verts=vs)

    def cyl(self, m, x, y, z, r, depth, axis='z', seg=24):
        b = self.bm(m)
        res = bmesh.ops.create_cone(b, cap_ends=True, cap_tris=False, segments=seg, radius1=r, radius2=r, depth=depth)
        vs = res['verts']
        if axis == 'x':
            bmesh.ops.rotate(b, cent=(0, 0, 0), matrix=_rot('Y', math.pi / 2), verts=vs)
        elif axis == 'y':
            bmesh.ops.rotate(b, cent=(0, 0, 0), matrix=_rot('X', math.pi / 2), verts=vs)
        bmesh.ops.translate(b, vec=(x, y, z), verts=vs)

    def sphere(self, m, x, y, z, r, sz=1.0):
        b = self.bm(m)
        res = bmesh.ops.create_uvsphere(b, u_segments=12, v_segments=6, radius=r)
        vs = res['verts']
        bmesh.ops.scale(b, vec=(1, 1, sz), verts=vs)
        bmesh.ops.translate(b, vec=(x, y, z), verts=vs)

    def hexbolt(self, m, x, y, z_top, r=0.011, h=0.008):
        b = self.bm(m)
        res = bmesh.ops.create_cone(b, cap_ends=True, cap_tris=False, segments=6, radius1=r, radius2=r, depth=h)
        bmesh.ops.translate(b, vec=(x, y, z_top - h / 2), verts=res['verts'])

    def build(self, bevel=0.003):
        obs = []
        for mname in sorted(self.parts):
            m, b = self.parts[mname]
            me = bpy.data.meshes.new(f'{self.name}.{mname}')
            b.to_mesh(me)
            b.free()
            ob = bpy.data.objects.new(me.name, me)
            bpy.context.scene.collection.objects.link(ob)
            me.materials.append(m)
            for p in me.polygons:
                p.use_smooth = True
            if bevel > 0:
                bv = ob.modifiers.new('bv', 'BEVEL')
                bv.width = bevel
                bv.segments = 2
                bv.limit_method = 'ANGLE'
                bv.angle_limit = math.radians(40)
                bv.harden_normals = False
            ws = ob.modifiers.new('ws', 'WEIGHTED_NORMAL')
            ws.keep_sharp = True
            obs.append(ob)
        return obs


def _rot(axis, a):
    from mathutils import Matrix
    return Matrix.Rotation(a, 3, axis)


# ---------------------------------------------------------------- the four sheets
def sheet_gratings():
    s = Sheet('gratings')
    bar = mat('g_bar', 0.5, 0.85, rime=1.0)
    frame = mat('g_frame', 0.42, 0.85, rime=0.55)
    rod = mat('g_rod', 0.55, 0.8, rime=0.2)
    pit = mat('g_pit', 0.95, 0.0, grime=0.0)
    bolt = mat('g_bolt', 0.3, 0.9, rime=0.3)
    s.box(pit, 0, SIZE, 0, SIZE, -0.09, -0.08)
    fw, depth = 0.04, 0.06
    for tx in range(2):
        for ty in range(2):
            x0, y0 = tx * 1.0, ty * 1.0
            # frame (4 flat bars) with a 4 mm gap between tiles
            g = 0.004
            s.box(frame, x0 + g, x0 + 1 - g, y0 + g, y0 + g + fw, -depth, 0.0)
            s.box(frame, x0 + g, x0 + 1 - g, y0 + 1 - g - fw, y0 + 1 - g, -depth, 0.0)
            s.box(frame, x0 + g, x0 + g + fw, y0 + g + fw, y0 + 1 - g - fw, -depth, 0.0)
            s.box(frame, x0 + 1 - g - fw, x0 + 1 - g, y0 + g + fw, y0 + 1 - g - fw, -depth, 0.0)
            along_x = (tx + ty) % 2 == 0
            inner0, inner1 = g + fw, 1 - g - fw
            n = 18
            pitch = (inner1 - inner0) / n
            for k in range(n):
                c = inner0 + (k + 0.5) * pitch
                if along_x:
                    s.box(bar, x0 + inner0, x0 + inner1, y0 + c - 0.0125, y0 + c + 0.0125, -0.045, -0.0005)
                else:
                    s.box(bar, x0 + c - 0.0125, x0 + c + 0.0125, y0 + inner0, y0 + inner1, -0.045, -0.0005)
            for k in range(1, 4):
                c = inner0 + (inner1 - inner0) * k / 4
                if along_x:
                    s.box(rod, x0 + c - 0.006, x0 + c + 0.006, y0 + inner0, y0 + inner1, -0.03, -0.012)
                else:
                    s.box(rod, x0 + inner0, x0 + inner1, y0 + c - 0.006, y0 + c + 0.006, -0.03, -0.012)
            for bx, by in ((0.024, 0.024), (0.976, 0.024), (0.024, 0.976), (0.976, 0.976)):
                s.hexbolt(bolt, x0 + bx, y0 + by, 0.006)
    return s


def sheet_panels():
    s = Sheet('panels')
    plate = mat('p_plate', 0.5, 0.75, rime=0.5)
    inset = mat('p_inset', 0.62, 0.7, rime=0.2)
    bolt = mat('p_bolt', 0.3, 0.9, rime=0.4)
    tread = mat('p_tread', 0.45, 0.85, rime=0.8)
    slot = mat('p_slot', 0.9, 0.2, grime=0.0)
    seam = 0.006
    s.box(slot, 0, SIZE, 0, SIZE, -0.03, -0.02)
    for tx in range(2):
        for ty in range(2):
            x0, y0 = tx * 1.0 + seam, ty * 1.0 + seam
            x1, y1 = tx * 1.0 + 1 - seam, ty * 1.0 + 1 - seam
            kind = ty * 2 + tx
            if kind == 1:   # inset panel: frame + recessed field
                b = 0.17
                s.box(plate, x0, x1, y0, y0 + b, -0.02, 0.0)
                s.box(plate, x0, x1, y1 - b, y1, -0.02, 0.0)
                s.box(plate, x0, x0 + b, y0 + b, y1 - b, -0.02, 0.0)
                s.box(plate, x1 - b, x1, y0 + b, y1 - b, -0.02, 0.0)
                s.box(inset, x0 + b, x1 - b, y0 + b, y1 - b, -0.02, -0.008)
            else:
                s.box(plate, x0, x1, y0, y1, -0.02, 0.0)
            if kind == 0:   # bolted plain plate
                for k in range(4):
                    t = 0.06 + k * (0.88 / 3)
                    for (bx, by) in ((t, 0.05), (t, 0.95), (0.05, t), (0.95, t)):
                        s.hexbolt(bolt, tx + bx, ty + by, 0.007)
            elif kind == 1:
                for (bx, by) in ((0.09, 0.09), (0.91, 0.09), (0.09, 0.91), (0.91, 0.91)):
                    s.hexbolt(bolt, tx + bx, ty + by, 0.007)
            elif kind == 2:  # diamond tread lozenges
                pitch = 0.05
                for i in range(1, 19):
                    for j in range(1, 19):
                        cx, cy = tx + i * pitch + (pitch / 2 if j % 2 else 0) - 0.0, ty + j * pitch
                        if cx > tx + 0.97:
                            continue
                        b = s.bm(tread)
                        res = bmesh.ops.create_cube(b, size=1.0)
                        bmesh.ops.scale(b, vec=(0.028, 0.008, 0.004), verts=res['verts'])
                        bmesh.ops.rotate(b, cent=(0, 0, 0), matrix=_rot('Z', math.pi / 4 if (i + j) % 2 else -math.pi / 4),
                                         verts=res['verts'])
                        bmesh.ops.translate(b, vec=(cx, cy, 0.002), verts=res['verts'])
            else:            # vent row + stencil plate
                for k in range(6):
                    cx = tx + 0.2 + k * 0.12
                    s.box(slot, cx - 0.035, cx + 0.035, ty + 0.15, ty + 0.17, -0.03, 0.001)
                s.box(inset, tx + 0.25, tx + 0.75, ty + 0.55, ty + 0.8, -0.0, 0.004)
                for (bx, by) in ((0.27, 0.57), (0.73, 0.57), (0.27, 0.78), (0.73, 0.78)):
                    s.hexbolt(bolt, tx + bx, ty + by, 0.009, r=0.007)
    return s


def strip_y(k):
    """Blender y range of strip k (k = 0 at the top of the image / Metal v = 0)."""
    return SIZE - (k + 1) * 0.25, SIZE - k * 0.25


def sheet_rails():
    s = Sheet('rails')
    base = mat('r_base', 0.5, 0.8, rime=0.4)
    rivet = mat('r_rivet', 0.35, 0.9, rime=0.6)
    rib = mat('r_rib', 0.45, 0.85, rime=0.6)
    groove = mat('r_groove', 0.8, 0.5, grime=0.0)
    paint = mat('r_paint', 0.55, 0.15, rime=0.3)
    brushed = mat('r_brushed', 0.32, 0.95, rime=0.3)
    for k in range(8):
        y0, y1 = strip_y(k)
        m = brushed if k == 7 else (paint if k == 5 else base)
        s.box(m, 0, SIZE, y0 + 0.004, y1 - 0.004, -0.02, 0.0)
    # 0 skirt: rivet rows + a groove for the edge strip
    y0, y1 = strip_y(0)
    s.box(groove, 0, SIZE, y0 + 0.11, y0 + 0.14, -0.03, -0.012)
    for i in range(20):
        x = 0.05 + i * 0.1
        s.sphere(rivet, x, y0 + 0.04, 0.0, 0.007, 0.6)
        s.sphere(rivet, x, y1 - 0.04, 0.0, 0.007, 0.6)
    # 1 girder web: stiffener ribs every 0.5 m, flange bands at both edges
    y0, y1 = strip_y(1)
    for i in range(4):
        x = 0.25 + i * 0.5
        s.box(rib, x - 0.012, x + 0.012, y0 + 0.03, y1 - 0.03, -0.01, 0.01)
    s.box(rib, 0, SIZE, y0 + 0.008, y0 + 0.03, -0.01, 0.008)
    s.box(rib, 0, SIZE, y1 - 0.03, y1 - 0.008, -0.01, 0.008)
    # 2 column face: panel seams every 1 m + bolt pairs
    y0, y1 = strip_y(2)
    for x in (0.0, 1.0, 2.0):
        s.box(groove, x - 0.004, x + 0.004, y0 + 0.004, y1 - 0.004, -0.03, -0.006)
        for by in (y0 + 0.06, y1 - 0.06):
            s.hexbolt(rivet, (x + 0.04) % SIZE, by, 0.006, r=0.008)
            s.hexbolt(rivet, (x - 0.04) % SIZE, by, 0.006, r=0.008)
    # 3 rail bar: joint collars every 1 m
    y0, y1 = strip_y(3)
    for x in (0.5, 1.5):
        s.box(rib, x - 0.02, x + 0.02, y0 + 0.01, y1 - 0.01, -0.01, 0.006)
    # 4 tread nosing: grooves along u
    y0, y1 = strip_y(4)
    for j in range(8):
        y = y0 + 0.03 + j * 0.026
        s.box(groove, 0, SIZE, y - 0.005, y + 0.005, -0.03, -0.004)
    # 5 hazard band: raised painted field with a bevelled border
    y0, y1 = strip_y(5)
    s.box(paint, 0, SIZE, y0 + 0.03, y1 - 0.03, -0.01, 0.003)
    # 6 chequer plate: small lozenges
    y0, y1 = strip_y(6)
    for i in range(50):
        for j in range(5):
            cx, cy = 0.02 + i * 0.04 + (0.02 if j % 2 else 0.0), y0 + 0.035 + j * 0.045
            b = s.bm(rib)
            res = bmesh.ops.create_cube(b, size=1.0)
            bmesh.ops.scale(b, vec=(0.022, 0.006, 0.003), verts=res['verts'])
            bmesh.ops.rotate(b, cent=(0, 0, 0), matrix=_rot('Z', math.pi / 4 if (i + j) % 2 else -math.pi / 4), verts=res['verts'])
            bmesh.ops.translate(b, vec=(cx % SIZE, cy, 0.0015), verts=res['verts'])
    return s


def sheet_pipes():
    s = Sheet('pipes')
    base = mat('q_base', 0.45, 0.85, rime=0.4)
    weld = mat('q_weld', 0.6, 0.8, rime=0.5)
    rubber = mat('q_rubber', 0.85, 0.0, rime=0.2)
    dark = mat('q_dark', 0.9, 0.2, grime=0.0)
    bolt = mat('q_bolt', 0.3, 0.9, rime=0.6)
    for k in range(8):
        y0, y1 = strip_y(k)
        s.box(rubber if k in (1, 2, 7) else base, 0, SIZE, y0 + 0.004, y1 - 0.004, -0.02, 0.0)
    # 0 pipe: weld rings every 1 m, a bolted flange at u = 0
    y0, y1 = strip_y(0)
    for x in (0.5, 1.5):
        s.cyl(weld, x, (y0 + y1) / 2, 0.0, 0.009, y1 - y0 - 0.02, axis='y', seg=10)
    s.box(base, -0.03, 0.03, y0 + 0.008, y1 - 0.008, -0.01, 0.01)
    s.box(base, SIZE - 0.03, SIZE + 0.03, y0 + 0.008, y1 - 0.008, -0.01, 0.01)
    for j in range(4):
        for x in (0.0, SIZE):
            s.hexbolt(bolt, x, y0 + 0.04 + j * 0.056, 0.014, r=0.008)
    # 1 corrugated hose: ribs across u every 4 cm
    y0, y1 = strip_y(1)
    for i in range(50):
        s.cyl(rubber, 0.02 + i * 0.04, (y0 + y1) / 2, -0.004, 0.012, y1 - y0 - 0.02, axis='y', seg=12)
    # 2 cable bundle: three round cables along u with clamps every 0.5 m
    y0, y1 = strip_y(2)
    for j in range(3):
        s.cyl(rubber, SIZE / 2, y0 + 0.05 + j * 0.075, -0.012, 0.03, SIZE + 0.1, axis='x', seg=16)
    for i in range(4):
        x = 0.25 + i * 0.5
        s.box(base, x - 0.015, x + 0.015, y0 + 0.01, y1 - 0.01, -0.02, 0.012)
    # 3 lattice angle: a step (flange) and lightening holes every 10 cm
    y0, y1 = strip_y(3)
    s.box(base, 0, SIZE, y0 + 0.004, y0 + 0.1, -0.02, 0.008)
    for i in range(20):
        s.cyl(dark, 0.05 + i * 0.1, y0 + 0.17, -0.01, 0.018, 0.03, seg=12)
    # 4 vent slots: two rows of rounded slots
    y0, y1 = strip_y(4)
    for i in range(32):
        for j in range(2):
            x = 0.03 + i * 0.0625
            s.box(dark, x - 0.02, x + 0.02, y0 + 0.06 + j * 0.11 - 0.012, y0 + 0.06 + j * 0.11 + 0.012, -0.04, 0.001)
    # 5 housing fins along u
    y0, y1 = strip_y(5)
    for j in range(10):
        y = y0 + 0.025 + j * 0.022
        s.box(base, 0, SIZE, y - 0.004, y + 0.004, -0.01, 0.01)
    # 6 bolted flange: raised band with bolts every 10 cm
    y0, y1 = strip_y(6)
    s.box(base, 0, SIZE, y0 + 0.06, y1 - 0.06, -0.01, 0.006)
    for i in range(20):
        s.hexbolt(bolt, 0.05 + i * 0.1, (y0 + y1) / 2, 0.013, r=0.009)
    return s


SHEETS = [sheet_gratings, sheet_panels, sheet_rails, sheet_pipes]


# ---------------------------------------------------------------- bake
def bake_sheet(builder, res):
    sc = reset()
    MATS.clear()
    w = bpy.data.worlds.new('w')
    sc.world = w
    w.use_nodes = True
    w.light_settings.distance = 0.06
    s = builder()
    # a dark floor under every sheet: every bake ray hits something (gaps, strip borders)
    s.box(mat('floor', 0.95, 0.0, grime=0.0), -0.05, SIZE + 0.05, -0.05, SIZE + 0.05, -0.1, -0.09)
    hp = s.build()
    ntri = 0
    for o in hp:
        o.data.calc_loop_triangles()
        ntri += len(o.data.loop_triangles)
    # low poly: the 2 × 2 m plane, uv 0..1
    me = bpy.data.meshes.new('lp')
    me.from_pydata([(0, 0, 0), (SIZE, 0, 0), (SIZE, SIZE, 0), (0, SIZE, 0)], [], [(0, 1, 2, 3)])
    uvl = me.uv_layers.new(name='uv')
    uvl.data.foreach_set('uv', [0, 0, 1, 0, 1, 1, 0, 1])
    lp = bpy.data.objects.new('lp', me)
    sc.collection.objects.link(lp)
    lm = bpy.data.materials.new('lp_mat')
    lm.use_nodes = True
    me.materials.append(lm)
    N = lm.node_tree.nodes
    out = {}
    for kind in ('NORMAL', 'AO', 'ROUGHNESS', 'EMIT'):
        img = bpy.data.images.new(f'{s.name}_{kind}', res, res, alpha=False, float_buffer=True)
        img.colorspace_settings.name = 'Non-Color'
        for n in list(N):
            if n.type == 'TEX_IMAGE':
                N.remove(n)
        tn = N.new('ShaderNodeTexImage')
        tn.image = img
        N.active = tn
        for o in bpy.context.view_layer.objects:
            o.select_set(False)
        for o in hp:
            o.select_set(True)
        lp.select_set(True)
        bpy.context.view_layer.objects.active = lp
        emission(kind == 'EMIT')
        sc.cycles.samples = {'NORMAL': 8, 'AO': 64, 'ROUGHNESS': 16, 'EMIT': 4}[kind]
        t = time.time()
        kw = dict(normal_space='TANGENT') if kind == 'NORMAL' else {}
        bpy.ops.object.bake(type=kind, use_selected_to_active=True, cage_extrusion=0.02, max_ray_distance=0.12, margin=0,
                            use_clear=True, **kw)
        a = np.empty(res * res * 4, np.float32)
        img.pixels.foreach_get(a)
        out[kind] = a.reshape(res, res, 4)[::-1].copy()      # Metal row order
        log(f'{s.name}: {kind} {res}² in {time.time() - t:.1f}s')
    log(f'{s.name}: high poly {ntri} triangles')
    n = out['NORMAL'][..., :3] * 2.0 - 1.0
    n /= np.maximum(np.linalg.norm(n, axis=2, keepdims=True), 1e-6)
    orm = np.zeros((res, res, 4), np.float32)
    orm[..., 0] = np.clip(out['AO'][..., 0], 0, 1)
    orm[..., 1] = np.clip(out['ROUGHNESS'][..., 0], 0.05, 1)
    orm[..., 2] = np.clip(out['EMIT'][..., 0], 0, 1)
    orm[..., 3] = np.clip(out['EMIT'][..., 1], 0, 1)
    return n.astype(np.float32), orm, ntri


def preview(normals, orms, path):
    from PIL import Image
    tiles = []
    for n, o in zip(normals, orms):
        a = Image.fromarray(np.clip((n * 0.5 + 0.5) * 255, 0, 255).astype(np.uint8)).resize((256, 256), Image.LANCZOS)
        b = Image.fromarray(np.clip(o[..., :3] * 255, 0, 255).astype(np.uint8)).resize((256, 256), Image.LANCZOS)
        c = Image.fromarray(np.clip(o[..., 3] * 255, 0, 255).astype(np.uint8)).convert('RGB').resize((256, 256), Image.LANCZOS)
        tiles.append((a, b, c))
    sheet = Image.new('RGB', (3 * 260, len(tiles) * 260), (14, 16, 20))
    for i, row in enumerate(tiles):
        for j, t in enumerate(row):
            sheet.paste(t, (j * 260, i * 260))
    sheet.save(path)


def main():
    args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else sys.argv[1:]
    out = os.path.abspath(args[0])
    os.makedirs(out, exist_ok=True)
    res = int(args[args.index('--res') + 1]) if '--res' in args else 1024
    prev = os.path.abspath(args[args.index('--previews') + 1]) if '--previews' in args else None
    normals, orms, tris = [], [], []
    for b in SHEETS:
        n, o, t = bake_sheet(b, res)
        normals.append(n)
        orms.append(o)
        tris.append(t)
    lv = iht.encode_layers(normals, 2, 'normal')
    sz = iht.write(os.path.join(out, 'trim_normal.iht'), 2, res, res, lv, flags=iht.FL_NORMAL)
    log(f'wrote trim_normal.iht: {sz} bytes (ASTC 5x5, {len(normals)} layers, {len(lv[0])} mips)')
    lv = iht.encode_layers(orms, 3, 'data', toksvig_layers=normals)
    sz = iht.write(os.path.join(out, 'trim_orm.iht'), 3, res, res, lv)
    log(f'wrote trim_orm.iht: {sz} bytes (ASTC 6x6, {len(orms)} layers)')
    if prev:
        os.makedirs(prev, exist_ok=True)
        preview(normals, orms, os.path.join(prev, 'trims.png'))
    import json
    with open(os.path.join(out, 'trims_build.json'), 'w') as f:
        json.dump(dict(res=res, layers=kitgeo.LAYER_NAMES, high_poly_triangles=tris,
                       orm_mean=[[float(x) for x in o.reshape(-1, 4).mean(0)] for o in orms]), f, indent=1, sort_keys=True)
    log('done')


main()
