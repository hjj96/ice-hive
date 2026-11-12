import XCTest
@testable import IceHiveCore

/// Stage 2 B4: the Threader (GameThreader.swift, GameThreaderAI.swift) and its arena, the Manifold (Manifold.swift) — every
/// move (the lure's 0.8 s lock, the strike's telegraph, slam and down window, the shed, the climb, the coil and its escape
/// routes, the rime spit, the squeeze's sequence, the pull-down changing the walk grid, the deck chase), the phases, the
/// damage routing and pools, the class counterplay, the bots, the mission and its calibration preset, determinism.
final class ThreaderTests: XCTestCase {

    // ---------------------------------------------------------------- helpers

    /// A game of the Manifold (its station and plan), the boss's warning as soon as the player is on the island.
    func manifold(_ tier: Difficulty = .veteran, seed: UInt32 = 7, god: Bool = true, autopilot: Bool = false,
                  configure: ((inout GameConfig) -> Void)? = nil) -> Game {
        tierGame(tier, seed: seed, autopilot: autopilot, god: god) { c in
            c.levelSource = ManifoldStation(); c.mission = .manifold; c.bossAt = 0
            configure?(&c)
        }
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

    /// The Manifold's BOSS step with the Threader there: the pumps skipped, the squad on the island; the bots hold their fire
    /// and their abilities unless `fight` (the Cryo's beam would lock the body).
    func arena(_ tier: Difficulty = .veteran, seed: UInt32 = 7, god: Bool = true, fight: Bool = false, autopilot: Bool = false,
               configure: ((inout GameConfig) -> Void)? = nil) -> Game {
        let g = manifold(tier, seed: seed, god: god, autopilot: autopilot, configure: configure)
        g.debugHoldFire = !fight
        if !fight { for m in g.marines { m.abCd = 1e9 } }
        g.debugSkip(); g.debugSkip()
        XCTAssertEqual(g.currentModule, .boss, "the two pumps done")
        g.debugSkip()
        XCTAssertEqual(g.stepPhase, .active, "on the island")
        XCTAssertTrue(run(g, seconds: 6, until: { g.boss.spawned }), "it came")
        XCTAssertTrue(g.boss.alive)
        XCTAssertEqual(g.boss.kind, .threader)
        g.clearEvents()
        return g
    }

    /// Marine `k` stands at (x, z) (and its last-tick place, so it does not slide).
    func put(_ g: Game, _ k: Int, _ x: Float, _ z: Float) {
        let m = g.marines[k]
        m.x = x; m.z = z; m.px = x; m.pz = z; m.vx = 0; m.vz = 0; m.kx = 0; m.kz = 0
    }

    /// The bots out of the way (on the landing pad: far from the arena), every tick of `seconds` (or until `cond`).
    @discardableResult
    func runAside(_ g: Game, seconds: Float, keep: Set<Int> = [0], heal: Bool = false, until cond: (() -> Bool)? = nil,
                  _ onEvent: ((GameEvent) -> Void)? = nil) -> Bool {
        for _ in 0..<Int(seconds * 60) {
            for k in 1..<4 where !keep.contains(k) { put(g, k, 28 + Float(k), 30) }
            // (the swarm keeps coming while the bots hold their fire: whoever stands is patched up before each tick)
            if heal { for m in g.marines where !m.downed { m.hp = m.maxHp } }
            g.tick()
            g.drainEvents { onEvent?($0) }
            if let c = cond, c() { return true }
        }
        return false
    }

    /// The boss's part `k` slot.
    func slot(_ g: Game, _ k: Int) -> Int { g.bossPartSlot(k) }

    /// Squad damage the boss dealt (its slot of the calibration ledger).
    func bossHurt(_ g: Game) -> Float { g.hurtBy[DamageSource.threader.ledger] }

    /// Force the Threader into phase `p` (its health just under the threshold) and let the phase begin.
    func toPhase(_ g: Game, _ p: Int) {
        let h = slot(g, 0)
        let below: [Float] = [1, 0.66, 0.33]
        g.bugs.hp[h] = g.bugs.hpMax[h] * (below[p] - 0.01)
        run(g, seconds: 0.1)
        XCTAssertEqual(g.boss.phase, p)
    }

    /// Start move `id` now (its clock run out), the boss free.
    func force(_ g: Game, _ id: String) {
        let m = g.bossSpec.moveIndex(id)
        XCTAssertGreaterThanOrEqual(m, 0, id)
        g.bossRT.clock[m] = 0
    }

    // ---------------------------------------------------------------- the rows, the name, the arena

    func testThreaderRows() {
        for (d, hp) in [(Difficulty.recruit, Float(3200)), (.veteran, 4500), (.nightmare, 7500)] {
            let s = d.boss(.threader)
            XCTAssertEqual(s, d.threader)
            XCTAssertEqual(s.hp, hp, d.id)
            XCTAssertEqual(s.speed, 6, "6 m/s on the trunks")
            guard let c = s.chain else { return XCTFail("a chain body") }
            XCTAssertEqual(c.segments, 18); XCTAssertEqual(c.spacing, 1.6); XCTAssertEqual(c.lead, 2)
            XCTAssertEqual(c.length, 2 + 17 * 1.6, accuracy: 1e-4, "≈ 30 m")
            XCTAssertEqual(c.head.downK, 2, "the head ×2 while it is down")
            XCTAssertEqual(c.head.damageK, 1)
            XCTAssertEqual(c.segment.damageK, 0.25, "the body ×0.25")
            XCTAssertEqual(c.nodes.map { $0.segment }, [3, 6, 9, 12, 15], "five lantern nodes along the body")
            for n in c.nodes {
                XCTAssertEqual(n.damageK, 1.5); XCTAssertEqual(n.pool, 0.08, "its own 8 % pool"); XCTAssertEqual(n.popStagger, 1.5)
            }
            XCTAssertEqual(s.phases.map { $0.below }, [1, 0.66, 0.33])
            XCTAssertTrue(s.phases[2].enraged); XCTAssertEqual(s.phases[2].speedK, 1.3, "enraged ×1.3")
            XCTAssertFalse(s.immune.freeze); XCTAssertEqual(s.immune.freezeLock, 2, "a frozen segment locks the body 2 s")
            XCTAssertEqual(s.immune.brittle, 1.5, "an Ice Wave on the head down: brittle 1.5 s")
            XCTAssertEqual(s.source, .threader)
            XCTAssertTrue(s.areaOnce)
            XCTAssertEqual(s.moves.map { $0.id }, ["strike", "strikeLow", "shed", "climb", "coil", "rime", "squeeze", "pull", "charge"])
            XCTAssertTrue(s.moves.allSatisfy { $0.kind == .custom })
            let st = s.move("strike")!, lo = s.move("strikeLow")!
            XCTAssertEqual([st.windUp, st.radius, st.damage, st.opensDown], [1.2, 3, 30, 2], "1.2 s, a 3 m slam, 30, 2 s down")
            XCTAssertGreaterThanOrEqual(st.knockback, 9, "the rig's knock-down")
            XCTAssertEqual(st.shape, .drop); XCTAssertEqual(st.phases, 0b011)
            XCTAssertEqual(lo.windUp, 0.6, "P3: from low height, 0.6 s"); XCTAssertEqual(lo.phases, 0b100)
            XCTAssertEqual(s.move("shed")!.cooldown, 14, "every 14 s"); XCTAssertEqual(s.move("shed")!.active, 1.5)
            XCTAssertEqual(s.move("climb")!.cooldown, 25, "every 25 s (P1)"); XCTAssertEqual(s.move("climb")!.phases, 0b001)
            XCTAssertEqual(s.move("coil")!.damage, 25); XCTAssertEqual(s.move("coil")!.phases, 0b010)
            XCTAssertEqual(s.move("rime")!.damage, 12); XCTAssertEqual(s.move("rime")!.phases, 0b010)
            XCTAssertEqual(s.move("squeeze")!.phases, 0b010); XCTAssertEqual(s.move("pull")!.phases, 0b100)
            XCTAssertEqual(s.move("charge")!.phases, 0b100)
        }
        XCTAssertEqual(Difficulty.legacyV10.threader.hp, 0, "no Threader on the hidden legacy row")
        XCTAssertEqual(BossKind.threader.name, .threader)
        XCTAssertEqual(NameRef.threader.key, "name.bug.threader")
        XCTAssertTrue(NameRef.all.contains(.threader))
        XCTAssertEqual(DamageSource.threader.ledger, DamageSource.queen.ledger, "in the boss's slot of the ledger")
        XCTAssertEqual(MetaText.lossTips[DamageSource.threader.rawValue].id, .tipLossThreader)
        XCTAssertEqual(TextID.tipLossThreader.signature, "@")
        XCTAssertEqual(TextID.objRestartPumps.signature, "dd")
    }

    func testManifoldArena() {
        let lv = Level(source: ManifoldStation())
        guard let A = lv.layout.manifold, let G = lv.overhead else { return XCTFail("the arena and its routes") }
        // the island with the pump housing, the ring, the bridges, the abyss between
        XCTAssertTrue(lv.canStand(5, 5)); XCTAssertTrue(lv.canStand(-5, 5))
        XCTAssertEqual(lv.walkValue(lv.cellOf(0.5, 0.5)), 2, "the pump housing is cover")
        XCTAssertTrue(lv.canStand(15, 0)); XCTAssertTrue(lv.canStand(0, -15)); XCTAssertTrue(lv.canStand(-15, 15))
        XCTAssertTrue(lv.canStand(10, 0)); XCTAssertTrue(lv.canStand(0, 10))
        XCTAssertFalse(lv.solid(10, 5), "the abyss between the island and the ring")
        XCTAssertFalse(lv.solid(25, 0), "beyond the ring")
        XCTAssertTrue(lv.canStand(Manifold.start.x, Manifold.start.y))
        XCTAssertTrue(lv.onLift(Manifold.lift.x, Manifold.lift.z))
        // the trunks: the «#» at 5 m over the island out to the ring, risers just outside it; the ring duct at 8 m
        XCTAssertEqual(A.trunks.count, 4)
        for t in A.trunks {
            XCTAssertEqual(t.length, 35, accuracy: 1e-3)
            XCTAssertEqual(t.edges.count, 5)
            for e in t.edges { XCTAssertEqual(G.point(e, G.length[e] * 0.5).y, 5, accuracy: 1e-3) }
        }
        XCTAssertEqual(A.trunks[0].project(0, -3.5).d, 0, accuracy: 1e-3)
        XCTAssertEqual(A.trunks[3].project(3.5, 0).d, 0, accuracy: 1e-3)
        var duct = 0
        for e in 0..<G.edgeCount where G.kind(e) == .duct && abs(G.point(e, 0).y - 8) < 0.01 && abs(G.point(e, G.length[e]).y - 8) < 0.01 { duct += 1 }
        XCTAssertEqual(duct, 12, "the ring duct's loop")
        XCTAssertEqual(G.ducts.count, 4, "four duct mouths at the ring's corners")
        XCTAssertEqual(G.entries.count, 12, "eight risers and four duct mouths")
        XCTAssertEqual(lv.layout.props.valves.count, 4, "four steam valves on the trunks")
        XCTAssertEqual(G.componentCount, 1, "one route set")
        // the island reaches the lift and the pad on foot
        let g = manifold()
        g.debugTeleport(5, 5)
        XCTAssertLessThan(g.swarmFlowField.distance(g.level.cellOf(Manifold.lift.x, Manifold.lift.z)), FlowField.unreachable)
        // the plan: two pumps → the Threader on the island → the lift
        XCTAssertEqual(g.mission.steps.map { $0.module }, [.switches, .boss, .extract])
        if case .switches(let s)? = g.mission.steps.first { XCTAssertEqual(s.needed, 2); XCTAssertEqual(s.sites.map { $0.time }, [15, 15]) }
        if case .boss(let b) = g.mission.steps[1] { XCTAssertEqual(b.boss, .threader); XCTAssertEqual(b.zone, Manifold.zone) }
        XCTAssertNotNil(MissionTemplate.named("manifold"))
        XCTAssertTrue(MissionTemplate.playable.contains { $0.id == "manifold" })
    }

    // ---------------------------------------------------------------- arrival

    func testItComesOutOfThePipes() {
        let g = manifold()
        g.debugHoldFire = true
        g.debugSkip(); g.debugSkip(); g.debugSkip()
        var warned = false, said = false, spawned = false
        run(g, seconds: 6, until: { g.boss.spawned }) { e in
            if case .bossWarning(let k, let p) = e { warned = k == .threader; XCTAssertEqual(p.x, -3.5); XCTAssertEqual(p.y, -15) }
            if case .toast(let t, _) = e, t.id == .toastThreaderPipes { said = true }
            if case .bossSpawned(.threader, _) = e { spawned = true }
        }
        XCTAssertTrue(warned && spawned); XCTAssertTrue(said, "«Something big in the pipes.»")
        XCTAssertEqual(g.bossPartCount, 1 + 18 + 5)
        let h = g.bossPart(0)
        XCTAssertEqual(h.position.y, 5, accuracy: 0.05, "on its trunk")
        XCTAssertTrue(h.up, "out of the deck weapons' reach up there")
        XCTAssertEqual(g.boss.hpFraction, 1)
        // it hunts along the trunks: the head stays on the «#» at 5 m
        run(g, seconds: 3)
        let p = g.bossPart(0).position
        XCTAssertEqual(p.y, 5, accuracy: 0.05)
        XCTAssertTrue(abs(abs(p.x) - 3.5) < 0.05 || abs(abs(p.z) - 3.5) < 0.05, "on a trunk line")
        XCTAssertEqual(g.threader.mode, .roam)
        XCTAssertTrue(g.threader.lure, "its lure sweeps")
        // the body follows the head's path by arc length
        for k in 1...18 {
            let s = g.bossPart(k), b = g.bossBodyPoint(behind: 2 + Float(k - 1) * 1.6)!
            XCTAssertEqual(s.position.x, b.position.x, accuracy: 0.15); XCTAssertEqual(s.position.z, b.position.z, accuracy: 0.15)
        }
    }

    // ---------------------------------------------------------------- the lure and the strike

    /// The player held in the light every tick (the bots away): ticks until the beam locks (the lure free to lock: its
    /// arrival's THREADER_FIRST_GAP or a strike's gap waived, no light gathered yet).
    func lockTicks(_ g: Game, _ onEvent: ((GameEvent) -> Void)? = nil) -> Int {
        var n = 0
        let iS = g.thr.iStrike
        // (hunting: its narrow fast sweep stays on the marine it hunts — the wide slow one only grazes a marine standing in it)
        g.thr.lockGap = 0; g.thr.noLock = 10
        for k in 0..<4 { g.thr.exposure[k] = 0 }
        while n < 600 {
            put(g, 0, g.thr.lx, g.thr.lz)
            for k in 1..<4 { put(g, k, 28 + Float(k), 30) }
            g.tick()
            g.drainEvents { onEvent?($0) }
            n += 1
            if g.bossRT.stage[iS] == 1 { return n }
        }
        return n
    }

    func testTheLureLocksAfterPointEightSecondsInItsLight() {
        let g = arena()
        runAside(g, seconds: 1)
        var cue = false, said = false
        let n = lockTicks(g) { e in
            if case .bossCue(.threader, .lureLock, _, let v) = e { cue = v == 0 }
            if case .toast(let t, _) = e, t.id == .toastThreaderLight { said = true }
        }
        // (0.8 s: 48 ticks of light; the strike starts on the runner's next tick)
        XCTAssertGreaterThanOrEqual(n, 48); XCTAssertLessThanOrEqual(n, 52, "locked after 0.8 s in the light")
        XCTAssertEqual(g.thr.locked, 0)
        XCTAssertEqual(g.threader.mode, .strike)
        XCTAssertGreaterThan(g.threader.strikeT, 1.1)
        XCTAssertTrue(cue); XCTAssertTrue(said, "«It's got a light — stay out of it!»")
        // out of the light the light ebbs: no lock while it stays out
        let h = arena(seed: 9)
        runAside(h, seconds: 1)
        h.thr.noLock = 10; h.thr.lockGap = 99
        for k in 0..<4 { h.thr.exposure[k] = 0 }
        for _ in 0..<30 { put(h, 0, h.thr.lx, h.thr.lz); for k in 1..<4 { put(h, k, 28 + Float(k), 30) }; h.tick() }
        XCTAssertEqual(h.thr.exposure[0], 0.5, accuracy: 0.02)
        for _ in 0..<60 { put(h, 0, h.thr.lx + 8, h.thr.lz + 8); for k in 1..<4 { put(h, k, 28 + Float(k), 30) }; h.tick() }
        XCTAssertEqual(h.thr.exposure[0], 0, "it ebbs out of the light")
        XCTAssertEqual(h.bossRT.stage[h.thr.iStrike], 0)
    }

    func testStrikeTelegraphSlamAndDownWindow() {
        let g = arena(god: false)
        runAside(g, seconds: 1)
        _ = lockTicks(g)
        let iS = g.thr.iStrike
        let sx = g.thr.px, sz = g.thr.pz
        // the closing ring at the predicted place: 4.35 → 3 m over 1.2 s (the lexicon's «lands here», frost-white)
        let ring = g.telegraphs.first { $0.active && $0.cause == .bossMove && $0.shape == .drop }
        XCTAssertNotNil(ring)
        XCTAssertEqual(ring?.x ?? 0, sx, accuracy: 1e-3); XCTAssertEqual(ring?.r0 ?? 0, 3 * 1.45, accuracy: 1e-3)
        XCTAssertEqual(ring?.r1 ?? 0, 3, accuracy: 1e-3); XCTAssertEqual(ring?.life ?? 0, 1.2, accuracy: 1e-3)
        // the player stays in the ring; the head stays up on its trunk until its last moment
        let y0 = g.bossPart(0).position.y
        var landed = -1, hurt0: Float = 0
        for t in 1...90 {
            put(g, 0, sx, sz)
            for k in 1..<4 { put(g, k, 28 + Float(k), 30) }
            if t == 40 { XCTAssertEqual(g.bossPart(0).position.y, y0, accuracy: 0.01, "still up 0.65 s in") }
            hurt0 = bossHurt(g)
            g.tick()
            if g.threader.mode == .down { landed = t; break }
        }
        // (it starts the tick it locked: 1.2 s = 72 ticks)
        XCTAssertEqual(Float(landed), 72, accuracy: 1.5, "1.2 s after the lock the head drops")
        XCTAssertEqual(bossHurt(g) - hurt0, 30 * g.dmgMul, accuracy: 0.01, "a 3 m slam: 30 × the damage multiplier")
        XCTAssertGreaterThanOrEqual(hypotf(g.player.kx, g.player.kz), 9, "the knock-down")
        XCTAssertEqual(g.bossPart(0).position.y, g.level.groundY(sx, sz) + 0.5, accuracy: 0.05, "the head down on the deck")
        XCTAssertFalse(g.bossPart(0).up, "within every deck weapon's reach")
        XCTAssertEqual(g.bossPart(0).down, 2, accuracy: 0.02, "the 2 s punish window")
        XCTAssertEqual(g.bossRT.stage[iS], 0)
        // ×2 on the head while it is down
        let h = slot(g, 0), hp0 = g.bugs.hp[h]
        g.hitBug(h, 100, 0)
        XCTAssertEqual(hp0 - g.bugs.hp[h], 200, accuracy: 0.01)
        // after the window it pulls its head back up its path to the trunk; the lure cannot lock for a while
        runAside(g, seconds: 2.1)
        XCTAssertEqual(g.bossPart(0).down, 0)
        let hp1 = g.bugs.hp[h], k1: Float = g.bossPart(0).up ? THREADER_HEAD_UP : 1
        g.hitBug(h, 100, 0)
        XCTAssertEqual(hp1 - g.bugs.hp[h], 100 * k1, accuracy: 0.01, "×1 once the window closed (the armour once up)")
        XCTAssertTrue(runAside(g, seconds: 3, until: { g.threader.mode == .roam }))
        XCTAssertEqual(g.bossPart(0).position.y, 5, accuracy: 0.05, "back up on its trunk")
        XCTAssertGreaterThan(g.thr.lockGap, 0, "the lure cannot lock again yet")
    }

    func testThePyrosNapalmMakesTheHeadRecoil() {
        let g = arena()
        runAside(g, seconds: 1)
        _ = lockTicks(g)
        // napalm under the strike spot
        let k = g.marines.firstIndex { $0.cls == .pyro }!
        put(g, k, g.thr.px + 1, g.thr.pz)
        g.marines[k].abCd = 0
        XCTAssertTrue(g.useAbility(g.marines[k], 0, 0))
        var recoil = false
        runAside(g, seconds: 1.3, keep: [0, k], until: { g.threader.mode == .down }) { e in
            if case .bossCue(.threader, .recoil, _, _) = e { recoil = true }
        }
        XCTAssertTrue(recoil)
        XCTAssertEqual(g.bossPart(0).down, 3, accuracy: 0.05, "+1 s down")
        XCTAssertEqual(g.threaderStats.recoils, 1)
    }

    func testANewPhaseEndsTheWindow() {
        let g = arena()
        runAside(g, seconds: 1)
        _ = lockTicks(g)
        XCTAssertTrue(runAside(g, seconds: 1.5, until: { g.threader.mode == .down }))
        toPhase(g, 1)
        XCTAssertEqual(g.bossPart(0).down, 0, "the window closes")
        XCTAssertGreaterThan(g.boss.untouchable, 1, "the scream: a moment untouchable")
        let h = slot(g, 0), hp0 = g.bugs.hp[h]
        g.hitBug(h, 500, 0)
        XCTAssertEqual(g.bugs.hp[h], hp0, "no damage while untouchable")
        XCTAssertTrue(runAside(g, seconds: 4, until: { g.threader.mode == .roam }), "back up its path")
    }

    func testTheLureWaitsAfterItsArrivalAndAPhase() {
        // its arrival: THREADER_FIRST_GAP s before the beam may lock, however long a marine stands in its light
        let g = arena()
        XCTAssertTrue(runAside(g, seconds: 1, until: { g.thr.ready }))
        XCTAssertEqual(g.thr.lockGap, THREADER_FIRST_GAP, accuracy: 0.05)
        g.thr.noLock = 10
        var n = 0
        while n < 900 && g.bossRT.stage[g.thr.iStrike] == 0 {
            put(g, 0, g.thr.lx, g.thr.lz)
            for k in 1..<4 { put(g, k, 28 + Float(k), 30) }
            g.tick(); g.clearEvents()
            n += 1
        }
        XCTAssertEqual(Float(n) / 60, THREADER_FIRST_GAP, accuracy: 0.2, "it locks once the gap is over")
        // a new phase: the scream, then THREADER_PHASE_GAP s without a lock
        let h = arena(seed: 9)
        runAside(h, seconds: 0.5)
        toPhase(h, 1)
        XCTAssertGreaterThanOrEqual(h.thr.lockGap, THREADER_PHASE_GAP - 0.15)
        XCTAssertEqual(h.boss.untouchable, THREADER_PHASE_UNTOUCHABLE - 0.1, accuracy: 0.05)
    }

    func testAPunishWindowEndsAtItsPain() {
        let g = arena()
        runAside(g, seconds: 1)
        _ = lockTicks(g)
        XCTAssertTrue(runAside(g, seconds: 1.5, until: { g.threader.mode == .down }))
        let h = slot(g, 0), max = g.bugs.hpMax[h]
        // under the cap the window stays open (×2)
        g.hitBug(h, max * 0.05, 0)
        XCTAssertGreaterThan(g.bossPart(0).down, 1.5)
        XCTAssertEqual(g.threaderStats.pains, 0)
        // THREADER_WINDOW_CAP of its health in one window: it screams and pulls back up at once
        var pain = -1
        g.hitBug(h, max * (THREADER_WINDOW_CAP - 0.1) / 2 + 1, 0)
        g.drainEvents { e in if case .bossCue(.threader, .pain, _, let v) = e { pain = v } }
        XCTAssertEqual(pain, 0, "the window's pain")
        XCTAssertEqual(g.bossPart(0).down, 0, "the window closed")
        XCTAssertEqual(g.threaderStats.pains, 1)
        XCTAssertTrue(runAside(g, seconds: 2, until: { g.threader.mode == .roam }), "back up its path (fast)")
        // a coil: THREADER_WINDOW_CAP of its health and it lets go
        let c = coilGame(seed: 12)
        runAside(c, seconds: 1.6)
        var let0 = false, pain1 = false
        let ch = slot(c, 0)
        c.hitBug(slot(c, 20), c.bugs.hpMax[ch] * THREADER_WINDOW_CAP / 1.5 + 5, 0)
        c.drainEvents { e in
            if case .bossCue(.threader, .pain, _, 1) = e { pain1 = true }
            if case .bossCue(.threader, .coilLetGo, _, _) = e { let0 = true }
        }
        XCTAssertTrue(pain1 && let0, "the coil's pain: it lets go")
        let hurt0 = bossHurt(c)
        runAside(c, seconds: 3)
        XCTAssertEqual(bossHurt(c), hurt0, "no crush")
    }

    func testAMoveThatCannotStartComesAgainShortly() {
        let g = arena()
        toPhase(g, 1)
        runAside(g, seconds: 1.4)
        _ = lockTicks(g)
        XCTAssertEqual(g.threader.mode, .strike)
        // the coil cannot start while the head strikes: tried again in 0.5 s, not after its whole cooldown
        let i = g.thr.iCoil
        g.bossRT.clock[i] = 0
        runAside(g, seconds: 2.0 / 60)
        XCTAssertLessThanOrEqual(g.bossRT.clock[i], 0.5)
        XCTAssertEqual(g.bossRT.stage[i], 0)
        XCTAssertGreaterThan(g.bossSpec.moves[i].cooldown, 5)
    }

    // ---------------------------------------------------------------- shed, climb

    func testShedDropsTicksAlongTheBody() {
        let g = arena()
        runAside(g, seconds: 0.5)
        let d0 = g.droppersAlive
        force(g, "shed")
        var dust = false, ticks = 0
        runAside(g, seconds: 0.05) { e in if case .bossCue(.threader, .shed, _, _) = e { dust = true } }
        XCTAssertTrue(dust, "frost dust along the body first")
        XCTAssertGreaterThan(g.threader.shedWarn, 1.3)
        XCTAssertEqual(g.droppersAlive, d0, "nothing yet")
        runAside(g, seconds: 1.6) { e in if case .bossCue(.threader, .ticks, _, let n) = e { ticks = n } }
        XCTAssertGreaterThanOrEqual(ticks, 1)
        XCTAssertLessThanOrEqual(ticks, 6)
        XCTAssertGreaterThan(g.droppersAlive, d0, "R4's Droppers")
        XCTAssertLessThanOrEqual(g.droppersAlive, g.difficulty.dropperCap, "the live Dropper cap holds")
        XCTAssertEqual(g.threaderStats.sheds, 1)
    }

    func testClimbToTheRingDuctUntouchable() {
        let g = arena()
        runAside(g, seconds: 0.5)
        force(g, "climb")
        XCTAssertTrue(runAside(g, seconds: 8, until: { g.threader.mode == .duct }), "up a riser pipe to the duct")
        XCTAssertEqual(g.bossPart(0).position.y, 8, accuracy: 0.1, "the ring duct at 8 m")
        XCTAssertGreaterThan(g.boss.untouchable, 3.9)
        let h = slot(g, 0), hp0 = g.bugs.hp[h]
        g.hitBug(h, 1000, 0)
        XCTAssertEqual(g.bugs.hp[h], hp0, "untouchable up there")
        let from = g.thr.ductGoal
        XCTAssertTrue(runAside(g, seconds: 9, until: { g.threader.mode == .roam }), "down onto a trunk")
        XCTAssertEqual(g.bossPart(0).position.y, 5, accuracy: 0.05)
        XCTAssertNotEqual(g.threaderTrunkOfDuct(from), -1)
        XCTAssertEqual(g.threaderStats.climbs, 1)
        XCTAssertGreaterThan(g.threaderStats.untouchT, 3.5)
    }

    // ---------------------------------------------------------------- the coil

    /// P2, the coil started round the player at (x, z) (the bots away).
    func coilGame(seed: UInt32 = 7, god: Bool = true, at p: Vec2 = Vec2(4.5, 4.5), configure: ((inout GameConfig) -> Void)? = nil) -> Game {
        let g = arena(seed: seed, god: god, configure: configure)
        toPhase(g, 1)
        runAside(g, seconds: 1.4)
        put(g, 0, p.x, p.y)
        force(g, "coil")
        // (it coils round a marine within 16 m of its head: tried again every 0.5 s until its head is near)
        XCTAssertTrue(runAside(g, seconds: 6, until: { g.threader.mode == .coil }))
        XCTAssertEqual(g.threader.mode, .coil)
        return g
    }

    /// The ring segment k (1…17) whose middle with segment k + 1 lies nearest the direction (dx, dz) from the coil's centre,
    /// and that middle's direction.
    func ringGap(_ g: Game, toward dx: Float, _ dz: Float) -> (k: Int, ux: Float, uz: Float) {
        let c = g.threader.coilCenter
        var best = (k: 1, ux: dx, uz: dz)
        var bd: Float = 9
        for k in 1..<THREADER_SEGMENTS {
            let a = g.bossPart(k).position, b = g.bossPart(k + 1).position
            var mx = (a.x + b.x) / 2 - c.x, mz = (a.z + b.z) / 2 - c.y
            let ml = hypotf(mx, mz)
            if abs(ml - g.threader.coilRadius) > 0.5 { continue }
            mx /= ml; mz /= ml
            let dd = hypotf(mx - dx, mz - dz)
            if dd < bd { bd = dd; best = (k, mx, mz) }
        }
        return best
    }

    func testCoilRingShrinksAndCrushes() {
        let g = coilGame()
        let c = g.threader.coilCenter
        XCTAssertEqual(c.x, 3.5, accuracy: 0.01, "round the marine at (4.5, 4.5), its ring kept over the island")
        XCTAssertEqual(c.y, 3.5, accuracy: 0.01)
        // the ring: the body lowered to 2 m round the deck section, 7 m across, shrinking for 2.5 s
        runAside(g, seconds: 1.5)
        var onRing = 0
        for k in 1...18 {
            let s = g.bossPart(k)
            let d = hypotf(s.position.x - c.x, s.position.z - c.y)
            if abs(d - g.threader.coilRadius) < 0.2 { onRing += 1; XCTAssertFalse(s.up, "within reach: the body lowers to 2 m") }
        }
        XCTAssertGreaterThanOrEqual(onRing, 10, "a ring of segments")
        XCTAssertEqual(g.threader.coilRadius, 3.5, accuracy: 0.2, "the 7 m ring")
        XCTAssertEqual(g.threader.coilT, 2.5, accuracy: 0.1)
        runAside(g, seconds: 1.25)
        XCTAssertLessThan(g.threader.coilRadius, 3.0, "it shrinks")
        // a runner inside (frozen: it neither bites nor steps out) dies with the player's crush (the player held in the middle)
        let i = g.spawnBug(T_RUN, c.x + 0.6, c.y - 0.4)
        g.bugs.frz[i] = 5
        let uid = g.bugs.uid[i]
        let hurt0 = bossHurt(g)
        var crush = false
        g.godMode = false
        for _ in 0..<84 {
            for m in g.marines where !m.downed { m.hp = m.maxHp }
            put(g, 0, c.x, c.y)
            for k in 1..<4 { put(g, k, 28 + Float(k), 30) }
            g.tick()
            g.drainEvents { e in if case .bossCue(.threader, .coilCrush, _, _) = e { crush = true } }
        }
        XCTAssertTrue(crush)
        XCTAssertEqual(bossHurt(g) - hurt0, 25 * g.dmgMul, accuracy: 0.01, "25 crush × the damage multiplier to whoever is inside")
        var alive = false
        for k in 0..<g.bugs.count where g.bugs.uid[k] == uid && g.bugs.dead[k] == 0 { alive = true }
        XCTAssertFalse(alive, "the bugs inside die too")
        XCTAssertEqual(g.threaderStats.crushed, 1)
        XCTAssertTrue(runAside(g, seconds: 4, until: { g.threader.mode == .roam }), "it lets go and climbs back up its path")
    }

    func testCoilEscapeRoutes() {
        // walking out is blocked: the ring's segments push a walker back in
        let g = coilGame()
        runAside(g, seconds: 1.6)
        let c = g.threader.coilCenter
        for _ in 0..<60 {
            for k in 1..<4 { put(g, k, 28 + Float(k), 30) }
            g.setPlayerInput(move: Vec2(1, 0), aim: nil, fire: false, ability: false, dash: false)
            g.tick()
        }
        XCTAssertLessThan(hypotf(g.player.x - c.x, g.player.z - c.y), g.threader.coilRadius + 0.2, "walking out: kept in")
        // a dash goes through a gap
        let d = coilGame(seed: 8)
        runAside(d, seconds: 1.6)
        let dc = d.threader.coilCenter
        // (from beside the ring toward the middle between two of its segments, toward the island's open deck: a dash ≈ 3.7 m)
        let (_, ux, uz) = ringGap(d, toward: -1, 0)
        put(d, 0, dc.x + ux * 1.8, dc.y + uz * 1.8)
        d.setPlayerInput(move: Vec2(0, 0), aim: nil, fire: false, ability: false, dash: false)
        d.player.dashCd = 0
        d.tryDash(d.player, ux, uz)
        runAside(d, seconds: 0.4)
        XCTAssertGreaterThan(hypotf(d.player.x - dc.x, d.player.z - dc.y), d.threader.coilRadius + 0.3, "dashed out through a gap")
        // two frozen ring segments open a gap: walking out through it
        let f = coilGame(seed: 9)
        runAside(f, seconds: 1.6)
        let fc = f.threader.coilCenter
        let (fk, gx, gz) = ringGap(f, toward: -1, 0)
        let gl: Float = 1
        f.bossRT.frozen[fk] = 2; f.bossRT.frozen[fk + 1] = 2
        var gap = false
        runAside(f, seconds: 0.05) { e in if case .bossCue(.threader, .coilGap, _, let s) = e { gap = s == fk } }
        XCTAssertTrue(gap); XCTAssertEqual(f.threader.coilGap, fk)
        put(f, 0, fc.x, fc.y)
        for _ in 0..<60 {
            for k in 1..<4 { put(f, k, 28 + Float(k), 30) }
            f.setPlayerInput(move: Vec2(gx / gl, gz / gl), aim: nil, fire: false, ability: false, dash: false)
            f.tick()
        }
        XCTAssertGreaterThan(hypotf(f.player.x - fc.x, f.player.z - fc.y), f.threader.coilRadius + 0.4, "walked out through the gap")
        // a grenade on a node makes it let go: no crush
        let n = coilGame(seed: 10, god: false)
        runAside(n, seconds: 1.6)
        var node = -1
        for q in 19..<24 where !n.bossPart(q).up { node = q; break }
        XCTAssertGreaterThanOrEqual(node, 0, "a node down on the ring")
        let np = n.bossPart(node).position
        n.queueBoom(np.x, np.z, 2.5, 50, 0, .frag)
        var letGo = false
        runAside(n, seconds: 0.1) { e in if case .bossCue(.threader, .coilLetGo, _, _) = e { letGo = true } }
        XCTAssertTrue(letGo)
        let hurt0 = bossHurt(n)
        runAside(n, seconds: 3)
        XCTAssertEqual(bossHurt(n), hurt0, "no crush")
        XCTAssertEqual(n.threaderStats.letGo, 1); XCTAssertEqual(n.threaderStats.crushed, 0)
    }

    // ---------------------------------------------------------------- rime, squeeze

    func testRimeSpitAlongATrunk() {
        let g = arena(god: false)
        toPhase(g, 1)
        runAside(g, seconds: 1.4)
        put(g, 0, 14, -3.5)    // on the ring under trunk 0's footprint (no other trunk within 4 m)
        force(g, "rime")
        runAside(g, seconds: 0.05)
        XCTAssertEqual(g.threader.mode, .rime)
        let lane = g.telegraphs.first { $0.active && $0.cause == .bossMove && $0.shape == .beam }
        XCTAssertNotNil(lane, "a red lane")
        XCTAssertEqual(lane?.len ?? 0, 35, accuracy: 0.01, "along the trunk's whole footprint")
        XCTAssertEqual(lane?.w ?? 0, 2.6, accuracy: 0.01)
        XCTAssertEqual(lane?.wind ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(lane?.z ?? 0, -3.5, accuracy: 0.01)
        let hurt0 = bossHurt(g)
        runAside(g, seconds: 1.1, until: { self.bossHurt(g) > hurt0 })
        XCTAssertEqual(bossHurt(g) - hurt0, 12 * g.dmgMul, accuracy: 0.01, "12 × the damage multiplier in the lane")
        XCTAssertEqual(g.threaderStats.rimeHits, 1)
    }

    func testSqueezeBurstsInSequence() {
        let g = arena()
        toPhase(g, 1)
        runAside(g, seconds: 1.4)
        put(g, 0, 14, 3.5)      // on the ring under trunk 1, on its last burst's curtain from its a end
        force(g, "squeeze")
        g.godMode = false
        runAside(g, seconds: 0.05, heal: true)
        XCTAssertEqual(g.threader.mode, .squeeze)
        let k = g.threader.squeezeTrunk
        XCTAssertEqual(k, 1, "the trunk the squad stands under")
        // burst j warns at j × 1.5 s for 1.5 s, then vents 3 s
        var states: [[Int]] = []
        for t in [0.1, 1.6, 3.1, 4.6] as [Float] {
            while g.threader.squeezeT < t { runAside(g, seconds: 1.0 / 60, heal: true) }
            states.append((0..<4).map { g.threaderBurst($0)!.state })
        }
        XCTAssertEqual(states[0], [1, 0, 0, 0])
        XCTAssertEqual(states[1], [2, 1, 0, 0])
        XCTAssertEqual(states[2], [2, 2, 1, 0])
        XCTAssertEqual(states[3], [3, 2, 2, 1])
        XCTAssertEqual(g.telegraphs.filter { $0.active && $0.cause == .steam && $0.shape == .lane }.count, 3, "a steam lane per burst so far")
        // the curtain scalds the marine under it (10/s, in 2.5 HP steps)
        let b = (0..<4).first { j in
            let s = g.threaderBurst(j)!
            return g.threaderLaneStep(g.player, s.from.x, s.from.y, (s.to.x - s.from.x) / 7, (s.to.y - s.from.y) / 7, 7, s.width, pad: 0) != nil
        }
        XCTAssertNotNil(b, "the player stands on one burst's curtain")
        runAside(g, seconds: 6, heal: true)
        XCTAssertGreaterThan(g.threaderStats.steamHurt, 0, "its curtain scalded the player once it vented")
        XCTAssertEqual(g.threader.mode, .roam, "over after the last curtain")
        XCTAssertEqual(g.threaderStats.squeezes, 1)
    }

    // ---------------------------------------------------------------- P3: pull down, the deck chase

    func testPullDownChangesTheWalkGrid() {
        let g = arena(god: false)
        let lv = g.level
        let c0 = lv.cellOf(5.5, 3.5), cg = lv.cellOf(0.5, 3.5), cb = lv.cellOf(10.5, 3.5)
        XCTAssertEqual(lv.walkValue(c0), 1); XCTAssertEqual(lv.walkValue(cb), 0)
        func hold() { put(g, 0, 4.5, 4.6); put(g, 1, 4.5, 6.5); put(g, 2, -4.5, 6.2); put(g, 3, 5.5, 6.5) }
        hold()
        toPhase(g, 2)
        XCTAssertTrue(g.boss.enraged)
        var rip = -1
        // (the squad held where it stands until the pull starts: the trunk with the most of it near)
        var started = false
        for _ in 0..<240 where !started {
            hold()
            g.tick()
            g.drainEvents { e in if case .bossCue(.threader, .pullRip, _, let k) = e { rip = k } }
            started = g.threader.pullTrunk >= 0
        }
        XCTAssertTrue(started)
        XCTAssertEqual(rip, 1, "the trunk over the squad")
        let lane = g.telegraphs.first { $0.active && $0.cause == .bossMove && $0.shape == .lane && abs($0.wind - 2) < 0.01 }
        XCTAssertNotNil(lane, "a long red lane along its whole length")
        XCTAssertEqual(lane?.len ?? 0, 35, accuracy: 0.01)
        put(g, 0, 4.5, 3.6)
        let hurt0 = bossHurt(g)
        var crash = false
        for _ in 0..<150 {
            put(g, 0, 4.5, 3.6)
            g.tick()
            g.drainEvents { e in if case .bossCue(.threader, .pullCrash, _, _) = e { crash = true } }
            if crash { break }
        }
        XCTAssertTrue(crash)
        XCTAssertEqual(bossHurt(g) - hurt0, 30 * g.dmgMul, accuracy: 0.01, "the crash")
        // the walk grid: an obstacle on the island (its snapped middle open), a bridge over the gaps
        XCTAssertEqual(lv.walkValue(c0), 2, "an obstacle on the island")
        XCTAssertEqual(lv.walkValue(cg), 1, "its snapped middle stays open")
        XCTAssertEqual(lv.walkValue(cb), 1, "a bridge over the gap")
        XCTAssertGreaterThan(lv.dynamicCellCount, 20)
        XCTAssertTrue(lv.canStand(g.player.x, g.player.z), "nobody stands inside the obstacle")
        // its routes are gone (no route choice takes them)
        let G = lv.overhead!
        for e in lv.layout.manifold!.trunks[1].edges { XCTAssertTrue(G.isBlocked(e)) }
        XCTAssertFalse(G.isBlocked(lv.layout.manifold!.trunks[0].edges[2]))
        // the swarm's flow goes across the new bridge
        run(g, seconds: 0.3)
        XCTAssertEqual(g.threader.fallenTrunk, 1)
        XCTAssertEqual(g.threader.mode, .deck)
        // a new sortie on the same level gets the grid back as laid
        var c = GameConfig()
        c.levelSource = ManifoldStation(); c.mission = .manifold
        _ = Game(seed: 3, playerClass: .gunner, config: c, level: lv)
        XCTAssertEqual(lv.walkValue(c0), 1); XCTAssertEqual(lv.walkValue(cb), 0); XCTAssertEqual(lv.dynamicCellCount, 0)
        XCTAssertFalse(G.isBlocked(lv.layout.manifold!.trunks[1].edges[2]))
    }

    func testDeckChaseChargesAndLunges() {
        let g = arena(god: false)
        put(g, 0, 4.5, 5.5)
        toPhase(g, 2)
        XCTAssertTrue(run(g, seconds: 6, until: { g.threader.mode == .deck }), "down on the deck after the pull")
        // the whole body at deck height: every part in reach, the nodes exposed (×1.5)
        for k in 0..<g.bossPartCount { XCTAssertFalse(g.bossPart(k).up, "part \(k) in reach") }
        let hy = g.bossPart(0).position
        XCTAssertEqual(hy.y, g.level.groundY(hy.x, hy.z) + 0.6, accuracy: 0.05)
        XCTAssertEqual(g.bossRT.bonus[19], 1, "the nodes exposed")
        // first it keeps away: out to the ring (its charges come from there; none now)
        XCTAssertGreaterThan(g.thr.awayT, 0)
        g.bossRT.clock[g.thr.iCharge] = 99
        let d0 = max(abs(g.bossPart(0).position.x), abs(g.bossPart(0).position.z))
        runAside(g, seconds: 3.2)
        let d1 = max(abs(g.bossPart(0).position.x), abs(g.bossPart(0).position.z))
        XCTAssertGreaterThan(d1, max(d0, 9), "out toward the ring")
        // a charge: the beam along its path for 1 s, then fast after its marine
        let h0 = g.bossPart(0).position
        put(g, 0, h0.x + (h0.x < 0 ? 9 : -9), h0.z)
        if !g.level.canStand(g.player.x, g.player.z) { put(g, 0, 0, 5.5) }
        force(g, "charge")
        runAside(g, seconds: 0.05)
        if g.threader.mode == .charge {
            let cone = g.telegraphs.first { $0.active && $0.cause == .bossMove && $0.shape == .cone }
            XCTAssertNotNil(cone, "the lure beam along its path")
            XCTAssertEqual(cone?.wind ?? 0, 1, accuracy: 0.01)
            let p0 = g.bossPart(0).position
            runAside(g, seconds: 1.3)
            let p1 = g.bossPart(0).position
            XCTAssertGreaterThan(hypotf(p1.x - p0.x, p1.z - p0.z), 2, "it charges")
        }
        XCTAssertGreaterThanOrEqual(g.threaderStats.pulls, 1)
        // the lunge: a strike from low height, 0.6 s
        XCTAssertEqual(g.bossSpec.move("strikeLow")!.windUp, 0.6)
    }

    // ---------------------------------------------------------------- damage routing and pools

    func testDamageRoutingAndPools() {
        let g = arena()
        runAside(g, seconds: 0.5)
        let h = slot(g, 0), S = g.bugs
        func dealt(_ part: Int, _ dmg: Float, src: Int = 0) -> Float {
            let hp0 = S.hp[h]
            g.hitBug(slot(g, part), dmg, src)
            return hp0 - S.hp[h]
        }
        XCTAssertTrue(g.bossPart(0).up)
        XCTAssertEqual(dealt(0, 100), 25, accuracy: 0.01, "the armoured head up on its trunk ×0.25 (THREADER_HEAD_UP)")
        XCTAssertEqual(dealt(5, 100), 25, accuracy: 0.01, "the body ×0.25")
        XCTAssertTrue(g.bossPart(19).up)
        XCTAssertEqual(dealt(19, 100), 25, accuracy: 0.01, "a node up on its trunk behind its plates: ×0.25")
        // exposed (P3): ×1.5 into its own 8 % pool; popped: dark, a scream, a 1.5 s stagger, ×0.25 after
        g.bugs.hp[h] = g.bugs.hpMax[h] * 0.32
        run(g, seconds: 1.5)
        XCTAssertEqual(g.boss.phase, 2)
        XCTAssertEqual(g.bossRT.bonus[20], 1)
        g.boss.untouchable = 0; g.boss.stagger = 0
        let pool = g.bossRT.poolMax[20]
        XCTAssertEqual(pool, 0.08 * g.bugs.hpMax[h], accuracy: 0.5)
        XCTAssertEqual(dealt(20, 100), 150, accuracy: 0.01, "an exposed node ×1.5")
        var popped = false, scream = false
        let left = g.bossRT.pool[20]
        _ = dealt(20, left / 1.5 + 1)
        g.drainEvents { e in
            if case .bossPartPopped(.threader, 20, _) = e { popped = true }
            if case .bossCue(.threader, .scream, _, 20) = e { scream = true }
        }
        XCTAssertTrue(popped && scream)
        XCTAssertTrue(g.bossPart(20).popped)
        XCTAssertEqual(g.boss.stagger, 1.5, accuracy: 0.02)
        XCTAssertEqual(dealt(20, 100), 25, accuracy: 0.01, "popped: ×0.25")
        XCTAssertEqual(g.threaderStats.popped, 1)
        // brittle ×1.5 (on an exposed node: ×1.5 × 1.5)
        g.bossBrittle(1)
        XCTAssertEqual(dealt(21, 100), 225, accuracy: 0.01)
        // an area hit counts once per source and tick: the part that took the most
        g.boss.brittle = 0
        g.tick()
        let p5 = g.bossPart(5).position
        let hp0 = S.hp[h]
        g.queueBoom(p5.x, p5.z, 6, 100, 0, .frag)
        g.processBooms()
        let one = hp0 - S.hp[h]
        XCTAssertGreaterThan(one, 0)
        XCTAssertLessThanOrEqual(one, 150 + 0.01, "no more than its best part's hit")
    }

    // ---------------------------------------------------------------- class counterplay

    func testClassCounterplay() {
        // the Cryo: a frozen part locks the body 2 s (the head stops), not again within 6 s of the lock's end
        let g = arena()
        runAside(g, seconds: 1)
        let q = slot(g, 4)
        g.bossPartFreeze(q, nova: false)
        XCTAssertEqual(g.boss.lock, 2, accuracy: 0.01)
        let p0 = g.bossPart(0).position
        runAside(g, seconds: 1)
        let p1 = g.bossPart(0).position
        XCTAssertEqual(hypotf(p1.x - p0.x, p1.z - p0.z), 0, accuracy: 0.01, "locked: it stands still")
        runAside(g, seconds: 1.2)
        g.bossRT.frozen[6] = 0
        g.bossPartFreeze(slot(g, 6), nova: false)
        XCTAssertEqual(g.boss.lock, 0, accuracy: 0.05, "too soon after the last lock")
        XCTAssertEqual(g.threaderStats.freezeLocks, 1)
        // the Cryo's Ice Wave on the head down: brittle 1.5 s (×1.5)
        let w = arena(seed: 11)
        runAside(w, seconds: 1)
        _ = lockTicks(w)
        XCTAssertTrue(runAside(w, seconds: 1.5, until: { w.threader.mode == .down }))
        w.bossPartFreeze(slot(w, 0), nova: true)
        XCTAssertEqual(w.boss.brittle, 1.5, accuracy: 0.01)
        // the Pyro's torch strips a node's frost plates: 1 s of flame on it, × 1.25 for the squad
        let t = arena(seed: 12, fight: true)
        let k = t.marines.firstIndex { $0.cls == .pyro }!
        t.debugHoldFire = true
        var node = -1
        var stripped = false
        for _ in 0..<240 {
            for j in 0..<4 where j != k { put(t, j, 28 + Float(j), 30) }
            node = 19
            let np = t.bossPart(node).position
            put(t, k, np.x + 3, np.z)
            t.marines[k].aim = atan2(-1, 0); t.marines[k].ax = -1; t.marines[k].az = 0
            t.marines[k].firing = true
            t.threaderTorch(SIM_DT)
            t.tick()
            t.drainEvents { e in if case .bossCue(.threader, .plateStrip, _, let p) = e { stripped = stripped || p == node } }
            if stripped { break }
        }
        XCTAssertTrue(stripped, "the torch strips its plates")
        XCTAssertEqual(t.bossRT.bonus[node], (t.bossPart(node).up && t.boss.phase < 2 ? THREADER_PLATED : 1) * 1.25, accuracy: 1e-4)
    }

    // ---------------------------------------------------------------- the bots

    func testBotsTargetsAndDodges() {
        let g = arena()
        runAside(g, seconds: 1)
        let gun = g.marines.first { $0.cls == .gunner && !$0.isPlayer } ?? g.marines[1]
        // up on the trunks — the head armoured, the nodes behind their plates — : no bot's pick (the turret's job)
        var bs: Float = 1e9
        for m in g.marines { bs = 1e9; XCTAssertEqual(g.threaderAITarget(m, 30, &bs), -1, "\(m.cls): nothing up there") }
        // the head down: everybody's first pick, once they have seen it land (BOT_REACT)
        _ = lockTicks(g)
        XCTAssertTrue(runAside(g, seconds: 1.5, until: { g.threader.mode == .down }))
        bs = 1e9
        XCTAssertEqual(g.threaderAITarget(g.marines[1], 30, &bs), -1, "not in the very first moment")
        runAside(g, seconds: BOT_REACT + 0.05)
        let head = slot(g, 0)
        for m in g.marines where !m.isPlayer {
            let hp = g.bugs.x[head], hz = g.bugs.z[head]
            put(g, m.index, hp + 4, hz)
            bs = 1e9
            XCTAssertEqual(g.threaderAITarget(m, 17, &bs), head, "\(m.cls): the head while it is down")
        }
        // the turret watches the nodes
        var bd: Float = 1e9
        g.turret = Turret(active: true, x: 3.5, z: -8, t: 10, angle: 0, cd: 0, owner: gun.index, think: 0, target: -1, tuid: 0, laser: 0)
        let tp = g.threaderTurretTarget(&bd)
        XCTAssertGreaterThanOrEqual(tp, 0)
        // its parts are no crowd for an ability
        let h = g.bossPart(0).position
        XCTAssertEqual(g.deckCrowd(h.x, h.z, 3), g.hash.queryCircle(g.bugs, h.x, h.z, 3) - (0..<g.hash.queryCircle(g.bugs, h.x, h.z, 3)).filter {
            g.bugs.bossPart(g.hash.qb[$0]) >= 0 }.count)
        // a bot steps out of the lure's light when it comes within 2 m
        let b = arena(seed: 13)
        runAside(b, seconds: 1)
        let bot = b.marines[2]
        put(b, 2, b.thr.lx + 1, b.thr.lz)
        bot.ai.sideT = 0
        b.threaderDodge(bot)
        XCTAssertGreaterThan(bot.ai.sideT, 0, "a sidestep")
        XCTAssertGreaterThan(bot.ai.sideX, 0.5, "away from the light")
    }

    // ---------------------------------------------------------------- the view, the mission, determinism

    func testTheRenderersView() {
        let g = arena()
        runAside(g, seconds: 1)
        let v = g.threader
        XCTAssertTrue(v.lure)
        XCTAssertEqual(v.lantern.y, g.bossPart(0).position.y - 0.9, accuracy: 1e-3, "the lantern hangs under the head")
        XCTAssertEqual(v.lureRadius, THREADER_LURE_R)
        XCTAssertEqual(v.locked, -1)
        XCTAssertEqual(v.strikeT, -1)
        XCTAssertFalse(v.coil); XCTAssertEqual(v.squeezeTrunk, -1); XCTAssertEqual(v.fallenTrunk, -1)
        XCTAssertFalse(v.inDuct)
        XCTAssertNil(g.threaderBurst(0))
        _ = lockTicks(g)
        runAside(g, seconds: 1.0 / 60)
        XCTAssertEqual(g.threader.locked, 0, "hot white: locked on the player")
        XCTAssertGreaterThan(g.threader.strikeT, 1)
        XCTAssertEqual(g.threader.lureSpot, g.threader.strike, "the beam on the strike's ring")
        XCTAssertTrue(g.bossTraceState.contains("mode=strike"))
    }

    func testManifoldOnAutopilot() {
        var c = GameConfig()
        c.levelSource = ManifoldStation(); c.mission = .manifold; c.difficulty = .recruit; c.autopilot = true; c.autoPickUpgrades = true
        let g = Game(seed: 21, playerClass: .assault, config: c)
        var steps: [MissionModule] = []
        var killed = false
        for _ in 0..<(8 * 60 * 60) {
            g.tick()
            g.drainEvents { e in
                if case .missionStep(_, let m) = e { steps.append(m) }
                if case .bossKilled(.threader, _) = e { killed = true }
            }
            if g.phase != .playing { break }
            XCTAssertFalse(g.player.x.isNaN || g.bugs.count > g.bugs.capacity)
        }
        XCTAssertEqual(g.phase, .won, "won on Recruit")
        XCTAssertTrue(killed)
        XCTAssertEqual(steps, [.boss, .extract])
        let r = g.runSummary(won: true, surrendered: false)
        XCTAssertEqual(r.bossKind, .threader)
        let sc = RunScore.make(r)
        XCTAssertTrue(sc.parts.contains { $0.label.id == .scoreThreader && $0.value == 1500 })
        XCTAssertTrue(sc.parts.contains { $0.label.id == .scorePumps })
        XCTAssertFalse(sc.parts.contains { $0.label.id == .scoreBeacons }, "no beacons line")
        XCTAssertEqual(r.strip?.map { $0.label.id }, [.reportStripPump, .reportStripPump, .reportStripThreader, .reportStripExtract])
    }

    func testThreaderIsDeterministic() {
        func play() -> String {
            var c = GameConfig()
            c.levelSource = ManifoldStation(); c.mission = .manifold; c.difficulty = .veteran; c.autopilot = true; c.autoPickUpgrades = true
            let g = Game(seed: 33, playerClass: .gunner, config: c)
            g.fastForward(seconds: 150)
            let s = g.threaderStats
            return "\(g.rng.state) \(g.time) \(g.boss.hpFraction) \(g.bossRT.headX) \(g.bossRT.headZ) \(s.locks) \(s.strikes) \(s.dmgHead) \(s.dmgNode) "
                + "\(g.bugs.count) \(g.kills) \(g.player.x) \(g.player.z)"
        }
        XCTAssertEqual(play(), play())
    }

    func testCalibrationPresets() {
        let b = Calibration.preset("bosses")!
        XCTAssertTrue(b.allSatisfy { $0.mission == "manifold" })
        XCTAssertEqual(b.count, 8 * 4 + 16 * 4 + 8 * 4 + 2 * 4, "8 / 16 / 8 runs per class, one AFK run per class on Veteran and Recruit")
        let m = Calibration.preset("missions")!
        XCTAssertFalse(m.contains { $0.mission == "manifold" }, "R7's missions preset keeps its rows")
        XCTAssertEqual(Set(m.compactMap { $0.mission }), ["breaker-run", "vent-purge"])
        let c = MissionTemplate.manifold.calib!
        XCTAssertTrue(c.gated); XCTAssertEqual(c.preset, "bosses")
        let vet = c.bands.first { $0.tier == 1 }!
        XCTAssertEqual([vet.bossReachedLo, vet.bossKilledLo, vet.bossMedianLo, vet.bossMedianHi], [75, 80, 60, 100])
        XCTAssertEqual(c.bands.first { $0.tier == 0 }!.winLo, 90)
        XCTAssertEqual(c.bands.first { $0.tier == 2 }!.winHi, 30)
        XCTAssertTrue(Calibration.presetNames.contains("bosses"))
        // a row of the Manifold carries the Threader's numbers; a classic row does not
        let r = Calibration.run(CalibRun(tag: "t", cls: .gunner, tier: 0, mode: .auto, maxs: 400, seed: 501, mission: "manifold"))
        XCTAssertNotNil(r.thr)
        XCTAssertTrue(r.json.contains("\"thr\":{\"p2T\":"))
        let back = CalibRow(json: r.json)?.thr
        XCTAssertEqual(back?.fields.map { $0.1 }, r.thr?.fields.map { $0.1 }, "its counts round-trip")
        XCTAssertEqual(back?.p2T ?? 0, r.thr?.p2T ?? 1, accuracy: 0.051)
        XCTAssertFalse(c.afkGated, "the AFK rows are reported beside the boss gate")
        XCTAssertTrue(MissionTemplate.breakerRun.calib!.afkGated, "R7's missions keep theirs")
    }
}
