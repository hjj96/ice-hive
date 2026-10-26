"""Headless Blender (pip bpy 5.2.2) build of one hive creature: model -> rig -> keyframed clips -> bake -> IHV1.

  venv/bin/python creatures/build.py <runner|spitter|brute|boomer> OUT_DIR WORK_DIR
  venv/bin/python creatures/build.py <name> OUT_DIR WORK_DIR --from-blend WORK_DIR/<name>_src.blend

Writes OUT_DIR/<name>.ihv (the RIGID ship file: three LODs, bone texture, glow table, sockets — no VAT; Swarm/
IHVLoader.swift reads it), WORK_DIR/<name>_src.blend (the editable source: rig, three LOD meshes, one action with
every clip, the clip table in scene['ihv_clips'], glow drives as animated rig props), WORK_DIR/<name>_build.json (the
full report) and WORK_DIR/<name>_gates.json ({"gates": {...}} for gates.py: rigid path vs the armature-deformed mesh,
planted-foot drift per locomotion clip, IK reach error per clip).
The bake only reads the Blender scene (evaluated depsgraph), so a hand-edited .blend re-exports the same way.
Deterministic: fixed seeds, the per-vertex AO is ray cast on Blender's BVH of the rest mesh (no Cycles).
"""
import importlib
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
from mathutils import Matrix, Vector  # noqa: E402
from mathutils.bvhtree import BVHTree  # noqa: E402

import ihv  # noqa: E402
from geo import hex2rgb  # noqa: E402
from insect import F_EYE, F_GLAND, F_SOCKET  # noqa: E402

T0 = time.time()
LOG = []


def log(*a):
    s = f'[{time.time() - T0:6.2f}s] ' + ' '.join(str(x) for x in a)
    print(s, flush=True)
    LOG.append(s)


C = np.array([[-1, 0, 0], [0, 0, 1], [0, 1, 0]], dtype=np.float64)   # Blender -> game: (-X, Z, Y)


# ================================================================== build
def make_rig(D):
    arm = bpy.data.armatures.new(f'{D.NAME}_rig')
    obj = bpy.data.objects.new(f'{D.NAME}_rig', arm)
    bpy.context.scene.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.mode_set(mode='EDIT')
    for name, parent, M, L in D.skeleton():
        eb = arm.edit_bones.new(name)
        eb.head = (0, 0, 0)
        eb.tail = (0, L, 0)
        eb.matrix = Matrix(M.tolist())
        if parent:
            eb.parent = arm.edit_bones[parent]
            eb.use_connect = False
    bpy.ops.object.mode_set(mode='OBJECT')
    err = 0.0
    for name, parent, M, L in D.skeleton():
        err = max(err, float(np.abs(np.array(arm.bones[name].matrix_local) - M).max()))
    log(f'rig: {len(arm.bones)} bones, max |rest - design| = {err:.2e}')
    for pb in obj.pose.bones:
        pb.rotation_mode = 'QUATERNION'
    for k in ('glow_gland', 'glow_pulse', 'glow_wave', 'glow_eye'):
        obj[k] = 1.0 if k in ('glow_gland', 'glow_eye') else 0.0
    return obj


def socket_list(D):
    """every LOD carries the same sockets (vertex points after the drawn vertices): LOD0's gland centres (seated on the
    most detailed carapace) + the creature's extra sockets (mouth, core, sac, ...). (name, bone, pos, flags)"""
    out = []
    for p in D.build_parts(0):
        for g in p.gland_centers:
            c, fl = (g if isinstance(g, tuple) else (g, 1))
            out.append((p.name.replace('gland.', 'g.'), p.bone, np.asarray(c, float), int(fl)))
    for nm, bone, c, fl in D.EXTRA_SOCKETS:
        out.append((nm, bone, np.asarray(c, float), int(fl)))
    return out


def make_mesh(D, rig, lod, sockets):
    parts = D.build_parts(lod)
    V, F, fpart = [], [], []
    vb, vcol, vglow, vrough, vflag = [], [], [], [], []
    bones = [b.name for b in rig.data.bones]
    off = 0
    for pi, p in enumerate(parts):
        n = len(p.V)
        V.append(p.V)
        F.extend(tuple(i + off for i in f) for f in p.F)
        fpart.extend([pi] * len(p.F))
        vb += [bones.index(p.bone)] * n
        col = p.vcolor if p.vcolor is not None else np.tile(hex2rgb(p.color) if isinstance(p.color, int) else p.color, (n, 1))
        vcol.append(col)
        vglow += [p.glow] * n
        vrough += [p.rough] * n
        vflag += [p.flags] * n
        off += n
    V = np.concatenate(V)
    vcol = np.concatenate(vcol)
    nface_v = len(V)
    S = np.array([s[2] for s in sockets])
    V = np.concatenate([V, S])
    vb += [bones.index(s[1]) for s in sockets]
    vcol = np.concatenate([vcol, np.ones((len(S), 3))])
    vglow += [0.0] * len(S)
    vrough += [0.5] * len(S)
    vflag += [F_SOCKET | (F_GLAND if s[3] & 1 else 0) for s in sockets]

    me = bpy.data.meshes.new(f'{D.NAME}_lod{lod}')
    me.from_pydata(V.tolist(), [], F)
    me.update()
    nP = len(me.polygons)
    # per-part hard edges: sharp where the dihedral angle exceeds the part's threshold
    pn = np.zeros(nP * 3); me.polygons.foreach_get('normal', pn); pn = pn.reshape(-1, 3)
    lt = np.zeros(nP, dtype=np.int32); me.polygons.foreach_get('loop_total', lt)
    le = np.zeros(len(me.loops), dtype=np.int32); me.loops.foreach_get('edge_index', le)
    lp = np.repeat(np.arange(nP), lt)
    edge_faces = {}
    for l, e in enumerate(le):
        edge_faces.setdefault(int(e), []).append(int(lp[l]))
    sharp = np.zeros(len(me.edges), dtype=bool)
    fpart = np.array(fpart)
    for e, fs in edge_faces.items():
        if len(fs) != 2:
            sharp[e] = True
            continue
        a, b = fs
        ang = math.degrees(math.acos(max(-1.0, min(1.0, float(np.dot(pn[a], pn[b]))))))
        if ang > parts[fpart[a]].sharp_deg:
            sharp[e] = True

    def battr(nm, dom):
        return me.attributes.get(nm) or me.attributes.new(nm, 'BOOLEAN', dom)
    battr('sharp_edge', 'EDGE').data.foreach_set('value', sharp)
    battr('sharp_face', 'FACE').data.foreach_set('value', np.array([not parts[i].smooth for i in fpart]))
    me.attributes.new('srgb', 'FLOAT_COLOR', 'POINT').data.foreach_set('color', np.concatenate([vcol, np.ones((len(V), 1))], 1).ravel())
    for nm, arr, typ in (('glow', vglow, 'FLOAT'), ('rough', vrough, 'FLOAT'), ('flags', vflag, 'INT'), ('bone_ix', vb, 'INT')):
        me.attributes.new(nm, typ, 'POINT').data.foreach_set('value', np.array(arr))
    # gland pulse phase (stable per gland part name, the same in every LOD)
    gph = np.zeros(len(V))
    o = 0
    for p in parts:
        if p.flags & F_GLAND:
            h = sum(ord(ch) * (k + 1) for k, ch in enumerate(p.name))
            gph[o:o + len(p.V)] = (h * 0.618034) % 1.0
        o += len(p.V)
    me.attributes.new('gphase', 'FLOAT', 'POINT').data.foreach_set('value', gph)
    me.attributes.new('ao', 'FLOAT', 'POINT').data.foreach_set('value', bake_ao(me, nface_v))
    obj = bpy.data.objects.new(f'{D.NAME}_lod{lod}', me)
    bpy.context.scene.collection.objects.link(obj)
    for b in bones:
        obj.vertex_groups.new(name=b)
    vb = np.array(vb)
    for bi, b in enumerate(bones):
        ids = np.nonzero(vb == bi)[0].tolist()
        if ids:
            obj.vertex_groups[b].add(ids, 1.0, 'REPLACE')
    obj.parent = rig
    obj['ihv_sockets'] = json.dumps([(s[0], s[1], s[3]) for s in sockets])
    obj['ihv_nface_v'] = int(nface_v)
    mod = obj.modifiers.new('rig', 'ARMATURE')
    mod.object = rig
    me.calc_loop_triangles()
    nt = len(me.loop_triangles)
    log(f'LOD{lod}: {len(parts)} parts, {len(me.vertices)} verts ({len(S)} socket points), {nt} tris, {int(sharp.sum())} hard edges')
    assert nt <= ihv.LOD_TRIS[lod], f'LOD{lod} {nt} triangles > budget {ihv.LOD_TRIS[lod]}'
    return obj, [(s[0], s[1], s[3]) for s in sockets], nface_v


def bake_ao(me, nface_v, rays=40, maxd=0.32):
    """Per-vertex ambient occlusion by ray casting the rest mesh (Blender's BVH)."""
    co = np.zeros(len(me.vertices) * 3); me.vertices.foreach_get('co', co); co = co.reshape(-1, 3)
    vn = np.zeros(len(me.vertices) * 3); me.vertices.foreach_get('normal', vn); vn = vn.reshape(-1, 3)
    bvh = BVHTree.FromPolygons([tuple(v) for v in co], [tuple(p.vertices) for p in me.polygons], epsilon=0.0)
    rng = np.random.default_rng(7)
    u1, u2 = rng.random(rays), rng.random(rays)
    r, phi = np.sqrt(u1), 2 * math.pi * u2
    local = np.stack([r * np.cos(phi), r * np.sin(phi), np.sqrt(1 - u1)], 1)    # cosine-weighted hemisphere
    ao = np.ones(len(co))
    for i in range(nface_v):
        n = vn[i]
        t = np.cross(n, [0, 0, 1] if abs(n[2]) < 0.9 else [1, 0, 0]); t /= np.linalg.norm(t)
        b = np.cross(n, t)
        dirs = local[:, 0:1] * t + local[:, 1:2] * b + local[:, 2:3] * n
        o = Vector(co[i] + n * 0.003)
        occ = 0.0
        for d in dirs:
            hit = bvh.ray_cast(o, Vector(d), maxd)
            if hit[0] is not None:
                occ += 1.0 - (hit[3] / maxd) ** 0.7
        ao[i] = 1.0 - occ / rays
    return np.clip(ao * 1.08, 0.08, 1.0)


def key_clips(D, rig):
    """Evaluate the procedural clips, convert to pose-bone basis transforms, insert keyframes (one action)."""
    arm = rig.data
    rest = {b.name: np.array(b.matrix_local) for b in arm.bones}
    parent = {b.name: (b.parent.name if b.parent else None) for b in arm.bones}
    order = [b[0] for b in D.skeleton()]
    rest_rel = {b: (np.linalg.inv(rest[parent[b]]) @ rest[b] if parent[b] else rest[b]) for b in order}
    legs = {lg.name: lg for lg in D.LEGS}
    rest_frames = {lg.name: lg.frames(lg.rest[0]) for lg in D.LEGS}
    clips, row = [], 0
    max_ik_err = {}
    prevq = {}
    lifts = []
    inv_rest = {b: np.linalg.inv(rest[b]) for b in order}
    probes = {}
    for p in D.build_parts(0):                 # floor-clamp probes: every LOD0 vertex, homogeneous, per bone
        probes.setdefault(p.bone, []).append(np.c_[p.V, np.ones(len(p.V))])
    probes = {bn: np.concatenate(v) for bn, v in probes.items()}
    for name, n, loop, stride, event, notes in D.CLIPS:
        clips.append(dict(name=name, first=row, frames=n, loop=loop, stride=stride, event=event if not loop else None, notes=notes))
        for f in range(n):
            st = D.clip_state(name, f, n)
            pose = {}
            for b in order:
                if '.femur' in b or '.tibia' in b or '.tarsus' in b:
                    continue
                Bm = st.basis.get(b, np.eye(4))
                pose[b] = (pose[parent[b]] @ rest_rel[b] if parent[b] else rest_rel[b]) @ Bm
            Bt = pose['thorax'] @ np.linalg.inv(rest['thorax'])
            Binv = np.linalg.inv(Bt)
            for ln, lg in legs.items():
                p, err = D.leg_body_targets(lg, st.feet[ln], Binv) if hasattr(D, 'leg_body_targets') else _leg(lg, st.feet[ln], Binv)
                max_ik_err[name] = max(max_ik_err.get(name, 0.0), err)
                for k, seg in enumerate(('femur', 'tibia', 'tarsus')):
                    bn = f'{ln}.{seg}'
                    pose[bn] = Bt @ lg.frames(p)[k] @ np.linalg.inv(rest_frames[ln][k]) @ rest[bn]
            if name in D.GROUND_CLAMP:
                zb = {bn: float((pose[bn] @ inv_rest[bn] @ pts.T)[2].min()) for bn, pts in probes.items()}
                low = min(zb, key=zb.get)
                lift = max(0.0, 0.003 - zb[low])
                if lift > 0:
                    Tl = np.eye(4); Tl[2, 3] = lift
                    pose = {bn: Tl @ M for bn, M in pose.items()}
                    lifts.append((name, f, lift, low))
            for b in order:
                basis = np.linalg.inv(rest_rel[b]) @ (np.linalg.inv(pose[parent[b]]) @ pose[b] if parent[b] else pose[b])
                loc, q, sc = Matrix(basis.tolist()).decompose()
                if b in prevq and prevq[b].dot(q) < 0:
                    q.negate()
                prevq[b] = q
                pb = rig.pose.bones[b]
                pb.location = loc
                pb.rotation_quaternion = q
                pb.scale = sc
                pb.keyframe_insert('location', frame=row)
                pb.keyframe_insert('rotation_quaternion', frame=row)
                pb.keyframe_insert('scale', frame=row)
            for k, v in st.glow.items():
                rig['glow_' + k] = float(v)
                rig.keyframe_insert(f'["glow_{k}"]', frame=row)
            row += 1
    sc = bpy.context.scene
    sc.frame_start, sc.frame_end = 0, row - 1
    sc.render.fps = D.FPS
    for c in clips:
        sc.timeline_markers.new(c['name'], frame=c['first'])
    sc['ihv_clips'] = json.dumps(clips)
    rig.animation_data.action.name = f'{D.NAME}_clips'
    big = [(n, f, l, b) for n, f, l, b in lifts if l > 0.01]
    if big:
        log('floor clamp lifted the root in ' + ', '.join(f'{n}#{f} {l * 100:.1f}cm ({b})' for n, f, l, b in big[:60])
            + (' …' if len(big) > 60 else '') + f' ({len(lifts)} frames total)')
    log(f'keyed {len(clips)} clips, {row} frames, {len(order)} bones; IK reach error (m, max per clip): '
        + ', '.join(f'{k} {v:.3f}' for k, v in max_ik_err.items()))
    return clips, row, max_ik_err


def _leg(lg, cmd, Binv):
    import insect
    return insect.leg_body_targets(lg, cmd, Binv)


# ================================================================== bake + export
def rest_layout(obj, nface_v):
    """Export vertices of one LOD from the rest mesh: split per (vertex, corner normal); sockets appended."""
    me = obj.data
    me.calc_loop_triangles()
    nl = len(me.loops)
    lv = np.zeros(nl, dtype=np.int64); me.loops.foreach_get('vertex_index', lv)
    cn = np.zeros(nl * 3); me.corner_normals.foreach_get('vector', cn); cn = cn.reshape(-1, 3)
    key = {}
    rep_loop, rep_vert = [], []
    loop_to_e = np.zeros(nl, dtype=np.int64)
    for l in range(nl):
        k = (int(lv[l]), tuple(np.round(cn[l] * 4096).astype(int)))
        e = key.get(k)
        if e is None:
            e = len(rep_loop)
            key[k] = e
            rep_loop.append(l)
            rep_vert.append(int(lv[l]))
        loop_to_e[l] = e
    ndraw = len(rep_loop)
    socket_verts = list(range(nface_v, len(me.vertices)))
    rep_vert += socket_verts
    vn = np.zeros(len(me.vertices) * 3); me.vertices.foreach_get('normal', vn); vn = vn.reshape(-1, 3)
    rest_nrm = np.concatenate([cn[rep_loop], vn[socket_verts]]) if socket_verts else cn[rep_loop]
    tl = np.zeros(len(me.loop_triangles) * 3, dtype=np.int64); me.loop_triangles.foreach_get('loops', tl)
    tris = loop_to_e[tl]
    return dict(rep_loop=np.array(rep_loop), rep_vert=np.array(rep_vert), ndraw=ndraw, tris=tris, nl=nl,
                socket_verts=socket_verts, rest_nrm=rest_nrm)


def attr(me, name, comps=1, dtype=np.float64, field='value'):
    a = me.attributes[name]
    out = np.zeros(len(a.data) * comps, dtype=dtype)
    a.data.foreach_get(field, out)
    return out.reshape(-1, comps) if comps > 1 else out


def bake_and_export(D, rig, lods, out_dir, work_dir, ik_err):
    sc = bpy.context.scene
    clips = json.loads(sc['ihv_clips'])
    frames = sc.frame_end - sc.frame_start + 1
    bones = [b.name for b in rig.data.bones]
    bone_par = [(b.name, bones.index(b.parent.name) if b.parent else -1) for b in rig.data.bones]
    rest = np.array([np.array(b.matrix_local) for b in rig.data.bones])
    lay = [rest_layout(o, nv) for o, _, nv in lods]
    nE = [len(L['rep_vert']) for L in lay]
    vat_p = [np.zeros((frames, n, 4), np.float32) for n in nE]
    vat_n = [np.zeros((frames, n, 4), np.float32) for n in nE]
    bone_tex = np.zeros((frames, len(bones), 3, 4), np.float32)
    glow_tab = np.zeros((frames, 4), np.float32)
    gph = [attr(o.data, 'gphase') for o, _, _ in lods]
    flg = [attr(o.data, 'flags', dtype=np.int32) for o, _, _ in lods]
    t0 = time.time()
    for fr in range(frames):
        sc.frame_set(sc.frame_start + fr)
        dg = bpy.context.evaluated_depsgraph_get()
        rig_e = rig.evaluated_get(dg)
        g = {k: float(rig_e[f'glow_{k}']) for k in ('gland', 'pulse', 'wave', 'eye')}
        glow_tab[fr] = (g['gland'], g['pulse'], g['wave'], g['eye'])
        for bi, b in enumerate(bones):
            Dm = np.array(rig_e.pose.bones[b].matrix) @ np.linalg.inv(rest[bi])
            G = np.eye(4); G[:3, :3] = C @ Dm[:3, :3] @ C; G[:3, 3] = C @ Dm[:3, 3]
            bone_tex[fr, bi] = G[:3, :4]
        for li, (obj, _, _) in enumerate(lods):
            ev = obj.evaluated_get(dg)
            me = ev.to_mesh()
            co = np.zeros(len(me.vertices) * 3); me.vertices.foreach_get('co', co); co = co.reshape(-1, 3)
            cn = np.zeros(len(me.loops) * 3); me.corner_normals.foreach_get('vector', cn); cn = cn.reshape(-1, 3)
            vn = np.zeros(len(me.vertices) * 3); me.vertices.foreach_get('normal', vn); vn = vn.reshape(-1, 3)
            L = lay[li]
            P = co[L['rep_vert']]
            Nn = np.concatenate([cn[L['rep_loop']], vn[L['socket_verts']]])
            mult = np.ones(len(P))
            fl = flg[li][L['rep_vert']]
            ph = gph[li][L['rep_vert']]
            gl = (fl & F_GLAND) > 0
            mult[gl] = g['gland'] + g['pulse'] * np.sin(2 * math.pi * (g['wave'] + ph[gl]))
            mult[(fl & F_EYE) > 0] = g['eye']
            vat_p[li][fr, :, :3] = P @ C.T
            vat_p[li][fr, :, 3] = mult
            vat_n[li][fr, :, :3] = Nn @ C.T
            ev.to_mesh_clear()
    log(f'baked {frames} frames x {len(lods)} LODs in {time.time() - t0:.2f}s')

    out_lods = []
    for li, (obj, sockets, nv) in enumerate(lods):
        me = obj.data
        L = lay[li]
        rv = L['rep_vert']
        srgb = attr(me, 'srgb', 4, field='color')[rv, :3]
        ao = attr(me, 'ao')[rv]
        glow = attr(me, 'glow')[rv]
        rough = attr(me, 'rough')[rv]
        bix = attr(me, 'bone_ix', dtype=np.int32)[rv]
        fl = attr(me, 'flags', dtype=np.int32)[rv]
        co = np.zeros(len(me.vertices) * 3); me.vertices.foreach_get('co', co); co = co.reshape(-1, 3)[rv] @ C.T
        V = np.zeros(len(rv), ihv.VERTEX_DTYPE)
        q = lambda x: np.clip(np.round(np.asarray(x) * 255), 0, 255).astype(np.uint8)  # noqa: E731
        V['albedo_ao'] = np.concatenate([q(srgb), q(ao)[:, None]], 1)
        V['material'] = np.stack([q(glow), q(rough), bix.astype(np.uint8), fl.astype(np.uint8)], 1)
        V['rest'] = np.concatenate([co, gph[li][rv][:, None]], 1).astype('<f2')
        V['nrm'][:, :3] = ihv.snorm8(L['rest_nrm'] @ C.T)
        out_lods.append(dict(vertices=V, indices=L['tris'], vat_pos=vat_p[li], vat_nrm=vat_n[li], draw_vertex_count=L['ndraw'],
                             switch_px=D.SWITCH_PX[li]))
    sock = []
    for si, (nm, bone, sflags) in enumerate(lods[0][1]):
        vids = [lay[li]['ndraw'] + si for li in range(len(lods))]
        sock.append((nm, vids, bones.index(bone), sflags))
    path = os.path.join(out_dir, f'{D.NAME}.ihv')
    size = ihv.write(path, float(D.FPS), clips, out_lods, bone_par, sock, bone_tex, glow_tab, with_vat=False)
    log(f'wrote {path}: {size} bytes (rigid ship file: 3 LODs, bone texture + glow table, no VAT)')

    # ---- validation from the written file: the rigid path (bone texture × rest) against the armature-deformed meshes
    DR = ihv.read(path)
    rep = dict(name=D.NAME, file=os.path.basename(path), bytes=size, frames=frames, bones=len(bones), clips=DR['clips'],
               lods=[], sockets=len(DR['sockets']), log=LOG)
    worst = 0.0
    for li, Lr in enumerate(DR['lods']):
        rp, rn, rg = 0.0, 0.0, 0.0
        nd = Lr['draw_vertex_count']
        for row in range(frames):
            P_, N_, G_ = ihv.rigid_row(DR, Lr, row)
            rp = max(rp, float(np.abs(P_ - vat_p[li][row, :, :3]).max()))
            ref = vat_n[li][row, :nd, :3]
            cosang = np.sum(N_[:nd] * ref, 1) / np.maximum(np.linalg.norm(ref, axis=1), 1e-9)
            rn = max(rn, float(np.degrees(np.arccos(np.clip(cosang.min(), -1, 1)))))
            rg = max(rg, float(np.abs(G_ - vat_p[li][row, :, 3]).max()))
        worst = max(worst, rp)
        rep['lods'].append(dict(vertices=Lr['vertex_count'], draw_vertices=nd, triangles=Lr['triangle_count'],
                                rigid_vs_vat=dict(pos_m=rp, normal_deg=rn, glow=rg)))
        log(f'LOD{li}: {Lr["triangle_count"]} tris, {nd} verts; rigid file vs deformed mesh: pos {rp * 1000:.2f} mm, '
            f'normal {rn:.2f} deg, glow {rg:.4f}')
    drift = foot_slide(D, DR, vat_p[0])
    rep['foot_slide'] = drift
    json.dump(rep, open(os.path.join(work_dir, f'{D.NAME}_build.json'), 'w'), indent=1, default=float)
    gates = dict(gates=dict(rigid_vs_vat_m=worst, foot_drift_m=drift, ik_err_m={k: float(v) for k, v in ik_err.items()}),
                 bytes=size, triangles=[L['triangle_count'] for L in DR['lods']], frames=frames, bones=len(bones),
                 clips=[c['name'] for c in DR['clips']])
    json.dump(gates, open(os.path.join(work_dir, f'{D.NAME}_gates.json'), 'w'), indent=1, sort_keys=True, default=float)
    return DR


def foot_slide(D, DR, vatp0):
    """Lowest rest vertex of each tarsus = contact point. Two consecutive loops are laid out in world space
    (root motion = stride per loop); every contiguous run of frames with the claw within 1.2 cm of the ground is
    one stance, and a planted foot should not move during it: report the worst horizontal drift (m)."""
    L = DR['lods'][0]
    bones = [b[0] for b in DR['bones']]
    bix = L['vertices']['material'][:, 2].astype(int)
    out = {}
    for c in DR['clips']:
        if not c['locomotion']:
            continue
        worst, n = 0.0, c['frames']
        for lg in D.LEGS:
            ids = np.nonzero(bix == bones.index(f'{lg.name}.tarsus'))[0]
            ids = ids[ids < L['draw_vertex_count']]
            tip = ids[np.argmin(L['vertices']['rest'][ids, 1].astype(float))]
            track = []
            for f in range(2 * n):
                p = vatp0[c['first'] + f % n, tip, :3].astype(np.float64).copy()
                p[2] += c['stride'] * f / n
                track.append(p)
            track = np.array(track)
            planted = track[:, 1] < 0.012
            f = 0
            while f < 2 * n:
                if planted[f]:
                    g = f
                    while g < 2 * n and planted[g]:
                        g += 1
                    if f > 0 and g < 2 * n and g - f >= 2:
                        seg = track[f:g][:, [0, 2]]
                        worst = max(worst, float(np.linalg.norm(seg - seg[0], axis=1).max()))
                    f = g
                else:
                    f += 1
        out[c['name']] = worst
    log('foot drift while planted (m, worst foot): ' + ', '.join(f'{k} {v:.4f}' for k, v in out.items()))
    return out


def main():
    name = sys.argv[1]
    out_dir = os.path.abspath(sys.argv[2])
    work_dir = os.path.abspath(sys.argv[3])
    os.makedirs(out_dir, exist_ok=True)
    os.makedirs(work_dir, exist_ok=True)
    D = importlib.import_module(name)
    if '--from-blend' in sys.argv:
        src = os.path.abspath(sys.argv[sys.argv.index('--from-blend') + 1])
        bpy.ops.wm.open_mainfile(filepath=src)
        rig = bpy.data.objects[f'{D.NAME}_rig']
        lods = []
        for li in range(3):
            o = bpy.data.objects[f'{D.NAME}_lod{li}']
            lods.append((o, [tuple(x) for x in json.loads(o['ihv_sockets'])], int(o['ihv_nface_v'])))
        log(f'opened {src}: {len(rig.data.bones)} bones, {bpy.context.scene.frame_end + 1} frames')
        bake_and_export(D, rig, lods, out_dir, work_dir, {})
        log('done')
        return
    bpy.ops.wm.read_factory_settings(use_empty=True)
    rig = make_rig(D)
    sockets = socket_list(D)
    lods = [make_mesh(D, rig, li, sockets) for li in range(3)]
    log(f'meshes + AO built ({len(sockets)} sockets)')
    _, _, ik_err = key_clips(D, rig)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(work_dir, f'{D.NAME}_src.blend'))
    log(f'saved {D.NAME}_src.blend')
    bake_and_export(D, rig, lods, out_dir, work_dir, ik_err)
    log('done')


if __name__ == '__main__':
    main()
