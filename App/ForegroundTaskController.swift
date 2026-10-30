import AppKit
import Foundation
import PerryBrain
import PerryCore
import PerryGuide
import PerryOverlay
import PerryRuntimes

typealias FinalizationBarrier = @MainActor () async -> Void

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

    let sessionController: SessionController
    let workers: CuaWorkerService
    let probe: EnvironmentProbe
    let voice: VoiceController
    let remoteIntegrationExecutor: RemoteIntegrationActionRuntime
    let activityLog: ActivityLog
    let overlayState: PerryCursorState
    let workspaceCoordinator: TaskCoordinator?
    let hooks: Hooks
    private let executionFinalizer: ExecutionFinalizer

    var agentCoordinator: AgentCoordinator?
    var workerLease: ForegroundWorkerLease?
    var activeRun: (any RunHandle)?
    private var handoffToHuman = false
    private var handoffGoal: String?
    private var doStartTask: Task<Void, Never>?
    private var foregroundActivityGeneration = UUID()
    private var observedForegroundTaskID: UUID?

    let activityStripState = AgentActivityStripState()
    var activityStripWindow: AgentActivityStripWindow?

#if DEBUG
    private var debugFinalizationBarrier: FinalizationBarrier?
    var debugConfirmer: (any Confirmer)?
    var debugAskUser: (@Sendable (String, [String]) async throws -> Void)?
    var debugTypedVerifier: (any TypedActionVerifier)?
#endif

    var supervisorActive: Bool { activeRun != nil }

    var startIsInFlight: Bool { doStartTask != nil }

    init(
        sessionController: SessionController,
        workers: CuaWorkerService,
        probe: EnvironmentProbe,
        voice: VoiceController,
        remoteIntegrationExecutor: RemoteIntegrationActionRuntime,
        activityLog: ActivityLog,
        executionFinalizer: ExecutionFinalizer,
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
        self.overlayState = overlayState
        self.workspaceCoordinator = workspaceCoordinator
        self.hooks = hooks
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

    @discardableResult
    func transitionSession(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return true
        } catch {
            hooks.setStatus("I stopped because something changed unexpectedly. Try again.")
            return false
        }
    }

    func cancelInvocationIfCurrent(_ attemptID: UUID) {
        guard sessionController.isInvoking(attemptID) else { return }
        _ = try? sessionController.cancelInvocation(attemptID)
    }

    func taskStartIsCurrent(_ attemptID: UUID) -> Bool {
        !Task.isCancelled && sessionController.isInvoking(attemptID)
    }

    func start(goal: String, threadID: UUID? = nil, targetHint: CuaTargetHint? = nil) {
        guard let attemptID = admitStart() else { return }
        startGoal(goal, attemptID: attemptID, threadID: threadID, targetHint: targetHint)
    }

    func startRoutine(_ routine: LearnedRoutine, parameters: [String: String] = [:]) {
        guard let attemptID = admitStart() else { return }
        spawn(attemptID) { controller in
            _ = await controller.perform(
                attemptID: attemptID,
                failureMessage: { error in
                    if let replay = error as? RoutineReplayError, let step = RoutineRunCopy.step(of: replay) {
                        return RoutineRunCopy.stopped(routine: routine, step: step, error: replay, reason: replay.localizedDescription)
                    }
                    return "I couldn’t run the routine. Try again."
                }
            ) { worker in
                switch try await controller.runRoutine(routine, parameters: parameters, attemptID: attemptID, worker: worker) {
                case .notStarted:
                    return nil
                case .finished(let outcome, let headline):
                    if outcome.isCompleted { controller.hooks.routineVerified(routine.id) }
                    return await controller.finalizeTask(with: outcome, headline: headline)
                }
            }
        }
    }

    private func startGoal(_ goal: String, attemptID: UUID, threadID: UUID?, targetHint: CuaTargetHint?) {
        spawn(attemptID) { controller in
            _ = await controller.perform(
                attemptID: attemptID,
                failureMessage: { _ in "I couldn’t finish the task. Try again." }
            ) { worker in
                try await controller.runForegroundOperation(
                    goal: goal,
                    attemptID: attemptID,
                    worker: worker, threadID: threadID, targetHint: targetHint
                )
            }
        }
    }

    private func admitStart() -> UUID? {
        guard !hooks.isErasureInProgress() else {
            voice.speak("I’m finishing a data erase before starting anything new.")
            return nil
        }
        guard !supervisorActive, !startIsInFlight else {
            voice.speak("I’m already working on a task. Stop or pause that one first.")
            return nil
        }
        let attemptID = sessionController.currentOrFreshAttemptID
        guard sessionController.beginInvokingIfNeeded(attemptID: attemptID) else {
            voice.speak("Finish or stop the current session first.")
            hooks.setStatus("Finish or stop the current session first.")
            return nil
        }
        return attemptID
    }

    private func spawn(_ attemptID: UUID, _ body: @escaping @MainActor (ForegroundTaskController) async -> Void) {
        doStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.cancelInvocationIfCurrent(attemptID)
                self.doStartTask = nil
            }
            await body(self)
        }
    }

    private func perform(
        attemptID: UUID,
        failureMessage: (Error) -> String,
        _ operation: @escaping @MainActor (CuaWorkerHandle) async throws -> DoOutcome?
    ) async -> DoOutcome? {
        guard !supervisorActive else {
            guard taskStartIsCurrent(attemptID) else { return nil }
            voice.speak("I’m already working on a task. Stop or pause that one first.")
            return nil
        }
        guard await preflight(attemptID: attemptID) else { return nil }
        do {
            return try await workers.withWorker(scope: .foreground, resources: []) { worker in
                try await operation(worker)
            }
        } catch {
            guard !(error is CancellationError), taskStartIsCurrent(attemptID) else { return nil }
            let message = failureMessage(error)
            hooks.setStatus(message)
            voice.speak(message)
            return nil
        }
    }

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

    func presentRunStart(_ execution: ExecutionSessionState, attemptID: UUID, bubble: String) -> Bool {
        guard sessionController.beginInvokingIfNeeded(attemptID: attemptID),
              transitionSession({ try sessionController.startExecution(execution, attemptID: attemptID) }) else {
            return false
        }
        hooks.setTranscriptPreview(execution.goal)
        hooks.stopSpatialMonitoring()
        hooks.stopGuideObservation()
        hooks.hidePanel()
        SoundPlayer.play(.send)
        overlayState.buddyState = .acting
        overlayState.agentTaskBubbleText = bubble
        activityStripWindow?.setExpanded(false, animate: false)
        showActivityStrip()
        return true
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
            lifecycle: .starting
        )
        guard presentRunStart(execution, attemptID: attemptID, bubble: "Working on \(goal)…"),
              transitionSession({ try sessionController.setExecutionPhase(.running) }) else { return nil }
        hooks.setStatus("Working…")

        let threadID = conversationID ?? UUID()
        activeRun = AgentRunHandle(coordinator: coordinator, threadID: threadID)
        let runID = UUID()
        workerLease?.set(worker, for: runID)
        defer {
            activeRun = nil
            workerLease?.set(nil, for: runID)
        }

        var answer = ""
        var stepIndex = 0
        var actionCalls: [String: String] = [:]
        var actionsDone = 0
        var lastActionFailure: String?
        var usedGUI = false
        let result = await coordinator.runToEnd(threadID: threadID, goal: goal, kind: .doTask, runID: runID, target: target) { event in
            guard executionIsCurrent(taskUUID), !Task.isCancelled else {
                coordinator.stop(threadID: threadID)
                return
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
                transitionSession {
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
            case .finished:
                break
            }
        }
        let finish: AgentFinish = Task.isCancelled ? .interrupted : result.finish
        if Task.isCancelled { coordinator.stop(threadID: threadID) }
        guard executionIsCurrent(taskUUID) else {
            return .blocked(reason: "the execution session changed")
        }
        let outcome = await finalizeTask(
            with: finish.doOutcome(stepsRun: actionsDone),
            headline: finish == .completed ? Self.doHeadline(actionsDone: actionsDone, lastActionFailure: lastActionFailure, answer: answer) : nil
        )
        if usedGUI, outcome.isCompleted { hooks.guiTaskCompleted() }
        return outcome
    }

    func executionIsCurrent(_ taskID: UUID) -> Bool {
        guard case .executing(let current) = sessionController.state else { return false }
        return current.taskID == taskID && !current.isFinalized
    }

    static func isGUITool(_ name: String) -> Bool {
        name.hasPrefix("ui.")
    }

    private static func toolStepSummary(_ call: ToolCall) -> String {
        let label = call.arguments["label"]?.stringValue
            ?? call.arguments["path"]?.stringValue
            ?? call.arguments["bundleID"]?.stringValue
            ?? call.arguments["elementID"]?.stringValue
        return label.map { "\(call.name) \($0)" } ?? call.name
    }

    static func doHeadline(actionsDone: Int, lastActionFailure: String?, answer: String) -> String? {
        if let lastActionFailure { return "I finished, but my last action failed: \(lastActionFailure)." }
        guard actionsDone == 0 else { return nil }
        let reply = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return reply.isEmpty ? "I didn’t change anything." : String(reply.prefix(240))
    }

    func showActivityStrip() {
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

    func pause() {
        guard let activeRun, transitionSession({ try sessionController.setExecutionPhase(.paused) }) else { return }
        hooks.setStatus("Pausing before the next step.")
        activeRun.pause()
    }

    func resume() {
        if handoffToHuman {
            continueFromHuman()
            return
        }
        guard let activeRun, transitionSession({ try sessionController.setExecutionPhase(.running) }) else { return }
        hooks.setStatus("Resuming the task.")
        activeRun.resume()
    }

    func takeOver() {
        guard let activeRun, !handoffToHuman else { return }
        guard transitionSession({ try sessionController.setExecutionPhase(.paused) }) else { return }
        if case .executing(let execution) = sessionController.state {
            handoffGoal = execution.goal
        }
        handoffToHuman = true
        activityStripState.handedToHuman = true
        hooks.setStatus("You’re in control. Do the step yourself, then choose Resume.")
        voice.speak("You’re in control. Choose Resume when you’re done.")
        activeRun.pause()
    }

    private func continueFromHuman() {
        guard handoffToHuman, let goal = handoffGoal, let activeRun else { return }
        handoffToHuman = false
        handoffGoal = nil
        activityStripState.handedToHuman = false
        if activeRun.continuesInPlace {
            guard transitionSession({ try sessionController.setExecutionPhase(.running) }) else { return }
            hooks.setStatus("Continuing. I’ll check what you did.")
            activeRun.resume()
            activeRun.steer("The user took over and did the current step themselves. Verify the result on screen, then continue the goal.")
            return
        }
        hooks.setStatus("Planning the rest from the current screen.")
        Task { @MainActor [weak self] in
            guard let self else { return }
            await activeRun.stop()
            for _ in 0..<100 where self.activeRun != nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard self.activeRun == nil else {
                self.hooks.setStatus("I’m still stopping the paused task. Try Resume again in a moment.")
                return
            }
            self.start(goal: goal)
        }
    }

    func cancel() {
        guard let activeRun, sessionController.requestStop() == .stopExecution else { return }
        hooks.setStatus("Stopping safely…")
        hooks.dismissIntentCard()
        Task { await activeRun.stop() }
    }

    func cancelActiveSupervisor() async {
        await activeRun?.stop()
    }

    func steer(_ instruction: String) {
        guard !handoffToHuman else { return }
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard case .executing(let execution) = sessionController.state,
              execution.lifecycle == .running || execution.lifecycle == .paused,
              let activeRun else { return }
        activeRun.steer(trimmed)
        if activeRun.continuesInPlace {
            hooks.setStatus("Steering: \(trimmed)")
            return
        }
        guard transitionSession({ try sessionController.setExecutionPhase(.paused) }) else { return }
        handoffGoal = "\(execution.goal) — user steered: \(trimmed)"
        handoffToHuman = true
        hooks.setStatus("Replanning with your instruction…")
        activeRun.pause()
        continueFromHuman()
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
        startGoal(goal, attemptID: attemptID, threadID: nil, targetHint: nil)
    }

    func cancelStartTask() {
        doStartTask?.cancel()
        doStartTask = nil
    }

    func joinStartTask() async {
        await doStartTask?.value
    }

    func finalizeTask(with reportedOutcome: DoOutcome, headline: String? = nil) async -> DoOutcome {
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
            transitionSession {
                try sessionController.fail(
                    SessionFailure(taskID: execution.taskID, goal: execution.goal, message: summary)
                )
            }
        } else {
            transitionSession {
                try sessionController.report(summary: summary, outcome: finalizationOutcome.isCompleted ? .completed : .stopped)
            }
        }
        voice.deliverVoiceReply(summary)
        activeRun = nil
        handoffToHuman = false
        handoffGoal = nil
        activityStripState.handedToHuman = false
        voice.refreshWakeWordListener()
        scheduleActivityRetirement(taskID: taskID, generation: foregroundActivityGeneration, after: 8)
        return finalizationOutcome
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
            self.transitionSession { try self.sessionController.completeDismissal() }
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
        guard sessionController.beginInvokingIfNeeded(attemptID: attemptID) else { return nil }
        defer { cancelInvocationIfCurrent(attemptID) }
        return try await workers.withWorker(scope: .foreground, resources: []) { worker in
            try await self.runForegroundOperation(
                goal: goal,
                attemptID: attemptID,
                worker: worker
            )
        }
    }
#endif
}

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
