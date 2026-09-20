import AppKit
import XCTest
import PerryCore
@testable import Perry

@MainActor
final class InteractivePanelTests: XCTestCase {
    func testBackgroundTasksPanelCanActivateForKeyboardInput() {
        let window = BackgroundTasksWindow(
            backgroundTasks: AppController.shared.backgroundTasks,
            runtimes: AppController.shared.runtimes
        )

        XCTAssertTrue(window.canBecomeKey)
        XCTAssertFalse(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(window.styleMask.contains(.resizable))
    }

    func testHistoryPanelCanActivateForSearchAndExport() {
        let window = HistoryWindow(store: TranscriptStore(directory: nil), activityLog: ActivityLog(storageDirectory: nil))

        XCTAssertTrue(window.canBecomeKey)
        XCTAssertFalse(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(window.styleMask.contains(.resizable))
    }

    func testWhatsNewPanelCanActivateAndGrowWithContent() {
        let window = WhatsNewWindow()

        XCTAssertTrue(window.canBecomeKey)
        XCTAssertFalse(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.minSize, NSSize(width: 440, height: 360))
    }

    func testCompleteErasureRequiresTheDestructiveButtonResponse() {
        XCTAssertTrue(CompleteErasurePrompt.isConfirmed(.alertFirstButtonReturn))
        XCTAssertFalse(CompleteErasurePrompt.isConfirmed(.alertSecondButtonReturn))
        XCTAssertFalse(CompleteErasurePrompt.isConfirmed(.cancel))
    }

    func testActivityStripActivatesOnlyWhenExpanded() {
        let state = AgentActivityStripState()
        let window = AgentActivityStripWindow(
            state: state,
            onPause: {},
            onResume: {},
            onStop: {},
            onRetry: {},
            onSteer: { _ in }
        )

        XCTAssertFalse(window.canBecomeKey)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))

        window.setExpanded(true, animate: false)
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertFalse(window.styleMask.contains(.nonactivatingPanel))

        window.setExpanded(false, animate: false)
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
    }

    func testActivityStripControlAvailabilityFollowsTaskPhaseAndRetryFinalization() {
        let state = AgentActivityStripState()

        XCTAssertFalse(state.steeringIsAvailable)
        XCTAssertFalse(state.stopIsAvailable)
        XCTAssertFalse(state.retryIsAvailable)

        state.phase = .starting
        XCTAssertFalse(state.steeringIsAvailable)
        XCTAssertTrue(state.stopIsAvailable)

        state.phase = .working
        XCTAssertTrue(state.steeringIsAvailable)
        XCTAssertTrue(state.stopIsAvailable)

        state.phase = .paused
        XCTAssertTrue(state.steeringIsAvailable)
        XCTAssertTrue(state.stopIsAvailable)

        state.phase = .confirming
        XCTAssertFalse(state.steeringIsAvailable)
        XCTAssertTrue(state.stopIsAvailable)

        state.phase = .verifying
        XCTAssertFalse(state.steeringIsAvailable)
        XCTAssertTrue(state.stopIsAvailable)

        state.phase = .failed
        XCTAssertFalse(state.stopIsAvailable)
        XCTAssertFalse(state.retryIsAvailable)

        state.canRetry = true
        XCTAssertTrue(state.retryIsAvailable)

        state.phase = .reporting
        XCTAssertFalse(state.retryIsAvailable)
    }

    func testActivityStripWindowReconcilesAfterStateReset() {
        let state = AgentActivityStripState()
        let window = AgentActivityStripWindow(
            state: state,
            onPause: {},
            onResume: {},
            onStop: {},
            onRetry: {},
            onSteer: { _ in }
        )

        window.setExpanded(true, animate: false)
        state.reset()
        window.setExpanded(false, animate: false)

        XCTAssertEqual(window.frame.size, NSSize(width: 300, height: 72))
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
    }

    func testActivityStripProjectsForegroundExecutionFromSessionState() throws {
        let session = SessionController()
        let taskID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let stepStartedAt = startedAt.addingTimeInterval(2)
        let approvalID = UUID()

        try session.wake(at: startedAt)
        try session.startExecution(
            ExecutionSessionState(
                taskID: taskID,
                goal: "Rename the selected file",
                startedAt: startedAt,
                appBundleID: "com.apple.finder",
                workspace: URL(fileURLWithPath: "/tmp/perry-activity-projection"),
                lifecycle: .starting
            )
        )
        try session.setPlannedStepCount(2)
        try session.setExecutionPhase(.running)
        try session.recordExecutionStep(
            id: "rename",
            summary: "Rename the file",
            tier: .yellow,
            reversible: true,
            index: 1,
            startedAt: stepStartedAt
        )
        try session.awaitApproval(approvalID, actionSummary: "Send the renamed file", tier: .orange)

        let activity = AgentActivityStripState()
        activity.apply(sessionState: session.state)

        XCTAssertEqual(activity.phase, .confirming)
        XCTAssertEqual(activity.title, "Approval needed")
        XCTAssertEqual(activity.detail, "Send the renamed file")
        XCTAssertEqual(activity.progress, 0.5)
        XCTAssertEqual(activity.tier, .orange)
        XCTAssertEqual(activity.startedAt, startedAt)
        XCTAssertEqual(activity.steps.map(\.summary), ["Rename the file"])
        XCTAssertEqual(activity.steps.first?.tier, .yellow)
        XCTAssertEqual(activity.steps.first?.timestamp, stepStartedAt)
    }
}
