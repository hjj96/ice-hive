import XCTest
@testable import IceHiveCore

/// Simulation cost per fixed step (web __dbg.bench). Printed to the CI log; the 2 ms budget for 1500 bugs
/// is asserted only for optimised builds (`swift test -c release`), debug builds are ~10x slower.
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
        let res = g.benchmark(counts: [500, 1500, 3000], warmupTicks: 10, measureTicks: 120)
        for r in res { print("[perf] \(r) [\(PerformanceTests.optimized ? "release" : "debug")]") }
        let r1500 = res[1]
        XCTAssertGreaterThan(r1500.spawned, 1400)
        if PerformanceTests.optimized {
            XCTAssertLessThan(r1500.msPerTick, 2.0, "1500 bugs: \(r1500.msPerTick) ms/tick")
            XCTAssertLessThan(r1500.denseMsPerTick, 2.0, "1500 bugs dense: \(r1500.denseMsPerTick) ms/tick")
        } else {
            XCTAssertLessThan(r1500.msPerTick, 40, "debug build, 1500 bugs: \(r1500.msPerTick) ms/tick")
        }
        // the bench restores the world
        XCTAssertEqual(g.bugs.count, 0)
        XCTAssertEqual(g.phase, .playing)
    }

    func testMissionThroughput() throws {
        // a full autopilot mission's simulation time, for the log (the mission tests already cover debug builds)
        if !PerformanceTests.optimized { throw XCTSkip("release builds only (swift test -c release)") }
        var cfg = GameConfig()
        cfg.autopilot = true; cfg.autoPickUpgrades = true
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
        print(String(format: "[perf] mission %d ticks in %.2f s: %.3f ms/tick avg, %.2f ms max [%@]", g.tickCount, dt, dt * 1000 / Double(max(1, g.tickCount)),
                     maxTick * 1000, PerformanceTests.optimized ? "release" : "debug"))
        XCTAssertEqual(g.phase, .won)
    }
}
