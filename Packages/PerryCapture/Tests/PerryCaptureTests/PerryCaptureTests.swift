import XCTest
@testable import PerryCapture

final class PerryCaptureSmokeTests: XCTestCase {
    func testPackageLoads() {
        XCTAssertEqual(PerryCaptureInfo.version, "0.1.0")
    }
}
