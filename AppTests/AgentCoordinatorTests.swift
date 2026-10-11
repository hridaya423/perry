import Foundation
import XCTest
import PerryBrain
import PerryCore
import PerryGuide
import PerryOverlay
@testable import Perry

@MainActor
final class AgentCoordinatorTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func collect(_ events: AsyncStream<AgentLoopEvent>) async -> [AgentLoopEvent] {
        var result: [AgentLoopEvent] = []
        for await event in events { result.append(event) }
        return result
    }

    func testStoppedSuggestionResearchIsJoinedBeforeErasure() async throws {
        let suite = "perry-suggestion-maintenance-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SuggestionController.enabledKey)
        let entered = expectation(description: "Integration discovery entered")
        let backend = SuspendedSuggestionBackend(entered: entered)
        let coordinator = AgentCoordinator(provider: { _ in
            XCTFail("Stopped suggestion research reached a provider")
            return ConversationTestProvider()
        }, host: PerryToolHost(executors: []), threads: ThreadStore(directory: try directory()), consent: ToolConsentStore(directory: nil))
        let suggestions = SuggestionController(coordinator: coordinator, backend: backend, isBusy: { false }, defaults: defaults)
        let morning = try XCTUnwrap(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()))
        suggestions.start(at: morning)
        await fulfillment(of: [entered], timeout: 2)
        suggestions.stop()
        var joined = false
        let join = Task { @MainActor in await suggestions.joinAll(); joined = true }
        await Task.yield()
        XCTAssertFalse(joined)
        await backend.release()
        await join.value
        XCTAssertTrue(joined)
        XCTAssertTrue(suggestions.cards.isEmpty)
        XCTAssertNil(defaults.data(forKey: "perry.suggestions.pending"))
        defaults.removePersistentDomain(forName: suite)
        suggestions.reloadCards()
        XCTAssertTrue(suggestions.cards.isEmpty)
    }

    func testStoppedPerryScheduleFinishesItsRecordBeforeErasure() async throws {
        let root = try directory()
        let store = PerryStore(directory: root)
        let perry = Perry(name: "Fixture", job: "Wait for cancellation", threadID: UUID().uuidString,
            schedule: .init(kind: .once(.distantPast)))
        try JSONEncoder().encode(perry).write(to: root.appendingPathComponent("\(perry.id.uuidString).json"))
        let entered = expectation(description: "Scheduled provider started")
        let coordinator = AgentCoordinator(provider: { _ in
            entered.fulfill()
            try await Task.sleep(for: .seconds(60))
            return ConversationTestProvider()
        }, host: PerryToolHost(executors: []), threads: ThreadStore(directory: root.appendingPathComponent("Threads")), consent: ToolConsentStore(directory: nil))
        let scheduler = PerrySchedulerController(store: store, coordinator: coordinator, isBusy: { false })
        scheduler.start()
        await scheduler.tick(now: Date(), awake: true, network: true)
        await fulfillment(of: [entered], timeout: 2)
        scheduler.stop()
        coordinator.closeAdmission()
        await coordinator.joinAll()
        await scheduler.joinAll()
        let updated = await store.list()
        XCTAssertNotNil(updated.first?.schedule?.lastRun)
        try FileManager.default.removeItem(at: root)
        await Task.yield()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testMaintenanceRejectsNewRunsAndJoinsCancelledWork() async throws {
        let store = ThreadStore(directory: try directory())
        let coordinator = AgentCoordinator(provider: { _ in ConversationTestProvider() },
            host: PerryToolHost(executors: []), threads: store, consent: ToolConsentStore(directory: nil))
        let entered = expectation(description: "Guide operation entered")
        let release = AsyncStream<Void>.makeStream()
        let id = UUID()
        var finish: AgentFinish?
        _ = coordinator.runGuide(threadID: id, goal: "Guide", runID: UUID(), operation: { _ in
            entered.fulfill()
            for await _ in release.stream { break }
            return ("Partial work", .completed)
        }, onFinish: { finish = $0 })
        await fulfillment(of: [entered], timeout: 2)
        coordinator.closeAdmission()
        let rejected = await collect(coordinator.run(threadID: UUID(), goal: "Must not start"))
        guard case .finished(.failed) = rejected.last else { return XCTFail("Maintenance accepted a new run") }
        await coordinator.joinAll()
        XCTAssertTrue(coordinator.runningThreads.isEmpty)
        XCTAssertEqual(finish, .interrupted)
        let saved = await store.thread(id: id)
        XCTAssertEqual(saved?.turns.last?.outcome, .interrupted)
        XCTAssertNil(saved?.pendingTurn)
        coordinator.reopenAdmission()
        let resumed = await collect(coordinator.run(threadID: UUID(), goal: "New request"))
        XCTAssertEqual(resumed.last, .finished(.completed))
        release.continuation.finish()
    }

    func testBusySpokenRunKeepsRequestedIdentityWhenHomeSelectionChanges() async throws {
        let root = try directory()
        let coordinator = AgentCoordinator(
            provider: { _ in XCTFail("Busy run dispatched a provider"); return ConversationTestProvider() },
            host: PerryToolHost(executors: []), threads: ThreadStore(directory: root),
            consent: ToolConsentStore(directory: nil)
        )
        let home = HomeController()
        home.threadStore = ThreadStore(directory: root)
        let requested = UUID()
        let selected = UUID()
        home.homeModel.sidebarSelection = .thread(selected)
        home.homeModel.pendingQuestions[requested] = .init(text: "Original request", turnIndex: 0)
        let observation = GuideObservation(snapshot: AXSnapshot(appBundleID: "fixture.app", windowTitle: "Fixture", elements: []))
        let run = home.runSpokenTurn(home.acceptInput("Follow up", threadID: requested), spatial: .init(observation: observation, bindings: [], skill: nil), coordinator: coordinator)
        XCTAssertEqual(run.threadID, requested)
        let events = await collect(run.events)
        guard case .finished(.failed) = events.last else { return XCTFail("Expected busy outcome") }
        XCTAssertEqual(home.homeModel.sidebarSelection, .thread(requested))
        XCTAssertEqual(home.homeModel.pendingQuestions[requested]?.text, "Original request")
    }

    func testDiscardedGuideInputCannotReachItsOperation() async throws {
        let store = ThreadStore(directory: try directory())
        let id = UUID()
        let input = PerryThread.WaitingInput(text: "Show me how to save")
        try await store.stageInput(input, to: id)
        try await store.removeWaitingInput(input.id, from: id)
        let coordinator = AgentCoordinator(
            provider: { _ in XCTFail("Discarded input dispatched a provider"); return ConversationTestProvider() },
            host: PerryToolHost(executors: []), threads: store, consent: ToolConsentStore(directory: nil)
        )
        var finish: AgentFinish?
        let task = try XCTUnwrap(coordinator.runGuide(
            threadID: id, goal: input.text, runID: input.id, waitingInputID: input.id,
            operation: { _ in XCTFail("Discarded input started Guide"); return ("", .completed) },
            onFinish: { finish = $0 }
        ))
        await task.value
        guard case .failed = finish else { return XCTFail("Expected rejected admission") }
        let saved = await store.thread(id: id)
        XCTAssertNil(saved?.pendingTurn)
        XCTAssertTrue(saved?.turns.isEmpty == true)
        XCTAssertTrue(coordinator.runningThreads.isEmpty)
    }

    func testGuideRequestKeepsHistoryFreshImageAndRunOwnership() async throws {
        let root = try directory()
        let store = ThreadStore(directory: root)
        let provider = ConversationTestProvider()
        let coordinator = AgentCoordinator(
            provider: { _ in provider }, host: PerryToolHost(executors: []),
            threads: store, consent: ToolConsentStore(directory: nil),
            memoryContext: { (true, "Use the Cedar workspace") }
        )
        let id = UUID()
        _ = await collect(coordinator.run(threadID: id, goal: "The document is called Orchid"))
        let runID = UUID()
        let fresh: [ModelContentPart] = [.text("Fresh Guide observation"), .image(data: Data([7, 8]), mimeType: "image/png")]
        let base = ModelRequest(system: "Explain only; do not act.", messages: [.user(fresh)], tier: .deep, maxOutputTokens: 2048)
        var finish: AgentFinish?
        let task = try XCTUnwrap(coordinator.runGuide(threadID: id, goal: "Show me how to save it", runID: runID, operation: { _ in
            let request = try await coordinator.prepareGuideRequest(threadID: id, runID: runID, provider: provider, request: base)
            XCTAssertEqual(request.messages, [
                .user([.text("The document is called Orchid")]),
                .assistant(text: "Understood", toolCalls: []), .user(fresh)
            ])
            XCTAssertTrue(request.system.contains("Use the Cedar workspace"))
            XCTAssertTrue(request.system.hasSuffix("Explain only; do not act."))
            XCTAssertTrue(request.tools.isEmpty)
            do {
                _ = try await coordinator.prepareGuideRequest(threadID: id, runID: UUID(), provider: provider, request: base)
                XCTFail("A different run borrowed the conversation")
            } catch is CancellationError {}
            return ("Guide complete", .completed)
        }, onFinish: { finish = $0 }))
        await task.value
        XCTAssertEqual(finish, .completed)
        do {
            _ = try await coordinator.prepareGuideRequest(threadID: id, runID: runID, provider: provider, request: base)
            XCTFail("A retired run prepared another request")
        } catch is CancellationError {}
    }

    func testGuideOperationSavesBeforeWorkAndContinuesInSameConversation() async throws {
        let root = try directory()
        let store = ThreadStore(directory: root)
        let provider = ConversationTestProvider()
        let coordinator = AgentCoordinator(
            provider: { _ in provider }, host: PerryToolHost(executors: []),
            threads: store, consent: ToolConsentStore(directory: nil)
        )
        let id = UUID()
        let runID = UUID()
        var finish: AgentFinish?
        let task = try XCTUnwrap(coordinator.runGuide(threadID: id, goal: "Guide me through saving", runID: runID, operation: { thread in
            let reopened = await ThreadStore(directory: root).thread(id: id)
            XCTAssertEqual(reopened?.pendingTurn?.id, runID)
            XCTAssertEqual(reopened?.pendingTurn?.question, "Guide me through saving")
            XCTAssertEqual(thread.id, id)
            XCTAssertTrue(provider.requests.isEmpty)
            return ("Observed completed steps: Open the document. Current instruction, not verified complete: Save.", .interrupted)
        }, onFinish: { finish = $0 }))
        await task.value
        XCTAssertEqual(finish, .interrupted)
        XCTAssertTrue(coordinator.runningThreads.isEmpty)
        let events = await collect(coordinator.run(threadID: id, goal: "Do the remaining step"))
        XCTAssertEqual(events.last, .finished(.completed))
        XCTAssertTrue(provider.requests.last?.messages.contains(.assistant(
            text: "Observed completed steps: Open the document. Current instruction, not verified complete: Save.", toolCalls: []
        )) == true)
        let saved = await ThreadStore(directory: root).thread(id: id)
        XCTAssertEqual(saved?.turns.count, 2)
        XCTAssertNil(saved?.pendingTurn)
    }

    func testGuideSaveFailurePreventsOperationAndReleasesOwnership() async throws {
        let root = try directory().appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: root)
        let coordinator = AgentCoordinator(
            provider: { _ in XCTFail("Guide must not dispatch the agent provider"); return ConversationTestProvider() },
            host: PerryToolHost(executors: []), threads: ThreadStore(directory: root), consent: ToolConsentStore(directory: nil)
        )
        var finish: AgentFinish?
        let task = try XCTUnwrap(coordinator.runGuide(threadID: UUID(), goal: "Guide", runID: UUID(), operation: { _ in
            XCTFail("Work started before input was saved")
            return ("Unexpected", .completed)
        }, onFinish: { finish = $0 }))
        await task.value
        guard case .failed(let message) = finish else { return XCTFail("Expected storage failure") }
        XCTAssertTrue(message.contains("Couldn’t save your request"))
        XCTAssertTrue(coordinator.runningThreads.isEmpty)
    }

    func testLiveChatGPTSpatialTurnAndTextFollowUp() async throws {
        guard ProcessInfo.processInfo.environment["PERRY_LIVE_CHATGPT_TESTS"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_PERRY_LIVE_CHATGPT_TESTS=1 to use the signed-in account with synthetic data.")
        }
        let root = try directory()
        let runtime = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("CodexRuntime/bin/codex")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: runtime.path))
        let process = CodexAppServerProcess(configuration: CodexAppServerConfiguration(
            binaryURL: runtime,
            codexHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Perry/CodexRuntime"),
            workingDirectory: root.appendingPathComponent("runtime")
        ))
        let provider = CodexAppServerProvider(process: process)
        let store = ThreadStore(directory: root.appendingPathComponent("threads"))
        let observations = AgentObservationStore()
        let overlay = PerryCursorState()
        let coordinator = AgentCoordinator(
            provider: { _ in provider },
            host: PerryToolHost(executors: DrawTools(overlayState: overlay, observations: observations).executors),
            threads: store, consent: ToolConsentStore(directory: nil), observations: observations
        )
        let home = HomeController()
        home.threadStore = store
        home.homeModel.newConversationDraft = "Preserve my separate draft"
        let observation = GuideObservation(snapshot: AXSnapshot(appBundleID: "com.example.fixture", windowTitle: "Synthetic fixture", elements: [
            AXElement(stableID: "project", role: .button, label: "Orchid-73", frame: AXElementFrame(x: 100, y: 100, width: 120, height: 30), isActionable: true)
        ]))
        let first = await collect(home.runSpokenTurn(
            home.acceptInput("This is a synthetic test fixture. Our project is Orchid-73. Use the ring tool exactly once on e1, then say the project name. Do not inspect any application."),
            spatial: .init(observation: observation, bindings: [], skill: nil), coordinator: coordinator
        ).events)
        guard case .thread(let id) = home.homeModel.sidebarSelection else {
            await process.terminate()
            return XCTFail("Missing shared conversation")
        }
        XCTAssertEqual(first.last, .finished(.completed))
        let calls = first.compactMap { event -> ToolCall? in
            if case .toolCallStarted(let call) = event { return call }; return nil
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "ring")
        XCTAssertEqual(calls.first?.arguments["elementID"], .string("e1"))
        XCTAssertEqual(overlay.visualGuidanceOverlays.count, 1)
        XCTAssertEqual(home.homeModel.threads.first?.id, id)
        XCTAssertEqual(home.homeModel.newConversationDraft, "Preserve my separate draft")
        let second = await collect(coordinator.run(threadID: id, goal: "What was our project called? Answer with its name only; do not use tools."))
        XCTAssertEqual(second.last, .finished(.completed))
        let saved = await ThreadStore(directory: root.appendingPathComponent("threads")).thread(id: id)
        XCTAssertEqual(saved?.turns.count, 2)
        XCTAssertTrue(saved?.turns.last?.answer.contains("Orchid-73") == true)
        XCTAssertNil(saved?.pendingTurn)
        XCTAssertTrue(coordinator.runningThreads.isEmpty)
        await process.terminate()
    }

    func testCompletionReleasesOnlyItsOwnCapturedContext() async throws {
        let root = try directory()
        let observations = AgentObservationStore()
        let runID = UUID()
        let otherRunID = UUID()
        let snapshot = AgentObservationStore.Snapshot(
            index: ElementIndex(elements: []), window: nil,
            screenshotData: Data([1, 2]), windowBoundsAX: nil
        )
        observations.store(snapshot, runID: runID)
        observations.store(snapshot, runID: otherRunID)
        let provider = ConversationTestProvider()
        let coordinator = AgentCoordinator(
            provider: { _ in provider }, host: PerryToolHost(executors: []),
            threads: ThreadStore(directory: root), consent: ToolConsentStore(directory: nil),
            observations: observations
        )
        let events = await collect(coordinator.run(threadID: UUID(), goal: "Finish", runID: runID))
        XCTAssertEqual(events.last, .finished(.completed))
        XCTAssertNil(observations.snapshot(runID: runID))
        XCTAssertEqual(observations.snapshot(runID: otherRunID)?.screenshotData, Data([1, 2]))
    }

    func testRunIdentityIsDurableBeforeProviderWorkStarts() async throws {
        let root = try directory()
        let store = ThreadStore(directory: root)
        let threadID = UUID()
        let runID = UUID()
        let provider = ConversationTestProvider()
        let coordinator = AgentCoordinator(
            provider: { _ in
                let saved = await store.thread(id: threadID)
                XCTAssertEqual(saved?.pendingTurn?.id, runID)
                return provider
            }, host: PerryToolHost(executors: []), threads: store,
            consent: ToolConsentStore(directory: nil)
        )
        let events = await collect(coordinator.run(threadID: threadID, goal: "Remember this run", runID: runID))
        XCTAssertEqual(events.last, .finished(.completed))
        let saved = await store.thread(id: threadID)
        XCTAssertNil(saved?.pendingTurn)
        XCTAssertEqual(saved?.turns.count, 1)
    }

    func testSpatialTurnSharesDurableHistoryWithoutRetainingItsScreenshot() async throws {
        let root = try directory()
        let store = ThreadStore(directory: root)
        let observations = AgentObservationStore()
        let id = UUID()
        let runID = UUID()
        let provider = ConversationTestProvider()
        let observation = GuideObservation(
            snapshot: AXSnapshot(appBundleID: "com.example.Editor", windowTitle: "Document", elements: [
                AXElement(stableID: "save", role: .button, label: "Save", frame: AXElementFrame(x: 10, y: 20, width: 30, height: 40), isActionable: true),
                AXElement(stableID: "secret", role: .textField, label: "Private password", frame: AXElementFrame(x: 0, y: 0, width: 20, height: 20), isActionable: true, sensitivity: .secure)
            ]), processID: 42, windowID: 7, screenshotData: Data([1, 2, 3])
        )
        let coordinator = AgentCoordinator(
            provider: { requirement in
                if provider.requests.isEmpty {
                    XCTAssertTrue(requirement.capabilities.contains(.vision))
                    XCTAssertEqual(observations.resolveElement("e1", runID: runID)?.label, "Save")
                    XCTAssertNil(observations.resolveElement("e2", runID: runID))
                    let saved = await store.thread(id: id)
                    XCTAssertEqual(saved?.pendingTurn?.id, runID)
                }
                return provider
            }, host: PerryToolHost(executors: []), threads: store,
            consent: ToolConsentStore(directory: nil), observations: observations
        )
        let first = await collect(coordinator.run(
            threadID: id, goal: "Remember Cedar", surface: .talk, runID: runID,
            spatialContext: .init(observation: observation, bindings: [], skill: "Read the current page before explaining.")
        ))
        XCTAssertEqual(first.last, .finished(.completed))
        guard case .user(let contextParts)? = provider.requests[0].messages.dropLast().last else {
            return XCTFail("spatial context should ride as its own user message")
        }
        let contextText = contextParts.compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
        }.joined(separator: "\n")
        XCTAssertTrue(contextText.contains("Save"))
        XCTAssertFalse(contextText.contains("Private password"))
        XCTAssertTrue(contextText.contains("Read the current page"))
        XCTAssertFalse(provider.requests[0].system.contains("Save"))
        XCTAssertEqual(provider.requests[0].messages.last, .user([.text("Remember Cedar"), .image(data: Data([1, 2, 3]), mimeType: "image/jpeg")]))
        XCTAssertNil(observations.snapshot(runID: runID))
        let second = await collect(coordinator.run(threadID: id, goal: "Which project?"))
        XCTAssertEqual(second.last, .finished(.completed))
        XCTAssertEqual(provider.requests[1].messages, [
            .user([.text("Remember Cedar")]), .assistant(text: "Understood", toolCalls: []), .user([.text("Which project?")])
        ])
        let saved = await ThreadStore(directory: root).thread(id: id)
        XCTAssertEqual(saved?.turns.count, 2)
        XCTAssertNil(saved?.pendingTurn)
    }

    func testPlainConversationUsesTextModelWithoutRequestingActionCapabilities() async throws {
        let root = try directory()
        let provider = ConversationTestProvider(capabilities: [.streaming])
        let coordinator = AgentCoordinator(
            provider: { requirement in
                XCTAssertFalse(requirement.capabilities.contains(.vision))
                XCTAssertFalse(requirement.capabilities.contains(.tools))
                return provider
            }, host: PerryToolHost(executors: []), threads: ThreadStore(directory: root),
            consent: ToolConsentStore(directory: nil)
        )
        let id = UUID()
        let events = await collect(coordinator.run(threadID: id, goal: "Help me phrase this sentence"))
        XCTAssertEqual(events.last, .finished(.completed))
        XCTAssertEqual(provider.requests.first?.tools, [])
        let saved = await ThreadStore(directory: root).thread(id: id)
        XCTAssertEqual(saved?.turns.first?.answer, "Understood")
        XCTAssertNil(saved?.pendingTurn)
    }

    func testFollowUpReceivesPriorConversationAndPersistsExactlyOnce() async throws {
        let root = try directory()
        let store = ThreadStore(directory: root)
        let provider = ConversationTestProvider()
        let coordinator = AgentCoordinator(
            provider: { _ in provider }, host: PerryToolHost(executors: []),
            threads: store, consent: ToolConsentStore(directory: nil)
        )
        let id = UUID()
        _ = await collect(coordinator.run(threadID: id, goal: "Remember the name Juniper"))
        let events = await collect(coordinator.run(threadID: id, goal: "What name?"))

        XCTAssertEqual(events.last, .finished(.completed))
        XCTAssertEqual(provider.requests.last?.messages, [
            .user([.text("Remember the name Juniper")]),
            .assistant(text: "Understood", toolCalls: []),
            .user([.text("What name?")])
        ])
        let saved = await ThreadStore(directory: root).thread(id: id)
        XCTAssertEqual(saved?.turns.count, 2)
        XCTAssertNil(saved?.pendingTurn)
        XCTAssertTrue(coordinator.runningThreads.isEmpty)
    }

    func testLongConversationSummarizesBeforeAnswerAndRetainsSources() async throws {
        let root = try directory()
        let store = ThreadStore(directory: root)
        let original = PerryThread(turns: (0..<100).map { index in
            index == 0
                ? .init(question: "The Orchid project ships Thursday.", answer: "Recorded.")
                : .init(question: "Question \(index)", answer: String(repeating: "a", count: 600))
        })
        _ = try await store.upsert(original)
        let provider = ConversationTestProvider(capacity: 4096)
        let coordinator = AgentCoordinator(
            provider: { _ in provider }, host: PerryToolHost(executors: []),
            threads: store, consent: ToolConsentStore(directory: nil)
        )
        let events = await collect(coordinator.run(threadID: original.id, goal: "When does the Orchid project ship?"))
        XCTAssertEqual(events.last, .finished(.completed))
        XCTAssertTrue(provider.requests.last?.messages.contains { message in
            guard case .user(let parts) = message, case .text(let text) = parts.first else { return false }
            return text.hasPrefix("Selected original conversation turns") && text.contains("The Orchid project ships Thursday.")
        } == true)
        XCTAssertGreaterThan(provider.requests.count, 1)
        XCTAssertTrue(provider.requests.first?.system.contains("Condense earlier conversation") == true)
        XCTAssertTrue(provider.requests.first?.tools.isEmpty == true)
        let saved = await ThreadStore(directory: root).thread(id: original.id)
        XCTAssertNotNil(saved?.contextSummary)
        XCTAssertEqual(saved?.turns.count, 101)
        XCTAssertEqual(saved?.turns.first?.question, original.turns.first?.question)
    }

    func testIncompleteSummaryStopsBeforeAnswerAndRetainsRequest() async throws {
        let root = try directory()
        let store = ThreadStore(directory: root)
        let original = PerryThread(turns: [.init(question: "Earlier question", answer: String(repeating: "a", count: 50_000))])
        _ = try await store.upsert(original)
        let provider = ConversationTestProvider(stopReason: .maxTokens)
        let coordinator = AgentCoordinator(
            provider: { _ in provider }, host: PerryToolHost(executors: []),
            threads: store, consent: ToolConsentStore(directory: nil)
        )
        let events = await collect(coordinator.run(threadID: original.id, goal: "Continue safely"))
        guard case .finished(.providerError) = events.last else { return XCTFail("Expected summary failure") }
        XCTAssertEqual(provider.requests.count, 1)
        let saved = await store.thread(id: original.id)
        XCTAssertNil(saved?.contextSummary)
        XCTAssertEqual(saved?.turns.last?.outcome, .failed)
        XCTAssertEqual(saved?.draft, "Continue safely")
        XCTAssertNil(saved?.pendingTurn)
        XCTAssertTrue(coordinator.runningThreads.isEmpty)
    }

    func testUnwritableRequestNeverCallsProvider() async throws {
        let root = try directory().appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: root)
        let provider = ConversationTestProvider()
        var routed = false
        let coordinator = AgentCoordinator(
            provider: { _ in routed = true; return provider }, host: PerryToolHost(executors: []),
            threads: ThreadStore(directory: root), consent: ToolConsentStore(directory: nil)
        )
        let events = await collect(coordinator.run(threadID: UUID(), goal: "Change a file"))
        guard case .finished(.failed) = events.last else { return XCTFail("Expected a visible save failure") }
        XCTAssertFalse(routed)
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertTrue(coordinator.runningThreads.isEmpty)
    }

    func testSecondRunCannotReplaceTheActiveConversationOwner() async throws {
        let coordinator = AgentCoordinator(
            provider: { _ in ConversationTestProvider() }, host: PerryToolHost(executors: []),
            threads: ThreadStore(directory: try directory()), consent: ToolConsentStore(directory: nil)
        )
        let id = UUID()
        let first = coordinator.run(threadID: id, goal: "First")
        let second = coordinator.run(threadID: id, goal: "Second")
        let rejected = await collect(second)
        guard case .finished(.failed) = rejected.last else { return XCTFail("Expected the second run to be refused") }
        let finished = await collect(first)
        XCTAssertEqual(finished.last, .finished(.completed))
        XCTAssertTrue(coordinator.runningThreads.isEmpty)
    }

    func testContextOverflowPreservesRequestWithoutProviderDispatch() async throws {
        let root = try directory()
        let id = UUID()
        let provider = ConversationTestProvider(capacity: 4096)
        let coordinator = AgentCoordinator(
            provider: { _ in provider }, host: PerryToolHost(executors: []),
            threads: ThreadStore(directory: root), consent: ToolConsentStore(directory: nil)
        )
        let question = String(repeating: "🪴", count: 2000)
        let events = await collect(coordinator.run(threadID: id, goal: question))
        guard case .finished(.providerError) = events.last else { return XCTFail("Expected context failure") }
        XCTAssertTrue(provider.requests.isEmpty)
        let saved = await ThreadStore(directory: root).thread(id: id)
        XCTAssertEqual(saved?.draft, question)
        XCTAssertEqual(saved?.turns.last?.outcome, .failed)
        XCTAssertNil(saved?.pendingTurn)
        XCTAssertTrue(coordinator.runningThreads.isEmpty)
    }

    func testTruncatedAnswerIsSavedAsFailedWithRecoverableInput() async throws {
        let root = try directory()
        let id = UUID()
        let provider = ConversationTestProvider(stopReason: nil)
        let coordinator = AgentCoordinator(
            provider: { _ in provider }, host: PerryToolHost(executors: []),
            threads: ThreadStore(directory: root), consent: ToolConsentStore(directory: nil)
        )
        let events = await collect(coordinator.run(threadID: id, goal: "Summarize my document"))
        guard case .finished(.failed) = events.last else { return XCTFail("Expected incomplete response failure") }
        let saved = await ThreadStore(directory: root).thread(id: id)
        XCTAssertEqual(saved?.turns.last?.outcome, .failed)
        XCTAssertEqual(saved?.turns.last?.answer, "Understood")
        XCTAssertEqual(saved?.draft, "Summarize my document")
        XCTAssertNotNil(saved?.turns.last?.failureReason)
        XCTAssertNil(saved?.pendingTurn)
        XCTAssertTrue(coordinator.runningThreads.isEmpty)
        XCTAssertEqual(provider.requests.count, 1)
    }

    func testProviderFailureIsSavedAndDoesNotFallback() async throws {
        let root = try directory()
        let id = UUID()
        let coordinator = AgentCoordinator(
            provider: { _ in throw ModelProviderError(kind: .unauthenticated, provider: .codex, message: "Sign in") },
            host: PerryToolHost(executors: []), threads: ThreadStore(directory: root),
            consent: ToolConsentStore(directory: nil)
        )
        let events = await collect(coordinator.run(threadID: id, goal: "Help"))
        guard case .finished(.providerError) = events.last else { return XCTFail("Expected the original provider failure") }
        let saved = await ThreadStore(directory: root).thread(id: id)
        XCTAssertEqual(saved?.turns.first?.outcome, .failed)
        XCTAssertTrue(saved?.turns.first?.failureReason?.contains("Sign in") == true)
        XCTAssertNil(saved?.pendingTurn)
        XCTAssertTrue(coordinator.runningThreads.isEmpty)
    }

    func testStopDuringProviderSetupRetiresTheRun() async throws {
        let root = try directory()
        let entered = expectation(description: "Provider setup entered")
        let id = UUID()
        let provider = ConversationTestProvider()
        let coordinator = AgentCoordinator(
            provider: { _ in
                entered.fulfill()
                try await Task.sleep(for: .seconds(60))
                return provider
            }, host: PerryToolHost(executors: []),
            threads: ThreadStore(directory: root), consent: ToolConsentStore(directory: nil)
        )
        let stream = coordinator.run(threadID: id, goal: "Do something")
        await fulfillment(of: [entered], timeout: 2)
        coordinator.stop(threadID: id)
        let events = await collect(stream)
        XCTAssertEqual(events.last, .finished(.interrupted))
        XCTAssertTrue(provider.requests.isEmpty)
        let saved = await ThreadStore(directory: root).thread(id: id)
        XCTAssertEqual(saved?.turns.first?.outcome, .interrupted)
        XCTAssertNil(saved?.pendingTurn)
        XCTAssertTrue(coordinator.runningThreads.isEmpty)
    }
}

private final class ConversationTestProvider: ModelProvider, @unchecked Sendable {
    let id: ProviderID = .codex
    let displayName = "Test"
    let capabilities: ModelCapabilities
    private let stopReason: ModelStopReason?
    private let capacity: Int?
    init(capabilities: ModelCapabilities = [.vision, .tools, .streaming], stopReason: ModelStopReason? = .endTurn, capacity: Int? = nil) {
        self.capabilities = capabilities
        self.stopReason = stopReason
        self.capacity = capacity
    }
    private let lock = NSLock()
    private var recorded: [ModelRequest] = []
    var requests: [ModelRequest] { lock.withLock { recorded } }

    func warm() async {}
    func contextWindow(for tier: ModelTier) async throws -> Int? { capacity }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        lock.withLock { recorded.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("Understood"))
            if let stopReason { continuation.yield(.done(stopReason)) }
            continuation.finish()
        }
    }
}

private actor SuspendedSuggestionBackend: IntegrationBackend {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(entered: XCTestExpectation) { self.entered = entered }

    func services() async throws -> [IntegrationService] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
        return [.init(id: "fixture", name: "Fixture", connected: true, writeEnabled: false,
                      operations: [.init(name: "read", description: "Read fixture", isWrite: false)])]
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func perform(service: String, operation: String, arguments: JSONValue) async throws -> JSONValue {
        XCTFail("Maintenance fixture must not execute integration operations")
        return .null
    }
}
