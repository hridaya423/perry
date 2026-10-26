import XCTest
@testable import PerryOverlay

final class TaskBubbleLifetimeTests: XCTestCase {
    func testBubbleClearsAfterExpiry() {
        let state = PerryCursorState()
        state.taskBubbleText = "Answer ready"
        state.expireTaskBubble(after: 0.05)
        let cleared = expectation(description: "cleared")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertNil(state.taskBubbleText)
            cleared.fulfill()
        }
        wait(for: [cleared], timeout: 1)
    }

    func testNewerTextSurvivesOlderExpiry() {
        let state = PerryCursorState()
        state.taskBubbleText = "First sentence."
        state.expireTaskBubble(after: 0.05)
        state.taskBubbleText = "Second sentence."
        let kept = expectation(description: "kept")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(state.taskBubbleText, "Second sentence.")
            kept.fulfill()
        }
        wait(for: [kept], timeout: 1)
    }
}
