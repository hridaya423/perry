import Combine
import CoreGraphics
import XCTest
@testable import PerryOverlay

@MainActor
final class OverlayPointerTests: XCTestCase {
    func testPublishesOnlyForThisScreenAndRealMovement() {
        let pointer = OverlayPointer(screenFrame: CGRect(x: 10_000, y: 10_000, width: 800, height: 600))
        var changes = 0
        let watch = pointer.objectWillChange.sink { changes += 1 }
        defer { watch.cancel() }
        let start = changes
        pointer.follow(CGPoint(x: -500, y: 20))
        pointer.follow(CGPoint(x: -400, y: 30))
        XCTAssertEqual(changes, start, "a pointer on another screen must not re-render this one")

        pointer.follow(CGPoint(x: 10_100, y: 10_100))
        XCTAssertTrue(pointer.onScreen)
        let arrived = changes
        pointer.follow(CGPoint(x: 10_100.2, y: 10_100.2))
        XCTAssertEqual(changes, arrived, "sub-half-point moves are dropped")
        pointer.follow(CGPoint(x: 10_110, y: 10_100))
        XCTAssertEqual(changes, arrived + 1)
    }
}
