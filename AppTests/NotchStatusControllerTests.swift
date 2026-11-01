import XCTest
@testable import Perry

final class NotchStatusControllerTests: XCTestCase {
    @MainActor
    func testNativePanelKeepsRequestedScreenEdgeAfterPresentation() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let requested = NotchGeometry.panelFrame(
            size: CGSize(width: 480, height: 380), screenFrame: screen.frame, centerX: screen.frame.midX
        )
        let panel = PerryPanel(frame: requested, canBecomeKey: true)
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        defer { panel.close() }
        panel.setFrame(requested, display: true)
        panel.orderFrontRegardless()
        XCTAssertEqual(panel.frame.maxY, screen.frame.maxY, accuracy: 0.5)
        XCTAssertEqual(panel.constrainFrameRect(requested, to: screen), requested)
    }

    func testPillPresentsForMeaningfulContentRegardlessOfTheNotchToggle() {
        XCTAssertFalse(NotchStatusController.shouldPresent(isRecording: false, backgroundCount: 0, awaitingApproval: 0))
        XCTAssertTrue(NotchStatusController.shouldPresent(isRecording: true, backgroundCount: 0, awaitingApproval: 0))
        XCTAssertTrue(NotchStatusController.shouldPresent(isRecording: false, backgroundCount: 2, awaitingApproval: 0))
        XCTAssertTrue(NotchStatusController.shouldPresent(isRecording: false, backgroundCount: 0, awaitingApproval: 1))
        XCTAssertTrue(NotchStatusController.shouldPresent(isRecording: false, backgroundCount: 0, awaitingApproval: 0, listeningForWake: true))
    }

}
