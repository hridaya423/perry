import XCTest
import PerryGuide
import PerryOverlay
@testable import Perry

@MainActor
final class AskSessionControllerTests: XCTestCase {
    private final class OutputStub: GuideSessionOutput {
        var statuses: [String] = []
        var spoken: [String] = []
        var buddyStates: [PerryBuddyState] = []
        var overlayShows = 0

        func guideShowOverlay() { overlayShows += 1 }
        func guideStopSpatialInput() {}
        func guideSetStatus(_ status: String) { statuses.append(status) }
        func guideSpeak(_ text: String, identity: GuideSpeechIdentity) { spoken.append(text) }
        func guidePlay(_ cue: SoundPlayer.Cue) {}
        func guidePresent(_ presentation: GuidePresentation) {}
        func guideSetBuddyState(_ state: PerryBuddyState) { buddyStates.append(state) }
        func guideInteractiveFrames() -> [CGRect] { [] }
        func guideShowFullPath(_ viewPlan: EverythingViewPlan) {}
        func guideClearPresentation() {}
        func guideClearHighlight() {}
        func guideClearFullPath() {}
    }

    private final class ContextStub: GuideSessionContext {
        func guideTargetHint() -> CuaTargetHint { CuaTargetHint() }
        func guideAppBundleID(for targetHint: CuaTargetHint) -> String? { "com.example.Editor" }
        func guideSpatialRegionDescription() -> String? { nil }
    }

    private func observation(
        id: String = "capture-1",
        windowID: Int64? = 7,
        title: String = "Document"
    ) -> GuideObservation {
        GuideObservation(
            snapshot: AXSnapshot(
                appBundleID: "com.example.Editor",
                windowTitle: title,
                elements: [
                    AXElement(
                        stableID: "save", role: .button, label: "Save",
                        frame: AXElementFrame(x: 10, y: 20, width: 60, height: 24),
                        isActionable: true, sensitivity: .ordinary
                    )
                ]
            ),
            processID: 42,
            windowID: windowID,
            connectionGeneration: 1,
            windowBounds: AXElementFrame(x: 0, y: 0, width: 800, height: 600),
            observationID: id
        )
    }

    private func makeController(
        sessionController: SessionController,
        overlayState: PerryCursorState,
        output: OutputStub,
        answerer: AskSessionController.Answerer? = nil,
        observationProvider: AskSessionController.ObservationProvider? = nil
    ) -> AskSessionController {
        AskSessionController(
            sessionController: sessionController,
            workers: CuaWorkerService(),
            overlayState: overlayState,
            output: output,
            context: ContextStub(),
            answererFactory: { answerer },
            observationProvider: observationProvider
        )
    }

    private func waitForCondition(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 where !predicate() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    func testAnswerPublishesReferencesAndSpeech() async {
        let session = SessionController()
        let overlay = PerryCursorState()
        let output = OutputStub()
        let answerer: AskSessionController.Answerer = { _, observation, _, _ in
            SpatialAnswer(
                text: "Save writes the document.",
                references: [
                    SpatialReference(
                        caption: "Save button",
                        observationID: observation.observationID,
                        target: .element(stableID: "save"),
                        frame: AXElementFrame(x: 10, y: 20, width: 60, height: 24)
                    )
                ],
                followUp: "Want the shortcut?",
                observationID: observation.observationID
            )
        }
        let controller = makeController(
            sessionController: session,
            overlayState: overlay,
            output: output,
            answerer: answerer,
            observationProvider: { self.observation() }
        )

        controller.submit(question: "What does Save do?")

        await waitForCondition {
            if case .asking(let ask) = session.state { return ask.answerText != nil }
            return false
        }
        guard case .asking(let ask) = session.state else { return XCTFail("expected asking") }
        XCTAssertEqual(ask.answerText, "Save writes the document.")
        XCTAssertEqual(ask.followUpPrompt, "Want the shortcut?")
        XCTAssertEqual(ask.turnCount, 1)
        XCTAssertFalse(ask.isWorking)
        XCTAssertEqual(overlay.visualGuidanceOverlays.count, 1)
        XCTAssertEqual(output.spoken, ["Save writes the document."])
        XCTAssertEqual(output.overlayShows, 1)
    }

    func testFollowUpReusesSessionAndConversation() async {
        let session = SessionController()
        let output = OutputStub()
        var seenTurnCounts: [Int] = []
        let answerer: AskSessionController.Answerer = { _, observation, conversation, _ in
            seenTurnCounts.append(conversation.turns.count)
            return SpatialAnswer(
                text: "answer \(conversation.turns.count)",
                references: [],
                followUp: nil,
                observationID: observation.observationID
            )
        }
        let controller = makeController(
            sessionController: session,
            overlayState: PerryCursorState(),
            output: output,
            answerer: answerer,
            observationProvider: { self.observation() }
        )

        controller.submit(question: "first")
        await waitForCondition {
            if case .asking(let ask) = session.state { return ask.turnCount == 1 }
            return false
        }
        controller.submit(question: "second")
        await waitForCondition {
            if case .asking(let ask) = session.state { return ask.turnCount == 2 }
            return false
        }

        XCTAssertEqual(seenTurnCounts, [0, 1])
        guard case .asking(let ask) = session.state else { return XCTFail("expected asking") }
        XCTAssertEqual(ask.question, "second")
        XCTAssertEqual(ask.answerText, "answer 1")
    }

    func testChangedWindowInvalidatesLateAnswer() async {
        let session = SessionController()
        let output = OutputStub()
        var captures = 0
        let answerer: AskSessionController.Answerer = { _, observation, _, _ in
            SpatialAnswer(
                text: "Late answer",
                references: [],
                followUp: nil,
                observationID: observation.observationID
            )
        }
        let controller = makeController(
            sessionController: session,
            overlayState: PerryCursorState(),
            output: output,
            answerer: answerer,
            observationProvider: {
                captures += 1
                // Second capture sees a different window: the baseline answer is stale.
                return self.observation(id: "capture-\(captures)", windowID: captures == 1 ? 7 : 99)
            }
        )

        controller.submit(question: "What is this?")
        await waitForCondition {
            if case .asking(let ask) = session.state { return !ask.isWorking }
            return false
        }

        guard case .asking(let ask) = session.state else { return XCTFail("expected asking") }
        XCTAssertNil(ask.answerText)
        XCTAssertEqual(ask.turnCount, 0)
        XCTAssertTrue(output.statuses.contains(SpatialAnswerError.staleObservation.errorDescription ?? ""))
        XCTAssertTrue(output.spoken.isEmpty)
    }

    func testProtectedWindowNeverReachesAnswerer() async {
        let session = SessionController()
        let output = OutputStub()
        var answererCalled = false
        let answerer: AskSessionController.Answerer = { _, _, _, _ in
            answererCalled = true
            return SpatialAnswer(text: "x", references: [], followUp: nil, observationID: "x")
        }
        let protected = GuideObservation(
            snapshot: AXSnapshot(appBundleID: "com.agilebits.onepassword-osx", windowTitle: "Vault", elements: []),
            processID: 9, windowID: 9, connectionGeneration: 1,
            windowBounds: AXElementFrame(x: 0, y: 0, width: 100, height: 100),
            observationID: "p1"
        )
        let protectedController = makeController(
            sessionController: session,
            overlayState: PerryCursorState(),
            output: output,
            answerer: answerer,
            observationProvider: { protected }
        )

        protectedController.submit(question: "What is this?")
        await waitForCondition {
            if case .asking(let ask) = session.state { return !ask.isWorking }
            return false
        }
        XCTAssertFalse(answererCalled)
    }

    func testBusySessionIsNotPreempted() {
        let session = SessionController()
        let output = OutputStub()
        var captures = 0
        let controller = makeController(
            sessionController: session,
            overlayState: PerryCursorState(),
            output: output,
            observationProvider: {
                captures += 1
                return self.observation()
            }
        )
        session.debugSet(.executing(ExecutionSessionState(
            taskID: UUID(), goal: "task", startedAt: Date(),
            appBundleID: nil, workspace: URL(fileURLWithPath: "/tmp"), lifecycle: .running
        )))

        controller.submit(question: "What is this?")

        XCTAssertEqual(captures, 0)
        XCTAssertTrue(output.statuses.contains("Finish or dismiss the current session before asking."))
    }

    func testCancelStopsPendingAnswer() async {
        let session = SessionController()
        let overlay = PerryCursorState()
        let output = OutputStub()
        let barrier = AsyncBarrier()
        let answerer: AskSessionController.Answerer = { _, observation, _, _ in
            await barrier.wait()
            return SpatialAnswer(
                text: "too late", references: [], followUp: nil,
                observationID: observation.observationID
            )
        }
        let controller = makeController(
            sessionController: session,
            overlayState: overlay,
            output: output,
            answerer: answerer,
            observationProvider: { self.observation() }
        )

        controller.submit(question: "What is this?")
        await waitForCondition {
            if case .asking(let ask) = session.state { return ask.isWorking }
            return false
        }
        controller.cancel()
        await barrier.release()

        try? await Task.sleep(nanoseconds: 50_000_000)
        guard case .asking(let ask) = session.state else { return XCTFail("expected asking") }
        XCTAssertNil(ask.answerText)
        XCTAssertTrue(output.spoken.isEmpty)
    }

    func testProviderFailureLeavesSessionReadyForRetry() async {
        let session = SessionController()
        let overlay = PerryCursorState()
        let output = OutputStub()
        var calls = 0
        let answerer: AskSessionController.Answerer = { _, observation, _, _ in
            calls += 1
            if calls == 1 { throw SpatialAnswerError.invalidResponse }
            return SpatialAnswer(
                text: "Second try worked.", references: [], followUp: nil,
                observationID: observation.observationID
            )
        }
        let controller = makeController(
            sessionController: session,
            overlayState: overlay,
            output: output,
            answerer: answerer,
            observationProvider: { self.observation() }
        )

        controller.submit(question: "What is this?")
        await waitForCondition {
            if case .asking(let ask) = session.state { return !ask.isWorking && output.statuses.count > 1 }
            return false
        }
        guard case .asking(let ask) = session.state else { return XCTFail("expected asking") }
        XCTAssertNil(ask.answerText)
        XCTAssertEqual(ask.turnCount, 0)
        XCTAssertTrue(overlay.visualGuidanceOverlays.isEmpty)
        XCTAssertTrue(output.spoken.isEmpty)

        controller.submit(question: "What is this?")
        await waitForCondition {
            if case .asking(let ask) = session.state { return ask.answerText != nil }
            return false
        }
        guard case .asking(let retried) = session.state else { return XCTFail("expected asking") }
        XCTAssertEqual(retried.answerText, "Second try worked.")
        XCTAssertEqual(retried.turnCount, 1)
        XCTAssertEqual(calls, 2)
    }

    func testSessionControllerAskTransitions() throws {
        let controller = SessionController()
        let ask = AskSessionState(id: UUID(), startedAt: Date(), question: "q")
        XCTAssertThrowsError(try controller.startAsk(ask))

        try controller.wake()
        try controller.startAsk(ask)
        guard case .asking(let live) = controller.state else { return XCTFail("expected asking") }
        XCTAssertEqual(live.question, "q")

        controller.updateAsk { $0.answerText = "a"; $0.turnCount += 1 }
        guard case .asking(let updated) = controller.state else { return XCTFail("expected asking") }
        XCTAssertEqual(updated.answerText, "a")
        XCTAssertEqual(updated.turnCount, 1)

        try controller.fail(SessionFailure(taskID: ask.id, message: "boom"))
        guard case .failed(let failure) = controller.state else { return XCTFail("expected failed") }
        XCTAssertEqual(failure.taskID, ask.id)
    }

    func testDismissClearsAskingSession() throws {
        let controller = SessionController()
        try controller.wake()
        try controller.startAsk(AskSessionState(id: UUID(), startedAt: Date(), question: "q"))
        XCTAssertEqual(controller.requestDismissal(), .dismiss)
        XCTAssertEqual(controller.state, .idle)
    }
}

/// Minimal awaitable gate for cancellation tests.
private actor AsyncBarrier {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
