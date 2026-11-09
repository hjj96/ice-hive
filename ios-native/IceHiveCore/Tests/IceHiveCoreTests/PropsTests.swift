import XCTest
@testable import IceHiveCore

/// Stage 1 R6 «Valves, light, lockers»: the station's lamps (the renderer's rule), steam valves (hits, the curtain, its
/// timing, the bots, the aim assist), the light circuits (the lit mask as the overhead's no-drop circles, the hive breaking
/// lamps, breaker rings, DARK, R1's breaker switch, lit beacons), supply lockers, the report line, and the classic mission
/// untouched with no props laid.

/// A game on «Кельвин-9» with its interactives (`PropLayout.kelvin`) and the overhead's demo slice, the director off unless
/// asked, the bots holding fire unless asked.
func propsGame(_ tier: Difficulty = .veteran, seed: UInt32 = 7, cls: MarineClass = .assault, god: Bool = false, director: Bool = false,
               holdFire: Bool = true, overhead: Bool = true, plan: MissionPlan? = nil) -> Game {
    var c = GameConfig()
    c.difficulty = tier
    c.autoPickUpgrades = true
    c.god = god
    c.levelSource = KelvinStation(overhead: overhead ? .kelvinSlice : OverheadLayout(), props: .kelvin)
    if let p = plan { c.mission = .custom(p) }
    let g = Game(seed: seed, playerClass: cls, config: c)
    g.directorEnabled = director
    g.debugHoldFire = holdFire
    g.clearEvents()
    return g
}

extension Game {
    /// A live bug with this uid.
    func aliveUid(_ u: Int32) -> Bool {
        for i in 0..<bugs.count where bugs.uid[i] == u { return bugs.dead[i] == 0 }
        return false
    }
    /// Slot of the live bug with this uid (-1 none).
    func slotOf(_ u: Int32) -> Int {
        for i in 0..<bugs.count where bugs.uid[i] == u && bugs.dead[i] == 0 { return i }
        return -1
    }
}

/// «Кельвин-9»'s circuits (PropLayout.kelvin): pad, hub (+ the bridge), beacon A, plaza, beacon B, beacon C, the lift stairs.
let C_PAD = 0, C_HUB = 1, C_A = 2

final class PropsDataTests: XCTestCase {
    func testKelvinLampsFollowTheRenderersRule() {
        let L = Level(source: KelvinStation(props: .kelvin), seed: 1)
        XCTAssertEqual(L.lamps.count, 48, "WorldLevel's 48 lamp posts (a lamp every 12 m on the railing runs)")
        var per = [Int](repeating: 0, count: PropLayout.kelvin.circuits.count)
        for l in L.lamps {
            XCTAssertGreaterThanOrEqual(l.circuit, 0, "every lamp of Kelvin-9 is on a circuit")
            per[max(0, l.circuit)] += 1
        }
        XCTAssertEqual(per, [3, 6, 7, 10, 8, 10, 4])
        // lamp 9: the bridge's far rail at x 9 (its arm reaches over the bridge, +z)
        XCTAssertEqual(L.lamps[9].x, 9)
        XCTAssertEqual(L.lamps[9].z, 27.12, accuracy: 1e-4)
        XCTAssertEqual(L.lamps[9].nz, 1)
        XCTAssertEqual(L.lamps[9].circuit, C_HUB)
        XCTAssertEqual(L.lamps[9].pool.y, 28.52, accuracy: 1e-4)
        // the classic station: no props, no lamp states — the same posts by the same rule
        XCTAssertTrue(KelvinStation().makeLayout(seed: 1).props.isEmpty)
        XCTAssertTrue(Level(source: KelvinStation(), seed: 1).lamps.isEmpty)
        XCTAssertEqual(StationLamps.place(Level(source: KelvinStation(), seed: 1)).map { Vec2($0.x, $0.z) }, L.lamps.map { Vec2($0.x, $0.z) })
    }

    func testBreakersAndTheLockerAreSolid() {
        let L = Level(source: KelvinStation(props: .kelvin), seed: 1), C = Level(source: KelvinStation(), seed: 1)
        for c in PropLayout.kelvin.circuits {
            XCTAssertEqual(L.walkValue(L.cellOf(c.x, c.z)), 2, "a breaker's pedestal blocks its cell")
            XCTAssertEqual(C.walkValue(C.cellOf(c.x, c.z)), 1, "deck on the classic station")
            XCTAssertTrue(L.canStand(c.x + 1.3, c.z) || L.canStand(c.x - 1.3, c.z), "room to stand in its ring")
        }
        let k = PropLayout.kelvin.lockers[0]
        XCTAssertEqual(L.walkValue(L.cellOf(k.cabinet.x, k.cabinet.y)), 2)
        XCTAssertTrue(L.canStand(k.x, k.z))
        // the props sit on the station's decks (valves: their curtains over deck)
        for v in PropLayout.kelvin.valves { XCTAssertTrue(L.walkable(v.mid.x, v.mid.y), "valve curtain at \(v.mid)") }
    }
}

final class ValveTests: XCTestCase {
    func testRoundsAimedUpPopAValve() {
        let g = propsGame()
        g.playerAlone(13, 31)
        let v = g.valves[0].site
        let ang = atan2f(v.x - 13, v.z - 31)
        // a round at the deck passes under the valve on its pipe
        g.fireBolt(13, 31, ang, 74, 17, 0, 0, 0, true)
        g.step(20)
        XCTAssertEqual(g.valves[0].hp, VALVE_HP)
        // rounds aimed up strike it (and count as hits)
        let hits0 = g.hits
        for _ in 0..<3 { g.fireBolt(13, 31, ang, 74, 17, 0, 0, 0, true, up: true) }
        g.step(20)
        XCTAssertEqual(g.valves[0].hp, VALVE_HP - 51, accuracy: 0.01)
        XCTAssertEqual(g.valves[0].phase, .ready)
        XCTAssertEqual(g.hits - hits0, 3)
        g.fireBolt(13, 31, ang, 74, 17, 0, 0, 0, true, up: true)
        g.step(8)
        XCTAssertEqual(g.valves[0].phase, .burst)
        XCTAssertEqual(g.valves[0].src, 0, "the curtain's kills are the shooter's")
        XCTAssertEqual(g.propStats.bursts, 1)
        g.step(Int(VALVE_WARN / SIM_DT) + 2)
        XCTAssertEqual(g.valves[0].phase, .venting)
    }

    func testTheSquadsBlastsReachTheValve() {
        let g = propsGame()
        g.playerAlone(13, 32)
        let v = g.valves[0].site
        g.queueBoom(v.x, v.z + 1.5, 5, 150, 0, .frag)
        g.step(2)
        XCTAssertNotEqual(g.valves[0].phase, .ready, "a frag under the pipe bursts it")
        // a boomer's blast does not reach up
        let h = propsGame()
        h.playerAlone(13, 32)
        h.queueBoom(v.x, v.z + 1.5, 3.1, 70, -1, .boomer)
        h.step(2)
        XCTAssertEqual(h.valves[0].phase, .ready)
    }

    func testTheCurtainScaldsTheDeckAndClearsTheSpan() {
        let g = propsGame(god: true)
        g.playerAlone(13, 28.4)
        // a runner up on the slice rack (out of the duct mouth, onto the rack over the bridge)
        let up = g.debugSpawnRouteBug(entry: SL_DUCT)
        XCTAssertGreaterThanOrEqual(up, 0)
        let upUid = g.bugs.uid[up]
        g.step(150)
        let ui = g.slotOf(upUid)
        XCTAssertGreaterThanOrEqual(ui, 0)
        XCTAssertNotEqual(g.bugs.up[ui], 0, "still up")
        XCTAssertTrue(g.valves[0].site.spanCovers(g.bugs.x[ui], g.bugs.z[ui]), "on the span of the valve")
        // runners and a brute under the span, round the player
        var deck: [Int32] = []
        for k in 0..<6 { let i = g.spawnBug(T_RUN, 11.5 + Float(k) * 0.6, 28.0 + Float(k % 2) * 0.8); deck.append(g.bugs.uid[i]) }
        let bi = g.spawnBug(T_BRUTE, 15.5, 28.4)
        let brute = g.bugs.uid[bi]
        g.debugBurstValve(0, by: 0)
        XCTAssertFalse(g.dropSpotOK(13, 28.4), "nothing drops into it from the burst on")
        g.step(Int(VALVE_WARN / SIM_DT) + 1)
        XCTAssertEqual(g.valves[0].phase, .venting)
        g.step(60)
        for u in deck { XCTAssertFalse(g.aliveUid(u), "a runner under the span scalded") }
        XCTAssertFalse(g.aliveUid(upUid), "the bug up on the span died")
        XCTAssertTrue(g.aliveUid(brute), "a brute survives a second of it")
        let b = g.slotOf(brute)
        XCTAssertLessThan(g.bugs.hp[b], g.bugs.hpMax[b], "scalded")
        XCTAssertGreaterThanOrEqual(g.propStats.curtainKills, 6)
        XCTAssertEqual(g.propStats.upKills, 1)
        // its timing: the curtain ends 5 s after it began; ready again 25 s after the burst
        g.step(Int((VALVE_VENT - 1) / SIM_DT) + 2)
        XCTAssertEqual(g.valves[0].phase, .recharge)
        XCTAssertTrue(g.dropSpotOK(17, 28.4), "the curtain no longer blocks drops (the dark middle of the bridge)")
        g.step(Int(VALVE_COOL / SIM_DT) - 4)
        XCTAssertEqual(g.valves[0].phase, .recharge)
        g.step(8)
        XCTAssertEqual(g.valves[0].phase, .ready)
        XCTAssertEqual(g.valves[0].hp, VALVE_HP)
        XCTAssertEqual(g.valves[0].gauge, 1)
    }

    func testTheCurtainScaldsMarinesTenASecond() {
        let g = propsGame()
        g.playerAlone(13, 28.4)
        let hp0 = g.player.hp
        g.debugBurstValve(0)
        g.step(Int((VALVE_WARN + VALVE_VENT) / SIM_DT) + 2)
        XCTAssertEqual(hp0 - g.player.hp, CURTAIN_MARINE_DPS * VALVE_VENT, accuracy: 3)
        XCTAssertEqual(g.propStats.steamHurt, CURTAIN_MARINE_DPS * VALVE_VENT, accuracy: 3)
    }

    func testAGunnerPopsAValveOverACrowdOnly() {
        // the autopilot gunner holding a spot on the bridge 4 m from the curtain's centre line
        func run(_ n: Int) -> Int {
            let plan = MissionPlan(id: "post", steps: [.hold(HoldStep(zone: .circle(x: 13, z: 32.4, r: 2.5), time: 999))])
            let g = propsGame(cls: .gunner, god: true, holdFire: false, plan: plan)
            g.playerAlone(13, 32.4)
            g.autopilot = true
            for k in 0..<n {
                let i = g.spawnBug(T_RUN, 8.5 + Float(k) * 1.4, 28.4)
                g.bugs.frz[i] = 60; g.bugs.chill[i] = 1
            }
            for _ in 0..<150 where g.propStats.bursts == 0 { g.step(1) }
            return g.propStats.bursts
        }
        XCTAssertEqual(run(8), 1, "8 bugs under the span: it pops the valve")
        XCTAssertEqual(run(3), 0, "3: not worth it")
    }

    func testTheAimAssistFindsAValveWhereItIsDrawn() {
        let g = propsGame()
        g.playerAlone(13, 33)
        let v = g.valves[0].site
        let lift = 0.75 * (v.y - g.level.groundY(v.x, v.z))
        let a = atan2f(v.x + FWD_X * lift - 13, v.z + FWD_Z * lift - 33)
        for _ in 0..<70 where g.valves[0].phase == .ready {
            g.setPlayerInput(move: Vec2(0, 0), aim: a, fire: true, ability: false, dash: false, assist: 0.75)
            g.step(1)
            XCTAssertTrue(g.player.aimUp, "the rounds go up to the valve")
        }
        XCTAssertNotEqual(g.valves[0].phase, .ready, "and pop it")
        // without assist the rounds stay on the deck
        let h = propsGame()
        h.playerAlone(13, 33)
        h.setPlayerInput(move: Vec2(0, 0), aim: a, fire: true, ability: false, dash: false, assist: 0)
        h.step(60)
        XCTAssertEqual(h.valves[0].phase, .ready)
    }

    func testBotsStepOutOfTheCurtain() {
        let g = propsGame(god: true)
        g.place(0, 2, 30)
        g.place(1, 13, 28.4)
        g.place(2, 16, 28.0)
        g.debugBurstValve(0)
        g.step(45)
        for k in 1...2 { XCTAssertFalse(g.valves[0].site.covers(g.marines[k].x, g.marines[k].z), "bot \(k) stepped out") }
    }
}

final class LightTests: XCTestCase {
    func testLitDeckIsTheOverheadsNoDropDeck() {
        let g = propsGame()
        g.playerAlone(16, 30)
        // the hub's lamps light the bridge's hub end; its middle is dark
        XCTAssertTrue(g.lit(9, 30))
        XCTAssertFalse(g.lit(17, 30))
        XCTAssertFalse(g.dropSpotOK(9, 30))
        XCTAssertTrue(g.dropSpotOK(17, 30))
        XCTAssertEqual(g.lightsLit, 7)
        g.debugCutCircuit(C_HUB)
        XCTAssertFalse(g.lit(9, 30))
        XCTAssertTrue(g.dropSpotOK(9, 30))
        XCTAssertEqual(g.lightsLit, 6)
    }

    func testDropsComeOnlyOverDarkDeck() {
        func warned(_ x: Float, _ z: Float) -> Int {
            let g = propsGame(god: true)
            g.playerAlone(x, z)
            g.debugRoutePack(6, entry: SL_RISER, rate: 3)
            var n = 0
            for _ in 0..<(60 * 8) {
                g.step(1)
                for e in g.events { if case .dropWarned(_, let to, _) = e { n += 1; XCTAssertFalse(g.lit(to.x, to.y), "a drop onto lit deck") } }
                g.clearEvents()
            }
            return n
        }
        XCTAssertEqual(warned(9.5, 30), 0, "the player on the lit end of the bridge: no drop")
        XCTAssertGreaterThan(warned(17.5, 30), 0, "in the dark middle: the drops come")
    }

    func testSpittersSpitOnLampsAndBreakThem() {
        let g = propsGame(god: true)
        g.playerAlone(14, 31)
        // a spitter on the bridge 6 m from lamp 9's foot
        let i = g.spawnBug(T_SPIT, 15, 28)
        g.bugs.cd[i] = 0
        for _ in 0..<60 where g.propStats.lampSpits == 0 { g.step(1) }
        XCTAssertEqual(g.propStats.lampSpits, 1)
        XCTAssertTrue(g.telegraphs.contains { $0.active && $0.cause == .acidTarget }, "the lime ring on the lamp")
        g.step(120)
        XCTAssertEqual(g.propStats.lampsBroken, 1)
        XCTAssertFalse(g.lamps[9].on)
        XCTAssertEqual(g.circuits[C_HUB].burning, 5)
        XCTAssertTrue(g.circuits[C_HUB].lit, "five of six still burn")
        // the next lamp waits LAMP_SPIT_GAP s (the spitter goes back to the squad)
        g.step(Int(10 / SIM_DT))
        XCTAssertEqual(g.propStats.lampSpits, 1)
    }

    func testBrutesRamLampPosts() {
        let g = propsGame(god: true)
        g.playerAlone(-2, 30)
        // a brute walking by the hub's west lamp post (−7.88, 21) leaves it; charging into it, it breaks it
        let w = g.spawnBug(T_BRUTE, -7.2, 21.3)
        g.bugs.cd[w] = 9
        g.step(3)
        XCTAssertTrue(g.lamps[40].on)
        g.bugs.st[w] = S_CHARGE; g.bugs.t[w] = 0.9; g.bugs.ax[w] = -0.3; g.bugs.az[w] = -0.95
        g.step(3)
        XCTAssertFalse(g.lamps[40].on)
        XCTAssertEqual(g.propStats.lampsBroken, 1)
        XCTAssertTrue(g.events.contains { if case .toast(let t, _) = $0 { return t.id == .toastLightsCut }; return false },
                      "«They're cutting the lights»")
        // one climbing over the railing beside a post leaves it (it has not reached the deck)
        let i = g.spawnBug(T_BRUTE, -5.2, 37.88, mode: 1, nx: 0, nz: 1)
        XCTAssertGreaterThanOrEqual(i, 0)
        g.step(3)
        XCTAssertTrue(g.lamps[10].on)
        // a boomer's blast does not break lamps (the design's hive: spitters and brutes)
        g.queueBoom(-5, 37.4, 3.1, 70, -1, .boomer)
        g.step(2)
        XCTAssertTrue(g.lamps[10].on)
        XCTAssertEqual(g.propStats.lampsBroken, 1)
    }

    func testABreakerRingBringsTheCircuitBack() {
        let g = propsGame()
        g.playerAlone(0, 30)
        g.debugCutCircuit(C_HUB)
        XCTAssertFalse(g.circuits[C_HUB].powered)
        XCTAssertEqual(g.circuits[C_HUB].burning, 0)
        XCTAssertFalse(g.circuits[C_HUB].lit)
        let s = g.circuits[C_HUB].site
        g.place(0, s.x + 1.2, s.z)
        g.step(Int(3 / SIM_DT))
        XCTAssertEqual(g.circuits[C_HUB].progress, 0.5, accuracy: 0.02)
        // out of the ring it drains
        g.place(0, s.x + 4, s.z)
        g.step(60)
        XCTAssertEqual(g.circuits[C_HUB].progress, 0, accuracy: 0.02)
        g.place(0, s.x + 1.2, s.z)
        g.step(Int(BREAKER_TIME / SIM_DT) + 2)
        XCTAssertTrue(g.circuits[C_HUB].powered)
        XCTAssertEqual(g.circuits[C_HUB].burning, 6)
        XCTAssertTrue(g.circuits[C_HUB].lit)
        XCTAssertEqual(g.propStats.restores, 1)
        XCTAssertTrue(g.lit(-6.48, 21))
        // it also mends the broken lamps of the circuit
        g.debugBreakLamp(40)
        XCTAssertTrue(g.circuits[C_HUB].needsRestore)
        g.step(Int(BREAKER_TIME / SIM_DT) + 2)
        XCTAssertTrue(g.lamps[40].on)
        XCTAssertEqual(g.lamps[40].hp, LAMP_HP)
    }

    func testADarkMissionStartsWithTheLightsOff() {
        let plan = MissionPlan(id: "dark", steps: [.extract(ExtractStep())], modifiers: [.dark])
        let g = propsGame(plan: plan)
        XCTAssertTrue(g.circuits.allSatisfy { !$0.powered })
        XCTAssertTrue(g.lamps.allSatisfy { !$0.on })
        XCTAssertEqual(g.lightsLit, 0)
        XCTAssertFalse(g.lit(9, 30))
        XCTAssertTrue(g.dropSpotOK(9, 30))
    }

    func testABreakerSwitchBringsItsCircuitBack() {
        let pad = PropLayout.kelvin.circuits[C_PAD]
        var step = SwitchStep(sites: [SwitchSite(x: pad.x, z: pad.z, radius: 2.0, time: 1, kind: .breaker)])
        step.alarm = PacingValue(legacy: 0, waves: 0)
        let plan = MissionPlan(id: "breaker", steps: [.switches(step), .extract(ExtractStep())], modifiers: [.dark])
        let g = propsGame(god: true, director: true, plan: plan)
        g.playerAlone(pad.x + 1.2, pad.z)
        g.step(30)
        XCTAssertEqual(g.circuits[C_PAD].progress, 0, "the step's ring is the one on its breaker")
        XCTAssertGreaterThan(g.switches[0].progress, 0.3)
        g.step(60)
        XCTAssertEqual(g.currentModule, .extract, "the switch was thrown")
        XCTAssertTrue(g.circuits[C_PAD].powered)
        XCTAssertEqual(g.circuits[C_PAD].burning, 3)
        XCTAssertFalse(g.circuits[C_HUB].powered, "the others stay dark")
    }

    func testALitBeaconLightsItsDeckForGood() {
        let g = propsGame()
        g.debugCutCircuit(C_A)
        let b = g.beacons[0]
        XCTAssertFalse(g.lit(b.x + 3, b.z))
        var guardN = 0
        while g.beacons[0].state != 2 && guardN < 3 { g.debugSkip(); guardN += 1 }
        XCTAssertEqual(g.beacons[0].state, 2)
        g.step(1)
        XCTAssertTrue(g.lit(b.x + 3, b.z), "beacons are big lamps")
        XCTAssertFalse(g.dropSpotOK(b.x + 3, b.z))
        XCTAssertFalse(g.circuits[C_A].powered, "its circuit is still off")
    }

    func testIdleBotsBringTheLightsBack() {
        let g = propsGame()
        g.debugCutCircuit(C_HUB)
        g.place(0, 0, 30); g.place(1, -1.6, 31.4); g.place(2, 1.6, 31.4); g.place(3, 0, 32.6)
        g.updateFlows()
        var t = 0
        while t < 60 * 15 && !g.circuits[C_HUB].powered { g.step(1); t += 1 }
        XCTAssertTrue(g.circuits[C_HUB].powered, "a bot re-lit the hub")
        XCTAssertLessThan(t, 60 * 12)
    }
}

final class LockerTests: XCTestCase {
    func testTheLockerGivesAMedkitAndTheAbility() {
        let g = propsGame()
        g.playerAlone(0, 33)
        g.debugHurt(marine: 0, hp: 50)
        g.player.abCd = 9
        let l = g.lockers[0].site
        g.place(0, l.x, l.z)
        g.step(Int(LOCKER_TIME / SIM_DT) + 2)
        XCTAssertTrue(g.lockers[0].used)
        XCTAssertEqual(g.lockers[0].openedBy, 0)
        XCTAssertEqual(g.player.abCd, 0, "the ability is ready")
        g.step(2)
        XCTAssertEqual(g.player.hp, 90, accuracy: 2, "the medkit, picked up at once")
        XCTAssertEqual(g.propStats.lockers, 1)
        // once per mission
        g.player.abCd = 9
        g.step(Int(LOCKER_TIME / SIM_DT) + 2)
        XCTAssertEqual(g.player.abCd, 9 - Float(Int(LOCKER_TIME / SIM_DT) + 2) * SIM_DT, accuracy: 0.05)
    }

    func testAHurtBotUsesTheLocker() {
        let g = propsGame()
        g.place(0, 2, 31); g.place(1, 3, 30); g.place(2, 1, 30); g.place(3, 2, 29)
        g.updateFlows()
        g.debugHurt(marine: 1, hp: 30)
        var t = 0
        while t < 60 * 10 && !g.lockers[0].used { g.step(1); t += 1 }
        XCTAssertTrue(g.lockers[0].used)
        XCTAssertEqual(g.lockers[0].openedBy, 1)
    }
}

final class PropsMissionTests: XCTestCase {
    func testTheReportCountsTheLightsAtExtraction() {
        func run(_ won: Bool, _ on: Int, _ total: Int) -> RunSummary {
            RunSummary(cls: .assault, won: won, surrendered: false, time: 300, playerKills: 10, beaconsDone: 3, queenSpawned: true, queenDone: true,
                       downs: 1, downBy: .runner, tierIndex: 1, tierMul: 1, stage: .extract, pressureLoss: false, shots: 10, hits: 5, accuracy: 50,
                       bestCombo: 3, level: 5, station: .kelvin, lightsOn: on, lightsTotal: total)
        }
        let p = RunScore.make(run(true, 6, 7)).parts.first { $0.label.id == .scoreLights }
        XCTAssertEqual(p?.label, GameText(.scoreLights, [.int(6), .int(7)]))
        XCTAssertEqual(p?.value, 6 * LIGHT_SCORE)
        XCTAssertNil(RunScore.make(run(true, 0, 0)).parts.first { $0.label.id == .scoreLights }, "no circuits: no line")
        XCTAssertNil(RunScore.make(run(false, 6, 7)).parts.first { $0.label.id == .scoreLights }, "no extraction: no line")
        // the game fills it in
        let g = propsGame()
        g.debugCutCircuit(C_A)
        let r = g.runSummary(won: true, surrendered: false)
        XCTAssertEqual(r.lightsOn, 6)
        XCTAssertEqual(r.lightsTotal, 7)
        XCTAssertEqual(sliceGame().runSummary(won: true, surrendered: false).lightsTotal, 0)
    }

    func testNoPropsReplaysByteForByte() {
        // a station laying an empty prop set plays exactly the classic mission
        let a = Calibration.run(CalibRun(tag: "t", cls: .pyro, tier: 1, mode: .auto, maxs: 150, seed: 3001))
        let lv = Level(source: KelvinStation(overhead: OverheadLayout(), props: PropLayout()), seed: 3001)
        let b = Calibration.run(CalibRun(tag: "t", cls: .pyro, tier: 1, mode: .auto, maxs: 150, seed: 3001), level: lv)
        XCTAssertEqual(a.json, b.json)
        XCTAssertNil(a.props)
        XCTAssertFalse(a.json.contains("\"props\""))
        // with the props laid: deterministic, and its row carries them
        let c1 = Calibration.run(CalibRun(tag: "p", cls: .gunner, tier: 1, mode: .auto, maxs: 150, seed: 77, props: true))
        let c2 = Calibration.run(CalibRun(tag: "p", cls: .gunner, tier: 1, mode: .auto, maxs: 150, seed: 77, props: true))
        XCTAssertEqual(c1.json, c2.json)
        XCTAssertEqual(c1.props?.circuits, 7)
        XCTAssertEqual(CalibRow(json: c1.json)?.props, c1.props, "the row reads back")
    }

    func testThePropsPresetIsInformational() {
        let runs = Calibration.preset("props") ?? []
        XCTAssertEqual(runs.count, 48)
        XCTAssertTrue(runs.allSatisfy { $0.props && $0.station == 0 && $0.mission == nil })
        XCTAssertFalse(Calibration.preset("gate")!.contains { $0.props }, "the gate keeps the classic station")
    }
}
