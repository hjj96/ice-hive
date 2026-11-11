import XCTest
@testable import IceHiveCore

/// Stage 1 R2 «Overhead core»: route data and validation, the generator post-pass, route movement and transitions, the
/// sentinel bucket, the drop's timing and telegraph, the hit rules, caps and fairness, the director's channel,
/// determinism, and the classic mission untouched with the overhead off.

/// A game on «Кельвин-9» with the demo slice (the pad → hub rack), the director off unless asked, the bots holding fire.
func sliceGame(_ tier: Difficulty = .veteran, seed: UInt32 = 7, cls: MarineClass = .assault, god: Bool = false, director: Bool = false,
               holdFire: Bool = true, configure: ((inout GameConfig) -> Void)? = nil) -> Game {
    var c = GameConfig()
    c.difficulty = tier
    c.autoPickUpgrades = true
    c.god = god
    c.levelSource = KelvinStation(overhead: .kelvinSlice)
    configure?(&c)
    let g = Game(seed: seed, playerClass: cls, config: c)
    g.directorEnabled = director
    g.debugHoldFire = holdFire
    g.clearEvents()
    return g
}

/// Slice node ids (OverheadLayout.kelvinSlice): pad post, junction, abyss riser, hub post, duct mouth.
let SL_PAD = 0, SL_J = 1, SL_RISER = 2, SL_HUB = 3, SL_DUCT = 4

extension Game {
    /// Put marine k at (x, z) (tests).
    func place(_ k: Int, _ x: Float, _ z: Float) {
        let m = marines[k]
        m.x = x; m.z = z; m.px = x; m.pz = z; m.vx = 0; m.vz = 0
    }
    /// The squad: the player at (x, z), the bots far away on the hub and down (only the player can be targeted).
    func playerAlone(_ x: Float, _ z: Float) {
        for k in 1..<4 { place(k, -6 + Float(k), 36); debugHurt(marine: k, hp: 0) }
        place(0, x, z)
        updateFlows()
    }
}

final class OverheadDataTests: XCTestCase {
    func testSliceIsAValidRouteSet() {
        let L = Level(source: KelvinStation(overhead: .kelvinSlice), seed: 1)
        let G = try! XCTUnwrap(L.overhead)
        XCTAssertEqual(G.nodeCount, 5)
        XCTAssertEqual(G.edgeCount, 4)
        XCTAssertEqual(G.entries, [SL_RISER, SL_DUCT], "the riser and the duct mouth spawn packs")
        XCTAssertEqual(G.posts, [SL_PAD, SL_HUB])
        XCTAssertEqual(G.componentCount, 1)
        XCTAssertEqual(G.nodeEdges[SL_J], [0, 1, 3], "the junction joins the pad leg, the riser leg and the duct")
        let chk = OverheadCheck.check(.kelvinSlice, level: L)
        XCTAssertTrue(chk.ok, chk.why)
        XCTAssertLessThanOrEqual(chk.footprint, 0.04)
        XCTAssertEqual(chk.length, 23, accuracy: 0.05)
        // every leg of the rack can drop onto the bridge (the far rail is 1.1 m from the walkway)
        for e in 0..<3 { XCTAssertLessThan(G.w0[e], G.w1[e], "edge \(e) has a drop window") }
        // heights are absolute: 4.5 m over the deck at 0
        XCTAssertEqual(G.point(1, G.length[1] / 2).y, 4.5)
        XCTAssertEqual(G.point(3, 0).y, 5.0)
        // the golden hash (quantised to 1/64 m: the same on every platform)
        XCTAssertEqual(OverheadLayout.kelvinSlice.hash, OverheadGoldens.slice)
    }

    func testClassicKelvinHasNoRoutes() {
        XCTAssertTrue(KelvinStation().makeLayout(seed: 1).overhead.isEmpty)
        XCTAssertNil(Level(source: KelvinStation(), seed: 1).overhead)
        XCTAssertNil(Level(source: StationGenerator(), seed: 0).overhead, "seed 0 is the hand-made station")
    }

    func testRouteCheckRejectsBadSets() {
        let L = Level(source: KelvinStation(), seed: 1)
        // a catwalk (wide) across the walkway of the pad → hub bridge
        var wide = OverheadLayout()
        let a = wide.addNode(14, 4.5, 25, .abyssRiser, riserFrom: -5), b = wide.addNode(14, 4.5, 31, .joint)
        wide.addEdge(a, b, .catwalk)
        XCTAssertEqual(OverheadCheck.check(wide, level: L).why, "wide")
        // too low over the deck
        var low = OverheadLayout()
        let c = low.addNode(10, 2, 26.4, .abyssRiser, riserFrom: -5), d = low.addNode(18, 2, 26.4, .joint)
        low.addEdge(c, d, .pipe)
        XCTAssertEqual(OverheadCheck.check(low, level: L).why, "height")
        // no way up: a lone span with neither a riser nor a post nor a duct mouth
        var lone = OverheadLayout()
        let e = lone.addNode(10, 4.5, 26.4, .joint), f = lone.addNode(18, 4.5, 26.4, .gantry)
        lone.addEdge(e, f, .pipe)
        XCTAssertEqual(OverheadCheck.check(lone, level: L).why, "reach")
        // over a beacon ring (Alpha at (−32, 27))
        var beacon = OverheadLayout()
        let g = beacon.addNode(-38, 4.5, 26, .abyssRiser, riserFrom: -5), h = beacon.addNode(-28, 4.5, 26, .joint)
        beacon.addEdge(g, h, .cable)
        XCTAssertEqual(OverheadCheck.check(beacon, level: L).why, "beacon")
    }

    func testGeneratedStationsGetValidRoutesOnTheirOwnStream() {
        var withRoutes = 0
        for seed in UInt32(1)...20 {
            let L = StationGenerator().makeLayout(seed: seed)
            let again = StationGenerator().makeLayout(seed: seed)
            XCTAssertEqual(L.overhead, again.overhead, "seed \(seed): deterministic")
            if L.overhead.isEmpty { continue }
            withRoutes += 1
            var bare = L
            bare.overhead = OverheadLayout()
            let chk = OverheadCheck.check(L.overhead, level: Level(layout: bare))
            XCTAssertTrue(chk.ok, "seed \(seed): \(chk.why)")
            XCTAssertGreaterThan(Level(layout: L).overhead?.entries.count ?? 0, 0, "seed \(seed): packs can climb up")
            // racks hang on the far side: every node is over the void or a deck end (thin pipes only over walkable deck)
            for e in L.overhead.edges where !e.kind.isThin {
                let p = L.overhead.nodes[Int(e.a)].p
                XCTAssertEqual(Level(layout: bare).walkValue(Level(layout: bare).cellOf(p.x, p.z)), 0, "seed \(seed): a wide route over the void")
            }
        }
        XCTAssertGreaterThanOrEqual(withRoutes, 15, "most generated stations have corridors to hang racks on")
        // golden: the post-pass of three seeds (its own random stream; quantised data)
        for (seed, h) in OverheadGoldens.stations {
            XCTAssertEqual(StationGenerator().makeLayout(seed: seed).overhead.hash, h, "seed \(seed)")
        }
    }

    func testTiersKeepTheFairnessNumbers() {
        // (Stage 1 R5: the overhead is on for the classic mission — tech.md §2.3's 0.15 / 0.20 / 0.25 as the start, Nightmare
        // recalibrated to 0.20 inside the bands; the legacy v1.0 row keeps it off)
        XCTAssertEqual(Difficulty.tiers.map { $0.routes }, [0.15, 0.2, 0.2])
        for d in Difficulty.tiers {
            XCTAssertGreaterThan(d.routes, 0, "\(d.id): the overhead is on since package R5")
            XCTAssertGreaterThanOrEqual(d.dropWarn, 0.9, "\(d.id): no drop lands without 0.9 s of warning")
            XCTAssertLessThanOrEqual(d.routeCap, 18)
            XCTAssertLessThanOrEqual(d.dropCap, 3)
            XCTAssertGreaterThan(d.dropWarn - DROP_T, 0.3, "\(d.id): a coil to read")
        }
        XCTAssertEqual(Difficulty.recruit.dropWarn, Difficulty.veteran.dropWarn + 0.3, accuracy: 1e-6, "Recruit adds 0.3 s")
        XCTAssertEqual(Difficulty.legacyV10.routes, 0)
        var d = Difficulty.veteran
        XCTAssertEqual(d.override(["routes": 0.2, "routeCap": 9, "dropCap": 2, "dropWarn": 1.1, "dropK": 1.3, "dropGap": 1]), [])
        XCTAssertEqual(d.routes, 0.2, accuracy: 1e-6)
        XCTAssertEqual(d.routeCap, 9)
        XCTAssertEqual(d.dropCap, 2)
        XCTAssertEqual(d.dropWarn, 1.1, accuracy: 1e-6)
    }
}

final class OverheadMovementTests: XCTestCase {
    /// Plan distance from (x, z) to the slice's route polyline and the route height there.
    func onRoute(_ g: Game, _ i: Int) -> (dist: Float, dy: Float) {
        let G = g.level.overhead!
        var best: Float = .infinity, dy: Float = 0
        for e in 0..<G.edgeCount {
            let pr = G.project(e, g.bugs.x[i], g.bugs.z[i])
            if pr.d2 < best { best = pr.d2; dy = g.bugs.y[i] - G.point(e, pr.s).y }
        }
        return (best.squareRoot(), dy)
    }

    func testRiserClimbThenAlongTheRackAndWaitAboveItsMarine() {
        let g = sliceGame()
        g.debugTeleport(0, 36)   // the squad on the hub, 9.6 m from the rack: nothing in drop range
        let i = g.debugSpawnRouteBug(entry: SL_RISER)
        XCTAssertGreaterThanOrEqual(i, 0)
        let S = g.bugs
        XCTAssertEqual(S.state(i), .riser)
        XCTAssertEqual(S.y[i], -5, "it starts at the foot of the abyss column")
        XCTAssertTrue(S.isOverhead(i))
        var lastY = S.y[i]
        var t = 0
        while S.state(i) == .riser && t < 600 {
            g.tick(); t += 1
            XCTAssertGreaterThanOrEqual(S.y[i], lastY)
            XCTAssertEqual(S.x[i], 14, accuracy: 1e-4); XCTAssertEqual(S.z[i], 26.4, accuracy: 0.01)
            lastY = S.y[i]
        }
        XCTAssertEqual(S.state(i), .high, "on the rack after the climb")
        XCTAssertLessThan(Float(t) / 60, 4.5, "≈ 9.5 m at 2.4–3.4 m/s")
        XCTAssertEqual(S.y[i], 4.5, accuracy: 1e-4)
        // along the rack toward the hub end (the squad's projection on the route), riding on top of it, then waiting
        for _ in 0..<(60 * 6) {
            g.tick()
            let r = onRoute(g, i)
            XCTAssertLessThan(r.dist, 1e-3, "on the route")
            XCTAssertEqual(r.dy, 0, accuracy: 1e-3, "at the route's height")
            XCTAssertTrue(S.isOverhead(i))
        }
        XCTAssertEqual(S.state(i), .high)
        XCTAssertEqual(S.x[i], 4, accuracy: 0.05, "waiting at the hub end, the point of the route nearest its marine")
        XCTAssertEqual(g.activeDropZones, 0, "out of drop range: no telegraph")
        XCTAssertEqual(g.overheadStats.drops, 0)
        XCTAssertFalse(g.hasNonFinite())
    }

    func testJunctionLeadsTowardTheMarine() {
        for (squad, wantX) in [((Float(30), Float(30)), Float(24)), ((Float(0), Float(36)), Float(4))] {
            let g = sliceGame()
            g.debugTeleport(squad.0, squad.1)
            let i = g.debugSpawnRouteBug(entry: SL_DUCT)
            XCTAssertEqual(g.bugs.state(i), .high, "straight onto the duct out of its mouth")
            XCTAssertEqual(g.bugs.y[i], 5.0, accuracy: 1e-4)
            for _ in 0..<(60 * 8) { g.tick() }
            XCTAssertEqual(g.bugs.x[i], wantX, accuracy: 0.6, "squad at \(squad): along the leg toward it")
            XCTAssertEqual(g.bugs.z[i], 26.4, accuracy: 0.01, "(1/64 m quantised)")
        }
    }

    func testRouteBugsAreOutOfEveryDeckQuery() {
        let g = sliceGame()
        g.debugTeleport(0, 36)
        let up = g.debugSpawnRouteBug(entry: SL_DUCT)
        let deck = g.spawnBug(T_RUN, 19, 28)
        g.tick()
        let S = g.bugs
        XCTAssertTrue(S.isOverhead(up)); XCTAssertFalse(S.isOverhead(deck))
        XCTAssertEqual(g.hash.overheadCount, 1)
        let ux = S.x[up], uz = S.z[up]
        let n = g.hash.queryCircle(S, ux, uz, 6)
        let found = (0..<n).map { g.hash.qb[$0] }
        XCTAssertFalse(found.contains(up), "queryCircle never sees a bug up on a route")
        XCTAssertTrue(found.contains(deck))
        XCTAssertFalse(g.bugsInCircle(Vec2(ux, uz), radius: 6).contains(up))
        // a ray / a segment straight through its footprint: the deck tests skip it (the footprint rule is the overhead's own)
        let ray = g.raycastBugs(origin: Vec2(ux - 5, uz), dir: Vec2(1, 0), maxDistance: 10)
        XCTAssertNotEqual(ray.bug, up)
        XCTAssertNotEqual(g.hash.segmentHit(S, ux - 5, uz, 1, 0, 10, -1).0, up)
        XCTAssertEqual(g.overheadSegmentHit(ux - 5, uz, 1, 0, 10, -1).0, up, "… and the footprint test finds it")
    }
}

final class OverheadDropTests: XCTestCase {
    /// Run until a drop telegraph is live (max `seconds`); returns its slot.
    func untilZone(_ g: Game, seconds: Float = 12, _ events: inout [GameEvent]) -> Int? {
        for _ in 0..<Int(seconds * 60) {
            g.tick()
            g.drainEvents { events.append($0) }
            if let k = g.dropZones.firstIndex(where: { $0.active }) { return k }
        }
        return nil
    }

    func testTelegraphTimingAndTheFixedLandingPoint() {
        for tier in Difficulty.tiers {
            let g = sliceGame(tier)
            g.playerAlone(14, 29)
            let i = g.debugSpawnRouteBug(entry: SL_RISER)
            var ev: [GameEvent] = []
            guard let k = untilZone(g, &ev) else { return XCTFail("\(tier.id): no drop") }
            let z = g.dropZones[k]
            XCTAssertEqual(z.marine, 0)
            XCTAssertEqual(z.warn, tier.dropWarn, accuracy: 1e-6)
            XCTAssertEqual(g.bugs.state(i), .coil)
            XCTAssertEqual(z.x, 14, accuracy: 1e-4, "on the marine standing still"); XCTAssertEqual(z.z, 29, accuracy: 1e-4)
            XCTAssertTrue(ev.contains { if case .dropWarned(_, let to, let eta) = $0 { return to == Vec2(z.x, z.z) && eta == tier.dropWarn }; return false })
            // the ring: a closing pink-white `.dropZone` ring for the whole warning
            let tele = try! XCTUnwrap(g.telegraphs.first { $0.active && $0.cause == .dropZone })
            XCTAssertEqual(tele.r0, DROP_RING0); XCTAssertEqual(tele.r1, DROP_RING); XCTAssertEqual(tele.life, tier.dropWarn, accuracy: 1e-6)
            // the marine walks off: the bug still lands where the ring was
            let t0 = g.simTime
            g.place(0, 9, 29)
            var landedAt: Float = -1
            for _ in 0..<120 {
                g.tick()
                g.drainEvents { if case .dropLanded(let p, let hit) = $0 { landedAt = g.simTime; XCTAssertEqual(p, Vec2(z.x, z.z)); XCTAssertFalse(hit) } }
                if landedAt >= 0 { break }
            }
            XCTAssertGreaterThan(landedAt, 0, "\(tier.id): it landed")
            XCTAssertEqual(landedAt - t0, tier.dropWarn, accuracy: 2.5 * SIM_DT, "\(tier.id): the warning is the whole time to the landing")
            XCTAssertEqual(g.bugs.state(i), .move, "a deck bug now")
            XCTAssertFalse(g.bugs.isOverhead(i))
            XCTAssertEqual(g.bugs.x[i], z.x, accuracy: 1e-4); XCTAssertEqual(g.bugs.z[i], z.z, accuracy: 1e-4)
            XCTAssertEqual(g.player.hp, g.player.maxHp, "out of the ring: no bite")
            XCTAssertEqual(g.overheadStats.hits, 0)
            XCTAssertEqual(g.activeDropZones, 0)
        }
    }

    func testALandingInTheRingBitesAndADashSaves() {
        // stands still: bitten by the runner's bite × the tier's bite × dropK
        let g = sliceGame()
        g.playerAlone(12, 29.5)
        _ = g.debugSpawnRouteBug(entry: SL_RISER)
        var ev: [GameEvent] = []
        XCTAssertNotNil(untilZone(g, &ev))
        let hp0 = g.player.hp
        // (until the landing only: the runner fights on afterwards and its next bite would count)
        for _ in 0..<90 where g.overheadStats.landed == 0 { g.tick() }
        let D = Difficulty.veteran
        XCTAssertEqual(hp0 - g.player.hp, BUG_SPECS[0].dmg * D.dmg * D.bite * D.dropK, accuracy: 0.01)
        XCTAssertEqual(g.overheadStats.hits, 1)
        XCTAssertEqual(g.lastHit, .runner, "a drop is a runner's hit (the damage sources keep their six slots)")
        // dashes out of the ring: no bite
        let h = sliceGame()
        h.playerAlone(12, 29.5)
        _ = h.debugSpawnRouteBug(entry: SL_RISER)
        ev = []
        XCTAssertNotNil(untilZone(h, &ev))
        for _ in 0..<20 { h.tick() }
        h.setPlayerInput(move: Vec2(-1, 0), aim: nil, fire: false, ability: false, dash: true)
        for _ in 0..<90 where h.overheadStats.landed == 0 { h.tick() }
        XCTAssertEqual(h.player.hp, h.player.maxHp)
        XCTAssertEqual(h.overheadStats.hits, 0)
        XCTAssertEqual(h.overheadStats.landed, 1)
    }

    func testFairnessCapsAndGrace() {
        let g = sliceGame(.veteran, seed: 11, god: true)
        g.debugTeleport(14, 29.5)
        XCTAssertEqual(g.debugRoutePack(40, entry: SL_RISER, rate: 6), Difficulty.veteran.routeCap, "the route cap holds at the queue")
        XCTAssertEqual(g.debugRoutePack(5, entry: SL_DUCT), 0)
        var starts: [(t: Float, m: Int)] = []
        var maxZones = 0, maxUp = 0
        for t in 0..<(60 * 40) {
            g.tick()
            g.drainEvents { _ in }
            maxZones = max(maxZones, g.activeDropZones)
            maxUp = max(maxUp, g.routeAlive)
            for z in g.dropZones where z.active && abs(z.t - (z.warn - SIM_DT)) < SIM_DT * 0.5 { starts.append((g.simTime, z.marine)) }
            // keep the pack up: top the route up every few seconds
            if t % 300 == 0 { g.debugRoutePack(15, entry: SL_RISER, rate: 6) }
        }
        XCTAssertGreaterThan(starts.count, 8, "drops happened")
        XCTAssertLessThanOrEqual(maxZones, Difficulty.veteran.dropCap, "≤ 3 drop warnings at once")
        XCTAssertLessThanOrEqual(maxUp, Difficulty.veteran.routeCap, "≤ the route cap up at once")
        XCTAssertLessThanOrEqual(g.overheadStats.maxUp, Difficulty.veteran.routeCap)
        for (a, b) in zip(starts, starts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.t - a.t, Difficulty.veteran.dropGap - 1e-4, "drop starts are dropGap apart")
        }
        for (k, s) in starts.enumerated() {
            let same = starts[k...].filter { $0.m == s.m && $0.t - s.t < DROP_WINDOW - 1e-4 }
            XCTAssertLessThanOrEqual(same.count, DROP_PER_MARINE, "≤ 2 drops on one marine in 3 s")
        }
        // grace: no drop is aimed at a marine for 2 s after its dash
        let h = sliceGame(.veteran, seed: 3, god: true)
        h.playerAlone(14, 29.5)
        h.debugRoutePack(6, entry: SL_RISER, rate: 6)
        var firstDash: Float = -1
        for _ in 0..<(60 * 30) {
            h.tick()
            if firstDash < 0 && h.routeAlive > 0 && h.bugs.count > 0 && (0..<h.bugs.count).contains(where: { h.bugs.state($0) == .high }) {
                h.setPlayerInput(move: Vec2(0, 0), aim: nil, fire: false, ability: false, dash: true)
                firstDash = h.simTime
            }
            if firstDash > 0 && h.simTime - firstDash < DROP_GRACE - 0.05 {
                XCTAssertFalse(h.dropZones.contains { $0.active && abs($0.t - ($0.warn - SIM_DT)) < SIM_DT * 0.5 }, "no drop starts in the grace")
            }
        }
        XCTAssertGreaterThan(firstDash, 0)
    }

    func testTheLullStaysALull() {
        // the wave director in its travel lull (beat 0 for the first 10 s): bugs up there creep and wait, nobody drops
        let g = sliceGame(.veteran, seed: 5, god: true, director: true)
        g.debugTeleport(14, 29.5)
        g.debugRoutePack(6, entry: SL_RISER, rate: 6)
        var zones = 0
        while g.beat == 0 && g.time < 30 {
            g.tick(); g.drainEvents { _ in }
            zones = max(zones, g.activeDropZones)
        }
        XCTAssertGreaterThan(g.routeAlive, 0)
        XCTAssertEqual(zones, 0, "no drop in the lull")
        XCTAssertEqual(g.beat, 1)
        var later = 0
        for _ in 0..<(60 * 8) { g.tick(); g.drainEvents { _ in }; later = max(later, g.activeDropZones) }
        XCTAssertGreaterThan(later, 0, "the build-up brings the drops")
    }

    func testNoDropOntoANoDropCircle() {
        let g = sliceGame()
        g.playerAlone(14, 29.5)
        g.debugSetNoDropZones([SIMD3<Float>(14, 29.5, 4)])
        g.debugRoutePack(4, entry: SL_RISER)
        for _ in 0..<(60 * 12) { g.tick() }
        XCTAssertEqual(g.overheadStats.drops, 0, "the lit deck of package R6 will set these circles")
        XCTAssertGreaterThan(g.routeAlive, 0)
    }

    func testBotsStepOutOfTheRing() {
        // bots in formation round the idle player; the drops aimed at them land on empty deck (they dodge like acid)
        var onBots = 0, hitBots = 0, onPlayer = 0, hitPlayer = 0
        for seed in UInt32(1)...6 {
            let g = sliceGame(.veteran, seed: seed, god: true)
            g.debugTeleport(14, 30)
            g.debugRoutePack(8, entry: SL_RISER, rate: 4)
            var aimed: [Int32: (marine: Int, x: Float, z: Float)] = [:]
            for _ in 0..<(60 * 25) {
                g.tick()
                for z in g.dropZones where z.active { aimed[z.uid] = (z.marine, z.x, z.z) }
                g.drainEvents { e in
                    guard case .dropLanded(let p, let hit) = e, let a = aimed.values.first(where: { $0.x == p.x && $0.z == p.y }) else { return }
                    if a.marine > 0 { onBots += 1; if hit { hitBots += 1 } } else { onPlayer += 1; if hit { hitPlayer += 1 } }
                }
            }
        }
        XCTAssertGreaterThan(onBots, 5, "drops were aimed at the bots")
        XCTAssertLessThanOrEqual(hitBots * 3, onBots, "the bots stepped out of most rings")
        if onPlayer > 0 { XCTAssertGreaterThan(hitPlayer, 0, "an idle player does not dodge") }
    }
}

final class OverheadHitTests: XCTestCase {
    /// A route bug waiting at the hub end of the rack (4, 26.4), its HP raised so it survives what the test throws at it;
    /// no drop anywhere near (a no-drop circle), so the marines the test places stay safe.
    func waitingBug(_ g: Game, hp: Float = 1000) -> Int {
        g.debugTeleport(0, 36)
        g.debugSetNoDropZones([SIMD3<Float>(4, 30, 12)])
        let i = g.debugSpawnRouteBug(entry: SL_RISER)
        for _ in 0..<(60 * 8) { g.tick() }
        XCTAssertEqual(g.bugs.state(i), .high)
        XCTAssertEqual(g.bugs.x[i], 4, accuracy: 0.05, "waiting at the hub end")
        XCTAssertEqual(g.bugs.velocityX[i], 0, accuracy: 1e-4)
        g.bugs.hp[i] = hp; g.bugs.hpMax[i] = hp
        return i
    }

    func testBulletsStrikeTheFootprint() {
        let g = sliceGame()
        let i = waitingBug(g, hp: 20)
        let S = g.bugs
        let bx = S.x[i], bz = S.z[i], r = S.r[i]
        // a round aimed at the deck flies under the route, even straight through the footprint
        g.fireBolt(bx, bz + 4, Float.pi, 74, 17, 0, 0, 0, true)
        for _ in 0..<12 { g.tick() }
        XCTAssertEqual(S.hp[i], 20, "aimed at the deck: it passes under")
        // aimed up, passing r × 1.15 from its plan position: inside the footprint (r × 1.3), outside the body
        g.fireBolt(bx + r * 1.15, bz + 4, Float.pi, 74, 17, 0, 0, 0, true, up: true)
        for _ in 0..<12 { g.tick() }
        XCTAssertLessThan(S.hp[i], 20, "hit up there")
        // one passing wide: no hit
        let hp1 = S.hp[i]
        g.fireBolt(bx + r * 1.3 + 0.3, bz + 4, Float.pi, 74, 17, 0, 0, 0, true, up: true)
        for _ in 0..<12 { g.tick() }
        XCTAssertEqual(S.hp[i], hp1)
        // an aimed-up round flies over the deck's bugs
        let deck = g.spawnBug(T_RUN, bx, bz + 2)
        g.bugs.hp[deck] = 1000
        g.fireBolt(bx + 2, bz + 2, -Float.pi / 2, 74, 17, 0, 0, 0, true, up: true)
        for _ in 0..<12 { g.tick() }
        XCTAssertEqual(g.bugs.hp[deck], 1000, "an aimed-up round never strikes the deck")
        XCTAssertEqual(S.hp[i], hp1)
        // a killing shot: it dies up there (an overhead kill, its corpse event at its height above the deck)
        var height: Float = -9
        let uid = S.uid[i]
        g.drainEvents { _ in }
        g.fireBolt(bx, bz + 4, Float.pi, 74, 30, 0, 0, 0, true, up: true)
        for _ in 0..<12 { g.tick(); g.drainEvents { if case .bugKilled(_, _, _, _, _, _, let h) = $0 { height = h } } }
        XCTAssertFalse((0..<S.count).contains { S.uid[$0] == uid && S.dead[$0] == 0 }, "dead (slots are compacted: by uid)")
        XCTAssertEqual(g.overheadStats.kills, 1)
        XCTAssertEqual(height, 4.5, accuracy: 0.01, "relative to the deck, as the renderer expects")
    }

    func testTheTorchBringsThemDownBurning() {
        let g = sliceGame(cls: .pyro)
        let i = waitingBug(g)
        let S = g.bugs, P = g.player
        g.place(0, S.x[i], 30)
        P.aim = Float.pi; P.ax = 0; P.az = -1
        g.flameTick(P, SIM_DT)
        XCTAssertGreaterThan(S.burn[i], 0, "the torch reaches 4.5 m up")
        var t = 0
        while S.state(i) != .fall && t < 120 { g.tick(); t += 1 }
        XCTAssertEqual(S.state(i), .fall)
        XCTAssertEqual(Float(t) * SIM_DT, GRIP_T, accuracy: 3 * SIM_DT, "it lets go after 0.8 s")
        for _ in 0..<60 { g.tick() }
        XCTAssertEqual(S.state(i), .move, "on the deck, still burning")
        XCTAssertGreaterThan(S.burn[i], 0)
        XCTAssertEqual(S.moods[i], BugMood.panic.rawValue)
        XCTAssertTrue(g.level.walkable(S.x[i], S.z[i]))
        XCTAssertEqual(g.overheadStats.knockdowns, 1)
    }

    func testFrostFreezesThemAndTheyShatter() {
        let g = sliceGame(cls: .cryo)
        let i = waitingBug(g)
        let S = g.bugs, P = g.player
        g.place(0, S.x[i], 30)
        let kills0 = g.kills
        XCTAssertTrue(g.useAbility(P, 0, 0), "the Ice Wave")
        XCTAssertEqual(S.state(i), .fall, "frozen, it falls at once")
        XCTAssertGreaterThan(S.frz[i], 0)
        for _ in 0..<60 { g.tick() }
        XCTAssertNotEqual(S.dead[i], 0, "it shattered on the deck")
        XCTAssertEqual(g.overheadStats.shattered, 1)
        XCTAssertEqual(g.kills, kills0 + 1, "a kill for the Cryo")
    }

    func testBlastsReachUpAtSixtyPercent() {
        let g = sliceGame()
        let i = waitingBug(g)
        let S = g.bugs
        let x = S.x[i]
        // a frag 4.6 m from its plan position (radius 5: reach 3 m): nothing up there
        g.queueBoom(x, 31, 5, 150, 0, .frag)
        g.tick()
        XCTAssertEqual(S.state(i), .high)
        XCTAssertEqual(S.hp[i], 1000)
        // 1.6 m away: hit and knocked down
        g.queueBoom(x, 28, 5, 150, 0, .frag)
        g.tick()
        XCTAssertLessThan(S.hp[i], 1000)
        XCTAssertEqual(S.state(i), .fall)
        for _ in 0..<60 { g.tick() }
        XCTAssertEqual(S.state(i), .move)
    }

    func testKnockedIntoTheVoidItDies() {
        let g = sliceGame()
        g.debugTeleport(30, 30)
        let i = g.debugSpawnRouteBug(entry: SL_DUCT)   // the duct mouth hangs 3.5 m out over the void
        g.tick()
        let kills0 = g.kills
        g.knockDown(i, src: 0)
        XCTAssertEqual(g.bugs.state(i), .fall)
        XCTAssertLessThan(g.bugs.routeParams[i], 0, "no deck within 2.5 m: the void")
        for _ in 0..<90 { g.tick() }
        XCTAssertNotEqual(g.bugs.dead[i], 0)
        XCTAssertEqual(g.kills, kills0 + 1)
    }

    func testWhoAimsUp() {
        let g = sliceGame()
        let i = waitingBug(g)
        let S = g.bugs
        let bot = g.marines[1]
        g.place(1, S.x[i] + 1, 30)
        // a bug only waiting up there is not a bot's target (the bots would strip every rack before a drop)
        XCTAssertEqual(g.aiPickTarget(bot, 17), -1)
        // coiling: the bots answer after a human reaction time, then before anything on the deck
        S.st[i] = S_COIL; S.t[i] = Difficulty.veteran.dropWarn - DROP_T
        XCTAssertEqual(g.aiPickTarget(bot, 17), -1, "not at once")
        S.t[i] -= BOT_REACT
        let deck = g.spawnBug(T_RUN, S.x[i] + 1, 31.5)
        g.hash.rebuild(S)
        XCTAssertEqual(g.aiPickTarget(bot, 17), i, "a coiling bug first (\(deck) is on the deck)")
        // the player's assist finds it where it is DRAWN (≈ 0.75 h up-screen of its footprint) and the rounds go up
        S.st[i] = S_HIGH
        S.dead[deck] = 1; S.deadPending += 1
        let P = g.player
        g.place(0, S.x[i] + 1.5, 32)
        let seen = Vec2(S.x[i] + FWD_X * 0.75 * 4.5 - P.x, S.z[i] + FWD_Z * 0.75 * 4.5 - P.z)
        let foot = Vec2(S.x[i] - P.x, S.z[i] - P.z)
        XCTAssertEqual(g.aimAssistTarget(from: P, dir: seen / (seen * seen).sum().squareRoot()), i, "pointing at the sprite")
        g.setPlayerInput(move: Vec2(0, 0), aim: Game.angle(of: seen), fire: true, ability: false, dash: false, assist: 1)
        g.tick()
        XCTAssertTrue(P.aimUp)
        XCTAssertEqual(P.aim, Game.angle(of: foot), accuracy: 0.05, "turned to the footprint")
    }

    func testTheSquadShootsCoilingBugsOffTheRack() {
        var kills = 0, drops = 0
        for seed in UInt32(1)...3 {
            let g = sliceGame(.veteran, seed: seed, god: true, holdFire: false)
            g.debugTeleport(12, 30)
            g.debugRoutePack(8, entry: SL_RISER, rate: 4)
            for _ in 0..<(60 * 15) { g.tick(); g.drainEvents { _ in } }
            kills += g.overheadStats.kills; drops += g.overheadStats.drops
        }
        XCTAssertGreaterThan(drops, 3)
        XCTAssertGreaterThan(kills, 0, "the squad shot (froze, burnt) bugs off the rack")
    }

    func testTheExtractionClearsTheOverhead() {
        let g = holdGame(.veteran, seed: 9) { $0.levelSource = KelvinStation(overhead: .kelvinSlice) }
        g.directorEnabled = false
        for k in 0..<4 { _ = g.debugSpawnRouteBug(entry: k % 2 == 0 ? SL_RISER : SL_DUCT) }
        for _ in 0..<30 { g.tick() }
        XCTAssertEqual(g.routeAlive, 4)
        g.directorEnabled = true
        g.debugSkip()   // the Queen, then the lift leaves
        while g.stage != .extract && g.time < 30 { g.tick() }
        XCTAssertEqual(g.stage, .extract)
        let kills0 = g.kills
        for _ in 0..<(60 * 2) { g.tick() }
        XCTAssertEqual(g.overheadStateCounts.reduce(0, +), 0, "they leapt into the void")
        XCTAssertEqual(g.kills, kills0, "and nobody gets the kills")
    }
}

final class OverheadMissionTests: XCTestCase {
    func fingerprint(_ g: Game) -> [Float] {
        var f: [Float] = [g.time, Float(g.kills), Float(g.bugs.count), Float(g.routeAlive), Float(g.overheadStats.drops)]
        for m in g.marines { f += [m.x, m.z, m.hp] }
        for i in 0..<g.bugs.count { f += [g.bugs.x[i], g.bugs.y[i], g.bugs.z[i], Float(g.bugs.st[i]), Float(g.bugs.re[i])] }
        return f
    }

    func testSameSeedSameOverhead() {
        func run() -> Game {
            let g = sliceGame(.veteran, seed: 21, holdFire: false)
            g.debugTeleport(14, 30)
            for t in 0..<(60 * 30) {
                if t % 240 == 0 { g.debugRoutePack(6) }
                g.tick(); g.clearEvents()
            }
            return g
        }
        let a = run(), b = run()
        XCTAssertGreaterThan(a.overheadStats.spawns, 10)
        XCTAssertGreaterThan(a.overheadStats.drops + a.overheadStats.kills, 0)
        XCTAssertEqual(fingerprint(a), fingerprint(b))
        XCTAssertEqual(a.overheadStats, b.overheadStats)
        XCTAssertFalse(a.hasNonFinite())
    }

    /// The overhead off (`routes` = 0) changes nothing: the same calibration row on the bare station and with routes laid.
    /// (Stage 1 R5: the tiers carry it on since — the runs turn it off by override.)
    func testRoutesOffReplaysByteForByte() {
        for (k, cls) in [MarineClass.assault, .cryo].enumerated() {
            let c = CalibRun(tag: "vet", cls: cls, tier: 1, mode: .auto, maxs: 150, seed: 1100 + UInt32(k), th: ["routes": 0])
            let bare = Calibration.run(c)
            let slice = Calibration.run(c, level: Level(source: KelvinStation(overhead: .kelvinSlice), seed: c.seed))
            XCTAssertEqual(bare.json, slice.json, "\(cls): Kelvin-9 with the slice laid, routes 0")
            XCTAssertNil(slice.oh)
        }
        // a generated station with its planned routes vs the same station stripped of them
        let st = CalibRun(tag: "st", cls: .gunner, tier: 1, mode: .auto, maxs: 150, seed: 1234, station: 3, th: ["routes": 0])
        var bare = StationGenerator().makeLayout(seed: 3)
        XCTAssertFalse(bare.overhead.isEmpty)
        bare.overhead = OverheadLayout()
        XCTAssertEqual(Calibration.run(st).json, Calibration.run(st, level: Level(layout: bare)).json)
    }

    func testTheDirectorsChannelInAFullMission() {
        // a generated station with its routes, the overhead on (routes 0.2): packs go up, drops come down, the caps hold
        var totals = OverheadStats()
        for (k, cls) in [MarineClass.assault, .pyro].enumerated() {
            let c = CalibRun(tag: "oh", cls: cls, tier: 1, mode: .auto, maxs: 400, seed: 1500 + UInt32(k), station: 2, th: ["routes": 0.2])
            let row = Calibration.run(c)
            let oh = try! XCTUnwrap(row.oh, "the row carries the overhead's numbers")
            XCTAssertGreaterThan(oh.spawns, 0)
            XCTAssertLessThanOrEqual(oh.maxUp, Difficulty.veteran.routeCap)
            XCTAssertLessThanOrEqual(oh.maxZones, Difficulty.veteran.dropCap)
            XCTAssertTrue(row.json.contains("\"oh\":{"))
            totals.spawns += oh.spawns; totals.drops += oh.drops
        }
        XCTAssertGreaterThan(totals.drops, 0, "drops in a real mission")
    }
}

/// Golden values of the route data (quantised to 1/64 m, so every platform gets the same).
enum OverheadGoldens {
    static let slice: UInt32 = 1520102459
    /// Generated stations 1–3 (14 nodes / 10 edges / 62 m, 10 / 7 / 44 m, 21 / 15 / 96 m).
    static let stations: [(UInt32, UInt32)] = [(1, 3725030225), (2, 3863092078), (3, 4248470906)]
}
