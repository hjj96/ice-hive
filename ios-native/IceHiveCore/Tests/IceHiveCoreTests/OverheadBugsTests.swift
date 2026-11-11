import XCTest
@testable import IceHiveCore

/// Stage 1 R4 «Overhead bugs»: the Dropper (a fifth bug type) — its telegraph, the PIN and its breaks (dash, the squad's
/// fire, running out, the marine down), its caps; perched spitters; duct mouths that rattle and can be shot shut; the
/// director's channels in a full mission; determinism. Uses R2's demo slice (OverheadTests.sliceGame): the pad → hub rack
/// at z 26.4 with its abyss riser (node 2), its joint (node 1) and the duct mouth (node 4) 3 m out over the void.

/// Every pinBroken event (cause, freer) drained from `g`.
private func pinBreaks(_ g: Game) -> [(PinBreak, Int)] {
    var out: [(PinBreak, Int)] = []
    g.drainEvents { if case .pinBroken(_, _, let c, let f) = $0 { out.append((c, f)) } }
    return out
}

final class DropperTypeTests: XCTestCase {
    func testTheDropperIsAFifthBugType() {
        XCTAssertEqual(BugType.allCases.count, 5)
        XCTAssertEqual(BUG_SPECS.count, BugType.allCases.count)
        XCTAssertEqual(BUG_TYPES, BugType.allCases.count)
        let s = BugType.dropper.spec
        XCTAssertEqual(BugType.dropper.id, "dropper")
        XCTAssertEqual(s.hp, 30); XCTAssertEqual(s.speed, 4.0); XCTAssertEqual(s.dmg, 6); XCTAssertEqual(s.xp, 3)
        XCTAssertEqual(s.speed * DROPPER_ROUTE_K, 5.5, accuracy: 1e-4, "5.5 m/s on the routes (design §1.1.3)")
        // the damage sources: its own for the report, the runner's slot in the six-slot calibration ledgers
        XCTAssertEqual(DamageSource(bugType: T_DROP), .dropper)
        XCTAssertEqual(DamageSource(bugType: T_BOOM), .boomer)
        XCTAssertEqual(DamageSource(bugType: 9), .environment)
        XCTAssertEqual(DamageSource.dropper.ledger, DamageSource.runner.ledger)
        for d in DamageSource.allCases where d != .dropper { XCTAssertEqual(d.ledger, d.rawValue + 1, "\(d): the classic slots") }
        // text: its name, first-sighting tip, loss tip
        XCTAssertTrue(NameRef.all.contains(.bug(.dropper)))
        XCTAssertEqual(GameText.bugTip(.dropper)?.id, .toastTipDropper)
        XCTAssertEqual(MetaText.lossTips[DamageSource.dropper.rawValue].id, .tipLossDropper)
        // the director never draws it for the deck
        XCTAssertEqual(SPECIAL_CAP.count, BUG_TYPES); XCTAssertEqual(WAVE_SPECIAL_CAP.count, BUG_TYPES)
        let g = tierGame(.veteran, seed: 4)
        g.time = 300; g.beaconsDone = 3
        for _ in 0..<5000 { XCTAssertNotEqual(g.pickType(true), T_DROP) }
    }

    func testTiersKeepThePinApprovedAndTheChannelsOff() {
        XCTAssertEqual(Difficulty.tiers.map { $0.dropperCap }, [4, 5, 6], "live Droppers 4 / 5 / 6")
        XCTAssertEqual(Difficulty.tiers.map { $0.pinT }, [0.8, 1.2, 1.2])
        for d in Difficulty.tiers {
            XCTAssertLessThanOrEqual(d.pinT, 1.2, "\(d.id): the owner approved a pin of up to 1.2 s")
            XCTAssertEqual(d.dropperGap, 0, "\(d.id): off until package R5")
            XCTAssertEqual(d.perchGap, 0)
            XCTAssertEqual(d.routes, 0)
        }
        var d = Difficulty.veteran
        XCTAssertEqual(d.override(["pinT": 5, "dropperCap": 2, "pinGnaw": 3, "dropperGap": 20, "perchGap": 30]), [])
        XCTAssertEqual(d.pinT, 1.2, "never past 1.2 s, whatever the override")
        XCTAssertEqual(d.dropperCap, 2)
        XCTAssertEqual(d.dropperGap, 20)
    }

    func testRouteSpeedsAndPatience() {
        let g = sliceGame()
        g.playerAlone(0, 36)
        let d = g.debugSpawnRouteBug(entry: SL_RISER, type: .dropper)
        let r = g.debugSpawnRouteBug(entry: SL_RISER)
        XCTAssertEqual(g.routeSpeedK(d, .pipe), DROPPER_ROUTE_K)
        XCTAssertEqual(g.routeSpeedK(d, .cable), DROPPER_CABLE_K, "slow on a cable (the runners' fast lane)")
        XCTAssertEqual(g.routeSpeedK(r, .pipe), 1)
        XCTAssertEqual(g.routeSpeedK(r, .cable), 1.25)
        XCTAssertEqual(g.bugs.lt[d], DROPPER_PATIENCE)
        XCTAssertEqual(g.bugs.lt[r], ROUTE_PATIENCE)
        XCTAssertEqual(g.droppersAlive, 1)
        XCTAssertEqual(g.overheadStats.droppers, 1)
    }
}

final class DropperPinTests: XCTestCase {
    /// Until the first drop telegraph (≤ `seconds`); the zone's index.
    func untilZone(_ g: Game, _ seconds: Float = 12) -> Int? {
        for _ in 0..<Int(seconds * 60) {
            g.tick()
            if let k = g.dropZones.firstIndex(where: { $0.active }) { return k }
        }
        return nil
    }

    func testTelegraphTimingAndThePin() {
        for tier in Difficulty.tiers {
            let g = sliceGame(tier)
            g.playerAlone(14, 29)
            let i = g.debugSpawnRouteBug(entry: SL_RISER, type: .dropper)
            guard let k = untilZone(g) else { return XCTFail("\(tier.id): no drop") }
            let z = g.dropZones[k]
            XCTAssertEqual(z.warn, tier.dropWarn, accuracy: 1e-6, "\(tier.id): the 0.9 s telegraph (Recruit 1.2 s)")
            XCTAssertGreaterThanOrEqual(z.warn, 0.9)
            XCTAssertEqual(g.bugs.state(i), .coil)
            let tele = try! XCTUnwrap(g.telegraphs.first { $0.active && $0.cause == .dropZone })
            XCTAssertEqual(tele.life, tier.dropWarn, accuracy: 1e-6)
            let t0 = g.simTime, hp0 = g.player.hp
            var landed: Float = -1
            var pinEvent = false
            for _ in 0..<120 {
                g.tick()
                g.drainEvents { e in
                    if case .dropLanded(_, let hit) = e { landed = g.simTime; XCTAssertTrue(hit) }
                    if case .pinned(let m, _, let time) = e { pinEvent = true; XCTAssertEqual(m, 0); XCTAssertEqual(time, tier.pinT) }
                }
                if landed >= 0 { break }
            }
            XCTAssertEqual(landed - t0, tier.dropWarn, accuracy: 2.5 * SIM_DT, "\(tier.id): it lands when the warning ends")
            XCTAssertTrue(pinEvent, "\(tier.id): standing in the ring, the player is pinned")
            XCTAssertTrue(g.player.pinned)
            XCTAssertEqual(g.player.pinT, tier.pinT, accuracy: 1e-6)
            XCTAssertEqual(g.bugs.state(i), .pin)
            XCTAssertEqual(hp0 - g.player.hp, DROPPER_LAND * tier.dmg, accuracy: 0.01, "\(tier.id): 14 × the damage multiplier")
            XCTAssertEqual(g.lastHit, .dropper)
            XCTAssertEqual(g.hurtBy[DamageSource.runner.rawValue + 1], DROPPER_LAND * tier.dmg, accuracy: 0.01, "the ledger keeps six slots")
            XCTAssertEqual(g.overheadStats.pins, 1)
            // beside the marine, never over it (its class colour stays readable), in reach of every deck weapon
            let d = hypotf2(g.bugs.x[i] - g.player.x, g.bugs.z[i] - g.player.z)
            XCTAssertEqual(d, PIN_REACH, accuracy: 0.02)
            XCTAssertFalse(g.bugs.isOverhead(i))
        }
    }

    func testPinnedNoMoveNoFireNoAbilityThenADashBreaksIt() {
        let g = sliceGame()
        g.playerAlone(14, 30)
        let i = g.debugPinMarine(0)
        XCTAssertGreaterThanOrEqual(i, 0)
        let P = g.player
        XCTAssertEqual(g.contextHint?.text.id, .hintPinned)
        XCTAssertEqual(g.contextHint?.urgent, true)
        let x0 = P.x, z0 = P.z, shots0 = g.shots, hp0 = P.hp
        g.setPlayerInput(move: Vec2(1, 0), aim: 0.3, fire: true, ability: true, dash: false)
        for _ in 0..<30 { g.tick() }
        XCTAssertEqual(P.x, x0, accuracy: 0.05); XCTAssertEqual(P.z, z0, accuracy: 0.05)
        XCTAssertEqual(g.shots, shots0, "no fire while pinned")
        XCTAssertEqual(P.abCd, 0, "no ability while pinned")
        XCTAssertTrue(P.pinned)
        XCTAssertEqual(hp0 - P.hp, Difficulty.veteran.pinGnaw * PIN_BITE_T * Difficulty.veteran.dmg, accuracy: 0.01, "one gnaw in 0.5 s")
        // the dash breaks it at once
        _ = pinBreaks(g)
        g.setPlayerInput(move: Vec2(-1, 0), aim: nil, fire: false, ability: false, dash: true)
        g.tick()
        XCTAssertFalse(P.pinned)
        XCTAssertGreaterThan(P.dashT, 0)
        let b = pinBreaks(g)
        XCTAssertEqual(b.first?.0, .dash)
        XCTAssertEqual(g.overheadStats.pinDash, 1)
        XCTAssertGreaterThan(P.dropGrace, 0, "a drop grace after the pin")
        XCTAssertNotEqual(g.bugs.state(i), .pin, "thrown off")
        for _ in 0..<20 { g.tick() }
        XCTAssertGreaterThan(hypotf2(P.x - x0, P.z - z0), 2, "the dash took the player away")
    }

    func testTheSquadsFireGetsItOff() {
        let g = sliceGame()
        g.playerAlone(14, 30)
        let i = g.debugPinMarine(0)
        _ = pinBreaks(g)
        // 15 damage over the pin, any weapon: 10 then 6
        g.hitBug(i, 10, 1)
        XCTAssertTrue(g.player.pinned)
        var toast: GameText? = nil
        g.hitBug(i, 6, 1)
        XCTAssertFalse(g.player.pinned)
        g.drainEvents { e in
            if case .pinBroken(_, _, let c, let f) = e { XCTAssertEqual(c, .fire); XCTAssertEqual(f, 1) }
            if case .toast(let t, _) = e { toast = t }
        }
        XCTAssertEqual(toast?.id, .toastPinFreed, "«Got it off you» from the squadmate")
        XCTAssertEqual(g.overheadStats.pinFire, 1)
        XCTAssertEqual(g.bugs.dead[i], 0, "off, not dead")
        // killing it frees the marine too
        let h = sliceGame()
        h.playerAlone(14, 30)
        let j = h.debugPinMarine(0)
        XCTAssertTrue(h.hitBug(j, 1000, 2))
        XCTAssertFalse(h.player.pinned)
        XCTAssertEqual(h.overheadStats.pinFire, 1)
    }

    func testTheBotsShootThePinnerFirstAndFreeThePlayer() {
        let g = sliceGame(god: true, holdFire: false)
        g.debugTeleport(14, 30)
        let i = g.debugPinMarine(0)
        let bot = g.marines[1], P = g.player
        // a runner between the bot and the player, nearer the bot: without the pin it is the bot's pick
        let deck = g.spawnBug(T_RUN, bot.x + (P.x - bot.x) * 0.3, bot.z + (P.z - bot.z) * 0.3)
        g.bugs.hp[deck] = 1000
        g.hash.rebuild(g.bugs)
        XCTAssertEqual(g.aiPickTarget(bot, 17), deck, "not before a human reaction time")
        g.marines[0].pinAt -= BOT_REACT
        XCTAssertEqual(g.aiPickTarget(bot, 17), i, "a pinning Dropper before the runner in front of it")
        g.marines[0].pinAt += BOT_REACT
        var freed: Float = -1
        let t0 = g.simTime
        for _ in 0..<120 {
            g.tick()
            if !g.player.pinned { freed = g.simTime; break }
        }
        XCTAssertGreaterThan(freed, 0, "the squad got it off")
        XCTAssertLessThan(freed - t0, Difficulty.veteran.pinT, "before the pin ran out")
        XCTAssertGreaterThanOrEqual(g.overheadStats.pinFire, 1)
    }

    func testThePinRunsOutNeverPast1_2s() {
        for tier in Difficulty.tiers {
            let g = sliceGame(tier)
            g.playerAlone(14, 30)
            _ = g.debugPinMarine(0)
            _ = pinBreaks(g)
            var held: Float = 0
            var cause: PinBreak? = nil
            for _ in 0..<120 {
                g.tick()
                if g.player.pinned { held += SIM_DT }
                if let b = pinBreaks(g).first { cause = b.0; break }
            }
            XCTAssertEqual(cause, .timeout, tier.id)
            XCTAssertEqual(held, tier.pinT, accuracy: 2 * SIM_DT, tier.id)
            XCTAssertLessThanOrEqual(held, 1.2 + 1e-4)
        }
    }

    func testAPinnedBotDashesOut() {
        let g = sliceGame(god: true)
        g.debugTeleport(14, 30)
        _ = g.debugPinMarine(2)
        _ = pinBreaks(g)
        var cause: PinBreak? = nil
        var t: Float = 0
        for _ in 0..<90 {
            g.tick(); t += SIM_DT
            if let b = pinBreaks(g).first { cause = b.0; break }
        }
        XCTAssertEqual(cause, .dash)
        XCTAssertEqual(t, PIN_REACT, accuracy: 3 * SIM_DT, "a human reaction, then the dash")
    }

    func testAPinEndsWhenTheMarineGoesDown() {
        let g = sliceGame()
        g.playerAlone(14, 30)
        let i = g.debugPinMarine(0)
        _ = pinBreaks(g)
        g.debugHurt(marine: 0, hp: 0)
        g.tick()
        XCTAssertEqual(pinBreaks(g).first?.0, .down)
        XCTAssertNotEqual(g.bugs.state(i), .pin)
        XCTAssertEqual(g.player.pinT, 0)
    }

    func testCapsAndNeverASecondPin() {
        for tier in Difficulty.tiers {
            let g = sliceGame(tier)
            g.playerAlone(0, 36)
            XCTAssertEqual(g.debugRoutePack(10, entry: SL_RISER, rate: 1, type: .dropper), tier.dropperCap, "\(tier.id): live Droppers")
        }
        // two Droppers over the player: the first pins, the second never starts a drop on the pinned marine
        let g = sliceGame(.veteran, seed: 5, god: true)
        g.playerAlone(14, 29.5)
        g.debugRoutePack(2, entry: SL_RISER, rate: 4, type: .dropper)
        var pinnedOnce = false, secondWhilePinned = false
        for _ in 0..<(60 * 20) {
            g.tick()
            g.drainEvents { _ in }
            if g.player.pinned {
                pinnedOnce = true
                if g.dropZones.contains(where: { $0.active && $0.marine == 0 && $0.progress < 0.05 }) { secondWhilePinned = true }
            }
        }
        XCTAssertTrue(pinnedOnce)
        XCTAssertFalse(secondWhilePinned, "no drop starts on a pinned marine")
        XCTAssertLessThanOrEqual(g.overheadStats.pins, g.overheadStats.drops)
    }
}

final class PerchedSpitterTests: XCTestCase {
    func testPerchPointsOfTheSlice() {
        let L = Level(source: KelvinStation(overhead: .kelvinSlice), seed: 1)
        let G = try! XCTUnwrap(L.overhead)
        XCTAssertEqual(G.perches, [SL_J, SL_RISER], "the joint and the riser top, both against the void beside the bridge")
        XCTAssertEqual(G.ducts, [SL_DUCT])
        XCTAssertEqual(OverheadLayout.kelvinSlice.hash, OverheadGoldens.slice, "derived: the golden hash is untouched")
    }

    func testASpitterPerchesAndSpitsFromHeight() {
        let g = sliceGame()
        g.playerAlone(14, 36)     // out of reach at first (9.6 m from the riser top… the far side of the hub deck)
        g.place(0, 13, 33)
        let i = g.debugSpawnRouteBug(entry: SL_RISER, type: .spitter)
        var perchedAt: SIMD3<Float>? = nil
        var t = 0
        while t < 60 * 6 && g.bugs.state(i) != .perch {
            g.tick(); t += 1
            g.drainEvents { if case .perched(let p) = $0 { perchedAt = p } }
        }
        XCTAssertEqual(g.bugs.state(i), .perch)
        XCTAssertNotNil(perchedAt)
        XCTAssertTrue(g.bugs.isOverhead(i), "up there: only rounds aimed up reach it")
        XCTAssertEqual(g.overheadStats.perched, 1)
        XCTAssertTrue(g.perchTaken(0) || g.perchTaken(1))
        // it spits: the lime ring + fill for the 0.65 s wind-up and the 1.1 s flight, then a glob from the perch
        var windAt: Float = -1, launchAt: Float = -1
        var flight: Float = 0
        for _ in 0..<(60 * 4) {
            g.tick()
            if windAt < 0 && g.bugs.t[i] > 0 { windAt = g.simTime - SIM_DT }
            g.drainEvents { if case .acidFromPerch(let f, _, let fl) = $0 { launchAt = g.simTime; flight = fl; XCTAssertGreaterThan(f.y, 4) } }
            if launchAt > 0 { break }
        }
        XCTAssertGreaterThan(launchAt, 0, "it spat")
        XCTAssertEqual(launchAt - windAt, PERCH_WIND, accuracy: 2 * SIM_DT, "the slower wind-up")
        XCTAssertEqual(flight, PERCH_GLOB)
        XCTAssertEqual(g.globs.dur[0], PERCH_GLOB, accuracy: 1e-6, "the slower glob")
        XCTAssertEqual(g.overheadStats.perchSpits, 1)
    }

    func testRangeSpacingAndTheBots() {
        // 14 m: a marine 13 m from the perch is spat at, one 15 m away is not
        func spits(_ px: Float, _ pz: Float) -> Int {
            let g = sliceGame()
            g.playerAlone(px, pz)
            let i = g.debugSpawnRouteBug(entry: SL_RISER, type: .spitter)
            for _ in 0..<(60 * 6) { g.tick() }
            XCTAssertEqual(g.bugs.state(i), .perch, "(\(px), \(pz))")
            return g.overheadStats.perchSpits
        }
        // (the riser top at (14, 26.4): 12.5 m to (1.5, 26.6)… on the hub deck; 15.5 m to (-1.5, 26.8) is off it — use the bridge)
        XCTAssertGreaterThan(spits(14, 33), 0, "6.6 m")
        // at most 2 perched within 20 m: a third spitter finds no perch and goes down to the deck
        let g = sliceGame()
        g.playerAlone(14, 33)
        g.debugRoutePack(3, entry: SL_RISER, rate: 4, type: .spitter)
        var maxPerched = 0
        for _ in 0..<(60 * 10) { g.tick(); maxPerched = max(maxPerched, g.overheadStateCounts[6]) }
        XCTAssertEqual(maxPerched, PERCH_MAX)
        XCTAssertGreaterThanOrEqual(g.overheadStats.hops, 1, "the third hopped down")
        // a bot answers a perched spitter winding up before a deck bug farther off
        let h = sliceGame()
        h.debugTeleport(14, 31)
        let i = h.debugSpawnRouteBug(entry: SL_RISER, type: .spitter)
        for _ in 0..<(60 * 4) where h.bugs.state(i) != .perch { h.tick() }
        XCTAssertEqual(h.bugs.state(i), .perch)
        h.bugs.t[i] = PERCH_WIND
        let far = h.spawnBug(T_RUN, h.marines[1].x + 7, h.marines[1].z + 2)
        h.bugs.hp[far] = 1000
        h.hash.rebuild(h.bugs)
        XCTAssertEqual(h.aiPickTarget(h.marines[1], 17), i)
    }

    func testFireBringsAPerchedSpitterDownAndFreesThePerch() {
        let g = sliceGame(cls: .pyro)
        g.playerAlone(14, 33)
        let i = g.debugSpawnRouteBug(entry: SL_RISER, type: .spitter)
        for _ in 0..<(60 * 4) where g.bugs.state(i) != .perch { g.tick() }
        XCTAssertEqual(g.bugs.state(i), .perch)
        g.bugs.hp[i] = 1000
        let P = g.player
        g.place(0, g.bugs.x[i], 30)
        P.aim = Float.pi; P.ax = 0; P.az = -1
        g.flameTick(P, SIM_DT)
        var t = 0
        while g.bugs.state(i) == .perch && t < 120 { g.tick(); t += 1 }
        XCTAssertEqual(g.bugs.state(i), .fall, "it lost its grip")
        XCTAssertFalse(g.perchTaken(0) || g.perchTaken(1), "the perch is free again")
    }
}

final class DuctMouthTests: XCTestCase {
    func testTheGrilleRattlesBeforeThePackPours() {
        let g = sliceGame()
        g.playerAlone(14, 33)
        XCTAssertEqual(g.ducts.count, 1)
        XCTAssertEqual(g.debugRoutePack(5, entry: SL_DUCT, rate: 2.5), 5)
        var rattleAt: Float = -1, firstOut: Float = -1, rattles = 0
        for _ in 0..<(60 * 5) {
            g.tick()
            g.drainEvents { if case .ductRattle(let k) = $0 { XCTAssertEqual(k, 0); rattles += 1; if rattleAt < 0 { rattleAt = g.simTime } } }
            if firstOut < 0 && g.overheadStats.spawns > 0 { firstOut = g.simTime }
        }
        XCTAssertEqual(rattles, 1, "one rattle per pack")
        XCTAssertGreaterThan(rattleAt, 0)
        XCTAssertEqual(firstOut - rattleAt, DUCT_RATTLE, accuracy: 2 * SIM_DT, "the pack pours when the 2 s rattle ends")
        XCTAssertEqual(g.overheadStats.spawns, 5)
        XCTAssertEqual(g.overheadStats.rattles, 1)
    }

    func testShotShutForFortyFiveSecondsThenTheHiveChewsThrough() {
        let g = sliceGame()
        g.playerAlone(14, 33)
        g.debugRoutePack(5, entry: SL_DUCT, rate: 2.5)
        for _ in 0..<30 { g.tick() }
        XCTAssertFalse(g.debugHurtDuct(0, DUCT_HP - 1))
        XCTAssertTrue(g.ducts[0].open)
        var sealed = false
        XCTAssertTrue(g.debugHurtDuct(0, 1))
        g.drainEvents { if case .ductSealed(let k) = $0 { sealed = k == 0 } }
        XCTAssertTrue(sealed)
        XCTAssertEqual(g.ducts[0].shutT, DUCT_SHUT)
        XCTAssertEqual(g.overheadStats.seals, 1)
        for _ in 0..<(60 * 3) { g.tick() }
        XCTAssertEqual(g.overheadStats.spawns, 0, "the pack bound for it is lost")
        XCTAssertEqual(g.overheadStats.ductLost, 5)
        XCTAssertEqual(g.debugRoutePack(3, entry: SL_DUCT), 0, "nothing is sent to a shut duct")
        XCTAssertNotEqual(g.routeEntry(near: Vec2(19, 26)), SL_DUCT)
        var opened = false
        for _ in 0..<Int((DUCT_SHUT - 3) * 60) + 5 { g.tick(); g.drainEvents { if case .ductOpened = $0 { opened = true } } }
        XCTAssertTrue(opened)
        XCTAssertTrue(g.ducts[0].open)
        XCTAssertEqual(g.ducts[0].hp, DUCT_HP)
        XCTAssertEqual(g.debugRoutePack(3, entry: SL_DUCT), 3)
    }

    func testRoundsAimedUpAndBlastsStrikeTheGrille() {
        let g = sliceGame()
        g.playerAlone(19, 30)
        let p = g.ducts[0].pos
        // a round aimed up toward the mouth (from the bridge, along −z)
        g.fireBolt(p.x, 30, Float.pi, 74, 17, 0, 0, 0, true, up: true)
        for _ in 0..<12 { g.tick() }
        XCTAssertEqual(g.ducts[0].hp, DUCT_HP - 17, accuracy: 1e-3)
        // one aimed at the deck passes under it
        g.fireBolt(p.x, 30, Float.pi, 74, 17, 0, 0, 0, true)
        for _ in 0..<12 { g.tick() }
        XCTAssertEqual(g.ducts[0].hp, DUCT_HP - 17, accuracy: 1e-3)
        // a frag 2 m off (reach 3 m): damage
        g.queueBoom(p.x, p.z + 2, 5, 150, 0, .frag)
        g.tick()
        XCTAssertLessThan(g.ducts[0].hp, DUCT_HP - 17 - 1)
    }

    func testTheAutopilotShootsARattlingDuctShut() {
        let g = sliceGame(holdFire: false)
        g.autopilot = true
        g.playerAlone(19, 29)
        g.debugRoutePack(6, entry: SL_DUCT, rate: 2)
        var t = 0
        while g.ducts[0].open && t < 60 * 6 { g.tick(); t += 1 }
        XCTAssertFalse(g.ducts[0].open, "the assault shot the grille shut")
        XCTAssertLessThan(g.overheadStats.spawns, 6)
    }

    func testTheAssistFindsTheMouthWhereItIsDrawn() {
        let g = sliceGame()
        g.playerAlone(19, 31)
        let P = g.player
        let p = g.ducts[0].pos
        let lift = 0.75 * (p.y - g.level.groundY(p.x, p.z))
        let seen = Vec2(p.x + FWD_X * lift - P.x, p.z + FWD_Z * lift - P.z)
        g.setPlayerInput(move: Vec2(0, 0), aim: Game.angle(of: seen), fire: true, ability: false, dash: false, assist: 0.75)
        g.tick()
        XCTAssertTrue(P.aimUp, "rounds go up at the duct")
        XCTAssertLessThan(abs(angDiff(P.aim, Game.angle(of: Vec2(p.x - P.x, p.z - P.z)))), 0.05, "turned to the mouth")
    }
}

final class OverheadBugsMissionTests: XCTestCase {
    func fingerprint(_ g: Game) -> [Float] {
        var f: [Float] = [g.time, Float(g.kills), Float(g.bugs.count), Float(g.routeAlive), Float(g.overheadStats.pins),
                          Float(g.overheadStats.perchSpits), Float(g.overheadStats.seals)]
        for m in g.marines { f += [m.x, m.z, m.hp, m.pinT] }
        for i in 0..<g.bugs.count { f += [g.bugs.x[i], g.bugs.y[i], g.bugs.z[i], Float(g.bugs.st[i]), Float(g.bugs.type[i])] }
        for d in g.ducts { f += [d.hp, d.shutT] }
        return f
    }

    func testSameSeedSameOverheadBugs() {
        func run() -> Game {
            let g = sliceGame(.veteran, seed: 23, holdFire: false)
            g.autopilot = true
            g.debugTeleport(14, 30)
            for t in 0..<(60 * 30) {
                if t % 300 == 0 { g.debugRoutePack(2, entry: SL_RISER, rate: 2, type: .dropper) }
                if t % 420 == 60 { g.debugRoutePack(1, entry: SL_RISER, rate: 2, type: .spitter) }
                if t % 600 == 120 { g.debugRoutePack(4, entry: SL_DUCT, rate: 2) }
                g.tick(); g.clearEvents()
            }
            return g
        }
        let a = run(), b = run()
        XCTAssertGreaterThan(a.overheadStats.droppers, 2)
        XCTAssertEqual(fingerprint(a), fingerprint(b))
        XCTAssertEqual(a.overheadStats, b.overheadStats)
        XCTAssertFalse(a.hasNonFinite())
    }

    func testTheChannelsInAFullMission() {
        // a generated station with its routes, the overhead on with the Dropper and perch channels: Droppers go up and drop,
        // spitters perch, the caps hold, every pin ends one of the four ways and none holds past 1.2 s (the squad's cones,
        // blasts and turret bring most Droppers down before they drop — R2's counterplay; calibration reports the numbers)
        var droppers = 0, drops = 0, perched = 0, pins = 0
        for (k, cls) in [MarineClass.gunner, .cryo, .assault].enumerated() {
            let c = CalibRun(tag: "ohb", cls: cls, tier: 1, mode: .auto, maxs: 400, seed: 1600 + UInt32(k), station: UInt32(1 + k),
                             th: ["routes": 0.2, "dropperGap": 15, "perchGap": 20])
            let row = Calibration.run(c)
            XCTAssertNil(row.error)
            let oh = try! XCTUnwrap(row.oh)
            XCTAssertLessThanOrEqual(oh.maxUp, Difficulty.veteran.routeCap)
            XCTAssertLessThanOrEqual(oh.maxZones, Difficulty.veteran.dropCap)
            XCTAssertLessThanOrEqual(oh.pinMs, oh.pins * 1200 + 20, "no pin past 1.2 s")
            XCTAssertEqual(oh.pinDash + oh.pinFire + oh.pinTimeout + oh.pinDown, oh.pins, "every pin ended one way")
            XCTAssertLessThanOrEqual(oh.dropperLanded, oh.dropperDrops)
            XCTAssertTrue(row.json.contains("\"pins\":"))
            droppers += oh.droppers; drops += oh.dropperDrops; perched += oh.perched; pins += oh.pins
        }
        XCTAssertGreaterThan(droppers, 4, "the Dropper channel sent Droppers up")
        XCTAssertGreaterThan(drops, 0, "Droppers dropped in real missions")
        XCTAssertGreaterThan(perched, 0, "spitters perched")
        XCTAssertLessThanOrEqual(pins, drops)
    }
}
