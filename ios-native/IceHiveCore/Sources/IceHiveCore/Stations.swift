import Foundation

// ================================================================
//  STATIONS — the seeded station generator (v1.1 «Ставки», package E): a
//  bit-exact port of origin/v1.1/e-stations @ ffeeea7 game/js/04-level.js
//  genLevel / genTry / genCheck / clampI. Same seed → same station on the web
//  and here (golden tests). Seed 0 is the hand-made «Кельвин-9».
//  Port rules: every number is a Double like the JS (convert to Float only in
//  `layout(name:)`); R() is the 32-bit mulberry32 double (`nextDouble`), never
//  the 24-bit Float `next()`; JS Math.round = floor(x + 0.5); the short-circuit
//  order of `cond && R() < p` is kept (it decides whether a number is drawn).
//  Rendering generated stations needs the WP6 station kit: the app keeps the
//  flag `AppFeatures.generatedStations` off until then.
// ================================================================

/// Floor height of a generated rect: flat, or a ramp along z (`ha` for z ≤ a, `hb` for z ≥ b).
public enum GenHeight: Equatable {
    case flat(Double)
    case ramp(a: Double, ha: Double, b: Double, hb: Double, stairs: Bool)

    /// web rectH.
    public func at(_ z: Double) -> Double {
        switch self {
        case .flat(let h): return h
        case .ramp(let a, let ha, let b, let hb, _):
            if z <= a { return ha }
            if z >= b { return hb }
            return ha + (hb - ha) * (z - a) / (b - a)
        }
    }
}

public struct GenRect: Equatable {
    public var x0, z0, x1, z1: Double
    /// 's' (snowy slab) vs 'g' (grating).
    public var slab: Bool
    public var hazard: Bool
    public var height: GenHeight
}

public struct GenCrate: Equatable {
    public var x0, z0: Double
    public var w, d: Int
    public var h: Double
}

public struct GenPipe: Equatable {
    public var x0, z0, x1, z1, h: Double
}

public struct GenBeacon: Equatable {
    public var x, z: Double
    public var name: String
}

/// Result of genCheck.
public struct StationCheck: Equatable {
    public let ok: Bool
    /// "" when ok, else start / unreachable / cliff / pockets / tour / rim.
    public let why: String
    public let tour: Int
    public let floor: Int
    /// Reachable share of the floor (3 decimals like the web).
    public let reach: Double
    public let rim: Int
    public let cliffs: Int
}

/// A generated station exactly as the JS object (Doubles).
public struct GeneratedStation {
    public var rects: [GenRect]
    public var crates: [GenCrate]
    public var pillars: [(x: Double, z: Double)]
    public var vents: [(x: Double, z: Double)]
    public var pipes: [GenPipe]
    public var start: (x: Double, z: Double)
    /// Landing pad rect x0, z0, x1, z1 (the start node).
    public var pad: [Double]
    public var lift: (x: Double, z: Double, r: Double, y: Double)
    public var beacons: [GenBeacon]
    /// Lattice data: row heights, nodes, start / lift / beacon nodes, link count.
    public var rowH: [Double]
    public var nodes: Int
    public var startNode: Int
    public var liftNode: Int
    public var beaconNodes: [Int]
    public var edges: Int
    public var seed: UInt32 = 0
    public var attempts: Int = 0
    public var check: StationCheck? = nil

    /// The simulation / renderer layout (Floats).
    public func layout(name: String) -> LevelLayout {
        let rs: [FloorRect] = rects.map { r in
            let h: FloorHeight
            switch r.height {
            case .flat(let v): h = .flat(Float(v))
            case .ramp(let a, let ha, let b, let hb, let st): h = .ramp(a: Float(a), ha: Float(ha), b: Float(b), hb: Float(hb), stairs: st)
            }
            return FloorRect(Float(r.x0), Float(r.z0), Float(r.x1), Float(r.z1), r.slab ? .slab : .grating, r.hazard, h)
        }
        var L = LevelLayout(name: name, seed: seed, rects: rs,
                            crates: crates.map { CrateSpec(Float($0.x0), Float($0.z0), $0.w, $0.d, Float($0.h)) },
                            pillars: pillars.map { Vec2(Float($0.x), Float($0.z)) },
                            start: Vec2(Float(start.x), Float(start.z)),
                            lift: LiftSpec(x: Float(lift.x), z: Float(lift.z), r: Float(lift.r), y: Float(lift.y)),
                            beacons: beacons.map { BeaconSite(x: Float($0.x), z: Float($0.z), name: $0.name) },
                            vents: vents.map { Vec2(Float($0.x), Float($0.z)) },
                            pipes: pipes.map { PipeRun(Float($0.x0), Float($0.z0), Float($0.x1), Float($0.z1), Float($0.h)) })
        L.pad = SIMD4<Float>(Float(pad[0]), Float(pad[1]), Float(pad[2]), Float(pad[3]))
        L.attempts = attempts
        L.isGenerated = true
        return L
    }
}

/// `LevelSource` of the generated stations: seed 0 (or a seed whose 40 attempts all fail) is «Кельвин-9».
public struct StationGenerator: LevelSource {
    public init() {}
    public func makeLayout(seed: UInt32) -> LevelLayout {
        if seed == 0 { return KelvinStation().makeLayout(seed: 0) }
        guard let g = Stations.generate(seed: seed) else { return KelvinStation().makeLayout(seed: 0) }
        return g.layout(name: Stations.name(seed: seed))
    }
}

public enum Stations {
    static let COLS = 4, ROWS = 4
    static let PITCH: Double = 24
    static let TOUR_MIN = 190, TOUR_MAX = 320
    static let REACH: Double = 0.97

    /// «Кельвин-9» for 0, else «Сектор {АБВГДЕЖИКЛМН[s % 12]}-{1 + (s >> 4) % 99}».
    public static func name(seed: UInt32) -> String {
        if seed == 0 { return "Кельвин-9" }
        let letters = Array("АБВГДЕЖИКЛМН")
        return "Сектор " + String(letters[Int(seed % 12)]) + "-\(1 + (seed >> 4) % 99)"
    }

    /// A stored seed: floor; 0 < v < 0x40000000 ? v : 0 (web stationSeedOf).
    public static func sanitize(_ v: Double?) -> UInt32 {
        guard let v0 = v, v0.isFinite else { return 0 }
        let f = v0.rounded(.down)
        return f > 0 && f < Double(0x4000_0000) ? UInt32(f) : 0
    }

    /// genLevel: 40 attempts, the first one genCheck accepts; nil when all fail (the caller falls back to seed 0).
    public static func generate(seed: UInt32, nodes: Int? = nil) -> GeneratedStation? {
        for attempt in 0..<40 {
            let s = UInt32(truncatingIfNeeded: Int64(seed) * 977 + Int64(attempt) * 7919)
            guard var L = genTry(s, nodes: nodes) else { continue }
            let c = check(L)
            if c.ok { L.seed = seed; L.attempts = attempt + 1; L.check = c; return L }
        }
        return nil
    }

    @inline(__always) static func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }
    static func clampI(_ v: Double, _ a: Double, _ b: Double) -> Double { a > b ? jsRound((a + b) / 2) : (v < a ? a : (v > b ? b : v)) }

    /// A lattice node's deck (integer metres).
    final class Node {
        let n: Int
        let cx, cz, hx, hz, h: Double
        var x0: Double { cx - hx }
        var x1: Double { cx + hx }
        var z0: Double { cz - hz }
        var z1: Double { cz + hz }
        var wing: [Double]? = nil
        init(n: Int, cx: Double, cz: Double, hx: Double, hz: Double, h: Double) { self.n = n; self.cx = cx; self.cz = cz; self.hx = hx; self.hz = hz; self.h = h }
    }

    // swiftlint:disable:next function_body_length
    static func genTry(_ s: UInt32, nodes: Int?) -> GeneratedStation? {
        var rng = SeededRNG(seed: s)
        func R() -> Double { rng.nextDouble() }
        func ri(_ a: Double, _ b: Double) -> Double { a + (R() * (b - a + 1)).rounded(.down) }
        func colOf(_ n: Int) -> Int { n % COLS }
        func rowOf(_ n: Int) -> Int { n / COLS }
        func nb(_ n: Int) -> [Int] {
            let c = colOf(n), r = rowOf(n)
            var o: [Int] = []
            if c > 0 { o.append(n - 1) }
            if c < COLS - 1 { o.append(n + 1) }
            if r > 0 { o.append(n - COLS) }
            if r < ROWS - 1 { o.append(n + COLS) }
            return o
        }
        let NN = COLS * ROWS
        // ---- 1. grow a random tree from the start node (row 0 = nearest the camera, highest deck) ----
        let target = nodes ?? Int(ri(8, 10))
        let start = Int(ri(0, Double(COLS - 1)))   // id(c, 0)
        var inSet = [Bool](repeating: false, count: NN)
        var edgeList: [(Int, Int)] = []
        var edgeSet = Set<Int>()
        var adj = [[Int]](repeating: [], count: NN)
        func ek(_ a: Int, _ b: Int) -> Int { a < b ? a * 16 + b : b * 16 + a }
        func link(_ a: Int, _ b: Int) {
            if edgeSet.insert(ek(a, b)).inserted { edgeList.append((min(a, b), max(a, b))) }
            adj[a].append(b); adj[b].append(a)
        }
        inSet[start] = true
        var count = 1
        while count < target {
            var front: [(Int, Int)] = []
            for n in 0..<NN where inSet[n] { for m in nb(n) where !inSet[m] { front.append((n, m)) } }
            if front.isEmpty { break }
            // bias toward growing downward (-z): the mission reads as a descent into the station
            let w = front.map { rowOf($0.1) > rowOf($0.0) ? 1.6 : 1.0 }
            var tot = 0.0
            for x in w { tot += x }
            var t = R() * tot
            var k = 0
            while k < front.count - 1 { t -= w[k]; if t <= 0 { break }; k += 1 }
            let (n, m) = front[k]
            inSet[m] = true; count += 1; link(n, m)
        }
        func bfs(_ from: Int) -> [Int] {
            var d = [Int](repeating: -1, count: NN)
            var q = [from]
            var h = 0
            d[from] = 0
            while h < q.count {
                let n = q[h]; h += 1
                for m in adj[n] where d[m] < 0 { d[m] = d[n] + 1; q.append(m) }
            }
            return d
        }
        // ---- 2. lift: a leaf in row >= 2 whose only link comes from +z (the lift railing opens toward +z) ----
        var d0 = bfs(start)
        var lift = -1
        var best = -1.0
        for n in 0..<NN {
            if !inSet[n] || rowOf(n) < 2 || adj[n].count != 1 || adj[n][0] != n - COLS { continue }
            let sc = Double(d0[n]) * 10 + Double(rowOf(n)) * 3 + R()
            if sc > best { best = sc; lift = n }
        }
        if lift < 0 { return nil }
        // ---- 3. one or two loop links (never into the lift): flanking routes and kiting circles ----
        let loops = Int(ri(1, 2))
        var tries = 0, made = 0
        while tries < 30 && made < loops {
            defer { tries += 1 }
            let n = Int(ri(0, Double(NN - 1)))
            if !inSet[n] || n == lift { continue }
            let nbs = nb(n)
            let m = nbs[Int((R() * Double(nbs.count)).rounded(.down))]
            if !inSet[m] || m == lift || edgeSet.contains(ek(n, m)) { continue }
            link(n, m); made += 1
        }
        d0 = bfs(start)
        // ---- 4. three beacons: far from the start and from each other (farthest-point on graph distance) ----
        var cand: [Int] = []
        for n in 0..<NN where inSet[n] && n != start && n != lift { cand.append(n) }
        if cand.count < 3 { return nil }
        var beac: [Int] = []
        while beac.count < 3 {
            var bn = -1
            var bs = -1.0
            for n in cand {
                if beac.contains(n) { continue }
                let dn = bfs(n)
                var mind = Double(d0[n]) * 0.8
                for b in beac { mind = min(mind, Double(dn[b]) * 1.2) }
                // the node next to the lift stays a plain approach (the climax needs a clean run-up)
                let sc = mind + (adj[lift][0] == n ? -2 : 0) + R() * 0.5
                if sc > bs { bs = sc; bn = n }
            }
            if bn < 0 { return nil }   // (the JS would throw here; never seen in 1000+ seeds)
            beac.append(bn)
        }
        // ---- 5. heights per row: each row is level with, or 3 m below, the row nearer the camera ----
        var rowH: [Double] = [0]
        for r in 1..<ROWS { rowH.append(rowH[r - 1] - (R() < 0.55 ? 3 : 0)) }
        // ---- 6. node footprints (integer metres so the 1 m walk grid rasterises cleanly) ----
        var N = [Node?](repeating: nil, count: NN)
        for n in 0..<NN {
            if !inSet[n] { continue }
            let big = beac.contains(n) || n == start
            let hx = big ? ri(8, 9) : ri(6, 8), hz = big ? ri(8, 9) : ri(6, 8)
            let cx = -36 + PITCH * Double(colOf(n)) + ri(-2, 2), cz = 36 - PITCH * Double(rowOf(n)) + ri(-2, 2)
            N[n] = Node(n: n, cx: cx, cz: cz, hx: hx, hz: hz, h: rowH[rowOf(n)])
        }
        var rects: [GenRect] = [], crates: [GenCrate] = [], pillars: [(x: Double, z: Double)] = []
        var vents: [(x: Double, z: Double)] = [], pipes: [GenPipe] = [], mouths: [(x: Double, z: Double)] = []
        guard let Lnode = N[lift], let up = N[lift - COLS] else { return nil }
        let LIFT_R = 10.0, liftY = up.h - 3
        // the lift disc sits under its approach node, centred on a 6 m stair that must fit inside that node
        let lx = clampI(Lnode.cx, up.x0 + 4, up.x1 - 4), lz = up.z0 - ri(10, 12) - LIFT_R
        N[lift] = nil
        for nd in N {
            guard let nd = nd else { continue }
            let isB = beac.contains(nd.n), isS = nd.n == start
            let slab = isS ? true : R() < 0.3
            rects.append(GenRect(x0: nd.x0, z0: nd.z0, x1: nd.x1, z1: nd.z1, slab: slab, hazard: isB || isS, height: .flat(nd.h)))
            // L-shaped wing on some plain nodes: more corners, more railing edges for climbers
            if !isB && !isS && R() < 0.4 {
                let side = Int(ri(0, 3)), w = ri(4, 6), len = ri(4, 6)
                var r2: [Double?]
                if side == 0 { r2 = [nd.x1, nd.z1 - w - ri(0, 3), nd.x1 + len, nil] }
                else if side == 1 { r2 = [nd.x0 - len, nd.z0 + ri(0, 3), nd.x0, nil] }
                else if side == 2 { r2 = [nd.x0 + ri(0, 3), nd.z1, nil, nd.z1 + len] }
                else { r2 = [nd.x1 - w - ri(0, 3), nd.z0 - len, nil, nd.z0] }
                if r2[3] == nil { r2[3] = r2[1]! + w }
                if r2[2] == nil { r2[2] = r2[0]! + w }
                nd.wing = r2.map { $0! }
            }
        }
        // ---- 7. connectors: flat bridges E-W, bridges / ramps / stairs N-S ----
        var conns: [GenRect] = []
        for (a, b) in edgeList {
            if a == lift || b == lift { continue }
            guard let A = N[a], let Bn = N[b] else { return nil }
            if rowOf(a) == rowOf(b) {
                let W = colOf(a) < colOf(b) ? A : Bn, E = W === A ? Bn : A
                let lo = max(W.z0, E.z0) + 1, hi = min(W.z1, E.z1) - 1
                var w = R() < 0.25 ? 3 : ri(4, 6)
                if hi - lo < w { w = hi - lo }
                if w < 3 { return nil }
                let zc = clampI(jsRound((W.cz + E.cz) / 2), lo + (w / 2).rounded(.up), hi - (w / 2).rounded(.down))
                let z0 = zc - (w / 2).rounded(.down), z1 = z0 + w
                conns.append(GenRect(x0: W.x1, z0: z0, x1: E.x0, z1: z1, slab: R() < 0.2, hazard: false, height: .flat(W.h)))
                mouths.append((W.x1, (z0 + z1) / 2)); mouths.append((E.x0, (z0 + z1) / 2))
            } else {
                let U = rowOf(a) < rowOf(b) ? A : Bn, D = U === A ? Bn : A   // U nearer the camera (+z), D lower z
                let lo = max(U.x0, D.x0) + 1, hi = min(U.x1, D.x1) - 1
                let drop = U.h - D.h
                let stairs = drop != 0 && R() < 0.6
                var w = drop != 0 ? (stairs ? 6 : 4) : (R() < 0.25 ? 3 : ri(4, 6))
                if hi - lo < w { w = hi - lo }
                if w < 3 { return nil }
                let xc = clampI(jsRound((U.cx + D.cx) / 2), lo + (w / 2).rounded(.up), hi - (w / 2).rounded(.down))
                let x0 = xc - (w / 2).rounded(.down), x1 = x0 + w, za = D.z1, zb = U.z0
                if zb - za < 4 { return nil }
                let hs: GenHeight = drop != 0 ? .ramp(a: za + 0.5, ha: D.h, b: zb - 0.5, hb: U.h, stairs: stairs) : .flat(U.h)
                if drop != 0 && zb - za - 1 < (stairs ? 5 : 6) { return nil }   // too steep
                conns.append(GenRect(x0: x0, z0: za, x1: x1, z1: zb, slab: stairs, hazard: false, height: hs))
                mouths.append(((x0 + x1) / 2, za)); mouths.append(((x0 + x1) / 2, zb))
            }
        }
        // the stair down to the lift (lands 0.5 m inside the disc rim, as in the hand-made level)
        conns.append(GenRect(x0: lx - 3, z0: lz + LIFT_R - 0.5, x1: lx + 3, z1: up.z0, slab: true, hazard: false,
                             height: .ramp(a: lz + LIFT_R + 1.5, ha: liftY, b: up.z0 - 0.5, hb: up.h, stairs: true)))
        mouths.append((lx, up.z0))
        // wings must not touch connectors or other nodes (2 m clearance), else they are dropped
        func hits(_ r: [Double], _ o: GenRect, _ m: Double) -> Bool { r[0] < o.x1 + m && r[2] > o.x0 - m && r[1] < o.z1 + m && r[3] > o.z0 - m }
        func hitsBox(_ r: [Double], _ o: [Double], _ m: Double) -> Bool { r[0] < o[2] + m && r[2] > o[0] - m && r[1] < o[3] + m && r[3] > o[1] - m }
        func isNode(_ o: GenRect, _ nd: Node) -> Bool { o.x0 == nd.x0 && o.z0 == nd.z0 && o.x1 == nd.x1 && o.z1 == nd.z1 }
        func hitsOthers(_ r: [Double], _ nd: Node, _ m: Double) -> Bool {
            for o in rects where !isNode(o, nd) { if hits(r, o, m) { return true } }
            for o in conns where !isNode(o, nd) { if hits(r, o, m) { return true } }
            return false
        }
        let liftBox = [lx - LIFT_R - 1, lz - LIFT_R - 1, lx + LIFT_R + 1, lz + LIFT_R + 1]
        // the disc must clear every deck and bridge except its own stair (2 m air gap), and stay on the grid
        do {
            var hit = false
            for o in rects where hitsBox(liftBox, [o.x0, o.z0, o.x1, o.z1], 1) { hit = true }
            for o in conns.dropLast() where hitsBox(liftBox, [o.x0, o.z0, o.x1, o.z1], 1) { hit = true }
            if hit || lz - LIFT_R < -58 { return nil }
        }
        for nd in N {
            guard let nd = nd, let w = nd.wing else { continue }
            if !hitsOthers(w, nd, 2) && !hitsBox(w, liftBox, 1) && w[0] > -56 && w[2] < 56 && w[1] > -56 && w[3] < 56 {
                rects.append(GenRect(x0: w[0], z0: w[1], x1: w[2], z1: w[3], slab: false, hazard: false, height: .flat(nd.h)))
            }
        }
        // ---- 8. dead-end catwalk spurs: extra climbing lanes that flank the route ----
        let live = N.compactMap { $0 }
        let spurs = Int(ri(1, 2))
        do {
            var t = 0, made = 0
            while t < 20 && made < spurs {
                defer { t += 1 }
                let nd = live[Int((R() * Double(live.count)).rounded(.down))]
                let side = Int(ri(0, 3)), w = 3.0, len = ri(5, 8)
                let r: [Double]
                if side == 0 { let z0 = ri(nd.z0 + 1, nd.z1 - 4); r = [nd.x1, z0, nd.x1 + len, z0 + w] }
                else if side == 1 { let z0 = ri(nd.z0 + 1, nd.z1 - 4); r = [nd.x0 - len, z0, nd.x0, z0 + w] }
                else if side == 2 { let x0 = ri(nd.x0 + 1, nd.x1 - 4); r = [x0, nd.z1, x0 + w, nd.z1 + len] }
                else { let x0 = ri(nd.x0 + 1, nd.x1 - 4); r = [x0, nd.z0 - len, x0 + w, nd.z0] }
                if hitsOthers(r, nd, 2) || hitsBox(r, liftBox, 1) || r[0] < -56 || r[2] > 56 || r[1] < -56 || r[3] > 56 { continue }
                rects.append(GenRect(x0: r[0], z0: r[1], x1: r[2], z1: r[3], slab: false, hazard: false, height: .flat(nd.h)))
                // a burrow vent at the far end: a visible flank the horde can pour out of
                vents.append((side == 0 ? r[2] - 1.5 : (side == 1 ? r[0] + 1.5 : (r[0] + r[2]) / 2),
                              side == 2 ? r[3] - 1.5 : (side == 3 ? r[1] + 1.5 : (r[1] + r[3]) / 2)))
                made += 1
            }
        }
        // ---- 9. objective and prop placement ----
        let names = ["Альфа", "Бета", "Гамма"]
        var beacons: [(x: Double, z: Double, name: String, node: Int)] = []
        for (k, n) in beac.enumerated() {
            guard let nd = N[n] else { return nil }
            let x = nd.cx + ri(-1, 1)
            let z = nd.cz + ri(-1, 1)
            beacons.append((x, z, names[k], n))
        }
        guard let sN = N[start] else { return nil }
        func near(_ x: Double, _ z: Double, _ list: [(x: Double, z: Double)], _ r: Double) -> Bool {
            for p in list where (p.x - x) * (p.x - x) + (p.z - z) * (p.z - z) < r * r { return true }
            return false
        }
        for b in beacons {
            guard let nd = N[b.node] else { continue }
            var k = 0, made = 0
            while k < 20 && made < 2 {
                defer { k += 1 }
                let a = R() * Double.pi * 2, d = 5.5 + R() * 1.5
                let x = jsRound(b.x + cos(a) * d) + 0.5, z = jsRound(b.z + sin(a) * d) + 0.5
                if x < nd.x0 + 1.5 || x > nd.x1 - 1.5 || z < nd.z0 + 1.5 || z > nd.z1 - 1.5 || near(x, z, vents, 4) { continue }
                vents.append((x, z)); made += 1
            }
        }
        for nd in N {
            guard let nd = nd else { continue }
            let isB = beac.contains(nd.n), isS = nd.n == start
            // teal-lit pillars on the corners (inset 1.5 m), like the hand-made decks
            if R() < 0.6 || isB || isS {
                for (sx, sz) in [(-1.0, -1.0), (1.0, 1.0), (-1.0, 1.0), (1.0, -1.0)] where R() < 0.6 {
                    let x = (sx < 0 ? nd.x0 : nd.x1) - sx * 1.5, z = (sz < 0 ? nd.z0 : nd.z1) - sz * 1.5
                    if !near(x, z, mouths, 3.5) { pillars.append((x, z)) }
                }
            }
            if isS {
                // crates stacked in one corner of the landing pad
                crates.append(GenCrate(x0: nd.x0 + 2, z0: nd.z1 - 3, w: 1, d: 1, h: 1.2))
                crates.append(GenCrate(x0: nd.x0 + 3, z0: nd.z1 - 3, w: 1, d: 1, h: 0.9))
                crates.append(GenCrate(x0: nd.x0 + 2, z0: nd.z1 - 4, w: 1, d: 1, h: 0.9))
                continue
            }
            let clusters = Int(ri(1, 3))
            var c = 0, t = 0
            while c < clusters && t < 25 {
                defer { t += 1 }
                let w = ri(1, 2), d = ri(1, 2), x0 = ri(nd.x0 + 2, nd.x1 - 2 - w), z0 = ri(nd.z0 + 2, nd.z1 - 2 - d)
                let cx = x0 + w / 2, cz = z0 + d / 2
                if near(cx, cz, mouths, 4.5) || near(cx, cz, vents, 2.5) || near(cx, cz, pillars, 2) { continue }
                if isB, let b = beacons.first(where: { $0.node == nd.n }), ((cx - b.x) * (cx - b.x) + (cz - b.z) * (cz - b.z)).squareRoot() < 4.6 + 2 { continue }
                crates.append(GenCrate(x0: x0, z0: z0, w: Int(w), d: Int(d), h: 0.8 + R() * 0.6))
                if R() < 0.5 { crates.append(GenCrate(x0: x0 + w, z0: z0, w: 1, d: 1, h: 0.7 + R() * 0.4)) }
                c += 1
            }
        }
        // pipe bundles under a few south (−z) deck edges
        for nd in N {
            guard let nd = nd else { continue }
            if R() < 0.45 { pipes.append(GenPipe(x0: nd.x0, z0: nd.z0 - 0.3, x1: nd.x1, z1: nd.z0 - 0.3, h: nd.h)) }
        }
        return GeneratedStation(rects: rects + conns, crates: crates, pillars: pillars, vents: vents, pipes: pipes,
                                start: (sN.cx, sN.cz), pad: [sN.x0, sN.z0, sN.x1, sN.z1], lift: (lx, lz, LIFT_R, liftY),
                                beacons: beacons.map { GenBeacon(x: $0.x, z: $0.z, name: $0.name) },
                                rowH: rowH, nodes: count, startNode: start, liftNode: lift, beaconNodes: beac, edges: edgeSet.count)
    }

    // ---------- validation on a scratch raster (same rules as rasterLevel; the live Level is never touched) ----------
    static let G = GRID
    static let GH = Double(GRID_HALF)

    @inline(__always) static func cellOf(_ x: Double, _ z: Double) -> Int {
        let i = Int((x + GH).rounded(.down)), j = Int((z + GH).rounded(.down))
        return (i < 0 || j < 0 || i >= G || j >= G) ? -1 : j * G + i
    }

    static func bfs(_ from: Int, _ w: [UInt8]) -> [Int32] {
        var d = [Int32](repeating: -1, count: G * G)
        var q = [Int](repeating: 0, count: G * G)
        var h = 0, t = 0
        d[from] = 0; q[t] = from; t += 1
        while h < t {
            let c = q[h]; h += 1
            let i = c % G, n1 = d[c] + 1
            if i > 0 && w[c - 1] == 1 && d[c - 1] < 0 { d[c - 1] = n1; q[t] = c - 1; t += 1 }
            if i < G - 1 && w[c + 1] == 1 && d[c + 1] < 0 { d[c + 1] = n1; q[t] = c + 1; t += 1 }
            if c >= G && w[c - G] == 1 && d[c - G] < 0 { d[c - G] = n1; q[t] = c - G; t += 1 }
            if c < G * (G - 1) && w[c + G] == 1 && d[c + G] < 0 { d[c + G] = n1; q[t] = c + G; t += 1 }
        }
        return d
    }

    /// genCheck: connectivity (start reaches every beacon ring and the lift, ≥ 97 % of the floor), no cliffs between
    /// walkable neighbours, objective tour 190–320 cells (the greedy order the autopilot plays), and a lift rim edge on the
    /// far side (z − lift.z < −4) for the Матка's climb.
    public static func check(_ L: GeneratedStation) -> StationCheck {
        var w = [UInt8](repeating: 0, count: G * G)
        var hg = [Float](repeating: 0, count: G * G)
        for r in L.rects {
            let i0 = max(0, Int((r.x0 + GH - 0.5).rounded(.down))), i1 = min(G - 1, Int((r.x1 + GH).rounded(.up)))
            let j0 = max(0, Int((r.z0 + GH - 0.5).rounded(.down))), j1 = min(G - 1, Int((r.z1 + GH).rounded(.up)))
            if i0 > i1 || j0 > j1 { continue }
            for j in j0...j1 {
                for i in i0...i1 {
                    let x = Double(i) - GH + 0.5, z = Double(j) - GH + 0.5
                    if x > r.x0 && x < r.x1 && z > r.z0 && z < r.z1 { w[j * G + i] = 1; hg[j * G + i] = Float(r.height.at(z)) }
                }
            }
        }
        let T = L.lift
        for j in 0..<G {
            for i in 0..<G {
                let x = Double(i) - GH + 0.5, z = Double(j) - GH + 0.5
                if (x - T.x) * (x - T.x) + (z - T.z) * (z - T.z) < (T.r - 0.3) * (T.r - 0.3) { let c = j * G + i; w[c] = 1; hg[c] = Float(T.y) }
            }
        }
        for cr in L.crates {
            for a in 0..<max(0, cr.w) { for b in 0..<max(0, cr.d) { let c = cellOf(cr.x0 + Double(a) + 0.5, cr.z0 + Double(b) + 0.5); if c >= 0 { w[c] = 2 } } }
        }
        for p in L.pillars { let c = cellOf(p.x, p.z); if c >= 0 { w[c] = 2 } }
        // the Матка's rim: a spawn edge (floor next to the abyss) by the lift, on its far side
        var rim = 0
        for j in 1..<(G - 1) {
            for i in 1..<(G - 1) {
                let c = j * G + i
                if w[c] != 1 { continue }
                if w[c - 1] != 0 && w[c + 1] != 0 && w[c - G] != 0 && w[c + G] != 0 { continue }
                let x = Double(i) - GH + 0.5, z = Double(j) - GH + 0.5
                if (x - T.x) * (x - T.x) + (z - T.z) * (z - T.z) <= (T.r + 1.5) * (T.r + 1.5) && z - T.z < -4 { rim += 1 }
            }
        }
        for b in L.beacons {
            for (ox, oz) in [(-0.5, -0.5), (0.5, -0.5), (-0.5, 0.5), (0.5, 0.5)] { let c = cellOf(b.x + ox, b.z + oz); if c >= 0 { w[c] = 2 } }
        }
        var floor = 0, cliffs = 0
        for j in 1..<(G - 1) {
            for i in 1..<(G - 1) {
                let c = j * G + i
                if w[c] != 1 { continue }
                floor += 1
                if w[c + 1] == 1 && abs(Double(hg[c + 1]) - Double(hg[c])) > 0.05 { cliffs += 1 }
                if w[c + G] == 1 && abs(Double(hg[c + G]) - Double(hg[c])) > 0.65 { cliffs += 1 }
            }
        }
        let s = cellOf(L.start.x + 0.5, L.start.z + 0.5)
        if s < 0 || w[s] != 1 { return StationCheck(ok: false, why: "start", tour: 0, floor: floor, reach: 0, rim: rim, cliffs: cliffs) }
        var d = bfs(s, w)
        var reach = 0
        for c in 0..<(G * G) where w[c] == 1 && d[c] >= 0 { reach += 1 }
        func ringD(_ x: Double, _ z: Double) -> Int {
            var m = Int.max
            for j in -4...4 {
                for i in -4...4 {
                    if i * i + j * j > 16 { continue }
                    let c = cellOf(x + Double(i), z + Double(j))
                    if c >= 0 && d[c] >= 0 { m = min(m, Int(d[c])) }
                }
            }
            return m
        }
        let unreachable = StationCheck(ok: false, why: "unreachable", tour: 0, floor: floor, reach: 0, rim: rim, cliffs: cliffs)
        for b in L.beacons where ringD(b.x, b.z) == Int.max { return unreachable }
        if ringD(T.x, T.z) == Int.max { return unreachable }
        // greedy tour start -> nearest unvisited beacon -> ... -> lift
        var tour = 0
        var left = L.beacons
        while !left.isEmpty {
            var bi = 0, bv = Int.max
            for (k, b) in left.enumerated() {
                let c = cellOf(b.x + 2.5, b.z + 2.5)
                let v = c >= 0 && d[c] >= 0 ? Int(d[c]) : Int.max
                if v < bv { bv = v; bi = k }
            }
            if bv == Int.max { return unreachable }
            tour += bv
            let nc = cellOf(left[bi].x + 2.5, left[bi].z + 2.5)
            d = bfs(nc, w)
            left.remove(at: bi)
        }
        let lc = cellOf(T.x, T.z)
        if lc < 0 || d[lc] < 0 { return unreachable }
        tour += Int(d[lc])
        let reachFrac = Double(reach) / Double(max(1, floor))
        let why = cliffs > 0 ? "cliff" : (reachFrac <= REACH ? "pockets" : ((tour < TOUR_MIN || tour > TOUR_MAX) ? "tour" : (rim == 0 ? "rim" : "")))
        return StationCheck(ok: why.isEmpty, why: why, tour: tour, floor: floor, reach: (reachFrac * 1000).rounded() / 1000, rim: rim, cliffs: cliffs)
    }

    /// The hand-made «Кельвин-9» as a GeneratedStation (web HAND_LEVEL; genCheck ok, tour 243, rim 18).
    public static var kelvin: GeneratedStation {
        let L = KelvinStation().makeLayout(seed: 0)
        return GeneratedStation(
            rects: L.rects.map { r in
                let h: GenHeight
                switch r.height {
                case .flat(let v): h = .flat(Double(v))
                case .ramp(let a, let ha, let b, let hb, let st): h = .ramp(a: Double(a), ha: Double(ha), b: Double(b), hb: Double(hb), stairs: st)
                }
                return GenRect(x0: Double(r.x0), z0: Double(r.z0), x1: Double(r.x1), z1: Double(r.z1), slab: r.kind == .slab, hazard: r.hazard, height: h)
            },
            crates: L.crates.map { GenCrate(x0: Double($0.x0), z0: Double($0.z0), w: $0.w, d: $0.d, h: Double($0.h)) },
            pillars: L.pillars.map { (Double($0.x), Double($0.y)) }, vents: L.vents.map { (Double($0.x), Double($0.y)) },
            pipes: L.pipes.map { GenPipe(x0: Double($0.x0), z0: Double($0.z0), x1: Double($0.x1), z1: Double($0.z1), h: Double($0.h)) },
            start: (Double(L.start.x), Double(L.start.y)), pad: [Double(L.pad.x), Double(L.pad.y), Double(L.pad.z), Double(L.pad.w)],
            lift: (Double(L.lift.x), Double(L.lift.z), Double(L.lift.r), Double(L.lift.y)),
            beacons: L.beacons.map { GenBeacon(x: Double($0.x), z: Double($0.z), name: $0.name) },
            rowH: [], nodes: 0, startNode: -1, liftNode: -1, beaconNodes: [], edges: 0)
    }
}
