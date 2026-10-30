import AppKit
import Foundation
import PerryCore
import PerryGuide
import PerryOverlay
import PerryRuntimes

enum RoutineOutcome {
    case notStarted
    case finished(DoOutcome, headline: String?)
}

@MainActor
final class RoutineRunner {
    struct Links {
        var isCurrent: (UUID) -> Bool
        var transition: (() throws -> Void) -> Bool
        var beginExecution: (ExecutionSessionState, UUID) -> Bool
        var showActivityStrip: () -> Void
        var speak: (String) -> Void
    }

    private let sessionController: SessionController
    private let probe: EnvironmentProbe
    private let remoteIntegrationExecutor: RemoteIntegrationActionRuntime
    private let activityLog: ActivityLog
    private let overlayState: PerryCursorState
    private let workspaceCoordinator: TaskCoordinator?
    private let hooks: ForegroundTaskController.Hooks
    private let links: Links

    var activeSupervisor: DoSupervisor?
    private var lastStartedStep: Int?
    private var lastBindingError: RoutineReplayError?

#if DEBUG
    var debugConfirmer: (any Confirmer)?
    var debugAskUser: (@Sendable (String, [String]) async throws -> Void)?
    var debugTypedVerifier: (any TypedActionVerifier)?
#endif

    init(
        sessionController: SessionController,
        probe: EnvironmentProbe,
        remoteIntegrationExecutor: RemoteIntegrationActionRuntime,
        activityLog: ActivityLog,
        overlayState: PerryCursorState,
        workspaceCoordinator: TaskCoordinator?,
        hooks: ForegroundTaskController.Hooks,
        links: Links
    ) {
        self.sessionController = sessionController
        self.probe = probe
        self.remoteIntegrationExecutor = remoteIntegrationExecutor
        self.activityLog = activityLog
        self.overlayState = overlayState
        self.workspaceCoordinator = workspaceCoordinator
        self.hooks = hooks
        self.links = links
    }

    func run(
        _ routine: LearnedRoutine,
        parameters: [String: String],
        attemptID: UUID,
        worker: CuaWorkerHandle
    ) async throws -> RoutineOutcome {
        guard links.isCurrent(attemptID) else { return .notStarted }
        let workspace = try WorkspaceScope.makeTaskDirectory()
        try await worker.claimResources([.workspace(workspace.standardizedFileURL.path)])
        let captured = await probe.captureScreenContext(worker: worker)
        guard links.isCurrent(attemptID) else { return .notStarted }
        guard EnvironmentProbe.captureIsUsable(captured.context) else {
            hooks.setStatus("I couldn’t capture that window, so I stopped before replaying.")
            links.speak("I couldn’t capture that window, so I stopped before replaying.")
            return .notStarted
        }
        let targetStore = CuaGuideTargetStore()
        await targetStore.set(CuaTargetHint(bundleID: routine.bundleID, processID: nil, windowTitle: nil))
        let observe: @Sendable () async throws -> GuideObservation = {
            try await CuaGuideTreeReader(worker: worker, targetStore: targetStore).observe()
        }
        let observation = try await observe()
        let plan = try RoutineReplay.plan(
            routine: routine,
            observation: observation,
            taskID: TaskID(UUID().uuidString),
            parameters: parameters
        )
        let title = observation.snapshot.windowTitle
        let targetWindow = WindowContext(
            appBundleID: routine.bundleID,
            title: title.isEmpty ? "Routine target" : title
        )
        return try await execute(
            plan: plan,
            elements: observation.snapshot.elements,
            routine: routine,
            observe: observe,
            goal: routine.name,
            attemptID: attemptID,
            context: captured.context,
            targetWindow: targetWindow,
            worker: worker,
            workspace: workspace,
            sandboxLabel: "learned routine “\(routine.name)”"
        )
    }

    private func execute(
        plan: ExecutionPlan,
        elements: [AXElement],
        routine: LearnedRoutine,
        observe: @escaping @Sendable () async throws -> GuideObservation,
        goal: String,
        attemptID: UUID,
        context: ScreenContext,
        targetWindow: WindowContext?,
        worker: CuaWorkerHandle,
        workspace: URL,
        sandboxLabel: String
    ) async throws -> RoutineOutcome {
        let taskUUID = UUID(uuidString: plan.taskID.rawValue) ?? UUID()
        lastStartedStep = nil
        lastBindingError = nil
        try ExecutionPlanValidator.validate(
            plan,
            capabilities: ExecutionPlanValidator.Capabilities(
                supportedOperations: Set(ExecutableAction.Operation.Kind.allCases),
                workspace: workspace,
                integrationAccounts: remoteIntegrationExecutor.executableAccountIDs
            )
        )
        guard links.isCurrent(attemptID) else { return .notStarted }
        try await worker.claimResources(typedTaskResources(plan: plan, workspaceURL: workspace))
        guard links.isCurrent(attemptID) else { return .notStarted }
        let execution = ExecutionSessionState(
            taskID: taskUUID,
            goal: goal,
            startedAt: Date(),
            appBundleID: targetWindow?.appBundleID,
            providerRoute: sandboxLabel,
            workspace: workspace,
            lifecycle: .starting,
            initialWarnings: []
        )
        guard links.beginExecution(execution, attemptID) else { return .notStarted }
        hooks.setStatus("Getting ready with \(sandboxLabel).")
        hooks.setTranscriptPreview(goal)
        hooks.stopSpatialMonitoring()
        hooks.stopGuideObservation()
        hooks.hidePanel()
        SoundPlayer.play(.send)
        overlayState.buddyState = .acting
        overlayState.agentTaskBubbleText = "Preparing \(goal)…"
        links.showActivityStrip()
#if DEBUG
        let confirmer = debugConfirmer ?? hooks.makeConfirmer()
        let typedVerifier = debugTypedVerifier ?? CompositeActionVerifier(workspace: workspace, worker: worker)
#else
        let confirmer = hooks.makeConfirmer()
        let typedVerifier: any TypedActionVerifier = CompositeActionVerifier(workspace: workspace, worker: worker)
#endif
        let supervisor = DoSupervisor(
            activityLog: activityLog,
            confirmer: confirmer,
            typedVerifier: typedVerifier,
            onEvent: { [weak self] event in
                await self?.handleDoEvent(event, taskID: execution.taskID)
            },
            onTypedEvent: { [weak self] event in
                await self?.handleTypedDoEvent(event, taskID: execution.taskID)
            }
        )
        activeSupervisor = supervisor
        let executionPlan = (try? plan.maskingSensitiveInputs(in: elements)) ?? plan
        let runJournal = try executionPlan.workspaceEffectsPlan().flatMap { effectsPlan -> WorkspaceRunJournal? in
            guard let coordinator = workspaceCoordinator else { return nil }
            return WorkspaceRunJournal(plan: effectsPlan, workspace: workspace, coordinator: coordinator)
        }
        let typedExecutor = typedActionRouter(
            worker: worker,
            workspace: workspace,
            journal: runJournal,
            bindComputerCommand: { [weak self] action in
                do {
                    return try RoutineReplay.binding(for: action, of: routine, in: try await observe())
                } catch let error as RoutineReplayError {
                    await self?.noteBindingFailure(error)
                    throw error
                }
            }
        )
        let outcome = await supervisor.run(
            plan: executionPlan,
            context: context,
            targetWindow: targetWindow,
            typedExecutor: typedExecutor
        )
        await runJournal?.settle()
        return .finished(outcome, headline: headline(for: outcome, routine: routine))
    }

    private func noteBindingFailure(_ error: RoutineReplayError) {
        lastBindingError = error
    }

    private func headline(for outcome: DoOutcome, routine: LearnedRoutine) -> String? {
        switch outcome {
        case .completed:
            return RoutineRunCopy.success(priorVerifiedRuns: routine.verifiedRuns)
        case .failed(_, let reason):
            return RoutineRunCopy.stopped(
                routine: routine,
                step: lastBindingError.flatMap(RoutineRunCopy.step(of:)) ?? lastStartedStep,
                error: lastBindingError,
                reason: reason
            )
        case .blocked:
            return nil
        }
    }

    private func typedActionRouter(
        worker: CuaWorkerHandle,
        workspace: URL,
        journal: WorkspaceRunJournal?,
        bindComputerCommand: @escaping @Sendable (ExecutableAction) async throws -> RoutineStepBinding?
    ) -> TypedActionRouter {
        let codexRuntimeHome = RuntimeCatalog.codexRuntimeHome
#if DEBUG
        let debugAskUser = self.debugAskUser
#endif
        return TypedActionRouter(
            worker: worker,
            workspace: workspace,
            remoteIntegrations: remoteIntegrationExecutor,
            askUser: { prompt, choices in
#if DEBUG
                if let debugAskUser { return try await debugAskUser(prompt, choices) }
#endif
                try await Self.presentAskUser(prompt: prompt, choices: choices)
            },
            runCodingTask: { runtimeID, workspaceURL, prompt in
                guard runtimeID == "cli.codex" else {
                    throw ExecutionError(message: "No coding agent is set up. Choose one in Settings > Brain.")
                }
                let runtime = CodexRuntime(
                    executableLocator: { try CodexRuntime.bundledLocator() },
                    workingDirectory: workspaceURL,
                    runtimeHome: codexRuntimeHome
                )
                _ = try await runtime.runCodingTask(prompt: prompt)
            },
            journaledTransforms: journal.map { journal in
                { action in try await journal.perform(action) }
            },
            bindComputerCommand: bindComputerCommand
        )
    }

    private static func presentAskUser(prompt: String, choices: [String]) async throws {
        try await TaskQuestionPresenter(prompt: prompt, choices: choices).ask()
    }

    private func typedTaskResources(
        plan: PerryRuntimes.ExecutionPlan,
        workspaceURL: URL
    ) -> Set<BackgroundTaskResource> {
        var resources: Set<BackgroundTaskResource> = [.workspace(workspaceURL.standardizedFileURL.path)]
        for claim in plan.actions.flatMap({ $0.policy.claims }) {
            switch claim {
            case .application(let bundleID): resources.insert(.application(bundleID))
            case .integration(let accountID): resources.insert(.integration(accountID))
            case .workspace(let workspace): resources.insert(.workspace(workspace.standardizedFileURL.path))
            }
        }
        return resources
    }


    private func handleDoEvent(_ event: DoEvent, taskID: UUID) {
        guard case .executing(let execution) = sessionController.state,
              execution.taskID == taskID,
              !execution.isFinalized else { return }
        switch event {
        case .planned(let steps):
            guard links.transition({ try sessionController.setPlannedStepCount(steps) }) else { return }
        case .started:
            guard links.transition({ try sessionController.setExecutionPhase(.running) }) else { return }
            hooks.setStatus("Working…")
        case .paused:
            guard links.transition({ try sessionController.setExecutionPhase(.paused) }) else { return }
            hooks.setStatus("Paused before the next step.")
        case .resumed:
            guard links.transition({ try sessionController.setExecutionPhase(.running) }) else { return }
        case .steered(let instruction):
            guard execution.lifecycle == .running || execution.lifecycle == .paused else { return }
            hooks.setStatus("Steering: \(instruction)")
        case .confirmationRequested(let request):
            guard links.transition({
                try sessionController.awaitApproval(
                    request.id,
                    actionSummary: request.actionSummary,
                    tier: request.tier
                )
            }) else { return }
            overlayState.buddyState = .awaitingApproval
            hooks.setStatus("Waiting for your OK.")
        case .confirmationAccepted(let approvalID):
            guard links.transition({ try sessionController.acceptApproval(approvalID) }) else { return }
            overlayState.buddyState = .acting
            hooks.setStatus("Continuing the approved task.")
        case .completed:
            guard links.transition({ try sessionController.setExecutionPhase(.verifying) }) else { return }
        case .stopped(let reason):
            guard links.transition({ try sessionController.setExecutionPhase(.stopping) }) else { return }
            hooks.setStatus(reason)
        case .failed(let stepSummary, _):
            guard links.transition({ try sessionController.setExecutionPhase(.stopping) }) else { return }
            hooks.setStatus("I stopped at \(stepSummary).")
        }
    }

    private func handleTypedDoEvent(_ event: TypedDoEvent, taskID: UUID) {
        guard case .executing(let execution) = sessionController.state,
              execution.taskID == taskID,
              !execution.isFinalized else { return }
        switch event {
        case .actionStarted(let index, let action, let tier):
            lastStartedStep = RoutineReplay.stepIndex(of: action)
            guard links.transition({
                try sessionController.recordExecutionStep(
                    id: action.id.rawValue,
                    summary: action.summary,
                    tier: tier,
                    reversible: action.policy.reversible,
                    index: index
                )
            }) else { return }
            overlayState.agentTaskBubbleText = action.summary
            hooks.setStatus(action.summary)
        case .verification(let action, let status):
            switch status {
            case .verified(let evidence):
                guard links.transition({
                    try sessionController.recordVerification(
                        stepID: action.id.rawValue,
                        verified: true,
                        evidence: evidence
                    )
                }) else { return }
            case .unverified(let reason):
                guard links.transition({
                    try sessionController.recordVerification(
                        stepID: action.id.rawValue,
                        verified: false,
                        warning: "\(action.summary): \(reason)"
                    )
                }) else { return }
            case .notRequired:
                guard links.transition({
                    try sessionController.recordVerificationNote(
                        stepID: action.id.rawValue,
                        note: "No read-back required"
                    )
                }) else { return }
            }
        }
    }
}

extension ExecutionPlan {
    func workspaceEffectsPlan() throws -> ExecutionPlan? {
        let transforms = actions.filter {
            if case .transform = $0.operation { return true }
            return false
        }
        guard !transforms.isEmpty else { return nil }
        return try ExecutionPlan(
            taskID: taskID,
            goal: goal,
            actions: try transforms.map { action in
                try ExecutableAction(
                    id: action.id,
                    summary: action.summary,
                    timeout: action.timeout,
                    approvalRequirement: .action,
                    idempotency: action.idempotency,
                    operation: action.operation,
                    postcondition: action.postcondition
                )
            },
            requestedScopes: [.workspaceWrite]
        )
    }

    func maskingSensitiveInputs(in elements: [AXElement]) throws -> ExecutionPlan {
        let sensitive = Set(actions.compactMap { action -> ActionID? in
            guard case .computer(_, let command) = action.operation,
                  case .accessibilityID(let identifier)? = command.primarySelector,
                  let element = elements.element(withStableID: identifier),
                  element.sensitivity == .secure || (command.typesText && element.sensitivity != .ordinary) else {
                return nil
            }
            return action.id
        })
        guard !sensitive.isEmpty else { return self }
        return try ExecutionPlan(
            schemaVersion: schemaVersion,
            planID: planID,
            taskID: taskID,
            goal: goal,
            actions: actions.map { action in
                guard sensitive.contains(action.id) else { return action }
                return try ExecutableAction(
                    id: action.id,
                    summary: "Enter sensitive input",
                    timeout: action.timeout,
                    approvalRequirement: action.approvalRequirement,
                    idempotency: action.idempotency,
                    operation: action.operation,
                    postcondition: action.postcondition
                )
            },
            requestedScopes: requestedScopes
        )
    }
}

private extension ExecutableAction.ComputerCommand {
    var typesText: Bool {
        if case .typeText = self { return true }
        return false
    }

    var primarySelector: ExecutableAction.Selector? {
        switch self {
        case .click(let selector), .rightClick(let selector), .doubleClick(let selector),
             .typeText(_, target: let selector), .drag(from: let selector, to: _, durationMilliseconds: _, steps: _):
            return selector
        case .scroll(_, _, _, let selector), .pressKey(_, _, let selector), .hotkey(_, _, let selector):
            return selector
        }
    }
}
