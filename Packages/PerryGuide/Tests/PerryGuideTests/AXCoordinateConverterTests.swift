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
}
