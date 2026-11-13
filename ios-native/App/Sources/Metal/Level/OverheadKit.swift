import Foundation
import IceHiveCore

// ================================================================
//  OVERHEAD KIT — the geometry of the overhead layer (Stage 1 R3
//  «Overhead render»; design.md §1.1.1–1.1.2, tech.md §2.4, the
//  concept-station proof): every route of `level.layout.overhead`
//  extruded at runtime on the station's trim sheets, plus the kit's
//  small overhead pieces (tools/blender/kit/pieces.py `oh_*`) and the
//  supports that carry it. The route line is the TOP of what the bugs
//  ride (a bug's feet stand on the route height: they ride ON TOP, the
//  only readable choice from the 57° camera).
//    pipe     a rack of 2–3 pipes (the main one on the route line, the
//             others toward the void side), flanges every 6 m, shoes
//             on the supports, a handwheel valve on long racks; over
//             walkable deck only the main pipe and a thin conduit
//    cable    a bundle of three thin cables with the route's sag (the
//             simulation's curve), clamps at both ends; its vertices
//             carry their mid-span weight for the sway (uv1)
//    tray     an open ladder tray (side rails, rungs, cables lying in
//             it): the bugs walk on the rungs, half behind the rails
//    catwalk  a grated walkway with stringers, the cyan strip on its
//             outer faces (the station's light language) and railings
//    duct     a 0.9 × 0.7 m duct with ribs; a duct mouth (grille with
//             amber slats under a hood) at a `ductMouth` node
//    arm      an edge from a node over the void to a `gantry` standing
//             over walkable deck: a cantilever girder (the crossing the
//             concept recommends: thin, from a far-side post)
//  Supports: abyss risers (a column from the abyss: packs climb it),
//  deck posts, and posts from the abyss under racks / joints / spans
//  over the void (≥ 3.5–4.5 m apart, from 50 m down: the station's
//  piers), each with a head under the run. A rack's dead end over open
//  void runs on 24 m into the dark (render only: a pipe bridge to
//  another block). The upper truss (decoration, deck + 11 m: a lattice
//  girder along every big deck) is built into its own chunk class.
//  Nothing here exists on a station without routes.
// ================================================================

/// Builds the overhead's meshes per 16 m cell and chunk class (0 = the routes and their supports, 1 = the upper truss).
final class OverheadBuild {
    static let cellSize: Float = 16
    static let cellsPerSide = Int(256 / OverheadBuild.cellSize)
    typealias Frame = (dir: F3, side: F3, len: Float)

    let level: Level
    let layout: OverheadLayout
    let pieces: [String: KitPiece]
    /// Class → cell key → mesh (Stage 2 B5: the Manifold's trunks take classes 2…9 — ManifoldBuild).
    private(set) var cells = [[Int: KitMesh]](repeating: [:], count: ManifoldBuild.classes)
    /// Swaying cables: edge index → (cable slot 0…63, unit plan perpendicular toward the void).
    private(set) var cables: [Int: (slot: Int, perp: F3)] = [:]
    /// Grid lights the overhead brings (duct-mouth glow): position, linear colour.
    var lights: [(F3, F3)] = []
    /// Built: metres per kind, supports, pieces placed, truss girders, cantilever arms.
    var metres = [Float](repeating: 0, count: RouteKind.allCases.count)
    var supports = 0, piecesPlaced = 0, trussGirders = 0, arms = 0

    // palette (sRGB): dark kit steel — the darker grade of vs_overhead takes it further down
    enum Col {
        static let rust: UInt32 = 0x6a5a44, girder: UInt32 = 0x1f262e, steelL: UInt32 = 0x6a7784, steelD: UInt32 = 0x29313a
        static let support: UInt32 = 0x1a2129, cable: UInt32 = 0x161b21, cable2: UInt32 = 0x23282f, deck: UInt32 = 0x4b5664
        static let rail: UInt32 = 0x73808c, cyan: UInt32 = 0x38d8ff, amber: UInt32 = 0xffa21a, valve: UInt32 = 0x6e1d1d
    }

    init(level: Level, pieces: [String: KitPiece]) {
        self.level = level
        self.layout = level.layout.overhead
        self.pieces = pieces
    }

    // ---------------------------------------------------------------- cells
    @inline(__always) static func key(_ x: Float, _ z: Float) -> Int {
        let n = OverheadBuild.cellsPerSide
        let i = max(0, min(n - 1, Int(((x + 128) / OverheadBuild.cellSize).rounded(.down))))
        let j = max(0, min(n - 1, Int(((z + 128) / OverheadBuild.cellSize).rounded(.down))))
        return j * n + i
    }

    func mesh(_ cls: Int, _ x: Float, _ z: Float) -> KitMesh {
        let k = OverheadBuild.key(x, z)
        if let m = cells[cls][k] { return m }
        let m = KitMesh(reserve: 2048)
        cells[cls][k] = m
        return m
    }

    // ---------------------------------------------------------------- level queries
    @inline(__always) private func overDeck(_ x: Float, _ z: Float) -> Bool {
        level.walkValue(level.cellOf(x, z)) != 0
    }

    // ---------------------------------------------------------------- edges
    private func ends(_ e: RouteEdge) -> (F3, F3) {
        let a = layout.nodes[Int(e.a)].p, b = layout.nodes[Int(e.b)].p
        return (F3(a.x, a.y, a.z), F3(b.x, b.y, b.z))
    }

    /// The route point at u (0…1) along an edge with its sag (the simulation's curve).
    @inline(__always) private func at(_ A: F3, _ B: F3, _ sag: Float, _ u: Float) -> F3 {
        var p = A + (B - A) * u
        p.y -= 4 * sag * u * (1 - u)
        return p
    }

    /// Unit plan direction of a → b, its perpendicular toward the void (the side with less walkable deck within 2 m; a tie
    /// goes up-screen, −x −z: the far side, where the image of what hangs there falls into the void), the length.
    private func frame(_ A: F3, _ B: F3) -> Frame {
        var d = F3(B.x - A.x, 0, B.z - A.z)
        let l = (d * d).sum().squareRoot()
        d = l > 1e-4 ? d / l : F3(1, 0, 0)
        var n = F3(-d.z, 0, d.x)
        var plus = 0, minus = 0
        for t: Float in [0.1, 0.3, 0.5, 0.7, 0.9] {
            let p = A + (B - A) * t
            for o: Float in [0.9, 1.8] {
                if overDeck(p.x + n.x * o, p.z + n.z * o) { plus += 1 }
                if overDeck(p.x - n.x * o, p.z - n.z * o) { minus += 1 }
            }
        }
        if plus > minus || (plus == minus && n.x + n.z > 0) { n = -n }
        let L = B - A
        return (d, n, (L * L).sum().squareRoot())
    }

    /// Any of the samples every metre along a → b, offset by each of `offs` m toward `side`, over walkable deck.
    private func crossesDeck(_ A: F3, _ B: F3, _ side: F3, _ offs: [Float]) -> Bool {
        let L = ((B - A) * (B - A)).sum().squareRoot()
        let n = max(1, Int(L.rounded(.up)))
        for k in 0...n {
            let p = A + (B - A) * (Float(k) / Float(n))
            for o in offs where overDeck(p.x + side.x * o, p.z + side.z * o) { return true }
        }
        return false
    }

    /// The line from P along `dir` for `len` m stays clear of every walkable deck (2 m to either side).
    private func clearVoid(_ P: F3, _ dir: F3, _ len: Float) -> Bool {
        let n = F3(-dir.z, 0, dir.x)
        var t: Float = 1
        while t <= len {
            let q = P + dir * t
            for o: Float in [-2, 0, 2] where overDeck(q.x + n.x * o, q.z + n.z * o) { return false }
            t += 1.5
        }
        return true
    }

    // ---------------------------------------------------------------- the build
    func build() {
        if layout.isEmpty { return }
        // (Stage 2 B5: the Manifold's routes are its trunks, ring duct and mouths — B2's kit in B4's layout)
        if let A = level.layout.manifold { ManifoldBuild(self, A).build(); return }
        var cableSlot = 0
        // supports: always under risers, deck posts, arm bases, gantries / duct mouths over the void; then junctions and
        // spans, each at least `gap` m from the ones already standing
        var standing: [F3] = []
        func support(_ p: F3, side: F3, along: F3, centred: Bool, always: Bool, gap: Float) {
            if !always && standing.contains(where: { ($0.x - p.x) * ($0.x - p.x) + ($0.z - p.z) * ($0.z - p.z) < gap * gap }) { return }
            if overDeck(p.x, p.z) { return }
            standing.append(p)
            post(p, side: side, along: along, centred: centred, from: nil)
        }
        let N = layout.nodes
        var degree = [Int](repeating: 0, count: N.count)
        var armBase = [Bool](repeating: false, count: N.count)
        // per node: the frame of one of its edges (a non-cable edge when it has one) and whether that edge is centred on
        // the route (trays, catwalks, ducts) rather than a rack hanging toward the void
        var nodeDir = [F3](repeating: F3(1, 0, 0), count: N.count)
        var nodeSide = [F3](repeating: F3(0, 0, -1), count: N.count)
        var nodeCentred = [Bool](repeating: false, count: N.count)
        var nodeRank = [Int](repeating: 0, count: N.count)
        for e in layout.edges {
            degree[Int(e.a)] += 1
            if e.b != e.a { degree[Int(e.b)] += 1 }
            let g = gantryEnd(e)
            if g >= 0 && e.kind != .cable { armBase[g == Int(e.a) ? Int(e.b) : Int(e.a)] = true }
        }
        for (k, e) in layout.edges.enumerated() {
            let (A, B) = ends(e)
            let f = frame(A, B)
            if f.len < 0.05 { continue }
            metres[Int(e.kind.rawValue)] += f.len
            let rank = e.kind == .cable ? 1 : 2
            for n in [Int(e.a), Int(e.b)] where nodeRank[n] < rank {
                nodeDir[n] = f.dir; nodeSide[n] = f.side; nodeCentred[n] = e.kind != .pipe && e.kind != .cable; nodeRank[n] = rank
            }
            let g = gantryEnd(e)
            if g >= 0 && e.kind != .cable {
                arm(base: g == Int(e.a) ? B : A, tip: g == Int(e.a) ? A : B)
                continue
            }
            switch e.kind {
            case .pipe: rack(A, B, f)
            case .cable:
                var slot = -1
                if cableSlot < 64 { slot = cableSlot; cableSlot += 1; cables[k] = (slot, f.side) }
                cable(A, B, e.sag, f, slot: slot)
            case .tray: tray(A, B, f)
            case .catwalk: catwalk(A, B, f)
            case .duct: duct(A, B, f, mouthA: N[Int(e.a)].kind == .ductMouth, mouthB: N[Int(e.b)].kind == .ductMouth)
            }
            // spans over the void: supports every ≤ 7.5 m (cables hang free between their anchors)
            if e.kind != .cable {
                let n = max(1, Int((f.len / 7.5).rounded(.up)))
                if n > 1 {
                    for s in 1..<n {
                        support(at(A, B, e.sag, Float(s) / Float(n)), side: f.side, along: f.dir, centred: e.kind != .pipe, always: false,
                                gap: 3.5)
                    }
                }
            }
            // a rack's dead end over open void runs on into the dark (render only: a pipe bridge to another block)
            if e.kind == .pipe {
                for (n, P, other) in [(Int(e.b), B, A), (Int(e.a), A, B)] where degree[n] == 1 && N[n].kind == .joint {
                    var out = P - other
                    out.y = 0
                    let ol = (out * out).sum().squareRoot()
                    if ol > 0.1 && clearVoid(P, out / ol, 24) { runOn(P, dir: out / ol, side: f.side, len: 24) }
                }
            }
        }
        // nodes
        for (n, nd) in N.enumerated() where degree[n] > 0 {
            let p = F3(nd.p.x, nd.p.y, nd.p.z)
            switch nd.kind {
            case .abyssRiser:
                riserColumn(p, from: nd.riserFrom - 40, side: nodeSide[n], along: nodeDir[n], centred: nodeCentred[n])
                standing.append(p)
            case .deckPost:
                deckPost(p, deck: nd.riserFrom, side: nodeSide[n], along: nodeDir[n], centred: nodeCentred[n])
                standing.append(p)
            case .mast:
                mast(p, base: nd.riserFrom)
                standing.append(p)
            case .ductMouth:
                support(p, side: nodeSide[n], along: nodeDir[n], centred: true, always: true, gap: 0)
            case .gantry, .perch:
                // (Stage 1 R4: an authored perch point stands on its own support, like a gantry head)
                support(p, side: nodeSide[n], along: nodeDir[n], centred: nodeCentred[n], always: true, gap: 0)
            case .joint:
                if armBase[n] { support(p, side: nodeSide[n], along: nodeDir[n], centred: nodeCentred[n], always: true, gap: 0) }
            }
        }
        for pass in 0..<2 {
            for (n, nd) in N.enumerated() where nd.kind == .joint && !armBase[n] && (pass == 0 ? degree[n] >= 3 : (degree[n] > 0 && degree[n] < 3)) {
                let p = F3(nd.p.x, nd.p.y, nd.p.z)
                support(p, side: nodeSide[n], along: nodeDir[n], centred: nodeCentred[n], always: false, gap: 4.5)
                if pass == 0 { junctionBox(p, along: nodeDir[n]) }
            }
        }
        upperTruss()
    }

    /// The gantry end of an edge whose other end is over the void while the gantry stands over walkable deck (a cantilever
    /// arm), -1 otherwise.
    private func gantryEnd(_ e: RouteEdge) -> Int {
        for n in [Int(e.a), Int(e.b)] {
            let nd = layout.nodes[n]
            if nd.kind == .gantry && overDeck(nd.p.x, nd.p.z) {
                let o = layout.nodes[n == Int(e.a) ? Int(e.b) : Int(e.a)]
                if !overDeck(o.p.x, o.p.z) { return n }
            }
        }
        return -1
    }

    // ---------------------------------------------------------------- materials
    private func pipeMat(_ tint: UInt32, _ strip: Int = Trim.pipe) -> KitMat {
        KitMat(tint: tint, metal: 0.75, layer: Trim.pipes, flags: KitFlag.frost, uv: .strip(strip, F3(1, 0, 0)))
    }
    private var girderMat: KitMat {
        KitMat(tint: Col.girder, metal: 0.7, layer: Trim.rails, flags: KitFlag.frost, uv: .strip(Trim.girder, F3(1, 0, 0)))
    }
    private var postMat: KitMat {
        KitMat(tint: Col.support, metal: 0.6, layer: Trim.rails, flags: KitFlag.frost, uv: .strip(Trim.column, F3(0, 1, 0)))
    }
    private func light(_ c: UInt32, _ k: Float) -> KitMat { KitMat(tint: c, metal: 0, emis: k, layer: Trim.none, flags: KitFlag.strip, uv: .none) }

    /// The yaw that turns a kit piece's +x along `d` (KitMesh.place).
    @inline(__always) private func yawOf(_ d: F3) -> Float { atan2f(-d.z, d.x) }

    // ---------------------------------------------------------------- pipes
    private func rack(_ A: F3, _ B: F3, _ f: Frame) {
        let m = mesh(0, (A.x + B.x) / 2, (A.z + B.z) / 2)
        let full = !crossesDeck(A, B, f.side, [0, 0.45, 0.85])
        // (offset toward the void, radius, centre below the route, tint, strip)
        let set: [(Float, Float, Float, UInt32, Int)] = full
            ? [(0, 0.2, 0.2, Col.rust, Trim.pipe), (0.44, 0.13, 0.27, Col.girder, Trim.pipe), (0.76, 0.08, 0.22, Col.steelL, Trim.cables)]
            : [(0, 0.17, 0.17, Col.rust, Trim.pipe), (0.3, 0.06, 0.14, Col.steelL, Trim.cables)]
        for (off, r, dy, tint, strip) in set {
            let o = f.side * off - F3(0, dy, 0)
            m.tube(A + o, B + o, r: r, seg: r >= 0.12 ? 10 : 7, pipeMat(tint, strip))
        }
        // flanges every 6 m on the main pipe
        let r0 = set[0].1, dy0 = set[0].2
        var t: Float = 3
        while t < f.len - 1 {
            let c = A + (B - A) * (t / f.len) - F3(0, dy0, 0)
            m.tube(c - f.dir * 0.05, c + f.dir * 0.05, r: r0 + 0.04, seg: 10, pipeMat(Col.steelD, Trim.flange))
            t += 6
        }
        // a handwheel valve on a long rack over the void (one per edge, a third of the way along), on the main pipe's top
        if full && f.len >= 9, let v = pieces["oh_valve"] {
            m.place(v, at: A + (B - A) * 0.37, yaw: yawOf(f.dir), paint: Col.valve)
            piecesPlaced += 1
        }
    }

    /// The pipes of a rack running on from a dead end into the void (render only), on posts every 7 m.
    private func runOn(_ P: F3, dir: F3, side s0: F3, len: Float) {
        let E = P + dir * len
        var side = F3(-dir.z, 0, dir.x)
        if (side * s0).sum() < 0 { side = -side }
        let m = mesh(0, (P.x + E.x) / 2, (P.z + E.z) / 2)
        for (off, r, dy, tint, strip) in [(Float(0), Float(0.2), Float(0.2), Col.rust, Trim.pipe), (0.44, 0.13, 0.27, Col.girder, Trim.pipe),
                                          (0.76, 0.08, 0.22, Col.steelL, Trim.cables)] {
            let o = side * off - F3(0, dy, 0)
            m.tube(P + o, E + o, r: r, seg: r >= 0.12 ? 10 : 7, pipeMat(tint, strip))
        }
        var t: Float = 7
        while t < len {
            post(P + dir * t, side: side, along: dir, centred: false, from: nil)
            t += 7
        }
    }

    // ---------------------------------------------------------------- cables
    private func cable(_ A: F3, _ B: F3, _ sag: Float, _ f: Frame, slot: Int) {
        let m = mesh(0, (A.x + B.x) / 2, (A.z + B.z) / 2)
        let n = max(4, Int((f.len / 1.0).rounded(.up)))
        let perp = f.side
        // (lateral offset, centre below the route, radius, tint)
        let strands: [(Float, Float, Float, UInt32)] = [(0, 0.045, 0.045, Col.cable), (0.09, 0.05, 0.035, Col.cable2), (-0.08, 0.07, 0.03, Col.cable)]
        for (lat, dy, r, tint) in strands {
            let mat = KitMat(tint: tint, metal: 0.15, layer: Trim.pipes, flags: KitFlag.frost, uv: .strip(Trim.cables, F3(1, 0, 0)))
            for s in 0..<n {
                let u0 = Float(s) / Float(n), u1 = Float(s + 1) / Float(n)
                let p0 = at(A, B, sag, u0) + perp * lat - F3(0, dy, 0)
                let p1 = at(A, B, sag, u1) + perp * lat - F3(0, dy, 0)
                let v0 = m.vertices.count
                m.tube(p0, p1, r: r, seg: 6, mat, caps: s == 0 || s == n - 1)
                if slot >= 0 { swayWeights(m, from: v0, p0, p1, u0, u1, slot: slot) }
            }
        }
        // clamps at both ends
        if let c = pieces["oh_clamp"] {
            m.place(c, at: A, yaw: yawOf(f.dir))
            m.place(c, at: B, yaw: yawOf(-f.dir))
            piecesPlaced += 2
        }
    }

    /// Cable vertices [v0, end) of a segment p0 → p1 (u0 → u1 along the span) carry their sway weight 4u(1 − u) and the
    /// cable slot in uv1 (WorldOverhead's sway table; runtime faces have no AO, so uv1 is free).
    private func swayWeights(_ m: KitMesh, from v0: Int, _ p0: F3, _ p1: F3, _ u0: Float, _ u1: Float, slot: Int) {
        let d = p1 - p0
        let l2 = max(1e-6, (d * d).sum())
        for i in v0..<m.vertices.count {
            let v = m.vertices[i]
            let t = clampf(((F3(v.px, v.py, v.pz) - p0) * d).sum() / l2, 0, 1)
            let u = u0 + (u1 - u0) * t
            m.vertices[i].uv1 = unorm16(4 * u * (1 - u)) | UInt32(slot + 1) << 16
        }
    }

    // ---------------------------------------------------------------- trays, catwalks, ducts
    private func tray(_ A: F3, _ B: F3, _ f: Frame) {
        let m = mesh(0, (A.x + B.x) / 2, (A.z + B.z) / 2)
        let lat = KitMat(tint: Col.steelL, metal: 0.6, layer: Trim.pipes, flags: KitFlag.frost, uv: .strip(Trim.lattice, F3(1, 0, 0)))
        let n = F3(-f.dir.z, 0, f.dir.x)
        for s: Float in [-0.3, 0.3] {
            m.beam(A + n * s + F3(0, 0.02, 0), B + n * s + F3(0, 0.02, 0), w: 0.04, h: 0.1, c: 0, lat)
        }
        var t: Float = 0.2
        while t < f.len - 0.1 {
            let c = A + (B - A) * (t / f.len) - F3(0, 0.0125, 0)
            m.beam(c - n * 0.3, c + n * 0.3, w: 0.035, h: 0.025, c: 0, lat, bottom: false)
            t += 0.45
        }
        for (o, r, tint) in [(Float(-0.15), Float(0.035), Col.cable), (0.0, 0.04, Col.cable2), (0.13, 0.03, Col.cable)] {
            let mat = KitMat(tint: tint, metal: 0.15, layer: Trim.pipes, flags: KitFlag.frost, uv: .strip(Trim.cables, F3(1, 0, 0)))
            m.tube(A + n * o + F3(0, r, 0), B + n * o + F3(0, r, 0), r: r, seg: 6, mat)
        }
    }

    private func catwalk(_ A: F3, _ B: F3, _ f: Frame) {
        let m = mesh(0, (A.x + B.x) / 2, (A.z + B.z) / 2)
        let n = F3(-f.dir.z, 0, f.dir.x)
        let h: Float = 0.45
        // the grating (top face, tile uv; no snow crust: a pale 0.9 m deck would out-shine the layer — its rails carry it)
        var q = [A - n * h, A + n * h, B + n * h, B - n * h]
        if Mat4.cross(q[1] - q[0], q[2] - q[0]).y < 0 { q.reverse() }
        m.face(q, KitMat(tint: Col.deck, metal: 0.3, layer: Trim.gratings))
        let skirt = KitMat(tint: Col.steelD, metal: 0.75, layer: Trim.rails, uv: .strip(Trim.skirt, F3(1, 0, 0)))
        for s: Float in [-1, 1] {
            let o = n * (s * (h + 0.04))
            m.beam(A + o - F3(0, 0.15, 0), B + o - F3(0, 0.15, 0), w: 0.08, h: 0.3, c: 0.02, skirt)
            // the cyan strip in the stringer's outer face (the station's light language for a walkable edge — the hive's)
            let so = n * (s * (h + 0.085))
            m.beam(A + so - F3(0, 0.1, 0), B + so - F3(0, 0.1, 0), w: 0.012, h: 0.03, c: 0, light(Col.cyan, 2.2))
        }
        // railings: posts every 2 m, a top and a mid rail, both sides
        let rail = KitMat(tint: Col.rail, metal: 0.7, layer: Trim.rails, uv: .strip(Trim.railbar, F3(1, 0, 0)))
        let postM = KitMat(tint: Col.steelL, metal: 0.7, layer: Trim.rails, uv: .strip(Trim.brushed, F3(0, 1, 0)))
        let k = max(1, Int((f.len / 2).rounded()))
        for s: Float in [-1, 1] {
            let o = n * (s * (h - 0.03))
            m.tube(A + o + F3(0, 1.0, 0), B + o + F3(0, 1.0, 0), r: 0.03, seg: 6, rail)
            m.tube(A + o + F3(0, 0.55, 0), B + o + F3(0, 0.55, 0), r: 0.02, seg: 5, rail, caps: false)
            for i in 0...k {
                let c = A + (B - A) * (Float(i) / Float(k)) + o
                m.beam(c, c + F3(0, 1.02, 0), w: 0.05, h: 0.05, c: 0, postM)
            }
        }
    }

    private func duct(_ A: F3, _ B: F3, _ f: Frame, mouthA: Bool, mouthB: Bool) {
        let m = mesh(0, (A.x + B.x) / 2, (A.z + B.z) / 2)
        // (the body without the snow crust — a 0.9 m pale top would out-shine the layer; the ribs carry it: pale bands
        // across a dark duct)
        let body = KitMat(tint: Col.steelD, metal: 0.55, layer: Trim.panels)
        m.beam(A - F3(0, 0.35, 0), B - F3(0, 0.35, 0), w: 0.9, h: 0.7, c: 0.05, body)
        let fins = KitMat(tint: Col.steelD, metal: 0.6, layer: Trim.pipes, flags: KitFlag.frost, uv: .strip(Trim.fins, F3(1, 0, 0)))
        var t: Float = 1.2
        while t < f.len - 0.4 {
            let c = A + (B - A) * (t / f.len) - F3(0, 0.35, 0)
            m.beam(c - f.dir * 0.05, c + f.dir * 0.05, w: 0.98, h: 0.78, c: 0.02, fins)
            t += 2.5
        }
        // the mouth (a grille with amber slats under a hood) at a duct-mouth end, facing out along the duct
        for (P, out, on) in [(A, -f.dir, mouthA), (B, f.dir, mouthB)] where on {
            if let mp = pieces["oh_duct_mouth"] {
                m.place(mp, at: P, yaw: yawOf(out))
                piecesPlaced += 1
            } else {
                m.beam(P - F3(0, 0.35, 0) - out * 0.02, P - F3(0, 0.35, 0) + out * 0.04, w: 0.96, h: 0.76, c: 0.02, body)
                for i in 0..<4 {
                    let y = P.y - 0.62 + 0.16 * Float(i)
                    m.beam(F3(P.x, y, P.z) + out * 0.06, F3(P.x, y, P.z) + out * 0.07, w: 0.8, h: 0.05, c: 0, light(Col.amber, 1.6))
                }
            }
            lights.append((P + out * 0.8 - F3(0, 0.35, 0), linearRGB(0xff5a1a)))
        }
    }

    // ---------------------------------------------------------------- arms, supports
    /// A cantilever girder from a node over the void out to a gantry over the walkway (its top on the route), with a knee
    /// brace back to the post below its base.
    private func arm(base: F3, tip: F3) {
        let m = mesh(0, (base.x + tip.x) / 2, (base.z + tip.z) / 2)
        m.beam(base - F3(0, 0.17, 0), tip - F3(0, 0.15, 0), w: 0.22, h: 0.3, c: 0.03, girderMat)
        let mid = base + (tip - base) * 0.42
        m.beam(base - F3(0, 1.6, 0), mid - F3(0, 0.3, 0), w: 0.09, h: 0.09, c: 0, girderMat)
        arms += 1
    }

    /// A post from 50 m down (or from `from`) up under the run at `p`, and a head across it.
    private func post(_ p: F3, side: F3, along: F3, centred: Bool, from: Float?) {
        let m = mesh(0, p.x, p.z)
        let bottom = from ?? (p.y - 50)
        m.beam(F3(p.x, bottom, p.z), F3(p.x, p.y - 0.55, p.z), w: 0.3, h: 0.3, c: 0.03, postMat)
        head(m, p, side: side, along: along, centred: centred)
        supports += 1
    }

    /// The head under a run: a rack's (the kit's head piece reaching toward the void side under all three pipes, a shoe
    /// under the main one) or a centred cross beam under a tray / catwalk / duct.
    private func head(_ m: KitMesh, _ p: F3, side: F3, along: F3, centred: Bool) {
        if centred {
            m.beam(F3(p.x, p.y - 0.78, p.z) - side * 0.6, F3(p.x, p.y - 0.78, p.z) + side * 0.6, w: 0.14, h: 0.14, c: 0.02, girderMat)
            return
        }
        if let h = pieces["oh_head"] {
            m.place(h, at: F3(p.x, p.y - 0.42, p.z), yaw: yawOf(side))
            piecesPlaced += 1
        } else {
            m.beam(F3(p.x, p.y - 0.5, p.z) - side * 0.35, F3(p.x, p.y - 0.5, p.z) + side * 1.0, w: 0.16, h: 0.16, c: 0.02, girderMat)
        }
        if let s = pieces["oh_shoe"] {
            m.place(s, at: F3(p.x, p.y - 0.4, p.z), yaw: yawOf(along))
            piecesPlaced += 1
        }
    }

    /// An abyss riser: the column the packs climb, out of the dark up under the run.
    private func riserColumn(_ p: F3, from: Float, side: F3, along: F3, centred: Bool) {
        let m = mesh(0, p.x, p.z)
        m.beam(F3(p.x, from, p.z), F3(p.x, p.y - 0.55, p.z), w: 0.5, h: 0.5, c: 0.06, postMat)
        head(m, p, side: side, along: along, centred: centred)
        supports += 1
    }

    /// A post standing on a deck at a run's end (the way down for the hive), a base plate and the head.
    private func deckPost(_ p: F3, deck: Float, side: F3, along: F3, centred: Bool) {
        let m = mesh(0, p.x, p.z)
        m.beam(F3(p.x, deck, p.z), F3(p.x, p.y - 0.55, p.z), w: 0.26, h: 0.26, c: 0.03, postMat)
        m.cbox(o: F3(p.x, deck + 0.03, p.z), w: 0.5, h: 0.06, d: 0.5, c: 0.015,
               KitMat(tint: Col.steelD, metal: 0.6, layer: Trim.panels, flags: KitFlag.frost), bottom: false)
        head(m, p, side: side, along: along, centred: centred)
        supports += 1
    }

    /// A lattice mast (guy-cable anchor): four legs tapering 3 m past the node, bracing, a red lamp on top.
    private func mast(_ p: F3, base: Float) {
        let m = mesh(0, p.x, p.z)
        let top = p.y + 3
        let lat = KitMat(tint: Col.steelD, metal: 0.5, layer: Trim.pipes, flags: KitFlag.frost, uv: .strip(Trim.lattice, F3(0, 1, 0)))
        let corners: [(Float, Float)] = [(1, 1), (-1, 1), (-1, -1), (1, -1)]
        func leg(_ k: Int, _ y: Float) -> F3 {
            let r = 0.45 - 0.3 * (y - base) / max(1, top - base)
            return F3(p.x + corners[k % 4].0 * r, y, p.z + corners[k % 4].1 * r)
        }
        for k in 0..<4 { m.beam(leg(k, base), leg(k, top), w: 0.07, h: 0.07, c: 0, lat) }
        var y = base + 1.5
        while y < top {
            for k in 0..<4 { m.beam(leg(k, y), leg(k + 1, y), w: 0.04, h: 0.04, c: 0, lat) }
            y += 1.5
        }
        m.cbox(o: F3(p.x, top + 0.06, p.z), w: 0.12, h: 0.1, d: 0.12, c: 0, light(0xff2a3a, 3))
        supports += 1
    }

    private func junctionBox(_ p: F3, along: F3) {
        guard let j = pieces["oh_junction"] else { return }
        mesh(0, p.x, p.z).place(j, at: F3(p.x, p.y - 0.42, p.z), yaw: yawOf(along))
        piecesPlaced += 1
    }

    // ---------------------------------------------------------------- the upper truss (decoration, class 1)
    /// One lattice girder 11 m above every big deck that carries no beacon (≥ 12 m both ways; a beacon's light column and
    /// the punch-in framing stay clear), along z and 6 m past both ends: Kelvin-9's corridors run along x, so the girders
    /// cross them instead of adding more parallel lines (concept-station README «what to avoid»). Thin, dark, no lights —
    /// a plane that slides at ≈ 1.45× the deck's speed (design §1.1.7). Not over the start deck (Stage 1 R5): the title's
    /// composition and the mission's first frames (tech.md §2.2's exclusion; R3's look call — at 11 m over the pad, close to
    /// the camera, it was a broad dark band across the frame); on Kelvin-9 the girders stand over the hub and the plaza.
    private func upperTruss() {
        // (no frost flag: no pale crust on the chords — the truss stays a dark silhouette high over the deck)
        let mat = KitMat(tint: Col.girder, metal: 0.6, layer: Trim.rails, uv: .strip(Trim.girder, F3(1, 0, 0)))
        let web = KitMat(tint: Col.support, metal: 0.6, layer: Trim.pipes, uv: .strip(Trim.lattice, F3(1, 0, 0)))
        for r in level.layout.rects {
            let w = r.x1 - r.x0, d = r.z1 - r.z0
            guard w >= 12 && d >= 12, !r.height.isStairs else { continue }
            if level.layout.beacons.contains(where: { $0.x >= r.x0 && $0.x <= r.x1 && $0.z >= r.z0 && $0.z <= r.z1 }) { continue }
            let st = level.layout.start
            if st.x > r.x0 && st.x < r.x1 && st.y > r.z0 && st.y < r.z1 { continue }
            let y = max(r.height.height(atZ: r.z0), r.height.height(atZ: r.z1)) + 11
            let A = F3((r.x0 + r.x1) / 2, y, r.z0 - 6), B = F3((r.x0 + r.x1) / 2, y, r.z1 + 6)
            let L = ((B - A) * (B - A)).sum().squareRoot()
            let dir = (B - A) / L
            let steps = max(2, Int((L / 2).rounded()))
            // two chords and the web per 2 m bay (each bay in its own 16 m cell: the cutaway takes only the near part)
            for s in 0..<steps {
                let p0 = A + dir * (L * Float(s) / Float(steps)), p1 = A + dir * (L * Float(s + 1) / Float(steps))
                let m = mesh(1, (p0.x + p1.x) / 2, (p0.z + p1.z) / 2)
                m.beam(p0, p1, w: 0.16, h: 0.16, c: 0.02, mat)
                m.beam(p0 - F3(0, 0.8, 0), p1 - F3(0, 0.8, 0), w: 0.14, h: 0.14, c: 0.02, mat)
                m.beam(p0 - F3(0, 0.8, 0), p0, w: 0.06, h: 0.06, c: 0, web)
                m.beam(s % 2 == 0 ? p0 - F3(0, 0.8, 0) : p0, s % 2 == 0 ? p1 : p1 - F3(0, 0.8, 0), w: 0.05, h: 0.05, c: 0, web)
            }
            trussGirders += 1
        }
    }
}
