import XCTest
@testable import PerryOverlay

final class PerryOverlaySmokeTests: XCTestCase {
    func testPackageLoads() {
        XCTAssertEqual(PerryOverlayInfo.version, "0.1.0")
    }
}
