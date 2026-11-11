import XCTest
@testable import IceHiveCore

/// Stage 1 R5 «Kelvin-9 Mk II»: the hand-made station's overhead (`OverheadLayout.kelvinMk2`) is a valid full route set
/// in tech.md's 150–450 m band with a golden hash, it carries R6's valves on its pipes, the design's duct mouths and
/// perches, keeps the lift's near half and the title's pad clear; the classic mission plays it (the app, the calibration
/// presets' classic rows) with the overhead and the props on, and the legacy v1.0 row keeps the bare station.
final class KelvinMk2Tests: XCTestCase {
    /// The golden hash of the route set (quantised to 1/64 m: the same on every platform).
    static let golden: UInt32 = 1_061_185_425

    var mk2Level: Level { Level(source: KelvinStation.mk2, seed: 1) }

    func testMk2IsAValidFullRouteSet() {
        let o = OverheadLayout.kelvinMk2
        XCTAssertEqual(o.nodes.count, 45)
        XCTAssertEqual(o.edges.count, 37)
        XCTAssertEqual(o.hash, KelvinMk2Tests.golden)
        let rc = OverheadCheck.check(o, level: mk2Level, lengthBand: KelvinMk2.lengthBand)
        XCTAssertTrue(rc.ok, rc.why)
        XCTAssertEqual(rc.length, 294.9, accuracy: 0.5)
        XCTAssertLessThanOrEqual(rc.footprint, OverheadCheck.maxFootprint)
        XCTAssertEqual(rc.entries, 16, "abyss risers, masts and duct mouths")
        // the same set validates on the bare decks (the props change only pedestal cells)
        XCTAssertTrue(OverheadCheck.check(o, level: Level(source: KelvinStation(), seed: 1), lengthBand: KelvinMk2.lengthBand).ok)
        // ≈ 130 triangles per metre of route (R3) keeps the full set near the tech estimate of +35–40 k
        XCTAssertLessThanOrEqual(rc.length, 300)
    }

    func testTheSpineStartsWithR2sSlice() {
        let mk2 = OverheadLayout.kelvinMk2.nodes, slice = OverheadLayout.kelvinSlice.nodes
        for k in [0, 1, 2, 4] { XCTAssertEqual(mk2[k], slice[k], "node \(k)") }
        XCTAssertEqual(mk2[KelvinMk2.spineRiser].kind, .abyssRiser)
        XCTAssertEqual(mk2[KelvinMk2.bridgeDuct].kind, .ductMouth)
        XCTAssertEqual(mk2[KelvinMk2.hubDuct].kind, .ductMouth)
        XCTAssertEqual(mk2[KelvinMk2.plazaDuct].kind, .ductMouth)
        for k in KelvinMk2.gantryPerches { XCTAssertEqual(mk2[k].kind, .perch) }
        for k in [KelvinMk2.chuteFoot, KelvinMk2.cRiser, KelvinMk2.bRiser, KelvinMk2.hxRiser] { XCTAssertEqual(mk2[k].kind, .abyssRiser) }
        XCTAssertEqual(mk2[KelvinMk2.mastA].kind, .mast)
        for k in KelvinMk2.liftMasts { XCTAssertEqual(mk2[k].kind, .mast) }
    }

    /// R6's steam valves sit on Mk II's pipes (design §1.2.1): the Spine Rack, B's heat exchanger, the plaza gantry over the
    /// head of the stairs down to the lift — each valve body on a pipe edge, at the pipe's height.
    func testR6sValvesSitOnTheMk2Pipes() {
        let o = OverheadLayout.kelvinMk2
        XCTAssertEqual(PropLayout.kelvin.valves.count, 4)
        for (k, v) in PropLayout.kelvin.valves.enumerated() {
            var on = false
            for e in o.edges where e.kind == .pipe {
                let A = o.nodes[Int(e.a)].p, B = o.nodes[Int(e.b)].p
                let dx = B.x - A.x, dz = B.z - A.z, l2 = dx * dx + dz * dz
                let u = max(0, min(1, ((v.x - A.x) * dx + (v.z - A.z) * dz) / l2))
                let px = A.x + dx * u, pz = A.z + dz * u, py = A.y + (B.y - A.y) * u
                if ((px - v.x) * (px - v.x) + (pz - v.z) * (pz - v.z)).squareRoot() < 0.08 && abs(py - v.y) < 0.08 { on = true }
            }
            XCTAssertTrue(on, "valve \(k) at (\(v.x), \(v.y), \(v.z)) on a Mk II pipe")
        }
    }

    func testDuctMouthsPerchesAndEntries() {
        let lv = mk2Level
        let G = try! XCTUnwrap(lv.overhead)
        XCTAssertEqual(G.ducts, [KelvinMk2.bridgeDuct, KelvinMk2.hubDuct, KelvinMk2.plazaDuct], "2–4 duct mouths per sector (R4)")
        for k in KelvinMk2.gantryPerches { XCTAssertTrue(G.perches.contains(k), "authored perch \(k)") }
        XCTAssertGreaterThanOrEqual(G.perches.count, 6)
        XCTAssertEqual(G.entries.count, 16)
        // every perch stands over the void (the far-side rule: a perched spitter against the dark, never over the walkway)
        for n in G.perches {
            let p = G.nodePos(n)
            XCTAssertEqual(lv.walkValue(lv.cellOf(p.x, p.z)), 0, "perch \(n) over the void")
        }
        // drop windows on most of the set (the lift's cables have none: their deck is the lift and its stairs)
        var withWindow = 0
        for e in 0..<G.edgeCount where G.w1[e] >= G.w0[e] { withWindow += 1 }
        XCTAssertGreaterThanOrEqual(withWindow, 30)
    }

    /// The readability exclusions of tech.md §2.2: the near half of the lift (the extraction camera's corridor) and the
    /// landing pad's title composition stay clear; beacons keep 6.1 m (routeCheck).
    func testTheLiftsNearHalfAndThePadStayClear() {
        let o = OverheadLayout.kelvinMk2
        let lift = KelvinStation().makeLayout(seed: 0).lift
        for (k, n) in o.nodes.enumerated() {
            let dx = n.p.x - lift.x, dz = n.p.z - lift.z
            if dx * dx + dz * dz < 20 * 20 { XCTAssertLessThan(dx + dz, 0, "node \(k) on the lift's far half") }
        }
        // on the pad only the Spine's deck post (R2's slice), 2 m in from its west edge
        let onPad = o.nodes.indices.filter { o.nodes[$0].p.x > 22 && o.nodes[$0].p.x < 38 && o.nodes[$0].p.z > 22 && o.nodes[$0].p.z < 38 }
        XCTAssertEqual(onPad, [0])
    }

    /// The classic mission's station: the app and the calibration presets' classic rows play Mk II; the bare station is
    /// still the v1.0 layout (the legacy row, the mechanics' tests, the generator's seed 0).
    func testTheClassicMissionPlaysMk2() {
        let bare = KelvinStation().makeLayout(seed: 0)
        XCTAssertTrue(bare.overhead.isEmpty)
        XCTAssertTrue(bare.props.isEmpty)
        let mk2 = KelvinStation.mk2.makeLayout(seed: 0)
        XCTAssertEqual(mk2.overhead, .kelvinMk2)
        XCTAssertEqual(mk2.props, .kelvin)
        XCTAssertEqual(mk2.rects.count, bare.rects.count)
        let gate = Calibration.preset("gate")!
        XCTAssertTrue(gate.filter { $0.tier >= 0 }.allSatisfy { $0.mk2 && !$0.props && $0.station == 0 })
        XCTAssertTrue(gate.filter { $0.tier < 0 }.allSatisfy { !$0.mk2 }, "the hidden legacy v1.0 row keeps the bare station")
        XCTAssertTrue(Calibration.preset("full")!.allSatisfy { $0.mk2 })
        XCTAssertFalse(Calibration.batch(tier: -1, mode: .auto, n: 1, mk2: true).contains { $0.mk2 })
        XCTAssertFalse(Calibration.batch(tier: 1, mode: .auto, n: 1, station: 3, mk2: true).contains { $0.mk2 })
        // a short classic row on Mk II carries the overhead's and the props' numbers
        let r = Calibration.run(CalibRun(tag: "vet", cls: .gunner, tier: 1, mode: .auto, maxs: 90, seed: 2100, mk2: true))
        XCTAssertNil(r.error)
        XCTAssertNotNil(r.oh)
        XCTAssertEqual(r.props?.circuits, 7)
        XCTAssertTrue(r.json.contains("\"oh\":{") && r.json.contains("\"props\":{"))
        XCTAssertEqual(CalibRow(json: r.json)?.oh, r.oh, "the row reads back")
    }

    /// The overhead in play in the classic mission (Veteran, autopilot, Mk II): packs go up the risers, masts and duct
    /// mouths, the Dropper and perch channels send theirs, drops are telegraphed, the caps hold, and it is deterministic.
    func testTheOverheadIsInPlayInTheClassicMission() {
        func play(_ seed: UInt32) -> Game {
            var c = GameConfig()
            c.difficulty = .veteran
            c.autopilot = true
            c.autoPickUpgrades = true
            c.god = true
            c.levelSource = KelvinStation.mk2
            let g = Game(seed: seed, playerClass: .cryo, config: c)
            for _ in 0..<(150 * 60) { g.tick(); g.clearEvents() }
            return g
        }
        let a = play(2024), b = play(2024)
        XCTAssertTrue(a.overheadOn)
        let s = a.overheadStats
        XCTAssertGreaterThan(s.packs, 5)
        XCTAssertGreaterThan(s.spawns, 20)
        XCTAssertGreaterThan(s.droppers, 0, "the Dropper channel")
        XCTAssertGreaterThan(s.drops, 0, "drops telegraphed")
        XCTAssertLessThanOrEqual(s.maxUp, Difficulty.veteran.routeCap)
        XCTAssertLessThanOrEqual(s.maxZones, Difficulty.veteran.dropCap)
        XCTAssertEqual(a.ducts.count, 3)
        XCTAssertEqual(a.circuits.count, 7)
        XCTAssertEqual(a.valves.count, 4)
        XCTAssertEqual(s, b.overheadStats)
        XCTAssertEqual(a.kills, b.kills)
        XCTAssertFalse(a.hasNonFinite())
    }
}
