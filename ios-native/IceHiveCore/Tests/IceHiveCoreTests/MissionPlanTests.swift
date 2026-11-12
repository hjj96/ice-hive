import XCTest
@testable import IceHiveCore

/// R1 «Mission modules»: the classic mission as a plan replays the old hard-coded stage machine bit for bit (golden
/// calibration rows of the code before the plan), a toy plan of every module on autopilot, each module's stages, HUD
/// lines and events, debugSkip through a whole plan, and the calibration presets per template.
final class MissionPlanTests: XCTestCase {

    /// Rows of «Operation Cold Light» from the stage machine before the plan (CI c22c370 calib.jsonl, `--preset gate`):
    /// a Recruit win with the Queen killed, a Veteran squad wiped on the walk to the lift, a Nightmare squad wiped in the
    /// hold with the Queen alive, the legacy v1.0 row (no Queen, the legacy stream).
    static let golden: [(CalibRun, String)] = [
        (CalibRun(tag: "rec", cls: .assault, tier: 0, mode: .auto, seed: 1000),
         #"{"tag":"rec","cls":"assault","q":"med","mode":"auto","tierIx":0,"seed":1000,"station":0,"th":{},"result":"won","t":330.5,"tier":"rec","shots":1771,"hits":1117,"pKills":1688,"stage":"extract","beacons":3,"kills":3947,"level":14,"stageAt":{"beacons":0,"b1":6.4,"c1":66.4,"b2":79.3,"c2":139.3,"b3":146.8,"toLift":206.8,"c3":206.8,"hold":225.9,"extract":325.9},"downs":[0,0,0,0],"pDowns":0,"downBy":-1,"firstDown":-1,"pFirstDown":-1,"holdDowns":0,"minHp":[100,115,120,77],"pLowS":0,"pHalfS":0,"pTakenPerMin":0,"maxAlive":179,"avgAlive":46,"holdAliveMax":173,"deckMax":126,"nearMax":60,"idleMax":1,"idleSt":"","pressAtHold":0,"pressMax":12.9,"firstBrute":43.4,"downSt":{},"queen":{"spawnT":263,"liftT":63,"hp":3607,"squadAtSpawn":"100/156/156/156","killT":11.2,"liftAtKill":51.8,"squadAtKill":"100/115/156/94","downs":0},"hurtBy":[0,97,8,0,13,41],"downBy4":[0,0,0,0,0,0]}"#),
        (CalibRun(tag: "vet", cls: .assault, tier: 1, mode: .auto, seed: 2001),
         #"{"tag":"vet","cls":"assault","q":"med","mode":"auto","tierIx":1,"seed":2001,"station":0,"th":{},"result":"lost","t":229.9,"tier":"vet","shots":1244,"hits":858,"pKills":1151,"stage":"toLift","beacons":3,"kills":2576,"level":13,"stageAt":{"beacons":0,"b1":6.4,"c1":66.4,"b2":80.7,"c2":141.4,"b3":150.3,"toLift":211,"c3":211},"downs":[1,1,1,1],"pDowns":1,"downBy":3,"firstDown":205.4,"pFirstDown":216.1,"holdDowns":0,"minHp":[8,5,19,1],"pLowS":0.7,"pHalfS":8.3,"pTakenPerMin":61,"maxAlive":192,"avgAlive":53,"holdAliveMax":0,"deckMax":0,"nearMax":56,"idleMax":1,"idleSt":"","pressAtHold":null,"pressMax":14.3,"firstBrute":39.6,"downSt":{"b3":1,"toLift":3},"queen":null,"hurtBy":[0,810,30,80,243,0],"downBy4":[0,2,0,0,2,0]}"#),
        (CalibRun(tag: "nm", cls: .assault, tier: 2, mode: .auto, seed: 3001),
         #"{"tag":"nm","cls":"assault","q":"med","mode":"auto","tierIx":2,"seed":3001,"station":0,"th":{},"result":"lost","t":300.9,"tier":"nm","shots":1819,"hits":1474,"pKills":1525,"stage":"hold","beacons":3,"kills":3849,"level":14,"stageAt":{"beacons":0,"b1":6.4,"c1":66.4,"b2":79.6,"c2":139.6,"b3":148.8,"toLift":215.3,"c3":215.3,"hold":236.6},"downs":[1,2,2,4],"pDowns":1,"downBy":0,"firstDown":203,"pFirstDown":298.8,"holdDowns":7,"minHp":[0,1,10,10],"pLowS":5.1,"pHalfS":19.7,"pTakenPerMin":72,"maxAlive":218,"avgAlive":59,"holdAliveMax":218,"deckMax":123,"nearMax":114,"idleMax":1,"idleSt":"","pressAtHold":0,"pressMax":13.1,"firstBrute":41.5,"downSt":{"b3":2,"hold":7},"queen":{"spawnT":268.9,"liftT":68.2,"hp":9998,"squadAtSpawn":"140/D/D/D","killT":null,"liftAtKill":null,"squadAtKill":null,"downs":3},"hurtBy":[0,1299,60,64,379,174],"downBy4":[0,6,0,0,2,1]}"#),
        (CalibRun(tag: "v10", cls: .assault, tier: -1, mode: .auto, seed: 4000),
         #"{"tag":"v10","cls":"assault","q":"med","mode":"auto","tierIx":-1,"seed":4000,"station":0,"th":{},"result":"won","t":326.4,"tier":"v10","shots":2064,"hits":1552,"pKills":4575,"stage":"extract","beacons":3,"kills":8666,"level":14,"stageAt":{"beacons":0,"b1":6.4,"c1":66.5,"b2":77.3,"c2":137.6,"b3":143.6,"toLift":203.6,"c3":203.6,"hold":221.8,"extract":321.8},"downs":[0,0,0,0],"pDowns":0,"downBy":-1,"firstDown":-1,"pFirstDown":-1,"holdDowns":0,"minHp":[80,120,91,120],"pLowS":0,"pHalfS":0,"pTakenPerMin":9,"maxAlive":856,"avgAlive":131,"holdAliveMax":856,"deckMax":128,"nearMax":51,"idleMax":1,"idleSt":"","pressAtHold":0,"pressMax":10.8,"firstBrute":36.5,"downSt":{},"queen":null,"hurtBy":[0,80,0,17,86,0],"downBy4":[0,0,0,0,0,0]}"#),
    ]

    func planGame(_ plan: MissionPlan, tier: Difficulty = .recruit, seed: UInt32 = 5, cls: MarineClass = .assault, autopilot: Bool = false,
                  god: Bool = true, configure: ((inout GameConfig) -> Void)? = nil) -> Game {
        tierGame(tier, seed: seed, cls: cls, autopilot: autopilot, god: god) { c in c.mission = .custom(plan); configure?(&c) }
    }

    /// Tick until `cond` (max `seconds`), handing every event to `onEvent`. Returns whether `cond` came true.
    @discardableResult
    func run(_ g: Game, seconds: Float, until cond: () -> Bool, _ onEvent: ((GameEvent) -> Void)? = nil) -> Bool {
        for _ in 0..<Int(seconds * 60) {
            g.tick()
            g.drainEvents { onEvent?($0) }
            if cond() { return true }
        }
        return false
    }

    // ---------------------------------------------------------------- the classic plan

    func testClassicPlanIsColdLight() {
        let g = Game(seed: 1, playerClass: .assault)
        XCTAssertEqual(g.mission, MissionTemplate.coldLight.build(g.level))
        XCTAssertEqual(g.mission.id, "cold-light")
        XCTAssertEqual(g.mission.steps.map { $0.module }, [.ring, .hold, .extract])
        guard case .ring(let r) = g.mission.steps[0], case .hold(let h) = g.mission.steps[1], case .extract(let e) = g.mission.steps[2] else {
            return XCTFail("classic plan shape")
        }
        XCTAssertEqual(r.sites, [0, 1, 2]); XCTAssertEqual(r.radius, BEACON_R); XCTAssertEqual(r.chargeTime, BEACON_TIME)
        XCTAssertEqual(r.contestedAt, 6); XCTAssertEqual(r.contestedRate, 0.3)
        XCTAssertEqual(h.zone, .lift); XCTAssertEqual(h.time, LIFT_TIME); XCTAssertTrue(h.pulse); XCTAssertTrue(h.releaseWithPlayer)
        XCTAssertEqual(h.boss, BossRider(.queen, at: nil, locks: true))
        XCTAssertEqual(h.names, StepNames(approach: "toLift", active: "hold"))
        XCTAssertEqual(e.duration, 4.6)
        XCTAssertEqual(g.mission.ringSiteCount, 3)
        XCTAssertEqual(g.mission.briefing, BannerText(title: .bannerDrop, sub: .bannerDropSub))
        XCTAssertEqual(g.missionStep, 0); XCTAssertEqual(g.currentModule, .ring); XCTAssertEqual(g.stepPhase, .approach)
        XCTAssertEqual(g.stage, .beacons); XCTAssertEqual(g.posture, .travel); XCTAssertEqual(g.calibStage, "beacons")
        // a generated station gets the same plan over its own beacons
        let s = Game(seed: 1, playerClass: .assault, level: Level(source: StationGenerator(), seed: 3))
        guard case .ring(let rs) = s.mission.steps[0] else { return XCTFail("generated plan") }
        XCTAssertEqual(rs.sites, Array(s.level.layout.beacons.indices))
        XCTAssertEqual(MissionTemplate.named("cold-light")?.id, "cold-light")
        XCTAssertEqual(Set(MissionTemplate.all.map { $0.id }).count, MissionTemplate.all.count)
    }

    /// The acceptance: the plan replays the old stage machine bit for bit.
    func testClassicPlanReplaysTheStageMachineBitForBit() {
        for (c, line) in MissionPlanTests.golden {
            XCTAssertEqual(Calibration.run(c).json, line, "\(c.tag) seed \(c.seed)")
        }
    }

    func testExplicitColdLightIsTheDefault() {
        let a = tierGame(.veteran, seed: 77, cls: .cryo, autopilot: true, god: true)
        let b = tierGame(.veteran, seed: 77, cls: .cryo, autopilot: true, god: true) { $0.mission = .coldLight }
        for _ in 0..<(60 * 150) { a.tick(); b.tick(); a.clearEvents(); b.clearEvents() }
        XCTAssertEqual(a.rng.state, b.rng.state)
        XCTAssertEqual(a.debugState.description, b.debugState.description)
        XCTAssertEqual(a.marines.map { $0.x }, b.marines.map { $0.x })
        XCTAssertEqual(a.kills, b.kills)
    }

    /// The HUD key changes whenever the objective line does (a whole plan of every module on autopilot).
    func testObjectiveKeyFollowsTheLine() {
        let g = tierGame(.recruit, seed: 9, cls: .gunner, autopilot: true, god: true) { $0.mission = MissionTemplate.named("drill-all") }
        var last = g.objective, key = g.objectiveKey, changes = 0
        for _ in 0..<(60 * 240) where g.phase == .playing {
            g.tick(); g.clearEvents()
            let o = g.objective, k = g.objectiveKey
            if o != last { changes += 1; XCTAssertNotEqual(k, key, "\(String(describing: last)) → \(String(describing: o))") }
            last = o; key = k
        }
        XCTAssertEqual(g.phase, .won)
        XCTAssertGreaterThan(changes, 8)
    }

    // ---------------------------------------------------------------- toy plans of every module on autopilot

    /// Each module drill (a one-module plan on the station's own decks; drill-all chains every module) is completed by
    /// the autopilot squad on Recruit without god mode, and its steps come in plan order.
    func testDrillsCompleteOnAutopilot() {
        for (k, t) in MissionTemplate.drills.enumerated() {
            let cls = MarineClass.allCases[k % 4]
            let g = tierGame(.recruit, seed: 300 + UInt32(k), cls: cls, autopilot: true) { $0.mission = t }
            var modules: [MissionModule] = [g.mission.steps[0].module]
            var thrown = 0, holds = 0, rides = 0, queens = 0
            run(g, seconds: 6 * 60, until: { g.phase != .playing }) { e in
                switch e {
                case .missionStep(let i, let m): XCTAssertEqual(i, modules.count, t.id); modules.append(m)
                case .switchThrown: thrown += 1
                case .holdStarted: holds += 1
                case .extractStarted: rides += 1
                case .bossKilled: queens += 1
                default: break
                }
            }
            XCTAssertEqual(g.phase, .won, "\(t.id) \(cls.id): \(g.debugState)")
            XCTAssertEqual(modules, g.mission.steps.map { $0.module }, t.id)
            XCTAssertEqual(g.missionStep, g.mission.steps.count - 1, t.id)
            let has = Set(modules)
            if has.contains(.switches) { XCTAssertEqual(thrown, 3, t.id); XCTAssertEqual(g.switchesDone, 3, t.id) }
            if has.contains(.hold) { XCTAssertEqual(holds, 1, t.id) }
            if has.contains(.extract) { XCTAssertEqual(rides, 1, t.id) }
            if has.contains(.boss) { XCTAssertEqual(queens, 1, t.id); XCTAssertTrue(g.boss.done) }
            if has.contains(.ring) { XCTAssertEqual(g.beacons.filter { $0.state == 2 }.count, 1, t.id) }
        }
    }

    // ---------------------------------------------------------------- each module's stages, lines and events

    func testSwitchModule() {
        let s1 = SwitchSite(x: 30, z: 25, radius: 2, time: 3, kind: .breaker), s2 = SwitchSite(x: 24, z: 30, radius: 2, time: 3, kind: .door)
        var step = SwitchStep(sites: [s1, s2])
        step.alarm = PacingValue(legacy: 0, waves: 0)
        let g = planGame(MissionPlan(id: "t-switch", steps: [.switches(step), .extract(ExtractStep())]))
        XCTAssertEqual(g.stage, .switches); XCTAssertEqual(g.posture, .travel); XCTAssertEqual(g.switches.count, 2)
        XCTAssertEqual(g.objective, GameText(.objSwitches, [.int(0), .int(2)]))
        XCTAssertEqual(g.objectivePoint(), Vec2(30, 25), "the nearer switch")
        XCTAssertEqual(g.calibStage, "switch")
        g.debugTeleport(s1.x, s1.z)
        var started = -1, thrownAt: [Int] = []
        run(g, seconds: 0.1, until: { g.activeSwitch >= 0 }) { if case .switchStarted(let k) = $0 { started = k } }
        XCTAssertEqual(started, 0); XCTAssertEqual(g.stepPhase, .active); XCTAssertEqual(g.posture, .defend)
        XCTAssertEqual(g.objective, GameText(.objHoldRing))
        XCTAssertEqual(g.threatState, .calm)
        run(g, seconds: 1.5, until: { false })
        XCTAssertEqual(g.objectiveProgress, 0.5, accuracy: 0.03)
        run(g, seconds: 2, until: { g.switches[0].state == 2 }) { if case .switchThrown(let k) = $0 { thrownAt.append(k) } }
        XCTAssertEqual(thrownAt, [0])
        XCTAssertEqual(g.activeSwitch, -1); XCTAssertEqual(g.stepPhase, .approach)
        XCTAssertEqual(g.beaconsDone, 0, "switches do not escalate by default")
        XCTAssertEqual(g.objective, GameText(.objSwitches, [.int(1), .int(2)]))
        // the second switch ends the step: the walk to the lift begins
        g.debugTeleport(s2.x, s2.z)
        var steps: [Int] = []
        run(g, seconds: 4, until: { g.missionStep == 1 }) { if case .missionStep(let i, let m) = $0 { steps.append(i); XCTAssertEqual(m, .extract) } }
        XCTAssertEqual(steps, [1])
        XCTAssertEqual(g.stage, .toLift); XCTAssertEqual(g.objective, GameText(.objLiftCalled)); XCTAssertEqual(g.calibStage, "toLift")
        // an escalating SWITCH step counts each switch like a beacon
        step.escalates = true
        let e = planGame(MissionPlan(id: "t-switch-esc", steps: [.switches(step)]))
        e.debugSkip()
        XCTAssertEqual(e.beaconsDone, 1)
        e.debugSkip()
        XCTAssertEqual(e.phase, .won, "the last step done wins the mission")
    }

    func testHoldOnADeck() {
        let zone = MissionZone.circle(x: 30, z: 25, r: 3)
        var h = HoldStep(zone: zone, time: 5)
        h.openHorde = PacingValue(legacy: 0, waves: 0)
        let g = planGame(MissionPlan(id: "t-hold", steps: [.hold(h)]))
        XCTAssertEqual(g.stage, .area); XCTAssertEqual(g.stepPhase, .approach); XCTAssertEqual(g.posture, .travel)
        XCTAssertEqual(g.objective, GameText(.objReach))
        XCTAssertEqual(g.objectiveMarker, Vec2(30, 25))
        XCTAssertEqual(g.calibStage, "toHold")
        XCTAssertTrue(g.approachAllowance)
        g.debugTeleport(30, 25)
        var opening = 0
        run(g, seconds: 0.1, until: { g.stepPhase == .active }) { if case .hordeStarted = $0 { opening += 1 } }
        XCTAssertEqual(opening, 0, "no opening horde when the step asks for none")
        XCTAssertEqual(g.stage, .area); XCTAssertEqual(g.posture, .hold); XCTAssertEqual(g.liftDur, 5)
        XCTAssertTrue(g.holdActive); XCTAssertEqual(g.calibStage, "hold")
        XCTAssertEqual(g.objective, GameText(.objHoldArea, [.clock(5)]))
        XCTAssertNil(g.contextHint, "the lift's hints stay on the lift")
        XCTAssertFalse(g.liftLocked)
        run(g, seconds: 1, until: { false })
        XCTAssertEqual(g.liftT, 4 - SIM_DT, accuracy: 0.05)
        // the countdown only runs with a standing marine inside
        g.debugTeleport(36, 34)
        for m in g.marines { m.x = 36; m.z = 34; m.px = 36; m.pz = 34 }
        let held = g.liftT
        run(g, seconds: 0.5, until: { false })
        XCTAssertEqual(g.liftT, held, accuracy: 1e-5)
        XCTAssertEqual(g.objectiveMarker, Vec2(30, 25), "the marker points back at the zone")
        g.debugTeleport(30, 25)
        run(g, seconds: 6, until: { g.phase != .playing })
        XCTAssertEqual(g.phase, .won)
    }

    /// An endless hold (a holdout like R10's «Dig In»): no countdown to name, no progress bar, it only ends with the squad.
    func testEndlessHold() {
        var h = HoldStep(zone: .circle(x: 30, z: 25, r: 3), time: .infinity)
        h.openHorde = PacingValue(legacy: 0, waves: 0)
        let g = planGame(MissionPlan(id: "t-holdout", steps: [.hold(h)]))
        g.debugTeleport(30, 25)
        run(g, seconds: 3, until: { false })
        XCTAssertTrue(g.holdActive)
        XCTAssertEqual(g.phase, .playing)
        XCTAssertEqual(g.objective, GameText(.objHoldArea, [.clock(0)]))
        XCTAssertEqual(g.objectiveProgress, -1)
        _ = g.objectiveKey
    }

    func testBossStep() {
        let g = planGame(MissionPlan(id: "t-boss", steps: [.boss(BossStep(.queen, zone: .lift, delay: 2))]), autopilot: true) { $0.bossHp = 400 }
        XCTAssertEqual(g.stage, .boss); XCTAssertEqual(g.objective, GameText(.objReach)); XCTAssertEqual(g.calibStage, "toBoss")
        g.debugSkip()
        XCTAssertEqual(g.stepPhase, .active); XCTAssertEqual(g.posture, .hold); XCTAssertEqual(g.calibStage, "boss")
        XCTAssertEqual(g.objective, GameText(.objKillBoss, [.name(.queen)]))
        var warnAt: Float = -1, spawnAt: Float = -1, warnPos = Vec2(0, 0)
        let t0 = g.time
        run(g, seconds: 6, until: { g.boss.spawned }) { e in
            if case .bossWarning(_, let p) = e { warnAt = g.time; warnPos = p }
            if case .bossSpawned = e { spawnAt = g.time }
        }
        XCTAssertEqual(warnAt - t0, 2, accuracy: 0.05, "the step's delay")
        XCTAssertEqual(spawnAt - warnAt, 2, accuracy: 0.05)
        let L = g.level.lift
        XCTAssertLessThan(warnPos.y - L.z, -4, "the far rim of her arena")
        XCTAssertEqual(g.threatState, .boss); XCTAssertEqual(g.objectiveStyle, .boss)
        XCTAssertEqual(g.objectiveProgress, 1 - g.boss.hpFraction, accuracy: 1e-5)
        run(g, seconds: 60, until: { g.phase != .playing })
        XCTAssertEqual(g.phase, .won, "her death ends the step and the mission")
        XCTAssertTrue(g.boss.done)
        // a tier without a Queen (the legacy row) skips the step
        let l = planGame(MissionPlan(id: "t-boss-v10", steps: [.boss(BossStep(.queen, zone: .lift))]), tier: .legacyV10)
        l.debugSkip()
        run(l, seconds: 0.2, until: { l.phase != .playing })
        XCTAssertEqual(l.phase, .won)
        XCTAssertFalse(l.boss.spawned)
    }

    func testExtractFromTheDeck() {
        let g = planGame(MissionPlan(id: "t-extract", steps: [.extract(ExtractStep())]), autopilot: true)
        XCTAssertEqual(g.stage, .toLift); XCTAssertEqual(g.objective, GameText(.objLiftCalled))
        XCTAssertEqual(g.objectiveMarker, Vec2(g.level.lift.x, g.level.lift.z))
        var rideAt: Float = -1
        run(g, seconds: 90, until: { g.phase != .playing }) { if case .extractStarted = $0 { rideAt = g.time } }
        XCTAssertGreaterThan(rideAt, 0)
        XCTAssertEqual(g.phase, .won)
        XCTAssertEqual(g.stage, .extract)
        XCTAssertEqual(g.time - rideAt, 4.6, accuracy: 0.05)
    }

    /// debugSkip walks a plan of every module (and the lift hold with its Queen) to the victory.
    func testDebugSkipThroughEveryModule() {
        let s = SwitchStep(sites: [SwitchSite(x: 30, z: 25), SwitchSite(x: 25, z: 30)])
        var area = HoldStep(zone: .circle(x: -1, z: 28, r: 4), time: 10)
        area.openHorde = PacingValue(legacy: 0, waves: 0)
        let plan = MissionPlan(id: "t-all", steps: [.switches(s), .ring(RingStep(sites: [2, 0])), .hold(area), .boss(BossStep(.queen, zone: .lift)),
                                                     .hold(HoldStep(zone: .lift, time: 30, pulse: true, boss: BossRider(.queen), releaseWithPlayer: true)),
                                                     .extract(ExtractStep())])
        let g = planGame(plan, tier: .veteran)
        var stages: [MissionStage] = [g.stage]
        var n = 0
        func note() { if stages.last != g.stage { stages.append(g.stage) } }
        while g.phase == .playing && n < 40 {
            n += 1
            g.debugSkip()
            note()
            for _ in 0..<12 { g.tick(); note() }
        }
        XCTAssertEqual(g.phase, .won)
        XCTAssertEqual(stages, [.switches, .beacons, .area, .boss, .toLift, .hold, .extract])
        XCTAssertEqual(g.beacons.map { $0.state }, [2, 0, 2], "only the RING step's beacons")
        XCTAssertEqual(g.mission.ringSiteCount, 2)
        XCTAssertEqual(g.runSummary(won: true, surrendered: false).beaconsTotal, 2)
    }

    /// A step's line takes as many of its arguments as its id's signature asks for.
    func testStepLinesFollowTheSignature() {
        let g = Game(seed: 2, playerClass: .pyro)
        XCTAssertEqual(g.stepLine(.objKillQueen, [.name(.queen)]), GameText(.objKillQueen))
        XCTAssertEqual(g.stepLine(.objKillBoss, [.name(.queen)]), GameText(.objKillBoss, [.name(.queen)]))
        XCTAssertEqual(g.stepLine(.bannerHoldSub, [.int(100)]), GameText(.bannerHoldSub, [.int(100)]))
        XCTAssertEqual(g.stepLine(.bannerHold, [.int(100)]), GameText(.bannerHold))
        // (R1's seven module lines, R7's six mission lines — Breaker Run, Vent Purge —, B4's three: the Manifold)
        XCTAssertEqual(Game.moduleObjectiveSamples.count, 16)
        for t in Game.moduleObjectiveSamples { XCTAssertEqual(t.args.count, t.id.signature.count) }
        // a deck hold's default lines and stage names
        let h = HoldStep(zone: .circle(x: 0, z: 0, r: 4), time: 20)
        XCTAssertNil(h.callBanner); XCTAssertNil(h.holdBanner)
        XCTAssertEqual([h.approachText, h.holdText, h.bossText], [.objReach, .objHoldArea, .objKillBoss])
        XCTAssertEqual(h.names, StepNames(approach: "toHold", active: "hold"))
    }

    // ---------------------------------------------------------------- calibration presets per template

    func testTemplateCalibration() {
        // the classic gate preset is unchanged (no gated templates yet)
        XCTAssertEqual(Calibration.preset("gate")!.count, 212)
        XCTAssertTrue(Calibration.preset("gate")!.allSatisfy { $0.mission == nil })
        let drills = Calibration.preset("drills")!
        XCTAssertEqual(drills.count, MissionTemplate.drills.count * 2 * 2 * 4)
        XCTAssertEqual(Set(drills.map { "\($0.mission!) \($0.seed)" }).count, drills.count)
        XCTAssertEqual(Calibration.preset("drill-hold")!.map { $0.mission }, [String?](repeating: "drill-hold", count: 16))
        XCTAssertEqual(Calibration.preset("drill-hold")!.first?.tag, "drill-hold-rec")
        // a template row carries its mission (a classic row never does) and survives the JSONL round trip
        let r = Calibration.run(CalibRun(tag: "drill-switch-rec", cls: .pyro, tier: 0, mode: .auto, seed: 7, mission: "drill-switch"))
        XCTAssertEqual(r.result, "won")
        XCTAssertEqual(r.stageAt.first?.0, "switch")
        XCTAssertTrue(r.json.contains(#""station":0,"mission":"drill-switch","th":{}"#), r.json)
        XCTAssertEqual(CalibRow(json: r.json)?.mission, "drill-switch")
        XCTAssertFalse(MissionPlanTests.golden[0].1.contains("mission"))
        XCTAssertNil(CalibRow(json: MissionPlanTests.golden[0].1)?.mission)
        XCTAssertEqual(Calibration.run(CalibRun(tag: "x", cls: .pyro, tier: 0, mode: .auto, seed: 7, mission: "nope")).error, "unknown mission nope")
        // the classic bands never read template rows; a template's own bands are reported
        var rows = (0..<20).map { _ in classic(0, won: true) } + (0..<20).map { k in classic(1, won: k < 16) } + (0..<10).map { k in classic(2, won: k < 2) }
        rows += (0..<4).map { _ in afk(1, 80) } + (0..<4).map { _ in afk(0, 130) }
        var lost = classic(1, won: false); lost.mission = "drill-ring"; lost.tag = "drill-ring-vet"
        rows += [lost, lost, lost]
        let (ok, lines) = Calibration.gate(rows)
        XCTAssertTrue(ok, lines.filter { !$0.ok }.map { $0.text }.joined(separator: "; "))
        XCTAssertTrue(lines.contains { !$0.gated && !$0.ok && $0.text.hasPrefix("drill-ring vet/auto wins 0.0%") }, lines.map { $0.text }.joined(separator: "; "))
        XCTAssertTrue(lines.contains { $0.gated && $0.text.hasPrefix("vet/auto wins 80.0%") })
        // a run of templates only is not failed for the missing classic groups; no rows at all still fail
        XCTAssertTrue(Calibration.gate([lost]).passed)
        XCTAssertFalse(Calibration.gate([]).passed)
    }

    func classic(_ tier: Int, won: Bool) -> CalibRow {
        var r = CalibRow()
        r.tierIx = tier; r.tag = Calibration.tierTag(tier); r.mode = "auto"; r.result = won ? "won" : "lost"
        var q = CalibQueen(); q.killT = 20; r.queen = q; r.stageAt = [("beacons", 0), ("hold", 220)]
        return r
    }

    func afk(_ tier: Int, _ first: Float) -> CalibRow {
        var r = CalibRow()
        r.tierIx = tier; r.tag = Calibration.tierTag(tier); r.mode = "afk"; r.result = "lost"; r.pFirstDown = first
        return r
    }
}
