import XCTest
@testable import PerryOverlay

final class PerryOverlaySmokeTests: XCTestCase {
    func testCursorTrackingDegradedHookFiresOnTransitionOnly() {
        let probe = OverlayPerfProbe.shared
        var fires = 0
        probe.onCursorTrackingDegraded = { fires += 1 }
        defer { probe.onCursorTrackingDegraded = nil; probe.markCursorTrackingDegraded(false) }

        probe.markCursorTrackingDegraded(false)
        XCTAssertEqual(fires, 0)
        XCTAssertFalse(probe.cursorTrackingDegraded)

        probe.markCursorTrackingDegraded(true)
        XCTAssertEqual(fires, 1)
        XCTAssertTrue(probe.cursorTrackingDegraded)

        probe.markCursorTrackingDegraded(false)
        XCTAssertEqual(fires, 1)
        XCTAssertFalse(probe.cursorTrackingDegraded)
    }
}
