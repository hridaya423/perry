import AppKit
import Foundation
import XCTest
import PerryBrain
import PerryCore
import PerryGuide
import PerryRuntimes
@testable import Perry

@MainActor
final class BackgroundApprovalOutcomeTests: XCTestCase {
    private let denial = ToolHostError.approvalDenied(name: "files.write").localizedDescription

    func testDeniedApprovalStopsTheTaskAndNamesTheTool() {
        var tally = AgentRunTally()
        feed(&tally, id: "note", name: "fixture.note", result: "done")
        feed(&tally, id: "write", name: "files.write", result: denial, isError: true)

        XCTAssertEqual(
            tally.outcome(for: .completed),
            .blocked(reason: "Needs your OK to create a file. Run it again in front of you to approve it.")
        )
        XCTAssertEqual(tally.actions, ["fixture.note"])
    }

    func testFinishedTaskReportsTheRealStepCount() {
        var tally = AgentRunTally()
        feed(&tally, id: "one", name: "fixture.note", result: "done")
        feed(&tally, id: "look", name: "fixture.read", result: "contents")
        feed(&tally, id: "two", name: "fixture.note", result: "done")

        XCTAssertEqual(tally.outcome(for: .completed), .completed(stepsRun: 0))
        XCTAssertEqual(tally.actions, ["fixture.note", "fixture.note"])
    }

    func testLastFailedActionIsNotReportedAsFinished() {
        var tally = AgentRunTally()
        feed(&tally, id: "note", name: "fixture.note", result: "done")
        feed(&tally, id: "broken", name: "fixture.broken", result: "the fixture action failed", isError: true)

        XCTAssertEqual(
            tally.outcome(for: .completed),
            .failed(stepSummary: "fixture.broken", reason: "the fixture action failed")
        )
        XCTAssertEqual(tally.actions, ["fixture.note"])
    }

    func testAFailureThatLaterSucceedsOrWasReadOnlyDoesNotFailTheTask() {
        var tally = AgentRunTally()
        feed(&tally, id: "broken", name: "fixture.broken", result: "the fixture action failed", isError: true)
        feed(&tally, id: "retry", name: "fixture.note", result: "done")
        feed(&tally, id: "look", name: "fixture.read", result: "no such thing", isError: true)

        XCTAssertEqual(tally.outcome(for: .completed), .completed(stepsRun: 0))
    }

    func testAnUnfinishedRunKeepsItsOwnOutcome() {
        var tally = AgentRunTally()
        feed(&tally, id: "write", name: "files.write", result: denial, isError: true)

        XCTAssertEqual(tally.outcome(for: .interrupted), .blocked(reason: "stopped by the user"))
    }

    func testApprovalReasonFallsBackToTheToolName() {
        let call = ToolCall(id: "1", name: "fixture.unknown", arguments: .object([:]))
        XCTAssertEqual(
            BackgroundTaskController.approvalReason(for: call),
            "Needs your OK to fixture.unknown. Run it again in front of you to approve it."
        )
    }

    private func feed(_ tally: inout AgentRunTally, id: String, name: String, result: String, isError: Bool = false) {
        let readOnly: (String) -> Bool = { $0 == "fixture.read" }
        tally.record(.toolCallStarted(ToolCall(id: id, name: name, arguments: .object([:]))), isReadOnly: readOnly)
        tally.record(.toolCallFinished(.text(id, result, isError: isError)), isReadOnly: readOnly)
    }
}

private final class QuietNotifier: AppNotificationClient, @unchecked Sendable {
    func configure(
        onApprove: @escaping @MainActor @Sendable (TaskID, String, UUID) -> Void,
        onDeny: @escaping @MainActor @Sendable (TaskID, UUID) -> Void,
        onOpen: @escaping @MainActor @Sendable () -> Void
    ) {}

    func requestAuthorization() async -> Bool { true }

    func deliver(_ notification: TaskNotification) async {}
}

@MainActor
final class HistorySaveRetryTests: XCTestCase {
    func testSuccessfulRunWhoseHistorySaveFailsOffersNoRetry() async throws {
        let directory = try makeTemporaryDirectory()
        let transcripts = directory.appendingPathComponent("Transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        try Data("{ corrupt".utf8).write(to: transcripts.appendingPathComponent("index.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: transcripts.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transcripts.path) }
        let controller = makeController(directory: directory, provider: AnswerProvider(failure: nil))

        let outcome = try await controller.subsystems.foreground.debugRun(goal: "Read the fixture")

        XCTAssertEqual(outcome, .completed(stepsRun: 0))
        guard case .failed(let failure) = controller.sessionState else {
            return XCTFail("expected the History failure to show, got \(controller.sessionState)")
        }
        XCTAssertNil(failure.goal)
        XCTAssertEqual(failure.message, "Done, but I couldn’t save it to History.")
        let strip = AgentActivityStripState()
        strip.apply(sessionState: controller.sessionState)
        XCTAssertEqual(strip.phase, .failed)
        XCTAssertEqual(strip.detail, "Done, but I couldn’t save it to History.")
        XCTAssertFalse(strip.retryIsAvailable)
    }

    func testMutedRunWhoseHistorySaveFailsDoesNotCopyTheFailureToTheClipboard() async throws {
        restoreDefaultsAfterTest([PerryPreferences.$speechOutputEnabled.key])
        UserDefaults.standard.set(true, forKey: PerryPreferences.$speechOutputEnabled.key)
        let directory = try makeTemporaryDirectory()
        let transcripts = directory.appendingPathComponent("Transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        try Data("{ corrupt".utf8).write(to: transcripts.appendingPathComponent("index.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: transcripts.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transcripts.path) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("perry.history-failure.\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)
        let controller = makeController(directory: directory, provider: AnswerProvider(failure: nil))
        controller.subsystems.voice.pasteboard = pasteboard
        controller.subsystems.voice.outputRoute = { (available: true, muted: true) }

        _ = try await controller.subsystems.foreground.debugRun(goal: "Read the fixture")

        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }

    func testRunThatFailedStillOffersRetry() async throws {
        let directory = try makeTemporaryDirectory()
        let controller = makeController(directory: directory, provider: AnswerProvider(failure: "the model fell over"))

        let outcome = try await controller.subsystems.foreground.debugRun(goal: "Read the fixture")

        guard case .failed = outcome else { return XCTFail("expected a failed run, got \(String(describing: outcome))") }
        guard case .failed(let failure) = controller.sessionState else {
            return XCTFail("expected a failed session, got \(controller.sessionState)")
        }
        XCTAssertEqual(failure.goal, "Read the fixture")
        let strip = AgentActivityStripState()
        strip.apply(sessionState: controller.sessionState)
        XCTAssertTrue(strip.retryIsAvailable)
        XCTAssertEqual(strip.title, "Failed")
    }

    private func makeController(directory: URL, provider: AnswerProvider) -> AppController {
        let inspector = RuntimeInventoryInspector(readDirectProvider: { nil }, commandLineProviders: [])
        let controller = AppController.testing(directory: directory, session: SessionController()) {
            $0.runtimeSetupLoader = { try await inspector.inspect() }
            $0.permissionSnapshotLoader = {
                PerryPermissionSnapshot(accessibility: true, screenRecording: .granted, microphone: .granted)
            }
            $0.screenHealthLoader = { ScreenDriverHealth(ready: true, summary: "Fixture screen control is ready.") }
            $0.screenContextLoader = { _, _ in
                (ScreenContext(frontAppBundleID: "fixture.app", frontWindowTitle: "Fixture window", screenshotReferenceID: "screen:fixture", screenshotCoordinateSpace: .windowPixels), nil)
            }
            $0.notifier = QuietNotifier()
        }
        controller.subsystems.foreground.agentCoordinator = AgentCoordinator(
            provider: { _ in provider },
            host: PerryToolHost(executors: []),
            threads: ThreadStore(directory: directory.appendingPathComponent("agent-threads")),
            consent: ToolConsentStore(directory: nil)
        )
        return controller
    }
}

private struct AnswerProvider: ModelProvider {
    let failure: String?
    let id: ProviderID = "fixture.answer"
    let displayName = "Fixture"
    let capabilities: ModelCapabilities = [.streaming]

    func warm() async {}

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            if let failure {
                continuation.finish(throwing: ExecutionError(message: failure))
                return
            }
            continuation.yield(.textDelta("The fixture answer."))
            continuation.yield(.done(.endTurn))
            continuation.finish()
        }
    }
}

@MainActor
final class GuideRoughEdgeTests: XCTestCase {
    func testStillWaitingCopyMatchesWhetherDoneIsShown() {
        XCTAssertEqual(
            GuideSessionCoordinator.stillWaitingStatus(hasPostcondition: false),
            "I can’t see that step done yet. Finish it, then choose Done."
        )
        let hidden = GuideSessionCoordinator.stillWaitingStatus(hasPostcondition: true)
        XCTAssertEqual(hidden, "I can’t see that done yet. Finish it and I’ll check again, or choose Skip this step.")
        XCTAssertFalse(hidden.contains("choose Done"))
    }

    func testFullPathOverviewHasNoPendingTimeoutAfterItIsPainted() async throws {
        let directory = try makeTemporaryDirectory()
        let capture = ScreenCapturedWindow.debugFixture(snapshot: AXSnapshot(
            appBundleID: "fixture.app", windowTitle: "Fixture window",
            elements: [AXElement(stableID: "save", role: .button, label: "Save",
                frame: AXElementFrame(x: 20, y: 20, width: 80, height: 30), isActionable: true)]
        ))
        let controller = AppController.testing(directory: directory) {
            $0.runtimeSetupLoader = { RuntimeSetupSnapshot(summary: "Typed foreground fixture", records: []) }
            $0.permissionSnapshotLoader = {
                PerryPermissionSnapshot(accessibility: true, screenRecording: .granted, microphone: .granted)
            }
            $0.screenHealthLoader = { ScreenDriverHealth(ready: true, summary: "Fixture screen control is ready.") }
            $0.fullGuideCaptureLoader = { _, _ in capture }
            $0.guidePlanner = OverviewPlanner()
            $0.notifier = QuietNotifier()
            $0.screenContextLoader = { _, _ in
                (ScreenContext(frontAppBundleID: "fixture.app", frontWindowTitle: "Fixture window", screenshotReferenceID: "screen:fixture", screenshotCoordinateSpace: .windowPixels), capture.target)
            }
        }
        await controller.showEverything(goal: "Save the fixture")
        for _ in 0..<300 where controller.subsystems.guideCoordinator.debugGuideSpeechIdentity == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .guiding = controller.sessionState else { return XCTFail("the overview did not paint: \(controller.sessionState)") }
        let scope = try XCTUnwrap(controller.subsystems.guideCoordinator.currentGuideScope)

        let settled = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                await scope.drain()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        XCTAssertTrue(settled, "a timer is still scheduled against the painted overview")
        guard case .guiding = controller.sessionState else { return XCTFail("the guide ended: \(controller.sessionState)") }
        controller.dismiss()
        controller.subsystems.guideCoordinator.prepareForTermination()
        await controller.subsystems.guideCoordinator.joinAfterWorkerShutdown()
    }
}

private struct OverviewPlanner: GuidePlanner {
    func nextStep(goal: String, observation: GuideObservation, progress: GuideProgress, context: GuideContext) async throws -> GuideDecision {
        try await AXGuidePlanner().nextStep(goal: goal, observation: observation, progress: progress, context: context)
    }

    func visiblePath(goal: String, observation: GuideObservation, context: GuideContext) async throws -> [GuideStep] {
        [GuideStep(instruction: "Select Save", target: .axElement(stableID: "save"))]
    }
}

final class ScreenWorkerErrorCopyTests: XCTestCase {
    func testEveryCaseReadsAsAPlainSentenceWithoutACode() {
        let cases: [ScreenWorkerError] = [
            .admissionClosed, .capacityReached, .resourceBusy, .retired, .operationDidNotStop, .maintenanceInsideWorker,
        ]
        for error in cases {
            let message = error.localizedDescription
            XCTAssertFalse(message.contains("error "), message)
            XCTAssertFalse(message.contains("ScreenWorkerError"), message)
            XCTAssertTrue(message.hasSuffix("."), message)
        }
        XCTAssertEqual(ScreenWorkerError.resourceBusy.localizedDescription, "Another task is using that app. Wait for it to finish, or stop it.")
    }
}
