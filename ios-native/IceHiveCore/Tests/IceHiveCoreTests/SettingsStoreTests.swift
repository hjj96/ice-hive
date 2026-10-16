import XCTest
@testable import IceHiveCore

final class SettingsStoreTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "icehive.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testDefaults() {
        let s = SettingsStore(defaults: freshDefaults())
        XCTAssertEqual(s.cls, "assault")
        XCTAssertEqual(s.bestKills, 0)
        XCTAssertEqual(s.bestWin, 0)
        XCTAssertFalse(s.muted)
        XCTAssertEqual(s.vol, 0.8, accuracy: 1e-6)
        XCTAssertTrue(s.haptics)
        XCTAssertEqual(s.quality, "auto")
        XCTAssertTrue(s.migrated.isEmpty)
    }

    /// v1.x (Capacitor Preferences) values are JSON strings under "CapacitorStorage.ledulei.<k>".
    func testMigratesCapacitorPreferences() {
        let d = freshDefaults()
        d.set("\"pyro\"", forKey: "CapacitorStorage.ledulei.cls")
        d.set("{\"kills\":4321,\"win\":512}", forKey: "CapacitorStorage.ledulei.best")
        d.set("true", forKey: "CapacitorStorage.ledulei.muted")
        d.set("0.4", forKey: "CapacitorStorage.ledulei.vol")
        d.set("false", forKey: "CapacitorStorage.ledulei.haptics")
        d.set("\"high\"", forKey: "CapacitorStorage.ledulei.quality")
        let s = SettingsStore(defaults: d)
        XCTAssertEqual(s.cls, "pyro")
        XCTAssertEqual(s.bestKills, 4321)
        XCTAssertEqual(s.bestWin, 512)
        XCTAssertTrue(s.muted)
        XCTAssertEqual(s.vol, 0.4, accuracy: 1e-6)
        XCTAssertFalse(s.haptics)
        XCTAssertEqual(s.quality, "high")
        XCTAssertEqual(Set(s.migrated), Set(["cls", "best", "muted", "vol", "haptics", "quality"]))
        // copied once: the 2.0 keys now exist and win over the legacy ones
        XCTAssertEqual(d.string(forKey: "ledulei.cls"), "\"pyro\"")
        s.setClass("cryo")
        let again = SettingsStore(defaults: d)
        XCTAssertEqual(again.cls, "cryo")
        XCTAssertTrue(again.migrated.isEmpty)
    }

    func testRecordsAndVolumeCycle() {
        let d = freshDefaults()
        let s = SettingsStore(defaults: d)
        XCTAssertTrue(s.recordMission(kills: 900, won: false, time: 300))
        XCTAssertFalse(s.recordMission(kills: 800, won: true, time: 640.4))
        XCTAssertEqual(s.bestKills, 900)
        XCTAssertEqual(s.bestWin, 640)
        s.recordMission(kills: 100, won: true, time: 700)
        XCTAssertEqual(s.bestWin, 640)
        s.recordMission(kills: 100, won: true, time: 600)
        XCTAssertEqual(s.bestWin, 600)
        XCTAssertEqual(d.string(forKey: "ledulei.best"), "{\"kills\":900,\"win\":600}")
        XCTAssertEqual(s.cycleVolume(), 0.6, accuracy: 1e-6)
        XCTAssertEqual(s.cycleVolume(), 0.4, accuracy: 1e-6)
        XCTAssertEqual(s.cycleVolume(), 0.2, accuracy: 1e-6)
        XCTAssertEqual(s.cycleVolume(), 1.0, accuracy: 1e-6)
        XCTAssertEqual(SettingsStore(defaults: d).vol, 1.0, accuracy: 1e-6)
        s.setMuted(true)
        XCTAssertEqual(SettingsStore(defaults: d).masterVolume, 0)
    }

    /// Garbage in the legacy store must not crash or be copied.
    func testIgnoresMalformedLegacyValues() {
        let d = freshDefaults()
        d.set("{not json", forKey: "CapacitorStorage.ledulei.best")
        d.set("\"assault\"", forKey: "CapacitorStorage.ledulei.cls")
        let s = SettingsStore(defaults: d)
        XCTAssertEqual(s.bestKills, 0)
        XCTAssertEqual(s.migrated, ["cls"])
    }
}
