import XCTest
import PerryBrain
import PerryGuide
import PerryOverlay
@testable import Perry

@MainActor
final class TalkSessionAskTests: XCTestCase {
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
        func guideClearFullPath() {}
    }

    private final class StubTalkInput: TalkSpeechInput {
        func start() async throws {}
        func finalize() async -> (transcript: String, words: [SpokenWord]) { ("", []) }
        func cancel() {}
    }

    private final class StubTalkOutput: TalkSpeechOutput {
        var isSpeaking = false
        func speak(_ sentence: String) {}
        func shutUp() {}
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
        capture: (@MainActor () async throws -> GuideObservation)? = nil,
        services scriptedServices: TalkSession.Services
    ) -> TalkSession {
        var services = scriptedServices
        services.capture = capture ?? { self.observation() }
        return TalkSession(
            sessionController: sessionController,
            overlayState: overlayState,
            output: output,
            services: services
        )
    }

    /// A runner whose Nth turn streams the events `script(N)` returns.
    private func scriptedRunner(
        onRun: @escaping @MainActor () -> Void = {},
        _ script: @escaping @MainActor (Int) async -> [AgentLoopEvent]
    ) -> TalkSession.Services {
        var calls = 0
        return TalkSession.Services(
            makeInput: { StubTalkInput() },
            output: StubTalkOutput(),
            capture: { throw CancellationError() },
            acceptInput: { text, id, _ in
                .init(threadID: id ?? UUID(), request: .init(text: text), saved: Task {})
            },
            run: { input, _ in
                calls += 1
                onRun()
                let call = calls
                return (input.threadID, AsyncStream { continuation in
                    Task { @MainActor in
                        for event in await script(call) { continuation.yield(event) }
                        continuation.finish()
                    }
                }, nil)
            }
        )
    }

    /// A Services literal from a two-arg accept plus the new-signature run —
    /// TalkSession owns spatial/skill construction now, so `run` receives the
    /// SpatialContext it built.
    private func scriptedServices(
        accept: @escaping @MainActor (String, UUID?) -> HomeController.AcceptedInput,
        run: @escaping @MainActor (HomeController.AcceptedInput, AgentCoordinator.SpatialContext?) -> (threadID: UUID, events: AsyncStream<AgentLoopEvent>, completion: Task<Void, Never>?)
    ) -> TalkSession.Services {
        TalkSession.Services(
            makeInput: { StubTalkInput() },
            output: StubTalkOutput(),
            capture: { throw CancellationError() },
            acceptInput: { text, id, _ in accept(text, id) },
            run: run
        )
    }

    private func answering(_ text: String) -> [AgentLoopEvent] {
        [.textDelta(text), .finished(.completed)]
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

    func testTypedInputIsSavedBeforeCaptureAndSurvivesDismissal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ThreadStore(directory: root)
        let home = HomeController()
        home.threadStore = store
        let original = try await store.upsert(PerryThread(draft: "Leave this draft alone"))
        home.homeModel.sidebarSelection = .thread(original.id)
        let capture = AsyncBarrier()
        let entered = expectation(description: "Capture started after save")
        let session = SessionController()
        let output = OutputStub()
        var dispatched = false
        let controller = makeController(
            sessionController: session, overlayState: PerryCursorState(), output: output,
            capture: {
                let saved = await ThreadStore(directory: root).thread(id: original.id)
                XCTAssertEqual(saved?.waitingInputs?.map(\.text), ["Keep my typed request"])
                XCTAssertEqual(saved?.draft, original.draft)
                entered.fulfill()
                await capture.wait()
                return self.observation()
            }, services: scriptedServices(accept: { home.acceptInput($0, threadID: $1) }, run: { input, _ in
                dispatched = true
                return (input.threadID, AsyncStream { $0.finish() }, nil)
            })
        )
        controller.submitComposer(question: "Keep my typed request")
        await fulfillment(of: [entered], timeout: 2)
        controller.cancel()
        _ = session.requestDismissal()
        await capture.release()
        await home.joinInputSaves()
        let saved = await ThreadStore(directory: root).thread(id: original.id)
        XCTAssertEqual(saved?.waitingInputs?.map(\.text), ["Keep my typed request"])
        XCTAssertNil(saved?.pendingTurn)
        XCTAssertFalse(dispatched)
    }

    func testCancelledInputSaveFailureCannotClearReplacementQuestion() async throws {
        let session = SessionController()
        let output = OutputStub()
        let firstSave = AsyncBarrier()
        let capture = AsyncBarrier()
        let captured = expectation(description: "Replacement capture is active")
        var accepted = 0
        let controller = makeController(
            sessionController: session, overlayState: PerryCursorState(), output: output,
            capture: {
                captured.fulfill()
                await capture.wait()
                return self.observation()
            }, services: scriptedServices(accept: { text, id in
                accepted += 1
                let isFirst = accepted == 1
                return .init(threadID: id ?? UUID(), request: .init(text: text), saved: Task {
                    if isFirst {
                        await firstSave.wait()
                        throw CocoaError(.fileWriteUnknown)
                    }
                })
            }, run: { input, _ in
                (input.threadID, AsyncStream { $0.finish() }, nil)
            })
        )
        controller.submitComposer(question: "First")
        controller.submitComposer(question: "Replacement")
        await fulfillment(of: [captured], timeout: 2)
        await firstSave.release()
        try await Task.sleep(for: .milliseconds(30))
        guard case .asking(let ask) = session.state else { return XCTFail("Missing replacement") }
        XCTAssertEqual(ask.question, "Replacement")
        XCTAssertTrue(ask.isWorking)
        XCTAssertFalse(output.buddyStates.contains(.blocked))
        controller.cancel()
        await capture.release()
    }

    func testSharedAskPersistsFollowUpsAndRejectsIncompleteAnswers() async throws {
        for reason: ModelStopReason? in [.endTurn, .maxTokens, nil] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            let store = ThreadStore(directory: directory)
            let provider = AskSharedProvider(reason: reason)
            let coordinator = AgentCoordinator(
                provider: { _ in provider }, host: PerryToolHost(executors: []),
                threads: store, consent: ToolConsentStore(directory: nil)
            )
            let home = HomeController()
            home.threadStore = store
            let session = SessionController()
            let output = OutputStub()
            let controller = makeController(
                sessionController: session, overlayState: PerryCursorState(), output: output,
                capture: { self.observation() },
                services: scriptedServices(accept: { home.acceptInput($0, threadID: $1) }, run: { input, spatial in
                    home.runSpokenTurn(input, spatial: spatial, coordinator: coordinator)
                })
            )
            controller.submitComposer(question: "Remember Orchid")
            await waitForCondition {
                guard case .asking(let ask) = session.state else { return false }
                return !ask.isWorking
            }
            if reason == .endTurn {
                guard case .asking(let first) = session.state else { return XCTFail("Missing Ask session") }
                let originalID = try XCTUnwrap(first.threadID)
                home.homeModel.sidebarSelection = .thread(UUID())
                controller.submitComposer(question: "Which document?")
                await waitForCondition {
                    guard case .asking(let ask) = session.state else { return false }
                    return ask.turnCount == 2 && !ask.isWorking
                }
                XCTAssertEqual(home.homeModel.sidebarSelection, .thread(originalID))
                XCTAssertEqual(provider.requests.count, 2)
                XCTAssertTrue(provider.requests.last?.messages.contains(.user([.text("Remember Orchid")])) == true)
                XCTAssertEqual(output.spoken, ["Orchid", "Orchid"])
            } else {
                XCTAssertTrue(output.spoken.isEmpty)
                XCTAssertEqual(output.buddyStates.last, .blocked)
            }
            let saved = await ThreadStore(directory: directory).list()
            XCTAssertEqual(saved.count, 1)
            XCTAssertEqual(saved.first?.turns.count, reason == .endTurn ? 2 : 1)
            XCTAssertEqual(saved.first?.turns.last?.outcome, reason == .endTurn ? .completed : .failed)
            XCTAssertNil(saved.first?.pendingTurn)
            XCTAssertTrue(coordinator.runningThreads.isEmpty)
            controller.cancel()
        }
    }

    func testSharedAskCancellationPreservesPartialAnswerAndStopsProvider() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = ThreadStore(directory: directory)
        let provider = AskSharedProvider(reason: .endTurn, suspend: true)
        let coordinator = AgentCoordinator(
            provider: { _ in provider }, host: PerryToolHost(executors: []),
            threads: store, consent: ToolConsentStore(directory: nil)
        )
        let home = HomeController()
        home.threadStore = store
        let session = SessionController()
        let output = OutputStub()
        let controller = makeController(
            sessionController: session, overlayState: PerryCursorState(), output: output,
            capture: { self.observation() },
            services: scriptedServices(accept: { home.acceptInput($0, threadID: $1) }, run: { input, spatial in
                home.runSpokenTurn(input, spatial: spatial, coordinator: coordinator)
            })
        )
        controller.submitComposer(question: "Keep my question")
        await waitForCondition {
            guard case .asking(let ask) = session.state else { return false }
            return ask.answerText == "Orchid"
        }
        controller.cancel()
        await waitForCondition { coordinator.runningThreads.isEmpty && home.homeModel.pendingQuestions.isEmpty }
        let saved = await ThreadStore(directory: directory).list()
        XCTAssertEqual(saved.first?.turns.first?.answer, "Orchid")
        XCTAssertEqual(saved.first?.turns.first?.outcome, .interrupted)
        XCTAssertEqual(saved.first?.draft, "Keep my question")
        XCTAssertNil(saved.first?.pendingTurn)
        XCTAssertTrue(output.spoken.isEmpty)
    }

    func testQueuedTransitionWaitsAndCannotSurviveCancellation() async {
        for cancel in [false, true] {
            let session = SessionController()
            let output = OutputStub()
            let barrier = AsyncBarrier()
            let controller = makeController(
                sessionController: session, overlayState: PerryCursorState(), output: output,
                capture: { self.observation() },
                services: scriptedRunner { _ in
                    await barrier.wait()
                    return self.answering("Ready")
                }
            )
            controller.submitComposer(question: "Explain this")
            var transitioned = false
            controller.afterCurrentAnswer { _ in XCTFail("Superseded transition ran") }
            controller.afterCurrentAnswer { state in
                XCTAssertFalse(state.isWorking)
                XCTAssertEqual(state.answerText, "Ready")
                transitioned = true
            }
            await Task.yield()
            XCTAssertFalse(transitioned)
            if cancel { controller.cancel() }
            await barrier.release()
            if cancel {
                try? await Task.sleep(for: .milliseconds(30))
                XCTAssertFalse(transitioned)
            } else {
                await waitForCondition { transitioned }
            }
            controller.cancel()
        }
    }

    func testCancelledTransitionStillJoinsItsInputSaveWithoutStartingGuide() async {
        let session = SessionController()
        let barrier = AsyncBarrier()
        let controller = makeController(
            sessionController: session, overlayState: PerryCursorState(), output: OutputStub(),
            capture: { self.observation() },
            services: scriptedRunner { _ in self.answering("Ready") }
        )
        controller.submitComposer(question: "Explain this")
        var saved = false
        var transitioned = false
        controller.afterCurrentAnswer(prepare: {
            await barrier.wait()
            saved = true
            return true
        }) { _ in transitioned = true }
        controller.cancel()
        var joined = false
        let join = Task { @MainActor in
            await controller.joinInputSaves()
            joined = true
        }
        await Task.yield()
        XCTAssertFalse(joined)
        await barrier.release()
        await join.value
        XCTAssertTrue(saved)
        XCTAssertFalse(transitioned)
    }

    func testFollowUpWaitsForPreviousPresentationLifetime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ThreadStore(directory: root)
        let home = HomeController()
        home.threadStore = store
        let coordinator = AgentCoordinator(provider: { _ in AskSharedProvider(reason: .endTurn) },
            host: PerryToolHost(executors: []), threads: store, consent: ToolConsentStore(directory: nil))
        let session = SessionController()
        let output = OutputStub()
        let release = AsyncStream<Void>.makeStream()
        var retired = false
        var completion: Task<Void, Never>?
        var requests = 0
        let controller = makeController(
            sessionController: session, overlayState: PerryCursorState(), output: output,
            capture: { self.observation() },
            services: scriptedServices(accept: { home.acceptInput($0, threadID: $1) }, run: { input, spatial in
                requests += 1
                let run = home.runSpokenTurn(input, spatial: spatial, coordinator: coordinator)
                if requests > 1 {
                    XCTAssertTrue(retired, "A follow-up outran presentation cleanup")
                    return run
                }
                completion = Task { @MainActor in
                    await run.completion?.value
                    for await _ in release.stream { break }
                    retired = true
                }
                return (run.threadID, run.events, completion)
            })
        )
        controller.submitComposer(question: "First")
        await waitForCondition {
            guard case .asking(let ask) = session.state else { return false }
            return ask.turnCount == 1
        }
        guard case .asking(let first) = session.state else { return XCTFail("Missing Ask session") }
        let threadID = try XCTUnwrap(first.threadID)
        var transitioned = false
        controller.afterCurrentAnswer { _ in transitioned = true }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(transitioned)
        controller.submitComposer(question: "Follow up")
        await home.joinInputSaves()
        XCTAssertEqual(requests, 1)
        let waiting = await ThreadStore(directory: root).thread(id: threadID)
        XCTAssertEqual(waiting?.waitingInputs?.map(\.text), ["Follow up"])
        XCTAssertEqual(waiting?.turns.count, 1)
        release.continuation.finish()
        await waitForCondition {
            guard case .asking(let ask) = session.state else { return false }
            return ask.turnCount == 2
        }
        XCTAssertEqual(requests, 2)
        XCTAssertFalse(transitioned)
        let finished = await store.thread(id: threadID)
        XCTAssertTrue(finished?.waitingInputs?.isEmpty == true)
        controller.cancel()
        await completion?.value
    }

    func testStreamedAnswerUpdatesSessionAndSpeaks() async {
        let session = SessionController()
        let output = OutputStub()
        let controller = makeController(
            sessionController: session, overlayState: PerryCursorState(), output: output,
            capture: { self.observation() },
            services: scriptedRunner { _ in self.answering("Save writes the document.") }
        )

        controller.submitComposer(question: "What does Save do?")

        await waitForCondition {
            if case .asking(let ask) = session.state { return !ask.isWorking }
            return false
        }
        guard case .asking(let ask) = session.state else { return XCTFail("expected asking") }
        XCTAssertEqual(ask.answerText, "Save writes the document.")
        XCTAssertEqual(ask.turnCount, 1)
        XCTAssertEqual(output.spoken, ["Save writes the document."])
        XCTAssertEqual(output.overlayShows, 1)
    }

    func testProtectedWindowNeverReachesRunner() async {
        let session = SessionController()
        let output = OutputStub()
        var ran = false
        let protected = GuideObservation(
            snapshot: AXSnapshot(appBundleID: "com.agilebits.onepassword-osx", windowTitle: "Vault", elements: []),
            processID: 9, windowID: 9, connectionGeneration: 1,
            windowBounds: AXElementFrame(x: 0, y: 0, width: 100, height: 100),
            observationID: "p1"
        )
        let controller = makeController(
            sessionController: session, overlayState: PerryCursorState(), output: output,
            capture: { protected },
            services: scriptedRunner(onRun: { ran = true }) { _ in self.answering("x") }
        )

        controller.submitComposer(question: "What is this?")
        await waitForCondition {
            if case .asking(let ask) = session.state { return !ask.isWorking }
            return false
        }
        XCTAssertFalse(ran)
        XCTAssertEqual(output.buddyStates.last, .blocked)
    }

    func testBusySessionIsNotPreempted() {
        let session = SessionController()
        let output = OutputStub()
        var captures = 0
        let controller = makeController(
            sessionController: session,
            overlayState: PerryCursorState(),
            output: output,
            capture: {
                captures += 1
                return self.observation()
            },
            services: scriptedRunner { _ in self.answering("x") }
        )
        session.debugSet(.executing(ExecutionSessionState(
            taskID: UUID(), goal: "task", startedAt: Date(),
            appBundleID: nil, workspace: URL(fileURLWithPath: "/tmp"), lifecycle: .running
        )))

        controller.submitComposer(question: "What is this?")

        XCTAssertEqual(captures, 0)
        XCTAssertTrue(output.statuses.contains("Finish or dismiss what I’m doing before you ask."))
    }

    func testCancelStopsPendingAnswer() async {
        let session = SessionController()
        let output = OutputStub()
        let barrier = AsyncBarrier()
        let controller = makeController(
            sessionController: session, overlayState: PerryCursorState(), output: output,
            capture: { self.observation() },
            services: scriptedRunner { _ in
                await barrier.wait()
                return self.answering("too late")
            }
        )

        controller.submitComposer(question: "What is this?")
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

    func testFailedAnswerLeavesSessionReadyForRetry() async {
        let session = SessionController()
        let output = OutputStub()
        let controller = makeController(
            sessionController: session, overlayState: PerryCursorState(), output: output,
            capture: { self.observation() },
            services: scriptedRunner { call in
                call == 1 ? [.finished(.failed("The model is unavailable."))] : self.answering("Second try worked.")
            }
        )

        controller.submitComposer(question: "What is this?")
        await waitForCondition {
            if case .asking(let ask) = session.state { return !ask.isWorking && output.buddyStates.last == .blocked }
            return false
        }
        guard case .asking(let ask) = session.state else { return XCTFail("expected asking") }
        XCTAssertNil(ask.answerText)
        XCTAssertEqual(ask.turnCount, 0)
        XCTAssertTrue(output.spoken.isEmpty)

        controller.submitComposer(question: "What is this?")
        await waitForCondition {
            if case .asking(let ask) = session.state { return ask.turnCount == 1 }
            return false
        }
        guard case .asking(let retried) = session.state else { return XCTFail("expected asking") }
        XCTAssertEqual(retried.answerText, "Second try worked.")
        XCTAssertEqual(output.spoken, ["Second try worked."])
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

private final class AskSharedProvider: ModelProvider, @unchecked Sendable {
    let id: ProviderID = "fixture.ask"
    let displayName = "Ask fixture"
    let capabilities: ModelCapabilities = [.vision, .streaming]
    let reason: ModelStopReason?
    let suspend: Bool
    private let lock = NSLock()
    private var recorded: [ModelRequest] = []
    var requests: [ModelRequest] { lock.withLock { recorded } }

    init(reason: ModelStopReason?, suspend: Bool = false) { self.reason = reason; self.suspend = suspend }
    func warm() async {}
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        lock.withLock { recorded.append(request) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.textDelta("Orchid"))
                do {
                    if suspend { try await Task.sleep(for: .seconds(60)) }
                    try Task.checkCancellation()
                    if let reason { continuation.yield(.done(reason)) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
