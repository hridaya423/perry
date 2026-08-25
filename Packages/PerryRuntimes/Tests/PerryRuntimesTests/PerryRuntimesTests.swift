import XCTest
@testable import PerryRuntimes

final class PerryRuntimesSmokeTests: XCTestCase {
    func testPackageLoads() {
        XCTAssertEqual(PerryRuntimesInfo.version, "0.1.0")
    }
}
