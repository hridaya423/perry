import AppKit
import XCTest
import PerryCore
import PerryGuide
import SwiftUI
@testable import Perry

@MainActor
final class InteractivePanelTests: XCTestCase {
    func testRenderSupportingSurfaces() throws {
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/living-ink-evidence")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let guide = GuideControlsState()
        guide.targetLabel = "Export a transparent copy"
        let activity = AgentActivityStripState()
        activity.phase = .working
        activity.title = "Organizing your notes"
        activity.detail = "Moving three draft notes into the project folder."
        activity.isExpanded = true
        let longActivity = AgentActivityStripState()
        longActivity.phase = .working
        longActivity.title = "Organizing your notes"
        longActivity.detail = "Review the completed steps below."
        longActivity.isExpanded = true
        longActivity.steps = (1...20).map {
            AgentActivityStep(id: String($0), summary: "Move draft note \($0) into the project folder", tier: .green, reversible: true, timestamp: .now, verification: "The note is in the project folder.")
        }
        let card = IntentCard(title: "Delete the original export?", detail: "This permanently removes the original export. The edited copy in the project folder will remain. Review the target before continuing.", tier: .red, targetSummary: "Original export.pdf", reversible: false)
        let recording = RoutineReviewState()
        recording.eventCount = 3
        let review = RoutineReviewState()
        review.presentReview(steps: [
            RoutineStep(summary: "Open a new note", action: .click),
            RoutineStep(summary: "Write the project heading", action: .typeText(.literal("Project notes")))
        ])
        review.name = "Prepare project notes"
        let longReview = RoutineReviewState()
        longReview.presentReview(steps: (1...20).map { RoutineStep(summary: "Step \($0): open the project note and review the heading before continuing.", action: .click) })
        longReview.name = "Review project notes"
        let parameters = RoutineReviewState()
        parameters.beginFillParameters(routineName: "Prepare project notes", parameters: [("heading", "Project heading")])
        let surfaces: [(String, AnyView)] = [
            ("whats-new", AnyView(WhatsNewView(onDone: {}))),
            ("routine-recording", AnyView(RoutineReviewView(state: recording, onStopRecording: {}, onDiscard: {}, onSave: {}, onSaveAndTry: {}, onRun: {}))),
            ("routine-review", AnyView(RoutineReviewView(state: review, onStopRecording: {}, onDiscard: {}, onSave: {}, onSaveAndTry: {}, onRun: {}))),
            ("routine-long-review", AnyView(RoutineReviewView(state: longReview, onStopRecording: {}, onDiscard: {}, onSave: {}, onSaveAndTry: {}, onRun: {}))),
            ("routine-parameters", AnyView(RoutineReviewView(state: parameters, onStopRecording: {}, onDiscard: {}, onSave: {}, onSaveAndTry: {}, onRun: {}))),
            ("approval", AnyView(IntentCardView(card: card, onAnswer: { _ in }))),
            ("approval-step-through", AnyView(IntentCardView(card: card, allowsStepThrough: true, onAnswer: { _ in }))),
            ("guide", AnyView(GuideControlsView(state: guide, onDone: {}, onBack: {}, onSkip: {}, onRepoint: {}, onSelectMarker: { _ in }, onChooseInput: { _ in }, onTakeOver: {}, onStop: {}))),
            ("activity", AnyView(AgentActivityStripView(state: activity, onPause: {}, onResume: {}, onStop: {}, onRetry: {}, onSteer: { _ in }, onTakeOver: {}, onToggleExpanded: {}))),
            ("activity-long", AnyView(AgentActivityStripView(state: longActivity, onPause: {}, onResume: {}, onStop: {}, onRetry: {}, onSteer: { _ in }, onTakeOver: {}, onToggleExpanded: {})))
        ]
        for (name, content) in surfaces {
            for (appearanceName, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", .darkAqua, .dark)] {
                let frame = NSRect(x: 0, y: 0, width: 560, height: 440)
                let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                let host = NSHostingView(rootView: content.padding(24)
                    .frame(width: 560, height: 440, alignment: .topLeading)
                    .background(PerryTheme.Colors.canvas)
                    .environment(\.colorScheme, scheme))
                window.contentView = host
                host.frame = frame
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: destination.appendingPathComponent("\(name)-\(appearanceName).png"))
                window.close()
            }
        }
    }

    func testNotchCanActivateForKeyboardInput() {
        let panel = CompactConversationPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        panel.close()
    }

    func testHomeOpensEachMigratedPageThroughNotch() {
        let controller = HomeController()
        var presented: [HomeModel.Selection?] = []
        controller.onOpenConversation = { presented.append(controller.homeModel.sidebarSelection) }
        let selections: [HomeModel.Selection] = [.history, .tasks, .settings, .whatsNew]
        for selection in selections { controller.openHome(selection: selection) }
        XCTAssertEqual(presented, selections.map(Optional.some))
    }

    func testRoutineReviewRemainsInNotchUntilClosed() {
        let presentation = NotchPresentation()
        let state = RoutineReviewState()
        state.presentReview(steps: [RoutineStep(summary: "Open a note", action: .click)])
        let review = RoutineReviewWindow(state: state, onStopRecording: {}, onDiscard: {}, onSave: {}, onSaveAndTry: {}, onRun: {}, presentation: presentation)
        review.show()
        XCTAssertEqual(presentation.current?.priority, .routine)
        review.close()
        XCTAssertNil(presentation.current)
    }

    func testCompleteErasureCancellationDoesNotConfirm() async {
        let presentation = NotchPresentation.shared
        let originalOnPresent = presentation.onPresent
        presentation.onPresent = nil
        let confirmation = CompleteErasurePrompt.makeConfirmation()
        defer { presentation.onPresent = originalOnPresent }
        let waiting = Task { await confirmation.confirm() }
        for _ in 0..<100 where !presentation.contains(confirmation.requestID) { await Task.yield() }
        XCTAssertTrue(presentation.contains(confirmation.requestID))
        confirmation.cancel()
        let confirmed = await waiting.value
        XCTAssertFalse(confirmed)
        XCTAssertFalse(presentation.contains(confirmation.requestID))
    }

    func testActivityRemainsAvailableWhileAnApprovalIsPresented() {
        let presentation = NotchPresentation()
        let state = AgentActivityStripState()
        let activity = AgentActivityStripWindow(state: state, onPause: {}, onResume: {}, onStop: {}, onRetry: {}, onSteer: { _ in }, presentation: presentation)
        activity.show()
        let activityID = presentation.current?.id
        let approvalID = UUID()
        presentation.present(id: approvalID, priority: .approval, content: Text("Approve"))
        activity.show()
        XCTAssertEqual(presentation.current?.id, approvalID)
        presentation.remove(approvalID)
        XCTAssertEqual(presentation.current?.id, activityID)
        activity.orderOut(nil)
        XCTAssertNil(presentation.current)
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
        XCTAssertEqual(activity.title, "Needs your OK")
        XCTAssertEqual(activity.detail, "Send the renamed file")
        XCTAssertEqual(activity.progress, 0.5)
        XCTAssertEqual(activity.tier, .orange)
        XCTAssertEqual(activity.startedAt, startedAt)
        XCTAssertEqual(activity.steps.map(\.summary), ["Rename the file"])
        XCTAssertEqual(activity.steps.first?.tier, .yellow)
        XCTAssertEqual(activity.steps.first?.timestamp, stepStartedAt)
    }
}
