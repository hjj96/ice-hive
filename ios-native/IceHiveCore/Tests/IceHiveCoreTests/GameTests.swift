import XCTest
@testable import IceHiveCore

final class GameTests: XCTestCase {
    func autopilotConfig() -> GameConfig {
        var c = GameConfig(); c.autopilot = true; c.autoPickUpgrades = true
        return c
    }

    func fingerprint(_ g: Game) -> [Float] {
        var f: [Float] = [g.time, Float(g.kills), Float(g.bugs.count), Float(g.xpLevel)]
        for m in g.marines { f += [m.x, m.z, m.hp, m.aim] }
        for i in stride(from: 0, to: g.bugs.count, by: 13) { f += [g.bugs.x[i], g.bugs.z[i], g.bugs.hp[i]] }
        return f
    }

    func testSameSeedSameRun() {
        let a = Game(seed: 1234, playerClass: .pyro, config: autopilotConfig())
        let b = Game(seed: 1234, playerClass: .pyro, config: autopilotConfig())
        a.step(60 * 25); b.step(60 * 25)
        XCTAssertEqual(fingerprint(a), fingerprint(b))
        XCTAssertGreaterThan(a.kills, 0)
        let c = Game(seed: 999, playerClass: .pyro, config: autopilotConfig())
        c.step(60 * 25)
        XCTAssertNotEqual(fingerprint(a), fingerprint(c))
    }

    func testEventsDoNotAffectTheSimulation() {
        let a = Game(seed: 4321, playerClass: .gunner, config: autopilotConfig())
        let b = Game(seed: 4321, playerClass: .gunner, config: autopilotConfig())
        var n = 0
        for _ in 0..<(60 * 20) {
            a.tick(); b.tick()
            a.drainEvents { _ in n += 1 }     // b never drains
            _ = a.laserLength(a.player); _ = a.bugCountNear(a.player.position); _ = a.objectiveText; _ = a.contextHint
        }
        XCTAssertGreaterThan(n, 100)
        XCTAssertEqual(fingerprint(a), fingerprint(b))
    }

    func testSquadSetup() {
        let g = Game(seed: 1, playerClass: .cryo)
        XCTAssertEqual(g.marines.count, 4)
        XCTAssertEqual(g.player.cls, .cryo)
        XCTAssertEqual(g.player.name, "ВЫ")
        XCTAssertEqual(g.marines.map { $0.cls }, [.cryo, .assault, .pyro, .gunner])
        XCTAssertEqual(g.marines[1].name, "Кекс")
        XCTAssertEqual(g.marines[1].maxHp, 120)
        XCTAssertEqual(g.marines[1].mods.dmg, BOT_DMG)
        XCTAssertEqual(g.player.mods.dmg, 1)
        XCTAssertEqual(g.objectiveText, "Запустите маяки 0/3")
        XCTAssertEqual(g.stage, .beacons)
        XCTAssertEqual(g.bugCap, 1400)
        var drained: [GameEvent] = []
        g.drainEvents { drained.append($0) }
        XCTAssertTrue(drained.contains { if case .banner(let t, _, _) = $0 { return t == "Высадка" }; return false })
        XCTAssertTrue(g.events.isEmpty)
    }

    func testPlayerInputMovesAndShoots() {
        let g = Game(seed: 3, playerClass: .assault)
        let p0 = g.player.position
        // move "up the screen" (world -x,-z) and shoot along it
        let dir = Game.worldFromScreen(0, -1)
        g.setPlayerInput(move: dir, aim: Game.angle(of: dir), fire: true, ability: false, dash: false)
        g.step(60)
        let p1 = g.player.position
        XCTAssertLessThan(p1.x, p0.x - 2)
        XCTAssertLessThan(p1.y, p0.y - 2)
        XCTAssertGreaterThan(g.shots, 5)
        XCTAssertLessThan(g.player.ammo, 40)
        var muzzles = 0
        g.drainEvents { if case .muzzle(0) = $0 { muzzles += 1 } }
        XCTAssertGreaterThan(muzzles, 5)
        // dash is a one-shot press with a cooldown
        g.setPlayerInput(move: dir, aim: nil, fire: false, ability: false, dash: true)
        g.tick()
        XCTAssertTrue(g.player.dashing)
        XCTAssertGreaterThan(g.player.dashCd, 2.5)
        // the player cannot walk off the platform
        g.setPlayerInput(move: Vec2(1, 0), aim: nil, fire: false, ability: false, dash: false)
        g.step(600)
        XCTAssertTrue(g.level.walkable(g.player.x, g.player.z))
        XCTAssertLessThan(g.player.x, 38)
    }

    func testGrenadeExplodesAndKills() {
        let g = Game(seed: 5, playerClass: .assault)
        let P = g.player
        let target = Vec2(P.x - 6, P.z - 6)
        for k in 0..<12 { g.spawnBug(T_RUN, target.x + Float(k % 4) * 0.5 - 1, target.y + Float(k / 4) * 0.5 - 0.5) }
        g.tick()
        g.clearEvents()
        g.setPlayerInput(move: Vec2(0, 0), aim: nil, fire: false, ability: true, dash: false, abilityTarget: target)
        var explosions = 0, killed = 0
        for _ in 0..<70 {
            g.tick()
            g.drainEvents { e in
                switch e {
                case .explosion(let kind, _, _): if kind == .frag { explosions += 1 }
                case .bugKilled: killed += 1
                default: break
                }
            }
        }
        XCTAssertEqual(explosions, 1)
        XCTAssertGreaterThanOrEqual(killed, 10)
        XCTAssertGreaterThan(g.player.abCd, 5)
        XCTAssertGreaterThanOrEqual(g.kills, 10)
    }

    func testAbilitiesOfEveryClass() {
        for cls in MarineClass.allCases {
            let g = Game(seed: 11, playerClass: cls)
            g.debugSpawn(60, type: .runner, minRadius: 2, maxRadius: 6)
            g.tick()
            g.clearEvents()
            g.setPlayerInput(move: Vec2(0, 0), aim: nil, fire: true, ability: true, dash: false)
            var ability: AbilityKind? = nil
            for _ in 0..<120 {
                g.tick()
                g.drainEvents { if case .ability(0, let k, _, _) = $0 { ability = k } }
            }
            XCTAssertNotNil(ability, "\(cls)")
            XCTAssertGreaterThan(g.kills, 5, "\(cls) killed \(g.kills)")
            switch cls {
            case .assault: XCTAssertEqual(ability, .grenade)
            case .pyro: XCTAssertEqual(ability, .napalm)
            case .cryo: XCTAssertEqual(ability, .nova)
            case .gunner: XCTAssertEqual(ability, .turret); XCTAssertTrue(g.turret.active)
            }
            XCTAssertFalse(g.hasNonFinite())
        }
    }

    func testSpecialBugsBehave() {
        // a brute winds up and charges (lane telegraph), a spitter lobs acid, a boomer swells and explodes
        let g = Game(seed: 21, playerClass: .assault)
        g.godMode = true
        g.directorEnabled = false
        let P = g.player
        g.spawnBug(T_BRUTE, P.x - 6, P.z)
        g.spawnBug(T_SPIT, P.x, P.z - 7)
        g.spawnBug(T_BOOM, P.x - 1.5, P.z - 1.5)
        var lane = false, acid = false, boom = false
        for _ in 0..<(60 * 8) {
            g.tick()
            g.drainEvents { e in
                switch e {
                case .telegraph(_, _, let cause, _): if cause == .bruteLane { lane = true }
                case .acidLaunched: acid = true
                case .explosion(let kind, _, _): if kind == .boomer { boom = true }
                default: break
                }
            }
        }
        XCTAssertTrue(lane, "brute never charged")
        XCTAssertTrue(acid, "spitter never spat")
        XCTAssertTrue(boom, "boomer never exploded")
    }

    func testDamageDownAndRevive() {
        let g = Game(seed: 8, playerClass: .gunner)
        let m = g.marines[2]
        g.hurtMarine(m, 500, 0, 0)
        XCTAssertTrue(m.downed)
        var revived = false
        // the bots come and revive their squadmate
        for _ in 0..<(60 * 10) {
            g.tick()
            g.drainEvents { if case .revived(2) = $0 { revived = true } }
            if revived { break }
        }
        XCTAssertTrue(revived)
        XCTAssertFalse(m.downed)
        XCTAssertEqual(m.hp, m.maxHp * 0.45, accuracy: 1)
    }

    func testDefeatWhenAllDown() {
        let g = Game(seed: 9, playerClass: .assault)
        for m in g.marines { g.hurtMarine(m, 1000, 0, 0) }
        g.tick()
        XCTAssertEqual(g.phase, .lost)
        var defeat = false
        g.drainEvents { if case .defeat = $0 { defeat = true } }
        XCTAssertTrue(defeat)
        let t = g.tickCount
        g.tick()
        XCTAssertEqual(g.tickCount, t, "a finished game does not tick")
    }

    func testSkipThroughStagesToVictory() {
        let g = Game(seed: 10, playerClass: .pyro)
        g.godMode = true
        XCTAssertEqual(g.debugSkip(), .beacons)
        XCTAssertEqual(g.beaconsDone, 1)
        g.debugSkip(); g.debugSkip()
        XCTAssertEqual(g.stage, .toLift)
        XCTAssertEqual(g.objectiveText, "Лифт вызван — к платформе")
        g.debugSkip()
        XCTAssertEqual(g.stage, .hold)
        XCTAssertTrue(g.objectiveText.hasPrefix("Держитесь на лифте · 1:40"))
        g.tick()
        g.debugSkip()
        g.step(5)
        XCTAssertEqual(g.stage, .extract)
        g.step(5 * 60)
        XCTAssertEqual(g.phase, .won)
        XCTAssertGreaterThan(g.stats.time, 0)
    }

    func testLevelUpFlow() {
        let g = Game(seed: 12, playerClass: .assault)
        g.debugLevelUp()
        XCTAssertTrue(g.wantsLevelUp)
        let offer = g.rollUpgrades()
        XCTAssertEqual(offer.count, 3)
        XCTAssertEqual(Set(offer.map { $0.id }).count, 3)
        for u in offer { XCTAssertTrue(u.classes == nil || u.classes!.contains(.assault)) }
        let dmg0 = g.marines[1].mods.dmg, hp0 = g.marines[1].maxHp
        let picked = g.chooseUpgrade(0)
        XCTAssertNotNil(picked)
        XCTAssertFalse(g.wantsLevelUp)
        XCTAssertEqual(g.upgradeCounts[picked!.id], 1)
        XCTAssertEqual(g.marines[1].mods.dmg, dmg0 * 1.04, accuracy: 1e-5)
        XCTAssertEqual(g.marines[1].maxHp, hp0 + 3)
        // XP from kills levels up
        let g2 = Game(seed: 13, playerClass: .assault)
        for _ in 0..<40 { g2.onBugKilled(T_RUN, 0, 0, 0) }
        XCTAssertEqual(g2.xpLevel, 2)
        XCTAssertEqual(g2.pendingLevels, 1)
        XCTAssertEqual(g2.combo, 40)
    }

    func testBeaconChargesWithMarineInside() {
        let g = Game(seed: 14, playerClass: .assault)
        g.godMode = true
        let b = g.beacons[0]
        g.debugTeleport(b.x + 2.5, b.z)
        g.tick()
        XCTAssertEqual(g.activeBeacon, 0)
        XCTAssertEqual(g.beacons[0].state, 1)
        XCTAssertGreaterThan(g.hordes, 0)
        g.step(120)
        XCTAssertGreaterThan(g.beacons[0].progress, 0.005)
        XCTAssertTrue(g.objectiveText.contains("Альфа"))
        XCTAssertGreaterThan(g.objectiveProgress, 0)
    }

    func testAttractModeRunsForever() {
        var cfg = GameConfig(); cfg.attract = true
        let g = Game(seed: 15, playerClass: .assault, config: cfg)
        XCTAssertGreaterThan(g.bugs.count, 100)
        g.step(60 * 30)
        XCTAssertEqual(g.phase, .playing)
        XCTAssertEqual(g.objectiveText, "")
        XCTAssertEqual(g.stage, .beacons)
        XCTAssertFalse(g.hasNonFinite())
        XCTAssertEqual(g.xpLevel, 1)
        XCTAssertGreaterThan(g.kills, 30)
    }

    func testStandardDifficultyIsV1() {
        let d = Difficulty.standard
        XCTAssertEqual(d.hp, 1); XCTAssertEqual(d.dmg, 1); XCTAssertEqual(d.trickle, 1); XCTAssertEqual(d.horde, 1)
        XCTAssertEqual(d.beaconHordeStep, 50); XCTAssertEqual(d.botDamage, 0.6); XCTAssertEqual(d.botGrow, 1.04)
        XCTAssertEqual(d.regen, 4); XCTAssertEqual(d.regenDelay, 3.5); XCTAssertEqual(d.regenCap, 1)
        XCTAssertEqual(d.beaconHeal, 0.25); XCTAssertEqual(d.reviveHp, 0.45); XCTAssertEqual(d.medkitChance, 0.35)
        XCTAssertEqual(d.trickleMinDist, 12); XCTAssertEqual(d.pulseInterval, 5); XCTAssertEqual(d.pulseFalloff, 0)
    }

    func testEventBufferIsBounded() {
        let g = Game(seed: 16, playerClass: .gunner, config: autopilotConfig())
        var peak = 0
        for _ in 0..<(60 * 40) {   // nobody drains
            g.tick()
            peak = max(peak, g.events.count)
        }
        XCTAssertGreaterThan(peak, 1000)
        XCTAssertLessThanOrEqual(peak, Game.maxBufferedEvents + 5000)
    }

    func testFastForwardAndAimAssist() {
        let g = Game(seed: 17, playerClass: .assault, config: autopilotConfig())
        let s = g.fastForward(seconds: 25)
        XCTAssertEqual(s.phase, .playing)
        XCTAssertGreaterThan(s.kills, 20)
        // aim assist finds a bug placed straight ahead
        let h = Game(seed: 18, playerClass: .assault)
        let P = h.player
        let i = h.spawnBug(T_BRUTE, P.x - 5, P.z - 5)
        h.tick()
        let dir = Vec2(-0.7071, -0.7071)
        XCTAssertEqual(h.aimAssistTarget(from: P, dir: dir), i)
        h.setVisibleArea([Vec2(100, 100), Vec2(110, 100), Vec2(110, 110)])
        XCTAssertEqual(h.aimAssistTarget(from: P, dir: dir), -1)
        h.setVisibleArea(nil)
        XCTAssertEqual(h.aimAssistTarget(from: P, dir: Vec2(0.7071, 0.7071)), -1)
        XCTAssertGreaterThan(h.laserLength(P), 0)
    }

    func testRandomPlayerInputStaysSane() {
        // a "monkey" player: random sticks and buttons every few ticks, every class
        for cls in MarineClass.allCases {
            let g = Game(seed: 31 + UInt32(cls.rawValue), playerClass: cls)
            var r = SeededRNG(seed: 99)
            for t in 0..<(60 * 20) {
                if t % 7 == 0 {
                    let mv = Vec2(r.range(-1, 1), r.range(-1, 1))
                    let aim: Float? = r.next() < 0.7 ? r.range(-4, 4) : nil
                    g.setPlayerInput(move: mv, aim: aim, fire: r.next() < 0.8, ability: r.next() < 0.05, dash: r.next() < 0.05,
                                     assist: r.next(), abilityTarget: r.next() < 0.5 ? Vec2(r.range(-60, 60), r.range(-60, 60)) : nil)
                }
                g.tick()
                if t % 30 == 0 { g.clearEvents() }
                if g.phase != .playing { break }
            }
            XCTAssertFalse(g.hasNonFinite(), "\(cls)")
            for m in g.marines where !m.downed { XCTAssertTrue(g.level.solid(m.x, m.z), "\(cls) marine \(m.index) off the deck at \(m.x),\(m.z)") }
            XCTAssertLessThanOrEqual(g.bugs.aliveCount, g.bugCap)
        }
    }
}
