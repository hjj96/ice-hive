import XCTest
@testable import IceHiveCore

/// T18: the calibration runner (icehive-calib) — one short run per mode gives a full row, rows survive a JSONL
/// round trip, the aggregate and the gate read synthetic rows, `--th` parsing.
final class CalibrationTests: XCTestCase {
    func testOneShortRunPerMode() {
        for mode in CalibMode.allCases {
            let c = CalibRun(tag: "t", cls: .pyro, tier: 1, mode: mode, maxs: 40, seed: Calibration.seed(1000, mode: mode, tier: 1, cls: .pyro, k: 0))
            let r = Calibration.run(c)
            XCTAssertNil(r.error)
            if mode == .afkbeacon {
                // AFK in the first beacon's horde: a squad wipe is a possible outcome
                XCTAssertTrue(r.result == "playing" || r.result == "lost", mode.rawValue)
                XCTAssertLessThanOrEqual(r.t, 40.05)
            } else {
                XCTAssertEqual(r.result, "playing", mode.rawValue)
                XCTAssertEqual(r.t, 40, accuracy: 0.05)
            }
            XCTAssertEqual(r.tier, "vet"); XCTAssertEqual(r.cls, "pyro"); XCTAssertEqual(r.mode, mode.rawValue); XCTAssertEqual(r.q, "med")
            XCTAssertEqual(r.stageAt.first?.0, "beacons")
            XCTAssertGreaterThan(r.maxAlive, 0)
            XCTAssertEqual(r.hurtBy.count, 6); XCTAssertEqual(r.downBy4.count, 6)
            if mode == .auto || mode == .passive { XCTAssertNotNil(r.stageTime("b1"), "\(mode): the autopilot starts beacon 1") }
            if mode == .afk { XCTAssertNil(r.stageTime("b1")); XCTAssertGreaterThan(r.pressMax, 25) }
            // JSONL round trip (key order of the objects aside)
            let back = CalibRow(json: r.json)
            XCTAssertNotNil(back)
            if let b = back {
                XCTAssertEqual(b.result, r.result); XCTAssertEqual(b.t, r.t); XCTAssertEqual(b.downs, r.downs); XCTAssertEqual(b.minHp, r.minHp)
                XCTAssertEqual(b.hurtBy, r.hurtBy); XCTAssertEqual(b.downBy4, r.downBy4); XCTAssertEqual(b.seed, r.seed); XCTAssertEqual(b.pKills, r.pKills)
                XCTAssertEqual(b.stageAt.sorted { $0.0 < $1.0 }.map { $0.0 }, r.stageAt.sorted { $0.0 < $1.0 }.map { $0.0 })
                XCTAssertEqual(b.idleMax, r.idleMax, accuracy: 1e-4); XCTAssertEqual(b.pressMax, r.pressMax, accuracy: 1e-4)
                XCTAssertEqual(b.queen == nil, r.queen == nil)
            }
        }
        XCTAssertEqual(Calibration.seed(1000, mode: .afk, tier: 2, cls: .gunner, k: 7), 1000 + 20000 + 2000 + 300 + 7)
        XCTAssertEqual(Calibration.seed(1000, mode: .auto, tier: -1, cls: .assault, k: 1), 1000 + 3000 + 1)
    }

    func testRunsAreDeterministicAndParallelSafe() {
        let cs = Calibration.batch(tier: 0, mode: .auto, n: 1, classes: [.assault, .cryo], maxs: 30) + Calibration.batch(tier: 2, mode: .afk, n: 1, classes: [.gunner], maxs: 30)
        let a = Calibration.runAll(cs, jobs: 3), b = Calibration.runAll(cs, jobs: 1)
        XCTAssertEqual(a.map { $0.json }, b.map { $0.json })
        XCTAssertEqual(a.map { $0.tag }, ["rec", "rec", "nm"])
    }

    func testPresets() {
        let g = Calibration.preset("gate")!
        XCTAssertEqual(g.count, 32 + 64 + 32 + 4 + 4 + 4 + 8)
        XCTAssertEqual(g.filter { $0.tier == 1 && $0.mode == .auto }.count, 64)
        XCTAssertEqual(g.filter { $0.mode == .afk }.map { $0.maxs }, [Float](repeating: 420, count: 8))
        XCTAssertEqual(Set(g.map { $0.seed }).count, g.count, "disjoint seeds")
        XCTAssertEqual(Calibration.preset("stations")!.map { $0.station }.max(), 4)
        XCTAssertEqual(Calibration.preset("legacy")!.count, 32)
        XCTAssertNil(Calibration.preset("nope"))
    }

    func synth(_ tier: Int, _ mode: String, won: Bool, downs: Int = 0, queen: Float? = nil, reached: Bool = true, pFirst: Float = -1) -> CalibRow {
        var r = CalibRow()
        r.tierIx = tier; r.tag = Calibration.tierTag(tier); r.mode = mode
        r.result = won ? "won" : "lost"
        r.downs = [min(downs, 1), max(0, downs - 1), 0, 0]
        r.pFirstDown = pFirst
        if reached { var q = CalibQueen(); q.killT = queen; r.queen = q; r.stageAt = [("beacons", 0), ("hold", 220)] }
        r.t = won ? 330 : 250
        return r
    }

    func testAggregateAndGateOnSyntheticRows() {
        var rows: [CalibRow] = []
        for k in 0..<20 { rows.append(synth(0, "auto", won: k != 0, queen: 12)) }
        for k in 0..<20 { rows.append(synth(1, "auto", won: k < 16, downs: k % 5, queen: k < 18 ? 25 : nil)) }
        for k in 0..<10 { rows.append(synth(2, "auto", won: k < 2, downs: 4, queen: nil, reached: k < 6)) }
        for _ in 0..<4 { rows.append(synth(1, "afk", won: false, downs: 4, reached: false, pFirst: 80)) }
        for _ in 0..<4 { rows.append(synth(0, "afk", won: false, downs: 4, reached: false, pFirst: 130)) }
        var (ok, lines) = Calibration.gate(rows)
        XCTAssertTrue(ok, lines.filter { !$0.ok }.map { $0.text }.joined(separator: "; "))
        let g = Calibration.groups(rows).first { $0.key == "vet auto" }!
        XCTAssertEqual(g.n, 20); XCTAssertEqual(g.winPct, 80); XCTAssertEqual(g.queenReachedPct, 100); XCTAssertEqual(g.queenKilledPct, 90)
        XCTAssertEqual(g.zeroDownPct, 20); XCTAssertEqual(g.someDownPct, 60); XCTAssertEqual(g.manyDownPct, 20)
        XCTAssertTrue(Calibration.aggregate(rows).contains("vet auto"))
        // Ветеран too easy → the gate fails with a CALIB: FAILED line
        for k in 20..<40 where k % 5 == 0 { rows[k].result = "won" }
        rows[37].result = "won"; rows[38].result = "won"; rows[39].result = "won"; rows[36].result = "won"
        (ok, lines) = Calibration.gate(rows)
        XCTAssertFalse(ok)
        let t = Calibration.gateText(rows)
        XCTAssertFalse(t.passed)
        XCTAssertTrue(t.text.contains("CALIB: FAILED vet/auto wins"))
        // an AFK run whose player never goes down fails its band
        var afk = rows.filter { $0.mode != "afk" || $0.tierIx != 1 }
        afk += [synth(1, "afk", won: false, reached: false, pFirst: -1)]
        XCTAssertTrue(Calibration.gateText(afk).text.contains("CALIB: FAILED vet/afk first player down"))
        // a missing group is a failure
        XCTAssertFalse(Calibration.gate(rows.filter { $0.tierIx != 2 }).passed)
        // web rows (no station / th keys) aggregate too
        let web = #"{"tag":"vet","cls":"assault","q":"med","mode":"auto","tierIx":1,"seed":0,"th":{},"result":"won","t":331.2,"tier":"vet","shots":1,"hits":1,"pKills":3,"stage":"extract","beacons":3,"kills":9,"level":14,"stageAt":{"beacons":0,"hold":230.1},"downs":[0,1,0,0],"pDowns":0,"downBy":-1,"firstDown":100,"pFirstDown":-1,"holdDowns":0,"minHp":[40,0,50,60],"pLowS":0,"pHalfS":3,"pTakenPerMin":20,"maxAlive":900,"avgAlive":120,"holdAliveMax":900,"deckMax":100,"nearMax":80,"idleMax":1,"idleSt":"","pressAtHold":2,"pressMax":20,"firstBrute":40,"downSt":{"b2":1},"queen":{"spawnT":265,"liftT":65,"hp":5000,"squadAtSpawn":"1/2/3/4","killT":20.5,"liftAtKill":44,"squadAtKill":"1/2/3/4","downs":0},"hurtBy":[0,1,2,3,4,5],"downBy4":[0,0,1,0,0,0],"aliveAt":"1,2","hpAt":"x"}"#
        let w = CalibRow(json: web)
        XCTAssertEqual(w?.queen?.killT, 20.5)
        XCTAssertEqual(w?.squadDowns, 1)
        XCTAssertEqual(w?.stageTime("hold"), 230.1)
    }

    func testThParsing() {
        let (f, e) = Calibration.parseTh(#"{"trickle":1.3,"qHp":4200}"#)
        XCTAssertEqual(f["trickle"], 1.3); XCTAssertEqual(f["qHp"], 4200); XCTAssertTrue(e.isEmpty)
        XCTAssertEqual(Calibration.parseTh(#"{"trikle":1.3}"#).errors, ["unknown tier field trikle"])
        XCTAssertEqual(Calibration.parseTh(#"{"revive":"x"}"#).errors, ["not a number: revive"])
        XCTAssertFalse(Calibration.parseTh("[1]").errors.isEmpty)
        XCTAssertTrue(Calibration.parseTh("").fields.isEmpty)
        let c = CalibRun(tag: "t", cls: .assault, tier: 1, mode: .auto, seed: 1, th: f)
        XCTAssertEqual(c.difficulty.trickle, 1.3, accuracy: 1e-6)
        XCTAssertEqual(c.difficulty.queen.hp, 4200)
        XCTAssertEqual(CalibRun(tag: "t", cls: .assault, tier: -1, mode: .auto, seed: 1).difficulty.id, "v10")
    }
}
