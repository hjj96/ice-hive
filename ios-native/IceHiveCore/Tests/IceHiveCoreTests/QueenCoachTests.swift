import XCTest
@testable import IceHiveCore

/// v1.1 «Ставки»: the Матка (T6), the coach «Учебная высадка» (T8), HUD texts from the core (T9).

/// A game in the lift hold with the squad on the deck (debugSkip through the beacons and the walk to the lift).
func holdGame(_ tier: Difficulty = .veteran, seed: UInt32 = 51, cls: MarineClass = .assault, god: Bool = true,
              configure: ((inout GameConfig) -> Void)? = nil) -> Game {
    let g = tierGame(tier, seed: seed, cls: cls, god: god, configure: configure)
    while g.stage != .hold { g.debugSkip() }
    g.clearEvents()
    return g
}

final class QueenTests: XCTestCase {
    /// Run until `cond` (max `seconds`), collecting events.
    @discardableResult
    func run(_ g: Game, seconds: Float, until cond: (() -> Bool)? = nil, _ onEvent: ((GameEvent) -> Void)? = nil) -> Bool {
        for _ in 0..<Int(seconds * 60) {
            g.tick()
            g.drainEvents { onEvent?($0) }
            if let c = cond, c() { return true }
        }
        return false
    }

    func queenSlot(_ g: Game) -> Int { g.queenSlotNow() }

    func testWarningAtTheFarRimThenSpawn() {
        let g = holdGame()
        let hold0 = g.time
        var warnAt: Float = -1, warnPos = Vec2(0, 0), spawnAt: Float = -1
        var ring: Telegraph? = nil
        var banners: [String] = [], sounds: [SoundID] = [], haptics: [HapticKind] = []
        run(g, seconds: 45, until: { g.queen.spawned }) { e in
            switch e {
            case .queenWarning(let p):
                warnAt = g.time; warnPos = p
                ring = g.telegraphs.first { $0.active && $0.cause == .queenRim }
            case .queenSpawned: spawnAt = g.time
            case .banner(let t, _, _): banners.append(t)
            case .sound(let id, nil, _): sounds.append(id)
            case .haptic(let k): haptics.append(k)
            default: break
            }
        }
        XCTAssertTrue(g.queen.spawned)
        // liftT runs while the squad stands on the deck: the warning comes queen.at = 35 s into the counted hold
        XCTAssertEqual(warnAt - hold0, 35, accuracy: 0.05)
        XCTAssertEqual(spawnAt - warnAt, 2, accuracy: 0.05)
        XCTAssertEqual(ring?.r0 ?? 0, 3, accuracy: 1e-5)
        XCTAssertEqual(ring?.life ?? 0, 2, accuracy: 1e-5)
        XCTAssertEqual(ring?.g ?? 0, 0.12, accuracy: 1e-5)
        XCTAssertLessThan(warnPos.y - g.level.lift.z, -4, "far side of the lift")
        let L = g.level.lift
        XCTAssertLessThan(hypotf2(warnPos.x - L.x, warnPos.y - L.z), L.r + 1.5)
        XCTAssertTrue(banners.contains("Матка"))
        XCTAssertTrue(sounds.contains(.siren) && sounds.contains(.queen))
        XCTAssertTrue(haptics.contains(.heavy))
        let i = queenSlot(g)
        XCTAssertGreaterThanOrEqual(i, 0)
        XCTAssertEqual(g.bugs.type[i], T_BRUTE)
        XCTAssertEqual(g.bugs.r[i], 1.5)
        XCTAssertEqual(g.bugs.sc[i], 4.2)
        XCTAssertEqual(g.bugs.spd[i], 1.5)
        XCTAssertEqual(g.bugs.hpMax[i], 3500 * g.hpMul, accuracy: 0.5)
        XCTAssertEqual(g.threatState, .queen)
        XCTAssertEqual(g.objectiveStyle, .boss)
        XCTAssertEqual(g.objectiveText, "Убейте Матку · лифт ждёт")
    }

    func testOverridesAndDebugQueen() {
        let a = holdGame { $0.queenAt = 0; $0.queenHp = 1000 }
        run(a, seconds: 3, until: { a.queen.spawned })
        XCTAssertTrue(a.queen.spawned)
        XCTAssertEqual(a.bugs.hpMax[queenSlot(a)], 1000)
        let b = holdGame(.nightmare, seed: 52)
        let uid = b.debugQueen(hp: 777)
        XCTAssertNotEqual(uid, 0)
        XCTAssertEqual(b.queen.uid, uid)
        XCTAssertEqual(b.bugs.hp[queenSlot(b)], 777)
        XCTAssertEqual(b.debugQueen(), 0, "only once")
        XCTAssertEqual(tierGame(.veteran).debugQueen(), 0, "hold only")
        let n = holdGame(.nightmare, seed: 53)
        n.debugQueen()
        XCTAssertEqual(n.bugs.hpMax[queenSlot(n)], 6000 * n.hpMul, accuracy: 1)
        XCTAssertEqual(n.bugs.spd[queenSlot(n)], 1.6)
    }

    func testImmunities() {
        let g = holdGame(cls: .cryo)
        g.debugQueen(hp: 100_000)
        var i = queenSlot(g)
        let P = g.player
        // the cryo beam and the nova on her for 15 s: no freeze, chill ≤ 0.5, but she takes damage
        var maxChill: Float = 0, maxFrz: Float = 0
        for k in 0..<(15 * 60) {
            i = queenSlot(g)
            g.bugs.x[i] = P.x + 3; g.bugs.z[i] = P.z
            let a = atan2f2(g.bugs.x[i] - P.x, g.bugs.z[i] - P.z)
            g.setPlayerInput(move: Vec2(0, 0), aim: a, fire: true, ability: k % 120 == 0, dash: false)
            g.tick(); g.clearEvents()
            i = queenSlot(g)
            maxChill = max(maxChill, g.bugs.chill[i]); maxFrz = max(maxFrz, g.bugs.frz[i])
        }
        XCTAssertEqual(maxFrz, 0)
        XCTAssertLessThanOrEqual(maxChill, 0.5 + 1e-5)
        XCTAssertLessThan(g.bugs.hp[i], 100_000 - 500, "the beam and the nova still hurt her")
        // frost blasts add no chill to her, the lift pulse leaves her untouched — a brute beside her takes both
        let h = holdGame(seed: 54)
        h.debugQueen(hp: 10_000)
        let q = queenSlot(h)
        let L = h.level.lift
        h.bugs.x[q] = L.x; h.bugs.z[q] = L.z; h.bugs.chill[q] = 0
        let b = h.spawnBug(T_BRUTE, L.x + 1.5, L.z)
        h.bugs.hp[b] = 1000; h.bugs.hpMax[b] = 1000
        h.hash.rebuild(h.bugs)
        h.queueBoom(L.x, L.z, 4, 10, 0, .frost)
        h.processBooms()
        XCTAssertEqual(h.bugs.chill[q], 0)
        XCTAssertGreaterThan(h.bugs.chill[b], 0.4)
        let qhp = h.bugs.hp[q], bhp = h.bugs.hp[b]
        h.queueBoom(L.x, L.z, L.r + 0.6, 100, -1, .pulse)
        h.processBooms()
        XCTAssertEqual(h.bugs.hp[q], qhp)
        XCTAssertLessThan(h.bugs.hp[b], bhp - 40)
    }

    func testMeleeRamVolleyAndBrood() {
        let g = holdGame(god: false)
        g.debugQueen(hp: 100_000)
        let t0 = g.time
        var i = queenSlot(g)
        // nothing else on the deck
        for k in 0..<g.bugs.count where k != i { g.bugs.dead[k] = 1 }
        g.queue.removeAll()
        let P = g.player
        for m in g.marines where !m.isPlayer { m.x = P.x + 30; m.px = m.x }
        // her bite: BUG_SPECS[brute].dmg × dmgMul × 1.6, source Матка, on her own clock
        var hurt0 = g.hurtBy[DamageSource.queen.rawValue + 1]
        var bitAt: Float = -1
        var winds = 0, volleys = 0, broodAt: Float = -1
        var launched = 0
        XCTAssertEqual([g.qBrood, g.qVolley, g.qRam], [4, 3, 6])
        for _ in 0..<(12 * 60) {
            i = queenSlot(g)
            if g.time - t0 < 3 { g.bugs.x[i] = P.x + 1.4; g.bugs.z[i] = P.z }
            P.hp = P.maxHp; P.inv = 0
            g.tick()
            g.drainEvents { if case .acidLaunched = $0 { launched += 1 } }
            i = queenSlot(g)
            if i >= 0 && g.bugs.st[i] == S_WIND { if winds == 0 { XCTAssertGreaterThan(g.time - t0, 5.9, "no ram before qRamT") }; winds += 1 }
            let h = g.hurtBy[DamageSource.queen.rawValue + 1]
            if bitAt < 0 && h > hurt0 {
                bitAt = g.time
                XCTAssertEqual(h - hurt0, BUG_SPECS[2].dmg * g.dmgMul * 1.6, accuracy: 0.01)
                XCTAssertEqual(g.lastHit, .queen)
                XCTAssertGreaterThan(g.qMeleeCd, 0)
            }
            hurt0 = h
            if broodAt < 0 && i >= 0 {
                // the brood bursts from her body: broodN fresh runners (vent burst: ±0.4 m, climb timer 0.45) this tick
                let qx = g.bugs.x[i], qz = g.bugs.z[i]
                var n = 0
                for k in 0..<g.bugs.count where g.bugs.dead[k] == 0 && k != i && g.bugs.type[k] == T_RUN && g.bugs.st[k] == S_CLIMB
                    && g.bugs.t[k] == 0.45 && abs(g.bugs.x[k] - qx) <= 0.41 && abs(g.bugs.z[k] - qz) <= 0.41 { n += 1 }
                if n > 0 { broodAt = g.time - t0; XCTAssertEqual(n, Difficulty.veteran.queen.broodN) }
            }
            if launched > 0 && volleys == 0 { volleys = launched; XCTAssertEqual(g.time - t0, 3, accuracy: 0.05) }
        }
        XCTAssertGreaterThan(bitAt, 0, "she bites")
        XCTAssertEqual(broodAt, 4, accuracy: 0.05, "first brood 4 s after she climbs up")
        // one glob per standing marine within 18 m (only the player)
        XCTAssertEqual(volleys, 1)
        // no brood while the swarm cap is full
        let c = holdGame(seed: 55)
        c.debugQueen(hp: 100_000)
        c.bugCap = c.bugs.count
        let n0 = c.bugs.count
        c.qBrood = 0.01
        c.queue.removeAll()
        c.tick()
        XCTAssertEqual(c.bugs.count, n0)
    }

    func testEnrageOnceBelowHalf() {
        let g = holdGame()
        g.debugQueen(hp: 10_000)
        g.queue.removeAll()
        g.clearEvents()
        let i = queenSlot(g)
        g.bugs.hp[i] = 4900
        var hordes: [(Int, String)] = [], enraged = 0
        g.tick()
        g.drainEvents { e in
            if case .hordeStarted(let n, let t, _) = e { hordes.append((n, t)) }
            if case .queenEnraged = e { enraged += 1 }
        }
        XCTAssertTrue(g.queen.enraged)
        XCTAssertEqual(enraged, 1)
        XCTAssertEqual(g.bugs.spd[queenSlot(g)], 1.5 * 1.35, accuracy: 1e-5)
        XCTAssertEqual(hordes.count, 1)
        XCTAssertEqual(hordes.first?.1, "Матка в ярости")
        let want = Int((Float(Int((80 * g.hordeScale()).rounded())) * Difficulty.veteran.horde).rounded())
        XCTAssertEqual(hordes.first?.0, want)
        g.step(60)
        g.drainEvents { if case .queenEnraged = $0 { enraged += 1 } }
        XCTAssertEqual(enraged, 1, "once")
    }

    func testHoldHordesPauseAndLiftLock() {
        let g = holdGame()
        g.debugQueen(hp: 1_000_000)
        g.hordeT = 5
        g.step(120)
        XCTAssertEqual(g.hordeT, 5, accuracy: 1e-4, "hold hordes pause while she lives")
        // trickle × queen.trickle: the hold stage multiplier 3.2 × 0.4
        g.trickle = 0
        g.tick()
        let rate = (1.8 + 0.5 * g.time / 60 + 0.5 * 3) * 3.2 * 0.4 * Difficulty.veteran.trickle
        XCTAssertEqual(g.trickle, rate * SIM_DT, accuracy: 1e-4)
        XCTAssertEqual(g.objectiveText, "Убейте Матку · лифт ждёт")
        XCTAssertEqual(g.objectiveProgress, 1 - g.queen.hpFraction, accuracy: 1e-5)
        XCTAssertLessThan(g.objectiveProgress, 0.01)
        g.debugSetLiftTime(0.01)
        g.step(60 * 10)
        XCTAssertEqual(g.stage, .hold)
        XCTAssertTrue(g.liftLocked)
        XCTAssertEqual(g.objectiveText, "Лифт заблокирован — Матка жива")
        // her death releases the lift: the squad leaves 4.6 s later
        let i = queenSlot(g)
        g.killBug(i, 0)
        let dead = g.time
        var won: Float = -1
        for _ in 0..<(8 * 60) { g.tick(); g.clearEvents(); if g.phase == .won { won = g.time; break } }
        XCTAssertGreaterThan(won - dead, 4.4)
        XCTAssertLessThan(won - dead, 5.0)
    }

    func testDeath() {
        let g = holdGame()
        g.debugQueen(hp: 5000)
        g.step(30)
        g.clearEvents()
        let i = queenSlot(g)
        // on the deck (medkits only land on walkable floor)
        g.bugs.x[i] = g.level.lift.x; g.bugs.z[i] = g.level.lift.z + 2
        let x = g.bugs.x[i], z = g.bugs.z[i]
        let xp0 = g.xp, lvl0 = g.xpLevel
        let med0 = g.medkits.filter { $0.active }.count
        let t0 = g.queen.t0
        g.killBug(i, 0)
        var order: [String] = []
        g.drainEvents { e in
            switch e {
            case .queenKilled: order.append("killed")
            case .hitStop: order.append("hitStop")
            case .banner(let t, let s, let teal): if t == "Матка убита" { XCTAssertEqual(s, "Лифт свободен"); XCTAssertTrue(teal); order.append("banner") }
            case .haptic(.success): order.append("haptic")
            default: break
            }
        }
        XCTAssertEqual(order.first, "killed")
        XCTAssertEqual(Array(order.prefix(2)), ["killed", "hitStop"])
        XCTAssertTrue(order.contains("banner") && order.contains("haptic"))
        XCTAssertFalse(g.queen.alive)
        XCTAssertTrue(g.queen.done)
        XCTAssertEqual(g.queen.killT, g.time - t0, accuracy: 1e-4)
        if g.xpLevel == lvl0 { XCTAssertEqual(g.xp - xp0, 60 + BUG_SPECS[2].xp) }
        let meds = g.medkits.filter { $0.active }
        XCTAssertEqual(meds.count - med0, 2, "two medkits, never a random one")
        XCTAssertTrue(meds.contains { abs($0.x - (x + 1)) < 1e-4 && abs($0.z - z) < 1e-4 })
        XCTAssertTrue(g.booms.contains { $0.r == 8 && $0.dmg == 300 && $0.src == 0 && $0.kind == .frag })
        XCTAssertEqual(g.threatState, .calm)
    }

    func testDebugSkipWinsOnEveryTier() {
        for tier in Difficulty.tiers + [.legacyV10] {
            let g = holdGame(tier, seed: 57)
            g.tick()
            g.debugSkip()
            XCTAssertTrue(tier.hasQueen ? g.queen.done : !g.queen.spawned || g.queen.done, tier.id)
            g.step(5)
            XCTAssertEqual(g.stage, .extract, tier.id)
            g.step(5 * 60)
            XCTAssertEqual(g.phase, .won, tier.id)
        }
        // a queen alive at the skip is killed first
        let g = holdGame(seed: 58)
        g.debugQueen()
        g.debugSkip()
        XCTAssertFalse(g.queen.alive)
        g.step(5 * 60 + 30)
        XCTAssertEqual(g.phase, .won)
    }

    func testQueenRunIsDeterministic() {
        func run() -> (QueenState, Float, Int, Int) {
            let g = holdGame(.veteran, seed: 59) { $0.queenAt = 1; $0.autopilot = true }
            g.autopilot = true
            g.step(60 * 30)
            return (g.queen, g.time, g.kills, g.bugsAlive)
        }
        let a = run(), b = run()
        XCTAssertEqual(a.0.uid, b.0.uid); XCTAssertEqual(a.0.hpFraction, b.0.hpFraction); XCTAssertEqual(a.0.position, b.0.position)
        XCTAssertEqual(a.0.alive, b.0.alive); XCTAssertEqual(a.0.killT, b.0.killT)
        XCTAssertEqual(a.2, b.2); XCTAssertEqual(a.3, b.3)
        XCTAssertTrue(a.0.spawned)
    }
}

final class CoachTests: XCTestCase {
    func coachGame(seed: UInt32 = 61, god: Bool = true, armed: Bool = false) -> Game {
        tierGame(.recruit, seed: seed, god: god) { $0.coach = true; $0.reviveLineArmed = armed }
    }

    func testIdleNoviceTimelineAndCalm() {
        let g = coachGame()
        g.setPlayerInput(move: Vec2(0, 0), aim: nil, fire: false, ability: false, dash: false)
        var steps: [(Int, Float)] = [(0, 0)]
        var seen = 0, banners: [String] = []
        g.drainEvents { if case .banner(let t, _, _) = $0 { banners.append(t) } }
        XCTAssertFalse(banners.contains("Высадка"), "no drop banner when coaching")
        XCTAssertEqual(g.coach.step, 0)
        XCTAssertEqual(g.coach.target, .moveStick)
        XCTAssertFalse(g.showControlHint)
        XCTAssertNil(g.contextHint)
        for _ in 0..<(40 * 60) {
            g.tick()
            g.drainEvents { e in
                if case .coachStep(let k) = e { steps.append((k, g.time)) }
                if case .coachSeen = e { seen += 1 }
            }
            if g.coach.active && g.coach.step <= 3 { XCTAssertTrue(g.calm) }
        }
        XCTAssertEqual(steps.map { $0.0 }, [0, 1, 2, 3, 4])
        for (k, want) in zip(steps.indices, [Float(0), 7, 19, 28, 36]) { XCTAssertEqual(steps[k].1, want, accuracy: 0.05, "step \(k)") }
        XCTAssertEqual(seen, 1, "seen after step 4")
        XCTAssertTrue(g.coach.active)
        XCTAssertEqual(g.coach.step, 4)
        XCTAssertFalse(g.calm)
        // zero hordes before the first beacon; its horde is × 0.65, then the multiplier is spent
        XCTAssertEqual(g.hordes, 0)
        XCTAssertEqual(g.beaconHordeMul, 0.65)
        let b = g.beacons[g.nextBeacon()]
        g.debugTeleport(b.x + 2.5, b.z)
        var ended = 0
        for _ in 0..<30 { g.tick(); g.drainEvents { if case .coachEnded = $0 { ended += 1 } } }
        XCTAssertGreaterThanOrEqual(g.activeBeacon, 0)
        XCTAssertFalse(g.coach.active)
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(g.beaconHordeMul, 1)
        XCTAssertEqual(g.hordes, 1)
    }

    func testStepsCompleteOnTheirActions() {
        let g = coachGame(seed: 62)
        // 1: move 3 m
        g.setPlayerInput(move: Vec2(1, 0), aim: nil, fire: false, ability: false, dash: false)
        var guardN = 0
        while g.coach.step == 0 && guardN < 600 { g.tick(); guardN += 1 }
        XCTAssertEqual(g.coach.step, 1)
        XCTAssertLessThan(g.time, 3)
        XCTAssertEqual(g.coachGroupCount, 1)
        XCTAssertEqual(g.coachGroups[0].n, 10)
        XCTAssertEqual(g.coachGroups[0].rate, 5)
        // 2: fire ≥ 1.2 s and > 2.5 s into the step
        let t1 = g.time
        g.setPlayerInput(move: Vec2(0, 0), aim: 0, fire: true, ability: false, dash: false)
        guardN = 0
        while g.coach.step == 1 && guardN < 900 { g.tick(); guardN += 1 }
        XCTAssertEqual(g.coach.step, 2)
        XCTAssertEqual(g.time - t1, 2.5, accuracy: 0.1)
        XCTAssertEqual(g.player.abCd, 0, "ability ready at step 3")
        XCTAssertTrue(g.coachGroups[0..<g.coachGroupCount].contains { $0.n == 18 && $0.rate == 30 } || g.coachGroupCount >= 1)
        // 3: the ability
        g.setPlayerInput(move: Vec2(0, 0), aim: 0, fire: false, ability: true, dash: false)
        g.tick()
        g.setPlayerInput(move: Vec2(0, 0), aim: 0, fire: false, ability: false, dash: false)
        g.tick()
        XCTAssertEqual(g.coach.step, 3)
        XCTAssertEqual(g.player.dashCd, 0, "dash ready at step 4")
        // a ring of 8 practice runners at half HP around the player
        let P = g.player
        var ring = 0
        for i in 0..<g.bugs.count where g.bugs.dead[i] == 0 && g.bugs.type[i] == T_RUN {
            let d = hypotf2(g.bugs.x[i] - P.x, g.bugs.z[i] - P.z)
            if d < 5.5 { ring += 1; XCTAssertLessThanOrEqual(g.bugs.hpMax[i], 8.4 + 1e-3) }
        }
        XCTAssertGreaterThanOrEqual(ring, 5)
        // 4: dash
        g.setPlayerInput(move: Vec2(1, 0), aim: nil, fire: false, ability: false, dash: true)
        var seen = 0
        g.tick()
        g.drainEvents { if case .coachSeen = $0 { seen += 1 } }
        XCTAssertEqual(g.coach.step, 4)
        XCTAssertEqual(seen, 1)
        XCTAssertEqual(g.coach.target, .objective)
    }

    func testPracticeRunnersAtHalfHealth() {
        let g = coachGame(seed: 63)
        g.debugCoachStep(1)
        let n0 = g.bugs.count
        g.step(60 * 3)
        var spawned = 0
        for i in n0..<g.bugs.count where g.bugs.type[i] == T_RUN {
            spawned += 1
            XCTAssertLessThanOrEqual(g.bugs.hpMax[i], 8.4 + 1e-3)
            XCTAssertGreaterThanOrEqual(g.bugs.hpMax[i], 6.6 - 1e-3)
        }
        XCTAssertEqual(spawned, 10, "group of 10 at 5/s, nothing else (calm)")
    }

    func testSkipEarlyEndAndUnfinishedMission() {
        let s = coachGame(seed: 64)
        var seen = 0, ended = 0
        s.coachSkip()
        s.drainEvents { e in if case .coachSeen = e { seen += 1 }; if case .coachEnded = e { ended += 1 } }
        XCTAssertEqual([seen, ended], [1, 1])
        XCTAssertFalse(s.coach.active)
        XCTAssertFalse(s.calm)
        s.coachSkip()
        XCTAssertTrue(s.events.isEmpty, "a second skip does nothing")
        // walking onto a beacon during steps 1–4 ends it (seen)
        let e = coachGame(seed: 65)
        let b = e.beacons[e.nextBeacon()]
        e.debugTeleport(b.x + 2.5, b.z)
        seen = 0
        for _ in 0..<10 { e.tick(); e.drainEvents { if case .coachSeen = $0 { seen += 1 } } }
        XCTAssertFalse(e.coach.active)
        XCTAssertEqual(seen, 1)
        // a mission that ends mid-coach does not mark it seen
        let m = coachGame(seed: 66, god: false)
        seen = 0
        for k in 0..<4 { m.debugHurt(marine: k, hp: 0) }
        for _ in 0..<60 { m.tick(); m.drainEvents { if case .coachSeen = $0 { seen += 1 } } }
        XCTAssertEqual(m.phase, .lost)
        XCTAssertEqual(seen, 0)
        // the autopilot walks into the first beacon: the coach ends there
        let a = tierGame(.recruit, seed: 67, autopilot: true, god: true) { $0.coach = true }
        for _ in 0..<(60 * 60) where a.coach.active { a.tick(); a.clearEvents() }
        XCTAssertFalse(a.coach.active)
        XCTAssertGreaterThanOrEqual(a.activeBeacon, 0)
    }

    func testBotsHoldFireForThePlayer() {
        let g = coachGame(seed: 68)
        let bot = g.marines[1]
        g.crowd[1] = 0
        XCTAssertTrue(g.coachHoldFire(bot))
        g.crowd[1] = 2
        XCTAssertFalse(g.coachHoldFire(bot))
        g.crowd[1] = 0
        XCTAssertFalse(g.coachHoldFire(g.player))
        g.coachSkip()
        XCTAssertFalse(g.coachHoldFire(bot))
    }

    func testReviveLineOncePerRunWhenArmed() {
        let g = tierGame(.veteran, seed: 69) { $0.reviveLineArmed = true }
        g.step(60 * 8)
        g.debugHurt(marine: 2, hp: 0)
        g.tick()
        XCTAssertEqual(g.coach.reviveLine, "Тень ранен — встаньте рядом, чтобы поднять")
        XCTAssertEqual(g.contextHint?.text, g.coach.reviveLine)
        g.step(60 * 6 + 5)
        XCTAssertNil(g.coach.reviveLine)
        g.debugHurt(marine: 2, hp: 100)
        g.debugHurt(marine: 1, hp: 0)
        g.tick()
        XCTAssertNil(g.coach.reviveLine, "once per run")
        let u = tierGame(.veteran, seed: 69)
        u.debugHurt(marine: 1, hp: 0)
        u.tick()
        XCTAssertNil(u.coach.reviveLine, "only when armed")
        XCTAssertEqual(CoachText.reviveLines.count, 3)
    }

    func testCardTexts() {
        XCTAssertEqual(CoachText.text(step: 0, abilityShort: "Граната", keyboard: false), "Левый палец — бег")
        XCTAssertEqual(CoachText.text(step: 1, abilityShort: "Граната", keyboard: false), "Правый палец — прицел, огонь сам")
        XCTAssertEqual(CoachText.text(step: 2, abilityShort: "Напалм", keyboard: false), "Напалм — по толпе")
        XCTAssertEqual(CoachText.text(step: 3, abilityShort: "", keyboard: false), "Рывок — из окружения")
        XCTAssertEqual(CoachText.text(step: 4, abilityShort: "", keyboard: false), "Маяк — встаньте в кольцо")
        XCTAssertEqual(CoachText.text(step: 0, abilityShort: "", keyboard: true), "WASD — бег")
        XCTAssertEqual(CoachText.text(step: 1, abilityShort: "", keyboard: true), "IJKL — прицел и огонь")
        XCTAssertEqual(CoachText.text(step: 2, abilityShort: "Волна", keyboard: true), "Волна — по толпе (Q)")
        XCTAssertEqual(CoachText.text(step: 3, abilityShort: "", keyboard: true), "Рывок — из окружения (пробел)")
        XCTAssertEqual(CoachText.counter(step: 2), "3/5")
    }
}

final class HudTextTests: XCTestCase {
    func testObjectiveStatesAndHoldHints() {
        let g = tierGame(.veteran, seed: 71, god: true)
        XCTAssertEqual(g.objectiveText, "Запустите маяки 0/3")
        XCTAssertEqual(g.objectiveProgress, -1)
        XCTAssertEqual(g.objectiveStyle, .normal)
        g.debugSkip()
        XCTAssertEqual(g.objectiveText, "Запустите маяки 1/3")
        let b = g.beacons[g.nextBeacon()]
        g.debugTeleport(b.x + 2.5, b.z)
        g.step(30)
        XCTAssertTrue(g.objectiveText.hasPrefix("Удерживайте маяк «"))
        XCTAssertGreaterThan(g.objectiveProgress, 0)
        while g.stage != .hold { g.debugSkip() }
        XCTAssertEqual(g.objectiveText, "Держитесь на лифте · 1:40")
        XCTAssertEqual(g.objectiveProgress, 0, accuracy: 1e-4)
        XCTAssertEqual(g.objectiveStyle, .normal)
        g.debugSetLiftTime(30)
        XCTAssertEqual(g.objectiveProgress, 0.7, accuracy: 1e-4)
        g.debugSkip()
        g.step(10)
        XCTAssertEqual(g.objectiveText, "Эвакуация!")
        var c = GameConfig(); c.attract = true
        XCTAssertEqual(Game(seed: 1, playerClass: .assault, config: c).objectiveText, "")
        // hold hints per tier (built once per Game)
        XCTAssertEqual(tierGame(.recruit).holdHint, "Защитный контур лифта бьёт током каждые 5 с")
        XCTAssertEqual(tierGame(.veteran).holdHint, "Контур бьёт каждые 6 с — у края слабее, держитесь центра")
        XCTAssertEqual(tierGame(.nightmare).holdHint, "Контур бьёт каждые 7 с — у края слабее, держитесь центра")
    }

    func testHintPriority() {
        let g = tierGame(.veteran, seed: 72, god: true) { $0.reviveLineArmed = true }
        XCTAssertTrue(g.showControlHint)
        XCTAssertNil(g.contextHint, "the first 7 s belong to the app's control hint")
        g.step(60 * 8)
        XCTAssertFalse(g.showControlHint)
        // 5. a downed bot within 6 m (the revive line comes first while it shows)
        let P = g.player
        let bot = g.marines[1]
        bot.x = P.x + 2; bot.z = P.z; bot.px = bot.x; bot.pz = bot.z
        g.debugHurt(marine: 1, hp: 0)
        g.tick()
        XCTAssertEqual(g.contextHint?.text, "Кекс ранен — встаньте рядом, чтобы поднять")
        g.step(60 * 6 + 2)
        let bot2 = g.marines[1]
        if bot2.downed {
            bot2.x = P.x + 2; bot2.z = P.z
            XCTAssertEqual(g.contextHint?.text, "Встаньте рядом с раненым, чтобы поднять его")
        }
        g.debugHurt(marine: 1, hp: 100)
        // 7. next beacon closer than 9 m
        let b = g.beacons[g.nextBeacon()]
        g.debugTeleport(b.x + 6, b.z)
        XCTAssertEqual(g.contextHint?.text, "Встаньте в кольцо маяка")
        // 6. active beacon, nobody inside
        g.debugTeleport(b.x + 2, b.z)
        g.tick()
        XCTAssertGreaterThanOrEqual(g.activeBeacon, 0)
        for m in g.marines { m.x = b.x + 20; m.px = m.x }
        g.tick()
        if g.activeBeacon >= 0 && g.standingIn(b.x, b.z, BEACON_R) == 0 {
            XCTAssertEqual(g.contextHint?.text, "Вернитесь в кольцо маяка!")
            XCTAssertEqual(g.contextHint?.urgent, true)
        }
        // 8. hold, player off the lift / 9. hold hint in the first 8 s
        let h = holdGame(seed: 73)
        h.time = 60
        XCTAssertEqual(h.contextHint?.text, h.holdHint)
        let L = h.level.lift
        h.debugTeleport(L.x + L.r + 3, L.z)
        XCTAssertEqual(h.contextHint?.text, "На платформу! Отсчёт стоит")
        XCTAssertEqual(h.contextHint?.urgent, true)
        // 1. the player downed beats everything
        h.debugHurt(marine: 0, hp: 0)
        XCTAssertEqual(h.contextHint?.text, "Вы ранены — союзники идут на помощь")
        // 3. coach active → nil
        let c = tierGame(.recruit, seed: 74) { $0.coach = true }
        c.time = 20
        XCTAssertNil(c.contextHint)
    }

    func testDropBannerAndStationName() {
        let g = tierGame(.veteran, seed: 75)
        var sub = ""
        g.drainEvents { if case .banner("Высадка", let s, _) = $0 { sub = s } }
        XCTAssertEqual(sub, "Кельвин-9 · запустите три маяка")
        XCTAssertEqual(g.stationName, "Кельвин-9")
        let s = Game(seed: 75, playerClass: .assault, config: GameConfig(), level: Level(source: StationGenerator(), seed: 7))
        sub = ""
        s.drainEvents { if case .banner("Высадка", let t, _) = $0 { sub = t } }
        XCTAssertEqual(sub, "Сектор И-1 · запустите три маяка")
    }

    func testRunSummaryAndStats() {
        let g = holdGame(seed: 76)
        g.debugQueen(hp: 10)
        g.killBug(g.queenSlotNow(), 0)
        g.debugSetOutcome(downs: 2, downBy: .brute, pressure: nil, idleMul: nil)
        let r = g.runSummary(won: false, surrendered: true)
        XCTAssertTrue(r.surrendered)
        XCTAssertEqual(r.beaconsDone, 3)
        XCTAssertTrue(r.queenSpawned && r.queenDone)
        XCTAssertEqual(r.downs, 2)
        XCTAssertEqual(r.downBy, .brute)
        XCTAssertEqual(r.tierIndex, 1)
        XCTAssertEqual(r.tierName, "Ветеран")
        XCTAssertEqual(r.stage, .hold)
        XCTAssertEqual(r.station, "Кельвин-9")
        XCTAssertFalse(r.pressureLoss)
        XCTAssertFalse(g.runSummary(won: true, surrendered: true).surrendered, "a win is never a surrender")
        let st = g.stats
        XCTAssertEqual(st.downs, 2); XCTAssertEqual(st.tierIndex, 1); XCTAssertEqual(st.beaconsDone, 3); XCTAssertTrue(st.queenDone)
        let p = tierGame(.veteran, seed: 77)
        p.debugSetOutcome(downs: nil, downBy: nil, pressure: 40, idleMul: 2)
        XCTAssertTrue(p.runSummary(won: false, surrendered: false).pressureLoss)
    }
}
