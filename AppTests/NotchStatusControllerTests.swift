import XCTest
@testable import Perry

final class NotchStatusControllerTests: XCTestCase {
    @MainActor
    func testNativePanelKeepsRequestedScreenEdgeAfterPresentation() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let requested = HomeController.notchPanelFrame(
            size: CGSize(width: 480, height: 380), screenFrame: screen.frame, centerX: screen.frame.midX
        )
        let panel = CompactConversationPanel(contentRect: requested, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        defer { panel.close() }
        panel.setFrame(requested, display: true)
        panel.orderFrontRegardless()
        XCTAssertEqual(panel.frame.maxY, screen.frame.maxY, accuracy: 0.5)
        XCTAssertEqual(panel.constrainFrameRect(requested, to: screen), requested)
    }

    func testPillPresentsOnlyWhenEnabledWithMeaningfulContent() {
        XCTAssertFalse(NotchStatusController.shouldPresent(isEnabled: true, isRecording: false, backgroundCount: 0, awaitingApproval: 0))
        XCTAssertTrue(NotchStatusController.shouldPresent(isEnabled: true, isRecording: true, backgroundCount: 0, awaitingApproval: 0))
        XCTAssertTrue(NotchStatusController.shouldPresent(isEnabled: true, isRecording: false, backgroundCount: 2, awaitingApproval: 0))
        XCTAssertTrue(NotchStatusController.shouldPresent(isEnabled: true, isRecording: false, backgroundCount: 0, awaitingApproval: 1))
        XCTAssertFalse(NotchStatusController.shouldPresent(isEnabled: false, isRecording: true, backgroundCount: 3, awaitingApproval: 0))
        XCTAssertFalse(NotchStatusController.shouldPresent(isEnabled: false, isRecording: false, backgroundCount: 0, awaitingApproval: 2))
        XCTAssertTrue(
            NotchStatusController.shouldPresent(isEnabled: false, isRecording: false, backgroundCount: 0, awaitingApproval: 0, listeningForWake: true),
            "an open ambient microphone stays visible even with the status indicator turned off"
        )
    }

}
