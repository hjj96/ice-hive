import Foundation
import IceHiveCore

// ================================================================
//  MANIFOLD KIT — the Manifold's overhead as drawn (Stage 2 B5; B2's kit
//  pieces in B4's layout, IceHiveCore Manifold.swift; the working
//  reference: tools/blender/checks/manifold_readback.py). On a level
//  with `layout.manifold` OverheadBuild hands its routes here instead of
//  R3's generic racks:
//    trunks      the four 0.45 m pipes of the «#» at 5 m (their TOP on
//                the route line the Threader rides; pipes strip 0),
//                broken 0.68 m from each crossing's centre where
//                `mf_trunk_cross` joins them, `mf_trunk_band` every
//                3.5 m, `mf_trunk_post` on the catwalk ring at ±15 m,
//                `mf_riser_tee` above it, `mf_trunk_elbow` at the
//                abyss risers (±17.5 m) and the 0.45 m riser pipe down
//                into the abyss; each trunk's run, bands, tee, elbow and
//                valve in its own chunk class (2 + k) so the one the
//                Threader rips down disappears, and its fallen twin —
//                two halves across the deck at deck height, snapped in
//                the middle — in class 6 + k, drawn only once it fell
//                (WorldOverhead.setTrunk; their runtime faces carry a
//                sway slot: the trunk shakes while it rips, the fallen
//                one drops 4.55 m in the last 0.4 s of the warning)
//    risers      the riser pipes (0.3 m) from each leg's tee to the duct
//    ring duct   the 0.9 × 0.7 m duct square at 8 m (R3's section) between
//                `mf_duct_corner`s, `mf_duct_band` every 2.5 m, the drops
//                from the corners' outlets down to R3's `oh_duct_mouth`
//                at the ring's corners (their amber grid lights)
//    valves      R6's four steam valves on the trunks (body on the
//                trunk's camera flank, red handwheel, the steam line under
//                the 0.9 m pipe) — in their trunk's class (WorldProps
//                leaves the Manifold's valves to this file; their lamp is
//                ThreaderLook's)
//  No upper truss (a boss arena keeps its sky for the duct), no generic
//  supports (the posts, tees and risers carry it). The pump housing and
//  the bridges' trusses are deck pieces: WorldLevel (ManifoldDecor).
// ================================================================
final class ManifoldBuild {
    static let trunkR: Float = 0.45, elbowR: Float = 0.9, ductW: Float = 0.9, ductH: Float = 0.7
    /// Chunk classes: the up trunks (2 + k), their fallen twins (6 + k); 0 the rest of the overhead, 1 the truss (none here).
    static let upClass = 2, fallenClass = 6, classes = 10
    /// WorldOverhead's sway slots of the trunks: the up trunk's shake (60 + k), the fallen trunk's drop (56 + k).
    static let shakeSlot = 60, fallSlot = 56
    /// The pipe's axis height of a fallen trunk (it lies on the deck), the gap the snap leaves in its middle (B4: 1 m each side).
    static let fallenAxis: Float = 0.45, snap: Float = 1.0
    enum Col {
        static let pipe: UInt32 = 0x5c4f3e, steelD: UInt32 = 0x29313a, steelL: UInt32 = 0x6a7784, wheel: UInt32 = 0xb3312a
        static let insul: UInt32 = 0x6f767d, brass: UInt32 = 0x8a6a3a
    }

    private unowned let b: OverheadBuild
    private let A: ManifoldArena
    private var pipeMat: KitMat { KitMat(tint: Col.pipe, metal: 0.7, layer: Trim.pipes, flags: KitFlag.frost, uv: .strip(Trim.pipe, F3(1, 0, 0))) }
    private var ductMat: KitMat { KitMat(tint: Col.steelD, metal: 0.55, layer: Trim.panels) }

    init(_ build: OverheadBuild, _ arena: ManifoldArena) {
        b = build
        A = arena
    }

    @inline(__always) private func yawOf(_ d: F3) -> Float { atan2f(-d.z, d.x) }

    private func place(_ name: String, _ cls: Int, _ at: F3, yaw: Float = 0) {
        guard let p = b.pieces[name] else { return }
        b.mesh(cls, at.x, at.z).place(p, at: at, yaw: yaw)
        b.piecesPlaced += 1
    }

    /// Vertices [v0, end) of a mesh move with WorldOverhead's sway slot `slot` at full weight (runtime faces only: kit pieces
    /// carry their baked AO in uv1).
    private func sway(_ m: KitMesh, from v0: Int, slot: Int) {
        for i in v0..<m.vertices.count where m.vertices[i].extra >> 24 == 0 {
            m.vertices[i].uv1 = 65535 | UInt32(slot + 1) << 16
        }
    }

    // ---------------------------------------------------------------- the build
    func build() {
        let y = A.trunkHeight
        for (k, tr) in A.trunks.enumerated() {
            let along = tr.dir
            let d3 = F3(along.x, 0, along.y)
            let alongX = abs(along.x) > 0.5
            let yaw = yawOf(d3)
            let cls = ManifoldBuild.upClass + k
            // the trunk's line: u from −(riser) to +(riser) about the arena's centre along its direction
            let half = tr.length / 2
            let mid = tr.point(half)
            func P(_ u: Float) -> F3 { F3(mid.x + along.x * u, y, mid.y + along.y * u) }
            // its runs, broken 0.68 m from each crossing's centre
            let cross: [Float] = A.trunks.compactMap { o in
                let oa = abs(o.dir.x) > 0.5
                if oa == alongX { return nil }
                return (oa ? o.point(o.length / 2).y : o.point(o.length / 2).x)
            }.sorted()
            var cuts: [Float] = [-half]
            for c in cross { cuts += [c - 0.68, c + 0.68] }
            cuts.append(half)
            for i in stride(from: 0, to: cuts.count - 1, by: 2) {
                let m = b.mesh(cls, (P(cuts[i]).x + P(cuts[i + 1]).x) / 2, (P(cuts[i]).z + P(cuts[i + 1]).z) / 2)
                let v0 = m.vertices.count
                m.tube(P(cuts[i]) - F3(0, ManifoldBuild.trunkR, 0), P(cuts[i + 1]) - F3(0, ManifoldBuild.trunkR, 0), r: ManifoldBuild.trunkR,
                       seg: 16, pipeMat, caps: false)
                sway(m, from: v0, slot: ManifoldBuild.shakeSlot + k)
            }
            b.metres[Int(RouteKind.pipe.rawValue)] += tr.length
            // bands every 3.5 m (not by a crossing or a post)
            var u = -Manifold.legAt + 1.75
            while u < Manifold.legAt {
                if cross.allSatisfy({ abs(u - $0) > 1.0 }) && abs(abs(u) - Manifold.legAt) > 0.6 { place("mf_trunk_band", cls, P(u), yaw: yaw) }
                u += 3.5
            }
            for s: Float in [-1, 1] {
                // the post on the ring (stays when the trunk falls), the tee on the trunk, the elbow at the riser
                var pp = P(s * Manifold.legAt)
                pp.y = b.level.groundY(pp.x, pp.z)
                place("mf_trunk_post", 0, pp, yaw: yaw)
                place("mf_riser_tee", cls, P(s * Manifold.legAt), yaw: yaw)
                place("mf_trunk_elbow", cls, P(s * Manifold.riserAt), yaw: s > 0 ? yaw : yaw + Float.pi)
                // the riser pipe down into the abyss from the elbow (stays)
                let e = P(s * Manifold.riserAt) + d3 * (s * ManifoldBuild.elbowR)
                let top = e - F3(0, ManifoldBuild.trunkR + ManifoldBuild.elbowR + 0.25, 0)
                b.mesh(0, top.x, top.z).tube(top, top - F3(0, 30, 0), r: ManifoldBuild.trunkR, seg: 14, pipeMat.with(uv: .strip(Trim.pipe, F3(0, 1, 0))),
                                             caps: false)
                b.supports += 1
                // the riser pipe from the tee up to the ring duct
                let leg = P(s * Manifold.legAt)
                var dp = leg * (A.ductHalf / Manifold.legAt)
                dp.y = A.ductHeight - ManifoldBuild.ductH
                b.mesh(0, leg.x, leg.z).tube(leg + F3(0, 0.38, 0), dp, r: 0.3, seg: 12, pipeMat)
            }
            fallen(k, tr)
            if tr.valve >= 0 && tr.valve < b.level.layout.props.valves.count { valve(b.level.layout.props.valves[tr.valve], cls: cls) }
        }
        // the crossings
        for x in [-Manifold.trunkOff, Manifold.trunkOff] {
            for z in [-Manifold.trunkOff, Manifold.trunkOff] { place("mf_trunk_cross", 0, F3(x, y, z)) }
        }
        ringDuct()
    }

    /// The trunk `k` as it lies after the pull-down: two halves across the deck at deck height (its pipe's bottom on the
    /// deck), snapped in the middle (B4: the island's cells 1 m either side stay open), with bands and torn flanges.
    private func fallen(_ k: Int, _ tr: ManifoldTrunk) {
        let cls = ManifoldBuild.fallenClass + k
        let half = tr.length / 2
        let mid = tr.point(half)
        let ax = ManifoldBuild.fallenAxis
        func P(_ u: Float) -> F3 { F3(mid.x + tr.dir.x * u, ax, mid.y + tr.dir.y * u) }
        let d3 = F3(tr.dir.x, 0, tr.dir.y)
        let flange = KitMat(tint: Col.steelD, metal: 0.65, layer: Trim.pipes, flags: KitFlag.frost, uv: .strip(Trim.flange, F3(1, 0, 0)))
        for (a, c) in [(-half, -ManifoldBuild.snap), (ManifoldBuild.snap, half)] {
            let m = b.mesh(cls, (P(a).x + P(c).x) / 2, (P(a).z + P(c).z) / 2)
            let v0 = m.vertices.count
            m.tube(P(a), P(c), r: ManifoldBuild.trunkR, seg: 16, pipeMat, caps: true)
            var u = a + 1.6
            while u < c - 0.6 {
                m.tube(P(u) - d3 * 0.07, P(u) + d3 * 0.07, r: ManifoldBuild.trunkR + 0.05, seg: 16, flange)
                u += 3.5
            }
            // the torn end at the snap: a wider ragged flange, slightly askew
            let e = abs(a) < abs(c) ? P(a) : P(c)
            let o = abs(a) < abs(c) ? d3 : -d3
            m.tube(e + o * 0.02, e + o * 0.16 + F3(0, 0.03, 0), r: ManifoldBuild.trunkR + 0.09, seg: 9, flange)
            sway(m, from: v0, slot: ManifoldBuild.fallSlot + k)
        }
    }

    /// R6's steam valve on its trunk: the body on the trunk's camera flank (+x +z) at the pipe's axis, the red handwheel on
    /// top of it, a gauge (its lamp: ThreaderLook), the steam line under the trunk along the curtain with nozzles down.
    private func valve(_ v: ValveSite, cls: Int) {
        let dx = v.bx - v.ax, dz = v.bz - v.az, len = max(0.1, hypotf(dx, dz))
        let u = F3(dx / len, 0, dz / len)
        let side = ManifoldBuild.cameraSide(u)
        let axisY = v.y - ManifoldBuild.trunkR
        let c = F3(v.x, axisY, v.z) + side * (ManifoldBuild.trunkR + 0.12)
        let m = b.mesh(cls, v.x, v.z)
        let steelL = KitMat(tint: Col.steelL, metal: 0.75, layer: Trim.pipes, flags: KitFlag.chamfer, uv: .strip(Trim.flange, F3(0, 1, 0)))
        m.lathe(o: c - F3(0, 0.16, 0), [(0.11, 0), (0.14, 0.04), (0.14, 0.24), (0.11, 0.28), (0.04, 0.28), (0.03, 0.42)], seg: 10, steelL)
        // a saddle back to the trunk
        m.beam(c - side * 0.13, c - side * 0.02, w: 0.16, h: 0.16, c: 0.02, steelL)
        let wheel = KitMat(tint: Col.wheel, metal: 0.35, layer: Trim.none, uv: .none)
        let wc = c + F3(0, 0.32, 0)
        m.lathe(o: wc, [(0.13, 0), (0.2, 0), (0.2, 0.035), (0.13, 0.035), (0.13, 0)], seg: 14, wheel)
        for k in 0..<3 {
            let a = Float(k) * 2 * Float.pi / 3
            let r = F3(cosf(a), 0, sinf(a))
            m.beam(wc + r * 0.03 + F3(0, 0.018, 0), wc + r * 0.15 + F3(0, 0.018, 0), w: 0.03, h: 0.025, c: 0, wheel)
        }
        // the gauge's housing (its light is drawn over it)
        m.cbox(o: ManifoldBuild.gaugeAt(v) - side * 0.03, w: 0.16, h: 0.16, d: 0.06, c: 0.01, steelL)
        // the steam line under the trunk, nozzles down every 1.5 m
        let ys = v.y - 2 * ManifoldBuild.trunkR - 0.1
        let pipe = KitMat(tint: Col.insul, metal: 0.55, layer: Trim.pipes, flags: KitFlag.frost, uv: .strip(Trim.pipe, u))
        let brass = KitMat(tint: Col.brass, metal: 0.8, layer: Trim.pipes, uv: .strip(Trim.flange, u))
        let A0 = F3(v.ax, ys, v.az), B0 = F3(v.bx, ys, v.bz)
        m.tube(A0, B0, r: 0.075, seg: 8, pipe)
        let n = max(1, Int((len / 1.5).rounded()))
        for k in 0...n {
            let p = A0 + (B0 - A0) * (Float(k) / Float(n))
            m.tube(p, p - F3(0, 0.16, 0), r: 0.034, seg: 6, brass)
        }
        // hangers from the trunk every ≈ 2 m
        for k in stride(from: 0, through: n, by: 2) {
            let p = A0 + (B0 - A0) * (Float(k) / Float(n))
            m.beam(p, p + F3(0, 0.12, 0), w: 0.04, h: 0.04, c: 0, steelL)
        }
    }

    /// The horizontal perpendicular of a plan direction that faces the camera (+x +z: the game camera never turns).
    static func cameraSide(_ u: F3) -> F3 {
        let s = F3(u.z, 0, -u.x)
        return (s.x + s.z) >= 0 ? s : -s
    }

    /// The gauge of a Manifold valve (world): on the valve body's camera face.
    static func gaugeAt(_ v: ValveSite) -> F3 {
        let dx = v.bx - v.ax, dz = v.bz - v.az, len = max(0.1, hypotf(dx, dz))
        let side = cameraSide(F3(dx / len, 0, dz / len))
        return F3(v.x, v.y - trunkR, v.z) + side * (trunkR + 0.12 + 0.17) + F3(0, 0.02, 0)
    }

    /// ThreaderLook's lamp of valve `site` on the Manifold (nil elsewhere).
    static func valveGauge(_ site: ValveSite, level: Level) -> F3? {
        guard level.layout.manifold != nil else { return nil }
        let dx = site.bx - site.ax, dz = site.bz - site.az, len = max(0.1, hypotf(dx, dz))
        return gaugeAt(site) + cameraSide(F3(dx / len, 0, dz / len)) * 0.04
    }

    /// The ring duct: four corners, the runs between them 0.66 m off each corner, bands every 2.5 m, the drops to the mouths.
    private func ringDuct() {
        let h = A.ductHalf, dy = A.ductHeight
        let corners: [(Float, Float, Float)] = [(-h, -h, 0), (h, -h, -Float.pi / 2), (h, h, Float.pi), (-h, h, Float.pi / 2)]
        for (x, z, yaw) in corners { place("mf_duct_corner", 0, F3(x, dy, z), yaw: yaw) }
        for i in 0..<4 {
            let a = F3(corners[i].0, dy, corners[i].1), c = F3(corners[(i + 1) % 4].0, dy, corners[(i + 1) % 4].1)
            let d = (c - a) / (2 * h)
            let p0 = a + d * 0.66, p1 = c - d * 0.66
            let m = b.mesh(0, (a.x + c.x) / 2, (a.z + c.z) / 2)
            m.beam(p0 - F3(0, ManifoldBuild.ductH / 2, 0), p1 - F3(0, ManifoldBuild.ductH / 2, 0), w: ManifoldBuild.ductW, h: ManifoldBuild.ductH,
                   c: 0.05, ductMat)
            b.metres[Int(RouteKind.duct.rawValue)] += 2 * h
            var t: Float = 1.6
            while t < 2 * h - 1.6 {
                place("mf_duct_band", 0, a + d * t, yaw: yawOf(d))
                t += 2.5
            }
        }
        for (sx, sz) in [(Float(-1), Float(-1)), (1, -1), (1, 1), (-1, 1)] {
            let top = F3(sx * (h - 0.6), dy - ManifoldBuild.ductH - 0.2, sz * (h - 0.6))
            let mp = A.mouths.min { hypotf($0.x - sx * h, $0.z - sz * h) < hypotf($1.x - sx * h, $1.z - sz * h) } ?? SIMD3(sx * 14.8, 4.6, sz * 14.8)
            let mouth = F3(mp.x, mp.y, mp.z)
            b.mesh(0, mouth.x, mouth.z).beam(top, mouth - F3(0, ManifoldBuild.ductH / 2, 0), w: ManifoldBuild.ductW, h: ManifoldBuild.ductH, c: 0.05, ductMat)
            let out = F3(-sx, 0, -sz) / Float(2).squareRoot()
            place("oh_duct_mouth", 0, mouth, yaw: atan2f(sz, -sx))
            b.lights.append((mouth + out * 0.8 - F3(0, 0.35, 0), linearRGB(0xff5a1a)))
        }
    }
}
