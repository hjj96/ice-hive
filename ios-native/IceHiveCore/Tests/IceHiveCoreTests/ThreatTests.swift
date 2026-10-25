import XCTest
@testable import IceHiveCore

/// v1.1 «Ставки»: tier table (T1), one-shot fodder (T2), director tier rules (T3), hive pressure (T4), AFK (T5),
/// damage sources and downs (T7).
func tierGame(_ tier: Difficulty, seed: UInt32 = 1, cls: MarineClass = .assault, autopilot: Bool = false, god: Bool = false,
              configure: ((inout GameConfig) -> Void)? = nil) -> Game {
    var c = GameConfig()
    c.difficulty = tier
    c.autopilot = autopilot
    c.autoPickUpgrades = true
    c.god = god
    configure?(&c)
    return Game(seed: seed, playerClass: cls, config: c)
}

final class TuningTests: XCTestCase {
    func testTierRowsAreTheCalibratedWebRows() {
        let r = Difficulty.recruit, v = Difficulty.veteran, n = Difficulty.nightmare
        XCTAssertEqual([r.index, v.index, n.index], [0, 1, 2])
        XCTAssertEqual([r.id, v.id, n.id], ["rec", "vet", "nm"])
        XCTAssertEqual([r.name, v.name, n.name], ["Новобранец", "Ветеран", "Кошмар"])
        XCTAssertEqual(r.line, "Рой мягче, отряд сильнее — для первого знакомства")
        XCTAssertEqual(v.line, "Как задумано: падения случаются, Матка опасна")
        XCTAssertEqual(n.line, "Рой беспощаден, союзники слабее — Матку переживают единицы")
        func row(_ d: Difficulty) -> [Float] {
            [d.scoreMul, d.hp, d.dmg, d.trickle, d.horde, d.beaconHordeStep, d.specials, d.specialCap, d.botDamage / BOT_DMG, d.botGrow,
             d.regen, d.regenDelay, d.regenCap, d.beaconHeal, d.reviveHp, d.medkitChance, d.trickleMinDist, d.pulseDamage, d.pulseInterval,
             d.pulseFalloff, d.stallTime, d.pressureGrace, d.runnerHp,
             d.queen.at, d.queen.hp, d.queen.speed, d.queen.ramT, d.queen.volleyT, d.queen.broodT, Float(d.queen.broodN), d.queen.horde, d.queen.trickle]
        }
        let want: [[Float]] = [
            [0.8, 1.0, 0.9, 1.09, 1.07, 50, 1, 1, 1.0, 1.04, 4, 3.5, 1, 0.25, 0.45, 0.35, 12, 1.0, 5, 0, 90, 40, 15,
             35, 2500, 1.5, 9, 6, 8, 6, 80, 0.4],
            // calibrated: trickle 1.25, revive 0.45
            [1.0, 1.10, 1.20, 1.25, 1.12, 30, 1.15, 1.2, 0.85, 1.025, 4, 4, 0.6, 0.20, 0.45, 0.35, 11, 1.0, 6, 0.5, 60, 25, 15,
             35, 3500, 1.5, 9, 6, 8, 6, 80, 0.4],
            // calibrated: trickle 1.2, qHp 6000
            [1.5, 1.15, 1.25, 1.20, 1.17, 40, 1.25, 1.3, 0.80, 1.02, 3, 5, 0.5, 0.15, 0.35, 0.25, 10, 0.8, 7, 0.6, 40, 15, 15,
             30, 6000, 1.6, 8, 5, 7, 8, 150, 0.6],
        ]
        for (k, d) in [r, v, n].enumerated() {
            let got = row(d)
            for (i, x) in want[k].enumerated() { XCTAssertEqual(got[i], x, accuracy: 1e-5, "tier \(k) field \(i)") }
        }
        XCTAssertEqual(Difficulty.tiers.map { $0.id }, ["rec", "vet", "nm"])
        XCTAssertEqual(Difficulty.tier(-3).id, "rec")
        XCTAssertEqual(Difficulty.tier(1).id, "vet")
        XCTAssertEqual(Difficulty.tier(9).id, "nm")
        XCTAssertEqual(GameConfig().difficulty.id, "vet")
        XCTAssertEqual(BUG_SPECS[0].hp, 15)
        XCTAssertEqual(SRC_QUEEN, DamageSource.queen.rawValue)
    }

    func testOverrideByWebNames() {
        var d = Difficulty.veteran
        let unknown = d.override(["trickle": 1.3, "qHp": 4200, "revive": 0.5, "bot": 0.8, "qBroodN": 10, "grace": 30, "nope": 1])
        XCTAssertEqual(unknown, ["nope"])
        XCTAssertEqual(d.trickle, 1.3, accuracy: 1e-6)
        XCTAssertEqual(d.queen.hp, 4200)
        XCTAssertEqual(d.reviveHp, 0.5, accuracy: 1e-6)
        XCTAssertEqual(d.botDamage, BOT_DMG * 0.8, accuracy: 1e-6)
        XCTAssertEqual(d.queen.broodN, 10)
        XCTAssertEqual(d.pressureGrace, 30)
        XCTAssertEqual(d.id, "vet")
        // every documented key is known
        var e = Difficulty.recruit
        XCTAssertEqual(e.override(Dictionary(uniqueKeysWithValues: Difficulty.overrideKeys.map { ($0, 1.0) })), [])
    }
}

final class FodderTests: XCTestCase {
    func runnerHps(_ g: Game, _ n: Int) -> (Float, Float) {
        var lo: Float = 1e9, hi: Float = 0
        let P = g.player
        for k in 0..<n {
            let i = g.spawnBug(T_RUN, P.x + Float(k % 20) * 0.3 - 3, P.z - 4)
            lo = min(lo, g.bugs.hpMax[i]); hi = max(hi, g.bugs.hpMax[i])
        }
        return (lo, hi)
    }

    func testRunnersAreOneShotOnEveryTier() {
        for tier in Difficulty.tiers {
            for t: Float in [0, 110] {
                let g = tierGame(tier, seed: 3)
                g.directorEnabled = true
                g.time = t
                g.tick()   // hpMul follows the mission time
                XCTAssertGreaterThan(g.hpMul, tier.hp * 0.99)
                let (lo, hi) = runnerHps(g, 200)
                XCTAssertGreaterThanOrEqual(lo, 13.2 - 1e-3, "\(tier.id) t=\(t)")
                XCTAssertLessThanOrEqual(hi, 16.8 + 1e-3, "\(tier.id) t=\(t)")
                // the assault bolt (17) kills every runner
                XCTAssertLessThan(hi, CLASS_SPECS[0].dmg)
                // the other types scale with hpMul
                let P = g.player
                let b = g.spawnBug(T_BRUTE, P.x - 6, P.z)
                XCTAssertEqual(g.bugs.hpMax[b], 360 * g.hpMul, accuracy: 0.01)
                let s = g.spawnBug(T_SPIT, P.x - 7, P.z)
                XCTAssertEqual(g.bugs.hpMax[s] / (44 * g.hpMul), 1, accuracy: 0.13)
                let o = g.spawnBug(T_BOOM, P.x - 8, P.z)
                XCTAssertEqual(g.bugs.hpMax[o] / (55 * g.hpMul), 1, accuracy: 0.13)
            }
        }
    }

    func testLegacyRowScalesRunnersLikeV10() {
        let g = tierGame(.legacyV10, seed: 4)
        g.time = 110; g.tick()
        let (lo, hi) = runnerHps(g, 200)
        XCTAssertGreaterThan(hi, 18 * g.hpMul * 1.05)
        XCTAssertGreaterThanOrEqual(lo, 18 * g.hpMul * 0.88 - 1e-3)
    }

    func testBenchKeepsImmortalRunners() {
        let g = tierGame(.veteran, seed: 5)
        let res = g.benchmark(counts: [200], warmupTicks: 2, measureTicks: 2)
        XCTAssertEqual(res.count, 1)
        // inside the bench (simOnly, hpMul 1e5) a runner gets 15 × 1e5 × k
        g.simOnly = true; g.hpMul = 1e5
        let i = g.spawnBug(T_RUN, g.player.x - 4, g.player.z)
        XCTAssertGreaterThan(g.bugs.hpMax[i], 1e6)
        g.simOnly = false
    }
}

final class DirectorTierTests: XCTestCase {
    func hordeSizes(_ g: Game, ticks: Int = 1) -> [Int] {
        var out: [Int] = []
        for _ in 0..<ticks {
            g.tick()
            g.drainEvents { if case .hordeStarted(let n, _, _) = $0 { out.append(n) } }
        }
        return out
    }

    func testBeaconHordeAndWaves() {
        for tier in Difficulty.tiers {
            let g = tierGame(tier, seed: 14, god: true)
            g.clearEvents()
            let b = g.beacons[0]
            g.debugTeleport(b.x + 2.5, b.z)
            let sizes = hordeSizes(g)
            let first = Int((Float(270) * g.hordeScale()).rounded())
            XCTAssertEqual(sizes, [Int((Float(first) * tier.horde).rounded())], tier.id)
            XCTAssertEqual(g.activeBeacon, 0)
            // a wave 2 s later: vent bursts of round((38 + 8·done)·hs·horde)
            g.waveT = 0
            g.queue.removeAll()
            g.tick()
            let ventN = g.queue.filter { $0.vent != nil }.map { $0.n }
            let edgeN = g.queue.filter { $0.vent == nil && $0.edge >= 0 }.map { $0.n }
            if !ventN.isEmpty { XCTAssertEqual(ventN, [Int((38 * g.hordeScale() * tier.horde).rounded())], tier.id) }
            else { XCTAssertEqual(edgeN, [Int((30 * g.hordeScale() * tier.horde).rounded())], tier.id) }
        }
    }

    func testCoachedFirstBeaconHordeIsSmallerOnce() {
        let g = tierGame(.recruit, seed: 14, god: true) { $0.coach = true }
        XCTAssertEqual(g.beaconHordeMul, 0.65)
        g.clearEvents()
        let b = g.beacons[0]
        g.debugTeleport(b.x + 2.5, b.z)
        let sizes = hordeSizes(g)
        let first = Int((270 * g.hordeScale() * Float(0.65)).rounded())
        XCTAssertEqual(sizes, [Int((Float(first) * Difficulty.recruit.horde).rounded())])
        XCTAssertEqual(g.beaconHordeMul, 1)
    }

    func testTrickleFactorAndAttract() {
        let g = tierGame(.veteran, seed: 2, god: true)
        g.trickle = 0
        g.tick()
        let minutes = g.time / 60
        XCTAssertEqual(g.trickle, (1.8 + 0.5 * minutes) * 1.25 * SIM_DT, accuracy: 1e-5)
        var c = GameConfig(); c.attract = true
        let a = Game(seed: 2, playerClass: .assault, config: c)
        a.trickle = 0
        a.tick()
        let m2 = a.time / 60
        XCTAssertEqual(a.trickle, (1.8 + 0.5 * m2) * 1.5 * 3 * SIM_DT, accuracy: 1e-5, "attract uses 3 (no tier)")
    }

    func testSpecialCapIsAFloatCompare() {
        let g = tierGame(.veteran, seed: 2)
        XCTAssertEqual(g.specialCapFor(T_BRUTE), 12 * 1.2, accuracy: 1e-5)
        XCTAssertEqual(g.specialCapFor(T_SPIT), 30 * 1.2, accuracy: 1e-5)
        g.beaconsDone = 2
        XCTAssertEqual(g.specialCapFor(T_BRUTE), 16 * 1.2, accuracy: 1e-5)
        XCTAssertEqual(tierGame(.legacyV10).specialCapFor(T_BOOM), 18)
    }

    func testStallClockUnlocksBrutes() {
        func brutes(_ g: Game, _ t: Float) -> Int {
            g.time = t
            var n = 0
            for _ in 0..<20000 {
                g.typeAlive = [0, 0, 0, 0]
                if g.pickType(false) == T_BRUTE { n += 1 }
            }
            return n
        }
        let g = tierGame(.veteran, seed: 9)
        XCTAssertEqual(brutes(g, 59), 0)
        XCTAssertGreaterThan(brutes(g, 61), 50)
        XCTAssertEqual(brutes(tierGame(.recruit, seed: 9), 89), 0)
        XCTAssertGreaterThan(brutes(tierGame(.recruit, seed: 9), 91), 50)
        XCTAssertEqual(brutes(tierGame(.legacyV10, seed: 9), 900), 0)
        var c = GameConfig(); c.attract = true; c.difficulty = .veteran
        XCTAssertEqual(brutes(Game(seed: 9, playerClass: .assault, config: c), 300), 0, "never in attract")
    }

    func testHealReviveRegenAndBots() {
        let n = tierGame(.nightmare, seed: 8)
        let m = n.marines[2]
        n.hurtMarine(m, 500, 0, 0)
        for _ in 0..<(60 * 10) where m.downed { n.tick() }
        XCTAssertFalse(m.downed)
        XCTAssertEqual(m.hp, m.maxHp * 0.35, accuracy: 1)
        XCTAssertEqual(n.marines[1].mods.dmg, BOT_DMG * 0.8, accuracy: 1e-6)
        // regen stops at regenCap (Ветеран 60 %)
        let g = tierGame(.veteran, seed: 8)
        g.directorEnabled = false
        let P = g.player
        P.hp = 30; P.calm = 10
        g.step(60 * 20)
        XCTAssertEqual(P.hp, 60, accuracy: 0.1)
        // beacon heal 20 %
        g.marines[1].hp = 50
        g.debugSkip()
        XCTAssertEqual(g.marines[1].hp, 50 + g.marines[1].maxHp * 0.2, accuracy: 0.01)
    }

    func testLiftPulseIntervalGuardAndFalloff() {
        let g = tierGame(.veteran, seed: 11, god: true)
        g.debugSkip(); g.debugSkip(); g.debugSkip(); g.debugSkip()
        XCTAssertEqual(g.stage, .hold)
        g.clearEvents()
        var pulses: [Float] = []
        for _ in 0..<(60 * 20) {
            g.tick()
            g.drainEvents { if case .explosion(.pulse, _, _) = $0 { pulses.append(g.time) } }
        }
        XCTAssertGreaterThanOrEqual(pulses.count, 3)
        for k in 1..<pulses.count { XCTAssertEqual(pulses[k] - pulses[k - 1], 6, accuracy: 0.05) }
        // falloff: full damage at the centre, half at the rim (Ветеран 0.5)
        let h = tierGame(.veteran, seed: 12)
        h.directorEnabled = false
        let L = h.level.lift
        let a = h.spawnBug(T_BRUTE, L.x, L.z), b = h.spawnBug(T_BRUTE, L.x + (L.r + 0.6) * 0.999, L.z)
        h.bugs.hp[a] = 1000; h.bugs.hp[b] = 1000
        h.hash.rebuild(h.bugs)
        h.queueBoom(L.x, L.z, L.r + 0.6, 100, -1, .pulse)
        h.processBooms()
        XCTAssertEqual(1000 - h.bugs.hp[a], 100, accuracy: 0.1)
        XCTAssertEqual(1000 - h.bugs.hp[b], 50, accuracy: 0.2)
        // guard: a tier without a pulse never queues one
        var d = Difficulty.veteran; d.pulseDamage = 0
        let q = tierGame(d, seed: 11, god: true)
        q.debugSkip(); q.debugSkip(); q.debugSkip(); q.debugSkip()
        q.clearEvents()
        var any = false
        for _ in 0..<(60 * 12) { q.tick(); q.drainEvents { if case .explosion(.pulse, _, _) = $0 { any = true } } }
        XCTAssertFalse(any)
    }
}

final class PressureTests: XCTestCase {
    func idle(_ tier: Difficulty, seconds: Float, _ g: Game? = nil) -> Game {
        let g = g ?? tierGame(tier, seed: 21, god: true)
        g.setPlayerInput(move: Vec2(0, 0), aim: nil, fire: false, ability: false, dash: false)
        let n = Int((seconds - g.time) * 60)
        if n > 0 { g.step(n) }
        return g
    }

    func testVeteranIdleEscalation() {
        let g = idle(.veteran, seconds: 14)
        XCTAssertEqual(g.threatState, .calm)
        XCTAssertEqual(g.objectiveText, "Запустите маяки 0/3")
        _ = idle(.veteran, seconds: 15.5, g)
        XCTAssertEqual(g.threatState, .waking)
        XCTAssertEqual(g.objectiveStyle, .waking)
        XCTAssertEqual(g.objectiveText, "Улей просыпается — к маяку")
        XCTAssertEqual(g.objectiveProgress, g.pressure / 25, accuracy: 1e-4)
        XCTAssertFalse(g.markerUrgent)
        _ = idle(.veteran, seconds: 25.5, g)
        XCTAssertEqual(g.threatState, .converging)
        XCTAssertEqual(g.objectiveText, "Рой стягивается — к маяку!")
        XCTAssertTrue(g.markerUrgent)
        XCTAssertEqual(g.objectiveProgress, 1)
        XCTAssertFalse(g.huntPressure)
        _ = idle(.veteran, seconds: 36, g)
        XCTAssertTrue(g.huntPressure, "even uids hunt from idleMul 1.5 (press ≥ grace + 10)")
        // heartbeat every 1.2 s of game time while converging
        g.clearEvents()
        var beats: [Float] = []
        for _ in 0..<(60 * 6) { g.tick(); g.drainEvents { if case .sound(.heart, nil, _) = $0 { beats.append(g.time) } } }
        XCTAssertTrue((4...5).contains(beats.count), "\(beats.count) beats")
        for k in 1..<beats.count { XCTAssertEqual(beats[k] - beats[k - 1], 1.2, accuracy: 0.02) }
        _ = idle(.veteran, seconds: 45, g)
        XCTAssertEqual(g.idleMul, 2.0, accuracy: 0.01)
        // a started beacon clears the state; the pressure decays 3/s
        let p0 = g.pressure
        let b = g.beacons[g.nextBeacon()]
        g.debugTeleport(b.x + 2.5, b.z)
        g.step(60)
        XCTAssertGreaterThanOrEqual(g.activeBeacon, 0)
        XCTAssertEqual(g.threatState, .calm)
        XCTAssertEqual(g.pressure, p0 - 3 * 1, accuracy: 0.2)
    }

    func testThresholdsPerTier() {
        for (tier, amber, red) in [(Difficulty.recruit, Float(30), Float(40)), (.nightmare, 5, 15)] {
            let g = idle(tier, seconds: amber - 0.5)
            XCTAssertEqual(g.threatState, .calm, tier.id)
            _ = idle(tier, seconds: amber + 0.5, g)
            XCTAssertEqual(g.threatState, .waking, tier.id)
            _ = idle(tier, seconds: red + 0.5, g)
            XCTAssertEqual(g.threatState, .converging, tier.id)
        }
        // the legacy row has no pressure
        let l = idle(.legacyV10, seconds: 60)
        XCTAssertEqual(l.threatState, .calm)
        XCTAssertEqual(l.idleMul, 1)
    }

    func testToLiftTextsAndAttract() {
        let g = tierGame(.veteran, seed: 23, god: true)
        g.debugSkip(); g.debugSkip(); g.debugSkip()
        XCTAssertEqual(g.stage, .toLift)
        XCTAssertEqual(g.objectiveText, "Лифт вызван — к платформе")
        g.debugSetPressure(16)
        XCTAssertEqual(g.objectiveText, "Улей просыпается — к лифту!")
        g.debugSetPressure(26)
        XCTAssertEqual(g.objectiveText, "Рой стягивается — к лифту!")
        var c = GameConfig(); c.attract = true
        let a = Game(seed: 3, playerClass: .assault, config: c)
        a.step(60 * 40)
        XCTAssertEqual(a.pressure, 0)
        XCTAssertEqual(a.threatState, .calm)
    }

    func testWalkToTheLiftHasATravelAllowance() {
        // a squad walking straight from the third beacon to the lift never wakes the hive on Ветеран
        for seed: UInt32 in [23, 24, 25] {
            let g = tierGame(.veteran, seed: seed, autopilot: true, god: true)
            g.debugSkip(); g.debugSkip(); g.debugSkip()
            XCTAssertEqual(g.stage, .toLift)
            var worst = ThreatState.calm, n = 0
            while g.stage == .toLift && n < 60 * 120 {
                g.tick(); n += 1
                if g.threatState.rawValue > worst.rawValue { worst = g.threatState }
            }
            XCTAssertEqual(g.stage, .hold, "seed \(seed): the autopilot reaches the lift")
            XCTAssertEqual(worst, .calm, "seed \(seed): walk \(Float(n) / 60) s")
            XCTAssertEqual(g.idleMul, 1)
        }
        // dawdling past the allowance still wakes it: amber 15 s after the allowance, as on the beacons stage
        let h = tierGame(.veteran, seed: 23, god: true)
        h.debugSkip(); h.debugSkip(); h.debugSkip()
        h.setPlayerInput(move: Vec2(0, 0), aim: nil, fire: false, ability: false, dash: false)
        h.step(30)
        let a = h.liftAllowance
        let L = h.level.lift, P = h.player
        XCTAssertGreaterThan(a, hypotf2(L.x - P.x, L.z - P.z) / 5.3 * 1.3 + 4, "path ≥ the straight line")
        XCTAssertEqual(h.pressure, 0)
        h.step(Int((a + 14) * 60))
        XCTAssertEqual(h.threatState, .calm)
        XCTAssertEqual(h.pressure, 14, accuracy: 0.1)
        h.step(120)
        XCTAssertEqual(h.threatState, .waking)
        XCTAssertEqual(h.objectiveText, "Улей просыпается — к лифту!")
        // the allowance is measured again on every mission (resetDirector)
        h.resetWorld()
        XCTAssertEqual(h.liftAllowance, -1)
    }

    func testCalmFreezesPressure() {
        let g = tierGame(.recruit, seed: 24, god: true) { $0.coach = true }
        g.step(60 * 6)
        XCTAssertTrue(g.calm)
        XCTAssertEqual(g.pressure, 0)
    }
}

final class AfkTests: XCTestCase {
    func testAfkClock() {
        let g = tierGame(.veteran, seed: 31, god: true)
        g.setPlayerInput(move: Vec2(0, 0), aim: nil, fire: false, ability: false, dash: false)
        g.step(60 * 5)
        XCTAssertEqual(g.afkTime, 5, accuracy: 0.05)
        g.setPlayerInput(move: Vec2(1, 0), aim: nil, fire: false, ability: false, dash: false)
        g.tick()
        XCTAssertEqual(g.afkTime, 0)
        g.setPlayerInput(move: Vec2(0, 0), aim: nil, fire: true, ability: false, dash: false)
        g.step(30)
        XCTAssertEqual(g.afkTime, 0)
        g.setPlayerInput(move: Vec2(0, 0), aim: nil, fire: false, ability: false, dash: false)
        g.step(30)
        XCTAssertGreaterThan(g.afkTime, 0.4)
        g.setPlayerInput(move: Vec2(0, 0), aim: nil, fire: false, ability: true, dash: false)
        g.tick()
        XCTAssertEqual(g.afkTime, 0, "ability press")
        g.setPlayerInput(move: Vec2(0, 0), aim: nil, fire: false, ability: false, dash: false)
        g.step(30)
        g.setPlayerInput(move: Vec2(0, 0), aim: nil, fire: false, ability: false, dash: true)
        g.tick()
        XCTAssertEqual(g.afkTime, 0, "dash press")
        g.setPlayerInput(move: Vec2(0, 0), aim: nil, fire: false, ability: false, dash: false)
        g.step(60 * 13)
        XCTAssertTrue(g.huntAfk)
        let a = tierGame(.veteran, seed: 31, autopilot: true, god: true)
        a.step(60 * 15)
        XCTAssertEqual(a.afkTime, 0, "the autopilot never counts")
        XCTAssertFalse(a.huntAfk)
    }

    func testHuntersPickThePlayer() {
        // bugs 4.5 m east of the player, a bot 3 m north of them: hunters (uid % 3 != 0 while AFK) turn west to the
        // player, the rest go north to the closer bot
        let g = tierGame(.veteran, seed: 32, god: true)
        g.directorEnabled = false
        let P = g.player
        P.x = 0; P.z = -5; P.px = P.x; P.pz = P.z
        let b = g.marines[1]
        b.x = 4.5; b.z = -2; b.px = b.x; b.pz = b.z
        for k in 2..<4 { g.marines[k].x = 40; g.marines[k].z = 30 }
        var ids: [Int] = []
        for k in 0..<12 { ids.append(g.spawnBug(T_RUN, 4.5 + Float(k % 4) * 0.3, -5 + Float(k / 4) * 0.3 - 0.3)) }
        g.huntAfk = true
        g.updateFlows()
        g.step(8)
        var hw = 0, hn = 0, ow = 0, on = 0
        for i in ids where g.bugs.dead[i] == 0 {
            let west = g.bugs.vx[i] < -0.3, north = g.bugs.vz[i] > 0.3
            if g.bugs.uid[i] % 3 != 0 { hn += 1; if west { hw += 1 } } else { on += 1; if north { ow += 1 } }
        }
        XCTAssertGreaterThan(hn, 4)
        XCTAssertGreaterThan(on, 1)
        XCTAssertGreaterThan(Float(hw), Float(hn) * 0.7, "hunters head for the player")
        XCTAssertGreaterThan(Float(ow), Float(on) * 0.5, "the others take the nearest marine")
    }
}

final class DamageSourceTests: XCTestCase {
    func testLastHitPerSource() {
        let g = tierGame(.veteran, seed: 41)
        g.directorEnabled = false
        let P = g.player
        for src in [DamageSource.runner, .spitter, .brute, .boomer, .queen] {
            P.inv = 0; P.dashT = 0
            g.hurtMarine(P, 1, 0, 0, src)
            XCTAssertEqual(g.lastHit, src)
        }
        // bots never touch the player's lastHit
        g.hurtMarine(g.marines[1], 1, 0, 0, .runner)
        XCTAssertEqual(g.lastHit, .queen)
        XCTAssertEqual(g.hurtBy[DamageSource.runner.rawValue + 1], 2, accuracy: 1e-5)
        // downs count only the player
        g.hurtMarine(g.marines[2], 999, 0, 0, .spitter)
        XCTAssertEqual(g.downs, 0)
        XCTAssertEqual(g.squadDownBy[DamageSource.spitter.rawValue + 1], 1)
        P.inv = 0
        g.hurtMarine(P, 999, 0, 0, .boomer)
        XCTAssertEqual(g.downs, 1)
        XCTAssertEqual(g.downBy, .boomer)
        XCTAssertEqual(g.squadDownBy.reduce(0, +), 2)
    }

    func testSourcesFromTheSwarm() {
        func firstHit(_ type: UInt8, dx: Float, dz: Float, seconds: Float = 6) -> DamageSource? {
            let g = tierGame(.veteran, seed: 42)
            g.directorEnabled = false
            for m in g.marines where !m.isPlayer { m.x += 30; m.px = m.x }
            let P = g.player
            g.spawnBug(type, P.x + dx, P.z + dz)
            for _ in 0..<Int(seconds * 60) {
                g.tick()
                if g.lastHit != .environment { return g.lastHit }
                P.hp = P.maxHp
            }
            return nil
        }
        XCTAssertEqual(firstHit(T_RUN, dx: -1, dz: 0), .runner)
        XCTAssertEqual(firstHit(T_SPIT, dx: -7, dz: 0), .spitter)
        XCTAssertEqual(firstHit(T_BRUTE, dx: -6, dz: 0), .brute)
        XCTAssertEqual(firstHit(T_BOOM, dx: -1.5, dz: 0), .boomer)
    }
}
