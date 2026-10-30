import AppKit
import XCTest
import PerryBrain
import PerryCore
import PerryGuide
import PerryOverlay
@testable import Perry

@MainActor
final class TalkSessionStateTests: XCTestCase {
    func testTalkLifecycle() throws {
        let controller = SessionController()
        let attemptID = UUID()
        try controller.wake(attemptID: attemptID)
        var talk = TalkSessionState(id: UUID(), startedAt: Date(), transcript: "")
        talk.isListening = true
        try controller.startTalk(talk, attemptID: attemptID)
        guard case .talking = controller.state else {
            return XCTFail("expected .talking")
        }
        controller.updateTalk { $0.transcript = "what is this" }
        guard case .talking(let live) = controller.state else {
            return XCTFail("expected .talking")
        }
        XCTAssertEqual(live.transcript, "what is this")
        try controller.completeDismissal()
        XCTAssertEqual(controller.state, .idle)
    }

    func testStartTalkRequiresInvocation() {
        let controller = SessionController()
        XCTAssertThrowsError(
            try controller.startTalk(TalkSessionState(id: UUID(), startedAt: Date(), transcript: ""), attemptID: UUID())
        )
    }

    func testUpdateTalkIsNoOpOutsideTalking() {
        let controller = SessionController()
        controller.updateTalk { $0.transcript = "ghost" }
        XCTAssertEqual(controller.state, .idle)
    }
}
