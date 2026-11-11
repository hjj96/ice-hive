import Foundation

// ================================================================
//  OVERHEAD — the second floor only the hive walks on (Stage 1 «Overhead»,
//  package R2; design.md §1.1, tech.md §2.2–2.3). Data and its index:
//   · `OverheadLayout` (`LevelLayout.overhead`): route nodes (x, ABSOLUTE y,
//     z — risers, deck posts, duct mouths, joints) and straight route edges
//     between them (pipe racks, cables, trays, catwalks, ducts). Positions
//     are quantised to 1/64 m, so a route set hashes the same everywhere;
//     the simulation and the renderer read the same values.
//   · `OverheadGraph` (`Level.overhead`): lengths, adjacency, the drop
//     windows measured against the walk grid, the spawn entries.
//   · `routeCheck`: the validation (it mirrors the generator's genCheck).
//   · `OverheadPlanner`: the post-pass that gives a generated station its
//     routes — its own random stream after genTry, so the station golden
//     vectors stay byte-identical.
//   · `OverheadLayout.kelvinSlice`: the demo / test route on «Кельвин-9»
//     (the pad → hub corridor's far rail, tech.md §2.8). The classic mission
//     has no routes until package R5 authors them (calibration unchanged).
//  Readability rules baked in (concept-station README): big runs on the FAR
//  side of a walkway (−x / −z: their image falls into the void), only thin
//  kinds over walkable deck, heights 3–9 m above the deck they serve.
// ================================================================

/// What a route edge is.
public enum RouteKind: UInt8, CaseIterable {
    case pipe = 0, cable = 1, tray = 2, catwalk = 3, duct = 4

    /// Occlusion width (m): a pipe bundle 0.3, a cable 0.08, a tray 0.6, a catwalk 1.0, a duct 0.8.
    public var width: Float {
        switch self {
        case .pipe: return 0.3
        case .cable: return 0.08
        case .tray: return 0.6
        case .catwalk: return 1.0
        case .duct: return 0.8
        }
    }
    /// × the bug's deck speed along it: cable runners race (design §1.1.3: packs on cable runs at 1.25×).
    public var speedK: Float { self == .cable ? 1.25 : 1 }
    /// Thin enough to cross over walkable deck (≤ 0.36 m; wide kinds hang over the void only).
    public var isThin: Bool { width <= 0.36 }
}

/// What a route node is.
public enum RouteNodeKind: UInt8, CaseIterable {
    /// A bend or a junction.
    case joint = 0
    /// A gantry post (a support; no way up or down).
    case gantry = 1
    /// A support column climbing out of the abyss to the route: packs climb it (a spawn entry).
    case abyssRiser = 2
    /// A post standing on a deck at a route end: the way down to that deck.
    case deckPost = 3
    /// A lattice mast (guy cables): packs climb it like a riser (a spawn entry).
    case mast = 4
    /// A duct mouth in the overhead: packs pour out of it straight onto the route (a spawn entry). Stage 1 R4: its grille
    /// rattles before a pack pours and can be shot shut (`Game.ducts`).
    case ductMouth = 5
    /// Stage 1 R4: an authored perch point for spitters (a gantry head, a catwalk end against the void). Gantries, joints,
    /// riser and mast tops against the void near a deck are perch points too (`OverheadGraph.perches`).
    case perch = 6

    /// Packs from the director's overhead channel start here.
    public var spawns: Bool { self == .abyssRiser || self == .mast || self == .ductMouth }
    /// A bug starting here climbs from `riserFrom` up to the node first.
    public var climbs: Bool { self == .abyssRiser || self == .deckPost || self == .mast }
}

/// Quantise to 1/64 m (route data is golden-hashable).
@inline(__always) func ohq(_ v: Float) -> Float { (v * 64).rounded() / 64 }

public struct RouteNode: Equatable {
    /// World x, ABSOLUTE height y, z (1/64 m).
    public var p: SIMD3<Float>
    public var kind: RouteNodeKind
    /// Risers, posts and masts: the absolute height their climb starts at (under the deck for an abyss riser, the deck
    /// for a post); the node's own height otherwise.
    public var riserFrom: Float

    public init(_ x: Float, _ y: Float, _ z: Float, _ kind: RouteNodeKind, riserFrom: Float? = nil) {
        p = SIMD3<Float>(ohq(x), ohq(y), ohq(z)); self.kind = kind; self.riserFrom = ohq(riserFrom ?? y)
    }
}

public struct RouteEdge: Equatable {
    public var a: Int32, b: Int32
    public var kind: RouteKind
    /// 0: bugs ride ON TOP (every route for now: a bug hanging under a thin cable is invisible from the 57° camera —
    /// concept-station README); 1: under (reserved for the renderer).
    public var ride: UInt8
    /// Occlusion width (m).
    public var width: Float
    /// Cables: the mid-span sag (m) — y(u) = lerp(ya, yb, u) − 4·sag·u(1 − u), the same curve for the simulation and the
    /// renderer (no trigonometry).
    public var sag: Float

    public init(_ a: Int32, _ b: Int32, _ kind: RouteKind, sag: Float = 0) {
        self.a = a; self.b = b; self.kind = kind; ride = 0; width = kind.width; self.sag = ohq(sag)
    }
}

/// The overhead route set of a station (pure data, part of `LevelLayout`).
public struct OverheadLayout: Equatable {
    public var nodes: [RouteNode]
    public var edges: [RouteEdge]

    public init(nodes: [RouteNode] = [], edges: [RouteEdge] = []) { self.nodes = nodes; self.edges = edges }

    public var isEmpty: Bool { edges.isEmpty }

    @discardableResult
    public mutating func addNode(_ x: Float, _ y: Float, _ z: Float, _ kind: RouteNodeKind, riserFrom: Float? = nil) -> Int32 {
        nodes.append(RouteNode(x, y, z, kind, riserFrom: riserFrom))
        return Int32(nodes.count - 1)
    }

    @discardableResult
    public mutating func addEdge(_ a: Int32, _ b: Int32, _ kind: RouteKind, sag: Float = 0) -> Int {
        edges.append(RouteEdge(a, b, kind, sag: sag))
        return edges.count - 1
    }

    /// Sum of the edge lengths (m, straight chords).
    public var totalLength: Float {
        var t: Float = 0
        for e in edges {
            let d = nodes[Int(e.b)].p - nodes[Int(e.a)].p
            t += (d * d).sum().squareRoot()
        }
        return t
    }

    /// FNV-1a 32 over the int32 LE values round(v · 64) in the order: node count, each node (x, y, z, kind, riserFrom),
    /// edge count, each edge (a, b, kind, ride, width, sag) — the golden hash of a route set.
    public var hash: UInt32 {
        var h: UInt32 = 0x811c_9dc5
        func put(_ v: Int32) {
            var u = UInt32(bitPattern: v)
            for _ in 0..<4 { h = (h ^ (u & 0xff)) &* 0x0100_0193; u >>= 8 }
        }
        func q(_ v: Float) -> Int32 { Int32((v * 64).rounded()) }
        put(Int32(nodes.count))
        for n in nodes { put(q(n.p.x)); put(q(n.p.y)); put(q(n.p.z)); put(Int32(n.kind.rawValue)); put(q(n.riserFrom)) }
        put(Int32(edges.count))
        for e in edges { put(e.a); put(e.b); put(Int32(e.kind.rawValue)); put(Int32(e.ride)); put(q(e.width)); put(q(e.sag)) }
        return h
    }

    /// The demo / test route of «Кельвин-9» (tech.md §2.8, the first stretch of design §1.2.1's «Spine Rack»): a 4.5 m
    /// pipe rack 0.6 m outside the far (−z) rail of the pad → hub bridge (deck x 6…22, z 27…33), running 2 m into the pad
    /// and the hub, an abyss riser at mid-span, deck posts at both ends and a duct mouth 3 m out over the void feeding the
    /// rack at a junction. The classic mission does not use it (KelvinStation() has no routes).
    public static let kelvinSlice: OverheadLayout = {
        var o = OverheadLayout()
        let pad = o.addNode(24, 4.5, 26.4, .deckPost, riserFrom: 0)
        let j = o.addNode(19, 4.5, 26.4, .joint)
        let riser = o.addNode(14, 4.5, 26.4, .abyssRiser, riserFrom: -5)
        let hub = o.addNode(4, 4.5, 26.4, .deckPost, riserFrom: 0)
        let duct = o.addNode(19, 5.0, 23.4, .ductMouth)
        o.addEdge(pad, j, .pipe)
        o.addEdge(j, riser, .pipe)
        o.addEdge(riser, hub, .pipe)
        o.addEdge(duct, j, .duct)
        return o
    }()
}

// ================================================================
//  The runtime index of a level's routes (built with the Level).
// ================================================================
public final class OverheadGraph {
    public let layout: OverheadLayout
    public var nodeCount: Int { layout.nodes.count }
    public var edgeCount: Int { layout.edges.count }
    /// Per edge: its end nodes, length (m, straight chord), kind, sag.
    let ea: [Int], eb: [Int]
    public let length: [Float]
    let kinds: [UInt8]
    let sag: [Float]
    /// Per edge: the drop window [w0, w1] along a → b (m); w1 < w0 = no window.
    public let w0: [Float], w1: [Float]
    /// Edges touching each node (ascending ids).
    public let nodeEdges: [[Int]]
    /// Spawn entries (abyss risers, masts, duct mouths) and deck posts, ascending node ids.
    public let entries: [Int]
    public let posts: [Int]
    /// Connected component of each node and each edge.
    let nodeComp: [Int], edgeComp: [Int]
    public let componentCount: Int
    /// Stage 1 R4: the duct mouths (`.ductMouth` nodes with an edge) and the perch points for spitters — authored `.perch`
    /// nodes, and gantries, joints, riser and mast tops against the void (not over walkable deck: the far-side rule) with a
    /// standable deck within DROP_MAX m in plan — ascending node ids. Derived from the layout (its golden hash is untouched).
    public let ducts: [Int]
    public let perches: [Int]

    /// `windows`: measure the drop windows (the validation does not need them).
    public init(layout: OverheadLayout, level: Level, windows: Bool = true) {
        self.layout = layout
        let N = layout.nodes, E = layout.edges
        var a: [Int] = [], b: [Int] = [], len: [Float] = [], kd: [UInt8] = [], sg: [Float] = []
        for e in E {
            let ia = Int(e.a), ib = Int(e.b)
            a.append(ia); b.append(ib)
            let d = N[ib].p - N[ia].p
            len.append(max(0.01, (d * d).sum().squareRoot()))
            kd.append(e.kind.rawValue); sg.append(e.sag)
        }
        ea = a; eb = b; length = len; kinds = kd; sag = sg
        var adj = [[Int]](repeating: [], count: N.count)
        for (k, e) in E.enumerated() {
            adj[Int(e.a)].append(k)
            if e.b != e.a { adj[Int(e.b)].append(k) }
        }
        nodeEdges = adj
        entries = N.indices.filter { N[$0].kind.spawns && !adj[$0].isEmpty }
        posts = N.indices.filter { N[$0].kind == .deckPost && !adj[$0].isEmpty }
        // components (BFS over the nodes)
        var comp = [Int](repeating: -1, count: N.count)
        var nc = 0
        for s in N.indices where comp[s] < 0 {
            comp[s] = nc
            var stack = [s]
            while let n = stack.popLast() {
                for k in adj[n] {
                    let o = a[k] == n ? b[k] : a[k]
                    if comp[o] < 0 { comp[o] = nc; stack.append(o) }
                }
            }
            nc += 1
        }
        nodeComp = comp
        edgeComp = a.map { comp[$0] }
        componentCount = nc
        // drop windows: samples every 0.5 m where a standable, stair-free, lift-free deck cell lies DROP_MIN…DROP_MAX away
        var lo: [Float] = [], hi: [Float] = []
        for k in E.indices {
            if !windows { lo.append(1); hi.append(0); continue }
            var first: Float = -1, last: Float = -2
            let L = len[k]
            var s: Float = 0
            while s <= L + 1e-3 {
                let u = s / L
                let x = N[a[k]].p.x + (N[b[k]].p.x - N[a[k]].p.x) * u, z = N[a[k]].p.z + (N[b[k]].p.z - N[a[k]].p.z) * u
                if OverheadGraph.deckWithin(level, x, z, DROP_MIN, DROP_MAX) {
                    if first < 0 { first = s }
                    last = s
                }
                s += 0.5
            }
            if first >= 0 { lo.append(first); hi.append(min(L, last)) } else { lo.append(1); hi.append(0) }
        }
        w0 = lo; w1 = hi
        ducts = N.indices.filter { N[$0].kind == .ductMouth && !adj[$0].isEmpty }
        if windows {
            perches = N.indices.filter { n in
                let nd = N[n]
                if adj[n].isEmpty { return false }
                if nd.kind == .perch { return true }
                if nd.kind != .gantry && nd.kind != .joint && nd.kind != .abyssRiser && nd.kind != .mast { return false }
                let c = level.cellOf(nd.p.x, nd.p.z)
                if c >= 0 && level.walk[c] != 0 { return false }
                return OverheadGraph.deckWithin(level, nd.p.x, nd.p.z, 0, DROP_MAX)
            }
        } else {
            perches = []
        }
    }

    /// A deck cell a marine can stand on (floor, not stairs, not the lift) with its centre r0…r1 m from (x, z).
    static func deckWithin(_ level: Level, _ x: Float, _ z: Float, _ r0: Float, _ r1: Float) -> Bool {
        let n = Int(r1.rounded(.up)) + 1
        let ci = floorInt(x + GRID_HALF), cj = floorInt(z + GRID_HALF)
        var j = cj - n
        while j <= cj + n {
            defer { j += 1 }
            if j < 0 || j >= GRID { continue }
            var i = ci - n
            while i <= ci + n {
                defer { i += 1 }
                if i < 0 || i >= GRID { continue }
                let c = j * GRID + i
                if level.walk[c] != 1 || level.stairCell[c] != 0 || level.liftCell[c] != 0 { continue }
                let dx = Level.cellX(c) - x, dz = Level.cellZ(c) - z, d2 = dx * dx + dz * dz
                if d2 >= r0 * r0 && d2 <= r1 * r1 { return true }
            }
        }
        return false
    }

    // ---------- geometry ----------
    @inline(__always) public func nodePos(_ n: Int) -> SIMD3<Float> { layout.nodes[n].p }
    @inline(__always) public func edgeEnds(_ e: Int) -> (a: Int, b: Int) { (ea[e], eb[e]) }
    @inline(__always) public func kind(_ e: Int) -> RouteKind { RouteKind(rawValue: kinds[e]) ?? .pipe }

    /// The route point `s` m along edge e from its node a: world x, absolute y (with the cable sag), z.
    @inline(__always) public func point(_ e: Int, _ s: Float) -> SIMD3<Float> {
        let A = layout.nodes[ea[e]].p, B = layout.nodes[eb[e]].p
        let u = clampf(s / length[e], 0, 1)
        var p = A + (B - A) * u
        if sag[e] != 0 { p.y -= 4 * sag[e] * u * (1 - u) }
        return p
    }

    /// The point of edge e closest to (x, z) in plan: its distance along the edge and the squared plan distance.
    @inline(__always) func project(_ e: Int, _ x: Float, _ z: Float) -> (s: Float, d2: Float) {
        let A = layout.nodes[ea[e]].p, B = layout.nodes[eb[e]].p
        let dx = B.x - A.x, dz = B.z - A.z, l2 = dx * dx + dz * dz
        var u: Float = 0
        if l2 > 1e-6 { u = clampf(((x - A.x) * dx + (z - A.z) * dz) / l2, 0, 1) }
        let px = A.x + dx * u - x, pz = A.z + dz * u - z
        return (u * length[e], px * px + pz * pz)
    }

    /// The edge at node `n` whose closest point is nearest to (x, z) in plan (`exclude` skipped unless it is the only one);
    /// ties go to the lowest edge id. -1 when the node has no edge.
    func bestEdge(at n: Int, _ x: Float, _ z: Float, exclude: Int = -1) -> Int {
        var best = -1
        var bd: Float = .infinity
        let adj = nodeEdges[n]
        for k in adj where k != exclude || adj.count == 1 {
            let d = project(k, x, z).d2
            if d < bd { bd = d; best = k }
        }
        return best
    }

    /// The smallest plan distance from (x, z) to any edge of component `c`.
    func componentDistance(_ c: Int, _ x: Float, _ z: Float) -> Float {
        var bd: Float = .infinity
        for k in 0..<edgeCount where edgeComp[k] == c { bd = min(bd, project(k, x, z).d2) }
        return bd.squareRoot()
    }

    @inline(__always) func component(ofNode n: Int) -> Int { nodeComp[n] }
}

// ================================================================
//  VALIDATION (routeCheck, tech.md §2.2) — deterministic, like genCheck.
// ================================================================
public struct RouteCheck: Equatable {
    public let ok: Bool
    /// "" when ok, else reach / height / beacon / wide / footprint / length.
    public let why: String
    public let length: Float
    /// Walkable cells under the routes' footprint / floor cells.
    public let footprint: Float
    public let entries: Int
}

public enum OverheadCheck {
    /// The heights a route keeps above the deck it serves (m).
    public static let heightBand: ClosedRange<Float> = 3...9
    /// Routes near a beacon stay this far from it (the ring 4.6 m + 1.5 m: the light column and the punch-in framing).
    public static let beaconClear: Float = 6.1
    /// Occluded walkable footprint, at most (share of the floor).
    public static let maxFootprint: Float = 0.04

    /// `lengthBand`: the total route length a full station set keeps (tech.md: 150–450 m); nil = any (the demo slice, a
    /// partial set).
    public static func check(_ o: OverheadLayout, level: Level, lengthBand: ClosedRange<Float>? = nil) -> RouteCheck {
        let total = o.totalLength
        func bad(_ w: String, _ fp: Float = 0) -> RouteCheck { RouteCheck(ok: false, why: w, length: total, footprint: fp, entries: 0) }
        if o.isEmpty { return bad("empty") }
        let G = OverheadGraph(layout: o, level: level, windows: false)
        // every component reaches an entry (a spawn entry or a deck post)
        var reach = [Bool](repeating: false, count: G.componentCount)
        for n in G.entries + G.posts { reach[G.component(ofNode: n)] = true }
        for k in 0..<G.edgeCount where !reach[G.edgeComp[k]] { return bad("reach") }
        // samples every 1 m: height above the nearest deck, beacon clearance, wide kinds only over the void, the footprint
        var touched = Set<Int>()
        for k in 0..<G.edgeCount {
            let kind = G.kind(k)
            let L = G.length[k]
            let n = max(1, Int((L / 1).rounded(.up)))
            for t in 0...n {
                let p = G.point(k, L * Float(t) / Float(n))
                if let deck = nearestDeckHeight(level, p.x, p.z, 7) {
                    if !heightBand.contains(p.y - deck) { return bad("height") }
                }
                for bcn in level.layout.beacons {
                    let dx = bcn.x - p.x, dz = bcn.z - p.z
                    if dx * dx + dz * dz < beaconClear * beaconClear { return bad("beacon") }
                }
                let c = level.cellOf(p.x, p.z)
                if c >= 0 && level.walk[c] != 0 && !kind.isThin { return bad("wide") }
                // cells under the footprint (centre within half the width + half a cell)
                let r = kind.width / 2 + 0.5
                let ci = floorInt(p.x + GRID_HALF), cj = floorInt(p.z + GRID_HALF)
                for j in (cj - 1)...(cj + 1) where j >= 0 && j < GRID {
                    for i in (ci - 1)...(ci + 1) where i >= 0 && i < GRID {
                        let cc = j * GRID + i
                        if level.walk[cc] != 1 { continue }
                        let dx = Level.cellX(cc) - p.x, dz = Level.cellZ(cc) - p.z
                        if dx * dx + dz * dz <= r * r { touched.insert(cc) }
                    }
                }
            }
        }
        var floor = 0
        for c in 0..<(GRID * GRID) where level.walk[c] == 1 { floor += 1 }
        let fp = floor > 0 ? Float(touched.count) / Float(floor) : 0
        if fp > maxFootprint { return bad("footprint", fp) }
        if let band = lengthBand, !band.contains(total) { return bad("length", fp) }
        return RouteCheck(ok: true, why: "", length: total, footprint: fp, entries: G.entries.count)
    }

    /// Height of the nearest walkable deck cell within `r` m of (x, z) (the deck a route serves), nil when none.
    static func nearestDeckHeight(_ level: Level, _ x: Float, _ z: Float, _ r: Float) -> Float? {
        let n = Int(r.rounded(.up))
        let ci = floorInt(x + GRID_HALF), cj = floorInt(z + GRID_HALF)
        var best: Float = r * r
        var h: Float? = nil
        for j in (cj - n)...(cj + n) where j >= 0 && j < GRID {
            for i in (ci - n)...(ci + n) where i >= 0 && i < GRID {
                let c = j * GRID + i
                if level.walk[c] == 0 { continue }
                let dx = Level.cellX(c) - x, dz = Level.cellZ(c) - z, d2 = dx * dx + dz * dz
                if d2 < best { best = d2; h = level.groundY(Level.cellX(c), Level.cellZ(c)) }
            }
        }
        return h
    }
}

// ================================================================
//  THE GENERATOR POST-PASS (tech.md §2.2 «Generated stations»): racks on
//  the far rail of every corridor-like rect, an abyss riser (or now and then
//  a duct mouth) at mid-span, deck posts where a rack runs into a deck. Its
//  own random stream, seeded from the station seed — the web generator's
//  stream and the golden layout hashes stay byte-identical.
// ================================================================
public enum OverheadPlanner {
    /// Route height above the deck: racks 4.5 m, trays over stairs 4 m (design §1.1.1 heights; concept-station README:
    /// 4.5–6.5 m reads best).
    static let rackH: Float = 4.5, trayH: Float = 4.0
    /// Distance of a rack outside the far rail, and how far it runs into the decks at each end.
    static let railOut: Float = 0.6, runIn: Float = 2.0

    public static func plan(_ L: LevelLayout) -> OverheadLayout {
        var rng = SeededRNG(seed: (L.seed &* 0x9E37_79B1) ^ 0x0E4D_A11C)
        let level = Level(layout: L)   // the walk grid of the station (no routes yet)
        var out = OverheadLayout()
        var ducts = 0
        for r in L.rects {
            let w = r.x1 - r.x0, d = r.z1 - r.z0
            let xCorr = w >= 8 && d <= 6, zCorr = d >= 8 && w <= 6
            if !(xCorr || zCorr) { continue }
            // never along the stair down to the lift (the extraction camera's corridor and the Queen's rim)
            if r.height.minHeight <= L.lift.y + 0.01 && r.height.isStairs { continue }
            let stairs = r.height.isStairs
            let hk: Float = stairs ? trayH : rackH
            let kind: RouteKind = stairs ? .tray : .pipe
            // the far rail: −z of an x-corridor, −x of a z-corridor
            var p0: SIMD2<Float>, p1: SIMD2<Float>
            var y0: Float, y1: Float
            if xCorr {
                let z = r.z0 - railOut
                p0 = SIMD2(r.x0 - runIn, z); p1 = SIMD2(r.x1 + runIn, z)
                y0 = r.height.height(atZ: r.z0 + 0.5) + hk; y1 = y0
            } else {
                let x = r.x0 - railOut
                p0 = SIMD2(x, r.z0 - runIn); p1 = SIMD2(x, r.z1 + runIn)
                y0 = r.height.height(atZ: r.z0) + hk; y1 = r.height.height(atZ: r.z1) + hk
            }
            // keep out of the beacon rings (+1.5 m) and the near half of the lift
            if tooClose(L, p0, p1) { continue }
            var cand = out
            let ka = endNode(&cand, level, p0, y0)
            let kb = endNode(&cand, level, p1, y1)
            let mid = (p0 + p1) * 0.5
            let ym = (y0 + y1) * 0.5
            // own stream: one draw for the riser depth, one for a duct mouth (2–4 per station, ≥ 10 m from beacons)
            let depth = 3 + 4 * rng.next()
            let ductRoll = rng.next()
            let deckH = ym - hk
            let km = cand.addNode(mid.x, ym, mid.y, .abyssRiser, riserFrom: deckH - depth)
            cand.addEdge(ka, km, kind)
            cand.addEdge(km, kb, kind)
            if ducts < 4 && ductRoll < 0.35 && farFromBeacons(L, mid, 10) {
                // the duct runs straight out over the void, away from the walkway (−z / −x), and feeds the rack mid-span
                let out3: SIMD2<Float> = xCorr ? SIMD2(0, -3) : SIMD2(-3, 0)
                let kd = cand.addNode(mid.x + out3.x, ym + 0.5, mid.y + out3.y, .ductMouth)
                cand.addEdge(kd, km, .duct)
            }
            if OverheadCheck.check(cand, level: level).ok {
                if cand.edges.count - out.edges.count == 3 { ducts += 1 }
                out = cand
            }
        }
        return out
    }

    /// A rack end: a deck post when it stands over walkable deck, else a joint over the void.
    static func endNode(_ o: inout OverheadLayout, _ level: Level, _ p: SIMD2<Float>, _ y: Float) -> Int32 {
        let c = level.cellOf(p.x, p.y)
        if c >= 0 && level.walk[c] == 1 && level.stairCell[c] == 0 {
            return o.addNode(p.x, y, p.y, .deckPost, riserFrom: level.groundY(p.x, p.y))
        }
        return o.addNode(p.x, y, p.y, .joint)
    }

    static func tooClose(_ L: LevelLayout, _ p0: SIMD2<Float>, _ p1: SIMD2<Float>) -> Bool {
        let n = 24
        for t in 0...n {
            let p = p0 + (p1 - p0) * (Float(t) / Float(n))
            for b in L.beacons {
                let dx = b.x - p.x, dz = b.z - p.y
                if dx * dx + dz * dz < OverheadCheck.beaconClear * OverheadCheck.beaconClear { return true }
            }
            let lx = p.x - L.lift.x, lz = p.y - L.lift.z
            if lx + lz > 0 && lx * lx + lz * lz < (L.lift.r + 3) * (L.lift.r + 3) { return true }
        }
        return false
    }

    static func farFromBeacons(_ L: LevelLayout, _ p: SIMD2<Float>, _ r: Float) -> Bool {
        for b in L.beacons where (b.x - p.x) * (b.x - p.x) + (b.z - p.y) * (b.z - p.y) < r * r { return false }
        return true
    }
}
