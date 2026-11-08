"""Marine material maps in texel space (feel build M2 «used armour, not plastic»; numpy only, deterministic).

The committed bake (bake_src: tangent normal, AO, worn-chamfer roughness / metal, paint mask) carries the SHAPE; this
module turns it into a used power armour, per texel of the class's 1024² atlas, as a pure function of
  * the bind-space position map — the shipped LOD0 UV triangles rasterised into the atlas: bind position, bind normal,
    material slot (vertex albedo + flags), owning bone per texel (`posmap`);
  * the bake's AO, chamfer (metal on painted slots) and paint-mask channels;
so the md5 gate holds (no Cycles, no random state: value noise hashed from the bind position in float32).

Layers (the feel study's column AFTER, char-study/scripts/maps.py, made a build step):
  * plates (ARMOUR, PAINT) in a cold field-grey matte paint (rough 0.6–0.8), each part's value drifting a little
    (a hash of its bone + broad bind-space noise); the class colour only as an ACCENT: the helmet's painted shell and the
    top-facing half of the pauldrons (a soft edge on the bind normal — what the 57° game camera sees), plus the class
    markings of the paint mask; the backpack, forearm and knee plates are field grey;
  * wear: the baked worn chamfers widened by noise into chipped paint → dark primer → bare steel at the very edge,
    sparse chips on the faces, thin scratches in two directions (burnished steel, a groove in the normal);
  * the dark stencils / hazard stripes of the paint mask kept;
  * grime: the AO cavity filled with dirt, downward streaks under the shoulders, soot and slush up the legs;
  * the undersuit (DARK, vertex flag bit4 = fabric: fs_marine adds a sheen lobe) a matte rubberised fabric (rough
    0.86–0.93) with a grain in the normal; soles dull rubber; the mechanics oily gunmetal with value drift;
  * rime on up-facing surfaces, in crevices and on the boots (bright, rough ~0.5, a crust in the normal) — its amount
    goes into the ORM alpha for fs_marine's view-dependent frost sparkle;
  * the emitters' texels (visor, lamp, strobe) and the dark glass keep their vertex colour (they emit from the vertex
    flags), nothing else glows.
Outputs per class: albedo (linear RGB), ORM (AO, roughness, metal, frost) and the tangent normal with the detail
added. build_marines.py encodes all classes into marine_albedo.iht (sRGB), marine_orm.iht and marine_normal.iht.

Stand-alone look-dev (reads the SHIPPED .ihv and the committed bake; same function as the build):
  venv/bin/python -B characters/paint.py App/Resources/Characters OUTDIR [--classes assault,cryo]
    → OUTDIR/<cls>_{albedo,rough,metal,frost,normal}.png + stats
"""
import os
import sys

import numpy as np

N = 1024
DILATE = 16           # texels of island padding (mip 4 still samples island data)

# ---------------------------------------------------------------- palette (sRGB 0..255 → linear)


def lin(c):
    c = np.asarray(c, dtype=np.float32) / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4).astype(np.float32)


def srgb(c):
    c = np.clip(np.asarray(c, dtype=np.float32), 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055).astype(np.float32)


FIELD = lin((116, 120, 121))        # cold field-grey paint (the ceramic and the class shells alike)
PRIMER = lin((46, 47, 47))          # the dark primer under chipped paint
STEEL = np.array([0.52, 0.52, 0.54], np.float32)    # bare steel (linear; metallic)
STENCIL = np.array([0.02, 0.021, 0.023], np.float32)
FABRIC = lin((38, 40, 41))          # the rubberised undersuit
GUNMETAL = lin((78, 81, 84))
BRASS_C = lin((120, 96, 62))
SOLE_C = lin((26, 26, 27))
GRIME = lin((30, 27, 24))           # oily soot
FROST = np.array([0.58, 0.64, 0.70], np.float32)


def smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return (t * t * (3.0 - 2.0 * t)).astype(np.float32)


def mix(a, b, t):
    return a + (b - a) * t


# ---------------------------------------------------------------- value noise in bind space (float32, like fs_marine)
def mhash(p):
    p = (p * np.float32(0.1031)) % np.float32(1.0)
    d = (p * (p[..., ::-1] + np.float32(31.32))).sum(-1, keepdims=True, dtype=np.float32)
    p = p + d
    return ((p[..., 0] + p[..., 1]) * p[..., 2]) % np.float32(1.0)


_CORNERS = [np.array(c, np.float32) for c in ((0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 1, 0), (0, 0, 1), (1, 0, 1), (0, 1, 1), (1, 1, 1))]


def mnoise(p):
    p = p.astype(np.float32)
    i = np.floor(p)
    f = p - i
    f = f * f * (np.float32(3) - np.float32(2) * f)
    h = [mhash(i + c) for c in _CORNERS]
    fx, fy, fz = f[..., 0], f[..., 1], f[..., 2]
    a = mix(h[0], h[1], fx)
    b = mix(h[2], h[3], fx)
    c = mix(h[4], h[5], fx)
    d = mix(h[6], h[7], fx)
    return mix(mix(a, b, fy), mix(c, d, fy), fz)


def fbm(p, octaves=3, lac=2.03, gain=0.5):
    s = np.zeros(p.shape[:-1], np.float32)
    a, tot = 1.0, 0.0
    q = p.astype(np.float32)
    for k in range(octaves):
        s = s + np.float32(a) * mnoise(q + np.float32(17.3 * k))
        tot += a
        a *= gain
        q = q * np.float32(lac)
    return (s / np.float32(tot)).astype(np.float32)


# ---------------------------------------------------------------- the position map
def posmap(V, I, n=N):
    """Rasterise the LOD0 UV triangles (V: ihv SKINNED_DTYPE with top-left uv, I: flat indices) into the n² atlas:
    bind position / normal per texel (barycentric), the provoking vertex's albedo, flags, bone; dilated DILATE texels
    so bilinear and mip sampling at island borders stay on island data. Returns a dict of (n, n[, k]) arrays."""
    I = np.asarray(I, np.int64).reshape(-1, 3)
    uv = V['uv'].astype(np.float64) * n - 0.5               # texel centres sit at integer + 0.5
    P = V['rest'][:, :3].astype(np.float64)
    Nn = V['nrm'][:, :3].astype(np.float64) / 127.0
    flags = V['nrm'][:, 3].astype(np.int32) & 0xff
    alb = V['albedo'][:, :3].astype(np.int32)
    bone = V['bones'][:, 0].astype(np.int32)
    pos = np.zeros((n, n, 3), np.float32)
    nrm = np.zeros((n, n, 3), np.float32)
    alb_m = np.zeros((n, n, 3), np.int32)
    flag_m = np.zeros((n, n), np.int32)
    bone_m = np.full((n, n), -1, np.int32)
    cov = np.zeros((n, n), bool)
    for tri in I:
        a, b, c = uv[tri[0]], uv[tri[1]], uv[tri[2]]
        x0, x1 = int(np.floor(min(a[0], b[0], c[0]))), int(np.ceil(max(a[0], b[0], c[0])))
        y0, y1 = int(np.floor(min(a[1], b[1], c[1]))), int(np.ceil(max(a[1], b[1], c[1])))
        x0, y0, x1, y1 = max(x0, 0), max(y0, 0), min(x1, n - 1), min(y1, n - 1)
        if x1 < x0 or y1 < y0:
            continue
        den = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1])
        if abs(den) < 1e-12:
            continue
        xs, ys = np.meshgrid(np.arange(x0, x1 + 1), np.arange(y0, y1 + 1))
        px, py = xs.ravel().astype(np.float64), ys.ravel().astype(np.float64)
        w0 = ((b[1] - c[1]) * (px - c[0]) + (c[0] - b[0]) * (py - c[1])) / den
        w1 = ((c[1] - a[1]) * (px - c[0]) + (a[0] - c[0]) * (py - c[1])) / den
        w2 = 1.0 - w0 - w1
        e = -0.6 / max(1.0, np.sqrt(abs(den)))            # conservative by about half a texel
        m = (w0 >= e) & (w1 >= e) & (w2 >= e)
        if not m.any():
            continue
        ix, iy, w0, w1, w2 = px[m].astype(np.int64), py[m].astype(np.int64), w0[m], w1[m], w2[m]
        pos[iy, ix] = w0[:, None] * P[tri[0]] + w1[:, None] * P[tri[1]] + w2[:, None] * P[tri[2]]
        nn = w0[:, None] * Nn[tri[0]] + w1[:, None] * Nn[tri[1]] + w2[:, None] * Nn[tri[2]]
        nrm[iy, ix] = nn / np.maximum(np.linalg.norm(nn, axis=1, keepdims=True), 1e-9)
        alb_m[iy, ix] = alb[tri[0]]
        flag_m[iy, ix] = flags[tri[0]]
        bone_m[iy, ix] = bone[tri[0]]
        cov[iy, ix] = True
    filled = cov.copy()
    for _ in range(DILATE):
        grown = np.zeros_like(filled)
        for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
            src = np.roll(np.roll(filled, dy, 0), dx, 1) & ~filled & ~grown
            if not src.any():
                continue
            ys, xs = np.nonzero(src)
            sy, sx = (ys - dy) % n, (xs - dx) % n
            for arr in (pos, nrm, alb_m):
                arr[ys, xs] = arr[sy, sx]
            flag_m[ys, xs] = flag_m[sy, sx]
            bone_m[ys, xs] = bone_m[sy, sx]
            grown[ys, xs] = True
        filled |= grown
    return dict(pos=pos, nrm=nrm, alb=alb_m, flags=flag_m, bone=bone_m, cov=cov, filled=filled)


# ---------------------------------------------------------------- the paint
def generate(cls, V, I, bone_names, nmap, orm, mats, accent_srgb, slots):
    """cls: class name; V, I: the exported LOD0 (ihv SKINNED_DTYPE, flat indices); bone_names: skeleton order;
    nmap (n, n, 3) unit tangent normals and orm (n, n, 4) 0..1 (AO, rough, metal, paint) from the committed bake;
    mats: marines.materials(cls) (slot → (albedo, rough, metal, glow, flags)); accent_srgb: the class paint (0..255);
    slots: dict of the slot indices by name (ARMOUR, PAINT, DARK, METAL, GLOW, GLASS, SOLE, LAMP, BRASS, HOT, STROBE).
    Returns (albedo linear (n, n, 3), orm (n, n, 4): AO / rough / metal / frost, normal (n, n, 3) unit, stats)."""
    pm = posmap(V, I, nmap.shape[0])
    F = pm['filled']
    sel = np.nonzero(F)
    p = pm['pos'][sel]
    nb = pm['nrm'][sel]
    flags = pm['flags'][sel]
    bone = pm['bone'][sel]
    alb_v = pm['alb'][sel]
    # material slot per texel from the vertex albedo + flags (the export writes the slot's values exactly)
    slot = np.full(len(p), -1, np.int32)
    for s, (alb, _r, _m, _g, fl) in sorted(mats.items()):
        hit = (alb_v[:, 0] == alb[0]) & (alb_v[:, 1] == alb[1]) & (alb_v[:, 2] == alb[2]) & ((flags & ~16) == (fl & ~16))
        slot[hit & (slot < 0)] = s
    S = slots
    isS = lambda *names: np.isin(slot, [S[k] for k in names])    # noqa: E731
    emissive = (flags & 2) > 0
    plate = isS('ARMOUR', 'PAINT') & ~emissive
    paint_slot = isS('PAINT') & ~emissive
    fabric = isS('DARK')
    mech = isS('METAL', 'HOT', 'BRASS')
    sole = isS('SOLE')
    glass = isS('GLASS')
    glowing = isS('GLOW', 'LAMP', 'STROBE')
    bi = {nm: k for k, nm in enumerate(bone_names)}
    head = bone == bi['head']
    pauld = (bone == bi['pauldron_L']) | (bone == bi['pauldron_R'])

    ao = orm[..., 0][sel].astype(np.float32)
    metal0 = orm[..., 2][sel].astype(np.float32)
    mask = orm[..., 3][sel].astype(np.float32)
    cav = 1.0 - ao
    cls_mark = smooth(0.7, 0.88, mask)
    dark_mark = smooth(0.25, 0.42, mask) * (1.0 - cls_mark)
    y = p[:, 1]

    # broad / mid / fine breakup, all in bind space (they stick to the body through every clip)
    big = fbm(p * np.float32(2.1) + np.float32(3.0), 3)
    mid = fbm(p * np.float32(9.0) + np.float32(11.0), 3)
    hi = fbm(p * np.float32(41.0) + np.float32(5.0), 3)
    # per-part drift: a value from the bone (the rigid parts — plates of one bone share it) — plates differ a little
    bh = mhash(np.stack([bone.astype(np.float32) * np.float32(7.13), np.full(len(p), 3.7, np.float32),
                         np.full(len(p), 11.1, np.float32)], -1))

    A = np.zeros((len(p), 3), np.float32)
    R = np.zeros(len(p), np.float32)
    M = np.zeros(len(p), np.float32)

    # ---- plates: field grey or the class accent, matte, worn
    top = smooth(0.05, 0.45, nb[:, 1])
    accent = np.where(paint_slot & head, 1.0, 0.0) + np.where(paint_slot & pauld, top, 0.0)
    accent = np.clip(np.maximum(accent, cls_mark * plate), 0.0, 1.0).astype(np.float32)
    acc = lin(accent_srgb)
    base = mix(FIELD[None], acc[None], accent[:, None])
    drift = (0.93 + 0.12 * bh) * (0.92 + 0.15 * big) * (0.96 + 0.07 * mid)
    base = base * drift[:, None]
    # faded paint: the class accent a little lighter and greyer where it is most exposed (sun / frost bleaching)
    fade = 0.25 * smooth(0.55, 0.8, big) * accent
    base = mix(base, (base.mean(-1, keepdims=True) * 1.12), fade[:, None])
    # wear: the baked worn chamfers (metal on painted slots) widened by noise into chips → primer → steel
    edge = smooth(0.15, 0.7, metal0) * plate
    chipn = smooth(0.67, 0.73, fbm(p * np.float32(23.0) + np.float32(1.7), 3) + 0.45 * edge) * (0.35 + 0.65 * edge)
    chip = np.clip(np.maximum(edge * smooth(0.35, 0.6, hi + 0.25), chipn * 0.85), 0.0, 1.0)
    bare = np.clip(edge * smooth(0.45, 0.62, hi + 0.2) + chip * smooth(0.6, 0.75, hi), 0.0, 1.0)

    def scratch(dirv, freq, seed):
        dv = np.array(dirv, np.float32)
        dv /= np.linalg.norm(dv)
        ph = (p @ dv) * np.float32(freq) + np.float32(6.0) * fbm(p * np.float32(3.0) + np.float32(seed), 2)
        line = 1.0 - smooth(0.0, 0.07, np.abs(np.sin(ph)))
        return line * smooth(0.62, 0.7, fbm(p * np.float32(4.0) + np.float32(seed * 2.0), 2)), ph

    s1, ph1 = scratch((0.3, 1.0, 0.2), 140.0, 2.0)
    s2, _ = scratch((1.0, 0.25, -0.4), 170.0, 9.0)
    scr = np.clip(s1 + s2, 0.0, 1.0) * plate
    steel = np.maximum(bare, scr * 0.8)
    pa = mix(base, PRIMER[None], chip[:, None])
    pa = mix(pa, STEEL[None] * (0.85 + 0.3 * hi)[:, None], steel[:, None])
    pa = mix(pa, STENCIL[None], (dark_mark * 0.9 * (1.0 - steel))[:, None])     # stencils / hazard stripes stay
    pr = 0.6 + 0.15 * mid + 0.06 * hi
    pr = mix(pr, 0.84, chip * (1.0 - bare))                                     # the primer is chalky
    pr = mix(pr, 0.3 + 0.12 * hi, steel)                                        # burnished steel
    A = np.where(plate[:, None], pa, A)
    R = np.where(plate, pr, R)
    M = np.where(plate, steel, M)

    # ---- undersuit: matte rubberised fabric with a weave
    weave = 0.5 + 0.5 * np.sin(p[:, 1] * np.float32(520.0) + np.float32(2.0) * mid) * np.sin(
        (p[:, 0] + p[:, 2]) * np.float32(520.0))
    A = np.where(fabric[:, None], FABRIC[None] * (0.82 + 0.3 * mid + 0.06 * weave)[:, None], A)
    R = np.where(fabric, 0.86 + 0.07 * hi, R)
    M = np.where(fabric, 0.0, M)
    # ---- mechanics and the weapon: oily gunmetal, brass fittings; burnished on the worn chamfers the bake found
    mc = np.where(isS('BRASS')[:, None], BRASS_C[None], GUNMETAL[None])
    slot_r = np.zeros(len(p), np.float32)
    for s, (_a, r, _m, _g, _f) in sorted(mats.items()):
        slot_r[slot == s] = r
    burn = smooth(0.04, 0.1, slot_r - orm[..., 1][sel]) * 0.6 * mech
    A = np.where(mech[:, None], mix(mc * (0.78 + 0.4 * mid)[:, None], STEEL[None], burn[:, None]), A)
    R = np.where(mech, np.clip(0.34 + 0.2 * mid + 0.1 * (hi - 0.5) - 0.1 * burn, 0.22, 0.7), R)
    M = np.where(mech, 0.9, M)
    # ---- soles
    A = np.where(sole[:, None], SOLE_C[None] * (0.9 + 0.2 * mid)[:, None], A)
    R = np.where(sole, 0.92, R)
    # ---- glass and the emitters keep their own colour (they glow from the vertex flags)
    keep = glass | glowing
    vcol = lin(alb_v)
    A = np.where(glass[:, None], vcol, A)
    R = np.where(glass, 0.06, R)
    A = np.where(glowing[:, None], vcol * 0.6, A)
    R = np.where(glowing, 0.2, R)
    # anything the slot table missed keeps its vertex colour / the bake (none expected; counted in the stats)
    other = slot < 0
    A = np.where(other[:, None], vcol, A)
    R = np.where(other, orm[..., 1][sel], R)
    M = np.where(other, metal0, M)

    # ---- grime: the cavities, streaks running down from the shoulders, soot and slush up the legs
    streak = fbm(p * np.array([24.0, 2.2, 24.0], np.float32) + np.float32(8.0), 3)
    soot = (1.0 - smooth(0.05, 0.75, y)) * (0.5 + 0.5 * big)
    g = np.clip(cav * 0.9 + 0.3 * smooth(0.6, 0.8, streak) * (1.0 - smooth(1.2, 1.9, y)) + soot * 0.6, 0.0, 1.0)
    g = np.where(keep, 0.0, g) * np.where(glass, 0.0, 1.0)
    A = mix(A, A * 0.4 + GRIME[None] * 0.6, (g * 0.7)[:, None])
    R = mix(R, 0.88, g * 0.5)
    M = M * (1.0 - 0.6 * g)

    # ---- frost: rime settles on up-facing surfaces, in crevices and on the boots
    frn = fbm(p * np.float32(58.0) + np.float32(21.0), 3)
    frb = fbm(p * np.float32(7.0) + np.float32(4.0), 2)                         # where the rime gathered at all
    upf = smooth(0.6, 0.95, nb[:, 1]) * smooth(0.4, 0.6, frb)
    frost = np.clip(upf * smooth(0.5, 0.66, frn) * 0.55 + cav * smooth(0.58, 0.72, frn) * 0.4
                    + (1.0 - smooth(0.04, 0.2, y)) * smooth(0.48, 0.64, frn) * 0.6, 0.0, 1.0)
    # the weapon and the mechanics run warm (less rime), the soles scrape it off
    frost = np.where(keep, 0.0, frost) * np.where(sole, 0.3, 1.0) * np.where(mech, 0.35, 1.0)
    A = mix(A, FROST[None], (frost * 0.6)[:, None])
    R = mix(R, 0.5, frost)
    M = M * (1.0 - frost)

    # ---- normal detail: fabric grain, the rime crust, a faint orange peel on the paint, scratch grooves
    nm = nmap[sel].astype(np.float32)
    h1 = fbm(p * np.float32(150.0) + np.float32(3.0), 2) - 0.5
    h2 = fbm(p * np.float32(150.0) + np.float32(41.0), 2) - 0.5
    amp = np.where(fabric, 0.16, 0.0) + frost * 0.24 + np.where(plate, 0.03, 0.0)
    nx = nm[:, 0] + h1 * amp + scr * 0.12 * np.sign(np.sin(ph1))
    ny = nm[:, 1] + h2 * amp + np.where(fabric, 0.05 * (weave - 0.5), 0.0)
    nz = np.maximum(nm[:, 2], 0.05)
    nl = np.sqrt(nx * nx + ny * ny + nz * nz)
    nrm_t = np.stack([nx / nl, ny / nl, nz / nl], -1).astype(np.float32)

    # ---- assemble the atlases (outside the padded islands: the bake / neutral values)
    n = nmap.shape[0]
    alb_out = np.zeros((n, n, 3), np.float32) + FIELD[None, None] * 0.5
    alb_out[sel] = np.clip(A, 0.0, 1.0)
    orm_out = orm.astype(np.float32).copy()
    orm_out[..., 2] = 0.0
    orm_out[..., 3] = 0.0
    orm_out[..., 1][sel] = np.clip(R, 0.04, 1.0)
    orm_out[..., 2][sel] = np.clip(M, 0.0, 1.0)
    orm_out[..., 3][sel] = frost
    nrm_out = nmap.astype(np.float32).copy()
    nrm_out[sel] = nrm_t

    cov = pm['cov'][sel]

    def share(m):
        return round(float((m & cov).sum()) / max(1, int(cov.sum())), 4)

    def pct(v, m):
        v = v[m & cov]
        return [round(float(x), 3) for x in np.percentile(v, [5, 50, 95])] if len(v) else []

    stats = dict(accent_share=share((accent > 0.5) & plate), plate_share=share(plate), fabric_share=share(fabric),
                 bare_metal_share=share((M > 0.5) & plate), chip_share=share((chip > 0.5) & plate),
                 frost_share=share(frost > 0.4), grime_share=share(g > 0.5), unmatched_texels=int((other & cov).sum()),
                 rough_plate_p5_50_95=pct(R, plate & (steel < 0.2) & (frost < 0.2) & (g < 0.3)),
                 rough_fabric_p5_50_95=pct(R, fabric & (frost < 0.2) & (g < 0.3)),
                 rough_all_p5_50_95=pct(R, np.ones_like(cov)))
    return alb_out, orm_out, nrm_out, stats


# ---------------------------------------------------------------- encoding (all classes → one array each)
def encode_albedo(layers, fmt):
    """layers: linear RGB (n, n, 3) per class → IHT levels: the mip chain averaged in LINEAR light, each level stored
    sRGB-encoded (the app samples it through an sRGB ASTC format; astcenc's LDR mode on sRGB values, alpha 1)."""
    import iht
    block = iht.ASTC[fmt]
    out = []
    for img in layers:
        chain, _ = iht.mip_chain(img.astype(np.float32), 'data')
        row = []
        for lvl in chain:
            px = np.zeros(lvl.shape[:2] + (4,), np.uint8)
            px[..., :3] = np.clip(np.round(srgb(lvl) * 255.0), 0, 255).astype(np.uint8)
            px[..., 3] = 255
            row.append(iht.astc_encode(px, block, 'data'))
        out.append(row)
    return out


# ---------------------------------------------------------------- look-dev entry
def _main():
    from PIL import Image
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, here)
    sys.path.insert(0, os.path.dirname(here))
    import ihv
    import marines as MR
    import shapes
    res, out = sys.argv[1], sys.argv[2]
    classes = MR.CLASSES
    if '--classes' in sys.argv:
        classes = sys.argv[sys.argv.index('--classes') + 1].split(',')
    os.makedirs(out, exist_ok=True)
    bake = os.path.join(here, 'bake_src')
    for cls in classes:
        D = ihv.read(os.path.join(res, f'marine_{cls}.ihv'))
        L = D['lods'][0]
        nmap = np.asarray(Image.open(os.path.join(bake, f'{cls}_normal.png')).convert('RGB'), dtype=np.float32) / 255.0 * 2 - 1
        nmap /= np.maximum(np.linalg.norm(nmap, axis=2, keepdims=True), 1e-6)
        orm = np.asarray(Image.open(os.path.join(bake, f'{cls}_orm.png')).convert('RGBA'), dtype=np.float32) / 255.0
        A, O, Nm, st = generate(cls, L['vertices'], L['indices'], [b[0] for b in D['bones']], nmap, orm, MR.materials(cls),
                                MR.rgb(MR.TRIM[cls]), slot_table(shapes, MR))
        u8 = lambda a: np.clip(np.round(a * 255), 0, 255).astype(np.uint8)    # noqa: E731
        Image.fromarray(u8(srgb(A)), 'RGB').save(os.path.join(out, f'{cls}_albedo.png'))
        for k, nm in ((1, 'rough'), (2, 'metal'), (3, 'frost')):
            Image.fromarray(u8(O[..., k]), 'L').save(os.path.join(out, f'{cls}_{nm}.png'))
        Image.fromarray(u8(Nm * 0.5 + 0.5), 'RGB').save(os.path.join(out, f'{cls}_normal.png'))
        print(cls, st, flush=True)


def slot_table(shapes, MR):
    return dict(ARMOUR=shapes.ARMOUR, PAINT=shapes.PAINT, DARK=shapes.DARK, METAL=shapes.METAL, GLOW=shapes.GLOW,
                GLASS=shapes.GLASS, SOLE=shapes.SOLE, LAMP=shapes.LAMP, BRASS=shapes.BRASS, HOT=shapes.HOT,
                STROBE=MR.STROBE)


if __name__ == '__main__':
    _main()
