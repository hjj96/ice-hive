import XCTest
@testable import IceHiveCore

/// Simulation cost per fixed step (web __dbg.bench), printed to the CI log. The 2 ms budget for 1500 bugs is
/// asserted for optimised builds (`swift test -c release`: ~0.3 ms); the CI runs unoptimised builds (~1.7 ms on
/// the CI Mac), checked against a looser regression guard.
final class PerformanceTests: XCTestCase {
    #if DEBUG
    static let optimized = false
    #else
    static let optimized = true
    #endif

    func testBench1500() {
        var cfg = GameConfig()
        cfg.quality = .high
        let g = Game(seed: 77, playerClass: .gunner, config: cfg)
        g.step(30)
        let n0 = g.bugs.count   // (the v1.1 default tier's trickle may already have a bug on the deck)
        let res = g.benchmark(counts: [500, 1500, 3000], warmupTicks: 10, measureTicks: 120)
        for r in res { print("[perf] \(r) [\(PerformanceTests.optimized ? "release" : "debug")]") }
        let r1500 = res[1]
        XCTAssertGreaterThan(r1500.spawned, 1400)
        if PerformanceTests.optimized {
            XCTAssertLessThan(r1500.msPerTick, 2.0, "1500 bugs: \(r1500.msPerTick) ms/tick")
            XCTAssertLessThan(r1500.denseMsPerTick, 2.0, "1500 bugs dense: \(r1500.denseMsPerTick) ms/tick")
        } else {
            // unoptimised builds measured ~1.7 ms on the CI Mac; generous regression guard
            XCTAssertLessThan(r1500.msPerTick, 8, "debug build, 1500 bugs: \(r1500.msPerTick) ms/tick")
        }
        // the bench restores the world
        XCTAssertEqual(g.bugs.count, n0)
        XCTAssertEqual(g.phase, .playing)
    }

    func testMissionThroughput() throws {
        // a full autopilot mission's simulation time, for the log (the mission tests already cover debug builds):
        // the v1.0 row (it always wins) and a v1.1 Ветеран mission with the Матка (rules cost, not its outcome)
        if !PerformanceTests.optimized { throw XCTSkip("release builds only (swift test -c release)") }
        for (label, tier) in [("v1.0", Difficulty.legacyV10), ("v1.1 vet", Difficulty.veteran)] {
            var cfg = GameConfig()
            cfg.autopilot = true; cfg.autoPickUpgrades = true; cfg.difficulty = tier
            let g = Game(seed: 5, playerClass: .assault, config: cfg)
            let t0 = ProcessInfo.processInfo.systemUptime
            var maxTick = 0.0
            while g.phase == .playing && g.time < 480 {
                let a = ProcessInfo.processInfo.systemUptime
                g.tick()
                maxTick = max(maxTick, ProcessInfo.processInfo.systemUptime - a)
                g.clearEvents()
            }
            let dt = ProcessInfo.processInfo.systemUptime - t0
            print(String(format: "[perf] mission %@ %d ticks in %.2f s: %.3f ms/tick avg, %.2f ms max, %@ queen=%@ [%@]", label, g.tickCount, dt,
                         dt * 1000 / Double(max(1, g.tickCount)), maxTick * 1000, "\(g.phase)", g.queen.done ? "killed" : (g.queen.spawned ? "alive" : "none"),
                         PerformanceTests.optimized ? "release" : "debug"))
            if tier.index < 0 { XCTAssertEqual(g.phase, .won) }
            XCTAssertLessThan(dt * 1000 / Double(max(1, g.tickCount)), 1.0, "\(label): average tick")
        }
    }

    /// The station generator over 1000 seeds (web golden summary: all valid, tour p10 / p50 / p90 = 207 / 252 / 301).
    func testGeneratorSweep1000() throws {
        if !PerformanceTests.optimized { throw XCTSkip("release builds only (swift test -c release)") }
        let t0 = ProcessInfo.processInfo.systemUptime
        var tours: [Int] = [], valid = 0, worst = 0.0
        for s: UInt32 in 1...1000 {
            let a = ProcessInfo.processInfo.systemUptime
            if let L = Stations.generate(seed: s), let c = L.check { valid += 1; tours.append(c.tour) }
            worst = max(worst, ProcessInfo.processInfo.systemUptime - a)
        }
        let dt = ProcessInfo.processInfo.systemUptime - t0
        tours.sort()
        func p(_ q: Double) -> Int { tours[Int((q * Double(tours.count - 1)).rounded(.down))] }
        print(String(format: "[perf] generator 1000 seeds in %.2f s (%.2f ms avg, %.1f ms worst): %d valid, tour p10/p50/p90 %d/%d/%d", dt, dt,
                     worst * 1000, valid, p(0.1), p(0.5), p(0.9)))
        let G = StationGolden.summary1000
        XCTAssertEqual(valid, G.valid)
        XCTAssertEqual([p(0.1), p(0.5), p(0.9)], [G.tourP10, G.tourP50, G.tourP90])
    }
}
