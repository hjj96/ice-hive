"""IHV1 — «Ледяной Улей» animated mesh container (Metal-friendly). Writer + reader (numpy only).

Version 2 of the format (this file) adds, over version 1 (the runner proof: 2 LODs, VAT + rigid bone texture):
  * up to 3 LODs (LOD2 ≤ 150 triangles for the far swarm) and 48-byte socket records with a vertex id per LOD;
  * SKINNED meshes (marines, flags bit2): a 32-byte vertex with 4 bone indices / weights, uv and a tangent, a bone
    table with each bone's rest transform, and CLIP TRACKS (flags bit3): bone-local rotation + translation per frame,
    which the app blends on the CPU (WP4) into a skinning palette.
The reader reads version 1 and version 2 files; the writer writes version 2 (version=1 still writes the old layout
for a rigid / VAT creature without LOD2, byte-identical to the proof pipeline).

One file per creature / character. Everything little-endian, every section on a 256-byte boundary, so the whole file
can back ONE MTLBuffer and each texture section can become a texture with buffer.makeTexture(descriptor:offset:
bytesPerRow:) (offsets / row pitches are 256-aligned).

COORDINATES — game space: metres, y up, nose +z, origin on the ground under the body; Blender → game = (-X, Z, Y)
(det +1: winding unchanged, counter-clockwise front faces like IHM1 / three.js).

HEADER (128 bytes)
  0  char[4] "IHV1"   4  u32 version (1 | 2)   8  u32 fileBytes   12 u32 flags
                        flags: bit0 bone texture (rigid path) · bit1 VAT · bit2 skinned (32-byte vertices, bone table
                               with rest transforms) · bit3 clip tracks (skinned animation)
  16 f32 fps (all clips)      20 u32 frameCount (rows of every per-frame section; clips concatenated)
  24 u32 clipCount            28 u32 lodCount (1…3)        32 u32 boneCount          36 u32 socketCount
  40 u32 clipTableOffset      44 u32 lodTableOffset        48 u32 socketTableOffset  52 u32 boneTableOffset
  56 u32 boneTexOffset (0 = none)        60 u32 boneTexRowBytes
  64 f32 boundsMin[3]         76 f32 boundsMax[3]   (all frames, all LODs, model space — culling)
  88 f32 restRadius           92 u32 boneTexWidth (texels = boneCount × 3)
  96 u32 glowTableOffset (0 = none)
  v2: 100 u32 trackOffset (0 = none)     104 u32 trackRowBytes (boneCount × 16 rounded up to 256)
      108 u32 vertexKind (0 rigid 20 B, 1 skinned 32 B)                             112..127 reserved 0

CLIP RECORD (48 bytes): char[16] name · u32 firstFrame · u32 frameCount · f32 fps · u32 flags (bit0 loop · bit1
  one-shot holding its last frame · bit2 locomotion: phase from distance) · f32 stride (m per loop at scale 1) ·
  u32 eventFrame (0xFFFFFFFF none) · f32 duration (loops frameCount/fps, one-shots (frameCount-1)/fps) · u32 0
  Sampling: loop      p = fract(t*fps/frameCount)*frameCount, rows first+floor(p), first+(floor(p)+1)%frameCount
            one-shot  p = min(t*fps, frameCount-1),          rows first+floor(p), first+min(floor(p)+1, frameCount-1)
            locomotion: t*fps/frameCount = distance / (stride * instanceScale) → planted feet at any speed.

LOD RECORD (64 bytes, LOD0 = most detailed): u32 vertexCount (incl. socket points) · u32 indexCount · u32
  triangleCount · u32 indexBytes (2 | 4) · u32 vertexOffset · u32 vertexStride (20 rigid | 32 skinned) · u32
  indexOffset · u32 vatWidth (0 = no VAT) · u32 vatRowBytes · u32 vatPosOffset · u32 vatNrmOffset · f32 switchPx
  (use this LOD while the creature is at least this many drawable px long; 0 = always) · u32 drawVertexCount
  (sockets are [drawVertexCount, vertexCount)) · 12 bytes 0

RIGID VERTEX (20 bytes; the animated position / normal come from the VAT or the bone texture)
  0  uchar4 albedoAO   rgb albedo (sRGB-encoded), a = baked AO (linear)
  4  uchar4 material   x glow 0..1 · y roughness · z bone index (rigid path) · w flags (bit0 gland · bit1 eye ·
                       bit2 carapace · bit3 socket point)
  8  half4  rest       xyz rest position (model space), w = gland phase 0..1
  16 char4  restNrm    snorm8 rest unit normal, w = 0
SKINNED VERTEX (32 bytes)
  0  half4  rest       xyz bind-pose position (model space), w = 0
  8  char4  normal     snorm8 xyz, w = flags (bit0 visor / class-hue strip · bit1 emissive · bit2 armour edge)
  12 char4  tangent    snorm8 xyz along +u, w = ±127 bitangent sign
  16 half2  uv         normal / ORM maps (top-left origin)
  20 uchar4 albedo     rgb (sRGB-encoded), a = glow 0..1
  24 uchar4 bones      four bone indices
  28 uchar4 weights    unorm, sum 255 (largest first)

VAT (per LOD, rigid / non-rigid creatures): two RGBA16F textures vatWidth × frameCount: vatPos (x, y, z, glow
  multiplier), vatNrm (nx, ny, nz, 0); column = vertex id, row = frame.
BONE TABLE: v1 32 bytes per bone: char[24] name, i32 parent (-1 root), u32 0.
            v2 64 bytes per bone: char[24] name, i32 parent, u32 flags, f32 restRot[4] (bone-local quaternion x y z w),
               f32 restPos[3] (bone-local translation, m), u32 0. Bones are ordered parents first.
BONE TEXTURE (rigid path, optional, RGBA16F boneCount*3 × frameCount): texel (3*b + r, frame) = row r of bone b's
  3×4 deform matrix (pose × restInverse) in game space; p = M · (rest, 1), n = normalize(M3×3 · restNrm).
GLOW TABLE (after the bone texture): frameCount × 4 f32 (gland, pulse, wave, eye); rigid glow multiplier:
  gland  gland + pulse·sin(2π(wave + rest.w)), eye  eye, else 1 (= what the VAT bake writes into vatPos.w).
CLIP TRACKS (skinned, flags bit3): frameCount rows of trackRowBytes; per bone 16 bytes: half4 rotation (bone-local
  quaternion x y z w) · half4 translation (bone-local xyz, w = uniform scale). The app evaluates two clip rows, blends
  (nlerp / lerp), adds additive layers, walks the hierarchy and multiplies by the inverse bind pose (from restRot /
  restPos) into the palette.
SOCKET RECORD: v1 32 bytes: char[16] name, u32 vid[2], u32 bone, u32 flags.
               v2 48 bytes: char[16] name, u32 vid[3] (LOD0…2; 0xFFFFFFFF absent), u32 bone, u32 flags (bit0 gland →
               glint dot), f32 offset[3] (bone-local offset for skinned meshes; 0 for VAT socket points).
"""
import struct

import numpy as np

ALIGN = 256
MAGIC = b'IHV1'
HDR = 128
CLIP_REC, LOD_REC = 48, 64
BONE_REC = {1: 32, 2: 64}
SOCK_REC = {1: 32, 2: 48}
CF_LOOP, CF_HOLD, CF_LOCO = 1, 2, 4
HF_BONES, HF_VAT, HF_SKINNED, HF_TRACKS = 1, 2, 4, 8
NONE = 0xFFFFFFFF
HDR_FMT = '<4sIIIfIIIIIIIIIII3f3ffII'
HDR2_FMT = '<III'          # at 100: trackOffset, trackRowBytes, vertexKind

VERTEX_DTYPE = np.dtype([('albedo_ao', 'u1', 4), ('material', 'u1', 4), ('rest', '<f2', 4), ('nrm', 'i1', 4)])
SKINNED_DTYPE = np.dtype([('rest', '<f2', 4), ('nrm', 'i1', 4), ('tan', 'i1', 4), ('uv', '<f2', 2), ('albedo', 'u1', 4),
                          ('bones', 'u1', 4), ('weights', 'u1', 4)])
assert VERTEX_DTYPE.itemsize == 20 and SKINNED_DTYPE.itemsize == 32

# budgets (plan §2) — gates.py enforces them on every committed file
LOD_TRIS = (3000, 450, 150)
RIGID_FILE_BYTES = 300 * 1024
SKINNED_TRIS = (8000, 10000)


def _al(n):
    return (n + ALIGN - 1) // ALIGN * ALIGN


def _name(s, n):
    b = s.encode('utf-8')[:n - 1]
    return b + b'\0' * (n - len(b))


def snorm8(v):
    return np.clip(np.round(np.asarray(v, dtype=np.float64) * 127.0), -127, 127).astype(np.int8)


def write(path, fps, clips, lods, bones, sockets, bone_tex=None, glow_tab=None, with_vat=True, version=2,
          tracks=None, bone_rest=None):
    """clips: [dict(name, first, frames, loop, stride, event)]
    lods: [dict(vertices: VERTEX_DTYPE or SKINNED_DTYPE (n,), indices (m,) int, draw_vertex_count, switch_px,
                vat_pos (F,n,4) f32, vat_nrm (F,n,4) f32 — rigid / VAT creatures; skinned meshes give
                bounds=(min3, max3) instead)]
    bones: [(name, parent_index)] parents first; bone_rest (v2 skinned): [(quat xyzw, pos xyz)] bone-local rest;
    sockets: [(name, [vid per lod], bone[, offset xyz])]; flags may follow bone as the 4th tuple item in v1 style
             (name, vids, bone, flags) or v2 (name, vids, bone, flags, offset);
    bone_tex: (F, B, 3, 4) f32 or None; glow_tab: (F, 4) f32 or None;
    tracks (skinned): (F, B, 2, 4) f32 — [..., 0, :] quaternion xyzw, [..., 1, :] translation xyz + scale;
    with_vat=False writes a rigid-only ship file; version=1 writes the proof layout (≤ 2 LODs, no skinning)."""
    skinned = lods[0]['vertices'].dtype == SKINNED_DTYPE
    assert version in (1, 2)
    assert version == 2 or (not skinned and tracks is None and len(lods) <= 2), 'version 1: rigid / VAT, ≤ 2 LODs'
    assert len(lods) <= 3, 'at most 3 LODs'
    if skinned:
        with_vat = False
        assert tracks is not None and bone_rest is not None and len(bone_rest) == len(bones)
        frames = tracks.shape[0]
    else:
        frames = lods[0]['vat_pos'].shape[0]
        assert with_vat or bone_tex is not None, 'a rigid file needs the VAT or the bone texture'
    sections = []
    off = _al(HDR)
    clip_off = off
    cb = b''
    for c in clips:
        flags = (CF_LOOP if c['loop'] else CF_HOLD) | (CF_LOCO if c.get('stride', 0) > 0 else 0)
        dur = c['frames'] / fps if c['loop'] else (c['frames'] - 1) / fps
        ev = c.get('event', None)
        cb += struct.pack('<16sIIfIfIfI', _name(c['name'], 16), c['first'], c['frames'], fps, flags,
                          float(c.get('stride', 0.0)), NONE if ev is None else ev, dur, 0)
    sections.append((clip_off, cb))
    off = _al(off + len(cb))
    lod_off = off
    off = _al(off + LOD_REC * len(lods))
    lod_recs = b''
    bmin = np.full(3, np.inf)
    bmax = np.full(3, -np.inf)
    for L in lods:
        V = np.asarray(L['vertices'])
        vb = np.ascontiguousarray(V).tobytes()
        n = len(V)
        idx = np.asarray(L['indices']).ravel()
        ib_bytes = 2 if n < 65536 else 4
        ib = idx.astype('<u2' if ib_bytes == 2 else '<u4').tobytes()
        voff = off
        sections.append((voff, vb))
        off = _al(off + len(vb))
        ioff = off
        sections.append((ioff, ib))
        off = _al(off + len(ib))
        W = poff = noff = 0
        if with_vat:
            W = (n + 63) // 64 * 64

            def vat_bytes(a):
                t = np.zeros((frames, W, 4), dtype='<f2')
                t[:, :n, :] = a.astype('<f2')
                return t.tobytes()
            pb = vat_bytes(L['vat_pos'])
            nb = vat_bytes(L['vat_nrm'])
            poff = off
            sections.append((poff, pb))
            off = _al(off + len(pb))
            noff = off
            sections.append((noff, nb))
            off = _al(off + len(nb))
        if skinned:
            lo, hi = L['bounds']
            bmin = np.minimum(bmin, lo)
            bmax = np.maximum(bmax, hi)
        else:
            P = L['vat_pos'][:, :L['draw_vertex_count'], :3]
            bmin = np.minimum(bmin, P.reshape(-1, 3).min(0))
            bmax = np.maximum(bmax, P.reshape(-1, 3).max(0))
        lod_recs += struct.pack('<IIIIIIIIIIIfI12x', n, len(idx), len(idx) // 3, ib_bytes, voff, V.dtype.itemsize,
                                ioff, W, W * 8, poff, noff, float(L.get('switch_px', 0.0)), L['draw_vertex_count'])
    sections.append((lod_off, lod_recs))
    sock_off = off
    sb = b''
    nv = 2 if version == 1 else 3
    for s in sockets:
        name, vids, bone = s[0], list(s[1]), s[2]
        flags = s[3] if len(s) > 3 else 0
        offs = s[4] if len(s) > 4 else (0.0, 0.0, 0.0)
        v = vids + [NONE] * (nv - len(vids))
        if version == 1:
            sb += struct.pack('<16sIIII', _name(name, 16), v[0], v[1], bone, flags)
        else:
            sb += struct.pack('<16sIIIII3f', _name(name, 16), v[0], v[1], v[2], bone, flags, *[float(x) for x in offs])
    sections.append((sock_off, sb))
    off = _al(off + max(len(sb), 1))
    bone_off = off
    if version == 1:
        bb = b''.join(struct.pack('<24siI', _name(nm, 24), par, 0) for nm, par in bones)
    else:
        rest = bone_rest or [((0.0, 0.0, 0.0, 1.0), (0.0, 0.0, 0.0))] * len(bones)
        bb = b''.join(struct.pack('<24siI4f3fI', _name(nm, 24), par, 0, *[float(x) for x in q], *[float(x) for x in t], 0)
                      for (nm, par), (q, t) in zip(bones, rest))
    for k, (_, par) in enumerate(bones):
        assert par < k, 'bones must be ordered parents first'
    sections.append((bone_off, bb))
    off = _al(off + max(len(bb), 1))
    btex_off = btex_row = btex_w = glow_off = trk_off = trk_row = 0
    if bone_tex is not None:
        Bn = bone_tex.shape[1]
        btex_w = Bn * 3
        btex_row = _al(btex_w * 8)
        t = np.zeros((frames, btex_row // 8, 4), dtype='<f2')
        t[:, :btex_w, :] = bone_tex.reshape(frames, Bn * 3, 4).astype('<f2')
        btex_off = off
        sections.append((btex_off, t.tobytes()))
        off = _al(off + t.nbytes)
        if glow_tab is not None:
            gt = np.ascontiguousarray(glow_tab, dtype='<f4').reshape(frames, 4)
            glow_off = off
            sections.append((glow_off, gt.tobytes()))
            off = _al(off + gt.nbytes)
    if tracks is not None:
        Bn = tracks.shape[1]
        trk_row = _al(Bn * 16)
        t = np.zeros((frames, trk_row // 2), dtype='<f2')
        t[:, :Bn * 8] = np.asarray(tracks, dtype=np.float64).reshape(frames, Bn * 8).astype('<f2')
        trk_off = off
        sections.append((trk_off, t.tobytes()))
        off = _al(off + t.nbytes)
    total = off
    if skinned:
        rest_r = float(np.max(np.linalg.norm(lods[0]['vertices']['rest'][:, :3].astype(np.float64), axis=1)))
    else:
        rest_r = float(np.max(np.linalg.norm(lods[0]['vat_pos'][0, :, :3], axis=1)))
    hflags = (HF_BONES if bone_tex is not None else 0) | (HF_VAT if with_vat else 0) | (HF_SKINNED if skinned else 0) \
        | (HF_TRACKS if tracks is not None else 0)
    hdr = struct.pack(HDR_FMT, MAGIC, version, total, hflags, fps, frames,
                      len(clips), len(lods), len(bones), len(sockets), clip_off, lod_off, sock_off, bone_off,
                      btex_off, btex_row, *bmin.tolist(), *bmax.tolist(), rest_r, btex_w, glow_off)
    if version == 2:
        hdr += struct.pack(HDR2_FMT, trk_off, trk_row, 1 if skinned else 0)
    hdr += b'\0' * (HDR - len(hdr))
    buf = bytearray(total)
    buf[0:HDR] = hdr
    for o, b in sections:
        buf[o:o + len(b)] = b
    with open(path, 'wb') as f:
        f.write(buf)
    return total


def read(path):
    """Parse an IHV1 file, version 1 or 2, into numpy arrays (the reference for the Swift loaders)."""
    data = open(path, 'rb').read()
    assert data[:4] == MAGIC, 'not an IHV1 file'
    h = struct.unpack_from(HDR_FMT, data, 0)
    (_, ver, total, flags, fps, frames, nclip, nlod, nbone, nsock, clip_off, lod_off, sock_off, bone_off,
     btex_off, btex_row) = h[:16]
    bmin, bmax, rest_r, btex_w, glow_off = h[16:19], h[19:22], h[22], h[23], h[24]
    assert ver in (1, 2) and total == len(data), 'version / size mismatch'
    trk_off = trk_row = kind = 0
    if ver == 2:
        trk_off, trk_row, kind = struct.unpack_from(HDR2_FMT, data, 100)
    assert nlod <= (2 if ver == 1 else 3)
    out = dict(version=ver, flags=flags, fps=fps, frames=frames, bounds=(bmin, bmax), rest_radius=rest_r, clips=[],
               lods=[], bones=[], bone_rest=[], sockets=[], bytes=total, skinned=bool(flags & HF_SKINNED))
    for i in range(nclip):
        nm, first, n, cfps, cf, stride, ev, dur, _ = struct.unpack_from('<16sIIfIfIfI', data, clip_off + i * CLIP_REC)
        out['clips'].append(dict(name=nm.rstrip(b'\0').decode(), first=first, frames=n, fps=cfps, loop=bool(cf & CF_LOOP),
                                 hold=bool(cf & CF_HOLD), locomotion=bool(cf & CF_LOCO), stride=stride,
                                 event=None if ev == NONE else ev, duration=dur))
    for i in range(nlod):
        (n, ni, nt, ibytes, voff, stride, ioff, W, row, poff, noff, switch_px, ndraw) = struct.unpack_from(
            '<IIIIIIIIIIIfI', data, lod_off + i * LOD_REC)
        dt = SKINNED_DTYPE if out['skinned'] else VERTEX_DTYPE
        assert stride == dt.itemsize, f'LOD{i}: vertex stride {stride}'
        V = np.frombuffer(data, dt, n, voff)
        I = np.frombuffer(data, '<u2' if ibytes == 2 else '<u4', ni, ioff).astype(np.int64)
        L = dict(vertex_count=n, triangle_count=nt, index_bytes=ibytes, vat_width=W, vertices=V, indices=I.reshape(-1, 3),
                 switch_px=switch_px, draw_vertex_count=ndraw, stride=stride, vat_pos=None, vat_nrm=None)
        if flags & HF_VAT:
            L['vat_pos'] = np.frombuffer(data, '<f2', frames * W * 4, poff).reshape(frames, W, 4)[:, :n].astype(np.float32)
            L['vat_nrm'] = np.frombuffer(data, '<f2', frames * W * 4, noff).reshape(frames, W, 4)[:, :n].astype(np.float32)
        out['lods'].append(L)
    for i in range(nbone):
        if ver == 1:
            nm, par, _ = struct.unpack_from('<24siI', data, bone_off + i * BONE_REC[1])
            out['bones'].append((nm.rstrip(b'\0').decode(), par))
        else:
            r = struct.unpack_from('<24siI4f3fI', data, bone_off + i * BONE_REC[2])
            out['bones'].append((r[0].rstrip(b'\0').decode(), r[1]))
            out['bone_rest'].append((r[3:7], r[7:10]))
    for i in range(nsock):
        if ver == 1:
            nm, v0, v1, b, fl = struct.unpack_from('<16sIIII', data, sock_off + i * SOCK_REC[1])
            out['sockets'].append(dict(name=nm.rstrip(b'\0').decode(), vid=[v0, v1], bone=b, flags=fl, offset=(0, 0, 0)))
        else:
            r = struct.unpack_from('<16sIIIII3f', data, sock_off + i * SOCK_REC[2])
            out['sockets'].append(dict(name=r[0].rstrip(b'\0').decode(), vid=list(r[1:4]), bone=r[4], flags=r[5],
                                       offset=r[6:9]))
    if flags & HF_BONES:
        T = np.frombuffer(data, '<f2', frames * (btex_row // 8) * 4, btex_off).reshape(frames, btex_row // 8, 4)
        out['bone_tex'] = T[:, :btex_w].astype(np.float32).reshape(frames, nbone, 3, 4)
        if glow_off:
            out['glow_tab'] = np.frombuffer(data, '<f4', frames * 4, glow_off).reshape(frames, 4).astype(np.float32)
    if flags & HF_TRACKS:
        T = np.frombuffer(data, '<f2', frames * trk_row // 2, trk_off).reshape(frames, trk_row // 2)
        out['tracks'] = T[:, :nbone * 8].astype(np.float32).reshape(frames, nbone, 2, 4)
    return out


def rigid_row(D, lod, row):
    """CPU reference of the rigid (bone texture) path for one row: positions, normals, glow multiplier — what
    vs_creature_rigid computes; equals the VAT row within half-float precision."""
    V = lod['vertices']
    M = D['bone_tex'][row][V['material'][:, 2].astype(int)]           # (n, 3, 4)
    rest = V['rest'][:, :3].astype(np.float64)
    P = np.einsum('vij,vj->vi', M[:, :, :3], rest) + M[:, :, 3]
    N = np.einsum('vij,vj->vi', M[:, :, :3], V['nrm'][:, :3].astype(np.float64) / 127.0)
    N /= np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-9)
    g = D['glow_tab'][row] if 'glow_tab' in D else np.array([1.0, 0.0, 0.0, 1.0])
    fl = V['material'][:, 3]
    mult = np.ones(len(V))
    gl = (fl & 1) > 0
    mult[gl] = g[0] + g[1] * np.sin(2 * np.pi * (g[2] + V['rest'][gl, 3].astype(np.float64)))
    mult[(fl & 2) > 0] = g[3]
    return P, N, mult


def sample(lod, clip, t, fps=None):
    """CPU reference of the VAT shader: position / normal / glow multiplier at clip time t (seconds)."""
    fps = fps or clip['fps']
    n = clip['frames']
    if clip['loop']:
        p = (t * fps / n % 1.0) * n
        r0 = int(p) % n
        r1 = (r0 + 1) % n
    else:
        p = min(t * fps, n - 1)
        r0 = int(p)
        r1 = min(r0 + 1, n - 1)
    f = p - int(p)
    a0, a1 = clip['first'] + r0, clip['first'] + r1
    P = lod['vat_pos'][a0] * (1 - f) + lod['vat_pos'][a1] * f
    N = lod['vat_nrm'][a0, :, :3] * (1 - f) + lod['vat_nrm'][a1, :, :3] * f
    N /= np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-8)
    return P[:, :3], N, P[:, 3]


# ---------------------------------------------------------------- skinned reference (CPU, what WP4's palette does)
def _qmul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return np.array([aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
                     aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz])


def _qmat(q):
    x, y, z, w = q / max(np.linalg.norm(q), 1e-12)
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def _world(bones, local):
    """local: [(R 3×3, t 3)] per bone (parents first) → model-space 3×4 per bone."""
    W = []
    for (nm, par), (R, t) in zip(bones, local):
        M = np.eye(4)
        M[:3, :3] = R
        M[:3, 3] = t
        W.append(M if par < 0 else W[par] @ M)
    return W


def skin_palette(D, row):
    """3×4 skinning matrices (model space) of every bone at a track row: world(pose) × inverse(world(rest))."""
    rest = _world(D['bones'], [(_qmat(np.array(q, dtype=np.float64)), np.array(t, dtype=np.float64)) for q, t in D['bone_rest']])
    T = D['tracks'][row].astype(np.float64)
    pose = _world(D['bones'], [(_qmat(T[b, 0]) * T[b, 1, 3], T[b, 1, :3]) for b in range(len(D['bones']))])
    return np.stack([(P @ np.linalg.inv(R))[:3] for P, R in zip(pose, rest)])


def skin_row(D, lod, row):
    """CPU reference of the skinned path: deformed positions / normals of a LOD at a track row."""
    V = lod['vertices']
    M = skin_palette(D, row)
    rest = V['rest'][:, :3].astype(np.float64)
    w = V['weights'].astype(np.float64) / 255.0
    P = np.zeros_like(rest)
    N = np.zeros_like(rest)
    nrm = V['nrm'][:, :3].astype(np.float64) / 127.0
    for k in range(4):
        Mk = M[V['bones'][:, k].astype(int)]
        P += w[:, k:k + 1] * (np.einsum('vij,vj->vi', Mk[:, :, :3], rest) + Mk[:, :, 3])
        N += w[:, k:k + 1] * np.einsum('vij,vj->vi', Mk[:, :, :3], nrm)
    N /= np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-9)
    return P, N
