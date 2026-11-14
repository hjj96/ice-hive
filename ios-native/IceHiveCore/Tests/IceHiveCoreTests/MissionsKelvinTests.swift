import XCTest
@testable import IceHiveCore

/// Stage 1 R7 «Missions I»: Breaker Run and Vent Purge on Kelvin-9 — their plans and station, the darkness and the
/// generator's staged relights, the seals (vents shut for good, pours, the thinning stream), the defended switch rings
/// (pushes, drain), both missions won on autopilot, their report lines and strip, their gated calibration preset, and the
/// classic mission untouched. Stage 2 M1 «Missions I at full length»: four contested breakers and a 90 s generator; the seals
/// under real pressure (the seal being worked pours) and the duct mouth held shut (its weld fills only while the grille is
/// shot shut, which the hive chews through in 10 s); the planned work long enough for a 6–8 min mission.

/// A game of mission `t` on its own station.
func missionGame(_ t: MissionTemplate, tier: Difficulty = .recruit, seed: UInt32 = 11, cls: MarineClass = .assault,
                 autopilot: Bool = true, god: Bool = false) -> Game {
    var c = GameConfig()
    c.difficulty = tier
    c.autopilot = autopilot
    c.autoPickUpgrades = true
    c.god = god
    c.mission = t
    return Game(seed: seed, playerClass: cls, config: c, level: t.level(seed: seed))
}

final class MissionsKelvinTests: XCTestCase {

    @discardableResult
    func run(_ g: Game, seconds: Float, until cond: () -> Bool, _ onEvent: ((GameEvent) -> Void)? = nil) -> Bool {
        for _ in 0..<Int(seconds * 60) {
            g.tick()
            g.drainEvents { onEvent?($0) }
            if cond() { return true }
        }
        return false
    }

    // ---------------------------------------------------------------- the plans

    func testBreakerRunPlan() {
        let t = MissionTemplate.breakerRun
        XCTAssertEqual(MissionTemplate.named("breaker-run")?.id, "breaker-run")
        XCTAssertEqual(t.name, .missionBreakerRun)
        let lv = t.level()
        XCTAssertEqual(lv.layout.props, .kelvin, "Kelvin-9 with its interactive props laid")
        XCTAssertEqual(lv.layout.overhead, .kelvinMk2, "the classic station's overhead: Mk II's routes (package R5)")
        let p = t.build(lv)
        XCTAssertEqual(p.id, "breaker-run")
        XCTAssertEqual(p.modifiers, [.dark])
        XCTAssertEqual(p.steps.map { $0.module }, [.switches, .hold, .extract])
        XCTAssertEqual(p.briefing, BannerText(title: .bannerBreakerRun, sub: .bannerBreakerRunSub))
        XCTAssertEqual(p.ringSiteCount, 0)
        XCTAssertEqual(p.switchCount, 4)
        XCTAssertTrue(p.ownStrip)
        guard case .switches(let s) = p.steps[0], case .hold(let h) = p.steps[1] else { return XCTFail("plan shape") }
        // the breakers of the beacon decks A, B, C (circuits 2, 4, 5) and (M1) the hub's (circuit 1): defended, contested rings
        let C = PropLayout.kelvin.circuits
        XCTAssertEqual(s.sites.map { Vec2($0.x, $0.z) }, [2, 4, 5, 1].map { Vec2(C[$0].x, C[$0].z) })
        XCTAssertTrue(s.sites.allSatisfy { $0.kind == .breaker && $0.time == BreakerRun.breakerTime && $0.radius == BREAKER_R })
        XCTAssertTrue(s.escalates)
        XCTAssertEqual(s.pushes, [0.3, 0.6, 0.85], "the hive pushes three times, the last from three sides")
        XCTAssertGreaterThan(s.drains, 0)
        XCTAssertEqual(s.contestedAt, BreakerRun.contestedAt)
        XCTAssertGreaterThan(s.contestedAt, 0)
        XCTAssertLessThan(s.contestedRate, 1)
        XCTAssertFalse(s.weldShut)
        XCTAssertEqual(s.workPourGap, 0)
        XCTAssertEqual(s.lineText, .objRestorePower)
        XCTAssertEqual(s.throwText, .objHoldBreaker)
        // the generator: a 4 m disc of open plaza deck (height −3), 60 s, relighting, no boss, no pulse
        guard case .circle(let gx, let gz, let gr) = h.zone else { return XCTFail("a deck zone") }
        XCTAssertEqual(gr, BreakerRun.zoneRadius)
        XCTAssertEqual(Vec2(gx, gz), Vec2(-3, -8), "on the plaza, clear of its crates")
        XCTAssertEqual(lv.groundY(gx, gz), -3, "on the plaza")
        // the whole zone is open deck (the crates, the pillars and the plaza breaker stay outside it)
        for r in stride(from: Float(0), through: gr, by: 0.5) {
            for k in 0..<24 {
                let a = Float(k) * TAU / 24
                XCTAssertTrue(lv.canStand(gx + cosf2(a) * r, gz + sinf2(a) * r), "open deck at \(r) m, \(k * 15)°")
            }
        }
        XCTAssertEqual(h.time, BreakerRun.holdTime)
        XCTAssertEqual(h.time, 90, "M1: a 90 s generator hold in stages")
        XCTAssertLessThan(h.stageMul.waves, HoldStep(zone: .lift, time: 1).stageMul.waves, "an open deck without the lift's pulse")
        XCTAssertTrue(h.relights)
        XCTAssertNil(h.boss)
        XCTAssertFalse(h.pulse)
        XCTAssertEqual(h.holdText, .objHoldGenerator)
        XCTAssertEqual(h.hordeSub, .bannerHordeSub, "a deck hold's hordes are not «climbing onto the platform»")
        XCTAssertEqual(p.tierStream, BreakerRun.tierStream)
    }

    func testVentPurgePlan() {
        let t = MissionTemplate.ventPurge
        XCTAssertEqual(MissionTemplate.named("vent-purge")?.name, .missionVentPurge)
        let lv = t.level()
        let p = t.build(lv)
        XCTAssertEqual(p.modifiers, [])
        XCTAssertEqual(p.steps.map { $0.module }, [.switches, .hold, .extract])
        XCTAssertEqual(p.switchCount, 4)
        guard case .switches(let s) = p.steps[0], case .hold(let h) = p.steps[1] else { return XCTFail("plan shape") }
        // the seals: under the overhead's three duct mouths (over the pad → hub bridge, over the hub → A walkway, on the plaza
        // gantry), then beacon A's deck vent (Kelvin-9's vent 0)
        guard let G = lv.overhead else { return XCTFail("Mk II's routes") }
        XCTAssertEqual(G.ducts, [KelvinMk2.bridgeDuct, KelvinMk2.hubDuct, KelvinMk2.plazaDuct])
        XCTAssertEqual(s.sites.map { $0.duct }, [0, 1, 2, -1])
        XCTAssertEqual(s.sites.map { $0.vent }, [-1, -1, -1, 0])
        for w in s.sites {
            XCTAssertEqual(w.kind, .seal)
            XCTAssertTrue(lv.walkable(w.x, w.z))
            if w.duct >= 0 {
                let m = G.nodePos(G.ducts[w.duct])
                XCTAssertLessThan(hypotf2(w.x - m.x, w.z - m.z), 6, "the ring on the deck under its duct mouth")
            } else {
                XCTAssertEqual(Vec2(w.x, w.z), lv.layout.vents[w.vent], "the ring stands on its vent")
            }
        }
        for (a, b) in [(0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3)] {
            XCTAssertGreaterThan(hypotf2(s.sites[a].x - s.sites[b].x, s.sites[a].z - s.sites[b].z), 8, "rings apart")
        }
        XCTAssertNotNil(s.pour)
        XCTAssertGreaterThan(s.thins, 0)
        // M1: the seal being worked pours too; a duct mouth is held shut (its weld waits for the grille shot shut, which the
        // hive chews through in `ductShut` s); the line while it waits
        XCTAssertTrue(s.sites.allSatisfy { $0.time == VentPurge.sealTime })
        XCTAssertEqual(s.workPourGap, VentPurge.workPourGap)
        XCTAssertGreaterThan(s.workPourGap, 0)
        XCTAssertEqual(s.ductShut, VentPurge.ductShut)
        XCTAssertLessThan(s.ductShut, DUCT_SHUT)
        XCTAssertTrue(s.weldShut)
        XCTAssertEqual(s.shutText, .objShutDuct)
        XCTAssertEqual(s.pushes.count, 2)
        XCTAssertEqual(s.lineText, .objSealVents)
        XCTAssertEqual(s.doneToast, .toastVentSealed)
        XCTAssertEqual(h.zone, .lift)
        XCTAssertTrue(h.pulse)
        XCTAssertNil(h.boss)
        XCTAssertEqual(h.time, VentPurge.holdTime)
        XCTAssertEqual(h.hordeK, VentPurge.hordeK)
        XCTAssertEqual(h.hordeSub, .bannerHordeLiftSub)
        // every template id is unique; the playable missions are the classic, R7's two, the Manifold (Stage 2 B4) and Dig In (D1)
        XCTAssertEqual(MissionTemplate.playable.map { $0.id }, ["cold-light", "breaker-run", "vent-purge", "manifold", "dig-in"])
        XCTAssertEqual(Set(MissionTemplate.all.map { $0.id }).count, MissionTemplate.all.count)
        XCTAssertNil(MissionTemplate.coldLight.station, "the classic plays the station it is given")
    }

    // ---------------------------------------------------------------- Breaker Run: darkness, breakers, the generator

    func testBreakerRunTakesTheLightBackDeckByDeck() {
        let g = missionGame(.breakerRun, seed: 21, god: true)
        XCTAssertTrue(g.circuits.allSatisfy { !$0.powered }, "the hive cut the main power")
        XCTAssertEqual(g.lightsLit, 0)
        var restored: [Int] = [], duringHold: [(Int, Float)] = []
        var holdStart: Float = -1
        run(g, seconds: 600, until: { g.phase != .playing }) { e in
            switch e {
            case .circuitRestored(let k):
                restored.append(k)
                if g.holdActive { duringHold.append((k, 1 - g.liftT / g.liftDur)) }
            case .holdStarted: holdStart = g.time
            default: break
            }
        }
        XCTAssertEqual(g.phase, .won, g.debugState.description)
        XCTAssertGreaterThan(holdStart, 0)
        // the four breaker switches brought A, B, C and the hub back (each the moment its ring filled)
        for c in [2, 4, 5, 1] { XCTAssertTrue(restored.contains(c), "circuit \(c) restored by its breaker") }
        // the generator brought the rest back in stages over the hold, nearest to it first, the last before it ran out
        XCTAssertFalse(duringHold.isEmpty)
        let fr = duringHold.map { $0.1 }
        XCTAssertEqual(fr, fr.sorted(), "one stage after another")
        XCTAssertLessThan(fr.last ?? 1, 0.95)
        XCTAssertTrue(g.circuits.allSatisfy { $0.powered }, "the whole station has power at the end")
        XCTAssertEqual(g.switchesThrown, 4)
        XCTAssertEqual(g.beaconsDone, 4, "each breaker is an escalation step")
        XCTAssertTrue(g.beacons.allSatisfy { $0.state == 0 }, "no beacon in this plan")
    }

    func testTheGeneratorStagesFollowTheCountdown() {
        // a plan of the generator hold alone, every circuit dark: n circuits come back at 1/(n+1) … n/(n+1) of the hold
        let lv = MissionTemplate.breakerRun.level()
        guard case .hold(let h0) = BreakerRun.plan(lv).steps[1] else { return XCTFail() }
        var h = h0
        h.time = 16
        h.openHorde = PacingValue(legacy: 0, waves: 0)
        let plan = MissionPlan(id: "gen", steps: [.hold(h), .extract(ExtractStep())], modifiers: [.dark])
        var c = GameConfig()
        c.difficulty = .recruit; c.god = true; c.mission = .custom(plan)
        let g = Game(seed: 3, playerClass: .assault, config: c, level: lv)
        g.directorEnabled = true
        g.debugSkip()   // the squad into the zone: the hold starts
        XCTAssertTrue(g.holdActive)
        XCTAssertEqual(g.relightQueue.count, 7)
        // nearest to the generator first: the plaza's own circuit (3)
        XCTAssertEqual(g.relightQueue.first, 3)
        var at: [Float] = []
        run(g, seconds: 30, until: { !g.holdActive }) { e in if case .circuitRestored = e { at.append(1 - g.liftT / g.liftDur) } }
        XCTAssertEqual(at.count, 7)
        for (k, f) in at.enumerated() { XCTAssertEqual(f, Float(k + 1) / 8, accuracy: 0.02, "stage \(k)") }
        XCTAssertEqual(g.lightsLit, 7)
    }

    // ---------------------------------------------------------------- Vent Purge: seals, pours, the stream

    func testVentPurgeSealsShutTheDuctsAndVentsAndThinTheStream() {
        let g = missionGame(.ventPurge, tier: .veteran, seed: 5, god: true)
        let sites = MissionTemplate.ventPurge.build(g.level).steps.compactMap { s -> [SwitchSite]? in
            if case .switches(let w) = s { return w.sites }
            return nil
        }.first!
        let vents = sites.filter { $0.vent >= 0 }.map { $0.vent }, ducts = sites.filter { $0.duct >= 0 }.map { $0.duct }
        XCTAssertEqual(vents, [0])
        XCTAssertEqual(ducts, [0, 1, 2])
        XCTAssertEqual(g.streamK, VentPurge.tierStream[1], "Veteran's stream of this mission")
        XCTAssertEqual(g.ventShut, [Bool](repeating: false, count: 8))
        XCTAssertTrue(g.ducts.allSatisfy { $0.open })
        var pours: [Int] = [], sealed: [Int] = [], ductsShut: Set<Int> = []
        var shutAtPour: [Bool] = []
        run(g, seconds: 600, until: { g.phase != .playing }) { e in
            switch e {
            case .ventPour(let k, let n):
                pours.append(k); shutAtPour.append(g.ventShut[k])
                XCTAssertGreaterThan(n, 0)
            case .ventSealed(let k): sealed.append(k)
            case .ductSealed(let d): ductsShut.insert(d)
            default: break
            }
        }
        XCTAssertEqual(g.phase, .won, g.debugState.description)
        XCTAssertEqual(g.switchesThrown, 4)
        XCTAssertEqual(sealed, vents, "the vent seal shut its own vent")
        XCTAssertEqual(ductsShut, Set(ducts), "the duct seals slammed their mouths")
        for d in ducts {
            XCTAssertFalse(g.ducts[d].open)
            XCTAssertEqual(g.ducts[d].shutT, .infinity, "duct mouth \(d) sealed for good")
        }
        XCTAssertFalse(pours.isEmpty, "the open vent poured packs")
        XCTAssertTrue(pours.allSatisfy { vents.contains($0) }, "only the seals' vents pour")
        XCTAssertFalse(shutAtPour.contains(true), "a shut vent never pours")
        XCTAssertEqual(g.streamK, VentPurge.tierStream[1] * powf(0.9, 4), accuracy: 1e-5, "each seal thins the stream by 10 %")
        for k in vents { XCTAssertTrue(g.ventShut[k]) }
        XCTAssertEqual(g.ventShut.filter { $0 }.count, vents.count, "the station's other vents stay open")
    }

    func testVentPurgeSealsTheOverheadsDuctMouthsForGood() {
        // a station with an overhead duct mouth (R2's slice: the mouth 3 m out over the void off the pad → hub bridge, R4's
        // duct): the first seal stands on the deck under it, three vents make the four
        let lv = Level(source: KelvinStation(overhead: .kelvinSlice, props: .kelvin), seed: 1)
        let seals = VentPurge.seals(lv)
        XCTAssertEqual(seals.count, 4)
        XCTAssertEqual(seals[0].duct, 0)
        XCTAssertEqual(seals[0].vent, -1)
        XCTAssertTrue(lv.canStand(seals[0].x, seals[0].z))
        XCTAssertLessThan(hypotf2(seals[0].x - 19, seals[0].z - 23.4), 6.5, "under the mouth")
        XCTAssertEqual(seals.dropFirst().map { $0.vent }, [0, 3, 5])
        // a station without routes (the v1.0 layout with R6's props): the vents of beacon A's, B's and C's decks and the plaza
        let bare = VentPurge.seals(Level(source: KelvinStation(props: .kelvin), seed: 1))
        XCTAssertEqual(bare.map { $0.vent }, [0, 3, 5, 6])
        XCTAssertEqual(bare.map { $0.duct }, [-1, -1, -1, -1])
        var c = GameConfig()
        c.difficulty = .veteran; c.god = true; c.mission = .ventPurge
        // (the tier's own overhead channels shut: every pack up there is the duct's pour)
        c.difficulty.routes = 0; c.difficulty.dropperGap = 0; c.difficulty.perchGap = 0
        let g = Game(seed: 5, playerClass: .assault, config: c, level: lv)
        XCTAssertEqual(g.ducts.count, 1)
        XCTAssertTrue(g.ducts[0].open)
        // the open duct mouth pours onto the routes (the overhead's own queue, R4's rattle first)
        var rattles = 0
        run(g, seconds: 200, until: { g.overheadStats.packs > 0 && rattles > 0 }) { e in if case .ductRattle = e { rattles += 1 } }
        XCTAssertGreaterThan(g.overheadStats.packs, 0, "a pour climbed out of the duct mouth")
        XCTAssertGreaterThan(rattles, 0, "its grille rattled first")
        // the squad steps in (M1): the weld waits for the grille shot shut — no weld while the mouth is open
        g.playerAlone(seals[0].x, seals[0].z)
        run(g, seconds: 2, until: { g.activeSwitch == 0 })
        XCTAssertEqual(g.activeSwitch, 0)
        if !g.ducts[0].open { run(g, seconds: DUCT_SHUT + 1, until: { g.ducts[0].open }) }
        XCTAssertTrue(g.weldWaits, "the weld waits for the grille shot shut")
        XCTAssertEqual(g.objective, GameText(.objShutDuct))
        let p0 = g.switches[0].progress
        g.step(60 * 3)
        XCTAssertEqual(g.switches[0].progress, p0, "no weld, no drain, while the mouth is open and the squad holds the ring")
        // shot shut: shut for `ductShut` s only (the hive chews through fast where it pushes), and the weld fills
        XCTAssertTrue(g.debugHurtDuct(0, DUCT_HP + 1))
        XCTAssertEqual(g.ducts[0].shutT, VentPurge.ductShut, accuracy: 0.05)
        XCTAssertFalse(g.weldWaits)
        XCTAssertEqual(g.objective, GameText(.objHoldSeal))
        g.step(60 * 2)
        XCTAssertGreaterThan(g.switches[0].progress, p0 + 1.5 / VentPurge.sealTime)
        // the hive chews through: the weld waits once more
        run(g, seconds: VentPurge.ductShut, until: { g.ducts[0].open })
        XCTAssertTrue(g.ducts[0].open)
        XCTAssertTrue(g.weldWaits)
        // shut again and the weld nearly full: thrown — the mouth sealed for good
        XCTAssertTrue(g.debugHurtDuct(0, DUCT_HP + 1))
        g.clearEvents()
        g.debugSwitchProgress(0.99)
        var sealed = 0
        run(g, seconds: 2, until: { g.switches[0].state == 2 }) { e in if case .ductSealed(let d) = e, d == 0 { sealed += 1 } }
        XCTAssertEqual(g.switches[0].state, 2)
        XCTAssertEqual(sealed, 1)
        XCTAssertFalse(g.ducts[0].open)
        XCTAssertEqual(g.ducts[0].shutT, .infinity)
        g.step(60 * 90)   // (R4's shot grille opens after 45 s; a seal never)
        XCTAssertFalse(g.ducts[0].open, "sealed for good")
    }

    func testAShutVentTakesNoPack() {
        let g = missionGame(.ventPurge, seed: 9, god: true)
        for k in 0..<g.ventShut.count { g.sealVent(k) }
        let c = Vec2(-9, 8)   // the hub → plaza stairs: the plaza's vent at (−9, −1) 9 m away
        for _ in 0..<400 { g.pack(3, near: c, dmin: 9, dmax: 24, rate: 4) }
        XCTAssertFalse(g.queue.contains { $0.vent != nil }, "every vent is shut: the packs come over the rails")
        let h = missionGame(.ventPurge, seed: 9, god: true)
        for _ in 0..<400 { h.pack(3, near: c, dmin: 9, dmax: 24, rate: 4) }
        XCTAssertTrue(h.queue.contains { $0.vent != nil }, "open vents take some")
    }

    // ---------------------------------------------------------------- the defended switch ring

    func testASwitchRingDrainsAndTheHivePushes() {
        var s = SwitchStep(sites: [SwitchSite(x: 30, z: 26, radius: 2.2, time: 4, kind: .panel)])
        s.alarm = PacingValue(legacy: 10, waves: 10)
        s.pushes = [0.5]
        s.drains = 1
        let plan = MissionPlan(id: "push", steps: [.switches(s), .extract(ExtractStep())])
        var c = GameConfig()
        c.difficulty = .recruit; c.god = true; c.mission = .custom(plan)
        let g = Game(seed: 4, playerClass: .assault, config: c)
        g.playerAlone(30, 26)
        g.step(60)   // 1 s in the ring: a quarter
        XCTAssertEqual(g.activeSwitch, 0)
        XCTAssertEqual(g.switches[0].progress, 0.25, accuracy: 0.02)
        g.playerAlone(30, 33)   // out of the ring: it drains at the fill rate
        g.step(30)
        XCTAssertEqual(g.switches[0].progress, 0.125, accuracy: 0.02)
        XCTAssertEqual(g.switches[0].pushes, 0)
        g.playerAlone(30, 26)
        g.step(120)
        XCTAssertGreaterThan(g.switches[0].progress, 0.5)
        XCTAssertEqual(g.switches[0].pushes, 1, "the hive pushed at half")
        g.step(120)
        XCTAssertEqual(g.currentModule, .extract)
    }

    func testTheMissionsHints() {
        // a draining switch ring the player left: «back in the ring»
        var s = SwitchStep(sites: [SwitchSite(x: 30, z: 26, radius: 2.2, time: 20, kind: .panel)])
        s.alarm = PacingValue(legacy: 0, waves: 0)
        s.drains = 0.5
        var c = GameConfig()
        c.difficulty = .recruit; c.god = true; c.mission = .custom(MissionPlan(id: "hint", steps: [.switches(s), .extract(ExtractStep())]))
        let g = Game(seed: 6, playerClass: .assault, config: c)
        g.playerAlone(30, 33)
        g.step(60 * 8)   // (the game's own hints start 7 s in)
        XCTAssertNil(g.contextHint)
        g.playerAlone(30, 26)
        g.step(30)
        XCTAssertEqual(g.activeSwitch, 0)
        XCTAssertNil(g.contextHint)
        g.playerAlone(30, 33)
        g.step(2)
        XCTAssertEqual(g.contextHint, HintLine(text: GameText(.hintBackToSwitch), urgent: true))
        // Breaker Run's generator: the player out of its zone during the hold
        let lv = MissionTemplate.breakerRun.level()
        guard case .hold(let h) = BreakerRun.plan(lv).steps[1] else { return XCTFail() }
        XCTAssertEqual(h.outHint, .hintBackToGenerator)
        var c2 = GameConfig()
        c2.difficulty = .recruit; c2.god = true; c2.mission = .custom(MissionPlan(id: "gen", steps: [.hold(h), .extract(ExtractStep())]))
        let q = Game(seed: 6, playerClass: .assault, config: c2, level: lv)
        q.debugSkip()
        q.step(60 * 8)
        XCTAssertTrue(q.holdActive)
        XCTAssertNil(q.contextHint)
        q.place(0, 10, -5)   // on the plaza's east side, out of the zone
        q.step(1)
        XCTAssertEqual(q.contextHint, HintLine(text: GameText(.hintBackToGenerator), urgent: true))
        // the lift hold keeps its own hints and no zone hint (the classic)
        XCTAssertNil(HoldStep(zone: .lift, time: 10).outHint)
    }

    // ---------------------------------------------------------------- M1: the beats that ask more

    func testAContestedSwitchRingFillsSlowerWhileBugsCrowdIt() {
        var s = SwitchStep(sites: [SwitchSite(x: 30, z: 26, radius: BREAKER_R, time: 10, kind: .panel)])
        s.alarm = PacingValue(legacy: 0, waves: 0)
        s.drains = 0.5
        s.contestedAt = 2
        var c = GameConfig()
        c.difficulty = .recruit; c.god = true; c.mission = .custom(MissionPlan(id: "crowd", steps: [.switches(s), .extract(ExtractStep())]))
        let g = Game(seed: 4, playerClass: .assault, config: c)
        g.calm = true   // (no trickle, no hordes: the only bugs are the test's)
        g.playerAlone(30, 31)
        g.step(60 * 8)   // (the game's own hints start 7 s in)
        g.playerAlone(30, 26)
        g.step(60)   // 1 s: a tenth
        XCTAssertEqual(g.activeSwitch, 0)
        XCTAssertEqual(g.switches[0].progress, 0.1, accuracy: 0.02)
        XCTAssertFalse(g.switches[0].contested)
        XCTAssertNil(g.contextHint)
        // three runners in the ring: contested — it fills at `contestedRate`, the hint says «Clear the ring»
        XCTAssertEqual(g.debugSpawnLine(3, type: .runner, from: Vec2(29.3, 26.5), to: Vec2(30.7, 26.5)), 3)
        g.step(2)
        XCTAssertTrue(g.switches[0].contested)
        XCTAssertEqual(g.contextHint, HintLine(text: GameText(.hintRingContested), urgent: true))
        let p1 = g.switches[0].progress
        g.step(60)
        XCTAssertEqual(g.switches[0].progress - p1, 0.1 * s.contestedRate, accuracy: 0.01)
        // cleared: the full rate again
        for i in 0..<g.bugs.count where g.bugs.dead[i] == 0 { g.killBug(i, 0) }
        g.step(2)
        XCTAssertFalse(g.switches[0].contested)
        let p2 = g.switches[0].progress
        g.step(60)
        XCTAssertEqual(g.switches[0].progress - p2, 0.1, accuracy: 0.01)
        // (off by default: the drills and every other switch fill whatever stands in the ring)
        XCTAssertEqual(SwitchStep(sites: []).contestedAt, 0)
        XCTAssertEqual(DrillSpots(MissionTemplate.breakerRun.level()).switchStep.contestedAt, 0)
    }

    func testTheSealBeingWorkedPours() {
        // a vent seal whose only pours are the work pour: it pours while worked, every `workPourGap` s (± 1 s), never sealed
        let lv = Level(source: KelvinStation(props: .kelvin), seed: 1)
        let v = 0, p = lv.layout.vents[v]
        var s = SwitchStep(sites: [SwitchSite(x: p.x, z: p.y, radius: 2.2, time: 30, kind: .seal, vent: v)])
        s.alarm = PacingValue(legacy: 0, waves: 0)
        s.pour = PacingValue(legacy: 32, waves: 8)
        s.pourGap = 1000
        s.workPourGap = 5
        var c = GameConfig()
        c.difficulty = .recruit; c.god = true; c.mission = .custom(MissionPlan(id: "work", steps: [.switches(s), .extract(ExtractStep())]))
        let g = Game(seed: 6, playerClass: .assault, config: c, level: lv)
        g.calm = true
        g.playerAlone(p.x, p.y)
        var at: [Float] = []
        run(g, seconds: 21, until: { false }) { e in if case .ventPour(let k, let n) = e, k == v { at.append(g.time); XCTAssertGreaterThan(n, 0) } }
        XCTAssertEqual(g.activeSwitch, 0)
        XCTAssertGreaterThanOrEqual(at.count, 3, "it pours while it is worked")
        XCTAssertEqual(at.first ?? 0, 2.5, accuracy: 0.2, "the first half a gap in")
        for (a, b) in zip(at, at.dropFirst()) { XCTAssertEqual(b - a, 5, accuracy: 1.05) }
        g.debugSwitchProgress(0.99)
        run(g, seconds: 1, until: { g.switches[0].state == 2 })
        XCTAssertTrue(g.ventShut[v])
        let n = at.count
        run(g, seconds: 12, until: { false }) { e in if case .ventPour = e { at.append(g.time) } }
        XCTAssertEqual(at.count, n, "sealed: no more pours")
    }

    func testTheAutopilotHoldsTheDuctShutWhileItWelds() {
        // Vent Purge on Kelvin-9 Mk II: the squad by the seal under the hub → A duct mouth; the autopilot shoots the grille shut
        // whenever the hive chews through it, and the weld ends with the mouth sealed for good
        let g = missionGame(.ventPurge, tier: .veteran, seed: 7, god: true)
        guard let k = g.switches.firstIndex(where: { $0.site.duct == 1 }) else { return XCTFail("the hub → A seal") }
        let w = g.switches[k].site
        g.debugTeleport(w.x - 1, w.z)
        var shut = 0, opened = 0
        run(g, seconds: 150, until: { g.switches[k].state == 2 }) { e in
            if case .ductSealed(let d) = e, d == 1 { shut += 1 }
            if case .ductOpened(let d) = e, d == 1 { opened += 1 }
        }
        XCTAssertEqual(g.switches[k].state, 2, "the seal is welded on autopilot: \(g.debugState)")
        XCTAssertGreaterThanOrEqual(opened, 2, "the hive chewed through the grille while the weld ran")
        XCTAssertGreaterThanOrEqual(shut, opened + 1, "shot shut each time, then sealed for good")
        XCTAssertTrue(g.ducts[1].shutT.isInfinite)
    }

    func testThePlannedWorkFillsAFullLengthMission() {
        // design §3.4: a standard mission runs 6–9 min; the rings and holds alone — no travel, no fight, no contested or
        // waiting rings — take ≥ 5 min of both missions (the calibration's Veteran medians: 6–8 min)
        func work(_ p: MissionPlan) -> Float {
            var t: Float = 0
            for st in p.steps {
                switch st {
                case .switches(let w): t += w.sites.prefix(w.needed).reduce(0) { $0 + $1.time }
                case .hold(let h): t += h.time
                default: break
                }
            }
            return t
        }
        XCTAssertGreaterThanOrEqual(work(BreakerRun.plan(MissionTemplate.breakerRun.level())), 300)
        XCTAssertGreaterThanOrEqual(work(VentPurge.plan(MissionTemplate.ventPurge.level())), 300)
    }

    // ---------------------------------------------------------------- won on autopilot; the report

    func testBothMissionsPlayThroughOnAutopilot() {
        for (k, t) in MissionTemplate.missions.enumerated() {
            let cls = MarineClass.allCases[(k + 1) % 4]
            // (god mode: the flow end to end; the win rates are the calibration gate's — `--preset missions`)
            let g = missionGame(t, seed: 600 + UInt32(k), cls: cls, god: true)
            var modules: [MissionModule] = [g.mission.steps[0].module]
            var thrown = 0, holds = 0, rides = 0, banners: [TextID] = []
            run(g, seconds: 10 * 60, until: { g.phase != .playing }) { e in
                switch e {
                case .missionStep(let i, let m): XCTAssertEqual(i, modules.count, t.id); modules.append(m)
                case .switchThrown: thrown += 1
                case .holdStarted: holds += 1
                case .extractStarted: rides += 1
                case .banner(let title, _, _): banners.append(title.id)
                default: break
                }
            }
            XCTAssertEqual(g.phase, .won, "\(t.id) \(cls.id): \(g.debugState)")
            XCTAssertEqual(modules, [.switches, .hold, .extract], t.id)
            XCTAssertEqual(thrown, g.mission.switchCount, t.id)
            XCTAssertEqual(holds, 1, t.id)
            XCTAssertEqual(rides, 1, t.id)
            XCTAssertEqual(banners.first, g.mission.briefing?.title, "\(t.id): the drop banner first")
            if t.id == "breaker-run" {
                XCTAssertTrue(banners.contains(.bannerBreakersLive))
                XCTAssertTrue(banners.contains(.bannerGenerator))
            } else {
                XCTAssertTrue(banners.contains(.bannerLiftCalled))
            }
            // the report: the switch line instead of the beacons, the lights line, the plan's own strip
            let r = g.runSummary(won: true, surrendered: false)
            XCTAssertEqual(r.switchesDone, g.mission.switchCount)
            XCTAssertEqual(r.switchesTotal, g.mission.switchCount)
            let parts = RunScore.make(r).parts
            XCTAssertNil(parts.first { $0.label.id == .scoreBeacons }, "no beacons in this plan")
            let line = t.id == "breaker-run" ? TextID.scoreBreakers : .scoreVents
            let sp = parts.first { $0.label.id == line }
            XCTAssertEqual(sp?.label, GameText(line, [.int(g.mission.switchCount), .int(g.mission.switchCount)]))
            XCTAssertEqual(sp?.value, t.id == "breaker-run" ? 1500 : 1500)
            XCTAssertNotNil(parts.first { $0.label.id == .scoreLights })
            let strip = try! XCTUnwrap(r.strip)
            let want: [TextID] = t.id == "breaker-run"
                ? [.reportStripBreaker, .reportStripBreaker, .reportStripBreaker, .reportStripBreaker, .reportStripGenerator, .reportStripExtract]
                : [.reportStripVent, .reportStripVent, .reportStripVent, .reportStripVent, .reportStripLift, .reportStripExtract]
            XCTAssertEqual(strip.map { $0.label.id }, want)
            XCTAssertTrue(strip.allSatisfy { $0.on })
            var prof = Profile()
            let res = prof.commit(r, diffPicked: false)
            let rep = MissionReport.make(run: r, result: res, profile: prof, stats: g.stats, newStationShown: false)
            XCTAssertEqual(rep.strip, strip)
            XCTAssertTrue(rep.parts.contains { $0.label.id == line })
        }
    }

    func testALostRunsStripStopsWhereTheSquadDid() {
        let g = missionGame(.breakerRun, seed: 8, god: true)
        run(g, seconds: 300, until: { g.switchesThrown >= 2 })
        let strip = try! XCTUnwrap(g.runSummary(won: false, surrendered: true).strip)
        XCTAssertEqual(strip.map { $0.on }, [true, true, false, false, false, false])
    }

    // ---------------------------------------------------------------- calibration

    func testTheMissionsPresetIsTheMissionGate() {
        let runs = Calibration.preset("missions") ?? []
        // per mission: 8 runs per class on Recruit and Nightmare, 32 on Veteran (M1: its rate is the noisy one), one AFK run per
        // class on Veteran and Recruit
        XCTAssertEqual(runs.count, 2 * 4 * (8 + 32 + 8 + 2))
        XCTAssertEqual(Set(runs.map { $0.mission ?? "" }), ["breaker-run", "vent-purge"])
        XCTAssertEqual(runs.filter { $0.mode == .afk }.count, 16)
        XCTAssertEqual(Set(runs.map { "\($0.mission!) \($0.seed)" }).count, runs.count, "own seeds")
        XCTAssertEqual(Calibration.preset("breaker-run")?.count, 4 * (8 + 32 + 8 + 2))
        // the classic gate preset keeps its rows (calib.jsonl byte-identical): no mission joins it
        XCTAssertEqual(Calibration.preset("gate")!.count, 212)
        XCTAssertTrue(Calibration.preset("gate")!.allSatisfy { $0.mission == nil })
        XCTAssertTrue(MissionTemplate.missions.allSatisfy { $0.calib?.gated == true })
        XCTAssertTrue(MissionTemplate.drills.allSatisfy { $0.calib?.gated == false })
    }

    func testAMissionRowPlaysItsOwnStation() {
        let r = Calibration.run(CalibRun(tag: "breaker-run-rec", cls: .gunner, tier: 0, mode: .auto, maxs: 120, seed: 9, mission: "breaker-run"))
        XCTAssertNil(r.error)
        XCTAssertEqual(r.stageAt.first?.0, "breakers")
        XCTAssertEqual(r.props?.circuits, 7, "Kelvin-9 with its props")
        XCTAssertTrue(r.json.contains(#""mission":"breaker-run""#))
        let r2 = Calibration.run(CalibRun(tag: "breaker-run-rec", cls: .gunner, tier: 0, mode: .auto, maxs: 120, seed: 9, mission: "breaker-run"))
        XCTAssertEqual(r.json, r2.json, "deterministic")
    }

    func testTheMissionBandsAreTheClassicBands() {
        func row(_ m: String, _ tier: Int, _ mode: String = "auto", won: Bool, downs: Int = 0, pFirst: Float = -1) -> CalibRow {
            var r = CalibRow()
            r.mission = m; r.tierIx = tier; r.mode = mode; r.tag = m + "-" + Calibration.tierTag(tier)
            r.result = won ? "won" : "lost"; r.downs = [downs, 0, 0, 0]; r.pFirstDown = pFirst
            return r
        }
        var rows: [CalibRow] = []
        for m in ["breaker-run", "vent-purge"] {
            rows += (0..<10).map { _ in row(m, 0, won: true) }
            rows += (0..<10).map { k in row(m, 1, won: k < 8) }
            rows += (0..<10).map { k in row(m, 2, won: k < 2) }
            rows += [row(m, 1, "afk", won: false, pFirst: 90), row(m, 0, "afk", won: false, pFirst: 200)]
        }
        let (ok, lines) = Calibration.gate(rows)
        XCTAssertTrue(ok, lines.filter { !$0.ok }.map { $0.text }.joined(separator: "; "))
        XCTAssertTrue(lines.contains { $0.gated && $0.text.hasPrefix("breaker-run vet/auto wins 80.0%") })
        XCTAssertTrue(lines.contains { $0.gated && $0.text.hasPrefix("vent-purge rec/auto downs/run") })
        XCTAssertTrue(lines.contains { $0.gated && $0.text.hasPrefix("vent-purge vet/afk first player down") })
        // out of a band: gated failures
        var bad = rows
        bad += (0..<10).map { _ in row("breaker-run", 1, won: true) }   // Veteran 90 %
        XCTAssertFalse(Calibration.gate(bad).passed)
        var slow = rows
        slow.append(row("vent-purge", 0, "afk", won: false, pFirst: 300))   // a Recruit AFK player standing 300 s
        XCTAssertFalse(Calibration.gate(slow).passed)
        var downs = rows
        downs.append(row("vent-purge", 0, won: true, downs: 12))
        XCTAssertFalse(Calibration.gate(downs).passed, "Recruit ≤ 0.5 squad downs per run")
    }

    // ---------------------------------------------------------------- the classic mission untouched

    func testTheClassicMissionIsUntouched() {
        let g = Game(seed: 1, playerClass: .assault)
        XCTAssertEqual(g.streamK, 1)
        XCTAssertEqual(g.ventShut, [Bool](repeating: false, count: g.level.layout.vents.count))
        XCTAssertFalse(g.mission.ownStrip)
        XCTAssertNil(g.mission.tierStream)
        let r = g.runSummary(won: false, surrendered: false)
        XCTAssertNil(r.strip, "the classic report strip")
        XCTAssertNil(r.switchLine)
        XCTAssertNotNil(RunScore.make(r).parts.first { $0.label.id == .scoreBeacons })
        // the classic plan's hold keeps the lift's horde subtitle
        guard case .hold(let h) = g.mission.steps[1] else { return XCTFail() }
        XCTAssertEqual(h.hordeSub, .bannerHordeLiftSub)
        XCTAssertEqual(h.hordeK, 1)
        XCTAssertFalse(h.relights)
    }
}
