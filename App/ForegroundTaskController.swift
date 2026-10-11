import AppKit
import Foundation
import PerryBrain
import PerryCore
import PerryGuide
import PerryOverlay
import PerryRuntimes

typealias FinalizationBarrier = @MainActor () async -> Void

/// Owns the foreground Do flow end to end: the invocation attempt lifecycle,
/// permission/health gates, grounded capture, runtime selection, plan
/// validation, resource claims, the `DoSupervisor`, session-state event
/// handling, finalization, retry/steer/pause controls, and the activity strip
/// that mirrors execution. The shell owns panels, menus, and onboarding; this
/// controller owns the work.
@MainActor
final class ForegroundTaskController: ObservableObject {
    struct Hooks {
        var setStatus: (String) -> Void = { _ in }
        var setTranscriptPreview: (String) -> Void = { _ in }
        var isErasureInProgress: () -> Bool = { false }
        var requestOnboarding: () -> Void = {}
        var hidePanel: () -> Void = {}
        var dismissIntentCard: () -> Void = {}
        var stopSpatialMonitoring: () -> Void = {}
        var stopGuideObservation: () -> Void = {}
        var makeConfirmer: () -> any Confirmer = { InteractiveConfirmer(controller: nil) }
    }

    private let sessionController: SessionController
    private let workers: CuaWorkerService
    private let probe: EnvironmentProbe
    private let runtimes: RuntimeCatalog
    private let voice: VoiceController
    private let remoteIntegrationExecutor: RemoteIntegrationActionRuntime
    private let activityLog: ActivityLog
    private let executionFinalizer: ExecutionFinalizer
    private let transcriptStore: TranscriptStore
    private let overlayState: PerryCursorState
    /// Durable record owner for workspace effects: when a plan contains file
    /// transforms they run write-ahead through this coordinator, so a
    /// foreground run lands the same receipts the queue produces — and Undo
    /// covers it.
    private let workspaceCoordinator: TaskCoordinator?
    private let hooks: Hooks

    private(set) var activeSupervisor: DoSupervisor?
    /// Open-ended Do goals run through the agent loop (Phase 7
    /// consolidation); the typed-plan supervisor remains for routine
    /// replay only. Set by the shell after init — no cycle either way.
    var agentCoordinator: AgentCoordinator?
    /// Lent to tool executors for the duration of an agent-driven run.
    var workerLease: ForegroundWorkerLease?
    /// The coordinator thread a live agent run is bound to; strip controls
    /// (pause/resume/steer/stop) route here when set.
    private var activeAgentThreadID: UUID?
    private var handoffToHuman = false
    private var handoffGoal: String?
    private var rehearsalContext: RehearsalContext?

    /// Everything a rehearsal repaint needs. Kept only while the plan card is
    /// up — cleared when the first action dispatches or the run exits.
    private struct RehearsalContext {
        var plan: ExecutionPlan
        var target: CuaWindowTarget?
        var markIDs: Set<UUID>
        var seenPlanRequest = false
    }
    private var doStartTask: Task<Void, Never>?
    private var foregroundActivityGeneration = UUID()
    private var observedForegroundTaskID: UUID?

    private let activityStripState = AgentActivityStripState()
    private var activityStripWindow: AgentActivityStripWindow?

#if DEBUG
    private var debugFinalizationBarrier: FinalizationBarrier?
    private var debugConfirmer: (any Confirmer)?
    private var debugAskUser: (@Sendable (String, [String]) async throws -> Void)?
    private var debugTypedVerifier: (any TypedActionVerifier)?
#endif

    var supervisorActive: Bool { activeSupervisor != nil || activeAgentThreadID != nil }

    var startIsInFlight: Bool { doStartTask != nil }

    init(
        sessionController: SessionController,
        workers: CuaWorkerService,
        probe: EnvironmentProbe,
        runtimes: RuntimeCatalog,
        voice: VoiceController,
        remoteIntegrationExecutor: RemoteIntegrationActionRuntime,
        activityLog: ActivityLog,
        executionFinalizer: ExecutionFinalizer,
        transcriptStore: TranscriptStore,
        overlayState: PerryCursorState,
        workspaceCoordinator: TaskCoordinator?,
        hooks: Hooks
    ) {
        self.sessionController = sessionController
        self.workers = workers
        self.probe = probe
        self.runtimes = runtimes
        self.voice = voice
        self.remoteIntegrationExecutor = remoteIntegrationExecutor
        self.activityLog = activityLog
        self.executionFinalizer = executionFinalizer
        self.transcriptStore = transcriptStore
        self.overlayState = overlayState
        self.workspaceCoordinator = workspaceCoordinator
        self.hooks = hooks
#if DEBUG
        self.debugFinalizationBarrier = nil
        self.debugConfirmer = nil
        self.debugAskUser = nil
        self.debugTypedVerifier = nil
#endif
    }

#if DEBUG
    convenience init(
        sessionController: SessionController,
        workers: CuaWorkerService,
        probe: EnvironmentProbe,
        runtimes: RuntimeCatalog,
        voice: VoiceController,
        remoteIntegrationExecutor: RemoteIntegrationActionRuntime,
        activityLog: ActivityLog,
        executionFinalizer: ExecutionFinalizer,
        transcriptStore: TranscriptStore,
        overlayState: PerryCursorState,
        hooks: Hooks,
        finalizationBarrier: FinalizationBarrier?,
        confirmer: (any Confirmer)?,
        askUser: (@Sendable (String, [String]) async throws -> Void)?,
        typedVerifier: (any TypedActionVerifier)?,
        workspaceCoordinator: TaskCoordinator? = nil
    ) {
        self.init(
            sessionController: sessionController,
            workers: workers,
            probe: probe,
            runtimes: runtimes,
            voice: voice,
            remoteIntegrationExecutor: remoteIntegrationExecutor,
            activityLog: activityLog,
            executionFinalizer: executionFinalizer,
            transcriptStore: transcriptStore,
            overlayState: overlayState,
            workspaceCoordinator: workspaceCoordinator,
            hooks: hooks
        )
        self.debugFinalizationBarrier = finalizationBarrier
        self.debugConfirmer = confirmer
        self.debugAskUser = askUser
        self.debugTypedVerifier = typedVerifier
    }
#endif

    // MARK: Session observation

    /// Keeps the retirement generation and the activity strip in step with the
    /// session. Called from the shell's session-state sink.
    func handleSessionState(_ state: SessionState) {
        switch state {
        case .executing(let execution):
            if observedForegroundTaskID != execution.taskID {
                foregroundActivityGeneration = UUID()
                observedForegroundTaskID = execution.taskID
            }
        case .invoking:
            break
        default:
            observedForegroundTaskID = nil
        }
        activityStripState.apply(sessionState: state)
    }

    // MARK: Invocation lifecycle

    @discardableResult
    private func transitionSession(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return true
        } catch {
            hooks.setStatus("Perry stopped because its session state changed unexpectedly.")
            return false
        }
    }

    private func beginInvokingIfNeeded(attemptID: UUID = UUID()) -> Bool {
        if case .idle = sessionController.state {
            return transitionSession { try sessionController.wake(attemptID: attemptID) }
        }
        if case .invoking(let invocation) = sessionController.state, invocation.id == attemptID { return true }
        return false
    }

    func cancelInvocationIfCurrent(_ attemptID: UUID) {
        guard case .invoking(let invocation) = sessionController.state, invocation.id == attemptID else { return }
        _ = try? sessionController.cancelInvocation(attemptID)
    }

    private func taskStartIsCurrent(_ attemptID: UUID) -> Bool {
        guard !Task.isCancelled else { return false }
        guard case .invoking(let invocation) = sessionController.state else { return false }
        return invocation.id == attemptID
    }

    // MARK: Do mode

    func start(goal: String, preferredRuntimeID: String? = nil, threadID: UUID? = nil, targetHint: CuaTargetHint? = nil) {
        guard !hooks.isErasureInProgress() else {
            voice.speak("I’m finishing a data erase before starting anything new.")
            return
        }
        guard !supervisorActive, !startIsInFlight else {
            voice.speak("I’m already working on a task. Stop or pause that one first.")
            return
        }
        let attemptID = sessionController.currentOrFreshAttemptID
        guard beginInvokingIfNeeded(attemptID: attemptID) else {
            voice.speak("Finish or stop the current session first.")
            hooks.setStatus("Finish or stop the current session first.")
            return
        }
        start(goal: goal, preferredRuntimeID: preferredRuntimeID, attemptID: attemptID, threadID: threadID, targetHint: targetHint)
    }

    private func start(goal: String, preferredRuntimeID: String? = nil, attemptID: UUID, threadID: UUID?, targetHint: CuaTargetHint?) {
        doStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.cancelInvocationIfCurrent(attemptID)
                self.doStartTask = nil
            }
            _ = await self.begin(goal: goal, attemptID: attemptID, preferredRuntimeID: preferredRuntimeID, threadID: threadID, targetHint: targetHint)
        }
    }

    func begin(goal: String, attemptID: UUID, preferredRuntimeID: String? = nil, threadID: UUID? = nil, targetHint: CuaTargetHint? = nil) async -> DoOutcome? {
        guard !supervisorActive else {
            guard taskStartIsCurrent(attemptID) else { return nil }
            voice.speak("I’m already working on a task. Stop or pause that one first.")
            return nil
        }
        guard await preflight(attemptID: attemptID) else { return nil }
        do {
            return try await workers.withWorker(scope: .foreground, resources: []) { worker in
                try await self.runForegroundOperation(
                    goal: goal,
                    attemptID: attemptID,
                    preferredRuntimeID: preferredRuntimeID,
                    worker: worker, threadID: threadID, targetHint: targetHint
                )
            }
        } catch {
            guard !(error is CancellationError), taskStartIsCurrent(attemptID) else { return nil }
            hooks.setStatus("Perry could not complete the task safely: \(error.localizedDescription)")
            voice.speak("Perry could not complete the task safely: \(error.localizedDescription)")
            return nil
        }
    }

    /// Permission and driver-health gates every foreground flow shares —
    /// goal planning, routine replay, anything that will touch the screen.
    private func preflight(attemptID: UUID) async -> Bool {
        guard taskStartIsCurrent(attemptID) else { return false }
        let permissions = await probe.permissionSnapshot()
        guard taskStartIsCurrent(attemptID) else { return false }
        guard permissions.requiredPermissionsGranted else {
            guard taskStartIsCurrent(attemptID) else { return false }
            hooks.setStatus("Accessibility and Screen Recording are required for a grounded task.")
            voice.speak("I need Accessibility and Screen Recording permission before I can safely take that on.")
            hooks.requestOnboarding()
            return false
        }
        let cuaHealth = await probe.cuaHealth()
        guard taskStartIsCurrent(attemptID) else { return false }
        guard cuaHealth.ready else {
            guard taskStartIsCurrent(attemptID) else { return false }
            hooks.setStatus(cuaHealth.summary)
            voice.speak(cuaHealth.summary)
            return false
        }
        return true
    }

    // MARK: Routine replay

    /// Runs a reviewed learned routine. The typed plan is rebuilt from a
    /// fresh observation of the routine's own app window — recorded
    /// coordinates are never replayed — then it flows through the same
    /// rehearsal, approval, and verification gates as a planned task.
    func startRoutine(_ routine: LearnedRoutine, parameters: [String: String] = [:]) {
        guard !hooks.isErasureInProgress() else {
            voice.speak("I’m finishing a data erase before starting anything new.")
            return
        }
        guard !supervisorActive, !startIsInFlight else {
            voice.speak("I’m already working on a task. Stop or pause that one first.")
            return
        }
        let attemptID = sessionController.currentOrFreshAttemptID
        guard beginInvokingIfNeeded(attemptID: attemptID) else {
            voice.speak("Finish or stop the current session first.")
            hooks.setStatus("Finish or stop the current session first.")
            return
        }
        doStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.cancelInvocationIfCurrent(attemptID)
                self.doStartTask = nil
            }
            _ = await self.beginRoutine(routine, parameters: parameters, attemptID: attemptID)
        }
    }

    private func beginRoutine(
        _ routine: LearnedRoutine,
        parameters: [String: String],
        attemptID: UUID
    ) async -> DoOutcome? {
        guard !supervisorActive else {
            guard taskStartIsCurrent(attemptID) else { return nil }
            voice.speak("I’m already working on a task. Stop or pause that one first.")
            return nil
        }
        guard await preflight(attemptID: attemptID) else { return nil }
        do {
            return try await workers.withWorker(scope: .foreground, resources: []) { worker in
                try await self.runRoutineOperation(
                    routine: routine,
                    parameters: parameters,
                    attemptID: attemptID,
                    worker: worker
                )
            }
        } catch {
            guard !(error is CancellationError), taskStartIsCurrent(attemptID) else { return nil }
            hooks.setStatus("Perry could not run the routine: \(error.localizedDescription)")
            voice.speak("Perry could not run the routine: \(error.localizedDescription)")
            return nil
        }
    }

    private func runRoutineOperation(
        routine: LearnedRoutine,
        parameters: [String: String],
        attemptID: UUID,
        worker: CuaWorkerHandle
    ) async throws -> DoOutcome? {
        guard taskStartIsCurrent(attemptID) else { return nil }
        let workspace = try Self.makeTaskWorkspace()
        try await worker.claimResources([.workspace(workspace.standardizedFileURL.path)])
        let captured = await probe.captureScreenContext(worker: worker)
        guard taskStartIsCurrent(attemptID) else { return nil }
        guard EnvironmentProbe.captureIsUsable(captured.context) else {
            hooks.setStatus("Cua could not capture the target window, so Perry stopped before replaying.")
            voice.speak("Cua could not capture the target window, so Perry stopped before replaying.")
            return nil
        }
        // Fresh observation of the routine's own app window; the plan binds
        // to whatever that window is right now.
        let targetStore = CuaGuideTargetStore()
        await targetStore.set(CuaTargetHint(bundleID: routine.bundleID, processID: nil, windowTitle: nil))
        let observation = try await CuaGuideTreeReader(worker: worker, targetStore: targetStore).observe()
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
        return try await executePreparedPlan(
            plan: plan,
            goal: routine.name,
            attemptID: attemptID,
            captured: captured,
            targetWindow: targetWindow,
            worker: worker,
            workspace: workspace,
            sandboxLabel: "learned routine “\(routine.name)”",
            initialWarnings: []
        )
    }

    private func runForegroundOperation(
        goal: String,
        attemptID: UUID,
        preferredRuntimeID: String?,
        worker: CuaWorkerHandle,
        threadID: UUID? = nil,
        targetHint: CuaTargetHint? = nil
    ) async throws -> DoOutcome? {
        guard taskStartIsCurrent(attemptID) else { return nil }
        let workspace = try Self.makeTaskWorkspace()
        try await worker.claimResources([.workspace(workspace.standardizedFileURL.path)])
        let captured = await probe.captureScreenContext(worker: worker, targetHint: targetHint)
        guard taskStartIsCurrent(attemptID) else { return nil }
        guard EnvironmentProbe.captureIsUsable(captured.context) else {
            hooks.setStatus("Cua could not capture the target window, so Perry stopped before planning.")
            voice.speak("Cua could not capture the target window, so Perry stopped before planning.")
            return nil
        }
        let targetWindow = captured.target.map {
            WindowContext(
                appBundleID: $0.bundleID,
                title: $0.title.isEmpty ? "Frontmost window" : $0.title
            )
        } ?? probe.targetWindow(for: captured.context)
        if let coordinator = agentCoordinator {
            // Open-ended Do runs the agent loop: the model observes and acts
            // through the tool host itself (intent cards per call) instead of
            // committing to a typed plan up front. preferredRuntimeID is
            // folded into the brain's deep route, not the runtime catalog.
            return try await executeAgentRun(
                goal: goal,
                attemptID: attemptID,
                targetWindow: targetWindow,
                target: captured.target?.hint ?? targetHint,
                conversationID: threadID,
                worker: worker,
                workspace: workspace,
                coordinator: coordinator
            )
        }
        // Legacy path: typed plan → supervisor. Kept for callers that
        // construct the controller without an agent coordinator (DEBUG test
        // harnesses); the plan path is retired for product entry points.
        guard let runtimeSelection = await runtimes.select(
            workingDirectory: workspace,
            preferredProviderID: RuntimeCatalog.providerID(from: preferredRuntimeID),
            goal: goal,
            attemptID: attemptID,
            attemptIsCurrent: { [weak self] id in self?.taskStartIsCurrent(id) ?? false }
        ) else {
            guard taskStartIsCurrent(attemptID) else { return nil }
            hooks.setStatus("No authenticated, healthy, bounded runtime is available.")
            voice.speak("No authenticated, healthy, bounded runtime is available.")
            return nil
        }
        guard taskStartIsCurrent(attemptID) else { return nil }
        let taskUUID = UUID()
        let taskID = TaskID(taskUUID.uuidString)
        let request = try PlanningRequest(
            goal: goal,
            taskID: taskID,
            workspace: workspace,
            context: .screen(captured.context)
        )
        let plan = try await runtimeSelection.provider.plan(request)
        return try await executePreparedPlan(
            plan: plan,
            goal: goal,
            attemptID: attemptID,
            captured: captured,
            targetWindow: targetWindow,
            worker: worker,
            workspace: workspace,
            sandboxLabel: runtimes.name(for: runtimeSelection.providerID.rawValue),
            initialWarnings: runtimeSelection.explanation.fallbackReason.map { [$0] } ?? []
        )
    }

    /// Agent-loop execution of an open-ended Do goal: session + strip come
    /// up the same way as a typed run, then `AgentCoordinator` streams the
    /// turn while this translates events into session evidence and status.
    private func executeAgentRun(
        goal: String,
        attemptID: UUID,
        targetWindow: WindowContext?,
        target: CuaTargetHint?,
        conversationID: UUID?,
        worker: CuaWorkerHandle,
        workspace: URL,
        coordinator: AgentCoordinator
    ) async throws -> DoOutcome? {
        let taskUUID = UUID()
        let execution = ExecutionSessionState(
            taskID: taskUUID,
            goal: goal,
            startedAt: Date(),
            appBundleID: targetWindow?.appBundleID,
            providerRoute: "agent-loop",
            workspace: workspace,
            lifecycle: .starting,
            initialWarnings: []
        )
        guard beginInvokingIfNeeded(attemptID: attemptID), transitionSession({ try sessionController.startExecution(execution, attemptID: attemptID) }) else {
            return nil
        }
        hooks.setTranscriptPreview(goal)
        activityStripWindow?.setExpanded(false, animate: false)
        hooks.stopSpatialMonitoring()
        hooks.stopGuideObservation()
        hooks.hidePanel()
        SoundPlayer.play(.send)
        overlayState.buddyState = .acting
        overlayState.agentTaskBubbleText = "Working on \(goal)…"
        showActivityStrip()
        guard transitionSession({ try sessionController.setExecutionPhase(.running) }) else { return nil }
        hooks.setStatus("Perry is working.")

        let threadID = conversationID ?? UUID()
        activeAgentThreadID = threadID
        let runID = UUID()
        workerLease?.set(worker, for: runID)
        defer {
            activeAgentThreadID = nil
            workerLease?.set(nil, for: runID)
        }

        var answer = ""
        var stepIndex = 0
        var terminal: AgentFinish?
        for await event in coordinator.run(threadID: threadID, goal: goal, runID: runID, target: target) {
            guard case .executing(let current) = sessionController.state,
                  current.taskID == taskUUID, !current.isFinalized else {
                coordinator.stop(threadID: threadID)
                return .blocked(reason: "the execution session changed")
            }
            if Task.isCancelled {
                coordinator.stop(threadID: threadID)
                terminal = .interrupted
                break
            }
            switch event {
            case .textDelta(let delta):
                answer += delta
                hooks.setTranscriptPreview(answer)
            case .toolCallStarted(let call):
                let summary = Self.toolStepSummary(call)
                _ = transitionSession {
                    try sessionController.recordExecutionStep(
                        id: call.id,
                        summary: summary,
                        tier: coordinator.toolTier(named: call.name) ?? .yellow,
                        reversible: false,
                        index: stepIndex
                    )
                }
                stepIndex += 1
                overlayState.agentTaskBubbleText = summary
                hooks.setStatus(summary)
            case .toolCallFinished(let result):
                if let first = result.content.compactMap({ part -> String? in
                    if case .text(let text) = part { return text.components(separatedBy: .newlines).first }
                    return nil
                }).first {
                    hooks.setStatus(first)
                }
            case .note(let note):
                hooks.setStatus(note)
            case .draw:
                break
            case .finished(let finish):
                terminal = finish
            }
        }
        if terminal == nil || Task.isCancelled {
            coordinator.stop(threadID: threadID)
            terminal = .interrupted
        }
        guard case .executing(let current) = sessionController.state,
              current.taskID == taskUUID, !current.isFinalized else {
            return .blocked(reason: "the execution session changed")
        }
        return await finalizeTask(with: Self.doOutcome(terminal ?? .interrupted, stepsRun: stepIndex))
    }

    /// One-line strip/status text for a tool call — name plus the most
    /// identifying argument, never raw values (a typed string may carry
    /// secrets).
    private static func toolStepSummary(_ call: ToolCall) -> String {
        let label = call.arguments["label"]?.stringValue
            ?? call.arguments["path"]?.stringValue
            ?? call.arguments["bundleID"]?.stringValue
            ?? call.arguments["elementID"]?.stringValue
        return label.map { "\(call.name) \($0)" } ?? call.name
    }

    private static func doOutcome(_ finish: AgentFinish, stepsRun: Int) -> DoOutcome {
        switch finish {
        case .completed: return .completed(stepsRun: stepsRun)
        case .interrupted: return .blocked(reason: "stopped by the user")
        case .paused: return .blocked(reason: "paused")
        case .budgetToolCalls: return .blocked(reason: "reached the 60-action limit")
        case .budgetTime: return .blocked(reason: "reached the 20-minute limit")
        case .providerError(let message), .failed(let message): return .failed(stepSummary: "the model", reason: message)
        }
    }

    private func showActivityStrip() {
        activityStripWindow = activityStripWindow ?? AgentActivityStripWindow(
            state: activityStripState,
            onPause: { [weak self] in self?.pause() },
            onResume: { [weak self] in self?.resume() },
            onStop: { [weak self] in self?.cancel() },
            onRetry: { [weak self] in self?.retry() },
            onSteer: { [weak self] instruction in self?.steer(instruction) },
            onTakeOver: { [weak self] in self?.takeOver() }
        )
        activityStripWindow?.show(on: NSScreen.main)
    }

    /// The post-plan half of every foreground task: publication gate,
    /// resource claims, session start, activity strip, supervisor. Shared by
    /// the planner path and by routine replay, which arrives with its typed
    /// plan already built from a fresh observation.
    private func executePreparedPlan(
        plan: ExecutionPlan,
        goal: String,
        attemptID: UUID,
        captured: (context: ScreenContext, target: CuaWindowTarget?),
        targetWindow: WindowContext?,
        worker: CuaWorkerHandle,
        workspace: URL,
        sandboxLabel: String,
        initialWarnings: [String]
    ) async throws -> DoOutcome? {
        // The execution session keeps the plan's own task ID so history,
        // grants, and transcripts describe one task end to end.
        let taskUUID = UUID(uuidString: plan.taskID.rawValue) ?? UUID()
        // Publication gate: nothing reaches the supervisor unless every action
        // is supported by this executor surface, bound to this workspace, and
        // inside timeout bounds.
        try ExecutionPlanValidator.validate(
            plan,
            capabilities: ExecutionPlanValidator.Capabilities(
                supportedOperations: Set(ExecutableAction.Operation.Kind.allCases),
                workspace: workspace,
                integrationAccounts: remoteIntegrationExecutor.executableAccountIDs
            )
        )
        guard taskStartIsCurrent(attemptID) else { return nil }
        try await worker.claimResources(typedTaskResources(plan: plan, workspaceURL: workspace))
        guard taskStartIsCurrent(attemptID) else { return nil }
        let execution = ExecutionSessionState(
            taskID: taskUUID,
            goal: goal,
            startedAt: Date(),
            appBundleID: targetWindow?.appBundleID,
            providerRoute: sandboxLabel,
            workspace: workspace,
            lifecycle: .starting,
            initialWarnings: initialWarnings
        )
        guard beginInvokingIfNeeded(attemptID: attemptID), transitionSession({ try sessionController.startExecution(execution, attemptID: attemptID) }) else {
            return nil
        }
        hooks.setStatus("Perry is preparing a safe sandbox with \(sandboxLabel).")
        hooks.setTranscriptPreview(goal)
        activityStripWindow?.setExpanded(false, animate: false)
        hooks.stopSpatialMonitoring()
        hooks.stopGuideObservation()
        hooks.hidePanel()
        SoundPlayer.play(.send)
        overlayState.buddyState = .acting
        overlayState.agentTaskBubbleText = "Preparing \(goal)…"
        showActivityStrip()
#if DEBUG
        let confirmer = debugConfirmer ?? makeConfirmer()
        let typedVerifier = debugTypedVerifier ?? CompositeActionVerifier(workspace: workspace, worker: worker)
#else
        let confirmer = makeConfirmer()
        let typedVerifier: any TypedActionVerifier = CompositeActionVerifier(workspace: workspace, worker: worker)
#endif
        let supervisor = DoSupervisor(
            activityLog: activityLog,
            confirmer: confirmer,
            typedVerifier: typedVerifier,
            cancelWindow: 5,
            onEvent: { [weak self] event in
                await self?.handleDoEvent(event, taskID: execution.taskID)
            },
            onTypedEvent: { [weak self] event in
                await self?.handleTypedDoEvent(event, taskID: execution.taskID)
            }
        )
        activeSupervisor = supervisor
        var context = RehearsalContext(plan: plan, target: captured.target, markIDs: [])
        let painted = await paintRehearsalMarks(context: context)
        context.markIDs = painted.overlayIDs
        rehearsalContext = context
        // Mask summaries for actions targeting non-ordinary elements so typed
        // secrets never reach the card, activity strip, receipts, or history.
        let executionPlan = (try? plan.maskingSensitiveSummaries(painted.sensitiveActionIDs)) ?? plan
        // Workspace transforms journal write-ahead through the shared durable
        // record — a foreground run lands receipts Undo can reach. The journal
        // binds the masked plan so its evidence never carries sensitive text.
        let runJournal = try executionPlan.workspaceEffectsPlan().flatMap { effectsPlan -> WorkspaceRunJournal? in
            guard let coordinator = workspaceCoordinator else { return nil }
            return WorkspaceRunJournal(plan: effectsPlan, workspace: workspace, coordinator: coordinator)
        }
        let typedExecutor = typedActionRouter(worker: worker, workspace: workspace, journal: runJournal)
        let outcome = await supervisor.run(
            plan: executionPlan,
            context: captured.context,
            targetWindow: targetWindow,
            typedExecutor: typedExecutor
        )
        clearRehearsalMarks()
        await runJournal?.settle()
        return await finalizeTask(with: outcome)
    }

    /// Spatial rehearsal: number the targets the plan will actually touch, resolved
    /// against a fresh observation. Only selectors that resolve right now produce
    /// marks — ungrounded steps stay text-only in the rehearsal card.
    private func paintRehearsalMarks(
        context: RehearsalContext
    ) async -> (overlayIDs: Set<UUID>, sensitiveActionIDs: Set<ActionID>) {
        let plan = context.plan
        let targetStore = CuaGuideTargetStore()
        if let target = context.target {
            await targetStore.set(CuaTargetHint(
                bundleID: target.bundleID,
                processID: target.processID,
                windowID: target.windowID,
                windowTitle: target.title
            ))
        }
        // Observe on a guide-scope worker: a failed rehearsal read retires
        // that worker instead of cancelling the foreground operation that
        // borrowed it.
        let elements: [AXElement]
        do {
            elements = try await workers.withWorker(scope: .guide, resources: []) { worker in
                try await CuaGuideTreeReader(worker: worker, targetStore: targetStore).observe().snapshot.elements
            }
        } catch {
            return ([], [])
        }
        let marks = RehearsalMarks.marks(for: plan, elements: elements)
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        // Ghost pointer path: a faint line through the targets in step order,
        // so the preview shows sequence, not just endpoints.
        let centers = marks.map { mark -> CGPoint in
            let rect = AXCoordinateConverter.appKitRect(
                axX: mark.frame.x, axY: mark.frame.y,
                width: mark.frame.width, height: mark.frame.height,
                primaryScreenMaxY: primaryMaxY
            )
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        var ids = Set<UUID>()
        if centers.count >= 2 {
            let path = PerryGuidanceOverlay.scribble(
                points: centers,
                accentHex: "#F59E0B",
                lineWidth: 2,
                duration: 60
            )
            ids.insert(path.id)
            overlayState.visualGuidanceOverlays.append(path)
        }
        for mark in marks {
            let rect = AXCoordinateConverter.appKitRect(
                axX: mark.frame.x,
                axY: mark.frame.y,
                width: mark.frame.width,
                height: mark.frame.height,
                primaryScreenMaxY: primaryMaxY
            )
            let overlay = PerryGuidanceOverlay.rectangle(
                rect: rect,
                accentHex: "#F59E0B",
                lineWidth: 3,
                fillOpacity: 0.08,
                caption: "\(mark.stepNumber). \(mark.caption)",
                duration: 60
            )
            ids.insert(overlay.id)
            overlayState.visualGuidanceOverlays.append(overlay)
        }
        return (ids, Set(marks.filter(\.sensitive).map(\.actionID)))
    }

    private func clearRehearsalMarks() {
        guard let context = rehearsalContext else { return }
        overlayState.visualGuidanceOverlays.removeAll { context.markIDs.contains($0.id) }
        rehearsalContext = nil
    }

    /// A replayed preview re-observes and repaints the marks — the review never
    /// rests on where targets were last time.
    private func repaintRehearsalMarks() {
        guard var context = rehearsalContext else { return }
        overlayState.visualGuidanceOverlays.removeAll { context.markIDs.contains($0.id) }
        Task {
            let painted = await paintRehearsalMarks(context: context)
            guard var current = rehearsalContext, current.plan.planID == context.plan.planID else { return }
            current.markIDs = painted.overlayIDs
            rehearsalContext = current
        }
    }

    private func makeConfirmer() -> any Confirmer {
        hooks.makeConfirmer()
    }

    private func typedActionRouter(worker: CuaWorkerHandle, workspace: URL, journal: WorkspaceRunJournal?) -> TypedActionRouter {
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
                    throw ExecutionError(message: "no sandboxed coding runtime named \(runtimeID) is configured")
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
            }
        )
    }

    @MainActor
    private static func presentAskUser(prompt: String, choices: [String]) throws {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.alertStyle = .informational
        for choice in choices.prefix(3) {
            alert.addButton(withTitle: choice)
        }
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard (0..<choices.prefix(3).count).contains(response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) else {
            throw CancellationError()
        }
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

    private static func makeTaskWorkspace() throws -> URL {
        let directory = WorkspaceScope.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: Demo

    func runForDemo(goal: String) async -> DoOutcome? {
        guard !supervisorActive, !startIsInFlight else { return nil }
        let attemptID = sessionController.currentOrFreshAttemptID
        guard beginInvokingIfNeeded(attemptID: attemptID) else { return nil }
        defer { cancelInvocationIfCurrent(attemptID) }
        guard let outcome = await begin(goal: goal, attemptID: attemptID) else { return nil }
        let transcript = await transcriptStore.snapshot().first { $0.request == goal }
        guard case .completed = outcome,
              transcript?.verified == true else {
            return .failed(
                stepSummary: "demo verification",
                reason: "The task did not produce independent verification for every side effect."
            )
        }
        return outcome
    }

    // MARK: Controls

    func pause() {
        if let threadID = activeAgentThreadID {
            guard transitionSession({ try sessionController.setExecutionPhase(.paused) }) else { return }
            hooks.setStatus("Pausing before the next step.")
            agentCoordinator?.pause(threadID: threadID)
            return
        }
        guard let activeSupervisor else { return }
        guard transitionSession({ try sessionController.setExecutionPhase(.paused) }) else { return }
        hooks.setStatus("Pausing before the next step.")
        Task { await activeSupervisor.pause() }
    }

    func resume() {
        if handoffToHuman {
            continueFromHuman()
            return
        }
        if let threadID = activeAgentThreadID {
            guard transitionSession({ try sessionController.setExecutionPhase(.running) }) else { return }
            hooks.setStatus("Resuming the task.")
            agentCoordinator?.resume(threadID: threadID)
            return
        }
        guard let activeSupervisor else { return }
        guard transitionSession({ try sessionController.setExecutionPhase(.running) }) else { return }
        hooks.setStatus("Resuming the task.")
        Task { await activeSupervisor.resume() }
    }

    /// "I'll do this step": settle at the next boundary, hand control to the
    /// user, and remember the goal so Continue can replan rather than resume
    /// a plan that expected to perform the step itself.
    func takeOver() {
        guard supervisorActive, !handoffToHuman else { return }
        guard transitionSession({ try sessionController.setExecutionPhase(.paused) }) else { return }
        if case .executing(let execution) = sessionController.state {
            handoffGoal = execution.goal
        }
        handoffToHuman = true
        activityStripState.handedToHuman = true
        hooks.setStatus("You're in control — do the step yourself, then Continue with Perry.")
        voice.speak("You're in control. Choose Continue with Perry when you're done.")
        if let threadID = activeAgentThreadID {
            agentCoordinator?.pause(threadID: threadID)
        } else {
            Task { await activeSupervisor?.pause() }
        }
    }

    /// After a human takeover, Continue resumes the run. On the agent path
    /// the loop keeps its history — a steer tells the model the user did the
    /// step, and it re-observes. On the typed-plan path the stale plan is
    /// cancelled and the same goal replans against the current screen.
    private func continueFromHuman() {
        guard handoffToHuman, let goal = handoffGoal else { return }
        if let threadID = activeAgentThreadID {
            handoffToHuman = false
            handoffGoal = nil
            activityStripState.handedToHuman = false
            guard transitionSession({ try sessionController.setExecutionPhase(.running) }) else { return }
            hooks.setStatus("Continuing — Perry will check what you did.")
            agentCoordinator?.resume(threadID: threadID)
            agentCoordinator?.steer(
                "The user took over and did the current step themselves. Verify the result on screen, then continue the goal.",
                threadID: threadID
            )
            return
        }
        guard let activeSupervisor else { return }
        handoffToHuman = false
        handoffGoal = nil
        activityStripState.handedToHuman = false
        hooks.setStatus("Replanning the remaining work from the current screen.")
        Task { @MainActor [weak self] in
            guard let self else { return }
            await activeSupervisor.cancel()
            for _ in 0..<100 where self.activeSupervisor != nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard self.activeSupervisor == nil else {
                hooks.setStatus("Perry is still settling the paused task — try Continue again in a moment.")
                return
            }
            self.start(goal: goal)
        }
    }

    func cancel() {
        if let threadID = activeAgentThreadID {
            guard sessionController.requestStop() == .stopExecution else { return }
            hooks.setStatus("Stopping safely…")
            hooks.dismissIntentCard()
            agentCoordinator?.stop(threadID: threadID)
            return
        }
        guard let activeSupervisor else { return }
        guard sessionController.requestStop() == .stopExecution else { return }
        hooks.setStatus("Stopping safely…")
        hooks.dismissIntentCard()
        Task { await activeSupervisor.cancel() }
    }

    /// Cancels the live run without touching the intent card or status —
    /// used by dismiss, erasure, and worker-stop paths.
    func cancelActiveSupervisor() async {
        if let threadID = activeAgentThreadID {
            agentCoordinator?.stop(threadID: threadID)
        }
        await activeSupervisor?.cancel()
    }

    /// On the agent path a steer lands at the next loop boundary as a user
    /// message — no replan needed, the model keeps its history. On the
    /// typed-plan path steering settles the current plan then replans the
    /// goal plus the instruction against a fresh observation — the new
    /// segment earns its own rehearsal instead of pretending the first
    /// preview predicted it.
    func steer(_ instruction: String) {
        guard !handoffToHuman else { return }
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard case .executing(let execution) = sessionController.state,
              execution.lifecycle == .running || execution.lifecycle == .paused else { return }
        if let threadID = activeAgentThreadID {
            hooks.setStatus("Steering: \(trimmed)")
            agentCoordinator?.steer(trimmed, threadID: threadID)
            return
        }
        guard let activeSupervisor else { return }
        Task { await activeSupervisor.steer(trimmed) }
        guard transitionSession({ try sessionController.setExecutionPhase(.paused) }) else { return }
        handoffGoal = "\(execution.goal) — user steered: \(trimmed)"
        handoffToHuman = true
        hooks.setStatus("Replanning with your instruction…")
        Task { @MainActor [weak self] in
            await activeSupervisor.pause()
            self?.continueFromHuman()
        }
    }

    func retry() {
        guard !supervisorActive, !startIsInFlight else {
            voice.speak("I’m still working on the current task.")
            return
        }
        guard case .failed = sessionController.state else {
            voice.speak("There isn’t a finished task to retry yet.")
            return
        }
        let attemptID = UUID()
        var goal: String?
        guard transitionSession({ goal = try sessionController.retry(attemptID: attemptID) }),
              let goal else { return }
        foregroundActivityGeneration = UUID()
        start(goal: goal, attemptID: attemptID, threadID: nil, targetHint: nil)
    }

    // MARK: Shutdown

    func cancelStartTask() {
        doStartTask?.cancel()
        doStartTask = nil
    }

    func joinStartTask() async {
        await doStartTask?.value
    }

    // MARK: Supervisor events

    private func handleDoEvent(_ event: DoEvent, taskID: UUID) {
        guard case .executing(let execution) = sessionController.state,
              execution.taskID == taskID,
              !execution.isFinalized else { return }
        switch event {
        case .starting:
            guard execution.lifecycle == .starting else { return }
        case .planned(let steps):
            guard transitionSession({ try sessionController.setPlannedStepCount(steps) }) else { return }
        case .started:
            guard transitionSession({ try sessionController.setExecutionPhase(.running) }) else { return }
            hooks.setStatus("Perry is working in a private sandbox.")
        case .paused:
            guard transitionSession({ try sessionController.setExecutionPhase(.paused) }) else { return }
            hooks.setStatus("Paused before the next step.")
        case .resumed:
            guard transitionSession({ try sessionController.setExecutionPhase(.running) }) else { return }
        case .steered(let instruction):
            guard execution.lifecycle == .running || execution.lifecycle == .paused else { return }
            hooks.setStatus("Steering: \(instruction)")
        case .confirmationRequested(let request):
            guard transitionSession({
                try sessionController.awaitApproval(
                    request.id,
                    actionSummary: request.actionSummary,
                    tier: request.tier
                )
            }) else { return }
            overlayState.buddyState = .awaitingApproval
            hooks.setStatus("Perry is waiting for your approval.")
            if rehearsalContext != nil {
                if rehearsalContext!.seenPlanRequest {
                    repaintRehearsalMarks()
                } else {
                    rehearsalContext!.seenPlanRequest = true
                }
            }
        case .confirmationAccepted(let approvalID):
            guard transitionSession({ try sessionController.acceptApproval(approvalID) }) else { return }
            overlayState.buddyState = .acting
            hooks.setStatus("Continuing the approved task.")
        case .completed:
            guard transitionSession({ try sessionController.setExecutionPhase(.verifying) }) else { return }
        case .stopped(let reason):
            guard transitionSession({ try sessionController.setExecutionPhase(.stopping) }) else { return }
            hooks.setStatus(reason)
        case .failed(let stepSummary, _):
            guard transitionSession({ try sessionController.setExecutionPhase(.stopping) }) else { return }
            hooks.setStatus("I stopped at \(stepSummary).")
        }
    }

    private func handleTypedDoEvent(_ event: TypedDoEvent, taskID: UUID) {
        guard case .executing(let execution) = sessionController.state,
              execution.taskID == taskID,
              !execution.isFinalized else { return }
        switch event {
        case .actionStarted(let index, let action, let tier):
            clearRehearsalMarks()
            guard transitionSession({
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
                guard transitionSession({
                    try sessionController.recordVerification(
                        stepID: action.id.rawValue,
                        verified: true,
                        evidence: evidence
                    )
                }) else { return }
            case .unverified(let reason):
                guard transitionSession({
                    try sessionController.recordVerification(
                        stepID: action.id.rawValue,
                        verified: false,
                        warning: "\(action.summary): \(reason)"
                    )
                }) else { return }
            case .notRequired:
                guard transitionSession({
                    try sessionController.recordVerificationNote(
                        stepID: action.id.rawValue,
                        note: "No read-back required"
                    )
                }) else { return }
            }
        }
    }

    private func finalizeTask(with reportedOutcome: DoOutcome) async -> DoOutcome {
        guard case .executing = sessionController.state else { return reportedOutcome }
        let execution: ExecutionSessionState
        let outcome: DoOutcome
        do {
            (execution, outcome) = try sessionController.beginFinalization(outcome: reportedOutcome)
        } catch {
            return .failed(stepSummary: "finalization", reason: "the session no longer accepts finalization")
        }
        let taskID = execution.taskID
#if DEBUG
        if let debugFinalizationBarrier {
            await debugFinalizationBarrier()
        }
#endif
        let committedExecution: ExecutionSessionState
        let finalizationOutcome: DoOutcome
        do {
            (committedExecution, finalizationOutcome) = try sessionController.commitFinalization(
                taskID: execution.taskID,
                outcome: outcome
            )
        } catch {
            return outcome
        }
        let finalization = await executionFinalizer.finalize(
            execution: committedExecution,
            outcome: finalizationOutcome
        )
        guard case .executing(let currentExecution) = sessionController.state,
              currentExecution.taskID == execution.taskID,
              currentExecution.finalizationOutcome == finalizationOutcome else {
            return finalizationOutcome
        }
        let terminalOutcome = finalizationOutcome
        let completion = finalization.completion
        let summary: String
        if finalization.issues.contains(.transcriptPersistence) {
            summary = "\(completion.summary) Perry could not save this task to history."
        } else if finalization.issues.contains(.memoryPersistence) {
            summary = "\(completion.summary) Perry could not update local memory."
        } else {
            summary = completion.summary
        }
        overlayState.agentTaskBubbleText = summary
        overlayState.buddyState = completion.outcome == .failed || !finalization.historySaved ? .blocked : .success
        hooks.setStatus(summary)
        if completion.outcome == .failed || !finalization.historySaved {
            _ = transitionSession {
                try sessionController.fail(
                    SessionFailure(taskID: execution.taskID, goal: execution.goal, message: summary)
                )
            }
        } else {
            let reportOutcome: ReportOutcome = if case .blocked = terminalOutcome { .stopped } else { .completed }
            _ = transitionSession {
                try sessionController.report(summary: summary, outcome: reportOutcome)
            }
        }
        voice.deliverVoiceReply(summary)
        activeSupervisor = nil
        activeAgentThreadID = nil
        handoffToHuman = false
        handoffGoal = nil
        activityStripState.handedToHuman = false
        voice.refreshWakeWordListener()
        let generation = foregroundActivityGeneration
        scheduleActivityRetirement(taskID: taskID, generation: generation, after: 8)
        return terminalOutcome
    }

    private func scheduleActivityRetirement(taskID: UUID, generation: UUID, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.foregroundActivityGeneration == generation else { return }
            switch self.sessionController.state {
            case .reporting(let report) where report.taskID == taskID:
                break
            case .failed(let failure) where failure.taskID == taskID:
                break
            default:
                return
            }
            self.activityStripWindow?.setExpanded(false, animate: false)
            self.activityStripWindow?.orderOut(nil)
            _ = self.transitionSession { try self.sessionController.completeDismissal() }
        }
    }

#if DEBUG
    var debugActivityState: AgentActivityStripState { activityStripState }

    var debugForegroundActivityGeneration: UUID {
        foregroundActivityGeneration
    }

    func debugScheduleActivityRetirement(taskID: UUID, generation: UUID, after delay: TimeInterval) {
        scheduleActivityRetirement(taskID: taskID, generation: generation, after: delay)
    }

    func debugInvokeActivityStop() {
        activityStripWindow?.debugInvokeStop()
    }

    func debugRun(goal: String, preferredRuntimeID: String? = nil) async throws -> DoOutcome? {
        let attemptID = sessionController.currentOrFreshAttemptID
        guard beginInvokingIfNeeded(attemptID: attemptID) else { return nil }
        defer { cancelInvocationIfCurrent(attemptID) }
        return try await workers.withWorker(scope: .foreground, resources: []) { worker in
            try await self.runForegroundOperation(
                goal: goal,
                attemptID: attemptID,
                preferredRuntimeID: preferredRuntimeID,
                worker: worker
            )
        }
    }

    func debugShowActivityFixture() {
        let fixtureStart = Date()
        activityStripState.reset()
        activityStripState.phase = .working
        activityStripState.title = "UI test fixture"
        activityStripState.detail = "Long task fixture · running"
        activityStripState.progress = 0.42
        activityStripState.tier = .yellow
        activityStripState.startedAt = fixtureStart
        activityStripState.steps = [
            AgentActivityStep(
                id: "fixture-inspect",
                summary: "Inspect the active window and collect a bounded snapshot",
                tier: .green,
                reversible: true,
                timestamp: fixtureStart.addingTimeInterval(-18),
                verification: "Verified: fixture snapshot ready"
            ),
            AgentActivityStep(
                id: "fixture-plan",
                summary: "Plan the next safe action from the current task state",
                tier: .yellow,
                reversible: true,
                timestamp: fixtureStart.addingTimeInterval(-12),
                verification: nil
            ),
            AgentActivityStep(
                id: "fixture-prepare",
                summary: "Prepare the staged result for review",
                tier: .orange,
                reversible: true,
                timestamp: fixtureStart.addingTimeInterval(-6),
                verification: nil
            ),
            AgentActivityStep(
                id: "fixture-report",
                summary: "Report the verified result and keep the task visible",
                tier: .yellow,
                reversible: true,
                timestamp: fixtureStart,
                verification: nil
            )
        ]
        activityStripWindow = AgentActivityStripWindow(
            state: activityStripState,
            onPause: { [weak self] in
                guard let self, self.activityStripState.phase == .working else { return }
                self.activityStripState.phase = .paused
                self.activityStripState.detail = "Long task fixture · paused"
            },
            onResume: { [weak self] in
                guard let self, self.activityStripState.phase == .paused else { return }
                self.activityStripState.phase = .working
                self.activityStripState.detail = "Long task fixture · running"
            },
            onStop: { [weak self] in
                guard let self else { return }
                self.activityStripState.phase = .failed
                self.activityStripState.detail = "Stopped by the UI test fixture; retry is available"
                self.activityStripState.canRetry = true
            },
            onRetry: { [weak self] in
                guard let self, self.activityStripState.retryIsAvailable else { return }
                self.activityStripState.phase = .working
                self.activityStripState.detail = "Long task fixture · running after retry"
                self.activityStripState.progress = 0.42
                self.activityStripState.canRetry = false
            },
            onSteer: { [weak self] instruction in
                guard let self, self.activityStripState.steeringIsAvailable else { return }
                self.activityStripState.detail = "Steering: \(instruction)"
            }
        )
        activityStripWindow?.show(on: NSScreen.main)
    }
#endif
}

/// The user-authorized root for Perry file work. Defaults to `~/PerryDemo`;
/// a folder chosen through the status menu replaces it. Task workspaces are
/// always per-task subdirectories inside this root, so existing containment
/// checks and Undo bindings never see a path the user didn't authorize.
enum WorkspaceScope {
    static var root: URL {
        if let path = PerryPreferences.workspaceRoot, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("PerryDemo", isDirectory: true)
    }

    static func setRoot(_ url: URL) {
        PerryPreferences.workspaceRoot = url.standardizedFileURL.path
    }
}

/// Spatial rehearsal marks: resolve a typed plan's computer targets against a
/// fresh observation. Only `.accessibilityID` selectors that resolve right now
/// produce marks — raw pixel targets and ungrounded steps stay text-only in the
/// rehearsal card rather than inventing coordinates.
enum RehearsalMarks {
    struct Mark: Equatable {
        let stepNumber: Int
        let actionID: ActionID
        let caption: String
        let frame: AXElementFrame
        let sensitive: Bool
    }

    static func marks(for plan: ExecutionPlan, elements: [AXElement]) -> [Mark] {
        plan.actions.enumerated().compactMap { index, action in
            guard case .computer(_, let command) = action.operation,
                  let selector = primarySelector(of: command),
                  case .accessibilityID(let identifier) = selector,
                  let element = elements.first(where: { $0.stableID == identifier }) else {
                return nil
            }
            return Mark(
                stepNumber: index + 1,
                actionID: action.id,
                caption: action.summary,
                frame: element.frame,
                sensitive: element.sensitivity != .ordinary
            )
        }
    }

    private static func primarySelector(of command: ExecutableAction.ComputerCommand) -> ExecutableAction.Selector? {
        switch command {
        case .click(let selector), .rightClick(let selector), .doubleClick(let selector),
             .typeText(_, target: let selector), .drag(from: let selector, to: _, durationMilliseconds: _, steps: _):
            return selector
        case .scroll(_, _, _, let selector), .pressKey(_, _, let selector), .hotkey(_, _, let selector):
            return selector
        }
    }
}

extension ExecutionPlan {
    /// The transform-only projection of a plan — the journaled record's plan.
    /// Approval lifts to action scope because each journaled effect is
    /// individually approved through the write-ahead performer. The record
    /// keeps the run's task identity so its row and workspace line up with
    /// the task the user saw.
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

    /// Replace the human-facing summary of actions whose targets resolve to
    /// non-ordinary-sensitivity elements, so typed secrets never reach the
    /// rehearsal card, activity strip, receipts, or history. The operation —
    /// and therefore what actually executes — is unchanged.
    func maskingSensitiveSummaries(_ actionIDs: Set<ActionID>) throws -> ExecutionPlan {
        guard !actionIDs.isEmpty else { return self }
        return try ExecutionPlan(
            schemaVersion: schemaVersion,
            planID: planID,
            taskID: taskID,
            goal: goal,
            actions: actions.map { action in
                guard actionIDs.contains(action.id) else { return action }
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
