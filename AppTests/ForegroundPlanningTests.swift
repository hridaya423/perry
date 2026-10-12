import Foundation
import AppKit
import XCTest
import SwiftUI
import PerryCapture
import PerryBrain
import PerryCore
import PerryGuide
import PerryRuntimes
@testable import Perry

@MainActor
final class ForegroundPlanningTests: XCTestCase {
    func testGuideTakeoverRetainsConversationTargetAndRejectsDuplicateClicks() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let capture = CuaCapturedWindow.debugFixture(snapshot: AXSnapshot(
            appBundleID: "fixture.app", windowTitle: "Fixture window",
            elements: [AXElement(stableID: "save", role: .button, label: "Save",
                frame: AXElementFrame(x: 20, y: 20, width: 80, height: 30), isActionable: true)]
        ))
        let controller = makeController(
            directory: directory,
            fullGuideCaptureLoader: { _, _ in capture },
            fullGuidePlanner: { _, _, _ in
                [GuideStep(instruction: "Select Save", target: .axElement(stableID: "save"))]
            },
            screenContextLoader: { _, target in
                XCTAssertEqual(target, capture.target.hint)
                return (ScreenContext(frontAppBundleID: "fixture.app", frontWindowTitle: "Fixture window",
                    screenshotReferenceID: "cua:fixture", screenshotCoordinateSpace: .windowPixels), capture.target)
            }
        )
        let store = ThreadStore(directory: directory.appendingPathComponent("handoff-threads"))
        let coordinator = AgentCoordinator(
            provider: { _ in ForegroundAnswerProvider(reason: .endTurn) },
            host: PerryToolHost(executors: []), threads: store,
            consent: ToolConsentStore(directory: nil)
        )
        controller.agentCoordinator = coordinator
        controller.foreground.agentCoordinator = coordinator
        await controller.showEverything(goal: "Save the fixture")
        let presented = await waitUntil { controller.guideCoordinator.debugGuideSpeechIdentity != nil }
        XCTAssertTrue(presented)
        guard case .guiding(let guide) = controller.sessionState else { return XCTFail("Guide did not start") }
        controller.guideCoordinator.takeOverGuide()
        controller.guideCoordinator.takeOverGuide()
        let finished = await waitUntil(timeout: .seconds(10)) {
            let conversations = await store.list()
            return conversations.first?.turns.count == 2 && coordinator.runningThreads.isEmpty
        }
        XCTAssertTrue(finished)
        await controller.foreground.joinStartTask()
        let conversations = await ThreadStore(directory: directory.appendingPathComponent("handoff-threads")).list()
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations.first?.id, guide.threadID)
        XCTAssertEqual(conversations.first?.turns.count, 2)
        XCTAssertEqual(conversations.first?.turns.first?.outcome, .interrupted)
        XCTAssertEqual(conversations.first?.turns.last?.outcome, .completed)
        XCTAssertEqual(conversations.first?.turns.last?.answer, "The fixture answer.")
        XCTAssertNil(conversations.first?.pendingTurn)
        controller.dismiss()
        controller.guideCoordinator.prepareForTermination()
        await controller.guideCoordinator.joinAfterWorkerShutdown()
    }

    func testGuideTakeoverSaveFailurePreventsDo() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let capture = CuaCapturedWindow.debugFixture(snapshot: AXSnapshot(
            appBundleID: "fixture.app", windowTitle: "Fixture window",
            elements: [AXElement(stableID: "save", role: .button, label: "Save",
                frame: AXElementFrame(x: 20, y: 20, width: 80, height: 30), isActionable: true)]
        ))
        let controller = makeController(
            directory: directory,
            fullGuideCaptureLoader: { _, _ in capture },
            fullGuidePlanner: { _, _, _ in
                [GuideStep(instruction: "Select Save", target: .axElement(stableID: "save"))]
            }
        )
        let threadDirectory = directory.appendingPathComponent("handoff-threads")
        let coordinator = AgentCoordinator(
            provider: { _ in
                XCTFail("Takeover dispatched work after its save failed")
                return ForegroundAnswerProvider(reason: .endTurn)
            }, host: PerryToolHost(executors: []), threads: ThreadStore(directory: threadDirectory),
            consent: ToolConsentStore(directory: nil)
        )
        controller.agentCoordinator = coordinator
        controller.foreground.agentCoordinator = coordinator
        await controller.showEverything(goal: "Save the fixture")
        let presented = await waitUntil { controller.guideCoordinator.debugGuideSpeechIdentity != nil }
        XCTAssertTrue(presented)
        let backup = directory.appendingPathComponent("recoverable-threads")
        try FileManager.default.moveItem(at: threadDirectory, to: backup)
        try Data("blocked storage".utf8).write(to: threadDirectory)
        controller.guideCoordinator.takeOverGuide()
        let failed = await waitUntil { controller.sessionStatus.contains("couldn’t be saved") }
        XCTAssertTrue(failed)
        XCTAssertTrue(coordinator.runningThreads.isEmpty)
        XCTAssertEqual(controller.sessionState, .idle)
        let recoverable = await ThreadStore(directory: backup).list()
        XCTAssertEqual(recoverable.first?.pendingTurn?.question, "Save the fixture")
        XCTAssertTrue(recoverable.first?.turns.isEmpty == true)
        controller.guideCoordinator.prepareForTermination()
        await controller.guideCoordinator.joinAfterWorkerShutdown()
    }

    func testDismissedTakeoverCannotStartAfterGuideRetires() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let gate = FullGuidePlannerGate()
        let capture = CuaCapturedWindow.debugFixture(snapshot: AXSnapshot(
            appBundleID: "fixture.app", windowTitle: "Fixture window",
            elements: [AXElement(stableID: "save", role: .button, label: "Save",
                frame: AXElementFrame(x: 20, y: 20, width: 80, height: 30), isActionable: true)]
        ))
        let controller = makeController(
            directory: directory,
            fullGuideCaptureLoader: { _, _ in capture },
            fullGuidePlanner: { goal, observation, context in
                try await gate.plan(goal: goal, observation: observation, context: context)
            }
        )
        let store = ThreadStore(directory: directory.appendingPathComponent("handoff-threads"))
        let coordinator = AgentCoordinator(
            provider: { _ in
                XCTFail("Dismissed takeover dispatched a provider request")
                return ForegroundAnswerProvider(reason: .endTurn)
            }, host: PerryToolHost(executors: []), threads: store,
            consent: ToolConsentStore(directory: nil)
        )
        controller.agentCoordinator = coordinator
        controller.foreground.agentCoordinator = coordinator
        await controller.showEverything(goal: "Save the fixture")
        await gate.waitForFirstEntry()
        controller.guideCoordinator.takeOverGuide()
        let reserved = await waitUntil {
            if case .invoking = controller.sessionState { return true }
            return false
        }
        XCTAssertTrue(reserved)
        controller.dismiss()
        await gate.releaseFirst()
        let retired = await waitUntil { coordinator.runningThreads.isEmpty }
        XCTAssertTrue(retired)
        await controller.foreground.joinStartTask()
        let conversations = await store.list()
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations.first?.turns.count, 1)
        XCTAssertEqual(conversations.first?.turns.first?.outcome, .interrupted)
        XCTAssertEqual(controller.sessionState, .idle)
        controller.guideCoordinator.prepareForTermination()
        await controller.guideCoordinator.joinAfterWorkerShutdown()
    }

    func testProductionAgentRouteConsumesAnswerAndTerminalOutcome() async throws {
        for reason: ModelStopReason? in [.endTurn, .maxTokens, nil] {
            let directory = try makeTemporaryDirectory()
            addTeardownBlock { try TestTempDirectory.remove(directory) }
            let session = SessionController()
            let controller = makeWakingController(directory: directory, session: session)
            let store = ThreadStore(directory: directory.appendingPathComponent("agent-threads"))
            let provider = ForegroundAnswerProvider(reason: reason)
            let coordinator = AgentCoordinator(
                provider: { _ in provider }, host: PerryToolHost(executors: []),
                threads: store, consent: ToolConsentStore(directory: nil)
            )
            controller.foreground.agentCoordinator = coordinator
            let outcome = try await controller.foreground.debugRun(goal: "Read the synthetic fixture")
            XCTAssertEqual(controller.transcriptPreview, "The fixture answer.")
            let history = await TranscriptStore(directory: directory).snapshot()
            let conversations = await store.list()
            XCTAssertEqual(conversations.count, 1)
            XCTAssertEqual(conversations.first?.turns.first?.answer, "The fixture answer.")
            XCTAssertNil(conversations.first?.pendingTurn)
            XCTAssertTrue(coordinator.runningThreads.isEmpty)
            if reason == .endTurn {
                XCTAssertEqual(outcome, .completed(stepsRun: 0))
                XCTAssertEqual(history.first?.outcome, .completed)
                XCTAssertEqual(conversations.first?.turns.first?.outcome, .completed)
            } else {
                guard case .failed = outcome else { return XCTFail("Expected provider failure, received \(String(describing: outcome))") }
                XCTAssertEqual(history.first?.outcome, .failed)
                XCTAssertEqual(conversations.first?.turns.first?.outcome, .failed)
            }
            controller.dismiss()
        }
    }

    func testProductionAgentStopPreservesPartialAnswerWithoutReportingSuccess() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let controller = makeWakingController(directory: directory, session: SessionController())
        let store = ThreadStore(directory: directory.appendingPathComponent("agent-threads"))
        let gate = FinalizationGate()
        let provider = ForegroundAnswerProvider(reason: .endTurn, waitAfterFirstText: { await gate.pause() })
        let coordinator = AgentCoordinator(
            provider: { _ in provider }, host: PerryToolHost(executors: []),
            threads: store, consent: ToolConsentStore(directory: nil)
        )
        controller.foreground.agentCoordinator = coordinator
        let run = Task { try await controller.foreground.debugRun(goal: "Read the synthetic fixture") }
        await gate.waitForEntry()
        let displayed = await waitUntil { controller.transcriptPreview == "The fixture " }
        XCTAssertTrue(displayed)
        controller.foreground.cancel()
        await gate.release()
        let outcome = try await run.value
        guard case .blocked = outcome else { return XCTFail("Stopped execution must not complete") }
        let history = await TranscriptStore(directory: directory).snapshot()
        XCTAssertEqual(history.first?.outcome, .stopped)
        let conversations = await store.list()
        XCTAssertEqual(conversations.first?.turns.first?.answer, "The fixture ")
        XCTAssertEqual(conversations.first?.turns.first?.outcome, .interrupted)
        XCTAssertEqual(conversations.first?.draft, "Read the synthetic fixture")
        XCTAssertNil(conversations.first?.pendingTurn)
        XCTAssertTrue(coordinator.runningThreads.isEmpty)
        XCTAssertFalse(controller.foreground.supervisorActive)
        controller.dismiss()
    }

    func testStaleAgentStreamCannotFinalizeReplacementExecution() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let session = SessionController()
        let controller = makeWakingController(directory: directory, session: session)
        let gate = FinalizationGate()
        let provider = ForegroundAnswerProvider(reason: .endTurn, waitAfterFirstText: { await gate.pause() })
        let coordinator = AgentCoordinator(
            provider: { _ in provider }, host: PerryToolHost(executors: []),
            threads: ThreadStore(directory: directory.appendingPathComponent("agent-threads")),
            consent: ToolConsentStore(directory: nil)
        )
        controller.foreground.agentCoordinator = coordinator
        let run = Task { try await controller.foreground.debugRun(goal: "Old fixture") }
        defer {
            run.cancel()
            Task { await gate.release() }
        }
        await gate.waitForEntry()
        let displayed = await waitUntil { controller.transcriptPreview == "The fixture " }
        XCTAssertTrue(displayed)
        guard case .executing(let original) = session.state else { return XCTFail("Missing execution") }
        try session.fail(.init(taskID: original.taskID, goal: original.goal, message: "Worker retired"))
        try session.completeDismissal()
        try session.wake()
        let replacement = ExecutionSessionState(
            taskID: UUID(), goal: "Replacement fixture", startedAt: Date(), appBundleID: nil,
            workspace: directory, lifecycle: .starting
        )
        try session.startExecution(replacement)
        try session.setExecutionPhase(.running)
        let replacementState = session.state
        await gate.release()
        let outcome = try await run.value
        XCTAssertEqual(outcome, .blocked(reason: "the execution session changed"))
        XCTAssertEqual(session.state, replacementState)
        XCTAssertEqual(controller.transcriptPreview, "The fixture ")
        let history = await TranscriptStore(directory: directory).snapshot()
        XCTAssertTrue(history.isEmpty)
        let settled = await waitUntil { coordinator.runningThreads.isEmpty }
        XCTAssertTrue(settled)
        controller.dismiss()
    }

    func testGuideUsesConversationTargetUnlessExplicitlyRetargeted() async throws {
        let remembered = CuaTargetHint(bundleID: "fixture.editor", processID: 42, windowID: 73, windowTitle: "Orchid")
        let newlySelected = CuaTargetHint(bundleID: "fixture.browser", processID: 43, windowID: 74, windowTitle: "Cedar")
        for override in [nil, newlySelected] as [CuaTargetHint?] {
            let directory = try makeTemporaryDirectory()
            addTeardownBlock { try TestTempDirectory.remove(directory) }
            let threadID = UUID()
            let expected = override ?? remembered
            var captured = false
            let controller = makeController(
                directory: directory,
                fullGuideCaptureLoader: { _, received in
                    XCTAssertEqual(received, expected)
                    captured = true
                    throw FullGuidePlannerError.failed
                }
            )
            controller.homeController.homeModel.sidebarSelection = .thread(threadID)
            controller.homeController.homeModel.conversationTargets[threadID] = remembered
            await controller.showEverything(goal: "Show me where to save it", targetHint: override)
            let settled = await waitUntil { controller.guideCoordinator.debugGuideScopeCount == 0 }
            XCTAssertTrue(settled)
            XCTAssertTrue(captured)
            let saved = await ThreadStore(directory: directory.appendingPathComponent("Threads")).thread(id: threadID)
            XCTAssertEqual(saved?.turns.first?.question, "Show me where to save it")
            XCTAssertEqual(saved?.turns.first?.outcome, .failed)
            XCTAssertNil(saved?.pendingTurn)
            XCTAssertEqual(controller.homeController.homeModel.sidebarSelection, .thread(threadID))
            XCTAssertEqual(controller.homeController.homeModel.conversationTargets[threadID], expected)
        }
    }

    func testExplicitAskGuideTransitionRetainsConversationAndTarget() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let session = SessionController()
        let store = ThreadStore(directory: directory.appendingPathComponent("Threads"))
        let thread = try await store.upsert(PerryThread(draft: "Unrelated conversation draft", turns: [.init(question: "Explain saving", answer: "Use Save")]))
        let target = CuaTargetHint(bundleID: "fixture.editor", processID: 42, windowID: 73, windowTitle: "Orchid")
        var captured = false
        let controller = makeController(
            directory: directory,
            fullGuideCaptureLoader: { _, received in
                XCTAssertEqual(received, target)
                captured = true
                throw FullGuidePlannerError.failed
            }, session: session
        )
        controller.homeController.homeModel.conversationTargets[thread.id] = target
        controller.homeController.homeModel.newConversationDraft = "Preserve this separate draft"
        controller.homeController.homeModel.sidebarSelection = .thread(UUID())
        try session.wake()
        try session.startAsk(AskSessionState(id: UUID(), threadID: thread.id, startedAt: Date(), question: "Explain saving"))
        controller.debugDispatch("show me everything save document")
        let settled = await waitUntil { captured && controller.guideCoordinator.debugGuideScopeCount == 0 }
        XCTAssertTrue(settled)
        let saved = await ThreadStore(directory: directory.appendingPathComponent("Threads")).thread(id: thread.id)
        XCTAssertEqual(saved?.turns.count, 2)
        XCTAssertEqual(saved?.turns.last?.question, "show me everything save document")
        XCTAssertTrue(saved?.waitingInputs?.isEmpty == true)
        XCTAssertEqual(saved?.draft, "Unrelated conversation draft")
        XCTAssertEqual(saved?.turns.last?.outcome, .failed)
        XCTAssertEqual(controller.homeController.homeModel.sidebarSelection, .thread(thread.id))
        XCTAssertNil(controller.homeController.homeModel.drafts[thread.id])
        XCTAssertEqual(controller.homeController.homeModel.newConversationDraft, "Preserve this separate draft")
    }

    func testRenderCompactWithUnsavedRequestRecovery() throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let controller = makeController(directory: directory)
        controller.homeController.homeModel.unsavedInputs = [
            .init(threadID: UUID(), request: .init(text: "Explain this document, keeping the original names and dates."), error: "The disk is full.")
        ]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let frame = NSRect(x: 0, y: 0, width: 480, height: 440)
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            let host = NSHostingView(rootView: CompactConversationView(controller: controller))
            window.contentView = host
            host.frame = frame
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/dependable-evidence/unsaved-compact-\(name).png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination)
            window.close()
        }
    }

    func testRenderWaitingGuideRequestInSessionPanel() throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let session = SessionController()
        let controller = makeController(directory: directory, session: session)
        try session.wake()
        var ask = AskSessionState(id: UUID(), startedAt: Date(), question: "Explain this")
        ask.pendingGuideRequest = .init(text: "Show me how to save this document")
        try session.startAsk(ask)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let frame = NSRect(x: 0, y: 0, width: 500, height: 740)
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            let host = NSHostingView(rootView: SessionPanelView(controller: controller))
            window.contentView = host
            host.frame = frame
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/dependable-evidence/waiting-guide-panel-\(name).png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination)
            window.close()
        }
    }

    func testUnsavedAskGuideRequestRemainsAvailableAndCannotCapture() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        try Data("Storage unavailable".utf8).write(to: directory.appendingPathComponent("Threads"))
        let session = SessionController()
        var captured = false
        let controller = makeController(directory: directory, fullGuideCaptureLoader: { _, _ in
            captured = true
            throw FullGuidePlannerError.failed
        }, session: session)
        try session.wake()
        try session.startAsk(AskSessionState(id: UUID(), startedAt: Date(), question: "Explain this"))
        let request = "show me everything save document"
        controller.debugDispatch(request)
        let failed = await waitUntil { controller.homeController.homeModel.unsavedInputs.contains { $0.request.text == request } }
        XCTAssertTrue(failed)
        guard case .asking(let ask) = session.state else { return XCTFail("Lost the unsaved request") }
        XCTAssertEqual(ask.pendingGuideRequest?.text, request)
        XCTAssertFalse(captured)
        XCTAssertEqual(controller.guideCoordinator.debugGuideScopeCount, 0)
    }

    func testGuideDismissedBeforeScheduledStartDoesNotCapture() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        var captured = false
        let controller = makeController(directory: directory, fullGuideCaptureLoader: { _, _ in
            captured = true
            throw FullGuidePlannerError.failed
        })
        controller.guideCoordinator.startGuiding(goal: "Save", full: true)
        controller.dismiss()
        await Task.yield()
        XCTAssertFalse(captured)
        XCTAssertEqual(controller.sessionState, .idle)
        XCTAssertEqual(controller.guideCoordinator.debugGuideScopeCount, 0)
    }

    func testHomeGuidePersistsFailureInOriginatingConversation() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let prompt = "show me everything for saving this document"
        let store = ThreadStore(directory: directory.appendingPathComponent("Threads"))
        let thread = try await store.upsert(PerryThread(draft: prompt))
        let target = CuaTargetHint(bundleID: "fixture.editor", processID: 42, windowID: 73, windowTitle: "Orchid")
        var captures = 0
        let controller = makeController(directory: directory, fullGuideCaptureLoader: { _, received in
            XCTAssertEqual(received, target)
            captures += 1
            throw FullGuidePlannerError.failed
        })
        let model = controller.homeController.homeModel
        model.threads = [thread]
        model.conversationTargets[thread.id] = target
        model.send(threadID: thread.id, text: prompt)
        let settled = await waitUntil { captures == 1 && model.pendingQuestions.isEmpty }
        XCTAssertTrue(settled)
        let saved = await ThreadStore(directory: directory.appendingPathComponent("Threads")).thread(id: thread.id)
        XCTAssertEqual(saved?.turns.count, 1)
        XCTAssertEqual(saved?.turns.first?.question, prompt)
        XCTAssertEqual(saved?.turns.first?.outcome, .failed)
        XCTAssertEqual(saved?.draft, prompt)
        XCTAssertNil(saved?.pendingTurn)
        XCTAssertNotNil(model.threadErrors[thread.id])
        XCTAssertTrue(controller.agentCoordinator.runningThreads.isEmpty)
    }

    func testHomeStopWaitsForGuideRetirementAndPreservesInput() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let gate = FullGuidePlannerGate()
        let prompt = "show me everything for saving"
        let store = ThreadStore(directory: directory.appendingPathComponent("Threads"))
        let thread = try await store.upsert(PerryThread(draft: prompt))
        let capture = CuaCapturedWindow.debugFixture(snapshot: AXSnapshot(
            appBundleID: "fixture.app", windowTitle: "Fixture",
            elements: [AXElement(stableID: "save", role: .button, label: "Save",
                frame: AXElementFrame(x: 20, y: 20, width: 80, height: 30), isActionable: true)]
        ))
        let controller = makeController(
            directory: directory,
            fullGuideCaptureLoader: { _, _ in capture },
            fullGuidePlanner: { goal, observation, context in
                try await gate.plan(goal: goal, observation: observation, context: context)
            }
        )
        let model = controller.homeController.homeModel
        model.threads = [thread]
        model.send(threadID: thread.id, text: prompt)
        await gate.waitForFirstEntry()
        XCTAssertTrue(controller.agentCoordinator.runningThreads.contains(thread.id))
        model.onStop?(thread.id)
        XCTAssertTrue(model.stoppingThreads.contains(thread.id))
        await gate.releaseFirst()
        let settled = await waitUntil { model.pendingQuestions.isEmpty && controller.agentCoordinator.runningThreads.isEmpty }
        XCTAssertTrue(settled)
        let saved = await ThreadStore(directory: directory.appendingPathComponent("Threads")).thread(id: thread.id)
        XCTAssertEqual(saved?.turns.count, 1)
        XCTAssertEqual(saved?.turns.first?.outcome, .interrupted)
        XCTAssertEqual(saved?.draft, prompt)
        XCTAssertNil(saved?.pendingTurn)
        XCTAssertNil(controller.guideCoordinator.debugGuideSpeechIdentity)
        XCTAssertTrue(model.stoppingThreads.isEmpty)
    }

    func testGuideStorageFailureStopsBeforeCapture() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        try Data("blocked store".utf8).write(to: directory.appendingPathComponent("Threads"))
        var captured = false
        let controller = AppController(
            debugStorageDirectory: directory,
            fullGuideCaptureLoader: { _, _ in
                captured = true
                throw FullGuidePlannerError.failed
            },
            notifier: ForegroundNotifier()
        )
        await controller.showEverything(goal: "Save the fixture")
        let settled = await waitUntil { controller.guideCoordinator.debugGuideScopeCount == 0 }
        XCTAssertTrue(settled)
        XCTAssertFalse(captured)
        XCTAssertTrue(controller.agentCoordinator.runningThreads.isEmpty)
        XCTAssertTrue(controller.sessionStatus.contains("Couldn’t save your request"))
        XCTAssertEqual(controller.sessionState, .idle)
    }

    func testInvocationKeepsItsWindowUntilExplicitSelectionOrNewInvocation() throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        var selection: SpatialSelection?
        let probe = EnvironmentProbe(
            workers: CuaWorkerService(), memoryStore: MemoryStore(storageDirectory: directory),
            oauthCoordinator: OAuthCoordinator(), remoteIntegrationPermissions: RemoteIntegrationPermissionStore(),
            spatialSelection: { selection }, storageDirectory: { directory }
        )
        let target = CuaTargetHint(bundleID: "fixture.editor", processID: 4242, windowID: 1001, windowTitle: "Document")
        probe.pinInvocationTarget(target)
        probe.pinInvocationTargetIfNeeded()
        XCTAssertEqual(probe.currentTargetHint(), target)

        selection = SpatialSelection(
            window: WindowContext(appBundleID: "fixture.preview", title: "Selected PDF"),
            rect: .zero, points: []
        )
        XCTAssertNil(probe.currentTargetHint().processID)
        XCTAssertEqual(probe.currentTargetHint().bundleID, "fixture.preview")
        XCTAssertEqual(probe.currentTargetHint().windowTitle, "Selected PDF")
        selection = nil
        XCTAssertEqual(probe.currentTargetHint(), target)

        probe.clearInvocationTarget()
        let next = CuaTargetHint(bundleID: "fixture.notes", processID: 4343, windowID: 2002)
        probe.pinInvocationTarget(next)
        XCTAssertEqual(probe.currentTargetHint(), next)
    }

    func testDoStartDuringPendingInvocationAdoptsIt() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let session = SessionController()
        let controller = makeWakingController(directory: directory, session: session)
        installAgentRunner(on: controller, directory: directory)

        // Hotkey wake leaves the session .invoking; a Do submission must
        // adopt that invocation instead of dropping on a mismatched id.
        try session.wake()
        controller.foreground.start(goal: "describe the screen")

        let finished = await waitUntil(timeout: .seconds(10)) {
            controller.transcriptPreview == "The fixture answer."
        }
        XCTAssertTrue(finished, "Do goal submitted while .invoking never ran — state: \(controller.sessionState), status: \(controller.sessionStatus)")
        await controller.foreground.joinStartTask()
    }

    func testGuideStartDuringPendingInvocationAdoptsIt() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let session = SessionController()
        let controller = makeWakingController(directory: directory, session: session)

        try session.wake()
        controller.startGuiding(goal: "how do I share this file")

        let guided = await waitUntil(timeout: .seconds(10)) {
            if case .guiding = controller.sessionState { return true }
            return false
        }
        XCTAssertTrue(guided, "Guide submitted while .invoking never started — state: \(controller.sessionState), status: \(controller.sessionStatus)")
        controller.dismiss()
    }

    func testDispatchPlainRequestDuringPendingInvocationStartsAsk() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let session = SessionController()
        let controller = makeWakingController(directory: directory, session: session)

        try session.wake()
        controller.debugDispatch("what does this button do")

        let asked = await waitUntil {
            if case .asking(let ask) = controller.sessionState {
                return ask.question == "what does this button do"
            }
            return false
        }
        XCTAssertTrue(asked, "plain request while .invoking did not open Ask — state: \(controller.sessionState)")
        controller.dismiss()
    }

    func testDispatchDuringAskingKeepsDictatedIntentAsFollowUp() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let session = SessionController()
        let controller = makeWakingController(directory: directory, session: session)

        try session.wake()
        controller.debugDispatch("what does this button do")
        let asked = await waitUntil {
            if case .asking = controller.sessionState { return true }
            return false
        }
        XCTAssertTrue(asked, "Ask session never started — state: \(controller.sessionState)")

        // A dictated Do-intent while Ask is live is a follow-up question,
        // never a task started around the mode the user is in.
        controller.debugDispatch(#"perry, do create file "evil.txt""#)
        let followedUp = await waitUntil {
            if case .asking(let ask) = controller.sessionState {
                return ask.question == #"perry, do create file "evil.txt""#
            }
            return false
        }
        XCTAssertTrue(followedUp, "dictated intent did not stay in Ask — state: \(controller.sessionState)")
        XCTAssertFalse(controller.foreground.startIsInFlight)
        controller.dismiss()
    }

    func testSystemSleepHandsAnActiveRunToTheUser() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let gate = FinalizationGate()
        let controller = makeWakingController(
            directory: directory,
            session: SessionController()
        )
        installAgentRunner(
            on: controller,
            directory: directory,
            provider: ForegroundAnswerProvider(
                reason: .endTurn,
                waitAfterFirstText: { await gate.pause() }
            )
        )
        defer { Task { await gate.release() } }

        controller.foreground.start(goal: "hold at the prompt")
        let running = await waitUntil(timeout: .seconds(10)) {
            guard case .executing(let execution) = controller.sessionState else { return false }
            return execution.lifecycle == .running
        }
        XCTAssertTrue(running, "run never reached .executing — state: \(controller.sessionState)")

        // The Mac sleeping mid-run settles the supervisor at a boundary and
        // hands control to the user; Continue replans against the post-sleep
        // screen instead of trusting pre-sleep observations.
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        let handedOff = await waitUntil {
            guard case .executing(let execution) = controller.sessionState else { return false }
            return execution.lifecycle == .paused
        }
        XCTAssertTrue(handedOff, "sleep did not settle the run — state: \(controller.sessionState)")

        controller.dismiss()
        await gate.release()
        await controller.foreground.joinStartTask()
    }

    func testDispatchDismissDuringAskingDismisses() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let session = SessionController()
        let controller = makeWakingController(directory: directory, session: session)

        try session.wake()
        controller.debugDispatch("what does this button do")
        let asked = await waitUntil {
            if case .asking = controller.sessionState { return true }
            return false
        }
        XCTAssertTrue(asked, "Ask session never started — state: \(controller.sessionState)")

        controller.debugDispatch("stop")
        let dismissed = await waitUntil {
            if case .idle = controller.sessionState { return true }
            return false
        }
        XCTAssertTrue(dismissed, "dismiss while .asking did not settle — state: \(controller.sessionState)")
    }

    func testForegroundDoRoutesToTheAgentLoop() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let provider = AgentRouteProvider()
        let controller = makeController(directory: directory)
        controller.foreground.agentCoordinator = AgentCoordinator(
            provider: { _ in provider },
            host: PerryToolHost(executors: []),
            threads: ThreadStore(directory: directory.appendingPathComponent("Threads")),
            consent: ToolConsentStore(directory: nil)
        )

        let outcome = try await controller.foreground.debugRun(goal: "agent routed goal")

        XCTAssertEqual(provider.requests.count, 1, "goal did not reach the agent loop")
        XCTAssertEqual(outcome, .completed(stepsRun: 0))
    }

    func testFailedForegroundTaskRetryDispatchesTheReplacementOnce() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let provider = FailOnceProvider()
        let controller = makeWakingController(
            directory: directory,
            session: SessionController()
        )
        installAgentRunner(on: controller, directory: directory, provider: provider)

        let firstOutcome = try await controller.foreground.debugRun(goal: "retry this task")
        guard case .failed = firstOutcome else {
            return XCTFail("expected the first attempt to fail, got \(firstOutcome)")
        }

        controller.foreground.retry()
        let retried = await waitUntil(timeout: .seconds(10)) {
            provider.callCount == 2
        }

        XCTAssertTrue(retried, "session state after retry: \(controller.sessionState), status: \(controller.sessionStatus)")
        XCTAssertEqual(provider.callCount, 2)
        await controller.foreground.joinStartTask()
    }

    func testStoppedForegroundReportProjectsAsStopped() throws {
        let session = SessionController()
        let taskID = UUID()
        try session.wake()
        try session.startExecution(
            ExecutionSessionState(
                taskID: taskID,
                goal: "stop this task",
                startedAt: Date(),
                appBundleID: nil,
                workspace: URL(fileURLWithPath: "/tmp/perry-stopped-report"),
                lifecycle: .starting
            )
        )
        try session.setExecutionPhase(.running)
        XCTAssertEqual(session.requestDismissal(), .stopExecution)
        let finalization = try session.beginFinalization(outcome: .completed(stepsRun: 0))
        XCTAssertEqual(
            finalization.outcome,
            .blocked(reason: "stop was requested while finishing; completed actions were not undone")
        )
        try session.report(summary: "Stopped safely", outcome: .stopped)

        let controller = AppController(sessionController: session)
        XCTAssertEqual(controller.foreground.debugActivityState.phase, .reporting)
        XCTAssertEqual(controller.foreground.debugActivityState.title, "Task stopped")
    }

    func testStoppingDuringForegroundFinalizationReportsStopped() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let gate = FinalizationGate()
        let controller = makeWakingController(
            directory: directory,
            session: SessionController(),
            finalizationBarrier: { await gate.pause() }
        )
        installAgentRunner(on: controller, directory: directory)

        let operation = Task {
            try await controller.foreground.debugRun(goal: "stop during finalization")
        }
        await gate.waitForEntry()
        controller.foreground.debugInvokeActivityStop()
        await gate.release()

        let outcome = try await operation.value
        XCTAssertEqual(
            outcome,
            .blocked(reason: "stop was requested while finishing; completed actions were not undone")
        )
        guard case .reporting(let report) = controller.sessionState else {
            return XCTFail("expected a stopped report")
        }
        XCTAssertEqual(report.outcome, .stopped)
        XCTAssertEqual(controller.foreground.debugActivityState.title, "Task stopped")
    }

    func testStopDuringFinalizationPersistenceKeepsCommittedCompletion() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let gate = FinalizationGate()
        let controller = makeWakingController(
            directory: directory,
            session: SessionController(),
            finalizationPersistenceBarrier: { await gate.pause() }
        )
        installAgentRunner(on: controller, directory: directory)

        let operation = Task {
            try await controller.foreground.debugRun(goal: "stop during persistence")
        }
        await gate.waitForEntry()
        controller.foreground.cancel()
        await gate.release()

        let outcome = try await operation.value
        XCTAssertEqual(outcome, .completed(stepsRun: 0))
        guard case .reporting(let report) = controller.sessionState else {
            return XCTFail("expected a completed report")
        }
        XCTAssertEqual(report.outcome, .completed)
        let history = await TranscriptStore(directory: directory).snapshot()
        XCTAssertEqual(history.first?.outcome, .completed)
    }

    func testBlockedFullGuideContinuationCannotMutateReplacementGuide() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let gate = FullGuideContinuationGate()
        let snapshot = AXSnapshot(
            appBundleID: "fixture.app",
            windowTitle: "Fixture window",
            elements: [
                AXElement(
                    stableID: "save",
                    role: .button,
                    label: "Save",
                    frame: AXElementFrame(x: 20, y: 20, width: 80, height: 30),
                    isActionable: true
                )
            ]
        )
        let capture = CuaCapturedWindow.debugFixture(snapshot: snapshot)
        let controller = makeController(
            directory: directory,
            fullGuideCaptureLoader: { _, _ in capture },
            fullGuideContinuationBarrier: { _ in await gate.pause() }
        )

        let firstRun = Task { @MainActor in
            await controller.showEverything(goal: "first")
        }

        await gate.waitForEntry()
        guard case .guiding(let first) = controller.sessionState else {
            return XCTFail("first full guide did not start")
        }
        controller.dismiss()
        let replacementRun = Task { @MainActor in
            await controller.showEverything(goal: "replacement")
        }
        let replacementStarted = await waitUntil {
            guard case .guiding(let replacement) = controller.sessionState else { return false }
            return replacement.goal == "replacement"
        }
        XCTAssertTrue(replacementStarted, "replacement full guide did not start")

        await gate.release()
        await firstRun.value

        guard case .guiding(let replacement) = controller.sessionState else {
            return XCTFail("stale full guide changed the replacement state")
        }
        XCTAssertNotEqual(first.id, replacement.id)
        XCTAssertEqual(replacement.goal, "replacement")

        controller.dismiss()
        await replacementRun.value
        controller.guideCoordinator.prepareForTermination()
        await controller.guideCoordinator.joinAfterWorkerShutdown()
    }

    func testThrowingFullGuidePlannerFinalizesFailedGuideAfterWorkerRelease() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let snapshot = AXSnapshot(
            appBundleID: "fixture.app",
            windowTitle: "Fixture window",
            elements: [
                AXElement(
                    stableID: "save",
                    role: .button,
                    label: "Save",
                    frame: AXElementFrame(x: 20, y: 20, width: 80, height: 30),
                    isActionable: true
                )
            ]
        )
        let capture = CuaCapturedWindow.debugFixture(snapshot: snapshot)
        let controller = makeController(
            directory: directory,
            fullGuideCaptureLoader: { _, _ in capture },
            fullGuidePlanner: { _, _, _ in throw FullGuidePlannerError.failed }
        )

        let run = Task { @MainActor in
            await controller.showEverything(goal: "planner failure")
        }
        await run.value

        let finished = await waitUntil {
            if case .idle = controller.sessionState {
                return controller.guideCoordinator.debugGuideScopeID == nil
            }
            return false
        }
        XCTAssertTrue(finished, "failed full guide state: \(controller.sessionState), scope: \(String(describing: controller.guideCoordinator.debugGuideScopeID))")
        let history = await TranscriptStore(directory: directory).snapshot()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.outcome, .failed)
        XCTAssertEqual(
            history.first?.summary,
            "Perry could not prepare the guide: fixture full-guide planner failure"
        )
    }

    func testDismissedGuidePlannerFailurePersistsStoppedHistoryOnceWhileReplacementRuns() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let gate = FullGuidePlannerGate()
        let snapshot = AXSnapshot(
            appBundleID: "fixture.app",
            windowTitle: "Fixture window",
            elements: [
                AXElement(
                    stableID: "save",
                    role: .button,
                    label: "Save",
                    frame: AXElementFrame(x: 20, y: 20, width: 80, height: 30),
                    isActionable: true
                )
            ]
        )
        let capture = CuaCapturedWindow.debugFixture(snapshot: snapshot)
        let controller = makeController(
            directory: directory,
            fullGuideCaptureLoader: { _, _ in capture },
            fullGuidePlanner: { goal, observation, context in
                try await gate.plan(goal: goal, observation: observation, context: context)
            }
        )

        let firstRun = Task { @MainActor in
            await controller.showEverything(goal: "first")
        }
        await gate.waitForFirstEntry()
        guard case .guiding(let first) = controller.sessionState else {
            return XCTFail("first full guide did not start")
        }
        controller.dismiss()

        let replacementRun = Task { @MainActor in
            await controller.showEverything(goal: "replacement")
        }
        let replacementStarted = await waitUntil {
            guard case .guiding(let replacement) = controller.sessionState else { return false }
            return replacement.goal == "replacement"
        }
        XCTAssertTrue(replacementStarted, "replacement full guide did not start")

        await gate.releaseFirst()
        await firstRun.value

        guard case .guiding(let replacement) = controller.sessionState else {
            return XCTFail("stale guide failure changed the replacement state")
        }
        XCTAssertEqual(replacement.goal, "replacement")
        XCTAssertNotEqual(first.id, replacement.id)
        let historyPersisted = await waitUntil {
            let history = await TranscriptStore(directory: directory).snapshot()
            return history.contains { $0.request == "first" }
        }
        XCTAssertTrue(historyPersisted, "first guide history was not persisted")
        let history = await TranscriptStore(directory: directory).snapshot()
        let firstHistory = history.filter { $0.request == "first" }
        XCTAssertEqual(firstHistory.count, 1)
        XCTAssertEqual(firstHistory.first?.outcome, .stopped)
        XCTAssertEqual(firstHistory.first?.summary, "Guide stopped before it finished.")

        controller.dismiss()
        await replacementRun.value
        let replacementPersisted = await waitUntil {
            let history = await TranscriptStore(directory: directory).snapshot()
            return history.contains { $0.request == "replacement" && $0.outcome == .stopped }
        }
        XCTAssertTrue(replacementPersisted, "replacement guide history was not persisted")
    }

    func testErasureClosesAllGuideScopesAndSuppressesDismissedScopeHistory() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let gate = FullGuidePlannerGate()
        let capture = CuaCapturedWindow.debugFixture(snapshot: AXSnapshot(
            appBundleID: "fixture.app",
            windowTitle: "Fixture window",
            elements: [
                AXElement(
                    stableID: "save",
                    role: .button,
                    label: "Save",
                    frame: AXElementFrame(x: 20, y: 20, width: 80, height: 30),
                    isActionable: true
                )
            ]
        ))
        let controller = makeController(
            directory: directory,
            fullGuideCaptureLoader: { _, _ in capture },
            fullGuidePlanner: { goal, observation, context in
                try await gate.plan(goal: goal, observation: observation, context: context)
            }
        )

        let firstRun = Task { @MainActor in
            await controller.showEverything(goal: "first")
        }
        await gate.waitForFirstEntry()
        controller.dismiss()
        let replacementRun = Task { @MainActor in
            await controller.showEverything(goal: "replacement")
        }
        let replacementStarted = await waitUntil {
            guard case .guiding(let guide) = controller.sessionState else { return false }
            return guide.goal == "replacement"
        }
        XCTAssertTrue(replacementStarted)

        let erasure = Task { @MainActor in
            await controller.guideCoordinator.stopForErasure()
        }
        await gate.releaseFirst()
        await erasure.value
        await firstRun.value
        await replacementRun.value

        XCTAssertEqual(controller.guideCoordinator.debugGuideScopeCount, 0)
        let history = await TranscriptStore(directory: directory).snapshot()
        XCTAssertEqual(history.count, 0)
    }

    func testTerminationJoinsSuspendedCurrentGuideScope() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let gate = FullGuidePlannerGate()
        let controller = makeController(
            directory: directory,
            fullGuideCaptureLoader: { _, _ in
                CuaCapturedWindow.debugFixture(snapshot: AXSnapshot(
                    appBundleID: "fixture.app",
                    windowTitle: "Fixture window",
                    elements: [
                        AXElement(
                            stableID: "save",
                            role: .button,
                            label: "Save",
                            frame: AXElementFrame(x: 20, y: 20, width: 80, height: 30),
                            isActionable: true
                        )
                    ]
                ))
            },
            fullGuidePlanner: { goal, observation, context in
                try await gate.plan(goal: goal, observation: observation, context: context)
            }
        )

        let run = Task { @MainActor in
            await controller.showEverything(goal: "termination")
        }
        await gate.waitForFirstEntry()
        controller.guideCoordinator.prepareForTermination()
        await gate.releaseFirst()
        await controller.guideCoordinator.joinAfterWorkerShutdown()
        await run.value

        XCTAssertEqual(controller.guideCoordinator.debugGuideScopeCount, 0)
    }

    func testTerminationJoinsReplacedGuideScopes() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let gate = FullGuidePlannerGate()
        let controller = makeController(
            directory: directory,
            fullGuideCaptureLoader: { _, _ in
                CuaCapturedWindow.debugFixture(snapshot: AXSnapshot(
                    appBundleID: "fixture.app",
                    windowTitle: "Fixture window",
                    elements: [
                        AXElement(
                            stableID: "save",
                            role: .button,
                            label: "Save",
                            frame: AXElementFrame(x: 20, y: 20, width: 80, height: 30),
                            isActionable: true
                        )
                    ]
                ))
            },
            fullGuidePlanner: { goal, observation, context in
                try await gate.plan(goal: goal, observation: observation, context: context)
            }
        )

        let firstRun = Task { @MainActor in
            await controller.showEverything(goal: "first")
        }
        await gate.waitForFirstEntry()
        controller.dismiss()
        let replacementRun = Task { @MainActor in
            await controller.showEverything(goal: "replacement")
        }
        let replacementStarted = await waitUntil {
            guard case .guiding(let guide) = controller.sessionState else { return false }
            return guide.goal == "replacement"
        }
        XCTAssertTrue(replacementStarted)

        controller.guideCoordinator.prepareForTermination()
        await gate.releaseFirst()
        await controller.guideCoordinator.joinAfterWorkerShutdown()
        await firstRun.value
        await replacementRun.value

        XCTAssertEqual(controller.guideCoordinator.debugGuideScopeCount, 0)
    }

    func testStaleGuideSpeechCompletionCannotClearReplacementHighlight() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let capture = CuaCapturedWindow.debugFixture(snapshot: AXSnapshot(
            appBundleID: "fixture.app",
            windowTitle: "Fixture window",
            elements: [
                AXElement(
                    stableID: "save",
                    role: .button,
                    label: "Save",
                    frame: AXElementFrame(x: 20, y: 20, width: 80, height: 30),
                    isActionable: true
                )
            ]
        ))
        let controller = makeController(
            directory: directory,
            fullGuideCaptureLoader: { _, _ in capture },
            fullGuidePlanner: { _, _, _ in
                [GuideStep(instruction: "this one Save", target: .axElement(stableID: "save"))]
            }
        )

        let firstRun = Task { @MainActor in
            await controller.showEverything(goal: "first")
        }
        let firstSpeech = await waitUntil { controller.guideCoordinator.debugGuideSpeechIdentity != nil }
        XCTAssertTrue(firstSpeech)
        let staleIdentity = try XCTUnwrap(controller.guideCoordinator.debugGuideSpeechIdentity)
        controller.dismiss()

        let replacementRun = Task { @MainActor in
            await controller.showEverything(goal: "replacement")
        }
        let replacementSpeech = await waitUntil {
            guard let identity = controller.guideCoordinator.debugGuideSpeechIdentity else { return false }
            return identity.guideID != staleIdentity.guideID
        }
        XCTAssertTrue(replacementSpeech)
        let replacementIdentity = controller.guideCoordinator.debugGuideSpeechIdentity

        controller.guideCoordinator.debugHandleSpeechFinished(staleIdentity)
        await Task.yield()

        XCTAssertEqual(controller.guideCoordinator.debugGuideSpeechIdentity, replacementIdentity)
        controller.dismiss()
        await firstRun.value
        await replacementRun.value
    }

    func testStaleStartupErrorCannotOverwriteReplacementAttempt() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let gate = StartupStreamGate()
        let provider = StaleErrorProvider(gate: gate)
        let controller = makeController(directory: directory)
        controller.foreground.agentCoordinator = AgentCoordinator(
            provider: { _ in provider },
            host: PerryToolHost(executors: []),
            threads: ThreadStore(directory: directory.appendingPathComponent("Threads")),
            consent: ToolConsentStore(directory: nil)
        )
        controller.foreground.start(goal: "old attempt")
        await gate.waitForCall(1)
        controller.dismiss()
        // Teardown is async: wait for the old run to release the session, then
        // settle the stopped report so the replacement can invoke.
        let tornDown = await waitUntil { !controller.foreground.supervisorActive }
        XCTAssertTrue(tornDown, "old attempt's supervisor did not clear: \(controller.sessionState)")
        controller.dismiss()
        let idled = await waitUntil {
            if case .idle = controller.sessionState { return true }
            return false
        }
        XCTAssertTrue(idled, "session did not settle to idle: \(controller.sessionState)")
        controller.foreground.start(goal: "replacement attempt")
        await gate.waitForCall(2)
        let replacementStatus = controller.sessionStatus
        await gate.releaseFirst()
        await gate.waitForFirstError()
        await Task.yield()

        XCTAssertEqual(controller.sessionStatus, replacementStatus)
        guard case .executing(let state) = controller.sessionState,
              state.goal == "replacement attempt" else {
            return XCTFail("replacement attempt was lost: \(controller.sessionState)")
        }
        controller.dismiss()
        await gate.releaseSecond()
        let replacementCancelled = await waitUntil { !controller.foreground.supervisorActive }
        XCTAssertTrue(replacementCancelled, "replacement state: \(controller.sessionState)")
        controller.dismiss()
    }

    func testOlderActivityRetirementCannotClearReplacementWithSameTaskID() async throws {
        let session = SessionController()
        let taskID = UUID()
        try session.wake()
        try session.startExecution(
            ExecutionSessionState(
                taskID: taskID,
                goal: "first task",
                startedAt: Date(),
                appBundleID: nil,
                workspace: URL(fileURLWithPath: "/tmp/perry-retirement-race"),
                lifecycle: .starting
            )
        )
        try session.setExecutionPhase(.running)
        try session.setExecutionPhase(.verifying)
        _ = try session.beginFinalization(outcome: .completed(stepsRun: 0))
        try session.report(summary: "First report")
        let controller = AppController(sessionController: session)
        let oldGeneration = controller.foreground.debugForegroundActivityGeneration
        controller.foreground.debugScheduleActivityRetirement(taskID: taskID, generation: oldGeneration, after: 0.02)
        try session.completeDismissal()
        try session.wake()
        try session.startExecution(
            ExecutionSessionState(
                taskID: taskID,
                goal: "replacement task",
                startedAt: Date(),
                appBundleID: nil,
                workspace: URL(fileURLWithPath: "/tmp/perry-retirement-race"),
                lifecycle: .starting
            )
        )
        try session.setExecutionPhase(.running)
        try session.setExecutionPhase(.verifying)
        _ = try session.beginFinalization(outcome: .completed(stepsRun: 0))
        try session.report(summary: "Replacement report")

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(controller.sessionState, .reporting(ReportState(taskID: taskID, summary: "Replacement report")))
    }

    private func makeController(
        directory: URL,
        finalizationBarrier: (@MainActor () async -> Void)? = nil,
        finalizationPersistenceBarrier: (@Sendable () async -> Void)? = nil,
        fullGuideCaptureLoader: (@MainActor (CuaWorkerHandle, CuaTargetHint?) async throws -> CuaCapturedWindow)? = nil,
        fullGuideContinuationBarrier: (@MainActor (UUID) async -> Void)? = nil,
        fullGuidePlanner: (@MainActor (String, GuideObservation, GuideContext) async throws -> [GuideStep])? = nil,
        typedVerifier: (any TypedActionVerifier)? = nil,
        askUser: (@Sendable (String, [String]) async throws -> Void)? = nil,
        screenContextLoader: EnvironmentProbe.ScreenContextLoader? = nil,
        session: SessionController? = nil
    ) -> AppController {
        let inventory = RuntimeInventory(
            setup: RuntimeSetupSnapshot(summary: "Typed foreground fixture", records: []),
            choices: [RuntimeChoice(id: "fixture.cli", name: "Fixture CLI")],
            credentialFailure: nil
        )
        return AppController(
            debugStorageDirectory: directory,
            sessionController: session ?? SessionController(),
            runtimeInventoryLoader: { _ in inventory },
            permissionSnapshotLoader: {
                PerryPermissionSnapshot(
                    accessibility: true,
                    screenRecording: .granted,
                    microphone: .granted
                )
            },
            cuaHealthLoader: {
                CuaDriverHealth(ready: true, summary: "Fixture Cua Driver is ready.")
            },
            fullGuideCaptureLoader: fullGuideCaptureLoader,
            fullGuideContinuationBarrier: fullGuideContinuationBarrier,
            fullGuidePlanner: fullGuidePlanner,
            finalizationBarrier: finalizationBarrier,
            finalizationPersistenceBarrier: finalizationPersistenceBarrier,
            screenContextLoader: screenContextLoader ?? { _, _ in
                (
                    ScreenContext(
                        frontAppBundleID: "fixture.app",
                        frontWindowTitle: "Fixture window",
                        screenshotReferenceID: "cua:fixture",
                        screenshotCoordinateSpace: .windowPixels
                    ),
                    nil
                )
            },
            typedVerifier: typedVerifier,
            notifier: ForegroundNotifier(),
            confirmer: ApprovingConfirmer(),
            askUser: askUser ?? { _, _ in }
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            do {
                try await Task.sleep(
                    until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(10))),
                    clock: .continuous
                )
            } catch {
                return false
            }
        }
        return await condition()
    }

    /// AppController with granted permission/CUA fixtures and an injectable
    /// SessionController so tests can drive `wake()` (hotkey → `.invoking`)
    /// before exercising the real submission/dispatch paths.
    private func makeWakingController(
        directory: URL,
        session: SessionController,
        workspace: WorkspaceCapture? = nil,
        finalizationBarrier: (@MainActor () async -> Void)? = nil,
        finalizationPersistenceBarrier: (@Sendable () async -> Void)? = nil
    ) -> AppController {
        let inspector = RuntimeInventoryInspector(
            readDirectProvider: { nil },
            commandLineProviders: []
        )
        return AppController(
            debugStorageDirectory: directory,
            sessionController: session,
            runtimeInventoryLoader: { workingDirectory in
                workspace?.value = workingDirectory
                return try await inspector.inspect(workingDirectory: workingDirectory)
            },
            permissionSnapshotLoader: {
                PerryPermissionSnapshot(
                    accessibility: true,
                    screenRecording: .granted,
                    microphone: .granted
                )
            },
            cuaHealthLoader: {
                CuaDriverHealth(ready: true, summary: "Fixture Cua Driver is ready.")
            },
            finalizationBarrier: finalizationBarrier,
            finalizationPersistenceBarrier: finalizationPersistenceBarrier,
            screenContextLoader: { _, _ in
                (
                    ScreenContext(
                        frontAppBundleID: "fixture.app",
                        frontWindowTitle: "Fixture window",
                        screenshotReferenceID: "cua:fixture",
                        screenshotCoordinateSpace: .windowPixels
                    ),
                    nil
                )
            },
            notifier: ForegroundNotifier(),
            confirmer: ApprovingConfirmer()
        )
    }

    /// Routes `foreground`'s open-ended Do path through an AgentCoordinator
    /// backed by `provider`, the same production route `AppSubsystems` wires.
    private func installAgentRunner(
        on controller: AppController,
        directory: URL,
        provider: any ModelProvider = ForegroundAnswerProvider(reason: .endTurn)
    ) {
        controller.foreground.agentCoordinator = AgentCoordinator(
            provider: { _ in provider },
            host: PerryToolHost(executors: []),
            threads: ThreadStore(directory: directory.appendingPathComponent("agent-threads")),
            consent: ToolConsentStore(directory: nil)
        )
    }

    private func makeProductionController(
        directory: URL,
        inspector: RuntimeInventoryInspector,
        workspace: WorkspaceCapture
    ) -> AppController {
        AppController(
            debugStorageDirectory: directory,
            runtimeInventoryLoader: { workingDirectory in
                workspace.value = workingDirectory
                return try await inspector.inspect(workingDirectory: workingDirectory)
            },
            screenContextLoader: { _, _ in
                (
                    ScreenContext(
                        frontAppBundleID: "fixture.app",
                        frontWindowTitle: "Fixture window",
                        screenshotReferenceID: "cua:fixture",
                        screenshotCoordinateSpace: .windowPixels
                    ),
                    nil
                )
            },
            notifier: ForegroundNotifier(),
            confirmer: ApprovingConfirmer()
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-foreground-planning-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class AgentRouteProvider: ModelProvider, @unchecked Sendable {
    let id: ProviderID = "fixture.agent-route"
    let displayName = "Fixture"
    let capabilities: ModelCapabilities = [.vision, .tools, .streaming]
    private let lock = NSLock()
    private var recorded: [ModelRequest] = []
    var requests: [ModelRequest] { lock.withLock { recorded } }
    func warm() async {}
    func contextWindow(for tier: ModelTier) async throws -> Int? { nil }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        lock.withLock { recorded.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("Done."))
            continuation.yield(.done(.endTurn))
            continuation.finish()
        }
    }
}

/// Fails its first stream so retry coverage can prove the replacement run is
/// dispatched exactly once; the second attempt answers normally.
private final class FailOnceProvider: ModelProvider, @unchecked Sendable {
    let id: ProviderID = "fixture.fail-once"
    let displayName = "Fixture"
    let capabilities: ModelCapabilities = [.streaming]
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }
    func warm() async {}
    func contextWindow(for tier: ModelTier) async throws -> Int? { nil }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        let call = lock.withLock { calls += 1; return calls }
        if call == 1 {
            return AsyncThrowingStream {
                $0.finish(throwing: ExecutionError(message: "first attempt failed"))
            }
        }
        return AsyncThrowingStream {
            $0.yield(.textDelta("Retried."))
            $0.yield(.done(.endTurn))
            $0.finish()
        }
    }
}

private enum FullGuidePlannerError: Error, LocalizedError {
    case failed

    var errorDescription: String? {
        "fixture full-guide planner failure"
    }
}

private struct AlwaysVerifiedTypedActionVerifier: TypedActionVerifier {
    func verify(
        approvedAction: ApprovedExecutableAction,
        result: ActionExecutionResult,
        context: ScreenContext
    ) async -> VerificationStatus {
        .verified(evidence: "fixture verification")
    }
}

private actor FinalizationGate {
    private var entered = false
    private var entryContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        entryContinuation?.resume()
        entryContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            entryContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor FullGuideContinuationGate {
    private var callCount = 0
    private var entryContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        callCount += 1
        guard callCount == 1 else { return }
        entryContinuation?.resume()
        entryContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitForEntry() async {
        if callCount > 0 { return }
        await withCheckedContinuation { continuation in
            entryContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor FullGuidePlannerGate {
    private var callCount = 0
    private var entryContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func plan(goal: String, observation: GuideObservation, context: GuideContext) async throws -> [GuideStep] {
        callCount += 1
        if callCount == 1 {
            entryContinuation?.resume()
            entryContinuation = nil
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
            throw FullGuidePlannerError.failed
        }
        return [
            GuideStep(
                instruction: "this one Save",
                target: .axElement(stableID: "save")
            ),
        ]
    }

    func waitForFirstEntry() async {
        if callCount > 0 { return }
        await withCheckedContinuation { continuation in
            entryContinuation = continuation
        }
    }

    func releaseFirst() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}


private final class WorkspaceCapture: @unchecked Sendable {
    var value: URL?
}

private struct ApprovingConfirmer: Confirmer {
    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool { true }
}

private final class ForegroundNotifier: AppNotificationClient, @unchecked Sendable {
    func configure(
        onApprove: @escaping @MainActor @Sendable (TaskID, String, UUID) -> Void,
        onDeny: @escaping @MainActor @Sendable (TaskID, UUID) -> Void,
        onOpen: @escaping @MainActor @Sendable () -> Void
    ) {}

    func requestAuthorization() async -> Bool { true }

    func deliver(_ notification: TaskNotification) async {}
}

private struct ForegroundAnswerProvider: ModelProvider {
    let id: ProviderID = "fixture.foreground-answer"
    let displayName = "Fixture"
    let capabilities: ModelCapabilities = [.streaming]
    let reason: ModelStopReason?
    var waitAfterFirstText: (@Sendable () async -> Void)? = nil

    func warm() async {}

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.textDelta("The fixture "))
                await waitAfterFirstText?()
                guard !Task.isCancelled else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                continuation.yield(.textDelta("answer."))
                if let reason { continuation.yield(.done(reason)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Records provider dispatches so tests can prove the agent-loop route was
/// taken; answers immediately with a fixed text stream.
private actor StartupStreamGate {
    private var callCount = 0
    private var callWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var firstReleased = false
    private var secondReleased = false
    private var firstErrorObserved = false
    private var firstReleaseWaiter: CheckedContinuation<Void, Never>?
    private var secondReleaseWaiter: CheckedContinuation<Void, Never>?
    private var firstErrorWaiter: CheckedContinuation<Void, Never>?

    func enter() -> Int {
        callCount += 1
        callWaiters[callCount]?.resume()
        callWaiters[callCount] = nil
        return callCount
    }

    func waitForCall(_ count: Int) async {
        if callCount >= count { return }
        await withCheckedContinuation { continuation in
            callWaiters[count] = continuation
        }
    }

    func waitForFirstRelease() async {
        if firstReleased { return }
        await withCheckedContinuation { continuation in
            firstReleaseWaiter = continuation
        }
    }

    func markFirstError() {
        firstErrorObserved = true
        firstErrorWaiter?.resume()
        firstErrorWaiter = nil
    }

    func waitForFirstError() async {
        if firstErrorObserved { return }
        await withCheckedContinuation { continuation in
            firstErrorWaiter = continuation
        }
    }

    func waitForSecondRelease() async {
        if secondReleased { return }
        await withCheckedContinuation { continuation in
            secondReleaseWaiter = continuation
        }
    }

    func releaseFirst() {
        firstReleased = true
        firstReleaseWaiter?.resume()
        firstReleaseWaiter = nil
    }

    func releaseSecond() {
        secondReleased = true
        secondReleaseWaiter?.resume()
        secondReleaseWaiter = nil
    }
}

private enum StaleStartupError: Error {
    case firstAttempt
}

/// The agent-path twin of the old typed-planner fixture: the first stream
/// blocks until released and then fails late, exercising the attempt-staleness
/// guard that keeps a cancelled attempt's error from clobbering its replacement.
private final class StaleErrorProvider: ModelProvider, @unchecked Sendable {
    let id: ProviderID = "fixture.stale-error"
    let displayName = "Fixture"
    let capabilities: ModelCapabilities = [.streaming]
    private let gate: StartupStreamGate

    init(gate: StartupStreamGate) {
        self.gate = gate
    }

    func warm() async {}
    func contextWindow(for tier: ModelTier) async throws -> Int? { nil }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        let gate = self.gate
        return AsyncThrowingStream { continuation in
            Task {
                switch await gate.enter() {
                case 1:
                    await gate.waitForFirstRelease()
                    await gate.markFirstError()
                    continuation.finish(throwing: StaleStartupError.firstAttempt)
                default:
                    await gate.waitForSecondRelease()
                    continuation.yield(.textDelta("Done."))
                    continuation.yield(.done(.endTurn))
                    continuation.finish()
                }
            }
        }
    }
}
