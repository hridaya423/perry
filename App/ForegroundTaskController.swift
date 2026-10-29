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
        var routineVerified: (UUID) -> Void = { _ in }
        var guiTaskCompleted: () -> Void = {}
    }

    private let sessionController: SessionController
    private let workers: CuaWorkerService
    private let probe: EnvironmentProbe
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

    private lazy var routines = RoutineRunner(
        sessionController: sessionController,
        workers: workers,
        probe: probe,
        remoteIntegrationExecutor: remoteIntegrationExecutor,
        activityLog: activityLog,
        overlayState: overlayState,
        workspaceCoordinator: workspaceCoordinator,
        hooks: hooks,
        links: RoutineRunner.Links(
            isCurrent: { [weak self] in self?.taskStartIsCurrent($0) ?? false },
            transition: { [weak self] in self?.transitionSession($0) ?? false },
            beginExecution: { [weak self] execution, attemptID in
                guard let self else { return false }
                return self.beginInvokingIfNeeded(attemptID: attemptID)
                    && self.transitionSession({ try self.sessionController.startExecution(execution, attemptID: attemptID) })
            },
            showActivityStrip: { [weak self] in
                self?.activityStripWindow?.setExpanded(false, animate: false)
                self?.showActivityStrip()
            },
            speak: { [weak self] in self?.voice.speak($0) }
        )
    )

    private var activeSupervisor: DoSupervisor? { routines.activeSupervisor }
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
    private var doStartTask: Task<Void, Never>?
    private var foregroundActivityGeneration = UUID()
    private var observedForegroundTaskID: UUID?

    private let activityStripState = AgentActivityStripState()
    private var activityStripWindow: AgentActivityStripWindow?

#if DEBUG
    private var debugFinalizationBarrier: FinalizationBarrier?
#endif

    var supervisorActive: Bool { activeSupervisor != nil || activeAgentThreadID != nil }

    var startIsInFlight: Bool { doStartTask != nil }

    init(
        sessionController: SessionController,
        workers: CuaWorkerService,
        probe: EnvironmentProbe,
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
#endif
    }

#if DEBUG
    convenience init(
        sessionController: SessionController,
        workers: CuaWorkerService,
        probe: EnvironmentProbe,
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
        routines.debugConfirmer = confirmer
        routines.debugAskUser = askUser
        routines.debugTypedVerifier = typedVerifier
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
            hooks.setStatus("I stopped because something changed unexpectedly. Try again.")
            return false
        }
    }

    private func beginInvokingIfNeeded(attemptID: UUID = UUID()) -> Bool {
        switch sessionController.state {
        case .idle:
            return transitionSession { try sessionController.wake(attemptID: attemptID) }
        case .reporting, .failed:
            // A finished/stopped report never gates a new attempt — asking
            // again is the dismissal (same rule requestDismissal applies).
            guard transitionSession({ try sessionController.completeDismissal() }) else { return false }
            return transitionSession { try sessionController.wake(attemptID: attemptID) }
        case .invoking(let invocation):
            return invocation.id == attemptID
        default:
            return false
        }
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

    func start(goal: String, threadID: UUID? = nil, targetHint: CuaTargetHint? = nil) {
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
        start(goal: goal, attemptID: attemptID, threadID: threadID, targetHint: targetHint)
    }

    private func start(goal: String, attemptID: UUID, threadID: UUID?, targetHint: CuaTargetHint?) {
        doStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.cancelInvocationIfCurrent(attemptID)
                self.doStartTask = nil
            }
            _ = await self.begin(goal: goal, attemptID: attemptID, threadID: threadID, targetHint: targetHint)
        }
    }

    func begin(goal: String, attemptID: UUID, threadID: UUID? = nil, targetHint: CuaTargetHint? = nil) async -> DoOutcome? {
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
                    worker: worker, threadID: threadID, targetHint: targetHint
                )
            }
        } catch {
            guard !(error is CancellationError), taskStartIsCurrent(attemptID) else { return nil }
            hooks.setStatus("I couldn’t finish the task. Try again.")
            voice.speak("I couldn’t finish the task. Try again.")
            return nil
        }
    }

    /// Permission and driver-health gates every foreground flow shares —
    /// goal planning, routine replay, anything that will touch the screen.
    private func preflight(attemptID: UUID) async -> Bool {
        PerfMark.mark("task.preflight.begin")
        defer { PerfMark.mark("task.preflight.end") }
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
                switch try await self.routines.run(routine, parameters: parameters, attemptID: attemptID, worker: worker) {
                case .notStarted: return nil
                case .finished(let outcome, let headline):
                    if case .completed = outcome { self.hooks.routineVerified(routine.id) }
                    return await self.finalizeTask(with: outcome, headline: headline)
                }
            }
        } catch {
            guard !(error is CancellationError), taskStartIsCurrent(attemptID) else { return nil }
            let message: String
            if let replay = error as? RoutineReplayError, let step = RoutineRunCopy.step(of: replay) {
                message = RoutineRunCopy.stopped(routine: routine, step: step, error: replay, reason: replay.localizedDescription)
            } else {
                message = "I couldn’t run the routine. Try again."
            }
            hooks.setStatus(message)
            voice.speak(message)
            return nil
        }
    }

    private func runForegroundOperation(
        goal: String,
        attemptID: UUID,
        worker: CuaWorkerHandle,
        threadID: UUID? = nil,
        targetHint: CuaTargetHint? = nil
    ) async throws -> DoOutcome? {
        guard taskStartIsCurrent(attemptID) else { return nil }
        let workspace = try WorkspaceScope.makeTaskDirectory()
        try await worker.claimResources([.workspace(workspace.standardizedFileURL.path)])
        let captured = await probe.resolveTaskWindow(worker: worker, targetHint: targetHint)
        guard taskStartIsCurrent(attemptID) else { return nil }
        guard EnvironmentProbe.captureIsUsable(captured.context) else {
            hooks.setStatus("I couldn’t capture that window, so I stopped before planning.")
            voice.speak("I couldn’t capture that window, so I stopped before planning.")
            return nil
        }
        let targetWindow = captured.target.map {
            WindowContext(
                appBundleID: $0.bundleID,
                title: $0.title.isEmpty ? "Frontmost window" : $0.title
            )
        } ?? probe.targetWindow(for: captured.context)
        // Open-ended Do runs the agent loop: the model observes and acts
        // through the tool host itself (intent cards per call) instead of
        // committing to a typed plan up front.
        guard let coordinator = agentCoordinator else {
            hooks.setStatus("I can’t run tasks right now. Restart Perry.")
            voice.speak("I can’t run tasks right now. Restart Perry.")
            return nil
        }
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
        hooks.setStatus("Working…")

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
        var actionCalls: [String: String] = [:]
        var actionsDone = 0
        var lastActionFailure: String?
        var usedGUI = false
        var terminal: AgentFinish?
        for await event in coordinator.run(threadID: threadID, goal: goal, runID: runID, target: target, task: true) {
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
                usedGUI = usedGUI || Self.isGUITool(call.name)
                let summary = Self.toolStepSummary(call)
                overlayState.agentTaskBubbleText = summary
                hooks.setStatus(summary)
                guard !coordinator.toolIsReadOnly(named: call.name) else { break }
                actionCalls[call.id] = summary
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
            case .toolCallFinished(let result):
                let first = result.content.compactMap({ part -> String? in
                    if case .text(let text) = part { return text.components(separatedBy: .newlines).first }
                    return nil
                }).first
                if let first { hooks.setStatus(first) }
                if let summary = actionCalls[result.callID] {
                    if result.isError {
                        lastActionFailure = "\(summary) failed" + (first.map { ": \($0)" } ?? "")
                    } else {
                        actionsDone += 1
                        lastActionFailure = nil
                    }
                }
            case .note(let note):
                hooks.setStatus(note)
            case .draw(let command):
                overlayState.apply(command)
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
        let outcome = await finalizeTask(
            with: Self.doOutcome(terminal ?? .interrupted, stepsRun: actionsDone),
            headline: terminal == .completed ? Self.doHeadline(actionsDone: actionsDone, lastActionFailure: lastActionFailure, answer: answer) : nil
        )
        if usedGUI, case .completed = outcome { hooks.guiTaskCompleted() }
        return outcome
    }

    static func isGUITool(_ name: String) -> Bool {
        name.hasPrefix("ui.")
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

    /// "Done. I ran N steps" is only said when N actions went through and
    /// the last one did not fail.
    static func doHeadline(actionsDone: Int, lastActionFailure: String?, answer: String) -> String? {
        if let lastActionFailure { return "I finished, but my last action failed: \(lastActionFailure)." }
        guard actionsDone == 0 else { return nil }
        let reply = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return reply.isEmpty ? "I didn’t change anything." : String(reply.prefix(240))
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
        activityStripWindow?.show()
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
        hooks.setStatus("You’re in control. Do the step yourself, then choose Resume.")
        voice.speak("You’re in control. Choose Resume when you’re done.")
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
            hooks.setStatus("Continuing. I’ll check what you did.")
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
        hooks.setStatus("Planning the rest from the current screen.")
        Task { @MainActor [weak self] in
            guard let self else { return }
            await activeSupervisor.cancel()
            for _ in 0..<100 where self.activeSupervisor != nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard self.activeSupervisor == nil else {
                hooks.setStatus("I’m still stopping the paused task. Try Resume again in a moment.")
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

    private func finalizeTask(with reportedOutcome: DoOutcome, headline: String? = nil) async -> DoOutcome {
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
            outcome: finalizationOutcome,
            headline: headline
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
            summary = "\(completion.summary) I couldn’t save this task to History."
        } else if finalization.issues.contains(.memoryPersistence) {
            summary = "\(completion.summary) I couldn’t update my notes."
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
        routines.activeSupervisor = nil
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

    func debugRun(goal: String) async throws -> DoOutcome? {
        let attemptID = sessionController.currentOrFreshAttemptID
        guard beginInvokingIfNeeded(attemptID: attemptID) else { return nil }
        defer { cancelInvocationIfCurrent(attemptID) }
        return try await workers.withWorker(scope: .foreground, resources: []) { worker in
            try await self.runForegroundOperation(
                goal: goal,
                attemptID: attemptID,
                worker: worker
            )
        }
    }

    func debugShowActivityFixture() {
        let fixtureStart = Date()
        activityStripState.reset()
        activityStripState.isExpanded = true
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
                verification: "Checked: fixture snapshot ready"
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
        activityStripWindow?.show()
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

    static func makeTaskDirectory() throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
