import XCTest
@testable import IceHiveCore

/// Headless autopilot missions (T17). The v1.0 rules (`legacyV10`): the AI-driven player plus the bot squad win on
/// every class (the web autopilot wins in about 5–6 minutes). v1.1 Новобранец: every class reaches the lift hold and
/// meets the Матка, at least three of four evacuate (the tier's calibrated win rate is ≈ 97 %; Ветеран / Кошмар
/// outcomes are the calibration gate's job, not a unit test's).
final class MissionTests: XCTestCase {
    static let maxMinutes: Float = 8

    func runMission(_ cls: MarineClass, seed: UInt32, tier: Difficulty = .legacyV10) -> (Game, Float) {
        var cfg = GameConfig()
        cfg.difficulty = tier
        cfg.autopilot = true
        cfg.autoPickUpgrades = true
        let g = Game(seed: seed, playerClass: cls, config: cfg)
        let maxTicks = Int(MissionTests.maxMinutes * 60 * 60)
        var t = 0
        var lastLog: Float = -100
        var maxAlive = 0
        var downs = 0
        var stages: [String] = []
        while t < maxTicks && g.phase == .playing {
            g.tick()
            t += 1
            g.drainEvents { e in
                let at = String(format: "%.1f", g.time)
                switch e {
                case .downed: downs += 1
                case .beaconStarted(let k): stages.append("beacon\(k)start@\(at)")
                case .beaconCompleted(let k): stages.append("beacon\(k)done@\(at)")
                case .holdStarted: stages.append("hold@\(at)")
                case .extractStarted: stages.append("extract@\(at)")
                default: break
                }
            }
            if t % 60 == 0 {
                XCTAssertFalse(g.hasNonFinite(), "non-finite numbers at t=\(g.time) (\(cls))")
                let alive = g.bugs.aliveCount
                maxAlive = max(maxAlive, alive)
                XCTAssertLessThanOrEqual(alive, g.bugCap, "bug cap exceeded (\(cls))")
            }
            if g.time - lastLog >= 60 { lastLog = g.time; print("[\(cls.id) \(tier.id) seed \(seed)] \(g.debugState)") }
        }
        print("[\(cls.id) \(tier.id) seed \(seed)] END \(g.debugState) maxAlive=\(maxAlive) downs=\(downs) acc=\(g.accuracy)% upgrades=\(g.upgradeCounts.count) level=\(g.xpLevel)\n  stages: \(stages.joined(separator: " "))")
        return (g, g.time)
    }

    func check(_ cls: MarineClass) {
        let (g, time) = runMission(cls, seed: 1000 + UInt32(cls.rawValue))
        XCTAssertEqual(g.phase, .won, "\(cls.id): autopilot did not win within \(MissionTests.maxMinutes) min: \(g.debugState)")
        XCTAssertLessThan(time, MissionTests.maxMinutes * 60)
        XCTAssertGreaterThan(g.kills, 300)
        XCTAssertEqual(g.beaconsDone, 3)
    }

    func testAutopilotWinsAssault() { check(.assault) }
    func testAutopilotWinsPyro() { check(.pyro) }
    func testAutopilotWinsCryo() { check(.cryo) }
    func testAutopilotWinsGunner() { check(.gunner) }

    func testRecruitMeetsTheQueen() {
        var wins = 0, queens = 0
        for cls in MarineClass.allCases {
            let (g, _) = runMission(cls, seed: 1100 + UInt32(cls.rawValue), tier: .recruit)
            XCTAssertTrue(g.stage == .hold || g.stage == .extract, "\(cls.id): never reached the lift hold: \(g.debugState)")
            // (a squad wiped in the first 35 s of the hold never meets her)
            XCTAssertTrue(g.queen.spawned || g.phase == .lost, "\(cls.id): no Матка")
            if g.phase == .won { XCTAssertTrue(g.queen.done, "\(cls.id): the lift left with her alive"); wins += 1 }
            if g.queen.spawned { queens += 1 }
        }
        XCTAssertGreaterThanOrEqual(wins, 3)
        XCTAssertGreaterThanOrEqual(queens, 3)
    }
}
