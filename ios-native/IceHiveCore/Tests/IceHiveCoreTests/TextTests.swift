import XCTest
@testable import IceHiveCore

/// The typed text of the core (Text.swift): stable keys, signatures, names bound to ids, and every line a mission
/// emits is a well-formed GameText (its initialiser asserts the signature in debug builds, which the tests run).
final class TextTests: XCTestCase {
    func testKeysAreUniqueAndWellFormed() {
        let ids = TextID.allCases.map { $0.rawValue }
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate TextID key")
        let names = NameRef.all.map { $0.key }
        XCTAssertEqual(Set(names).count, names.count, "duplicate NameRef key")
        XCTAssertTrue(Set(ids).isDisjoint(with: names), "a TextID and a name share a key")
        let shape = try! NSRegularExpression(pattern: "^[a-z0-9_]+(\\.[a-z0-9_]+)+$")
        for k in ids + names {
            XCTAssertNotNil(shape.firstMatch(in: k, range: NSRange(k.startIndex..., in: k)), "key shape: \(k)")
        }
        for id in TextID.allCases {
            XCTAssertTrue(id.signature.allSatisfy { $0 == "d" || $0 == "@" }, "\(id.rawValue) signature \(id.signature)")
        }
    }

    func testNamesAreIdsNotProse() {
        XCTAssertEqual(NameRef.callsign(.assault).key, "name.callsign.assault")
        XCTAssertEqual(NameRef.callsign(.gunner).key, "name.callsign.gunner")
        XCTAssertEqual(NameRef.beacon(0).key, "name.beacon.alpha")
        XCTAssertEqual(NameRef.beacon(2).key, "name.beacon.gamma")
        XCTAssertEqual(NameRef.bug(.boomer).key, "name.bug.boomer")
        XCTAssertEqual(NameRef.cls(.pyro).key, "class.pyro.name")
        XCTAssertEqual(NameRef.abilityShort(.cryo).key, "class.cryo.ability_short")
        XCTAssertEqual(NameRef.tierAbbr(2).key, "tier.nm.abbr")
        XCTAssertEqual(NameRef.upgrade(.turret).key, "upg.turret.name")
        XCTAssertEqual(NameRef.quality(.low).key, "quality.low")
        XCTAssertEqual(NameRef.sector(letter: 3, number: 17).logID, "sector-3-17")
        XCTAssertEqual(NameRef.kelvin.logID, "kelvin-9")
        // every upgrade card has its name and a description whose numbers are arguments
        for u in UPGRADES {
            XCTAssertEqual(u.name, .upgrade(u.id))
            XCTAssertEqual(u.desc.id.rawValue, "upg." + u.id.rawValue + ".desc")
        }
        XCTAssertEqual(UPGRADES.first { $0.id == .regen }?.desc, GameText(.upgRegen, [.tenths(15)]))
        XCTAssertEqual(UPGRADES.first { $0.id == .turret }?.desc, GameText(.upgTurret, [.int(5), .int(30)]))
    }

    func testToastBuilders() {
        XCTAssertNil(GameText.bugTip(.runner))
        XCTAssertEqual(GameText.bugTip(.brute), GameText(.toastTipBrute, [.name(.bug(.brute))]))
        XCTAssertEqual(GameText.downToast(.player), GameText(.toastPlayerDown))
        XCTAssertEqual(GameText.downToast(.callsign(.cryo)), GameText(.toastMateDown, [.name(.callsign(.cryo))]))
        XCTAssertEqual(GameText.upToast(.callsign(.pyro)), GameText(.toastMateUp, [.name(.callsign(.pyro))]))
        XCTAssertEqual(GameText(.objHoldLift, [.time(99.7)]), GameText(.objHoldLift, [.clock(99)]))
        XCTAssertEqual(GameText(.objHoldBeacon, [.name(.beacon(1))]).description, "obj.hold_beacon(name.beacon.beta)")
    }

    /// A whole mission (autopilot, every tier): every toast, banner, horde title, hint and objective is a GameText whose
    /// arguments match its id (the initialiser asserts it), and the squad's toasts name the class call-signs.
    func testMissionTextIsTyped() {
        for tier in Difficulty.tiers {
            var c = GameConfig()
            c.difficulty = tier; c.autopilot = true; c.autoPickUpgrades = true; c.reviveLineArmed = true
            let g = Game(seed: 41, playerClass: .gunner, config: c)
            var ids = Set<TextID>()
            for _ in 0..<(60 * 60 * 8) {
                g.tick()
                if g.tickCount % 30 == 0 {
                    if let o = g.objective { ids.insert(o.id) }
                    if let h = g.contextHint { ids.insert(h.text.id) }
                }
                g.drainEvents { e in
                    switch e {
                    case .toast(let t, _): ids.insert(t.id)
                        if t.id == .toastMateDown || t.id == .toastMateUp, case .name(let n)? = t.args.first {
                            XCTAssertTrue([.callsign(.assault), .callsign(.pyro), .callsign(.cryo)].contains(n), "\(n)")
                        }
                    case .banner(let a, let b, _): ids.insert(a.id); ids.insert(b.id)
                    case .hordeStarted(_, let a, let b): ids.insert(a.id); ids.insert(b.id)
                    default: break
                    }
                }
                if g.phase != .playing { break }
            }
            XCTAssertTrue(ids.contains(.bannerDrop) && ids.contains(.objLightBeacons), "\(tier.id): \(ids.map { $0.rawValue }.sorted())")
            XCTAssertTrue(ids.contains(.bannerBeaconOnline), "\(tier.id): no beacon came online")
        }
    }
}
