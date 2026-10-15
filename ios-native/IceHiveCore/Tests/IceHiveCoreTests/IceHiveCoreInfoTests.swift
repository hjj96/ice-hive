import XCTest
@testable import IceHiveCore

final class IceHiveCoreInfoTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertEqual(IceHiveCoreInfo.version, "0.0.1")
    }
}
