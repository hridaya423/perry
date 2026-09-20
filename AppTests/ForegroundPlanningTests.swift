import Foundation
import XCTest
import PerryCapture
import PerryCore
import PerryGuide
import PerryRuntimes
@testable import Perry

@MainActor
final class ForegroundPlanningTests: XCTestCase {
    func testProductionWorkspaceProviderExecutesAndVerifiesTypedPostcondition() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceCapture()
        let inspector = RuntimeInventoryInspector(
            readDirectProvider: { nil },
            commandLineProviders: []
        )
        let inventory = try await inspector.inspect(workingDirectory: directory)
        let provider = try XCTUnwrap(inventory.registry.provider(for: "local.workspace-files"))
        XCTAssertEqual(provider.descriptor.operations, [.planning, .execution])
        XCTAssertEqual(provider.descriptor.capabilities, RuntimeCapabilities(fileIO: true, latencyClass: .fast))
        XCTAssertEqual(
            ProductionRuntimeSelector().select(
                from: inventory.registry,
                preferredProviderID: "local.workspace-files"
            )?.providerID,
            "local.workspace-files"
        )
        let controller = makeProductionController(
            directory: directory,
            inspector: inspector,
            workspace: workspace
        )

        let goal = #"create file "report.txt" with "typed foreground""#
        let outcome = try await controller.foreground.debugRun(
            goal: goal,
            preferredRuntimeID: "local.workspace-files"
        )
        let taskWorkspace = try XCTUnwrap(workspace.value)
        let file = taskWorkspace.appendingPathComponent("report.txt")
        let history = await TranscriptStore(directory: directory).snapshot()

        XCTAssertEqual(outcome, .completed(stepsRun: 1))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "typed foreground")
        XCTAssertEqual(history.first?.outcome, .completed)
        XCTAssertEqual(history.first?.verified, true)
    }

    func testFileGoalRoutesAwayFromConfiguredDirectProvider() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let endpoint = BYOKAgentEndpoint(
            baseURL: try XCTUnwrap(URL(string: "https://api.openai.com")),
            model: "fixture-model"
        )
        let inspector = RuntimeInventoryInspector(
            readDirectProvider: {
                ConfiguredDirectRuntime(endpoint: endpoint, credential: "fixture-secret")
            },
            commandLineProviders: []
        )
        let workspace = WorkspaceCapture()
        let controller = makeProductionController(
            directory: directory,
            inspector: inspector,
            workspace: workspace
        )

        let outcome = try await controller.foreground.debugRun(
            goal: #"create file "routed.txt" with "workspace route""#
        )
        let taskWorkspace = try XCTUnwrap(workspace.value)

        XCTAssertEqual(outcome, .completed(stepsRun: 1))
        XCTAssertEqual(
            try String(contentsOf: taskWorkspace.appendingPathComponent("routed.txt"), encoding: .utf8),
            "workspace route"
        )
    }

    func testTypedPlanningErrorDoesNotCallLegacyPlannerOrExecute() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let planner = ForegroundPlanner(error: PlanningError.typedPlanRejected("fixture planning failure"))
        let controller = makeController(
            directory: directory,
            planner: planner
        )

        do {
            _ = try await controller.foreground.debugRun(goal: "typed planning failure")
            XCTFail("typed planning failure should stop foreground execution")
        } catch let error as PlanningError {
            XCTAssertEqual(error, .typedPlanRejected("fixture planning failure"))
        }

        XCTAssertEqual(controller.sessionState, .idle)
    }

    func testFailedForegroundTaskRetryDispatchesTheReplacementOnce() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let planner = ForegroundPlanner()
        let askUser = FailOnceAskUser()
        let controller = makeController(
            directory: directory,
            planner: planner,
            askUser: { _, _ in try await askUser.answer() }
        )

        let firstOutcome = try await controller.foreground.debugRun(goal: "retry this task")
        XCTAssertEqual(
            firstOutcome,
            .failed(stepSummary: "Typed action", reason: "retry fixture failure")
        )

        controller.foreground.retry()
        let retried = await waitUntil(timeout: .seconds(10)) {
            await askUser.callCount == 2
        }

        XCTAssertTrue(retried, "session state after retry: \(controller.sessionState), status: \(controller.sessionStatus)")
        let callCount = await askUser.callCount
        XCTAssertEqual(callCount, 2)
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
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let gate = FinalizationGate()
        let planner = ForegroundPlanner()
        let controller = makeController(
            directory: directory,
            planner: planner,
            finalizationBarrier: { await gate.pause() },
            typedVerifier: AlwaysVerifiedTypedActionVerifier()
        )

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
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let gate = FinalizationGate()
        let controller = makeController(
            directory: directory,
            planner: ForegroundPlanner(),
            finalizationPersistenceBarrier: { await gate.pause() },
            typedVerifier: AlwaysVerifiedTypedActionVerifier()
        )

        let operation = Task {
            try await controller.foreground.debugRun(goal: "stop during persistence")
        }
        await gate.waitForEntry()
        controller.foreground.cancel()
        await gate.release()

        let outcome = try await operation.value
        XCTAssertEqual(outcome, .completed(stepsRun: 1))
        guard case .reporting(let report) = controller.sessionState else {
            return XCTFail("expected a completed report")
        }
        XCTAssertEqual(report.outcome, .completed)
        let history = await TranscriptStore(directory: directory).snapshot()
        XCTAssertEqual(history.first?.outcome, .completed)
    }

    func testBlockedFullGuideContinuationCannotMutateReplacementGuide() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
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
            planner: ForegroundPlanner(),
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
    }

    func testThrowingFullGuidePlannerFinalizesFailedGuideAfterWorkerRelease() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
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
            planner: ForegroundPlanner(),
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
            "Cua could not finish the full guide: fixture full-guide planner failure"
        )
    }

    func testDismissedGuidePlannerFailurePersistsStoppedHistoryOnceWhileReplacementRuns() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
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
            planner: ForegroundPlanner(),
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
    }

    func testErasureClosesAllGuideScopesAndSuppressesDismissedScopeHistory() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
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
            planner: ForegroundPlanner(),
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
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let gate = FullGuidePlannerGate()
        let controller = makeController(
            directory: directory,
            planner: ForegroundPlanner(),
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
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let gate = FullGuidePlannerGate()
        let controller = makeController(
            directory: directory,
            planner: ForegroundPlanner(),
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
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
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
            planner: ForegroundPlanner(),
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
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let gate = StartupPlanningGate()
        let planner = StaleErrorPlanner(gate: gate)
        let controller = makeController(
            directory: directory,
            planner: planner,
            typedVerifier: AlwaysVerifiedTypedActionVerifier()
        )
        controller.foreground.start(goal: "old attempt")
        await gate.waitForCall(1)
        controller.dismiss()
        controller.foreground.start(goal: "replacement attempt")
        let replacementStatus = controller.sessionStatus
        await gate.releaseFirst()
        await gate.waitForFirstError()
        await Task.yield()

        XCTAssertEqual(controller.sessionStatus, replacementStatus)
        guard case .invoking = controller.sessionState else {
            return XCTFail("replacement attempt was lost: \(controller.sessionState)")
        }
        controller.dismiss()
        await gate.releaseSecond()
        let replacementCancelled = await waitUntil {
            if case .idle = controller.sessionState { return true }
            return false
        }
        XCTAssertTrue(replacementCancelled, "replacement state: \(controller.sessionState)")
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
        planner: any TaskPlanner,
        finalizationBarrier: (@MainActor () async -> Void)? = nil,
        finalizationPersistenceBarrier: (@Sendable () async -> Void)? = nil,
        fullGuideCaptureLoader: (@MainActor (CuaWorkerHandle, CuaTargetHint?) async throws -> CuaCapturedWindow)? = nil,
        fullGuideContinuationBarrier: (@MainActor (UUID) async -> Void)? = nil,
        fullGuidePlanner: (@MainActor (String, GuideObservation, GuideContext) async throws -> [GuideStep])? = nil,
        typedVerifier: (any TypedActionVerifier)? = nil,
        askUser: (@Sendable (String, [String]) async throws -> Void)? = nil
    ) -> AppController {
        let descriptor = RuntimeProviderDescriptor(
            id: planner.id,
            displayName: "Typed foreground fixture",
            kind: .local,
            capabilities: planner.capabilities,
            operations: [.planning, .execution],
            installation: .notApplicable(.local),
            confinement: .workspace,
            priority: 100
        )
        let provider = RuntimeProvider(
            planner: planner,
            descriptor: descriptor
        )
        let inventory = RuntimeInventory(
            registry: RuntimeProviderRegistry(providers: [provider]),
            setup: RuntimeSetupSnapshot(summary: "Typed foreground fixture", records: []),
            choices: [RuntimeChoice(id: planner.id, name: planner.id)],
            automaticPreference: provider.id,
            credentialFailure: nil
        )
        return AppController(
            debugStorageDirectory: directory,
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

private final class ForegroundPlanner: TaskPlanner, @unchecked Sendable {
    let id = "fixture.typed-foreground"
    let capabilities = RuntimeCapabilities(latencyClass: .fast)
    private let error: Error?
    private let lock = NSLock()
    private var recordedTaskID: TaskID?

    init(error: Error? = nil) {
        self.error = error
    }

    var requestedTaskID: TaskID? {
        lock.withLock { recordedTaskID }
    }

    func plan(_ request: PlanningRequest) async throws -> ExecutionPlan {
        lock.withLock { recordedTaskID = request.taskID }
        if let error { throw error }
        let action = try ExecutableAction(
            id: ActionID("typed-action"),
            summary: "Typed action",
            approvalRequirement: .action,
            operation: .askUser(prompt: "Continue?", choices: ["yes"]),
            postcondition: .answered
        )
        return try ExecutionPlan(
            taskID: request.taskID,
            goal: request.goal,
            actions: [action],
            requestedScopes: []
        )
    }
}

private final class StaleErrorPlanner: TaskPlanner, @unchecked Sendable {
    let id = "fixture.stale-error"
    let capabilities = RuntimeCapabilities(latencyClass: .fast)
    private let gate: StartupPlanningGate
    private let fixture = ForegroundPlanner()

    init(gate: StartupPlanningGate) {
        self.gate = gate
    }

    func plan(_ request: PlanningRequest) async throws -> ExecutionPlan {
        switch await gate.enter() {
        case 1:
            await gate.waitForFirstRelease()
            await gate.markFirstError()
            throw StaleStartupError.firstAttempt
        default:
            await gate.waitForSecondRelease()
            return try await fixture.plan(request)
        }
    }
}

private enum StaleStartupError: Error {
    case firstAttempt
}

private enum FullGuidePlannerError: Error, LocalizedError {
    case failed

    var errorDescription: String? {
        "fixture full-guide planner failure"
    }
}

private actor StartupPlanningGate {
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

private enum RetryFixtureError: Error, CustomStringConvertible {
    case firstAttempt

    var description: String { "retry fixture failure" }
}

private actor FailOnceAskUser {
    private(set) var callCount = 0

    func answer() throws {
        callCount += 1
        if callCount == 1 {
            throw RetryFixtureError.firstAttempt
        }
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
