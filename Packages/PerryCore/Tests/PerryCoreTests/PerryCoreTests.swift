import XCTest
@testable import PerryCore

final class PerryCoreSmokeTests: XCTestCase {
    func testPackageLoads() {
        XCTAssertEqual(PerryCoreInfo.version, "0.1.0")
    }
}
