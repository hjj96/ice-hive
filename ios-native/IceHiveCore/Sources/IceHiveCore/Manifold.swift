import Foundation

// ================================================================
//  THE MANIFOLD (Stage 2 B4; design §1.5 «Arena: the Manifold», §1.6
//  «Manifold», §3.4 «Boss mission») — the junction of Kelvin-9's main pipe
//  trunks, the Threader's arena, as layout data:
//    ISLAND     a 14 × 14 m deck at the centre with the PUMP HOUSING, a
//               4 × 4 m block of cover (2.6 m high) in its middle
//    RING       a 4 m catwalk ring round it at 15 m (a square: 13…17 m out),
//               four radial BRIDGES (3 m wide) to the island
//    OVERHEAD   four pipe TRUNKS at 5 m — the «#» over the island, out to
//               the ring (deck posts: their legs on the ring) and on to
//               abyss risers just outside it — the Threader's highway, and
//               the RING DUCT at 8 m (its retreat loop) joined to every
//               trunk's leg by a riser pipe; four DUCT MOUTHS at the ring's
//               corners; four STEAM VALVES (R6's props) on the trunks over
//               the island — all of it R2's overhead routes: the hive walks
//               them too, and the Droppers the Threader sheds are R4's
//    BELOW      the abyss
//  The approach: a landing pad south-east of the ring (the camera's side),
//  two pump consoles on the walkway to the ring (the mission's warm-up), and
//  the extraction lift beyond the ring's north-west corner.
//  `LevelLayout.manifold` carries the arena's pieces for the simulation (the
//  trunks the Threader squeezes, spits along and pulls down) and for the
//  renderer and the kit (B5 / B2: where the trunks, the duct, the mouths, the
//  valves, the pump housing, the bridges and the ring stand).
//  The mission (`MissionTemplate.manifold`): SWITCH ×2 — restart the pumps
//  (the warm-up fights; the pumps' rumble draws it out) → BOSS the Threader
//  on the island → EXTRACT at the lift. Its own calibration preset (`bosses`)
//  is gated on the boss bands (packages.md «B4»).
// ================================================================

/// One of the Manifold's four pipe trunks (the «#» at 5 m): a straight run from riser to riser across the arena.
public struct ManifoldTrunk: Equatable {
    /// Its two ends in plan (the abyss risers just outside the ring) and its height (absolute, m).
    public var a: Vec2
    public var b: Vec2
    public var y: Float
    /// Its route edges in the station's overhead layout, in order from `a` to `b`.
    public var edges: [Int]
    /// Its steam valve (an index into `PropLayout.valves`, R6's prop), -1 none.
    public var valve: Int
    /// The squeeze's burst points along it (m from `a`): the valves of its pipe burst there in turn (design §1.5 «Squeeze»).
    public var bursts: [Float]

    public init(a: Vec2, b: Vec2, y: Float, edges: [Int], valve: Int, bursts: [Float]) {
        self.a = a; self.b = b; self.y = y; self.edges = edges; self.valve = valve; self.bursts = bursts
    }

    public var length: Float { hypotf2(b.x - a.x, b.y - a.y) }
    /// Unit direction a → b (plan).
    public var dir: Vec2 { let l = max(1e-4, length); return Vec2((b.x - a.x) / l, (b.y - a.y) / l) }
    /// The point `s` m from `a` (plan).
    public func point(_ s: Float) -> Vec2 { let d = dir; return Vec2(a.x + d.x * s, a.y + d.y * s) }
    /// Plan distance from (x, z) to its line (clamped to the run) and the distance along it.
    public func project(_ x: Float, _ z: Float) -> (d: Float, s: Float) {
        let d = dir, l = length
        let s = clampf((x - a.x) * d.x + (z - a.y) * d.y, 0, l)
        return (hypotf2(x - (a.x + d.x * s), z - (a.y + d.y * s)), s)
    }
}

/// The Manifold's pieces (pure data; `LevelLayout.manifold`). Plan rects are (x0, z0, x1, z1).
public struct ManifoldArena: Equatable {
    /// The arena's centre (the island's), the island, the pump housing on it and the housing's height.
    public var center: Vec2
    public var island: SIMD4<Float>
    public var pump: SIMD4<Float>
    public var pumpHeight: Float
    /// The catwalk ring: a square band `ringIn`…`ringOut` m out from the centre.
    public var ringIn: Float
    public var ringOut: Float
    /// The four radial bridges island ↔ ring.
    public var bridges: [SIMD4<Float>]
    /// The trunks (0, 1 along x at z −3.5 / +3.5; 2, 3 along z at x −3.5 / +3.5) and their height.
    public var trunks: [ManifoldTrunk]
    public var trunkHeight: Float
    /// The trunks' legs on the ring (deck posts; their riser pipes climb from there to the ring duct).
    public var legs: [SIMD3<Float>]
    /// The ring duct: a square `ductHalf` m out at `ductHeight` m.
    public var ductHalf: Float
    public var ductHeight: Float
    /// The duct mouths (x, absolute y, z) at the ring's corners.
    public var mouths: [SIMD3<Float>]
    /// The steam valves on the trunks (x, absolute y, z; R6's props, same order as the layout's valves).
    public var valves: [SIMD3<Float>]
    /// The squeeze: half the length of a burst's curtain along its trunk, and its half-width on the deck (m).
    public var burstHalf: Float
    public var burstWidth: Float
    /// The pull-down: the island cells a fallen trunk leaves open in its snapped middle (|along − centre| < this, m).
    public var pullGap: Float

    public init(center: Vec2, island: SIMD4<Float>, pump: SIMD4<Float>, pumpHeight: Float, ringIn: Float, ringOut: Float,
                bridges: [SIMD4<Float>], trunks: [ManifoldTrunk], trunkHeight: Float, legs: [SIMD3<Float>], ductHalf: Float,
                ductHeight: Float, mouths: [SIMD3<Float>], valves: [SIMD3<Float>], burstHalf: Float, burstWidth: Float, pullGap: Float) {
        self.center = center; self.island = island; self.pump = pump; self.pumpHeight = pumpHeight; self.ringIn = ringIn
        self.ringOut = ringOut; self.bridges = bridges; self.trunks = trunks; self.trunkHeight = trunkHeight; self.legs = legs
        self.ductHalf = ductHalf; self.ductHeight = ductHeight; self.mouths = mouths; self.valves = valves
        self.burstHalf = burstHalf; self.burstWidth = burstWidth; self.pullGap = pullGap
    }

    /// The trunk whose line passes nearest to (x, z) in plan (−1 none).
    public func nearestTrunk(_ x: Float, _ z: Float) -> Int {
        var best = -1
        var bd: Float = .infinity
        for (k, t) in trunks.enumerated() {
            let d = t.project(x, z).d
            if d < bd { bd = d; best = k }
        }
        return best
    }

    /// (x, z) is on the island (plan).
    @inline(__always) public func onIsland(_ x: Float, _ z: Float) -> Bool {
        x > island.x && x < island.z && z > island.y && z < island.w
    }
}

/// The Manifold's numbers and builders (the station `ManifoldStation`, the plan of `MissionTemplate.manifold`).
public enum Manifold {
    /// Trunk height, ring duct height and half-size, trunk offset from the centre, riser and leg distances (design §1.5).
    public static let trunkY: Float = 5
    public static let ductY: Float = 8
    public static let ductHalf: Float = 16
    public static let trunkOff: Float = 3.5
    public static let riserAt: Float = 17.5
    public static let legAt: Float = 15
    /// The landing pad, the start, the extraction lift (beyond the ring's north-west corner).
    public static let pad = SIMD4<Float>(22, 22, 34, 34)
    public static let start = Vec2(28, 28)
    public static let lift = LiftSpec(x: -29, z: -15, r: 6, y: 0)
    /// The boss arena (the BOSS step's zone): the island, r 7.
    public static let zone = MissionZone.circle(x: 0, z: 0, r: 7)
    /// The pump consoles of the warm-up (SWITCH ×2): on the walkway north of the pad and at the ring's south-east corner.
    public static let pumpSites: [Vec2] = [Vec2(26, 19.5), Vec2(15, 15)]
    /// Seconds in a pump console's ring, its radius (the walkway is 4 m wide).
    public static let pumpTime: Float = 15
    public static let pumpRadius: Float = 2.0

    // ---------------------------------------------------------------- the overhead

    /// The route set: the four trunks (each riser → leg (deck post) → crossing → crossing → leg → riser, pipes at 5 m), the
    /// ring duct (12 nodes at 8 m, ducts), the eight riser pipes leg → duct, and the four duct mouths under the duct's
    /// corners (a duct up to the corner). Node order: the four crossings, each trunk's risers and legs, the duct loop from
    /// its north-west corner clockwise in plan (+x first), the mouths. Built once (`arena` reads the trunks' edge ids).
    public static let overhead: OverheadLayout = build().0

    /// The arena's pieces (its trunks carry their route edge ids in `overhead`).
    public static let arena: ManifoldArena = build().1

    static func build() -> (OverheadLayout, ManifoldArena) {
        var o = OverheadLayout()
        let y = trunkY, t = trunkOff
        // the crossings (−,−), (+,−), (−,+), (+,+)
        let X: [Int32] = [o.addNode(-t, y, -t, .joint), o.addNode(t, y, -t, .joint), o.addNode(-t, y, t, .joint), o.addNode(t, y, t, .joint)]
        // the trunks: 0 along x at z −t, 1 along x at z +t, 2 along z at x −t, 3 along z at x +t
        struct T { var ra: Int32, pa: Int32, xa: Int32, xb: Int32, pb: Int32, rb: Int32 }
        var tr: [T] = []
        for k in 0..<4 {
            let alongX = k < 2
            let off: Float = (k == 0 || k == 2) ? -t : t
            func p(_ u: Float) -> (Float, Float) { alongX ? (u, off) : (off, u) }
            let (rax, raz) = p(-riserAt), (pax, paz) = p(-legAt), (pbx, pbz) = p(legAt), (rbx, rbz) = p(riserAt)
            let ra = o.addNode(rax, y, raz, .abyssRiser, riserFrom: -8)
            let pa = o.addNode(pax, y, paz, .deckPost, riserFrom: 0)
            let pb = o.addNode(pbx, y, pbz, .deckPost, riserFrom: 0)
            let rb = o.addNode(rbx, y, rbz, .abyssRiser, riserFrom: -8)
            // its crossings in order along the run
            let xa = alongX ? (k == 0 ? X[0] : X[2]) : (k == 2 ? X[0] : X[1])
            let xb = alongX ? (k == 0 ? X[1] : X[3]) : (k == 2 ? X[2] : X[3])
            tr.append(T(ra: ra, pa: pa, xa: xa, xb: xb, pb: pb, rb: rb))
        }
        var trunkEdges: [[Int]] = []
        for T in tr {
            trunkEdges.append([o.addEdge(T.ra, T.pa, .pipe), o.addEdge(T.pa, T.xa, .pipe), o.addEdge(T.xa, T.xb, .pipe),
                               o.addEdge(T.xb, T.pb, .pipe), o.addEdge(T.pb, T.rb, .pipe)])
        }
        // the ring duct, clockwise in plan from its north-west corner: north side (+x), east side (+z), south (−x), west (−z)
        let h = ductHalf, dy = ductY
        let loop: [(Float, Float)] = [(-h, -h), (-t, -h), (t, -h), (h, -h), (h, -t), (h, t), (h, h), (t, h), (-t, h), (-h, h), (-h, t), (-h, -t)]
        var D: [Int32] = []
        for (x, z) in loop { D.append(o.addNode(x, dy, z, .joint)) }
        for k in 0..<D.count { o.addEdge(D[k], D[(k + 1) % D.count], .duct) }
        // riser pipes from each leg up to the duct beside it
        func ductAt(_ x: Float, _ z: Float) -> Int32 {
            var best: Int32 = D[0]
            var bd: Float = .infinity
            for n in D {
                let p = o.nodes[Int(n)].p
                let d = (p.x - x) * (p.x - x) + (p.z - z) * (p.z - z)
                if d < bd { bd = d; best = n }
            }
            return best
        }
        for T in tr {
            for leg in [T.pa, T.pb] {
                let p = o.nodes[Int(leg)].p
                o.addEdge(leg, ductAt(p.x * h / legAt, p.z * h / legAt), .pipe)
            }
        }
        // the duct mouths at the ring's corners, under the duct's corners (a short duct up to it)
        var mouths: [SIMD3<Float>] = []
        for (x, z) in [(Float(-1), Float(-1)), (1, -1), (1, 1), (-1, 1)] {
            let m = o.addNode(x * 14.8, 4.6, z * 14.8, .ductMouth)
            o.addEdge(m, ductAt(x * h, z * h), .duct)
            mouths.append(o.nodes[Int(m)].p)
        }
        // the arena's pieces
        var trunks: [ManifoldTrunk] = []
        let bursts: [Float] = [4, 13.5, 21.5, 31]
        for k in 0..<4 {
            let T = tr[k]
            let a = o.nodes[Int(T.ra)].p, b = o.nodes[Int(T.rb)].p
            trunks.append(ManifoldTrunk(a: Vec2(a.x, a.z), b: Vec2(b.x, b.z), y: y, edges: trunkEdges[k], valve: k, bursts: bursts))
        }
        var legs: [SIMD3<Float>] = []
        for T in tr { legs.append(o.nodes[Int(T.pa)].p); legs.append(o.nodes[Int(T.pb)].p) }
        let A = ManifoldArena(
            center: Vec2(0, 0), island: SIMD4(-7, -7, 7, 7), pump: SIMD4(-2, -2, 2, 2), pumpHeight: 2.6, ringIn: 13, ringOut: 17,
            bridges: [SIMD4(7, -1.5, 13, 1.5), SIMD4(-13, -1.5, -7, 1.5), SIMD4(-1.5, 7, 1.5, 13), SIMD4(-1.5, -13, 1.5, -7)],
            trunks: trunks, trunkHeight: y, legs: legs, ductHalf: h, ductHeight: dy, mouths: mouths,
            valves: valveSites.map { SIMD3($0.x, $0.y, $0.z) }, burstHalf: 3.5, burstWidth: 1.5, pullGap: 1.0)
        return (o, A)
    }

    /// The four steam valves (R6's props), one per trunk over the island's edge — a pinwheel: trunk 0 west, 1 east, 2 south,
    /// 3 north — their scald curtains under the trunk from the island's edge to its crossing.
    public static let valveSites: [ValveSite] = {
        let t = trunkOff, y = trunkY
        return [
            ValveSite(x: -5.25, y: y, z: -t, from: Vec2(-7, -t), to: Vec2(-t, -t), width: 1.4),
            ValveSite(x: 5.25, y: y, z: t, from: Vec2(t, t), to: Vec2(7, t), width: 1.4),
            ValveSite(x: -t, y: y, z: 5.25, from: Vec2(-t, t), to: Vec2(-t, 7), width: 1.4),
            ValveSite(x: t, y: y, z: -5.25, from: Vec2(t, -7), to: Vec2(t, -t), width: 1.4),
        ]
    }()

    // ---------------------------------------------------------------- the mission

    /// The pump consoles (SWITCH sites, `.panel`): `pumpTime` s in each ring.
    public static func pumps(_ lv: Level) -> [SwitchSite] {
        pumpSites.map { p in
            let c = lv.canStand(p.x, p.y) ? p : (lv.openSpot(near: p, from: 0, to: 6, clearance: 1.0) ?? p)
            return SwitchSite(x: c.x, z: c.y, radius: pumpRadius, time: pumpTime, kind: .panel)
        }
    }

    /// The hive's stream on Recruit, Veteran, Nightmare for the whole mission (the plan's `tierStream`).
    public static let tierStream: [Float] = [1, 1, 1]

    /// SWITCH ×2 (restart the pumps: a surge at each, a push at half, the ring drains while nobody holds it) → BOSS the
    /// Threader on the island (3 s after the player steps onto it) → EXTRACT at the lift.
    public static func plan(_ lv: Level) -> MissionPlan {
        var sw = SwitchStep(sites: pumps(lv))
        sw.alarm = PacingValue(legacy: 80, waves: 20)
        sw.pushes = [0.5]
        sw.pushK = 0.8
        sw.drains = 0.5
        sw.lineText = .objRestartPumps
        sw.throwText = .objHoldPump
        sw.names = StepNames(approach: "pumps", active: "pump")
        sw.stripText = .reportStripPump
        sw.scoreText = .scorePumps
        sw.score = 250
        var boss = BossStep(.threader, zone: zone, delay: 3)
        boss.stripText = .reportStripThreader
        boss.names = StepNames(approach: "toBoss", active: "boss")
        var ex = ExtractStep()
        ex.stripText = .reportStripExtract
        var plan = MissionPlan(id: "manifold", steps: [.switches(sw), .boss(boss), .extract(ex)],
                               briefing: BannerText(title: .bannerManifold, sub: .bannerManifoldSub))
        plan.tierStream = tierStream
        return plan
    }
}

/// «The Manifold» as a station (a sector of Kelvin-9: its name in the banners is the station's): the island with its pump
/// housing, the ring and its bridges, the approach from the landing pad, the lift; the trunks, the ring duct and the duct
/// mouths as overhead routes; the steam valves as R6's props; the arena's pieces in `LevelLayout.manifold`.
public struct ManifoldStation: LevelSource {
    public init() {}

    public func makeLayout(seed: UInt32) -> LevelLayout {
        let A = Manifold.arena
        var rects: [FloorRect] = [
            FloorRect(A.island.x, A.island.y, A.island.z, A.island.w, .grating, false, .flat(0)),      // the island
            FloorRect(-17, -17, 17, -13, .grating, false, .flat(0)),                                       // the ring: north
            FloorRect(-17, 13, 17, 17, .grating, false, .flat(0)),                                         // south
            FloorRect(-17, -13, -13, 13, .grating, false, .flat(0)),                                       // west
            FloorRect(13, -13, 17, 13, .grating, false, .flat(0)),                                         // east
        ]
        for b in A.bridges { rects.append(FloorRect(b.x, b.y, b.z, b.w, .grating, false, .flat(0))) }
        rects += [
            FloorRect(Manifold.pad.x, Manifold.pad.y, Manifold.pad.z, Manifold.pad.w, .slab, true, .flat(0)),   // the landing pad
            FloorRect(24, 17, 28, 22, .grating, false, .flat(0)),                                           // pad → walkway north
            FloorRect(17, 13, 28, 17, .grating, false, .flat(0)),                                           // walkway west → the ring
            FloorRect(-24, -17, -17, -13, .grating, false, .flat(0)),                                       // the ring → the lift
        ]
        let p = A.pump
        let crates = [CrateSpec(p.x, p.y, Int(p.z - p.x), Int(p.w - p.y), A.pumpHeight)]
        var L = LevelLayout(name: .kelvin, seed: seed, rects: rects, crates: crates, pillars: [], start: Manifold.start, lift: Manifold.lift,
                            beacons: [], vents: [], pipes: [])
        L.pad = Manifold.pad
        L.overhead = Manifold.overhead
        L.props = PropLayout(valves: Manifold.valveSites)
        L.manifold = A
        return L
    }
}

extension MissionTemplate {
    /// The boss missions (Stage 2: the Manifold), after R7's missions in the title's mission choice.
    public static var bosses: [MissionTemplate] { [manifold] }

    /// Its gate (packages.md «B4», design §1.5 / tech §5.4): Recruit wins ≥ 90 %; Veteran — the boss reached in ≥ 75 % of the
    /// runs and killed in ≥ 80 % of those, its kill median 60–100 s; Nightmare wins ≤ 30 %. Reported (not gated): Veteran
    /// wins in the classic 70–85 %, Recruit ≤ 0.5 squad downs, the AFK first downs of every mission (an idle squad on the
    /// landing pad holds the walkway: the approach is not the boss's gate).
    static let manifoldBands = [CalibBand(tier: 0, winLo: 90),
                                CalibBand(tier: 1, bossReachedLo: 75, bossKilledLo: 80, bossMedianLo: 60, bossMedianHi: 100),
                                CalibBand(tier: 2, winHi: 30)]
    static let manifoldInfo = [CalibBand(tier: 0, downsHi: 0.5), CalibBand(tier: 1, winLo: 70, winHi: 85)]

    /// «Manifold» (design §1.6): a short approach — restart two pumps under fire — → BOSS the Threader → EXTRACT. Its preset is
    /// `bosses` (calib-bosses.jsonl): 8 runs per class on Recruit and Nightmare, 16 on Veteran, one AFK run per class on
    /// Veteran and Recruit, seeds from its own base.
    public static let manifold = MissionTemplate(id: "manifold", name: .missionManifold, station: ManifoldStation(),
                                                 calib: MissionCalib(tiers: [0, 1, 2], runs: 8, tierRuns: [1: 16], seedBase: 500_000,
                                                                     bands: manifoldBands, afk: missionAFK, gated: true, preset: "bosses",
                                                                     info: manifoldInfo, afkGated: false)) { Manifold.plan($0) }
}
