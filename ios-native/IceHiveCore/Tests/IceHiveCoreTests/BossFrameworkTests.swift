import XCTest
@testable import IceHiveCore

/// Stage 2 B1, the boss framework (Boss.swift, GameBoss.swift, GameBossBody.swift): the Queen's rows on it, and a toy
/// multi-part boss — a chain of a head, six segments and two nodes — for the parts: the path follow by arc length, the
/// routed hits, the pools, the weak-point windows, the phases, the moves, the death, the arrivals and determinism. (The
/// Queen's own behaviour on the framework: QueenTests, MissionPlanTests; the classic mission replays bit for bit:
/// `testClassicPlanReplaysTheStageMachineBitForBit` and the calibration md5s.)
final class BossFrameworkTests: XCTestCase {

    /// The toy chain: head ×1 (×2 while down, ×1.5 from behind), segments ×0.25, two nodes ×1.5 with 10 % pools (popped
    /// ×0.25, a 1.5 s stagger); a slam (ring, 1 s wind-up, opens a 2 s window on the head) from the start, a beam lane only
    /// in phase 1 (below half health: enraged, ×1.3 speed, a 0.5 s stagger). Not freeze-immune: a frozen part locks the body
    /// 2 s, an Ice Wave on an open window makes it brittle.
    static func toySpec(hp: Float = 4000) -> BossSpec {
        let head = BossPartSpec(.head, type: .brute, radius: 0.9, scale: 1.6, damageK: 1, downK: 2, rearK: 1.5)
        let seg = BossPartSpec(.segment, type: .runner, radius: 0.5, scale: 1.2, damageK: 0.25)
        let n1 = BossPartSpec(.node, type: .spitter, radius: 0.35, lift: -0.2, segment: 2, damageK: 1.5, pool: 0.1, poppedK: 0.25, popStagger: 1.5)
        let n2 = BossPartSpec(.node, type: .spitter, radius: 0.35, lift: -0.2, segment: 5, damageK: 1.5, pool: 0.1, poppedK: 0.25, popStagger: 1.5)
        let chain = BossChainSpec(head: head, segment: seg, segments: 6, spacing: 1.2, lead: 1.4, nodes: [n1, n2], sampleStep: 0.2)
        var slam = BossMove("slam", .slam, first: 1, cooldown: 4)
        slam.shape = .ring; slam.windUp = 1; slam.damage = 20; slam.knockback = 9; slam.radius = 2.5; slam.opensDown = 2
        var rime = BossMove("rime", .lane, first: 2, cooldown: 5)
        rime.shape = .beam; rime.windUp = 0.8; rime.active = 0.4; rime.damage = 12; rime.radius = 1.2; rime.length = 10; rime.phases = 0b10
        var p2 = BossPhase(below: 0.5)
        p2.enraged = true; p2.speedK = 1.3; p2.stagger = 0.5
        var s = BossSpec(at: .infinity, hp: hp, speed: 4, body: .chain(chain), spawn: .arena(lift: 0, heading: 0),
                         phases: [BossPhase(below: 1), p2], moves: [slam, rime], source: .queen)
        s.immune.freeze = false; s.immune.chillCap = 0.6; s.immune.freezeLock = 2; s.immune.brittle = 1.5
        s.reward = BossReward(xp: 30)
        return s
    }

    func planGame(_ plan: MissionPlan, tier: Difficulty = .veteran, seed: UInt32 = 5, god: Bool = true, autopilot: Bool = false,
                  configure: ((inout GameConfig) -> Void)? = nil) -> Game {
        tierGame(tier, seed: seed, autopilot: autopilot, god: god) { c in c.mission = .custom(plan); configure?(&c) }
    }

    @discardableResult
    func run(_ g: Game, seconds: Float, until cond: (() -> Bool)? = nil, _ onEvent: ((GameEvent) -> Void)? = nil) -> Bool {
        for _ in 0..<Int(seconds * 60) {
            g.tick()
            g.drainEvents { onEvent?($0) }
            if let c = cond, c() { return true }
        }
        return false
    }

    /// The toy without its moves (the damage and walking checks: no slam reopening the head's window).
    static func stillToy(hp: Float = 4000) -> BossSpec {
        var s = toySpec(hp: hp)
        s.moves = []
        return s
    }

    /// A game in the toy's BOSS step on the lift, the squad in the arena, the toy there (no warning left); the bots hold
    /// their fire unless `fight` (the squad's Cryo would lock the toy's body with its beam).
    func toyGame(seed: UInt32 = 5, god: Bool = true, spec: BossSpec = BossFrameworkTests.toySpec(), fight: Bool = false,
                 configure: ((inout GameConfig) -> Void)? = nil) -> Game {
        let g = planGame(MissionPlan(id: "t-toy", steps: [.boss(BossStep(.queen, zone: .lift, delay: 0.5, spec: spec))]), seed: seed, god: god,
                         configure: configure)
        g.debugHoldFire = !fight
        // (quiet: no abilities either — the bots count the parts as a crowd, the Cryo's Ice Wave would lock the body)
        if !fight { for m in g.marines { m.abCd = 1e9 } }
        g.debugSkip()
        XCTAssertEqual(g.stepPhase, .active)
        run(g, seconds: 4, until: { g.boss.spawned })
        XCTAssertTrue(g.boss.alive, "the toy came")
        g.clearEvents()
        return g
    }

    /// The deck's height at the arena's centre.
    func deckY(_ g: Game) -> Float { g.level.groundY(g.level.lift.x, g.level.lift.z) }

    // ---------------------------------------------------------------- the Queen's rows

    func testQueenRowsAreTheV11Numbers() {
        for (d, at, hp, spd, ram, vol, brood, n, horde, trickle) in [
            (Difficulty.recruit, Float(35), Float(2500), Float(1.5), Float(9), Float(6), Float(8), 6, Float(80), Float(0.4)),
            (Difficulty.veteran, 35, 3500, 1.5, 9, 6, 8, 6, 80, 0.4),
            (Difficulty.nightmare, 30, 6000, 1.6, 8, 5, 7, 8, 150, 0.6)] {
            let q = d.boss(.queen)
            XCTAssertEqual(q, d.queen)
            XCTAssertEqual([q.at, q.hp, q.speed, q.ramT, q.volleyT, q.broodT, Float(q.broodN), q.horde, q.trickle],
                           [at, hp, spd, ram, vol, brood, Float(n), horde, trickle], d.id)
            // her structure: a brute body 1.5 / 4.2 over the far rim (3 m below, margin 1.5, z < −4), 2 s of ring 3 m wide
            XCTAssertEqual(q.body, .bug(type: .brute, radius: 1.5, scale: 4.2))
            XCTAssertEqual(q.spawn, .rim(depth: 3, margin: 1.5, backZ: -4))
            XCTAssertEqual([q.warn, q.warnRing], [2, 3])
            XCTAssertEqual(q.moves.map { $0.id }, ["brood", "volley", "ram"])
            XCTAssertEqual(q.moves.map { $0.kind }, [.brood, .volley, .bodyCharge])
            XCTAssertEqual(q.moves.map { $0.first }, [4, 3, 6])
            XCTAssertEqual(q.move("volley").map { [$0.range, $0.lead, $0.spread] }, [18, 0.8, 1.2])
            XCTAssertEqual(q.phases.count, 2)
            XCTAssertEqual(q.phases[1].below, 0.5); XCTAssertTrue(q.phases[1].enraged); XCTAssertEqual(q.phases[1].speedK, 1.35)
            XCTAssertEqual(q.phases[1].cooldownK, [0.7, 0.75, 0.75])
            XCTAssertEqual(q.phases[1].hordeWavesK, 0.5); XCTAssertEqual(q.phases[1].hordeTitle, .bannerQueenRage)
            XCTAssertTrue(q.immune.freeze && q.immune.pulse); XCTAssertEqual(q.immune.chillCap, 0.5)
            XCTAssertEqual(q.bite, 1.6); XCTAssertEqual(q.source, .queen); XCTAssertTrue(q.pausesHordes)
            XCTAssertEqual(q.deathBlast, BossBlast(r: 8, dmg: 300, src: 0, kind: .frag))
            XCTAssertEqual(q.reward, BossReward(xp: 60, medkits: [Vec2(1, 0), Vec2(-1, 0)]))
            XCTAssertEqual(q.banner, BannerText(title: .bannerQueen, sub: .bannerQueenSub))
            XCTAssertEqual(q.deathBanner, BannerText(title: .bannerQueenDead, sub: .bannerQueenDeadSub))
        }
        // the legacy row: her structure, every number 0, she never comes
        let l = Difficulty.legacyV10.queen
        XCTAssertFalse(l.comes); XCTAssertEqual(l.hp, 0); XCTAssertEqual(l.trickle, 1)
        XCTAssertFalse(Difficulty.legacyV10.hasQueen)
        // the --th keys reach her moves and phases
        var d = Difficulty.veteran
        XCTAssertEqual(d.override(["qRamT": 4, "qVolleyT": 3, "qBroodT": 2, "qHorde": 99, "qSpd": 2]), [])
        XCTAssertEqual([d.queen.ramT, d.queen.volleyT, d.queen.broodT, d.queen.horde, d.queen.speed], [4, 3, 2, 99, 2])
    }

    func testTheQueenIsABugBody() {
        let g = holdGame()
        g.debugBoss(hp: 5000)
        let i = g.bossSlotNow()
        XCTAssertGreaterThanOrEqual(i, 0)
        XCTAssertTrue(g.bugs.isBoss(i)); XCTAssertEqual(g.bugs.bossPart(i), -1)
        XCTAssertEqual(g.bossPartCount, 0)
        XCTAssertEqual(g.boss.kind, .queen); XCTAssertEqual(g.boss.arrivals, 1)
        // no other slot is the boss's
        var others = 0
        for k in 0..<g.bugs.count where k != i && g.bugs.isBoss(k) { others += 1 }
        XCTAssertEqual(others, 0)
        // a hit on her is a plain hit (her own health is the bar)
        let hp0 = g.bugs.hp[i]
        g.hitBug(i, 100, 0)
        XCTAssertEqual(g.bugs.hp[i], hp0 - 100)
    }

    // ---------------------------------------------------------------- the chain body

    func testChainSpawnsAtTheArenaWithItsBodyBehind() {
        let g = toyGame()
        let s = BossFrameworkTests.toySpec()
        XCTAssertEqual(g.bossPartCount, 9)
        let L = g.level.lift, y0 = deckY(g)
        let h = g.bossPart(0)
        XCTAssertEqual(h.role, .head)
        XCTAssertEqual(h.position.x, L.x, accuracy: 0.01); XCTAssertEqual(h.position.z, L.z, accuracy: 0.01)
        XCTAssertEqual(h.position.y, y0, accuracy: 0.01)
        // heading 0 (+z): segment j stands lead + (j − 1) × spacing behind, along −z
        for j in 1...6 {
            let p = g.bossPart(j)
            XCTAssertEqual(p.role, .segment); XCTAssertEqual(p.segment, j)
            XCTAssertEqual(p.position.x, L.x, accuracy: 0.01)
            XCTAssertEqual(p.position.z, L.z - (1.4 + Float(j - 1) * 1.2), accuracy: 0.01, "segment \(j)")
        }
        // the nodes ride segments 2 and 5, 0.2 m under them
        XCTAssertEqual(g.bossPart(7).role, .node); XCTAssertEqual(g.bossPart(7).segment, 2)
        XCTAssertEqual(g.bossPart(7).position.z, g.bossPart(2).position.z, accuracy: 1e-4)
        XCTAssertEqual(g.bossPart(7).position.y, g.bossPart(2).position.y - 0.2, accuracy: 1e-4)
        XCTAssertEqual(g.bossPart(8).segment, 5)
        // every part is a swarm slot of its type, marked, state .boss, its radius; only the head holds the bar
        for k in 0..<9 {
            let v = g.bossPart(k)
            XCTAssertGreaterThanOrEqual(v.slot, 0)
            XCTAssertEqual(g.bugs.bossPart(v.slot), k)
            XCTAssertEqual(g.bugs.state(v.slot), .boss)
            XCTAssertEqual(g.bugs.r[v.slot], k == 0 ? 0.9 : (k <= 6 ? 0.5 : 0.35))
            XCTAssertEqual(v.pool, 1)
        }
        XCTAssertEqual(g.bugs.hpMax[g.bossPart(0).slot], s.hp * g.hpMul, accuracy: 1)
        XCTAssertEqual(g.bugs.uid[g.bossPart(0).slot], g.boss.uid)
        XCTAssertEqual(g.boss.hpFraction, 1)
        // not the swarm's: the type counts and the overhead's caps leave the parts out
        XCTAssertEqual(g.bossPartsUp, 0)
    }

    func testSegmentsFollowTheHeadsPathByArcLength() {
        let g = toyGame()
        let L = g.level.lift, y = deckY(g)
        // a square with a climb on one side: the head walks it at 4 m/s; its true path is recorded every tick
        let pts: [SIMD3<Float>] = [SIMD3(L.x + 4, y, L.z + 2), SIMD3(L.x + 4, y + 3, L.z - 4), SIMD3(L.x - 3, y + 3, L.z - 4),
                                   SIMD3(L.x - 3, y, L.z + 3), SIMD3(L.x + 4, y, L.z + 3)]
        g.bossSetTrack(pts, loop: true)
        var path: [SIMD3<Float>] = [g.bossPart(0).position]
        for _ in 0..<(9 * 60) {
            g.tick(); g.clearEvents()
            if !g.boss.alive { break }
            path.append(g.bossPart(0).position)
        }
        XCTAssertTrue(g.boss.alive)
        // arc length of the true path back from the head
        var arc: [Float] = [0]
        var k = path.count - 1
        while k > 0 { arc.append(arc.last! + simd_len(path[k] - path[k - 1])); k -= 1 }
        func truePoint(_ d: Float) -> SIMD3<Float> {
            var j = 0
            while j + 1 < arc.count && arc[j + 1] < d { j += 1 }
            let i1 = path.count - 1 - j, i0 = max(0, i1 - 1)
            let span = arc[min(j + 1, arc.count - 1)] - arc[j]
            let t = span > 1e-6 ? (d - arc[j]) / span : 0
            return path[i1] + (path[i0] - path[i1]) * t
        }
        XCTAssertGreaterThan(arc.last!, 20, "the head walked")
        for j in 1...6 {
            let want = truePoint(1.4 + Float(j - 1) * 1.2)
            let got = g.bossPart(j).position
            XCTAssertLessThan(simd_len(got - want), 0.12, "segment \(j) is on the head's path, lead + (j − 1) × spacing behind")
        }
        // consecutive segments: a chord never longer than their path spacing
        for j in 2...6 {
            let d = simd_len(g.bossPart(j).position - g.bossPart(j - 1).position)
            XCTAssertLessThanOrEqual(d, 1.2 + 0.05); XCTAssertGreaterThan(d, 0.6)
        }
        // the renderer's sampler agrees with the parts
        let b = g.bossBodyPoint(behind: 1.4 + 2 * 1.2)!
        XCTAssertLessThan(simd_len(b.position - g.bossPart(3).position), 1e-3)
        XCTAssertEqual(b.heading, g.bossPart(3).heading, accuracy: 1e-3)
    }

    func testPartsAboveReachAreUpOnly() {
        let g = toyGame()
        let L = g.level.lift, y = deckY(g)
        // the head climbs to 5 m and walks on: the parts up there leave the deck's reach (the sentinel bucket)
        g.bossSetTrack([SIMD3(L.x, y + 5, L.z + 1), SIMD3(L.x, y + 5, L.z + 12)], loop: false)
        run(g, seconds: 4)
        let h = g.bossPart(0)
        XCTAssertTrue(h.up)
        XCTAssertEqual(g.bugs.overheadFlags[h.slot], 1)
        XCTAssertTrue(g.bugs.hasAbsoluteHeight(h.slot))
        XCTAssertEqual(g.bugs.heights[h.slot], y + 5, accuracy: 0.01)
        g.hash.rebuild(g.bugs)
        XCTAssertEqual(g.hash.cell[h.slot], SpatialHash.sentinel)
        XCTAssertEqual(g.bossPartsUp, (0..<9).filter { g.bossPart($0).up }.count)
        XCTAssertGreaterThan(g.bossPartsUp, 0)
        XCTAssertEqual(g.routeAlive, g.hash.overheadCount - g.bossPartsUp, "the overhead's cap leaves the boss out")
        // a deck query misses the head; a round aimed up at its footprint finds it
        let n = g.hash.queryCircle(g.bugs, h.position.x, h.position.z, 0.5)
        XCTAssertFalse((0..<n).contains { g.bugs.isBoss(g.hash.qb[$0]) }, "a deck query never sees a part up there")
        let (b, _) = g.overheadSegmentHit(h.position.x, h.position.z - 3, 0, 1, 6, 0)
        XCTAssertEqual(g.bugs.isBoss(b), true)
    }

    // ---------------------------------------------------------------- damage routing, pools, windows

    func testHitsRouteToOneBar() {
        let g = toyGame(spec: BossFrameworkTests.stillToy())
        let head = g.bossPart(0).slot, seg = g.bossPart(3).slot, node = g.bossPart(7).slot
        func bar() -> Float { g.bugs.hp[g.bossPart(0).slot] }
        let max0 = g.bugs.hpMax[head]
        // body ×0.25, the head ×1, a node ×1.5 (into its own pool too); the parts' own health never moves
        var hp = bar()
        g.hitBug(seg, 100, 0); XCTAssertEqual(bar(), hp - 25, accuracy: 1e-3); hp = bar()
        g.hitBug(head, 100, 0); XCTAssertEqual(bar(), hp - 100, accuracy: 1e-3); hp = bar()
        g.hitBug(node, 100, 0); XCTAssertEqual(bar(), hp - 150, accuracy: 1e-3); hp = bar()
        XCTAssertEqual(g.bossPart(7).pool, 1 - 150 / (0.1 * max0), accuracy: 1e-4)
        XCTAssertEqual(g.bugs.hp[seg], BOSS_PART_HP)
        XCTAssertGreaterThan(g.bugs.flashes[seg], 0, "the struck part flashes")
        // a window on the head: ×2 while it lasts
        g.bossOpenWindow(0, 2)
        XCTAssertEqual(g.bossPart(0).down, 2)
        g.hitBug(head, 100, 0); XCTAssertEqual(bar(), hp - 200, accuracy: 1e-3); hp = bar()
        g.hitBug(seg, 100, 0); XCTAssertEqual(bar(), hp - 25, accuracy: 1e-3, "only the part with the window"); hp = bar()
        run(g, seconds: 2.1)
        hp = bar()
        XCTAssertEqual(g.bossPart(0).down, 0)
        g.hitBug(head, 100, 0); XCTAssertEqual(bar(), hp - 100, accuracy: 1e-3); hp = bar()
        // brittle ×1.5, untouchable nothing, a bonus on a part, struck from behind (the head's rearK 1.5)
        g.bossBrittle(1)
        g.hitBug(head, 100, 0); XCTAssertEqual(bar(), hp - 150, accuracy: 1e-3); hp = bar()
        run(g, seconds: 1.1); hp = bar()
        g.bossUntouchable(1)
        g.hitBug(head, 100, 0); XCTAssertEqual(bar(), hp, "untouchable")
        run(g, seconds: 1.1); hp = bar()
        g.bossPartBonus(3, 1.25)
        g.hitBug(g.bossPart(3).slot, 100, 0); XCTAssertEqual(bar(), hp - 31.25, accuracy: 1e-3); hp = bar()
        let hd = g.bossPart(0).heading
        g.hitBug(g.bossPart(0).slot, 100, 0, dir: Vec2(sinf2(hd), cosf2(hd))); XCTAssertEqual(bar(), hp - 150, accuracy: 1e-3, "from behind"); hp = bar()
        g.hitBug(g.bossPart(0).slot, 100, 0, dir: Vec2(-sinf2(hd), -cosf2(hd))); XCTAssertEqual(bar(), hp - 100, accuracy: 1e-3, "head on"); hp = bar()
        // the boss bar follows
        run(g, seconds: 0.05)
        XCTAssertEqual(g.boss.hpFraction, bar() / max0, accuracy: 1e-5)
        XCTAssertEqual(g.objectiveProgress, 1 - g.boss.hpFraction, accuracy: 1e-5)
    }

    func testANodesPoolPopsIt() {
        let g = toyGame(spec: BossFrameworkTests.stillToy())
        let node = g.bossPart(8).slot
        let pool = 0.1 * g.bugs.hpMax[g.bossPart(0).slot]
        var popped: [Int] = []
        // 1.5 × damage until the pool is spent
        var hits = 0
        while !g.bossPart(8).popped && hits < 100 { g.hitBug(node, 50, 0); hits += 1 }
        g.drainEvents { if case .bossPartPopped(_, let p, _) = $0 { popped.append(p) } }
        XCTAssertEqual(popped, [8])
        XCTAssertEqual(hits, Int((pool / 75).rounded(.up)))
        XCTAssertEqual(g.bossPart(8).pool, 0)
        XCTAssertEqual(g.boss.stagger, 1.5, "it staggers")
        // popped: ×0.25 from now on; the other node still ×1.5
        let hp = g.bugs.hp[g.bossPart(0).slot]
        g.hitBug(node, 100, 0)
        XCTAssertEqual(g.bugs.hp[g.bossPart(0).slot], hp - 25, accuracy: 1e-3)
        XCTAssertFalse(g.bossPart(7).popped)
        // the stagger pauses the moves and the head
        let L = g.level.lift, y = deckY(g)
        g.bossSetTrack([SIMD3(L.x + 10, y, L.z)], loop: false)
        let p0 = g.bossPart(0).position
        run(g, seconds: 1)
        XCTAssertEqual(simd_len(g.bossPart(0).position - p0), 0, accuracy: 1e-4, "staggered: it stands")
        run(g, seconds: 1)
        XCTAssertGreaterThan(simd_len(g.bossPart(0).position - p0), 1, "then it moves on")
    }

    func testSlamTelegraphsLandsAndOpensTheWindow() {
        let g = toyGame(god: false)
        // the squad stands in the arena: the slam aims at the nearest standing marine, rings it for 1 s, lands
        var moveAt: Float = -1, windowAt: Float = -1, ring: Telegraph? = nil
        let t0 = g.time
        let hp0 = g.marines.map { $0.hp }
        run(g, seconds: 3, until: { windowAt >= 0 }) { e in
            switch e {
            case .bossMove(_, let m, _): if m == 0 && moveAt < 0 { moveAt = g.time; ring = g.telegraphs.first { $0.active && $0.cause == .bossMove } }
            case .bossWindow(_, let p, _, let t): if p == 0 { windowAt = g.time; XCTAssertEqual(t, 2) }
            default: break
            }
        }
        XCTAssertEqual(moveAt - t0, 1, accuracy: 0.05, "its first use")
        XCTAssertEqual(windowAt - moveAt, 1, accuracy: 0.05, "its wind-up")
        XCTAssertEqual(ring?.shape, .ring); XCTAssertEqual(ring?.r0, 2.5)
        XCTAssertGreaterThan(g.bossPart(0).down, 1.9)
        // someone in the ring took 20 × the damage multiplier
        let lost = zip(hp0, g.marines.map { $0.hp }).map { $0 - $1 }
        XCTAssertTrue(lost.contains { $0 >= 20 * g.dmgMul * 0.99 }, "\(lost)")
        XCTAssertEqual(g.hurtBy[DamageSource.queen.rawValue + 1] > 0, true, "its source")
    }

    func testPhasesOnThresholds() {
        let g = toyGame()
        let head = g.bossPart(0).slot
        let max0 = g.bugs.hpMax[head]
        var phases: [(Int, Bool)] = []
        var rimeMoves = 0
        // above half: phase 0, the rime (phase 1 only) never starts
        run(g, seconds: 4) { if case .bossMove(_, 1, _) = $0 { rimeMoves += 1 } }
        XCTAssertEqual(g.boss.phase, 0); XCTAssertFalse(g.boss.enraged); XCTAssertEqual(rimeMoves, 0)
        // under half: phase 1 once (enraged, its stagger), the rime comes in (struck on a segment, ×0.25: whatever window the
        // slam left on the head)
        g.hitBug(g.bossPart(3).slot, max0 * 0.55 / 0.25, 0)
        run(g, seconds: 0.05) { if case .bossPhase(_, let p, let e, _) = $0 { phases.append((p, e)) } }
        XCTAssertEqual(phases.count, 1); XCTAssertEqual(phases.first?.0, 1); XCTAssertEqual(phases.first?.1, true)
        XCTAssertEqual(g.boss.phase, 1); XCTAssertTrue(g.boss.enraged)
        XCTAssertGreaterThan(g.boss.stagger, 0.4)
        run(g, seconds: 8) { e in
            if case .bossMove(_, 1, _) = e { rimeMoves += 1 }
            if case .bossPhase = e { phases.append((9, false)) }
        }
        XCTAssertGreaterThan(rimeMoves, 0, "the phase's move")
        XCTAssertEqual(phases.count, 1, "a phase begins once")
        // its speed × 1.3: the head walks 4 × 1.3 m/s
        let L = g.level.lift, y = deckY(g)
        g.bossSetTrack([SIMD3(L.x + 30, y, L.z)], loop: false)
        run(g, seconds: 1.5)
        let a = g.bossPart(0).position
        run(g, seconds: 0.5)
        XCTAssertEqual(simd_len(g.bossPart(0).position - a), 4 * 1.3 * 0.5, accuracy: 0.1)
    }

    func testDeathTakesEveryPartAndEndsTheStep() {
        let g = toyGame()
        let slots = (0..<9).map { g.bossPart($0).slot }
        let uids = slots.map { g.bugs.uid[$0] }
        let xp0 = g.xp, lvl0 = g.xpLevel
        var killed = 0
        g.hitBug(slots[4], 1e7, 0)
        g.drainEvents { if case .bossKilled = $0 { killed += 1 } }
        XCTAssertEqual(killed, 1)
        XCTAssertFalse(g.boss.alive); XCTAssertTrue(g.boss.done)
        for s in slots { XCTAssertEqual(g.bugs.deadFlags[s], 1) }
        XCTAssertTrue(g.xp > xp0 || g.xpLevel > lvl0, "its bounty")
        g.tick()
        for u in uids { XCTAssertFalse((0..<g.bugs.count).contains { g.bugs.uid[$0] == u }, "compacted away") }
        XCTAssertEqual(g.phase, .won, "the BOSS step (the last) ends")
    }

    func testAFrozenPartLocksTheBody() {
        let g = toyGame(spec: BossFrameworkTests.stillToy())
        let L = g.level.lift, y = deckY(g)
        g.bossSetTrack([SIMD3(L.x + 20, y, L.z), SIMD3(L.x - 20, y, L.z)], loop: true)
        run(g, seconds: 1)
        var frozen: [Int] = []
        // the beam's chill on a segment: never frozen solid — the body locks 2 s
        let s = g.bossPart(4).slot
        g.bossBeamChill(s, 2)
        g.drainEvents { if case .bossPartFrozen(_, let p, _) = $0 { frozen.append(p) } }
        XCTAssertEqual(frozen, [4])
        XCTAssertEqual(g.boss.lock, 2)
        XCTAssertEqual(g.bugs.freezeTimers[s], 0)
        XCTAssertLessThanOrEqual(g.bugs.chills[s], 0.6 + 1e-5)
        let p0 = g.bossPart(0).position
        run(g, seconds: 1.5)
        XCTAssertEqual(simd_len(g.bossPart(0).position - p0), 0, accuracy: 1e-4, "locked")
        run(g, seconds: 1)
        XCTAssertGreaterThan(simd_len(g.bossPart(0).position - p0), 1, "free again")
        // an Ice Wave on the head while its window is open: brittle 1.5 s
        g.bossOpenWindow(0, 2)
        g.bossPartFreeze(g.bossPart(0).slot, nova: true)
        XCTAssertEqual(g.boss.brittle, 1.5)
        // the Queen ignores all of it
        let q = holdGame(cls: .cryo)
        q.debugBoss(hp: 10_000)
        let i = q.bossSlotNow()
        q.bossBeamChill(i, 5)
        q.bossPartFreeze(i, nova: true)
        XCTAssertEqual(q.bugs.chills[i], 0); XCTAssertEqual(q.boss.lock, 0); XCTAssertEqual(q.boss.brittle, 0)
    }

    func testMoveShapes() {
        let g = toyGame()
        let R = g.bossRT
        // a lane from (0, 0) along +x, 10 long, 2 wide
        var lane = BossMove("l", .lane, first: 0, cooldown: 1); lane.length = 10; lane.radius = 2
        R.ax[3] = 0; R.az[3] = 0; R.adx[3] = 1; R.adz[3] = 0
        XCTAssertNotNil(g.bossShapeHit(3, lane, 5, 0.9, 0))
        XCTAssertNil(g.bossShapeHit(3, lane, 5, 1.2, 0))
        XCTAssertNotNil(g.bossShapeHit(3, lane, 5, 1.2, 0.3), "its body overlaps")
        XCTAssertNil(g.bossShapeHit(3, lane, 11, 0, 0))
        XCTAssertEqual(g.bossShapeHit(3, lane, 5, -0.5, 0).map { $0.y }, -1, "pushed out sideways")
        // a cone of half-angle 30°, 6 long
        var cone = BossMove("c", .cone, first: 0, cooldown: 1); cone.length = 6; cone.angle = Float.pi / 6
        XCTAssertNotNil(g.bossShapeHit(3, cone, 5, 2, 0))
        XCTAssertNil(g.bossShapeHit(3, cone, 5, 4, 0))
        XCTAssertNil(g.bossShapeHit(3, cone, -1, 0, 0))
        XCTAssertNil(g.bossShapeHit(3, cone, 7, 0, 0))
        // three drop targets round the aim
        var drop = BossMove("d", .drop, first: 0, cooldown: 1); drop.count = 3; drop.radius = 1; drop.spread = 4
        R.turn[3] = 0
        XCTAssertNotNil(g.bossShapeHit(3, drop, 0, 0, 0))
        XCTAssertNotNil(g.bossShapeHit(3, drop, 0, 4, 0), "the second target, 4 m out")
        XCTAssertNil(g.bossShapeHit(3, drop, 2, 2, 0))
    }

    func testToyRunIsDeterministic() {
        func run1() -> [Float] {
            let g = toyGame(seed: 77, god: false, fight: true) { $0.autopilot = true }
            let L = g.level.lift, y = deckY(g)
            g.bossSetTrack([SIMD3(L.x + 5, y, L.z), SIMD3(L.x, y + 2, L.z + 5), SIMD3(L.x - 5, y, L.z), SIMD3(L.x, y, L.z - 5)], loop: true)
            for _ in 0..<(25 * 60) { g.tick(); g.clearEvents(); if g.phase != .playing { break } }
            var out: [Float] = [g.time, g.boss.hpFraction, Float(g.kills), Float(g.boss.phase), Float(g.rng.state & 0xFFFF)]
            for k in 0..<g.bossPartCount { let p = g.bossPart(k).position; out += [p.x, p.y, p.z] }
            return out
        }
        let a = run1(), b = run1()
        XCTAssertEqual(a, b)
        XCTAssertLessThan(a[1], 1, "the squad fought it")
    }

    // ---------------------------------------------------------------- arrivals (R10's Dig In: a boss in an endless hold)

    func testPeriodicRiderInAnEndlessHold() {
        let rider = BossRider(.queen, arrival: .every(first: 4, gap: 6), locks: false)
        let g = planGame(MissionPlan(id: "t-holdout", steps: [.hold(HoldStep(zone: .lift, time: .infinity, pulse: true, boss: rider))]))
        g.debugSkip()   // the squad on the lift: the endless hold starts
        XCTAssertEqual(g.stepPhase, .active)
        var warns: [Float] = [], spawns: [Float] = []
        let t0 = g.time
        func watch(_ e: GameEvent) {
            if case .bossWarning = e { warns.append(g.time - t0) }
            if case .bossSpawned = e { spawns.append(g.time - t0) }
        }
        run(g, seconds: 8, until: { g.boss.spawned }, watch)
        XCTAssertEqual(warns.first ?? -1, 4, accuracy: 0.05, "first 4 s into the hold")
        XCTAssertEqual(spawns.first ?? -1, 6, accuracy: 0.05)
        XCTAssertEqual(g.boss.arrivals, 1)
        // she dies: 6 s later her next warning, a fresh boss (full health), arrivals counted on
        g.killBug(g.bossSlotNow(), 0)
        let tk = g.time - t0
        run(g, seconds: 10, until: { g.boss.spawned && g.boss.arrivals == 2 }, watch)
        XCTAssertEqual(warns.count, 2)
        XCTAssertEqual(warns[1] - tk, 6, accuracy: 0.1, "the gap after her death")
        XCTAssertEqual(g.boss.arrivals, 2); XCTAssertTrue(g.boss.alive); XCTAssertEqual(g.boss.hpFraction, 1)
        // the hold never ends, never shows a NaN
        XCTAssertEqual(g.liftT, .infinity)
        XCTAssertFalse(g.objectiveProgress.isNaN)
        XCTAssertEqual(g.phase, .playing)
        XCTAssertEqual(g.threatState, .boss)
    }

    func testStepTimeRiderAndTheClassicRuleInAnEndlessHold() {
        // `.stepTime`: once, `at` s into the hold
        let a = planGame(MissionPlan(id: "t-st", steps: [.hold(HoldStep(zone: .lift, time: .infinity, boss: BossRider(.queen, arrival: .stepTime(3), locks: false)))]))
        a.debugSkip()
        var warnAt: Float = -1
        let t0 = a.time
        run(a, seconds: 6, until: { a.boss.spawned }) { if case .bossWarning = $0 { warnAt = a.time - t0 } }
        XCTAssertEqual(warnAt, 3, accuracy: 0.05)
        XCTAssertTrue(a.boss.alive)
        // the classic rule counts the hold's countdown: an endless hold never counts, so it never comes there (R1's note)
        let b = planGame(MissionPlan(id: "t-ht", steps: [.hold(HoldStep(zone: .lift, time: .infinity, boss: BossRider(.queen, locks: false)))]))
        b.debugSkip()
        run(b, seconds: 50)
        XCTAssertFalse(b.boss.spawned)
        // the legacy row has no Queen: neither rule brings her
        let c = planGame(MissionPlan(id: "t-st-v10", steps: [.hold(HoldStep(zone: .lift, time: .infinity, boss: BossRider(.queen, arrival: .stepTime(1), locks: false)))]),
                         tier: .legacyV10)
        c.debugSkip()
        run(c, seconds: 5)
        XCTAssertFalse(c.boss.spawned)
    }

    func testPulseOffHazard() {
        // a rider whose second phase cuts the lift pulse
        var s = BossFrameworkTests.stillToy(hp: 3000)
        s.phases[1].hazards = [.pulseOff]
        let rider = BossRider(.queen, arrival: .stepTime(0.5), locks: false, spec: s)
        let g = planGame(MissionPlan(id: "t-pulse", steps: [.hold(HoldStep(zone: .lift, time: .infinity, pulse: true, boss: rider))]))
        g.debugHoldFire = true
        g.debugSkip()
        run(g, seconds: 3, until: { g.boss.spawned })
        var pulses = 0
        run(g, seconds: 8) { if case .explosion(.pulse, _, _) = $0 { pulses += 1 } }
        XCTAssertGreaterThan(pulses, 0, "the lift pulses")
        g.hitBug(g.bossPart(0).slot, g.bugs.hpMax[g.bossPart(0).slot] * 0.6, 0)
        run(g, seconds: 0.1)
        XCTAssertEqual(g.boss.phase, 1)
        pulses = 0
        run(g, seconds: 10) { if case .explosion(.pulse, _, _) = $0 { pulses += 1 } }
        XCTAssertEqual(pulses, 0, "no pulse while it lives")
    }

    // ---------------------------------------------------------------- calibration: a boss mission's own bands

    func testTemplateBossBandsGate() {
        // a boss mission's template (B4's Manifold row: reached ≥ 75 %, killed ≥ 80 % of those, kill median 60–100 s)
        let band = CalibBand(tier: 1, winLo: 70, bossReachedLo: 75, bossKilledLo: 80, bossMedianLo: 60, bossMedianHi: 100)
        let t = MissionTemplate(id: "t-bossband", calib: MissionCalib(tiers: [1], runs: 4, seedBase: 1, bands: [band], gated: true)) { _ in
            MissionPlan(id: "t-bossband", steps: [.boss(BossStep(.queen, zone: .lift))])
        }
        func row(_ reached: Bool, _ killT: Float?) -> CalibRow {
            var r = CalibRow()
            r.tierIx = 1; r.tag = "vet"; r.mode = "auto"; r.q = "med"; r.mission = "t-bossband"
            r.result = killT != nil ? "won" : "lost"
            if reached { var q = CalibQueen(); q.killT = killT; r.queen = q }
            return r
        }
        // 10 runs: 9 reach it, 8 of those kill it (89 %), median 80 s
        var rows = (0..<8).map { row(true, 70 + Float($0) * 3) }
        rows.append(row(true, nil)); rows.append(row(false, nil))
        let ok = Calibration.gate(rows, templates: [t]).lines
        let mine = ok.filter { $0.text.hasPrefix("t-bossband") }
        XCTAssertEqual(mine.count, 4, "\(mine.map { $0.text })")
        XCTAssertTrue(mine.allSatisfy { $0.ok && $0.gated }, "\(mine.map { $0.text })")
        XCTAssertTrue(mine.contains { $0.text.contains("boss killed of reached 88.9%") })
        // killed in too few of the fights that reach it: the gate fails
        var bad = (0..<5).map { _ in row(true, 80) }
        bad += (0..<5).map { _ in row(true, nil) }
        let lines = Calibration.gate(bad, templates: [t]).lines.filter { $0.text.hasPrefix("t-bossband") }
        XCTAssertTrue(lines.contains { !$0.ok && $0.text.contains("boss killed of reached") })
        // the shipped templates set no boss band: the classic and the missions' gates are as before
        XCTAssertTrue(MissionTemplate.all.allSatisfy { ($0.calib?.bands ?? []).allSatisfy { $0.bossReachedLo == nil && $0.bossKilledLo == nil } })
    }
}

private func simd_len(_ v: SIMD3<Float>) -> Float { (v * v).sum().squareRoot() }
