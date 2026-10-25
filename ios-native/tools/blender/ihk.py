"""IHK1 — «Ледяной Улей» static station-kit container (Metal-friendly). Writer + reader (numpy only).

One file holds every piece of the station kit (crates, pillars, lamp heads, vents, beacon masts, lift pads, icicle
fringes, snow drifts …). The app (App/Sources/Metal/Level/KitStore.swift) reads it once and WorldLevel places the
pieces from the level layout, merging them into a few static vertex buffers (one draw per buffer). Same layout rules
as IHV1: little-endian, every section on a 256-byte boundary, so the whole file can back one MTLBuffer.

COORDINATES — game space: metres, y up, the piece's origin on the floor under it (+z = the piece's "front"), exported
from Blender as game = (-X, Z, Y) (det +1: counter-clockwise front faces stay counter-clockwise).

HEADER (128 bytes)
  0  char[4] "IHK1"        4  u32 version = 1       8  u32 fileBytes         12 u32 flags (0)
  16 u32 pieceCount        20 u32 pieceTableOffset  24 u32 vertexStride (32) 28 u32 vertexCount
  32 u32 vertexOffset      36 u32 indexCount        40 u32 indexOffset (u16, piece-local: add the piece's firstVertex)
  44 u32 layerCount        (trim-sheet layers the pieces use: Kit/trim_*.iht are arrays of this many layers)
  48 u32 aoAtlasSize       (px of Kit/kit_ao.iht; uv1 below addresses it)
  52 f32 trimDensity       (trim-sheet uv0 units per metre along a tiling strip)
  56 char[24] kitName      80..127 reserved 0

PIECE RECORD (96 bytes, pieceCount of them, sorted by name)
  0  char[32] name         32 u32 firstVertex      36 u32 vertexCount      40 u32 firstIndex       44 u32 indexCount
  48 u32 flags (bit0 lift piece: rides the lift deck; bit1 dynamic: drawn per frame with a transform, not merged)
  52 u32 triangles         56 f32 boundsMin[3]     68 f32 boundsMax[3]
  80 f32 aoRect[4]         (u0, v0, u1, v1 of the piece's island block in the AO atlas; informative)

VERTEX (32 bytes)
  0  half4  position       xyz model metres, w = 1
  8  char4  normal         snorm8 xyz (flat-shaded hard surface: split per face group), w = 0
  12 char4  tangent        snorm8 xyz along +u of uv0, w = ±127 bitangent sign
  16 half2  uv0            trim sheet (layer below); u may run past 1 along a tiling strip
  20 ushort2 uv1           unorm16 into the AO atlas (baked ambient occlusion of the piece alone)
  24 uchar4 tint           rgb albedo (sRGB-encoded), a = metalness (0..255)
  28 uchar4 extra          x = emissive strength * 32 (HDR: 255 = 7.97 × albedo), y = trim layer (0..layerCount-1,
                           255 = none: flat normal, ORM from the vertex), z = flags, w = AO strength
         flags: bit0 snow (drift: snow material) · bit1 ice (icicles) · bit2 hazard stripes along uv0.u
                · bit3 chamfer (worn bright edge) · bit4 frost-receptive (rime from the world mask on up faces)
                · bit5 light strip (emissive housing; the colour is the tint) · bit6 paint: the placement's
                colour replaces the tint (crate shells, lamp lenses, the beacon head's state colour)
         w = AO strength of uv1 (255 for pieces; procedural level geometry has no atlas island: 0)
  Metal: the runtime merge rewrites position as packed_float3 world space (36-byte vertex, KitStore.swift).

The trim sheets and the AO atlas are IHT1 files (iht.py); their names come from the build (Kit/trim_normal.iht,
Kit/trim_orm.iht, Kit/kit_ao.iht).
"""
import struct
import numpy as np

ALIGN = 256
MAGIC = b'IHK1'
HDR = 128
PIECE_REC = 96
HDR_FMT = '<4s12If24s'

F_SNOW, F_ICE, F_HAZARD, F_CHAMFER, F_FROST, F_STRIP, F_PAINT = 1, 2, 4, 8, 16, 32, 64
P_LIFT, P_DYNAMIC = 1, 2

VERTEX_DTYPE = np.dtype([('pos', '<f2', 4), ('nrm', 'i1', 4), ('tan', 'i1', 4), ('uv0', '<f2', 2), ('uv1', '<u2', 2),
                         ('tint', 'u1', 4), ('extra', 'u1', 4)])
assert VERTEX_DTYPE.itemsize == 32


def _al(n):
    return (n + ALIGN - 1) // ALIGN * ALIGN


def _name(s, n):
    b = s.encode('utf-8')[:n - 1]
    return b + b'\0' * (n - len(b))


def write(path, pieces, layer_count, ao_size, trim_density, kit_name='station'):
    """pieces: [dict(name, vertices: VERTEX_DTYPE (n,), indices (m,) int (piece-local), flags, ao_rect)] —
    written sorted by name (deterministic). Returns the file size."""
    pieces = sorted(pieces, key=lambda p: p['name'])
    names = [p['name'] for p in pieces]
    assert len(set(names)) == len(names), 'duplicate piece names'
    V = [np.ascontiguousarray(p['vertices']) for p in pieces]
    I = [np.asarray(p['indices'], dtype=np.int64).ravel() for p in pieces]
    for p, v, i in zip(pieces, V, I):
        assert v.dtype == VERTEX_DTYPE, p['name']
        assert len(v) < 65536, f"{p['name']}: {len(v)} vertices (u16 indices)"
        assert len(i) % 3 == 0 and (len(i) == 0 or (i.min() >= 0 and i.max() < len(v))), p['name']
    nv = sum(len(v) for v in V)
    ni = sum(len(i) for i in I)
    off = _al(HDR)
    piece_off = off
    off = _al(off + PIECE_REC * len(pieces))
    vert_off = off
    off = _al(off + nv * VERTEX_DTYPE.itemsize)
    idx_off = off
    off = _al(off + ni * 2)
    total = off
    buf = bytearray(total)
    fv = fi = 0
    for k, (p, v, i) in enumerate(zip(pieces, V, I)):
        pos = v['pos'][:, :3].astype(np.float64)
        lo = pos.min(0) if len(v) else np.zeros(3)
        hi = pos.max(0) if len(v) else np.zeros(3)
        ao = p.get('ao_rect', (0.0, 0.0, 0.0, 0.0))
        rec = struct.pack('<32sIIIIII3f3f4f', _name(p['name'], 32), fv, len(v), fi, len(i), int(p.get('flags', 0)),
                          len(i) // 3, *lo.tolist(), *hi.tolist(), *[float(a) for a in ao])
        assert len(rec) == PIECE_REC
        buf[piece_off + k * PIECE_REC: piece_off + (k + 1) * PIECE_REC] = rec
        vb = v.tobytes()
        buf[vert_off + fv * 32: vert_off + fv * 32 + len(vb)] = vb
        ib = i.astype('<u2').tobytes()
        buf[idx_off + fi * 2: idx_off + fi * 2 + len(ib)] = ib
        fv += len(v)
        fi += len(i)
    hdr = struct.pack(HDR_FMT, MAGIC, 1, total, 0, len(pieces), piece_off, VERTEX_DTYPE.itemsize, nv, vert_off, ni, idx_off,
                      int(layer_count), int(ao_size), float(trim_density), _name(kit_name, 24))
    buf[0:len(hdr)] = hdr
    with open(path, 'wb') as f:
        f.write(buf)
    return total


def read(path):
    """Parse an IHK1 file (the reference for KitStore.swift)."""
    data = open(path, 'rb').read()
    assert data[:4] == MAGIC, 'not an IHK1 file'
    h = struct.unpack_from(HDR_FMT, data, 0)
    (_, ver, total, flags, npc, piece_off, stride, nv, vert_off, ni, idx_off, layers, ao_size, density, kname) = h
    assert ver == 1 and total == len(data) and stride == VERTEX_DTYPE.itemsize, 'version / size / stride mismatch'
    Vall = np.frombuffer(data, VERTEX_DTYPE, nv, vert_off)
    Iall = np.frombuffer(data, '<u2', ni, idx_off).astype(np.int64)
    out = dict(version=ver, bytes=total, layers=layers, ao_size=ao_size, trim_density=density,
               name=kname.rstrip(b'\0').decode(), pieces=[], vertex_count=nv, index_count=ni)
    for k in range(npc):
        r = struct.unpack_from('<32sIIIIII3f3f4f', data, piece_off + k * PIECE_REC)
        nm, fv, cv, fi, ci, pf, ntri = r[:7]
        P = dict(name=nm.rstrip(b'\0').decode(), first_vertex=fv, vertex_count=cv, first_index=fi, index_count=ci,
                 flags=pf, triangles=ntri, bounds=(r[7:10], r[10:13]), ao_rect=r[13:17])
        P['vertices'] = Vall[fv:fv + cv]
        P['indices'] = Iall[fi:fi + ci].reshape(-1, 3)
        out['pieces'].append(P)
    return out


def ao_fingerprint(pieces, kinds):
    """md5 of what the kit's AO atlas depends on: every piece's positions, AO-atlas uv1 and triangles (sorted by name)
    and its bake context (`kinds`: name → 'floor' / 'ceiling' / 'none', the occluder plane under / over it). `pieces`
    are build_kit's exported dicts or `read()`'s records (both: name, VERTEX_DTYPE vertices, indices), so the build and
    gates.py compute the same value from the same bytes. kit/ao_src/bake.json keeps the one the committed bake was made
    for; the build refuses a stale bake (build.sh --bake-ao re-bakes)."""
    import hashlib
    h = hashlib.md5()
    for p in sorted(pieces, key=lambda q: q['name']):
        V = p['vertices']
        h.update(p['name'].encode('utf-8') + b'\0' + str(kinds.get(p['name'], '?')).encode('utf-8') + b'\0')
        h.update(np.ascontiguousarray(V['pos'][:, :3]).tobytes())
        h.update(np.ascontiguousarray(V['uv1']).tobytes())
        h.update(np.asarray(p['indices'], dtype='<u4').ravel().tobytes())
    return h.hexdigest()


def pack_vertices(pos, nrm, tan, sign, uv0, uv1, tint_srgb, metal, emissive, layer, flags, ao=255):
    """Arrays -> VERTEX_DTYPE. pos (n,3) game metres, nrm/tan (n,3) unit, sign (n,) ±1, uv0 (n,2), uv1 (n,2) 0..1,
    tint_srgb (n,3) 0..1, metal (n,) 0..1, emissive (n,) 0..7.97, layer (n,) int (255 none), flags (n,) int."""
    n = len(pos)
    V = np.zeros(n, VERTEX_DTYPE)
    V['pos'][:, :3] = np.asarray(pos, dtype=np.float64).astype('<f2')
    V['pos'][:, 3] = 1.0
    V['nrm'][:, :3] = np.clip(np.round(np.asarray(nrm) * 127.0), -127, 127).astype(np.int8)
    V['tan'][:, :3] = np.clip(np.round(np.asarray(tan) * 127.0), -127, 127).astype(np.int8)
    V['tan'][:, 3] = np.where(np.asarray(sign) < 0, -127, 127).astype(np.int8)
    V['uv0'] = np.asarray(uv0, dtype=np.float64).astype('<f2')
    V['uv1'] = np.clip(np.round(np.asarray(uv1, dtype=np.float64) * 65535.0), 0, 65535).astype('<u2')
    V['tint'][:, :3] = np.clip(np.round(np.asarray(tint_srgb) * 255.0), 0, 255).astype(np.uint8)
    V['tint'][:, 3] = np.clip(np.round(np.asarray(metal) * 255.0), 0, 255).astype(np.uint8)
    V['extra'][:, 0] = np.clip(np.round(np.asarray(emissive) * 32.0), 0, 255).astype(np.uint8)
    V['extra'][:, 1] = np.asarray(layer).astype(np.uint8)
    V['extra'][:, 2] = np.asarray(flags).astype(np.uint8)
    V['extra'][:, 3] = np.asarray(ao).astype(np.uint8)
    return V
