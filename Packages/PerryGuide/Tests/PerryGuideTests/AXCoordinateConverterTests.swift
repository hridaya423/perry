import XCTest
@testable import PerryGuide

final class AXCoordinateConverterTests: XCTestCase {
    func testConvertsTopLeftOriginToBottomLeftOrigin() {
        let rect = AXCoordinateConverter.appKitRect(
            axX: 100, axY: 200, width: 80, height: 24,
            primaryScreenMaxY: 900
        )
        XCTAssertEqual(rect.minX, 100)
        XCTAssertEqual(rect.maxY, 700)
        XCTAssertEqual(rect.height, 24)
        XCTAssertEqual(rect.width, 80)
    }

    func testTopOfScreenMapsToPrimaryMaxY() {
        let rect = AXCoordinateConverter.appKitRect(
            axX: 0, axY: 0, width: 400, height: 20,
            primaryScreenMaxY: 1080
        )
        XCTAssertEqual(rect.maxY, 1080)
    }
}
