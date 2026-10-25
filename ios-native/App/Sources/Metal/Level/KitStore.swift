import Foundation
import Metal

// ================================================================
//  KIT STORE — the station kit (owned by WP6 «Станция и конвейер»):
//  loads what the Blender pipeline (ios-native/tools/blender, see its
//  README) commits under App/Resources/Kit:
//    station.ihk       IHK1: every authored piece (crates, pillars,
//                      lamp posts, vents, beacon mast / head, lift pad
//                      / hub, icicle fringes, drifts …) as 32-byte
//                      vertices + u16 indices
//    trim_normal.iht   IHT1: 4 trim sheets (gratings, panels, rails,
//                      pipes) as a 2D array, ASTC 5×5, tangent normal
//                      (x in .rgb, y in .a), full mips
//    trim_orm.iht      IHT1: the same 4 layers, ASTC 6×6: R AO,
//                      G roughness, B metal, A rime receptivity
//    kit_ao.iht        IHT1: the pieces' baked AO atlas (uv1)
//  and builds the merged station geometry (KitMesh) from the pieces
//  and from runtime primitives that follow the same trim-sheet rules
//  (tools/blender/kit/kitgeo.py): tile uvs (2 m per sheet, world-
//  aligned), strip uvs (8 strips of the rails / pipes sheets), flat
//  normals with MikkTSpace-compatible tangents (Blender bitangent
//  convention: B = sign · cross(N, T) runs toward Blender +v, i.e.
//  Metal −v), chamfers flagged for the worn bright edge.
//  The project has no MetalKit: the IHT1 levels are blitted into
//  private textures here. Without ASTC (an Intel-Mac simulator) the
//  trim sheets fall back to flat 1×1 layers (logged).
// ================================================================

/// One vertex of the merged station geometry (Level.metal `KitVertex`, 40 bytes, 4-byte aligned).
struct KitVertex {
    var px: Float, py: Float, pz: Float
    /// char4 snorm normal (xyz, w 0).
    var nrm: UInt32
    /// char4 snorm tangent (xyz) along +u, w = ±127 bitangent sign.
    var tan: UInt32
    /// Trim-sheet uv (Metal convention: v down).
    var u: Float, v: Float
    /// ushort2 unorm16 AO-atlas uv.
    var uv1: UInt32
    /// uchar4: rgb albedo (sRGB-encoded), a = metalness.
    var tint: UInt32
    /// uchar4: x emissive × 32, y trim layer (255 none), z flags (KitFlag), w AO strength.
    var extra: UInt32
}

/// Vertex flags (IHK1 / kitgeo.py F_*).
enum KitFlag {
    static let snow: UInt32 = 1, ice: UInt32 = 2, hazard: UInt32 = 4, chamfer: UInt32 = 8, frost: UInt32 = 16
    static let strip: UInt32 = 32, paint: UInt32 = 64
    /// A beacon head vertex (WorldLevel): extra.w holds the head index instead of the AO strength; vs_kit spins it.
    static let head: UInt32 = 128
}

/// Trim-sheet layers (kitgeo.py).
enum Trim {
    static let gratings: UInt32 = 0, panels: UInt32 = 1, rails: UInt32 = 2, pipes: UInt32 = 3, none: UInt32 = 255
    /// uv units per metre (2 m per sheet).
    static let density: Float = 0.5
    // strips of the rails sheet
    static let skirt = 0, girder = 1, column = 2, railbar = 3, nosing = 4, hazard = 5, chequer = 6, brushed = 7
    // strips of the pipes sheet
    static let pipe = 0, hose = 1, cables = 2, lattice = 3, vent = 4, fins = 5, flange = 6, rubber = 7
}

/// How a runtime face gets its trim uv.
enum KitUV {
    /// World-aligned planar projection (floors: u = x, v = z; walls: along the wall, v down).
    case tile
    /// Strip `k` of the layer, u along `axis` (metres × density), v across the face inside the strip.
    case strip(Int, F3)
    /// No texture (snow, ice, light strips).
    case none
}

/// Material of a runtime face (the IHK1 face attributes).
struct KitMat {
    var tint: UInt32
    var metal: Float = 0.6
    var emis: Float = 0
    var layer: UInt32 = Trim.panels
    var flags: UInt32 = 0
    var uv: KitUV = .tile

    func with(flags f: UInt32) -> KitMat { var m = self; m.flags |= f; return m }
    func with(uv rule: KitUV, layer l: UInt32? = nil) -> KitMat { var m = self; m.uv = rule; if let l = l { m.layer = l }; return m }
    func tinted(_ t: UInt32) -> KitMat { var m = self; m.tint = t; return m }
}

/// A piece of the kit as loaded (model space, game axes).
struct KitPiece {
    let name: String
    let flags: UInt32
    var positions: [F3] = []
    var normals: [F3] = []
    /// xyz tangent, w bitangent sign.
    var tangents: [F4] = []
    var uv0: [SIMD2<Float>] = []
    var uv1: [UInt32] = []
    var tint: [UInt32] = []
    var extra: [UInt32] = []
    var indices: [UInt16] = []
    var boundsMin = F3(repeating: 0), boundsMax = F3(repeating: 0)
    var triangles: Int { indices.count / 3 }
    /// Largest |x| / |z| of the piece's bounds (a drift's half length / half width, its crest side included).
    var halfLength: Float { max(-boundsMin.x, boundsMax.x) }
    var halfWidth: Float { max(-boundsMin.z, boundsMax.z) }
}

/// Growing merged geometry (one vertex / index stream; WorldLevel splits it into culling chunks).
final class KitMesh {
    var vertices: [KitVertex] = []
    var indices: [UInt32] = []
    /// The triangles that cast flashlight shadows (a second index list over the same vertices: crates, pillars, masts,
    /// lamp posts — `place(…, caster: true)`).
    var casterIndices: [UInt32] = []
    var lo = F3(repeating: .greatestFiniteMagnitude), hi = F3(repeating: -.greatestFiniteMagnitude)

    init(reserve: Int = 0) {
        vertices.reserveCapacity(reserve)
        indices.reserveCapacity(reserve * 3 / 2)
    }

    var triangles: Int { indices.count / 3 }
    var isEmpty: Bool { indices.isEmpty }

    @inline(__always) func add(_ v: KitVertex) -> UInt32 {
        vertices.append(v)
        let p = F3(v.px, v.py, v.pz)
        lo = pointwiseMin(lo, p)
        hi = pointwiseMax(hi, p)
        return UInt32(vertices.count - 1)
    }

    // ---------------------------------------------------------------- packing
    @inline(__always) static func snorm(_ v: F3, _ w: Float = 0) -> UInt32 {
        func b(_ x: Float) -> UInt32 { UInt32(UInt8(bitPattern: Int8(max(-127, min(127, (x * 127).rounded()))))) }
        return b(v.x) | b(v.y) << 8 | b(v.z) << 16 | b(w) << 24
    }

    @inline(__always) static func extra(emis: Float, layer: UInt32, flags: UInt32, ao: UInt32) -> UInt32 {
        UInt32(max(0, min(255, (emis * 32).rounded()))) | (layer & 255) << 8 | (flags & 255) << 16 | (ao & 255) << 24
    }

    @inline(__always) static func tint(_ hex: UInt32, metal: Float) -> UInt32 {
        // memory order r, g, b, a (uchar4): r in the low byte
        ((hex >> 16) & 255) | ((hex >> 8) & 255) << 8 | (hex & 255) << 16 | UInt32(max(0, min(255, (metal * 255).rounded()))) << 24
    }

    // ---------------------------------------------------------------- runtime faces
    /// A convex planar polygon (counter-clockwise seen from the front), flat-shaded, with its trim uvs and tangent.
    func face(_ P: [F3], _ m: KitMat, flags extraFlags: UInt32 = 0) {
        guard P.count >= 3 else { return }
        // Newell normal
        var n = F3(0, 0, 0)
        for i in 0..<P.count {
            let a = P[i], b = P[(i + 1) % P.count]
            n += Mat4.cross(a, b)
        }
        let nl = (n * n).sum().squareRoot()
        if nl < 1e-9 { return }
        n /= nl
        let uv = KitMesh.uvs(P, n, m.uv)
        // tangent from the first triangle's uv gradient (planar face: exact for the whole face)
        var t = F3(1, 0, 0)
        var sign: Float = 1
        if case .none = m.uv {} else {
            let e1 = P[1] - P[0], e2 = P[2] - P[0]
            let d1 = uv[1] - uv[0], d2 = uv[2] - uv[0]
            let det = d1.x * d2.y - d2.x * d1.y
            if abs(det) > 1e-12 {
                let r = 1 / det
                var T = (e1 * d2.y - e2 * d1.y) * r
                let Bm = (e2 * d1.x - e1 * d2.x) * r          // dP / dv (Metal v)
                T -= n * Mat4.dot(n, T)
                let tl = (T * T).sum().squareRoot()
                if tl > 1e-9 {
                    t = T / tl
                    // Blender bitangent = +dP/dv_blender = −dP/dv_metal
                    sign = Mat4.dot(Mat4.cross(n, t), -Bm) < 0 ? -1 : 1
                }
            }
        }
        let ns = KitMesh.snorm(n), ts = KitMesh.snorm(t, sign)
        let tn = KitMesh.tint(m.tint, metal: m.metal)
        let ex = KitMesh.extra(emis: m.emis, layer: { if case .none = m.uv { return Trim.none }; return m.layer }(),
                               flags: m.flags | extraFlags, ao: 0)
        let base = UInt32(vertices.count)
        for (p, q) in zip(P, uv) {
            _ = add(KitVertex(px: p.x, py: p.y, pz: p.z, nrm: ns, tan: ts, u: q.x, v: q.y, uv1: 0, tint: tn, extra: ex))
        }
        for k in 1..<(P.count - 1) { indices += [base, base + UInt32(k), base + UInt32(k + 1)] }
    }

    static func uvs(_ P: [F3], _ n: F3, _ rule: KitUV) -> [SIMD2<Float>] {
        let d = Trim.density
        switch rule {
        case .none:
            return P.map { _ in SIMD2<Float>(0, 0) }
        case .tile:
            let ax = abs(n.x), ay = abs(n.y), az = abs(n.z)
            if ay >= ax && ay >= az { return P.map { SIMD2<Float>($0.x * d, $0.z * d) } }
            if ax >= az { let s: Float = n.x > 0 ? 1 : -1; return P.map { SIMD2<Float>(-s * $0.z * d, -$0.y * d) } }
            let s: Float = n.z > 0 ? 1 : -1
            return P.map { SIMD2<Float>(s * $0.x * d, -$0.y * d) }
        case .strip(let k, let axis0):
            var across = Mat4.cross(n, axis0)
            if (across * across).sum() < 1e-10 { across = Mat4.cross(n, abs(n.y) < 0.9 ? F3(0, 1, 0) : F3(1, 0, 0)) }
            across /= (across * across).sum().squareRoot()
            let ts = P.map { Mat4.dot($0, across) }
            let lo = ts.min()!, hi = ts.max()!
            let span = max(hi - lo, 1e-6)
            let h: Float = 1.0 / 8.0, pad = h / 16, v0 = Float(k) * h
            return zip(P, ts).map { SIMD2<Float>(Mat4.dot($0.0, axis0) * d, v0 + pad + (h - 2 * pad) * ($0.1 - lo) / span) }
        }
    }

    /// Chamfered box (c = 0: plain) in a frame: centre `o`, unit axes ax (width w), ay (height h), az (depth d).
    /// Chamfers carry KitFlag.chamfer. `bottom` false skips the faces under the box.
    func cbox(o: F3, ax: F3 = F3(1, 0, 0), ay: F3 = F3(0, 1, 0), az: F3 = F3(0, 0, 1), w: Float, h: Float, d: Float, c c0: Float,
              _ m: KitMat, chamfer: KitMat? = nil, bottom: Bool = true) {
        let hx = w / 2, hy = h / 2, hz = d / 2
        let c = min(c0, hx * 0.49, hy * 0.49, hz * 0.49)
        let A = [ax, ay, az], H = [hx, hy, hz]
        func P(_ s: [Float], _ onFace: Int) -> F3 {
            var p = o
            for k in 0..<3 { p += A[k] * (s[k] * (H[k] - (k == onFace || c <= 0 ? 0 : c))) }
            return p
        }
        let cm = chamfer ?? m
        for a in 0..<3 {
            for s: Float in [-1, 1] {
                if a == 1 && s < 0 && !bottom { continue }
                let o1 = (a + 1) % 3, o2 = (a + 2) % 3
                var pts: [F3] = []
                for (u, v) in [(Float(-1), Float(-1)), (1, -1), (1, 1), (-1, 1)] {
                    var sg: [Float] = [0, 0, 0]
                    sg[a] = s; sg[o1] = u; sg[o2] = v
                    pts.append(P(sg, a))
                }
                if s < 0 { pts.reverse() }
                face(pts, m)
            }
        }
        guard c > 0 else { return }
        // 12 edge chamfers: edge along axis a, at signs (s1, s2) of the other two
        for a in 0..<3 {
            let o1 = (a + 1) % 3, o2 = (a + 2) % 3
            for s1: Float in [-1, 1] {
                for s2: Float in [-1, 1] {
                    if !bottom && ((o1 == 1 && s1 < 0) || (o2 == 1 && s2 < 0)) { continue }
                    var sg: [Float] = [0, 0, 0]
                    sg[o1] = s1; sg[o2] = s2
                    sg[a] = -1
                    let p0 = P(sg, o1), p1 = P(sg, o2)
                    sg[a] = 1
                    let p2 = P(sg, o2), p3 = P(sg, o1)
                    var q = [p0, p1, p2, p3]
                    // orient outward
                    let out = A[o1] * s1 + A[o2] * s2
                    let nn = Mat4.cross(q[1] - q[0], q[2] - q[0])
                    if Mat4.dot(nn, out) < 0 { q.reverse() }
                    face(q, cm, flags: KitFlag.chamfer)
                }
            }
        }
        for sx: Float in [-1, 1] {
            for sy: Float in [-1, 1] {
                if !bottom && sy < 0 { continue }
                for sz: Float in [-1, 1] {
                    let s: [Float] = [sx, sy, sz]
                    var q = [P(s, 0), P(s, 1), P(s, 2)]
                    let out = ax * sx + ay * sy + az * sz
                    if Mat4.dot(Mat4.cross(q[1] - q[0], q[2] - q[0]), out) < 0 { q.reverse() }
                    face(q, cm, flags: KitFlag.chamfer)
                }
            }
        }
    }

    /// Chamfered bar of cross-section w (horizontal) × h between two points; strip uvs run along it.
    func beam(_ p0: F3, _ p1: F3, w: Float, h: Float, c: Float, _ m0: KitMat, bottom: Bool = true) {
        let d = p1 - p0
        let L = (d * d).sum().squareRoot()
        guard L > 1e-4 else { return }
        let ax = d / L
        var up = F3(0, 1, 0)
        if abs(Mat4.dot(ax, up)) > 0.95 { up = F3(1, 0, 0) }
        var az = Mat4.cross(ax, up)
        az /= (az * az).sum().squareRoot()
        let ay = Mat4.cross(az, ax)
        var m = m0
        if case .strip(let k, _) = m0.uv { m.uv = .strip(k, ax) }
        cbox(o: (p0 + p1) * 0.5, ax: ax, ay: ay, az: az, w: L, h: h, d: w, c: c, m, bottom: bottom)
    }

    /// Prism of `seg` sides between two points (pipes, round rails, columns), smooth-shaded sides when `smooth`.
    func tube(_ p0: F3, _ p1: F3, r: Float, seg: Int, _ m0: KitMat, smooth: Bool = true, caps: Bool = true) {
        let d = p1 - p0
        let L = (d * d).sum().squareRoot()
        guard L > 1e-4 else { return }
        let ax = d / L
        var up = F3(0, 1, 0)
        if abs(Mat4.dot(ax, up)) > 0.95 { up = F3(1, 0, 0) }
        var e1 = Mat4.cross(ax, up)
        e1 /= (e1 * e1).sum().squareRoot()
        let e2 = Mat4.cross(e1, ax)
        var m = m0
        var k = 0
        if case .strip(let kk, _) = m0.uv { k = kk; m.uv = .strip(kk, ax) }
        let ts = KitMesh.tint(m.tint, metal: m.metal)
        let layer: UInt32 = { if case .none = m.uv { return Trim.none }; return m.layer }()
        let ex = KitMesh.extra(emis: m.emis, layer: layer, flags: m.flags, ao: 0)
        let h: Float = 1.0 / 8.0
        for i in 0..<seg {
            let a0 = (Float(i) + 0.5) / Float(seg) * 2 * .pi, a1 = (Float(i) + 1.5) / Float(seg) * 2 * .pi
            let n0 = e1 * cosf(a0) + e2 * sinf(a0), n1 = e1 * cosf(a1) + e2 * sinf(a1)
            let q0 = p0 + n0 * r, q1 = p0 + n1 * r, q2 = p1 + n1 * r, q3 = p1 + n0 * r
            if smooth {
                // smooth sides: per-vertex radial normals, v around the circumference inside the strip
                let va = Float(k) * h + h / 16 + (h - h / 8) * Float(i) / Float(seg)
                let vb = Float(k) * h + h / 16 + (h - h / 8) * Float(i + 1) / Float(seg)
                let ua = Mat4.dot(p0, ax) * Trim.density, ub = Mat4.dot(p1, ax) * Trim.density
                let base = UInt32(vertices.count)
                for (p, n, uu, vv) in [(q0, n0, ua, va), (q1, n1, ua, vb), (q2, n1, ub, vb), (q3, n0, ub, va)] {
                    // tangent along +u (the axis); Blender bitangent toward +v_blender (= −v_metal = −around)
                    let around = Mat4.cross(ax, n)
                    let sign: Float = Mat4.dot(Mat4.cross(n, ax), -around) < 0 ? -1 : 1
                    _ = add(KitVertex(px: p.x, py: p.y, pz: p.z, nrm: KitMesh.snorm(n), tan: KitMesh.snorm(ax, sign), u: uu, v: vv,
                                      uv1: 0, tint: ts, extra: ex))
                }
                // counter-clockwise seen from outside: q0, q3, q2, q1 (n0 → n1 turns around +ax)
                indices += [base, base + 3, base + 2, base, base + 2, base + 1]
            } else {
                face([q0, q3, q2, q1], m)
            }
        }
        if caps {
            var c0: [F3] = [], c1: [F3] = []
            for i in 0..<seg {
                let a = (Float(i) + 0.5) / Float(seg) * 2 * .pi
                let n = e1 * cosf(a) + e2 * sinf(a)
                c0.append(p0 + n * r)
                c1.append(p1 + n * r)
            }
            var capM = m
            capM.uv = .tile
            face(c0, capM)
            face(c1.reversed(), capM)
        }
    }

    /// Surface of revolution around +y at `o`: profile [(r, y)] bottom to top (flat bands), `seg` sides.
    func lathe(o: F3, _ prof: [(Float, Float)], seg: Int, _ m: KitMat, phase: Float = 0) {
        for b in 0..<(prof.count - 1) {
            let (r0, y0) = prof[b], (r1, y1) = prof[b + 1]
            for i in 0..<seg {
                let a0 = phase + Float(i) / Float(seg) * 2 * .pi, a1 = phase + Float(i + 1) / Float(seg) * 2 * .pi
                let d0 = F3(cosf(a0), 0, -sinf(a0)), d1 = F3(cosf(a1), 0, -sinf(a1))
                let A0 = o + d0 * r0 + F3(0, y0, 0), A1 = o + d1 * r0 + F3(0, y0, 0)
                let B0 = o + d0 * r1 + F3(0, y1, 0), B1 = o + d1 * r1 + F3(0, y1, 0)
                let slanted = abs(y1 - y0) > 1e-4 && abs(r1 - r0) > 1e-4
                if r0 < 1e-5 {
                    face([A0, B1, B0], m)
                } else if r1 < 1e-5 {
                    face([A0, A1, B0], m)
                } else {
                    face([A0, A1, B1, B0], m, flags: slanted ? KitFlag.chamfer : 0)
                }
            }
        }
    }

    /// Flat disc (top face) of radius r at height y around o, `seg` sides (floors: tile uv).
    func disc(o: F3, r: Float, y: Float, seg: Int, _ m: KitMat) {
        var pts: [F3] = []
        for i in 0..<seg {
            let a = Float(i) / Float(seg) * 2 * .pi
            pts.append(F3(o.x + cosf(a) * r, y, o.z - sinf(a) * r))
        }
        face(pts, m)
    }

    // ---------------------------------------------------------------- pieces
    /// A kit piece placed with a yaw, an optional scale (`scaleY` vertical, `scaleX` / `scaleZ` along the piece's own
    /// axes, all before the yaw) and a paint colour (KitFlag.paint faces take it).
    /// `headIndex`: the piece is beacon head k (KitFlag.head on every vertex, k in extra.w; vs_kit spins it).
    func place(_ p: KitPiece, at t: F3, yaw: Float = 0, scaleY: Float = 1, scaleX: Float = 1, scaleZ: Float = 1,
               paint: UInt32? = nil, headIndex: UInt32? = nil, caster: Bool = false) {
        let c = cosf(yaw), s = sinf(yaw)
        @inline(__always) func rot(_ v: F3) -> F3 { F3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z) }
        let base = UInt32(vertices.count)
        let paintTint: UInt32? = paint
        // non-uniform scale: positions × k, normals × 1 / k (inverse transpose), tangents × k
        let k = F3(scaleX, scaleY, scaleZ)
        let scaled = k != F3(1, 1, 1)
        for i in 0..<p.positions.count {
            let q = p.positions[i]
            let w = rot(q * k) + t
            var n = p.normals[i]
            var tg = p.tangents[i]
            if scaled {
                n /= k
                n /= max(1e-6, (n * n).sum().squareRoot())
                var tt = F3(tg.x, tg.y, tg.z) * k
                tt /= max(1e-6, (tt * tt).sum().squareRoot())
                tg = F4(tt.x, tt.y, tt.z, tg.w)
            }
            n = rot(n)
            let tr = rot(F3(tg.x, tg.y, tg.z))
            var tint = p.tint[i]
            if let pt = paintTint, (p.extra[i] >> 16) & KitFlag.paint != 0 {
                tint = KitMesh.tint(pt, metal: Float((tint >> 24) & 255) / 255)
            }
            var uv = p.uv0[i]
            if (p.extra[i] >> 16) & KitFlag.snow != 0 {
                // a drift has no trim layer, so uv0 carries the mound's own coordinates for fs_level: u along the drift
                // (−1…1 of its half length), v the height above its base (0…1 of the piece's height) — the snow thins
                // out toward the outline instead of ending in a hard pill edge
                uv = SIMD2(q.x / max(p.halfLength, 1e-3), max(0, q.y) / max(p.boundsMax.y, 1e-3))
            }
            var ex = p.extra[i]
            if let k = headIndex { ex = (ex & 0x00ff_ffff) | (KitFlag.head << 16) | ((k & 255) << 24) }
            _ = add(KitVertex(px: w.x, py: w.y, pz: w.z, nrm: KitMesh.snorm(n), tan: KitMesh.snorm(tr, tg.w),
                              u: uv.x, v: uv.y, uv1: p.uv1[i], tint: tint, extra: ex))
        }
        for ix in p.indices { indices.append(base + UInt32(ix)) }
        if caster { for ix in p.indices { casterIndices.append(base + UInt32(ix)) } }
    }
}

// ================================================================ the store
final class KitStore {
    let device: MTLDevice
    private(set) var pieces: [String: KitPiece] = [:]
    /// 2D arrays of the 4 trim layers; the AO atlas.
    private(set) var trimNormal: MTLTexture?
    private(set) var trimORM: MTLTexture?
    private(set) var aoAtlas: MTLTexture?
    private(set) var missing: [String] = []
    private(set) var bytesLoaded = 0
    /// ASTC textures could not be made (no ASTC on this GPU): flat fallbacks are bound instead.
    private(set) var astcFallback = false
    /// The kit loaded completely (pieces + textures): WorldLevel builds the station from it.
    var ready: Bool { !pieces.isEmpty && trimNormal != nil && trimORM != nil && aoAtlas != nil }

    init(device: MTLDevice) {
        self.device = device
    }

    private func url(_ name: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Kit")
    }

    /// Everything, synchronously (call off the main thread). Returns a one-line summary for the log. The three
    /// textures go up in ONE blit command buffer with one wait (each wait can sit behind the loading cover's frames).
    func loadAll(queue: MTLCommandQueue?) -> String {
        let t0 = FrameTimer.now()
        if let u = url("station", "ihk"), let d = try? Data(contentsOf: u) {
            bytesLoaded += d.count
            if let err = parseIHK(d) { missing.append("station.ihk (\(err))") }
        } else {
            missing.append("station.ihk")
        }
        let tPieces = FrameTimer.now()
        let astc = device.supportsFamily(.apple2)
        astcFallback = !astc
        let cb = queue?.makeCommandBuffer()
        let blit = cb?.makeBlitCommandEncoder()
        trimNormal = loadIHT("trim_normal", blit: blit, astc: astc, fallback: [128, 128, 255, 128])
        trimORM = loadIHT("trim_orm", blit: blit, astc: astc, fallback: [255, 150, 180, 70])
        aoAtlas = loadIHT("kit_ao", blit: blit, astc: astc, fallback: [255, 255, 255, 255])
        blit?.endEncoding()
        let tEncode = FrameTimer.now()
        cb?.commit()
        cb?.waitUntilCompleted()
        let t1 = FrameTimer.now()
        var tris = 0
        for p in pieces.values { tris += p.triangles }
        return String(format: "kit %d pieces (%d triangles), trims %@, %.1f MB in %.0f ms (pieces %.0f, textures read %.0f, GPU upload wait %.0f)",
                      pieces.count, tris, astc ? "ASTC" : "FLAT (no ASTC on this GPU)", Double(bytesLoaded) / 1_048_576,
                      (t1 - t0) * 1000, (tPieces - t0) * 1000, (tEncode - tPieces) * 1000, (t1 - tEncode) * 1000)
            + (missing.isEmpty ? "" : " MISSING: " + missing.joined(separator: ", "))
    }

    // ---------------------------------------------------------------- IHK1
    private func parseIHK(_ data: Data) -> String? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            guard let base = raw.baseAddress, raw.count >= 128 else { return "short" }
            func u32(_ o: Int) -> UInt32 { UInt32(littleEndian: base.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
            func f32(_ o: Int) -> Float { Float(bitPattern: u32(o)) }
            func u16(_ o: Int) -> UInt16 { UInt16(littleEndian: base.loadUnaligned(fromByteOffset: o, as: UInt16.self)) }
            guard String(bytes: raw[0..<4], encoding: .ascii) == "IHK1", u32(4) == 1, Int(u32(8)) == raw.count else {
                return "bad header"
            }
            let npc = Int(u32(16)), pieceOff = Int(u32(20)), stride = Int(u32(24))
            let nv = Int(u32(28)), vOff = Int(u32(32)), ni = Int(u32(36)), iOff = Int(u32(40))
            guard stride == 32, vOff + nv * 32 <= raw.count, iOff + ni * 2 <= raw.count, pieceOff + npc * 96 <= raw.count else {
                return "bad layout"
            }
            for k in 0..<npc {
                let r = pieceOff + k * 96
                let nameBytes = raw[r..<(r + 32)].prefix { $0 != 0 }
                let name = String(decoding: nameBytes, as: UTF8.self)
                let fv = Int(u32(r + 32)), cv = Int(u32(r + 36)), fi = Int(u32(r + 40)), ci = Int(u32(r + 44))
                guard fv + cv <= nv, fi + ci <= ni else { return "bad piece \(name)" }
                var p = KitPiece(name: name, flags: u32(r + 48))
                p.boundsMin = F3(f32(r + 56), f32(r + 60), f32(r + 64))
                p.boundsMax = F3(f32(r + 68), f32(r + 72), f32(r + 76))
                p.positions.reserveCapacity(cv)
                for i in 0..<cv {
                    let o = vOff + (fv + i) * 32
                    p.positions.append(F3(halfToFloat(u16(o)), halfToFloat(u16(o + 2)), halfToFloat(u16(o + 4))))
                    p.normals.append(snormVec(u32(o + 8)))
                    let t = u32(o + 12)
                    let tv = snormVec(t)
                    p.tangents.append(F4(tv.x, tv.y, tv.z, Int8(bitPattern: UInt8(t >> 24)) < 0 ? -1 : 1))
                    p.uv0.append(SIMD2<Float>(halfToFloat(u16(o + 16)), halfToFloat(u16(o + 18))))
                    p.uv1.append(u32(o + 20))
                    p.tint.append(u32(o + 24))
                    p.extra.append(u32(o + 28))
                }
                p.indices.reserveCapacity(ci)
                for i in 0..<ci {
                    let ix = u16(iOff + (fi + i) * 2)
                    if Int(ix) >= cv { return "index out of range in \(name)" }
                    p.indices.append(ix)
                }
                pieces[name] = p
            }
            return nil
        }
    }

    // ---------------------------------------------------------------- IHT1
    /// An IHT1 file into a private texture: its levels are copied by `blit` from a shared staging buffer (the caller
    /// commits and waits once for all of them).
    private func loadIHT(_ name: String, blit: MTLBlitCommandEncoder?, astc: Bool, fallback: [UInt8]) -> MTLTexture? {
        guard let u = url(name, "iht"), let d = try? Data(contentsOf: u) else {
            missing.append(name + ".iht")
            return nil
        }
        bytesLoaded += d.count
        let t: MTLTexture? = d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> MTLTexture? in
            guard let base = raw.baseAddress, raw.count >= 64 else { return nil }
            func u32(_ o: Int) -> UInt32 { UInt32(littleEndian: base.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
            guard String(bytes: raw[0..<4], encoding: .ascii) == "IHT1", u32(4) == 1, Int(u32(8)) == raw.count else { return nil }
            let fmt = u32(16), w = Int(u32(20)), h = Int(u32(24)), layers = Int(u32(28)), mips = Int(u32(32)), tab = Int(u32(36))
            let pf: MTLPixelFormat
            let block: Int
            switch fmt {
            case 1: pf = .astc_4x4_ldr; block = 4
            case 2: pf = .astc_5x5_ldr; block = 5
            case 3: pf = .astc_6x6_ldr; block = 6
            case 4: pf = .astc_8x8_ldr; block = 8
            case 16: pf = .rgba8Unorm; block = 1
            default: return nil
            }
            if block > 1 && !astc { return flat(layers: layers, fallback, label: name) }
            let desc = MTLTextureDescriptor()
            desc.textureType = layers > 1 ? .type2DArray : .type2D
            desc.pixelFormat = pf
            desc.width = w
            desc.height = h
            desc.arrayLength = layers
            desc.mipmapLevelCount = mips
            desc.usage = .shaderRead
            desc.storageMode = .private
            guard let tex = device.makeTexture(descriptor: desc), let blit = blit,
                  let staging = device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared) else {
                return block > 1 ? flat(layers: layers, fallback, label: name) : nil
            }
            for L in 0..<layers {
                for m in 0..<mips {
                    let r = tab + 16 * (L * mips + m)
                    let off = Int(u32(r)), n = Int(u32(r + 4)), bpr = Int(u32(r + 8))
                    let mw = max(1, w >> m), mh = max(1, h >> m)
                    guard off + n <= raw.count else { return nil }
                    blit.copy(from: staging, sourceOffset: off, sourceBytesPerRow: bpr, sourceBytesPerImage: n,
                              sourceSize: MTLSize(width: mw, height: mh, depth: 1), to: tex, destinationSlice: L, destinationLevel: m,
                              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                }
            }
            tex.label = name
            return tex
        }
        if t == nil { missing.append(name + ".iht (unreadable)") }
        return t
    }

    /// 1×1 layers of one RGBA8 value (no ASTC on this GPU).
    private func flat(layers: Int, _ v: [UInt8], label: String) -> MTLTexture? {
        let desc = MTLTextureDescriptor()
        desc.textureType = layers > 1 ? .type2DArray : .type2D
        desc.pixelFormat = .rgba8Unorm
        desc.width = 1
        desc.height = 1
        desc.arrayLength = layers
        desc.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        for L in 0..<layers {
            v.withUnsafeBytes {
                t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: L, withBytes: $0.baseAddress!, bytesPerRow: 4,
                          bytesPerImage: 4)
            }
        }
        t.label = label + " (flat)"
        return t
    }
}

// ---------------------------------------------------------------- bit helpers
/// IEEE half → Float (no Float16: also builds where it is unavailable).
@inline(__always) func halfToFloat(_ h: UInt16) -> Float {
    let s = UInt32(h >> 15) << 31
    let e = Int((h >> 10) & 0x1f)
    let m = UInt32(h & 0x3ff)
    if e == 0 {
        if m == 0 { return Float(bitPattern: s) }
        let v = Float(m) / 1024 * powf(2, -14)
        return s != 0 ? -v : v
    }
    if e == 31 { return Float(bitPattern: s | 0x7f80_0000 | (m << 13)) }
    return Float(bitPattern: s | UInt32(e - 15 + 127) << 23 | (m << 13))
}

/// char4 snorm (xyz) → unit vector.
@inline(__always) func snormVec(_ v: UInt32) -> F3 {
    func c(_ b: UInt32) -> Float { max(-1, Float(Int8(bitPattern: UInt8(b & 255))) / 127) }
    let r = F3(c(v), c(v >> 8), c(v >> 16))
    let l = (r * r).sum().squareRoot()
    return l > 1e-6 ? r / l : F3(0, 1, 0)
}
