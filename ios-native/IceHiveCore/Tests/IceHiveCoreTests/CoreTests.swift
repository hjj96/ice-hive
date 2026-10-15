import XCTest
@testable import IceHiveCore

final class CoreTests: XCTestCase {
    func testRNGIsDeterministicAndInRange() {
        var a = SeededRNG(seed: 42), b = SeededRNG(seed: 42), c = SeededRNG(seed: 43)
        var same = true, differs = false
        for _ in 0..<10_000 {
            let x = a.next(), y = b.next(), z = c.next()
            XCTAssert(x >= 0 && x < 1)
            if x != y { same = false }
            if x != z { differs = true }
        }
        XCTAssertTrue(same)
        XCTAssertTrue(differs)
        var r = SeededRNG(seed: 7)
        for _ in 0..<10_000 { let k = r.int(5); XCTAssert(k >= 0 && k < 5) }
    }

    func testMulberry32MatchesWebGenerator() {
        // first outputs of mulberry32(1) in the web game: ((t ^ t >>> 14) >>> 0) / 2^32
        var r = SeededRNG(seed: 1)
        let u = r.nextUInt32()
        XCTAssertEqual(Double(u) / 4294967296.0, 0.6270739405881613, accuracy: 1e-12)
    }

    func testAngDiff() {
        XCTAssertEqual(angDiff(0, 1), 1, accuracy: 1e-6)
        XCTAssertEqual(angDiff(3, -3), Float(-6 + 2 * Double.pi), accuracy: 1e-5)
        XCTAssertEqual(angDiff(0, 100 * TAU + 0.5), 0.5, accuracy: 1e-3)
        XCTAssertEqual(angDiff(0, .nan), 0)
    }

    func testFormatTime() {
        XCTAssertEqual(formatTime(0), "0:00")
        XCTAssertEqual(formatTime(65.7), "1:05")
        XCTAssertEqual(formatTime(-3), "0:00")
    }

    func testXpTable() {
        XCTAssertEqual(xpFor(1), 40)
        XCTAssertEqual(xpFor(2), 68)   // 40*1.4 + 12
        XCTAssertEqual(xpFor(3), 102)  // 40*1.96 + 24 = 102.4
    }
}
