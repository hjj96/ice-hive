import XCTest
@testable import IceHiveCore

/// Stage 2 D1 «Dig In» (DigIn.swift, GameHoldout.swift): an endless hold at the lift fought in waves — the plan and its
/// station, the waves and their escalation, the Queen's own arrival rule (she leads every fifth wave), the bank and the fall
/// (a banked score survives it), the report and the profile's best, the HUD lines, the calibration preset, rows and gate; the
/// hold never stalls or goes non-finite in a long run, and it is deterministic.
final class DigInTests: XCTestCase {

    /// Tick until `cond` (max `seconds`), handing every event to `onEvent`. Returns whether `cond` came true.
    @discardableResult
    func run(_ g: Game, seconds: Float, until cond: () -> Bool = { false }, _ onEvent: ((GameEvent) -> Void)? = nil) -> Bool {
        for _ in 0..<Int(seconds * 60) {
            g.tick()
            g.drainEvents { onEvent?($0) }
            if cond() { return true }
            if g.phase != .playing { return false }
        }
        return false
    }

    /// A Dig In run (the squad on the lift: its first tick starts the hold).
    func digIn(_ tier: Difficulty = .veteran, seed: UInt32 = 17, cls: MarineClass = .assault, autopilot: Bool = true, god: Bool = true) -> Game {
        let g = missionGame(.digIn, tier: tier, seed: seed, cls: cls, autopilot: autopilot, god: god)
        g.tick()
        g.clearEvents()
        return g
    }

    // ---------------------------------------------------------------- the template

    func testPlanStationAndPreset() throws {
        let t = MissionTemplate.digIn
        XCTAssertEqual(t.id, "dig-in")
        XCTAssertEqual(t.name, TextID.missionDigIn)
        XCTAssertTrue(MissionTemplate.playable.contains { $0.id == "dig-in" })
        XCTAssertEqual(MissionTemplate.named("dig-in")?.id, "dig-in")
        let lv = t.level(seed: 3)
        // Kelvin-9 Mk II (the overhead's routes, the props), the squad set down on the lift's deck
        XCTAssertEqual(lv.layout.name, .kelvin)
        XCTAssertNotNil(lv.overhead)
        XCTAssertFalse(lv.layout.props.circuits.isEmpty)
        XCTAssertTrue(lv.onLift(lv.start.x, lv.start.y))
        let plan = t.build(lv)
        XCTAssertEqual(plan.id, "dig-in")
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.briefing, BannerText(title: .bannerDigIn, sub: .bannerDigInSub))
        guard case .hold(let h) = plan.steps[0] else { return XCTFail("one HOLD") }
        XCTAssertEqual(h.zone, .lift)
        XCTAssertEqual(h.time, .infinity)
        XCTAssertTrue(h.pulse)
        XCTAssertNotNil(h.waves)
        XCTAssertNil(h.callBanner); XCTAssertNil(h.holdBanner)
        XCTAssertEqual(h.openHorde.waves, 0)
        let q = try XCTUnwrap(h.boss)
        XCTAssertEqual(q.kind, .queen)
        XCTAssertFalse(q.locks)
        XCTAssertEqual(q.arrival, .waves(first: DigIn.queenFirst, every: DigIn.queenEvery))
        // no other template holds out
        for o in MissionTemplate.all where o.id != t.id {
            for s in o.build(o.level(seed: 3)).steps { if case .hold(let oh) = s { XCTAssertNil(oh.waves, o.id) } }
        }
        // its own gated preset (`holdout`): the missions' and the bosses' presets keep their rows
        let c = try XCTUnwrap(t.calib)
        XCTAssertTrue(c.gated)
        XCTAssertEqual(c.preset, "holdout")
        XCTAssertEqual(c.maxs, DigIn.calibMaxs)
        XCTAssertTrue(Calibration.presetNames.contains("holdout"))
        let runs = try XCTUnwrap(Calibration.preset("holdout"))
        XCTAssertEqual(runs.count, 8 * 4 + 16 * 4 + 8 * 4 + 4 + 4)
        XCTAssertTrue(runs.allSatisfy { $0.mission == "dig-in" })
        XCTAssertTrue(runs.filter { $0.mode == .auto }.allSatisfy { $0.maxs == DigIn.calibMaxs })
        XCTAssertTrue(runs.filter { $0.mode == .afk }.allSatisfy { $0.maxs == 420 })
        XCTAssertEqual(Set(runs.map { $0.seed }).count, runs.count)
        XCTAssertEqual(runs.first?.tag, "dig-in-rec")
        XCTAssertEqual(Calibration.preset("missions")?.count, 400)
        XCTAssertFalse(Calibration.preset("missions")!.contains { $0.mission == "dig-in" })
        XCTAssertEqual(Calibration.preset("bosses")?.count, 136)
        XCTAssertEqual(Calibration.preset("gate")?.count, 212)
        // a tuning batch's tag
        XCTAssertEqual(Calibration.preset("holdout", tag: "h12")?.first?.tag, "h12-dig-in-rec")
    }

    // ---------------------------------------------------------------- the waves

    func testTheHoldStartsOnTheLiftAndTheWavesEscalate() {
        let g = digIn(.veteran, seed: 17)
        let D = Difficulty.veteran, w = DigIn.waves
        XCTAssertEqual(g.stepPhase, .active, "the squad starts on the lift: the hold starts on the first tick")
        XCTAssertEqual(g.stage, .hold)
        XCTAssertEqual(g.liftT, .infinity)
        XCTAssertEqual(g.holdout.wave, 1)
        XCTAssertEqual(g.holdout.phase, .build)
        XCTAssertEqual(g.objective, GameText(.objDigIn, [.int(1)]))
        let key1 = g.objectiveKey
        var peaks: [(wave: Int, horde: Int)] = [], held: [Int] = [], hordes = 0
        run(g, seconds: 300, until: { g.holdout.held >= 4 }) { e in
            if case .holdoutWave(let n, let queen) = e { XCTAssertFalse(queen); peaks.append((n, g.holdout.horde)) }
            if case .holdoutHeld(let n) = e { held.append(n) }
            if case .hordeStarted(_, let title, _) = e { hordes += 1; XCTAssertEqual(title.id, .bannerWave) }
        }
        XCTAssertEqual(held, [1, 2, 3, 4])
        XCTAssertEqual(peaks.map { $0.wave }, [1, 2, 3, 4])
        guard peaks.count == 4 else { return XCTFail("four peaks: \(peaks)") }
        XCTAssertEqual(hordes, 4, "each wave's peak is one horde, with its banner")
        // each wave's horde is bigger than the last: base + grow × (n − 1), × the tier's horde and population scale
        XCTAssertEqual(Float(peaks[0].horde), w.horde(1, queen: false) * D.horde * D.popK, accuracy: 1.5)
        for k in 1..<peaks.count { XCTAssertGreaterThan(peaks[k].horde, peaks[k - 1].horde) }
        XCTAssertGreaterThan(w.horde(9, queen: false), w.horde(4, queen: false))
        XCTAssertEqual(w.horde(5, queen: true), w.horde(5, queen: false) * w.queenHordeK)
        // every wave held is an escalation step of the director: bug health climbs with the waves
        XCTAssertEqual(g.beaconsDone, 4)
        XCTAssertGreaterThan(g.hpMul, D.hp * 1.24)
        // the lull: the wave held, the next one regroups; the objective changed with it
        XCTAssertEqual(g.holdout.phase, .lull)
        XCTAssertEqual(g.holdout.wave, 5)
        XCTAssertEqual(g.objective, GameText(.objDigInHeld, [.int(4)]))
        XCTAssertNotEqual(g.objectiveKey, key1)
        XCTAssertEqual(g.objectiveProgress, 0.8, accuracy: 0.001, "four of the five waves to the first bank")
        XCTAssertEqual(g.holdProgress, 0.8, accuracy: 0.001)
        XCTAssertEqual(g.holdout.banked, 0, "nothing banked before wave 5")
        // the next wave builds, then it banks: its own line
        run(g, seconds: 20, until: { g.holdout.phase == .build })
        XCTAssertEqual(g.objective, GameText(.objDigInBank, [.int(5)]))
    }

    // ---------------------------------------------------------------- the Queen's arrival rule

    func testTheQueenLeadsEveryFifthWave() {
        let g = digIn(.veteran, seed: 23, cls: .gunner)
        XCTAssertTrue(Game.queenLeads(5, first: 5, every: 5) && Game.queenLeads(15, first: 5, every: 5))
        for n in [5, 10, 15, 20] { XCTAssertTrue(g.holdoutQueenLeads(n), "wave \(n)") }
        for n in [1, 2, 3, 4, 6, 7, 9, 11, 14, 16] { XCTAssertFalse(g.holdoutQueenLeads(n), "wave \(n)") }
        var warns: [Int] = []
        func watch(_ e: GameEvent) { if case .bossWarning = e { warns.append(g.holdout.wave) } }
        // wave 4: no Queen at its peak
        g.debugHoldoutWave(4)
        run(g, seconds: 6, watch)
        XCTAssertTrue(warns.isEmpty)
        XCTAssertFalse(g.boss.spawned)
        g.debugSkip()
        XCTAssertEqual(g.holdout.held, 4)
        // wave 5: her warning as its horde comes, then her (2 s); the horde is the smaller one, the banner says she leads it
        var peak: (Int, Bool)? = nil, sub: GameText? = nil
        run(g, seconds: 30, until: { g.boss.alive }) { e in
            watch(e)
            if case .holdoutWave(let n, let q) = e { peak = (n, q) }
            if case .hordeStarted(_, let title, let s) = e, title.id == .bannerWave { sub = s }
        }
        XCTAssertEqual(peak?.0, 5); XCTAssertEqual(peak?.1, true)
        XCTAssertEqual(sub, GameText(.bannerWaveQueenSub))
        XCTAssertEqual(warns, [5])
        XCTAssertTrue(g.boss.alive)
        XCTAssertEqual(g.boss.arrivals, 1)
        XCTAssertEqual(g.bossSpec.banner?.sub, TextID.bannerQueenWaveSub, "her own banners in a holdout")
        XCTAssertEqual(g.bossSpec.deathBanner?.sub, TextID.bannerQueenWaveDeadSub)
        XCTAssertEqual(g.threatState, .boss)
        XCTAssertEqual(g.objective, GameText(.objDigInQueen))
        // the wave is not held while she lives
        run(g, seconds: 2)
        if g.boss.alive { XCTAssertEqual(g.holdout.held, 4) }
        // she dies: her death counts once, the wave is held (the swarm down, or 8 s after her), the score banks
        if g.boss.alive { g.killBug(g.bossSlotNow(), 0) }
        var banked: (Int, Int)? = nil
        run(g, seconds: 20, until: { g.holdout.held >= 5 }) { e in if case .holdoutBanked(let n, let s) = e { banked = (n, s) } }
        XCTAssertEqual(g.holdout.held, 5)
        XCTAssertEqual(g.holdout.queensKilled, 1)
        XCTAssertEqual(banked?.0, 5)
        XCTAssertEqual(g.holdout.bankWave, 5)
        XCTAssertTrue(g.boss.done, "until her next wave the report and calibration see her dead")
        // waves 6–9: no Queen; wave 10: a fresh one (full health), her arrivals counted on
        g.debugHoldoutWave(10)
        XCTAssertEqual(g.holdout.held, 9)
        run(g, seconds: 6, until: { g.boss.alive }, watch)
        XCTAssertEqual(warns, [5, 10])
        XCTAssertTrue(g.boss.alive)
        XCTAssertEqual(g.boss.arrivals, 2)
        XCTAssertEqual(g.boss.hpFraction, 1, accuracy: 0.001)
        XCTAssertEqual(g.holdout.queensKilled, 1)
        // the hold never locks and never ends while she lives
        XCTAssertFalse(g.liftLocked)
        XCTAssertEqual(g.phase, .playing)
    }

    // ---------------------------------------------------------------- the bank and the fall

    func testABankedScoreSurvivesTheFall() throws {
        let g = digIn(.veteran, seed: 19, cls: .cryo)
        let w = DigIn.waves
        // waves 1–4 held: nothing banked yet
        for _ in 0..<4 { g.debugSkip() }
        XCTAssertEqual(g.holdout.held, 4)
        XCTAssertEqual(g.holdout.banked, 0)
        XCTAssertEqual(g.holdout.banks, 0)
        // wave 5: the Queen comes; the wave held (she dies first) banks the score — the kills, five waves, the Queen
        g.debugHoldoutWave(5)
        run(g, seconds: 10, until: { g.boss.alive })
        XCTAssertTrue(g.boss.alive)
        g.debugSkip()
        var bank: (Int, Int)? = nil
        g.drainEvents { e in if case .holdoutBanked(let n, let s) = e { bank = (n, s) } }
        let expected = g.playerKills + 5 * w.waveScore + w.queenScore
        XCTAssertEqual(g.holdout.held, 5)
        XCTAssertEqual(g.holdout.queensKilled, 1)
        XCTAssertEqual(g.holdout.banked, expected)
        XCTAssertEqual(g.holdout.bankWave, 5)
        XCTAssertEqual(g.holdout.banks, 1)
        XCTAssertEqual(bank?.0, 5); XCTAssertEqual(bank?.1, expected)
        XCTAssertEqual(g.holdoutProgress, 0, accuracy: 0.001)
        // a sixth wave held: more score, not banked
        g.debugSkip()
        XCTAssertEqual(g.holdout.held, 6)
        XCTAssertGreaterThan(g.holdoutScore, g.holdout.banked)
        // the squad falls: the mission is lost (never won), the bank stays
        g.godMode = false
        for k in 0..<4 { g.debugHurt(marine: k, hp: 0) }
        g.tick()
        XCTAssertEqual(g.phase, .lost)
        XCTAssertEqual(g.holdout.banked, expected)
        let summary = g.runSummary(won: false, surrendered: false)
        let h = try XCTUnwrap(summary.holdout)
        XCTAssertEqual(h.held, 6); XCTAssertEqual(h.banked, expected); XCTAssertEqual(h.bankWave, 5); XCTAssertEqual(h.queens, 1)
        XCTAssertEqual(h.earned, g.holdoutScore)
        XCTAssertEqual(h.lost, g.holdoutScore - expected)
        XCTAssertGreaterThan(h.lost, 0)
        XCTAssertEqual(h.nextBank, 10)
        let sc = RunScore.make(summary)
        XCTAssertEqual(sc.raw, expected, "the fall keeps the bank and nothing more")
        XCTAssertEqual(sc.total, RunScore.scaled(expected, tierMul: Difficulty.veteran.scoreMul))
        // the report: its title, its strip of banks, «Banked», its lines (the fall's part negative), the bank tip
        var p = Profile()
        let res = p.commit(summary, diffPicked: false)
        let rep = MissionReport.make(run: summary, result: res, profile: p, stats: g.stats, newStationShown: false)
        XCTAssertEqual(rep.title, GameText(.reportTitleDigIn, [.int(6)]))
        XCTAssertEqual(rep.scoreLabel, GameText(.reportScoreBanked))
        XCTAssertEqual(rep.scoreTotal, sc.total)
        XCTAssertEqual(rep.strip.map { $0.label }, [5, 10, 15, 20, 25, 30].map { GameText(.reportStripWave, [.int($0)]) })
        XCTAssertEqual(rep.strip.map { $0.on }, [true, false, false, false, false, false])
        XCTAssertEqual(rep.parts.map { $0.label }, [GameText(.scoreKills), GameText(.scoreWaves, [.int(6)]), GameText(.scoreQueens, [.int(1)]),
                                                    GameText(.scoreLost)])
        XCTAssertEqual(rep.parts.last?.value, GameText(.fmtMinus, [.num(h.lost)]))
        XCTAssertEqual(rep.parts.first?.value, GameText(.fmtPlus, [.num(h.kills)]))
        XCTAssertTrue(rep.tips.contains(ReportTip(text: GameText(.tipDigInBanked, [.int(5)]), good: true)), "\(rep.tips)")
        XCTAssertNil(rep.chip)
        XCTAssertNil(rep.scoreNote, "the first Dig In run on the tier: no best yet")
        XCTAssertEqual(p.dig, [0, 6, 0])
    }

    func testNothingBankedBeforeWaveFive() {
        // a fall before the first bank: the score is 0 — everything earned is the fall's
        let h = HoldoutSummary(held: 3, kills: 210, waveScore: 750, queens: 0, queenScore: 0, banked: 0, bankWave: 0, bankEvery: 5)
        var summary = RunSummary(cls: .pyro, won: false, surrendered: false, time: 140, playerKills: 210, beaconsDone: 0, queenSpawned: false,
                                 queenDone: false, downs: 1, downBy: .runner, tierIndex: 0, tierMul: 0.8, stage: .hold, pressureLoss: false,
                                 shots: 900, hits: 600, accuracy: 67, bestCombo: 22, level: 6, station: .kelvin)
        summary.holdout = h
        let sc = RunScore.make(summary)
        XCTAssertEqual(sc.raw, 0)
        XCTAssertEqual(sc.total, 0)
        XCTAssertEqual(sc.parts.map { $0.value }, [210, 750, -960])
        var p = Profile()
        let res = p.commit(summary, diffPicked: false)
        let rep = MissionReport.make(run: summary, result: res, profile: p, stats: Game(seed: 1).stats, newStationShown: false)
        XCTAssertEqual(rep.tips.first, ReportTip(text: GameText(.tipLossRunner), good: false))
        XCTAssertTrue(rep.tips.contains(ReportTip(text: GameText(.tipDigInNoBank, [.int(5)]), good: false)), "\(rep.tips)")
        XCTAssertEqual(rep.strip.map { $0.on }, [false, false, false, false, false, false])
        XCTAssertEqual(p.dig, [3, 0, 0])
    }

    func testTheBestWavesAndTheProfile() {
        func digRun(_ held: Int, banked: Int, bankWave: Int) -> RunSummary {
            var r = RunSummary(cls: .assault, won: false, surrendered: false, time: Float(40 * held), playerKills: 100 * held, beaconsDone: 0,
                               queenSpawned: held >= 5, queenDone: held >= 5, downs: 1, downBy: .brute, tierIndex: 1, tierMul: 1, stage: .hold,
                               pressureLoss: false, shots: 1000, hits: 700, accuracy: 70, bestCombo: 30, level: 10, station: .kelvin)
            r.holdout = HoldoutSummary(held: held, kills: 100 * held, waveScore: 250 * held, queens: held / 5, queenScore: 1000 * (held / 5),
                                       banked: banked, bankWave: bankWave, bankEvery: 5)
            return r
        }
        var p = Profile()
        let stats = Game(seed: 2).stats
        func report(_ r: RunSummary, _ res: RunResult) -> MissionReport {
            MissionReport.make(run: r, result: res, profile: p, stats: stats, newStationShown: false)
        }
        // a first run on Veteran: its waves are the best, no note yet
        let ra = digRun(7, banked: 2750, bankWave: 5)
        let a = p.commit(ra, diffPicked: false)
        XCTAssertEqual(a.prevWaves, 0); XCTAssertFalse(a.wavesRecord)
        XCTAssertNil(report(ra, a).scoreNote)
        XCTAssertEqual(p.dig, [0, 7, 0])
        // fewer waves: «best 7 waves»
        let rb = digRun(5, banked: 2750, bankWave: 5)
        let b = p.commit(rb, diffPicked: false)
        XCTAssertEqual(b.prevWaves, 7); XCTAssertFalse(b.wavesRecord)
        XCTAssertEqual(report(rb, b).scoreNote, GameText(.reportBestWaves, [.int(7)]))
        XCTAssertFalse(report(rb, b).record)
        // more waves: «New best»
        let rc = digRun(9, banked: 2750, bankWave: 5)
        let c = p.commit(rc, diffPicked: false)
        XCTAssertEqual(c.prevWaves, 7); XCTAssertTrue(c.wavesRecord)
        XCTAssertEqual(report(rc, c).scoreNote, GameText(.reportRecord))
        XCTAssertTrue(report(rc, c).record)
        XCTAssertEqual(p.dig, [0, 9, 0])
        // never won, no medal, never the early-loss chip, «longer than last time» untouched
        let r = p.record(.assault)
        XCTAssertEqual(r.runs, 3); XCTAssertEqual(r.wins, 0); XCTAssertEqual(r.ev, [0, 0, 0])
        XCTAssertEqual(r.lossEarly, 0); XCTAssertEqual(r.lastT, 0); XCTAssertEqual(p.recTip, 0)
        XCTAssertFalse(a.recTip || b.recTip || c.recTip)
        XCTAssertGreaterThan(r.xp, 0)
        // the profile keeps it, after the classes; an older profile has none yet
        let s = p.encoded()
        XCTAssertTrue(s.hasSuffix(",\"dig\":[0,9,0]}"), s)
        XCTAssertEqual(Profile.load(raw: s, legacyBest: nil), p)
        XCTAssertEqual(Profile.load(raw: "{\"v\":1,\"runs\":2}", legacyBest: nil).dig, [0, 0, 0])
        XCTAssertEqual(Profile.load(raw: "{\"v\":1,\"dig\":[4,\"x\",-2,9]}", legacyBest: nil).dig, [4, 0, 0])
        // a classic run never touches it
        var q = Profile()
        q.commit(RunSummary(cls: .gunner, won: true, surrendered: false, time: 400, playerKills: 900, beaconsDone: 3, queenSpawned: true,
                            queenDone: true, downs: 0, downBy: .environment, tierIndex: 1, tierMul: 1, stage: .extract, pressureLoss: false,
                            shots: 2000, hits: 1500, accuracy: 75, bestCombo: 40, level: 12, station: .kelvin), diffPicked: false)
        XCTAssertEqual(q.dig, [0, 0, 0])
    }

    // ---------------------------------------------------------------- the long run

    /// A squad that cannot fall holds out for eight minutes on Veteran: the waves keep coming and being held (none waits longer
    /// than a Queen's fight), nothing goes non-finite, the HUD's numbers stay finite, the mission never ends by itself.
    func testTheEndlessHoldNeverStallsOrNaNs() {
        let g = digIn(.veteran, seed: 31, cls: .gunner)
        var lastHeld = 0, lastAt: Float = 0, maxGap: Float = 0
        for k in 0..<(480 * 60) {
            g.tick()
            g.clearEvents()
            if g.holdout.held > lastHeld { maxGap = max(maxGap, g.time - lastAt); lastHeld = g.holdout.held; lastAt = g.time }
            if k % 600 == 0 {
                XCTAssertFalse(g.hasNonFinite(), "t=\(g.time)")
                XCTAssertFalse(g.objectiveProgress.isNaN, "t=\(g.time)")
                XCTAssertTrue(g.holdProgress.isFinite && g.holdProgress >= 0 && g.holdProgress <= 1, "t=\(g.time)")
                XCTAssertNotNil(g.objective)
            }
            if g.phase != .playing { break }
        }
        maxGap = max(maxGap, g.time - lastAt)
        XCTAssertEqual(g.phase, .playing, "only the squad's fall ends it")
        XCTAssertGreaterThanOrEqual(g.holdout.held, 7, "waves held in eight minutes")
        XCTAssertLessThan(maxGap, 150, "the longest wait between two waves held")
        XCTAssertEqual(g.liftT, .infinity)
        XCTAssertGreaterThanOrEqual(g.holdout.banks, 1)
        XCTAssertEqual(g.holdout.banks, g.holdout.held / 5)
        XCTAssertEqual(g.beaconsDone, g.holdout.held)
    }

    /// Nightmare, nobody at the controls and no god mode: the squad falls in the end — the mission is lost, never won.
    func testOnlyTheFallEndsIt() {
        let g = digIn(.nightmare, seed: 41, cls: .pyro, autopilot: false, god: false)
        run(g, seconds: 900)
        XCTAssertNotEqual(g.phase, .won)
        XCTAssertEqual(g.phase, .lost, "an idle squad on Nightmare falls within fifteen minutes")
        XCTAssertFalse(g.hasNonFinite())
        let h = g.runSummary(won: false, surrendered: false).holdout
        XCTAssertEqual(h?.held, g.holdout.held)
    }

    func testDigInIsDeterministic() {
        func run1() -> [Float] {
            let g = digIn(.veteran, seed: 51, cls: .pyro, autopilot: true, god: false)
            for _ in 0..<(150 * 60) { g.tick(); g.clearEvents(); if g.phase != .playing { break } }
            return [g.time, Float(g.holdout.held), Float(g.holdout.wave), Float(g.holdout.phase.rawValue), g.holdout.t, Float(g.kills),
                    Float(g.playerKills), Float(g.holdoutScore), Float(g.bugs.aliveCount), Float(g.rng.state & 0xFFFF), g.marines[0].x, g.marines[0].z]
        }
        let a = run1()
        XCTAssertEqual(a, run1())
        XCTAssertGreaterThanOrEqual(a[1], 1, "a wave held in 150 s")
    }

    // ---------------------------------------------------------------- calibration

    func testCalibrationRowTableAndGate() throws {
        let r = Calibration.run(CalibRun(tag: "dig-in-vet", cls: .gunner, tier: 1, mode: .auto, maxs: 150, seed: 7, mission: "dig-in"))
        XCTAssertNil(r.error)
        let d = try XCTUnwrap(r.dig)
        XCTAssertGreaterThanOrEqual(d.held, 1)
        XCTAssertEqual(d.waveAt.count, d.held)
        XCTAssertGreaterThan(d.maxHorde, 0)
        XCTAssertEqual(r.beacons, d.held, "every wave held is an escalation step")
        XCTAssertTrue(r.json.contains("\"mission\":\"dig-in\""), r.json)
        XCTAssertTrue(r.json.contains(",\"dig\":{\"held\":\(d.held),"), r.json)
        XCTAssertEqual(CalibRow(json: r.json)?.dig, d)
        // a classic row never carries it
        XCTAssertNil(CalibRow(json: MissionPlanTests.golden[0].1)?.dig)
        XCTAssertFalse(MissionPlanTests.golden[0].1.contains("\"dig\""))
        // the gate: the median waves held of each tier in its band, the AFK first downs
        let c = try XCTUnwrap(MissionTemplate.digIn.calib)
        func row(_ tier: Int, held: Int, mode: String = "auto", firstDown: Float = 60) -> CalibRow {
            var x = CalibRow()
            x.tierIx = tier; x.tag = "dig-in-" + Calibration.tierTag(tier); x.mode = mode; x.mission = "dig-in"; x.result = "lost"
            x.pFirstDown = firstDown
            var h = CalibHoldout(); h.held = held; x.dig = h
            return x
        }
        var rows: [CalibRow] = []
        for b in c.bands {
            let mid = Int((((b.wavesLo ?? 0) + (b.wavesHi ?? 40)) / 2).rounded())
            rows += (0..<12).map { k in row(b.tier, held: mid + (k % 3) - 1) }
        }
        for a in c.afk { rows += (0..<4).map { _ in row(a.tier, held: 1, mode: "afk", firstDown: a.firstDownMax - 20) } }
        let (ok, lines) = Calibration.gate(rows)
        XCTAssertTrue(ok, lines.filter { !$0.ok }.map { $0.text }.joined(separator: "; "))
        let mine = lines.filter { $0.text.hasPrefix("dig-in") }
        XCTAssertEqual(mine.filter { $0.gated && $0.text.contains("waves held median") }.count, 3, "\(mine.map { $0.text })")
        XCTAssertFalse(mine.contains { $0.text.contains("/auto wins") }, "an endless mission has no wins line")
        XCTAssertTrue(mine.contains { !$0.gated && $0.text.contains("afk waves held median") })
        // a median out of its band fails the gate
        let vet = c.bands.first { $0.tier == 1 }!
        var bad = rows.filter { $0.tierIx != 1 || $0.mode != "auto" }
        bad += (0..<12).map { _ in row(1, held: Int((vet.wavesHi ?? 20) + 6)) }
        XCTAssertFalse(Calibration.gate(bad).passed)
        // the classic bands never read its rows (one classic Recruit win: 100 %); its table comes with the aggregate
        let classicRow = try XCTUnwrap(CalibRow(json: MissionPlanTests.golden[0].1))
        let classic = Calibration.gate(rows + [classicRow])
        XCTAssertTrue(classic.lines.contains { $0.text.hasPrefix("rec/auto wins 100.0%") }, classic.lines.map { $0.text }.joined(separator: "; "))
        let agg = Calibration.aggregate(rows + [r])
        XCTAssertTrue(agg.contains("holdout"), agg)
        XCTAssertTrue(agg.contains("holdout falls"), agg)
    }
}
