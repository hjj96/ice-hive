import XCTest
import Foundation
@testable import IceHiveCore

/// T14: the seeded station generator is a bit-exact port of the web genLevel / genCheck (golden vectors from
/// origin/v1.1/e-stations @ ffeeea7, StationGolden.swift), seed 0 is «Кельвин-9», generated stations are playable.
enum StationFingerprint {
    /// FNV-1a 32 over bytes (web stHash).
    static func fnv<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var h: UInt32 = 0x811c_9dc5
        for b in bytes { h = (h ^ UInt32(b)) &* 0x0100_0193 }
        return h
    }
    static func le(_ v: [Int32]) -> [UInt8] {
        var o: [UInt8] = []
        o.reserveCapacity(v.count * 4)
        for x in v { let u = UInt32(bitPattern: x); o += [UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8(u >> 24)] }
        return o
    }

    /// Quantised layout hash (golden.mjs quant): int32 of JS Math.round(v·1000) in a fixed order, FNV-1a.
    static func quant(_ L: GeneratedStation) -> UInt32 {
        var a: [Int32] = []
        func q(_ v: Double) { a.append(Int32(truncatingIfNeeded: Int64(((v * 1000) + 0.5).rounded(.down)))) }
        q(Double(L.rects.count))
        for r in L.rects {
            q(r.x0); q(r.z0); q(r.x1); q(r.z1); q(r.slab ? 1 : 0); q(r.hazard ? 1 : 0)
            switch r.height {
            case .flat(let h): q(0); q(h)
            case .ramp(let ra, let ha, let b, let hb, let st): q(1); q(ra); q(ha); q(b); q(hb); q(st ? 1 : 0)
            }
        }
        q(Double(L.crates.count)); for c in L.crates { q(c.x0); q(c.z0); q(Double(c.w)); q(Double(c.d)); q(c.h) }
        q(Double(L.pillars.count)); for p in L.pillars { q(p.x); q(p.z) }
        q(Double(L.vents.count)); for v in L.vents { q(v.x); q(v.z) }
        q(Double(L.pipes.count)); for p in L.pipes { q(p.x0); q(p.z0); q(p.x1); q(p.z1); q(p.h) }
        q(L.start.x); q(L.start.z)
        for v in L.pad { q(v) }
        q(L.lift.x); q(L.lift.z); q(L.lift.r); q(L.lift.y)
        q(Double(L.beacons.count)); for b in L.beacons { q(b.x); q(b.z) }
        return fnv(le(a))
    }

    struct Raster {
        var walk: UInt32, floor: Int, blocked: Int, lift: UInt32, liftCells: Int, haz: UInt32, hazCells: Int
        var stair: UInt32, stairCells: Int, edges: Int, edgeHash: UInt32, hgtSum: Double, hgtSq: Double
    }

    /// The web rasterLevel fingerprints, measured on the native `Level`.
    static func raster(_ lv: Level) -> Raster {
        let n = GRID * GRID
        let walk = Array(UnsafeBufferPointer(start: lv.walk, count: n))
        let lift = Array(UnsafeBufferPointer(start: lv.liftCell, count: n))
        let haz = Array(UnsafeBufferPointer(start: lv.hazCell, count: n))
        let stair = Array(UnsafeBufferPointer(start: lv.stairCell, count: n))
        var hs = 0.0, hs2 = 0.0
        for c in 0..<n { let h = Double(lv.hgt[c]); hs += h; hs2 += h * h }
        let edgeCells = (0..<lv.edgeCount).map { Int32(lv.cellOf(lv.edgeX[$0], lv.edgeZ[$0])) }
        return Raster(walk: fnv(walk), floor: walk.filter { $0 == 1 }.count, blocked: walk.filter { $0 == 2 }.count,
                      lift: fnv(lift), liftCells: lift.filter { $0 == 1 }.count, haz: fnv(haz), hazCells: haz.filter { $0 == 1 }.count,
                      stair: fnv(stair), stairCells: stair.filter { $0 == 1 }.count, edges: edgeCells.count,
                      edgeHash: fnv(le(edgeCells)), hgtSum: hs, hgtSq: hs2)
    }
}

final class StationTests: XCTestCase {
    typealias F = StationFingerprint

    func testMulberryStreamsAndNames() {
        for (s, want) in StationGolden.rng {
            var r = SeededRNG(seed: UInt32(truncatingIfNeeded: s))
            XCTAssertEqual(want.map { _ in r.nextUInt32() }, want, "seed \(s)")
            var d = SeededRNG(seed: UInt32(truncatingIfNeeded: s))
            XCTAssertEqual(d.nextDouble(), Double(want[0]) / 4_294_967_296)
        }
        XCTAssertEqual(Stations.name(seed: 0), "Кельвин-9")
        XCTAssertEqual(Stations.name(seed: 7), "Сектор И-1")
        XCTAssertEqual(Stations.name(seed: 17), "Сектор Е-2")
        XCTAssertEqual(Stations.sanitize(12.9), 12)
        XCTAssertEqual(Stations.sanitize(0), 0)
        XCTAssertEqual(Stations.sanitize(-5), 0)
        XCTAssertEqual(Stations.sanitize(Double(0x4000_0000)), 0)
        XCTAssertEqual(Stations.sanitize(Double(0x3fff_ffff)), 0x3fff_ffff)
        XCTAssertEqual(Stations.sanitize(.nan), 0)
        XCTAssertEqual(Stations.sanitize(nil), 0)
    }

    func testSeedZeroIsKelvin() {
        let g = StationGenerator().makeLayout(seed: 0), k = KelvinStation().makeLayout(seed: 0)
        XCTAssertEqual(g.name, "Кельвин-9")
        XCTAssertFalse(g.isGenerated)
        XCTAssertEqual(g.pad, SIMD4<Float>(22, 22, 38, 38))
        XCTAssertEqual(g.rects.count, k.rects.count); XCTAssertEqual(g.crates.count, k.crates.count)
        let K = StationGolden.kelvin
        XCTAssertEqual(F.quant(Stations.kelvin), UInt32(K.quant), "hand level quant hash")
        let c = Stations.check(Stations.kelvin)
        XCTAssertTrue(c.ok, c.why)
        XCTAssertEqual(c.tour, K.tour)
        XCTAssertEqual(c.rim, K.rim)
        let r = F.raster(Level(source: StationGenerator(), seed: 0))
        XCTAssertEqual(r.walk, UInt32(K.walk)); XCTAssertEqual(r.floor, K.floor); XCTAssertEqual(r.blocked, K.blocked)
        XCTAssertEqual(r.lift, UInt32(K.lift)); XCTAssertEqual(r.liftCells, K.liftCells)
        XCTAssertEqual(r.haz, UInt32(K.haz)); XCTAssertEqual(r.hazCells, K.hazCells)
        XCTAssertEqual(r.stair, UInt32(K.stair)); XCTAssertEqual(r.stairCells, K.stairCells)
        XCTAssertEqual(r.edges, K.edges); XCTAssertEqual(r.edgeHash, UInt32(K.edgeHash))
        XCTAssertEqual(r.hgtSum, K.hgtSum, accuracy: 0.01)
        XCTAssertEqual(r.hgtSq, K.hgtSq, accuracy: 0.05)
        // byte-equal to today's level
        let a = F.raster(Level(source: KelvinStation()))
        XCTAssertEqual(a.walk, r.walk); XCTAssertEqual(a.edgeHash, r.edgeHash); XCTAssertEqual(a.hgtSum, r.hgtSum)
    }

    func testGoldenSeeds() {
        for (seed, attempts, tour, floor, rim, start, lift, beacons, counts, quant) in StationGolden.seeds {
            guard let L = Stations.generate(seed: seed) else { XCTFail("seed \(seed): no station"); continue }
            XCTAssertEqual(L.attempts, attempts, "seed \(seed) attempts")
            XCTAssertEqual(L.check?.tour, tour, "seed \(seed) tour")
            XCTAssertEqual(L.check?.floor, floor, "seed \(seed) floor")
            XCTAssertEqual(L.check?.rim, rim, "seed \(seed) rim")
            XCTAssertEqual(L.check?.ok, true)
            XCTAssertEqual(Float(L.start.x), start.0); XCTAssertEqual(Float(L.start.z), start.1)
            XCTAssertEqual(Float(L.lift.x), lift.0); XCTAssertEqual(Float(L.lift.z), lift.1); XCTAssertEqual(Float(L.lift.y), lift.2)
            XCTAssertEqual(L.beacons.map { Float($0.x) }, beacons.map { $0.0 }, "seed \(seed) beacons")
            XCTAssertEqual(L.beacons.map { Float($0.z) }, beacons.map { $0.1 })
            XCTAssertEqual([L.rects.count, L.crates.count, L.pillars.count, L.vents.count, L.pipes.count], counts, "seed \(seed) counts")
            XCTAssertEqual(F.quant(L), quant, "seed \(seed) quantised layout")
        }
        for (seed, attempts, tour, start, lift, quant) in StationGolden.bigSeeds {
            guard let L = Stations.generate(seed: seed) else { XCTFail("seed \(seed): no station"); continue }
            XCTAssertEqual(L.attempts, attempts, "seed \(seed)")
            XCTAssertEqual(L.check?.tour, tour, "seed \(seed)")
            XCTAssertEqual(Float(L.start.x), start.0); XCTAssertEqual(Float(L.start.z), start.1)
            XCTAssertEqual(Float(L.lift.x), lift.0); XCTAssertEqual(Float(L.lift.z), lift.1); XCTAssertEqual(Float(L.lift.y), lift.2)
            XCTAssertEqual(F.quant(L), quant, "seed \(seed) quantised layout")
        }
    }

    func testGoldenLayoutsFieldByField() throws {
        let data = try XCTUnwrap(StationGoldenLayouts.json.data(using: .utf8))
        let all = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func d(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? .nan }
        // (1e-12: some JSONSerialization builds parse decimals off by an ulp; the layout values come from the same
        // double arithmetic as the web, which the quantised hashes of testGoldenSeeds pin)
        func eq(_ a: [Double], _ b: [Double], _ msg: String) {
            XCTAssertEqual(a.count, b.count, msg)
            for (x, y) in zip(a, b) where !(abs(x - y) <= 1e-12 * max(1, abs(y))) { XCTFail("\(msg): \(a) vs \(b)"); return }
        }
        for (key, any) in all {
            let o = try XCTUnwrap(any as? [String: Any])
            let seed = try XCTUnwrap(UInt32(key))
            let L = try XCTUnwrap(Stations.generate(seed: seed))
            let rects = try XCTUnwrap(o["rects"] as? [[Any]])
            XCTAssertEqual(rects.count, L.rects.count)
            for (k, r) in rects.enumerated() where k < L.rects.count {
                let m = L.rects[k]
                eq([m.x0, m.z0, m.x1, m.z1], (0..<4).map { d(r[$0]) }, "seed \(seed) rect \(k)")
                XCTAssertEqual(m.slab, (r[4] as? String) == "s")
                XCTAssertEqual(m.hazard, d(r[5]) != 0)
                if let h = r[6] as? [String: Any] {
                    if case .ramp(let ra, let ha, let rb, let hb, let st) = m.height {
                        eq([ra, ha, rb, hb], [d(h["a"]), d(h["ha"]), d(h["b"]), d(h["hb"])], "seed \(seed) rect \(k) ramp")
                        XCTAssertEqual(st, (h["stairs"] as? Bool) ?? false)
                    } else { XCTFail("seed \(seed) rect \(k): flat, want a ramp") }
                } else {
                    if case .flat(let fh) = m.height { eq([fh], [d(r[6])], "seed \(seed) rect \(k) height") } else { XCTFail("seed \(seed) rect \(k): ramp, want flat") }
                }
            }
            let crates = try XCTUnwrap(o["crates"] as? [[Any]])
            XCTAssertEqual(crates.count, L.crates.count)
            for (k, c) in crates.enumerated() where k < L.crates.count {
                let m = L.crates[k]
                eq([m.x0, m.z0, Double(m.w), Double(m.d), m.h], (0..<5).map { d(c[$0]) }, "seed \(seed) crate \(k)")
            }
            let pil = try XCTUnwrap(o["pillars"] as? [[Any]]), ven = try XCTUnwrap(o["vents"] as? [[Any]])
            eq(pil.flatMap { [d($0[0]), d($0[1])] }, L.pillars.flatMap { [$0.x, $0.z] }, "seed \(seed) pillars")
            eq(ven.flatMap { [d($0[0]), d($0[1])] }, L.vents.flatMap { [$0.x, $0.z] }, "seed \(seed) vents")
            let pipes = try XCTUnwrap(o["pipes"] as? [[Any]])
            eq(pipes.flatMap { p in (0..<5).map { d(p[$0]) } }, L.pipes.flatMap { [$0.x0, $0.z0, $0.x1, $0.z1, $0.h] }, "seed \(seed) pipes")
            let st = try XCTUnwrap(o["start"] as? [String: Any]), lf = try XCTUnwrap(o["lift"] as? [String: Any])
            eq([d(st["x"]), d(st["z"])], [L.start.x, L.start.z], "seed \(seed) start")
            eq([d(lf["x"]), d(lf["z"]), d(lf["r"]), d(lf["y"])], [L.lift.x, L.lift.z, L.lift.r, L.lift.y], "seed \(seed) lift")
            eq((o["pad"] as? [Any])?.map { d($0) } ?? [], L.pad, "seed \(seed) pad")
            let bs = try XCTUnwrap(o["beacons"] as? [[String: Any]])
            eq(bs.flatMap { [d($0["x"]), d($0["z"])] }, L.beacons.flatMap { [$0.x, $0.z] }, "seed \(seed) beacons")
            XCTAssertEqual(bs.map { $0["name"] as? String ?? "" }, L.beacons.map { $0.name })
            let meta = try XCTUnwrap(o["meta"] as? [String: Any])
            eq((meta["rowH"] as? [Any])?.map { d($0) } ?? [], L.rowH, "seed \(seed) rowH")
            XCTAssertEqual(Int(d(meta["nodes"])), L.nodes)
            XCTAssertEqual(Int(d(meta["start"])), L.startNode)
            XCTAssertEqual(Int(d(meta["lift"])), L.liftNode)
            XCTAssertEqual((meta["beac"] as? [Any])?.map { Int(d($0)) }, L.beaconNodes)
            XCTAssertEqual(Int(d(meta["edges"])), L.edges)
            XCTAssertEqual(Int(d(o["attempts"])), L.attempts)
        }
        XCTAssertEqual(StationGenerator().makeLayout(seed: 7).name, "Сектор И-1")
    }

    func testRasterFingerprintsOfGeneratedSeeds() {
        for (seed, walk, floor, blocked, liftCells, hazCells, stairCells, edges, edgeHash, hgtSum) in StationGolden.rasters {
            let r = F.raster(Level(source: StationGenerator(), seed: seed))
            XCTAssertEqual(r.walk, walk, "seed \(seed) walk")
            XCTAssertEqual(r.floor, floor, "seed \(seed)"); XCTAssertEqual(r.blocked, blocked, "seed \(seed)")
            XCTAssertEqual(r.liftCells, liftCells); XCTAssertEqual(r.hazCells, hazCells, "seed \(seed)")
            XCTAssertEqual(r.stairCells, stairCells, "seed \(seed)")
            XCTAssertEqual(r.edges, edges, "seed \(seed) edges"); XCTAssertEqual(r.edgeHash, edgeHash, "seed \(seed) edge hash")
            XCTAssertEqual(r.hgtSum, hgtSum, accuracy: 0.05, "seed \(seed) Σhgt")
        }
    }

    /// Independent of genCheck: on the native `Level`, the start reaches every beacon ring and the lift, almost all of
    /// the floor is one region, and the Матка has a far-side rim edge to climb.
    func testGeneratedStationsArePlayableOnTheNativeLevel() {
        for seed: UInt32 in 1...200 {
            let lv = Level(source: StationGenerator(), seed: seed)
            XCTAssertTrue(lv.layout.isGenerated, "seed \(seed) fell back")
            let n = GRID * GRID
            var dist = [Int32](repeating: -1, count: n)
            var q = [Int](), head = 0
            let s0 = lv.cellOf(lv.start.x, lv.start.y)
            XCTAssertEqual(lv.walk[s0], 1, "seed \(seed): start on floor")
            dist[s0] = 0; q.append(s0)
            while head < q.count {
                let c = q[head]; head += 1
                for nb in [c - 1, c + 1, c - GRID, c + GRID] where nb >= 0 && nb < n && dist[nb] < 0 && lv.walk[nb] == 1 {
                    dist[nb] = dist[c] + 1; q.append(nb)
                }
            }
            var floor = 0, reach = 0
            for c in 0..<n where lv.walk[c] == 1 { floor += 1; if dist[c] >= 0 { reach += 1 } }
            XCTAssertGreaterThanOrEqual(Double(reach) / Double(floor), 0.97, "seed \(seed) reach")
            func reachable(_ x: Float, _ z: Float, _ r: Float) -> Bool {
                for c in 0..<n where dist[c] >= 0 {
                    let dx = Float(c % GRID) - GRID_HALF + 0.5 - x, dz = Float(c / GRID) - GRID_HALF + 0.5 - z
                    if dx * dx + dz * dz <= r * r { return true }
                }
                return false
            }
            for b in lv.layout.beacons { XCTAssertTrue(reachable(b.x, b.z, BEACON_R), "seed \(seed) beacon \(b.name)") }
            XCTAssertTrue(reachable(lv.lift.x, lv.lift.z, lv.lift.r - 1), "seed \(seed) lift")
            var rim = 0
            let r2 = (lv.lift.r + 1.5) * (lv.lift.r + 1.5)
            for e in 0..<lv.edgeCount {
                let dx = lv.edgeX[e] - lv.lift.x, dz = lv.edgeZ[e] - lv.lift.z
                if dx * dx + dz * dz < r2 && dz < -4 { rim += 1 }
            }
            XCTAssertGreaterThan(rim, 0, "seed \(seed): far-side rim edge for the Матка")
        }
    }

    func testTooFewNodesFallsBack() {
        XCTAssertNil(Stations.generate(seed: 5, nodes: 3))
        XCTAssertNotNil(Stations.generate(seed: 5))
    }

    /// A short autopilot run (Новобранец, 120 s) on seeds 1–4: no NaN, every marine on walkable cells.
    func testShortAutopilotRunsOnGeneratedStations() {
        for seed: UInt32 in 1...4 {
            var c = GameConfig()
            c.difficulty = .recruit; c.autopilot = true; c.autoPickUpgrades = true
            let lv = Level(source: StationGenerator(), seed: seed)
            let g = Game(seed: 100 + seed, playerClass: MarineClass(rawValue: Int(seed) % 4)!, config: c, level: lv)
            XCTAssertEqual(g.stationName, Stations.name(seed: seed))
            for t in 0..<(120 * 60) {
                g.tick(); g.clearEvents()
                if t % 60 == 0 {
                    XCTAssertFalse(g.hasNonFinite(), "seed \(seed) t=\(g.time)")
                    for m in g.marines where !m.downed {
                        XCTAssertNotEqual(lv.walk[max(0, lv.cellOf(m.x, m.z))], 0, "seed \(seed): \(m.name) over the abyss at t=\(g.time)")
                    }
                }
                if g.phase != .playing { break }
            }
            XCTAssertGreaterThan(g.kills, 50, "seed \(seed)")
        }
    }
}
