import AppKit
import XCTest
import PerryBrain
import PerryCore
import PerryGuide
import PerryOverlay
@testable import Perry

@MainActor
final class TalkCompletionTests: XCTestCase {
    private final class Input: TalkSpeechInput {
        let text: String
        init(_ text: String = "Explain this") { self.text = text }
        func start() async throws {}
        func finalize() async -> (transcript: String, words: [SpokenWord]) { (text, []) }
        func cancel() {}
    }

    private final class Output: TalkSpeechOutput, GuideSessionOutput, GuideSessionContext {
        private(set) var isSpeaking = false
        private var pending = 0
        /// Holds playback open so tests can act while speech is still "playing".
        var speechHeld = false { didSet { if !speechHeld && pending == 0 { isSpeaking = false } } }
        var stopped = 0
        func speak(_ sentence: String) {
            pending += 1
            isSpeaking = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(20))
                self.pending -= 1
                self.isSpeaking = self.pending > 0 || self.speechHeld
            }
        }
        func shutUp() { pending = 0; isSpeaking = false; stopped += 1 }
        func guideShowOverlay() {}
        func guideStopSpatialInput() {}
        func guideSetStatus(_ status: String) {}
        func guideSpeak(_ text: String, identity: GuideSpeechIdentity) {}
        func guidePlay(_ cue: SoundPlayer.Cue) {}
        func guidePresent(_ presentation: GuidePresentation) {}
        func guideSetBuddyState(_ state: PerryBuddyState) {}
        func guideInteractiveFrames() -> [CGRect] { [] }
        func guideShowFullPath(_ viewPlan: EverythingViewPlan) {}
        func guideClearPresentation() {}
        func guideClearFullPath() {}
        func guideTargetHint() -> CuaTargetHint { CuaTargetHint() }
        func guideAppBundleID(for targetHint: CuaTargetHint) -> String? { targetHint.bundleID }
        func guideSpatialRegionDescription() -> String? { nil }
    }

    private struct Provider: ModelProvider {
        let id: ProviderID = .codex
        let displayName = "Test"
        let capabilities: ModelCapabilities = [.vision, .streaming]
        let reason: ModelStopReason?
        func warm() async {}
        func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.textDelta("A partial answer. "))
                if let reason { continuation.yield(.done(reason)) }
                continuation.finish()
            }
        }
    }

    private func execution(provider: any ModelProvider) throws -> (HomeController, AgentCoordinator, ThreadStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ThreadStore(directory: root)
        let home = HomeController()
        home.threadStore = store
        let router = ProviderRouter(providers: [provider])
        let coordinator = AgentCoordinator(
            provider: { try await router.route($0).provider }, host: PerryToolHost(executors: []),
            threads: store, consent: ToolConsentStore(directory: nil)
        )
        return (home, coordinator, store)
    }

    private struct WaitingProvider: ModelProvider {
        let id: ProviderID = .codex
        let displayName = "Waiting"
        let capabilities: ModelCapabilities = [.vision, .streaming]
        let started: XCTestExpectation
        let cancelled: XCTestExpectation
        func warm() async {}
        func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.onTermination = { _ in cancelled.fulfill() }
                continuation.yield(.textDelta("The first answer. "))
                started.fulfill()
            }
        }
    }

    func testSpokenInputSurvivesCancellationWhileCaptureIsPending() async throws {
        let session = SessionController()
        let output = Output()
        let (home, coordinator, store) = try execution(provider: Provider(reason: .endTurn))
        let thread = try await store.upsert(PerryThread(draft: "Separate conversation draft"))
        home.homeModel.sidebarSelection = .thread(thread.id)
        home.homeModel.newConversationDraft = "Separate welcome draft"
        let capture = AsyncStream<Void>.makeStream()
        var dispatched = false
        let talk = TalkSession(
            sessionController: session, overlayState: PerryCursorState(), output: output,
            services: .init(makeInput: { Input("Keep my spoken request") }, output: output, capture: {
                for await _ in capture.stream { break }
                return GuideObservation(snapshot: AXSnapshot(appBundleID: "fixture.app", windowTitle: "Fixture", elements: []))
            }, acceptInput: { home.acceptInput($0, threadID: $1, contextKey: $2) }, run: {
                dispatched = true
                return home.runSpokenTurn($0, spatial: $1, coordinator: coordinator)
            }), tracer: PointerTraceRecorder(point: { .zero })
        )
        talk.keyDown()
        talk.holdCommitted()
        talk.keyUp()
        for _ in 0..<200 {
            if await store.thread(id: thread.id)?.waitingInputs?.first != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let saved = await store.thread(id: thread.id)
        XCTAssertEqual(saved?.waitingInputs?.map(\.text), ["Keep my spoken request"])
        XCTAssertEqual(saved?.draft, "Separate conversation draft")
        XCTAssertNil(saved?.pendingTurn)
        XCTAssertFalse(dispatched)
        talk.cancel()
        capture.continuation.finish()
        await home.joinInputSaves()
        XCTAssertFalse(dispatched)
        XCTAssertEqual(home.homeModel.newConversationDraft, "Separate welcome draft")
        let afterCancellation = await store.thread(id: thread.id)
        XCTAssertEqual(afterCancellation?.waitingInputs?.count, 1)
        XCTAssertTrue(afterCancellation?.turns.isEmpty == true)
    }

    func testReleaseKeepsListening250msBeforeFinalizing() async throws {
        final class TimedInput: TalkSpeechInput {
            var finalizedAt: ContinuousClock.Instant?
            func start() async throws {}
            func finalize() async -> (transcript: String, words: [SpokenWord]) {
                finalizedAt = .now
                return ("Explain this", [])
            }
            func cancel() {}
        }
        let input = TimedInput()
        let output = Output()
        let (home, coordinator, _) = try execution(provider: Provider(reason: .endTurn))
        let talk = TalkSession(
            sessionController: SessionController(), overlayState: PerryCursorState(), output: output,
            services: .init(makeInput: { input }, output: output, capture: {
                GuideObservation(snapshot: AXSnapshot(appBundleID: "com.example.Editor", windowTitle: "Document", elements: []))
            }, acceptInput: { home.acceptInput($0, threadID: $1, contextKey: $2) }, run: { home.runSpokenTurn($0, spatial: $1, coordinator: coordinator) }),
            tracer: PointerTraceRecorder(point: { .zero })
        )
        talk.keyDown()
        talk.holdCommitted()
        let released = ContinuousClock.now
        talk.keyUp()
        for _ in 0..<100 where input.finalizedAt == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let finalizedAt = try XCTUnwrap(input.finalizedAt)
        XCTAssertGreaterThanOrEqual(finalizedAt - released, .milliseconds(250))
        talk.cancel()
    }

    func testBargeInKeepsTheNewListeningSessionActive() async throws {
        let started = expectation(description: "First provider stream started")
        let cancelled = expectation(description: "First provider stream cancelled")
        let controller = SessionController()
        let overlay = PerryCursorState()
        let output = Output()
        let (home, coordinator, _) = try execution(provider: WaitingProvider(started: started, cancelled: cancelled))
        let talk = TalkSession(
            sessionController: controller, overlayState: overlay, output: output,
            services: .init(makeInput: { Input() }, output: output, capture: {
                GuideObservation(snapshot: AXSnapshot(appBundleID: "com.example.Editor", windowTitle: "Document", elements: []))
            }, acceptInput: { home.acceptInput($0, threadID: $1, contextKey: $2) }, run: { home.runSpokenTurn($0, spatial: $1, coordinator: coordinator) }),
            tracer: PointerTraceRecorder(point: { .zero })
        )
        var completed = 0
        talk.onTurnCompleted = { completed += 1 }
        talk.keyDown()
        talk.holdCommitted()
        talk.keyUp()
        await fulfillment(of: [started], timeout: 2)
        talk.keyDown()
        await fulfillment(of: [cancelled], timeout: 2)
        await Task.yield()
        XCTAssertEqual(talk.phase, .listening)
        XCTAssertEqual(overlay.voiceState, .listening)
        XCTAssertEqual(overlay.buddyState, .listening)
        XCTAssertFalse(output.isSpeaking)
        XCTAssertEqual(completed, 0)
        guard case .talking(let state) = controller.state else { return XCTFail("Expected Talk state") }
        XCTAssertTrue(state.isListening)
        XCTAssertFalse(state.isWorking)
        XCTAssertEqual(state.turnCount, 0)
        talk.cancel()
    }

    func testKeyPressDuringSpeechPlaybackBargesIn() async throws {
        let controller = SessionController()
        let overlay = PerryCursorState()
        let output = Output()
        output.speechHeld = true
        let talk = TalkSession(
            sessionController: controller, overlayState: overlay, output: output,
            services: .init(makeInput: { Input() }, output: output, capture: {
                GuideObservation(snapshot: AXSnapshot(appBundleID: "com.example.Editor", windowTitle: "Document", elements: []))
            }, acceptInput: { text, id, _ in
                .init(threadID: id ?? UUID(), request: .init(text: text), saved: Task {})
            }, run: { input, _ in
                (input.threadID, AsyncStream { continuation in
                    continuation.yield(.textDelta("Done. "))
                    continuation.yield(.finished(.completed))
                    continuation.finish()
                }, nil)
            }), tracer: PointerTraceRecorder(point: { .zero })
        )
        talk.keyDown()
        talk.holdCommitted()
        talk.keyUp()
        for _ in 0..<200 {
            if case .talking(let state) = controller.state, state.turnCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        talk.keyDown()
        XCTAssertEqual(output.stopped, 1)
        XCTAssertFalse(output.isSpeaking)
        XCTAssertEqual(talk.phase, .listening)
        output.speechHeld = false
        talk.cancel()
    }

    func testSpokenSaveFailureReleasesPresentationWithoutProviderWork() async throws {
        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: blocked)
        addTeardownBlock { try? FileManager.default.removeItem(at: blocked) }
        let store = ThreadStore(directory: blocked)
        let home = HomeController()
        home.threadStore = store
        home.homeModel.newConversationDraft = "Keep this separate draft"
        let coordinator = AgentCoordinator(provider: { _ in
            XCTFail("Saving the input must precede provider work")
            return Provider(reason: .endTurn)
        }, host: PerryToolHost(executors: []), threads: store, consent: ToolConsentStore(directory: nil))
        let observation = GuideObservation(snapshot: AXSnapshot(appBundleID: "com.example.Editor", windowTitle: "Document", elements: []))
        let stream = home.runSpokenTurn(home.acceptInput("Explain this"), spatial: .init(observation: observation, bindings: [], skill: nil), coordinator: coordinator).events
        guard case .thread(let id) = home.homeModel.sidebarSelection else { return XCTFail("Missing conversation") }
        home.homeModel.onStop?(id)
        var finish: AgentFinish?
        for await event in stream { if case .finished(let result) = event { finish = result } }
        guard case .failed = finish else { return XCTFail("Expected save failure") }
        XCTAssertEqual(home.homeModel.unsavedInputs.map(\.request.text), ["Explain this"])
        XCTAssertFalse(home.homeModel.unsavedInputs.first?.error.isEmpty ?? true)
        XCTAssertTrue(home.homeModel.pendingQuestions.isEmpty)
        XCTAssertTrue(home.homeModel.stoppingThreads.isEmpty)
        XCTAssertTrue(coordinator.runningThreads.isEmpty)
        XCTAssertEqual(home.homeModel.newConversationDraft, "Keep this separate draft")
    }

    func testFreshObservationInvalidatesOldInlineInkTargets() async throws {
        let controller = SessionController()
        let overlay = PerryCursorState()
        let output = Output()
        let finished = expectation(description: "Spoken answer finished")
        let talk = TalkSession(
            sessionController: controller, overlayState: overlay, output: output,
            services: .init(makeInput: { Input() }, output: output, capture: {
                GuideObservation(snapshot: AXSnapshot(appBundleID: "com.example.Editor", windowTitle: "Document", elements: [
                    AXElement(stableID: "save", role: .button, label: "Save", frame: AXElementFrame(x: 10, y: 20, width: 80, height: 30), isActionable: true)
                ]))
            }, acceptInput: { text, id, _ in
                .init(threadID: id ?? UUID(), request: .init(text: text), saved: Task {})
            }, run: { input, _ in
                (input.threadID, AsyncStream { continuation in
                    // The coordinator decodes inline markup once: clean text
                    // deltas plus .draw commands (Phase 2 item 6).
                    continuation.yield(.textDelta("Before Save. "))
                    continuation.yield(.draw(DrawCommand(verb: .ring, elementID: "e1", label: "Save")))
                    continuation.yield(.toolCallStarted(ToolCall(id: "refresh", name: "screen.observe", arguments: .object([:]))))
                    continuation.yield(.textDelta("After Moved. "))
                    continuation.yield(.finished(.completed))
                    continuation.finish()
                }, nil)
            }), tracer: PointerTraceRecorder(point: { .zero })
        )
        talk.onTurnCompleted = { finished.fulfill() }
        talk.keyDown()
        talk.holdCommitted()
        talk.keyUp()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(overlay.visualGuidanceOverlays.isEmpty)
        guard case .talking(let state) = controller.state else { return XCTFail("Expected Talk state") }
        XCTAssertEqual(state.answerText, "Before Save. After Moved. ")
        talk.cancel()
    }

    func testSpokenGuideWaitsForRetirementAndSurvivesTalkCleanup() async throws {
        for cancelWhileWaiting in [false, true] {
            let session = SessionController()
            let output = Output()
            let (home, coordinator, store) = try execution(provider: Provider(reason: .endTurn))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let observation = GuideObservation(snapshot: AXSnapshot(appBundleID: "fixture.editor", windowTitle: "Orchid", elements: []), processID: 42, windowID: 73)
            var captured = false
            let guide = GuideSessionCoordinator(
                sessionController: session, workers: CuaWorkerService(),
                transcriptStore: TranscriptStore(directory: root), memoryStore: MemoryStore(storageDirectory: root),
                output: output, context: output,
                fullGuideCaptureLoader: { _, target in
                    XCTAssertEqual(target, CuaTargetHint(bundleID: "fixture.editor", processID: 42, windowID: 73, windowTitle: "Orchid"))
                    captured = true
                    throw CocoaError(.fileReadUnknown)
                }, executionOwner: coordinator
            )
            let waiting = expectation(description: "Talk waits before Guide")
            let release = AsyncStream<Void>.makeStream()
            var turn = 0
            var guideTask: Task<AgentFinish, Never>?
            let talk = TalkSession(
                sessionController: session, overlayState: PerryCursorState(), output: output,
                services: .init(makeInput: {
                    turn += 1
                    return Input(turn == 1 ? "Explain this" : "show me everything for saving")
                }, output: output, capture: { observation },
                acceptInput: { home.acceptInput($0, threadID: $1, contextKey: $2) },
                run: { home.runSpokenTurn($0, spatial: $1, coordinator: coordinator) },
                waitForConversation: { id in
                    await coordinator.waitForCompletion(threadID: id)
                    waiting.fulfill()
                    for await _ in release.stream { break }
                }, guide: { input, spatial, full in
                    XCTAssertEqual(session.state, .idle)
                    XCTAssertTrue(coordinator.runningThreads.isEmpty)
                    guideTask = guide.startGuiding(goal: input.request.text, threadID: input.threadID, targetHint: spatial.target, full: full, waitingInput: input.request)
                }), tracer: PointerTraceRecorder(point: { .zero })
            )
            talk.keyDown()
            talk.holdCommitted()
            talk.keyUp()
            for _ in 0..<200 where talk.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
            guard case .talking(let first) = session.state else { return XCTFail("Missing Talk session") }
            let threadID = try XCTUnwrap(first.threadID)
            home.homeModel.sidebarSelection = .thread(UUID())
            talk.keyDown()
            talk.holdCommitted()
            talk.keyUp()
            await fulfillment(of: [waiting], timeout: 2)
            XCTAssertNil(guideTask)
            if cancelWhileWaiting { talk.cancel() }
            release.continuation.finish()
            for _ in 0..<200 where talk.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
            if cancelWhileWaiting {
                await Task.yield()
                XCTAssertNil(guideTask)
                XCTAssertFalse(captured)
            } else {
                let task = try XCTUnwrap(guideTask)
                let finish = await task.value
                guard case .failed = finish else { return XCTFail("Guide must run after Talk cleanup, not inherit cancellation") }
                XCTAssertTrue(captured)
            }
            let saved = await store.list()
            XCTAssertEqual(saved.count, 1)
            XCTAssertEqual(saved.first?.id, threadID)
            XCTAssertEqual(saved.first?.turns.count, cancelWhileWaiting ? 1 : 2)
            XCTAssertNil(saved.first?.pendingTurn)
            talk.cancel()
            guide.prepareForTermination()
            await guide.joinAfterWorkerShutdown()
        }
    }

    func testSpokenFollowUpWaitsForPreviousPresentationLifetime() async throws {
        let session = SessionController()
        let output = Output()
        let (home, coordinator, store) = try execution(provider: Provider(reason: .endTurn))
        let thread = try await store.upsert(PerryThread(draft: "Unrelated draft"))
        home.homeModel.sidebarSelection = .thread(thread.id)
        let release = AsyncStream<Void>.makeStream()
        var retired = false
        var requests = 0
        var completion: Task<Void, Never>?
        let talk = TalkSession(
            sessionController: session, overlayState: PerryCursorState(), output: output,
            services: .init(makeInput: { Input() }, output: output, capture: {
                GuideObservation(snapshot: AXSnapshot(appBundleID: "fixture.app", windowTitle: "Fixture", elements: []))
            }, acceptInput: { home.acceptInput($0, threadID: $1, contextKey: $2) }, run: { input, spatial in
                requests += 1
                XCTAssertEqual(input.threadID, thread.id)
                let run = home.runSpokenTurn(input, spatial: spatial, coordinator: coordinator)
                if requests > 1 {
                    XCTAssertTrue(retired, "Spoken follow-up outran presentation cleanup")
                    return run
                }
                completion = Task { @MainActor in
                    await run.completion?.value
                    for await _ in release.stream { break }
                    retired = true
                }
                return (run.threadID, run.events, completion)
            }), tracer: PointerTraceRecorder(point: { .zero })
        )
        talk.keyDown()
        talk.holdCommitted()
        talk.keyUp()
        for _ in 0..<200 where talk.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(requests, 1)
        talk.keyDown()
        talk.holdCommitted()
        talk.keyUp()
        for _ in 0..<200 {
            if await store.thread(id: thread.id)?.waitingInputs?.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(requests, 1)
        let waiting = await store.thread(id: thread.id)
        XCTAssertEqual(waiting?.waitingInputs?.map(\.text), ["Explain this"])
        XCTAssertEqual(waiting?.draft, "Unrelated draft")
        XCTAssertEqual(waiting?.turns.count, 1)
        release.continuation.finish()
        for _ in 0..<200 where talk.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(requests, 2)
        guard case .talking(let state) = session.state else { return XCTFail("Missing Talk") }
        XCTAssertEqual(state.turnCount, 2)
        let finished = await store.thread(id: thread.id)
        XCTAssertTrue(finished?.waitingInputs?.isEmpty == true)
        XCTAssertEqual(finished?.draft, "Unrelated draft")
        talk.cancel()
        await completion?.value
    }

    func testTalkFollowUpRetainsConversationWhenHomeSelectionChanges() async throws {
        let controller = SessionController()
        let output = Output()
        let (home, coordinator, store) = try execution(provider: Provider(reason: .endTurn))
        let talk = TalkSession(
            sessionController: controller, overlayState: PerryCursorState(), output: output,
            services: .init(makeInput: { Input() }, output: output, capture: {
                GuideObservation(snapshot: AXSnapshot(appBundleID: "com.example.Editor", windowTitle: "Document", elements: []))
            }, acceptInput: { home.acceptInput($0, threadID: $1, contextKey: $2) }, run: { home.runSpokenTurn($0, spatial: $1, coordinator: coordinator) }),
            tracer: PointerTraceRecorder(point: { .zero })
        )
        var originalID: UUID?
        for count in 1...2 {
            talk.keyDown()
            talk.holdCommitted()
            talk.keyUp()
            for _ in 0..<200 where talk.phase != .idle {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(talk.phase, .idle)
            guard case .talking(let state) = controller.state else { return XCTFail("Missing Talk session") }
            let threadID = try XCTUnwrap(state.threadID)
            if let originalID { XCTAssertEqual(threadID, originalID) } else { originalID = threadID }
            XCTAssertEqual(state.turnCount, count)
            let saved = await store.list()
            XCTAssertEqual(saved.count, 1)
            XCTAssertEqual(saved.first?.turns.count, count)
            home.homeModel.sidebarSelection = .thread(UUID())
        }
        talk.cancel()
    }

    func testOnlyCompletedAnswersAdvanceTalkAndOnboarding() async throws {
        let reasons: [ModelStopReason?] = [nil, .maxTokens, .cancelled, .other("incomplete"), .toolUse, .endTurn]
        for reason in reasons {
            let controller = SessionController()
            let overlay = PerryCursorState()
            let output = Output()
            let (home, coordinator, store) = try execution(provider: Provider(reason: reason))
            let talk = TalkSession(
                sessionController: controller, overlayState: overlay, output: output,
                services: .init(makeInput: { Input() }, output: output, capture: {
                    GuideObservation(snapshot: AXSnapshot(appBundleID: "com.example.Editor", windowTitle: "Document", elements: []), processID: 42, windowID: 7)
                }, acceptInput: { home.acceptInput($0, threadID: $1, contextKey: $2) }, run: { home.runSpokenTurn($0, spatial: $1, coordinator: coordinator) }),
                tracer: PointerTraceRecorder(point: { .zero })
            )
            var completed = 0
            talk.onTurnCompleted = { completed += 1 }
            talk.keyDown()
            talk.holdCommitted()
            talk.keyUp()
            for _ in 0..<200 where talk.phase != .idle {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(talk.phase, .idle)
            guard case .talking(let state) = controller.state else { return XCTFail("Expected Talk state") }
            let succeeded = reason == .endTurn
            XCTAssertEqual(completed, succeeded ? 1 : 0)
            XCTAssertEqual(state.turnCount, succeeded ? 1 : 0)
            XCTAssertFalse(state.isWorking)
            XCTAssertEqual(state.transcript, "Explain this")
            XCTAssertTrue(state.answerText?.contains("partial answer") == true)
            guard case .thread(let id) = home.homeModel.sidebarSelection else { return XCTFail("Missing shared conversation") }
            let saved = await store.thread(id: id)
            XCTAssertEqual(saved?.turns.count, 1)
            XCTAssertEqual(saved?.turns.last?.outcome, succeeded ? .completed : (reason == .cancelled ? .interrupted : .failed))
            XCTAssertEqual(saved?.draft, succeeded ? "" : "Explain this")
            XCTAssertEqual(home.homeModel.threads.first?.id, id)
            if !succeeded {
                XCTAssertNotEqual(overlay.buddyState, .success)
                XCTAssertFalse(output.isSpeaking)
            }
            talk.cancel()
        }
    }
}
