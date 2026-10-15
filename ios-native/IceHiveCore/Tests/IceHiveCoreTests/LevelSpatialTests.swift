import XCTest
@testable import IceHiveCore

final class LevelTests: XCTestCase {
    let level = Level(source: KelvinStation(), seed: 1)

    func testLayoutRaster() {
        let L = level
        // landing pad, plaza, lift tiers
        XCTAssertTrue(L.walkable(30, 30))
        XCTAssertEqual(L.groundY(30, 30), 0, accuracy: 1e-5)
        XCTAssertEqual(L.groundY(0, -5), -3, accuracy: 1e-5)
        XCTAssertEqual(L.groundY(-3, -42), -6, accuracy: 1e-5)
        // staircase hub -> plaza: halfway down
        XCTAssertEqual(L.groundY(-1, 10), -1.5, accuracy: 0.11)
        // abyss
        XCTAssertFalse(L.walkable(0, 50))
        XCTAssertFalse(L.walkable(60, 60))
        XCTAssertFalse(L.walkable(.nan, 0))
        XCTAssertEqual(L.cellOf(1000, 0), -1)
        // props block: pillar, crate, beacon base
        XCTAssertFalse(L.walkable(23.5, 23.5))
        XCTAssertEqual(L.walkValue(L.cellOf(24.5, 35.5)), 2)
        XCTAssertFalse(L.walkable(-32.5, 26.5))
        XCTAssertTrue(L.solid(-32.5, 26.5))
        // lift deck
        XCTAssertTrue(L.onLift(-3, -42))
        XCTAssertTrue(L.isLiftCell(L.cellOf(-3, -42)))
        XCTAssertTrue(L.canStand(30, 30))
        // spawn edges exist, sit on floor and point outward to the abyss
        XCTAssertGreaterThan(L.edgeCount, 200)
        for e in stride(from: 0, to: L.edgeCount, by: 7) {
            let x = L.edgeX[e], z = L.edgeZ[e]
            XCTAssertTrue(L.walkable(x, z))
            XCTAssertFalse(L.solid(x + L.edgeNX[e] * 1.0, z + L.edgeNZ[e] * 1.0), "edge \(e) normal does not point into the abyss")
        }
    }

    func testCellHelpers() {
        let c = level.cellOf(0.2, -0.7)
        XCTAssertEqual(Level.cellX(c), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Level.cellZ(c), -0.5, accuracy: 1e-6)
        XCTAssertEqual(Level.cellClamp(-1000, .nan), 0)
        XCTAssertEqual(Level.cellClamp(1000, 1000), GRID * GRID - 1)
    }
}

final class SpatialTests: XCTestCase {
    func makeSwarm(_ n: Int, seed: UInt32) -> Swarm {
        let S = Swarm(capacity: MAX_BUGS)
        var r = SeededRNG(seed: seed)
        for i in 0..<n {
            S.x[i] = r.range(-20, 20); S.z[i] = r.range(-20, 20); S.r[i] = r.range(0.2, 0.9)
            S.dead[i] = r.next() < 0.1 ? 1 : 0; S.st[i] = 0; S.uid[i] = Int32(i + 1)
        }
        S.count = n
        return S
    }

    func testQueryCircleMatchesBruteForce() {
        let S = makeSwarm(1500, seed: 3)
        let H = SpatialHash(capacity: MAX_BUGS)
        H.rebuild(S)
        var r = SeededRNG(seed: 9)
        for _ in 0..<200 {
            let x = r.range(-25, 25), z = r.range(-25, 25), rad = r.range(0.1, 9)
            let n = H.queryCircle(S, x, z, rad)
            let got = Set((0..<n).map { Int(H.qb[$0]) })
            var want = Set<Int>()
            for i in 0..<S.count where S.dead[i] == 0 {
                let dx = S.x[i] - x, dz = S.z[i] - z, rr = rad + S.r[i]
                if dx * dx + dz * dz < rr * rr { want.insert(i) }
            }
            XCTAssertEqual(got, want)
        }
    }

    func testHashCountingSortCoversAllBugs() {
        let S = makeSwarm(1000, seed: 5)
        let H = SpatialHash(capacity: MAX_BUGS)
        H.rebuild(S)
        XCTAssertEqual(Int(H.start[GRID * GRID]), 1000)
        var seen = [Bool](repeating: false, count: 1000)
        for c in 0..<(GRID * GRID) {
            for k in Int(H.start[c])..<Int(H.start[c + 1]) {
                let b = Int(H.items[k])
                XCTAssertFalse(seen[b]); seen[b] = true
                XCTAssertEqual(Int(H.cell[b]), c)
                XCTAssertEqual(Level.cellClamp(S.x[b], S.z[b]), c)
            }
        }
        XCTAssertTrue(seen.allSatisfy { $0 })
    }

    func testRaycastFindsNearestBug() {
        let S = Swarm(capacity: 16)
        // three bugs on the +x axis, the middle one dead, plus one off-axis
        let xs: [Float] = [5, 3, 9, 4], zs: [Float] = [0, 0, 0, 3], dead: [UInt8] = [0, 1, 0, 0]
        for i in 0..<4 { S.x[i] = xs[i]; S.z[i] = zs[i]; S.r[i] = 0.5; S.dead[i] = dead[i]; S.st[i] = 0; S.uid[i] = Int32(i + 1) }
        S.count = 4
        let H = SpatialHash(capacity: 16)
        H.rebuild(S)
        let (d, b) = H.raycast(S, 0, 0, 1, 0, 24)
        XCTAssertEqual(b, 0)
        XCTAssertEqual(d, 4.5, accuracy: 1e-4)
        let (d2, b2) = H.raycast(S, 0, 0, -1, 0, 24)
        XCTAssertEqual(b2, -1)
        XCTAssertEqual(d2, 24)
        // segment hit honours the excluded uid (pierce) and the length
        let (s1, t1) = H.segmentHit(S, 0, 0, 1, 0, 10, 0)
        XCTAssertEqual(s1, 0); XCTAssertEqual(t1, 5, accuracy: 1e-4)
        let (s2, _) = H.segmentHit(S, 0, 0, 1, 0, 10, 1)
        XCTAssertEqual(s2, 2)
        let (s3, _) = H.segmentHit(S, 0, 0, 1, 0, 2, 0)
        XCTAssertEqual(s3, -1)
    }

    func testFlowFieldLeadsToSource() {
        let L = Level(source: KelvinStation(), seed: 1)
        let F = FlowField()
        let q = UnsafeMutablePointer<Int32>.allocate(capacity: GRID * GRID)
        defer { q.deallocate() }
        let src: [Float] = [30, 30]
        src.withUnsafeBufferPointer { F.compute(level: L, sources: $0, queue: q) }
        let s = L.cellOf(30, 30)
        XCTAssertEqual(F.distance(s), 0)
        // the lift is reachable (via the stairs), the abyss is not
        let lc = L.cellOf(-3, -42)
        XCTAssertLessThan(F.distance(lc), 200)
        XCTAssertEqual(F.distance(L.cellOf(0, 50)), FlowField.unreachable)
        // BFS distances: neighbours differ by at most 1
        for c in 0..<(GRID * GRID) where F.d[c] != FlowField.unreachable {
            let i = c % GRID
            if i + 1 < GRID && F.d[c + 1] != FlowField.unreachable { XCTAssertLessThanOrEqual(abs(Int(F.d[c]) - Int(F.d[c + 1])), 1) }
        }
        // walking the field from far cells reaches the source
        for (x0, z0) in [(-3, -42), (-36.5, -9.5), (-32, 30.5), (30.5, -11.5), (0, -5), (-41, -1), (37, -15)] as [(Float, Float)] {
            var x = x0, z = z0
            var steps = 0
            while steps < 4000 {
                let c = L.cellOf(x, z)
                XCTAssertGreaterThanOrEqual(c, 0)
                if c < 0 || F.distance(c) == 0 { break }
                let d = F.direction(c)
                XCTAssertTrue(d.x != 0 || d.y != 0, "dead end at \(x),\(z)")
                if d.x == 0 && d.y == 0 { break }
                // a walker like a bug: small steps along the field of the current cell
                x += d.x * 0.3; z += d.y * 0.3
                XCTAssertTrue(L.solid(x, z), "flow leads off the floor at \(x),\(z)")
                steps += 1
            }
            XCTAssertEqual(F.distance(L.cellOf(x, z)), 0, "did not reach the source from \(x0),\(z0)")
        }
    }
}
