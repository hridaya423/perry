import XCTest
@testable import PerryOverlay

final class MarkLifetimeTests: XCTestCase {
    func testClickingAMarkRemovesItAndLeavesTheOthers() {
        let state = PerryCursorState()
        let settings = PerryGuidanceOverlay.ringMark(around: CGRect(x: 100, y: 100, width: 40, height: 20))
        let other = PerryGuidanceOverlay.ringMark(around: CGRect(x: 600, y: 600, width: 40, height: 20))
        state.visualGuidanceOverlays = [settings, other]
        state.dismissMarks(at: CGPoint(x: 120, y: 110))
        XCTAssertEqual(state.visualGuidanceOverlays.map(\.id), [other.id])
        state.dismissMarks(at: CGPoint(x: 300, y: 300))
        XCTAssertEqual(state.visualGuidanceOverlays.map(\.id), [other.id])
    }

    func testAMarkGoesAwayAfterItsDuration() {
        let state = PerryCursorState()
        state.visualGuidanceOverlays = [.ringMark(around: CGRect(x: 0, y: 0, width: 20, height: 20), duration: 0.3)]
        let gone = expectation(description: "expired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            XCTAssertTrue(state.visualGuidanceOverlays.isEmpty)
            gone.fulfill()
        }
        wait(for: [gone], timeout: 2)
    }
}
