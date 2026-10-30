import Foundation
import PerryCore
import PerryGuide
import PerryRuntimes

enum RoutineOutcome {
    case notStarted
    case finished(DoOutcome, headline: String?)
}

@MainActor
private final class RoutineRunTrace {
    var lastStartedStep: Int?
    var lastBindingError: RoutineReplayError?

    func noteBindingFailure(_ error: RoutineReplayError) {
        lastBindingError = error
    }
}

extension ForegroundTaskController {
    func runRoutine(
        _ routine: LearnedRoutine,
        parameters: [String: String],
        attemptID: UUID,
        worker: CuaWorkerHandle
    ) async throws -> RoutineOutcome {
        guard taskStartIsCurrent(attemptID) else { return .notStarted }
        let workspace = try WorkspaceScope.makeTaskDirectory()
        try await worker.claimResources([.workspace(workspace.standardizedFileURL.path)])
        let captured = await probe.captureScreenContext(worker: worker)
        guard taskStartIsCurrent(attemptID) else { return .notStarted }
        guard EnvironmentProbe.captureIsUsable(captured.context) else {
            hooks.setStatus("I couldn’t capture that window, so I stopped before replaying.")
            voice.speak("I couldn’t capture that window, so I stopped before replaying.")
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
        let executionPlan = (try? plan.maskingSensitiveInputs(in: observation.snapshot.elements)) ?? plan
        let workspaceURL = workspace
        let sandboxLabel = "learned routine “\(routine.name)”"
        let trace = RoutineRunTrace()
        try ExecutionPlanValidator.validate(
            plan,
            capabilities: ExecutionPlanValidator.Capabilities(
                supportedOperations: Set(ExecutableAction.Operation.Kind.allCases),
                workspace: workspaceURL,
                integrationAccounts: remoteIntegrationExecutor.executableAccountIDs
            )
        )
        guard taskStartIsCurrent(attemptID) else { return .notStarted }
        try await worker.claimResources(typedTaskResources(plan: plan, workspaceURL: workspaceURL))
        guard taskStartIsCurrent(attemptID) else { return .notStarted }
        let execution = ExecutionSessionState(
            taskID: UUID(uuidString: plan.taskID.rawValue) ?? UUID(),
            goal: routine.name,
            startedAt: Date(),
            appBundleID: targetWindow.appBundleID,
            providerRoute: sandboxLabel,
            workspace: workspaceURL,
            lifecycle: .starting
        )
        guard presentRunStart(execution, attemptID: attemptID, bubble: "Preparing \(routine.name)…") else { return .notStarted }
        hooks.setStatus("Getting ready with \(sandboxLabel).")
        let confirmer = confirmerOverride ?? hooks.makeConfirmer()
        let typedVerifier = typedVerifierOverride ?? CompositeActionVerifier(workspace: workspaceURL, worker: worker)
        let taskID = execution.taskID
        let supervisor = DoSupervisor(
            activityLog: activityLog,
            confirmer: confirmer,
            typedVerifier: typedVerifier,
            onEvent: { [weak self] event in
                await self?.handleDoEvent(event, taskID: taskID)
            },
            onTypedEvent: { [weak self] event in
                await self?.handleTypedDoEvent(event, taskID: taskID, trace: trace)
            }
        )
        let runJournal = try executionPlan.workspaceEffectsPlan().flatMap { effectsPlan -> WorkspaceRunJournal? in
            guard let coordinator = workspaceCoordinator else { return nil }
            return WorkspaceRunJournal(plan: effectsPlan, workspace: workspaceURL, coordinator: coordinator)
        }
        let typedExecutor = typedActionRouter(
            worker: worker,
            workspace: workspaceURL,
            journal: runJournal,
            bindComputerCommand: { action in
                do {
                    return try RoutineReplay.binding(for: action, of: routine, in: try await observe())
                } catch let error as RoutineReplayError {
                    await trace.noteBindingFailure(error)
                    throw error
                }
            }
        )
        activeRun = SupervisorRunHandle(supervisor: supervisor)
        let outcome = await supervisor.run(
            plan: executionPlan,
            context: captured.context,
            targetWindow: targetWindow,
            typedExecutor: typedExecutor
        )
        await runJournal?.settle()
        return .finished(outcome, headline: headline(for: outcome, routine: routine, trace: trace))
    }

    private func headline(for outcome: DoOutcome, routine: LearnedRoutine, trace: RoutineRunTrace) -> String? {
        switch outcome {
        case .completed:
            return RoutineRunCopy.success(priorVerifiedRuns: routine.verifiedRuns)
        case .failed(_, let reason):
            return RoutineRunCopy.stopped(
                routine: routine,
                step: trace.lastBindingError.flatMap(RoutineRunCopy.step(of:)) ?? trace.lastStartedStep,
                error: trace.lastBindingError,
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
        let askUserOverride = self.askUserOverride
        return TypedActionRouter(
            worker: worker,
            workspace: workspace,
            remoteIntegrations: remoteIntegrationExecutor,
            askUser: { prompt, choices in
                if let askUserOverride { return try await askUserOverride(prompt, choices) }
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
        try await NotchPresentation.shared.askChoice(prompt: prompt, choices: choices)
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
            guard sessionController.transition({ try sessionController.setPlannedStepCount(steps) }) else { return }
        case .started:
            guard sessionController.transition({ try sessionController.setExecutionPhase(.running) }) else { return }
            hooks.setStatus("Working…")
        case .paused:
            guard sessionController.transition({ try sessionController.setExecutionPhase(.paused) }) else { return }
            hooks.setStatus("Paused before the next step.")
        case .resumed:
            guard sessionController.transition({ try sessionController.setExecutionPhase(.running) }) else { return }
        case .steered(let instruction):
            guard execution.lifecycle == .running || execution.lifecycle == .paused else { return }
            hooks.setStatus("Steering: \(instruction)")
        case .confirmationRequested(let request):
            guard sessionController.transition({
                try sessionController.awaitApproval(
                    request.id,
                    actionSummary: request.actionSummary,
                    tier: request.tier
                )
            }) else { return }
            overlayState.buddyState = .awaitingApproval
            hooks.setStatus("Waiting for your OK.")
        case .confirmationAccepted(let approvalID):
            guard sessionController.transition({ try sessionController.acceptApproval(approvalID) }) else { return }
            overlayState.buddyState = .acting
            hooks.setStatus("Continuing the approved task.")
        case .completed:
            guard sessionController.transition({ try sessionController.setExecutionPhase(.verifying) }) else { return }
        case .stopped(let reason):
            guard sessionController.transition({ try sessionController.setExecutionPhase(.stopping) }) else { return }
            hooks.setStatus(reason)
        case .failed(let stepSummary, _):
            guard sessionController.transition({ try sessionController.setExecutionPhase(.stopping) }) else { return }
            hooks.setStatus("I stopped at \(stepSummary).")
        }
    }

    private func handleTypedDoEvent(_ event: TypedDoEvent, taskID: UUID, trace: RoutineRunTrace) {
        guard case .executing(let execution) = sessionController.state,
              execution.taskID == taskID,
              !execution.isFinalized else { return }
        switch event {
        case .actionStarted(let index, let action, let tier):
            trace.lastStartedStep = RoutineReplay.stepIndex(of: action)
            guard sessionController.transition({
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
                guard sessionController.transition({
                    try sessionController.recordVerification(
                        stepID: action.id.rawValue,
                        verified: true,
                        evidence: evidence
                    )
                }) else { return }
            case .unverified(let reason):
                guard sessionController.transition({
                    try sessionController.recordVerification(
                        stepID: action.id.rawValue,
                        verified: false,
                        warning: "\(action.summary): \(reason)"
                    )
                }) else { return }
            case .notRequired:
                guard sessionController.transition({
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
