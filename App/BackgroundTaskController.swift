import AppKit
import Foundation
import PerryBrain
import PerryCore
import PerryGuide
import PerryRuntimes

@MainActor
final class BackgroundTaskController: ObservableObject {
    static func undoGoal(for goal: String) -> String {
        if goal.hasPrefix("Undo “"), goal.hasSuffix("”") { return String(goal.dropFirst(6).dropLast()) }
        return "Undo “\(goal)”"
    }

    struct Hooks {
        var setStatus: (String) -> Void = { _ in }
        var isErasureInProgress: () -> Bool = { false }
        var requestOnboarding: () -> Void = {}
        var statusCountsChanged: (_ total: Int, _ active: Int, _ awaitingApproval: Int) -> Void = { _, _, _ in }
    }

    private let workers: ScreenWorkerService
    private let coordinator: TaskCoordinator
    private let runner: ResumableTaskRunner
    private let contextStore: BackgroundTaskContextStore
    private let transcriptStore: TranscriptStore
    private let notifier: any AppNotificationClient
    private let agentCoordinator: AgentCoordinator
    private let storageDirectory: () -> URL?
    private let hooks: Hooks

    private struct Handles {
        var setup: Task<Void, Never>?
        var launch: Task<Void, Never>?
        var run: Task<Void, Never>?

        var all: [Task<Void, Never>] { [setup, launch, run].compactMap { $0 } }
    }

    private var owned: [TaskID: Handles] = [:]
    private let controlScope = BackgroundTaskControlScope()
    private let launchGate = BackgroundTaskLaunchGate()
    private var messages: [TaskID: String] = [:]

    @Published private(set) var records: [TaskRecord] = []
    @Published private(set) var persistenceError: PersistenceError?
    @Published private(set) var runningCount = 0
    @Published private(set) var undoingIDs: Set<TaskID> = []

    private static let maximumConcurrentTasks = 3
    private static let joinTimeout: Duration = .milliseconds(500)

    var trashURL: URL?
#if DEBUG
    private var debugLaunchBarrier: (@MainActor () async -> Void)?
#endif

    init(
        workers: ScreenWorkerService,
        coordinator: TaskCoordinator,
        runner: ResumableTaskRunner,
        contextStore: BackgroundTaskContextStore,
        transcriptStore: TranscriptStore,
        notifier: any AppNotificationClient,
        agentCoordinator: AgentCoordinator,
        storageDirectory: @escaping () -> URL?,
        hooks: Hooks
    ) {
        self.workers = workers
        self.coordinator = coordinator
        self.runner = runner
        self.contextStore = contextStore
        self.transcriptStore = transcriptStore
        self.notifier = notifier
        self.agentCoordinator = agentCoordinator
        self.storageDirectory = storageDirectory
        self.hooks = hooks
    }

    var acceptsControls: Bool { controlScope.acceptsControls }
    var hasRunningTasks: Bool { runCount > 0 }

    private var runCount: Int { owned.values.filter { $0.run != nil }.count }

    private var canStartWork: Bool { controlScope.acceptsControls && !hooks.isErasureInProgress() }

    private func setHandle(_ id: TaskID, _ slot: WritableKeyPath<Handles, Task<Void, Never>?>, _ task: Task<Void, Never>?) {
        var handles = owned[id] ?? Handles()
        handles[keyPath: slot] = task
        owned[id] = handles.all.isEmpty ? nil : handles
    }

    func isRunning(_ id: TaskID) -> Bool {
        owned[id] != nil
    }

    func message(for id: TaskID) -> String? {
        messages[id]
    }

    func undoableDescriptions(for record: TaskRecord) -> [String] {
        guard let workspace = undoWorkspace(for: record),
              let journal = record.workspaceJournal else { return [] }
        let engine = WorkspaceUndoEngine(workspace: workspace)
        return journal.completed.reversed().compactMap { engine.inverseDescription(for: $0.receipt) }
    }

    func isUndoing(_ id: TaskID) -> Bool {
        undoingIDs.contains(id)
    }

    func undoWorkspaceChanges(_ record: TaskRecord) {
        guard controlScope.acceptsControls,
              !undoingIDs.contains(record.id),
              let workspace = undoWorkspace(for: record),
              let journal = record.workspaceJournal,
              !journal.completed.isEmpty else { return }
        let receipts = journal.completed.map(\.receipt)
        undoingIDs.insert(record.id)
        let admitted = controlScope.start { @MainActor [weak self] in
            guard let self else { return }
            defer { self.undoingIDs.remove(record.id) }
            do {
                let engine = WorkspaceUndoEngine(workspace: workspace, trashURL: self.trashURL)
                let plan = try engine.inversePlan(
                    receipts: receipts,
                    goal: Self.undoGoal(for: record.goal)
                )
                let journal = WorkspaceRunJournal(
                    plan: plan, workspace: workspace, coordinator: self.coordinator,
                    trashURL: self.trashURL
                )
                var undone = 0
                var stopped: String?
                for action in plan.actions {
                    do {
                        _ = try await journal.perform(action)
                        undone += 1
                    } catch {
                        stopped = error.localizedDescription
                        break
                    }
                }
                await journal.settle()
                self.messages[record.id] = stopped.map { stopped in
                    undone == 0
                        ? "Nothing was undone. \(stopped)"
                        : "Undid \(undone) change\(undone == 1 ? "" : "s"), then stopped: \(stopped)"
                } ?? "Undid \(undone) change\(undone == 1 ? "" : "s")."
            } catch {
                self.messages[record.id] = "Nothing was undone. \(error.localizedDescription)"
            }
            await self.reloadRecords()
        }
        if !admitted {
            undoingIDs.remove(record.id)
        }
    }

    private func undoWorkspace(for record: TaskRecord) -> URL? {
        guard record.isTerminal, !isRunning(record.id),
              case .executable(let plan) = record.plan else { return nil }
        return plan.actions.lazy.compactMap { action -> URL? in
            guard case .transform(let workspace, _) = action.operation else { return nil }
            return workspace
        }.first
    }

    func refreshRecords() {
        Task { @MainActor [weak self] in
            await self?.reloadRecords()
        }
    }

    func reloadRecords() async {
        let records = await runner.records()
        persistenceError = await coordinator.lastPersistenceError
        if let issue = persistenceError {
            hooks.setStatus(issue.localizedDescription)
        }
        let metadata = await contextStore.snapshot()
        self.records = records
        runningCount = runCount
        let liveIDs = Set(records.map(\.id))
        messages = messages.filter { liveIDs.contains($0.key) }
        for record in records where messages[record.id] == nil {
            messages[record.id] = metadata[record.id]?.runtimeRoutingSummary
        }
        hooks.statusCountsChanged(
            records.count,
            records.filter { !$0.isTerminal }.count,
            awaitingApprovalCount
        )
    }

    var awaitingApprovalCount: Int {
        records.filter { $0.workspaceActionToApprove != nil }.count
    }

    func recoverInterruptedAndStartQueued() async {
        do {
            _ = try await coordinator.recoverInterruptedRuns()
        } catch {
            hooks.setStatus("Background-task recovery failed: \(error.localizedDescription)")
            await reloadRecords()
            return
        }
        await reloadRecords()
        startQueuedTasks()
    }

    func queue(goal: String) {
        guard !hooks.isErasureInProgress() else {
            hooks.setStatus("I’m finishing a data erase.")
            return
        }
        guard controlScope.acceptsControls else { return }
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hooks.setStatus("Tell Perry what the background task should do.")
            return
        }
        let id = TaskID()
        let setupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.setHandle(id, \.setup, nil) }
            _ = await self.notifier.requestAuthorization()
            do {
                let record = try await self.coordinator.enqueue(
                    agentPlan: AgentTaskPlan(goal: trimmed, threadID: UUID()),
                    taskID: id
                )
                try await self.contextStore.save(
                    BackgroundTaskMetadata(runtimeRoutingSummary: "Perry agent"),
                    for: id
                )
                guard !Task.isCancelled,
                      !self.hooks.isErasureInProgress(),
                      self.controlScope.acceptsControls else {
                    try await self.rollbackCreation(for: id)
                    return
                }
                start(record: record)
                hooks.setStatus("Queued \(trimmed) as a background task.")
                refreshRecords()
            } catch is CancellationError {
                do {
                    try await self.rollbackCreation(for: id)
                } catch {
                    self.hooks.setStatus("Couldn’t clean up the cancelled background task: \(error.localizedDescription)")
                }
            } catch {
                let failure = error.localizedDescription
                do {
                    try await self.rollbackCreation(for: id)
                    hooks.setStatus("Couldn’t queue the background task: \(failure)")
                } catch {
                    hooks.setStatus("Couldn’t queue the background task: \(failure). Cleanup failed: \(error.localizedDescription)")
                }
            }
        }
        setHandle(id, \.setup, setupTask)
    }

    private func rollbackCreation(for id: TaskID) async throws {
        if await coordinator.record(id: id) != nil {
            try await runner.discard(id: id)
        }
        if await contextStore.metadata(for: id) != nil {
            try await contextStore.remove(for: id)
        }
        try Self.removeWorkspace(for: id, root: workspaceRoot())
    }

    func pause(_ id: TaskID) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        guard controlScope.acceptsControls else { return }
        launchGate.cancel(id)
        if case .agent(let agentPlan) = record.plan {
            agentCoordinator.stop(threadID: agentPlan.threadID)
        }
        messages[id] = "Pausing at the next safe boundary"
        _ = controlScope.start { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.runner.pause(id: id)
            } catch {
                self.messages[id] = "Couldn’t persist the paused state: \(error.localizedDescription)"
            }
            self.refreshRecords()
        }
    }

    func approveWorkspace(_ record: TaskRecord) {
        guard controlScope.acceptsControls, !hooks.isErasureInProgress(),
              record.workspaceActionToApprove != nil else { return }
        _ = controlScope.start { @MainActor [weak self] in
            guard let self else { return }
            do {
                let prepared = try await self.coordinator.approveWorkspaceAction(id: record.id, expectedRevision: record.revision)
                guard !Task.isCancelled, self.controlScope.acceptsControls, !self.hooks.isErasureInProgress() else { return }
                self.start(record: prepared)
            } catch {
                if let current = await self.coordinator.record(id: record.id),
                   current.revision != record.revision {
                    self.messages[record.id] = "That approval request is no longer current"
                } else {
                    self.messages[record.id] = "Approval was not applied: \(error.localizedDescription). Review the current task and try again."
                }
            }
            await self.reloadRecords()
        }
    }

    func approve(_ id: TaskID, expectedActionID: String, expectedRevision: UUID) {
        guard let record = records.first(where: { $0.id == id }), record.revision == expectedRevision else {
            messages[id] = "That approval request is no longer current"
            return
        }
        if record.workspaceActionToApprove?.id.rawValue == expectedActionID {
            approveWorkspace(record)
            return
        }
        messages[id] = "That approval request is no longer current"
    }

    func deny(_ id: TaskID, expectedRevision: UUID) {
        guard records.first(where: { $0.id == id })?.revision == expectedRevision else {
            messages[id] = "That approval request is no longer current"
            return
        }
        cancel(id, expectedRevision: expectedRevision)
    }

    func resume(_ id: TaskID) {
        guard controlScope.acceptsControls else { return }
        guard let visibleRecord = records.first(where: { $0.id == id }) else { return }
        if let message = BackgroundTaskLaunchGate.blocker(record: visibleRecord) {
            messages[id] = message
            return
        }
        guard let launchLease = launchGate.acquire(for: id) else {
            messages[id] = "Resume already in progress"
            return
        }
        let launchTask = Task { @MainActor [weak self] in
            defer { self?.setHandle(id, \.launch, nil) }
            guard let self else { return }
#if DEBUG
            if let barrier = self.debugLaunchBarrier {
                await barrier()
            }
#endif
            guard let record = await self.runner.records().first(where: { $0.id == id }),
                  self.launchGate.contains(launchLease),
                  !Task.isCancelled,
                  self.canStartWork else {
                self.launchGate.release(launchLease)
                return
            }
            if let message = BackgroundTaskLaunchGate.blocker(record: record) {
                self.messages[id] = message
                self.launchGate.release(launchLease)
                return
            }
            guard self.start(
                record: record,
                launchLease: launchLease
            ) else {
                self.launchGate.release(launchLease)
                return
            }
            self.refreshRecords()
        }
        setHandle(id, \.launch, launchTask)
        guard controlScope.start({ @MainActor in
            await launchTask.value
        }) else {
            launchTask.cancel()
            launchGate.release(launchLease)
            return
        }
    }

    func canResume(_ record: TaskRecord) -> Bool {
        (record.canResumeWorkspaceTask || record.canResumeAgentTask)
            && !record.checkpoint.isAwaitingApproval && !isRunning(record.id)
    }

    func resumeAll() {
        records.filter(canResume).map(\.id).forEach(resume)
    }

    func cancel(_ id: TaskID, expectedRevision: UUID? = nil) {
        guard owned[id]?.setup != nil
            || records.contains(where: { $0.id == id }) else { return }
        guard controlScope.acceptsControls else { return }
        if expectedRevision == nil {
            owned[id]?.setup?.cancel()
        }
        messages[id] = "Stopping"
        _ = controlScope.start { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.runner.cancel(id: id, expectedRevision: expectedRevision)
            } catch {
                if await self.coordinator.record(id: id).map(\.isTerminal) ?? true {
                    self.cancelOwnedWork(id)
                    _ = await self.waitForOwnershipToEnd(id)
                    self.refreshRecords()
                    return
                }
                self.messages[id] = "Couldn’t persist cancellation: \(error.localizedDescription)"
                self.refreshRecords()
                return
            }
            self.cancelOwnedWork(id)
            guard await self.waitForOwnershipToEnd(id) else {
                self.refreshRecords()
                return
            }
            guard let currentRecord = await self.coordinator.record(id: id) else {
                self.refreshRecords()
                return
            }
            if currentRecord.canReportWorkspaceTask {
                do {
                    let report = try await self.coordinator.queueWorkspaceReport(id: id, expectedRevision: currentRecord.revision)
                    _ = self.start(record: report)
                } catch {
                    self.messages[id] = "Couldn’t queue the verified report: \(error.localizedDescription)"
                }
                self.refreshRecords()
                return
            }
            do {
                let outcome = try await self.coordinator.finishCancellation(
                    id: currentRecord.id,
                    reason: "user cancelled the task",
                    expectedRevision: currentRecord.revision
                )
                await self.handleOutcome(
                    record: currentRecord,
                    metadata: await self.contextStore.metadata(for: id),
                    outcome: outcome
                )
            } catch {
                if await self.coordinator.record(id: id).map(\.isTerminal) ?? true {
                    self.refreshRecords()
                    return
                }
                self.messages[id] = "Couldn’t finish cancellation: \(error.localizedDescription)"
                self.refreshRecords()
                return
            }
            self.refreshRecords()
        }
    }

    private func cancelOwnedWork(_ id: TaskID) {
        launchGate.cancel(id)
        owned[id]?.all.forEach { $0.cancel() }
    }

    private func waitForOwnershipToEnd(_ id: TaskID) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: Self.joinTimeout)
        while owned[id] != nil {
            guard ContinuousClock.now < deadline else { return false }
            do {
                try await Task.sleep(
                    until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(5))),
                    clock: .continuous
                )
            } catch {
                return false
            }
        }
        return true
    }

    func discard(_ id: TaskID) {
        guard owned[id]?.run == nil else { return }
        guard controlScope.acceptsControls else { return }
        launchGate.cancel(id)
        _ = controlScope.start { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.runner.discard(id: id)
                try Self.removeWorkspace(for: id, root: self.workspaceRoot())
            } catch {
                self.messages[id] = "Couldn’t discard task: \(error.localizedDescription)"
                return
            }
            do {
                try await self.contextStore.remove(for: id)
            } catch {
                self.messages[id] = "Task removed, but cleanup failed: \(error.localizedDescription)"
                return
            }
            self.messages[id] = nil
            self.refreshRecords()
        }
    }

    @discardableResult
    private func start(
        record: TaskRecord,
        launchLease: BackgroundTaskLaunchLease? = nil
    ) -> Bool {
        guard canStartWork, owned[record.id]?.run == nil else { return false }
        switch record.plan {
        case .executable:
            return startWorkspaceTask(record: record, launchLease: launchLease)
        case .agent:
            return startAgentTask(record: record, launchLease: launchLease)
        }
    }

    private func launchIsCurrent(_ lease: BackgroundTaskLaunchLease?) -> Bool {
        guard let lease else { return true }
        return launchGate.contains(lease)
    }

    private func beginRun(_ record: TaskRecord, message: String, body: @escaping @MainActor (BackgroundTaskController) async -> Void) -> Bool {
        guard runCount < Self.maximumConcurrentTasks else {
            messages[record.id] = "Queued until another background task finishes"
            return false
        }
        messages[record.id] = message
        setHandle(record.id, \.run, Task { @MainActor [weak self] in
            guard let self else { return }
            await body(self)
        })
        runningCount = runCount
        return true
    }

    private func finishRun(_ id: TaskID, lease: BackgroundTaskLaunchLease?, advanceQueue: Bool = true) async {
        if let lease { launchGate.release(lease) }
        setHandle(id, \.run, nil)
        await reloadRecords()
        if advanceQueue { startQueuedTasks() }
    }

    private func startWorkspaceTask(record: TaskRecord, launchLease: BackgroundTaskLaunchLease?) -> Bool {
        guard record.canResumeWorkspaceTask, case .executable(let plan) = record.plan else {
            messages[record.id] = "Review the file and approve its creation before running."
            return false
        }
        return beginRun(record, message: "Running approved file task") { controller in
            var reported = false
            var canAdvanceQueue = true
            do {
                try Task.checkCancellation()
                guard controller.launchIsCurrent(launchLease), controller.canStartWork else { throw CancellationError() }
                let metadata = await controller.contextStore.metadata(for: record.id)
                let progress: WorkspaceTaskProgress
                if record.canReportWorkspaceTask {
                    controller.messages[record.id] = "Saving verified task report"
                    progress = .reported(try await controller.runner.reportWorkspaceTask(record: record, history: controller.transcriptStore, startedAt: metadata?.createdAt ?? Date()))
                } else {
                    let workspace = try controller.workspaceURL(for: record.id, metadata: metadata)
                    progress = try await controller.workers.withWorker(scope: .background, resources: [.workspace(workspace.standardizedFileURL.path)]) { _ in
                        try await controller.runner.runWorkspaceTask(record: record, runtime: WorkspaceFileRuntime(baseURL: workspace), history: controller.transcriptStore, startedAt: metadata?.createdAt ?? Date())
                    }
                }
                switch progress {
                case .awaitingApproval:
                    controller.messages[record.id] = "Action verified. Review and approve the next action."
                case .reported:
                    reported = true
                    _ = await controller.runner.takeReportedWorkspaceOutcome(for: plan.planID)
                    controller.messages[record.id] = "Report saved to history"
                    try await controller.contextStore.remove(for: record.id)
                }
            } catch {
                let recordIsFinished = await controller.coordinator.record(id: record.id).map(\.isTerminal) ?? true
                if !reported, recordIsFinished,
                   await controller.runner.takeReportedWorkspaceOutcome(for: plan.planID) != nil {
                    reported = true
                    do {
                        try await controller.contextStore.remove(for: record.id)
                        controller.messages[record.id] = "Report saved to history"
                    } catch {
                        controller.messages[record.id] = "History saved, but metadata cleanup failed: \(error.localizedDescription)"
                    }
                } else {
                    controller.messages[record.id] = reported
                        ? "History saved, but metadata cleanup failed: \(error.localizedDescription)"
                        : "Task stopped: \(error.localizedDescription). Review its saved state before retrying."
                }
                if !reported, let current = await controller.coordinator.record(id: record.id),
                   current.revision == record.revision,
                   !current.cancellationRequested || current.canResumeWorkspaceTask {
                    do {
                        _ = try await controller.coordinator.pause(id: record.id, expectedRevision: current.revision)
                    } catch TaskCoordinatorError.invalidTransition {
                    } catch {
                        canAdvanceQueue = false
                        controller.messages[record.id] = "Couldn’t save the paused task: \(error.localizedDescription). Waiting tasks won’t start until saving works again."
                    }
                }
                if await controller.coordinator.lastPersistenceError != nil {
                    canAdvanceQueue = false
                }
            }
            await controller.finishRun(record.id, lease: launchLease, advanceQueue: canAdvanceQueue)
        }
    }

    private func startAgentTask(record: TaskRecord, launchLease: BackgroundTaskLaunchLease?) -> Bool {
        guard case .agent(let agentPlan) = record.plan, record.canResumeAgentTask else {
            messages[record.id] = "This task can’t resume."
            return false
        }
        return beginRun(record, message: "Running in the background") { controller in
            let metadata = await controller.contextStore.metadata(for: record.id)
            var outcome: DoOutcome?
            var ranActions: [String]?
            do {
                try Task.checkCancellation()
                guard controller.launchIsCurrent(launchLease), controller.canStartWork else { throw CancellationError() }
                _ = try await controller.coordinator.beginAgentRun(id: record.id, expectedRevision: record.revision)
                controller.refreshRecords()
                var tally = AgentRunTally()
                let result = await controller.agentCoordinator.runToEnd(
                    threadID: agentPlan.threadID,
                    goal: record.goal,
                    kind: .unattended(perryID: nil)
                ) { event in
                    tally.record(event) { controller.agentCoordinator.toolIsReadOnly(named: $0) }
                    switch event {
                    case .toolCallStarted(let call):
                        controller.messages[record.id] = "Running \(call.name)"
                    case .toolCallFinished(let finished):
                        if finished.isError { controller.messages[record.id] = "A tool call failed" }
                    case .note(let note):
                        controller.messages[record.id] = note
                    case .textDelta, .draw, .finished:
                        break
                    }
                }
                if await controller.coordinator.record(id: record.id)?.state == .paused || Task.isCancelled {
                    throw CancellationError()
                }
                let resolved = tally.outcome(for: result.finish)
                ranActions = tally.actions
                outcome = try await controller.coordinator.finish(id: record.id, outcome: resolved)
            } catch is CancellationError {
            } catch {
                let resolved = DoOutcome.failed(stepSummary: "the agent run", reason: error.localizedDescription)
                outcome = resolved
                if let current = await controller.coordinator.record(id: record.id), !current.isTerminal {
                    _ = try? await controller.coordinator.finish(id: record.id, outcome: resolved)
                }
            }
            if await controller.coordinator.record(id: record.id)?.state == .paused {
                controller.messages[record.id] = "Paused. Resume continues the task on the same thread."
                await controller.finishRun(record.id, lease: launchLease)
                return
            }
            await controller.handleOutcome(record: record, metadata: metadata, outcome: outcome, ranActions: ranActions)
            if let outcome {
                let completed = outcome.isCompleted
                await controller.notifier.deliver(TaskNotification(
                    kind: completed ? .completed : .stopped,
                    title: completed ? "Background task finished" : "Background task stopped",
                    body: record.goal,
                    taskID: record.id
                ))
            }
            await controller.finishRun(record.id, lease: launchLease)
        }
    }

    static func approvalReason(for call: ToolCall) -> String {
        let headline = ToolApprovalPresenter.headline(call, target: nil)
        let question = headline.dropLast()
        let title = headline == "Approve this step?" ? call.name : question.prefix(1).lowercased() + question.dropFirst()
        return "Needs your OK to \(title). Run it again in front of you to approve it."
    }

    private func startQueuedTasks() {
        guard controlScope.acceptsControls, runCount < Self.maximumConcurrentTasks else { return }
        records
            .filter { ($0.canStartAutomatically || $0.canResumeAgentTask) && owned[$0.id]?.run == nil }
            .forEach { resume($0.id) }
    }

    private func handleOutcome(
        record: TaskRecord,
        metadata: BackgroundTaskMetadata?,
        outcome reportedOutcome: DoOutcome?,
        ranActions: [String]? = nil
    ) async {
        let outcome: DoOutcome
        if let reportedOutcome {
            outcome = reportedOutcome
        } else {
            guard let currentRecord = await coordinator.record(id: record.id),
                  !currentRecord.isTerminal else {
                refreshRecords()
                return
            }
            guard currentRecord.cancellationRequested else {
                messages[record.id] = "Waiting to retry"
                return
            }
            do {
                outcome = try await coordinator.finishCancellation(
                    id: currentRecord.id,
                    reason: "user cancelled the task"
                )
            } catch {
                if await coordinator.record(id: currentRecord.id).map(\.isTerminal) ?? true {
                    refreshRecords()
                    return
                }
                messages[record.id] = "Couldn’t finish cancellation: \(error.localizedDescription)"
                refreshRecords()
                return
            }
        }
        let persisted = await runner.records().contains { $0.id == record.id && !$0.isTerminal }
        let cleanupFailure: String
        switch outcome {
        case .completed:
            messages[record.id] = "Finished"
            cleanupFailure = "Finished, but cleanup failed"
        case .blocked(let reason):
            messages[record.id] = persisted ? "Paused: \(reason)" : "Stopped: \(reason)"
            cleanupFailure = "Stopped, but cleanup failed"
        case .failed(let step, let reason):
            messages[record.id] = persisted ? "Paused after \(step): \(reason)" : "Failed at \(step): \(reason)"
            cleanupFailure = "Failed, and cleanup also failed"
        }
        if outcome.isCompleted || !persisted {
            await recordToTranscript(record: record, metadata: metadata, outcome: outcome, ranActions: ranActions)
            do {
                try await contextStore.remove(for: record.id)
            } catch {
                messages[record.id] = "\(cleanupFailure): \(error.localizedDescription)"
            }
        }
        hooks.setStatus("Background task \(record.goal) \(messages[record.id]?.lowercased() ?? "updated").")
    }

    private func recordToTranscript(
        record: TaskRecord,
        metadata: BackgroundTaskMetadata?,
        outcome: DoOutcome,
        ranActions: [String]? = nil
    ) async {
        func sentence(_ text: String) -> String { text.hasSuffix(".") ? text : text + "." }
        let summary: String
        let stepCount: Int
        switch outcome {
        case .completed(let stepsRun):
            let count = ranActions?.count ?? stepsRun
            summary = "Finished \(count) step\(count == 1 ? "" : "s") in the background."
            stepCount = count
        case .blocked(let reason):
            summary = "Stopped safely in the background: \(sentence(reason))"
            stepCount = record.checkpoint.nextStepIndex
        case .failed(let step, let reason):
            summary = "Stopped in the background at \(step): \(sentence(reason))"
            stepCount = record.checkpoint.nextStepIndex
        }
        await transcriptStore.append(
            TranscriptEntry(
                request: record.goal,
                appBundleID: metadata?.targetAppBundleID,
                summary: summary,
                outcome: outcome.transcriptOutcome,
                startedAt: metadata?.createdAt ?? Date(),
                finishedAt: Date(),
                steps: ranActions ?? Array(record.plan.actionSummaries.prefix(stepCount)),
                verified: nil
            )
        )
    }

    private func makeWorkspace(for id: TaskID) throws -> URL {
        let directory = workspaceRoot().appendingPathComponent(id.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func workspaceURL(for id: TaskID, metadata: BackgroundTaskMetadata?) throws -> URL {
        let root = workspaceRoot().standardizedFileURL
        if let path = metadata?.workspacePath {
            let candidate = URL(fileURLWithPath: path).standardizedFileURL
            if candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") {
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
                return candidate
            }
        }
        return try makeWorkspace(for: id)
    }

    private func workspaceRoot() -> URL {
        if let override = storageDirectory() {
            return override.appendingPathComponent("BackgroundWorkspaces", isDirectory: true)
        }
        return WorkspaceScope.root
            .appendingPathComponent("BackgroundTasks", isDirectory: true)
    }

    static func removeWorkspace(
        for id: TaskID,
        root: URL,
        fileManager: FileManager = .default
    ) throws {
        let standardizedRoot = root.standardizedFileURL
        let workspace = standardizedRoot.appendingPathComponent(id.rawValue, isDirectory: true).standardizedFileURL
        guard workspace.deletingLastPathComponent() == standardizedRoot else {
            throw PerryErasureAdapterError(message: "task workspace escaped its root")
        }
        guard fileManager.fileExists(atPath: workspace.path) else { return }
        try fileManager.removeItem(at: workspace)
    }

    func closeControls() {
        controlScope.close()
    }

    func reopenControls() {
        controlScope.reopen()
    }

    func pauseAllOwnedForWorkerStop() async throws {
        try await controlScope.closeAndDrain()
        let records = await runner.records()
        for record in records where owned[record.id] != nil && !record.isTerminal && !record.cancellationRequested {
            do {
                try await coordinator.pause(id: record.id)
            } catch {
                guard let currentRecord = await coordinator.record(id: record.id) else {
                    continue
                }
                if currentRecord.cancellationRequested { continue }
                throw error
            }
        }
        owned.values.flatMap(\.all).forEach { $0.cancel() }
    }

    func cancelAllOwned() {
        owned.values.flatMap(\.all).forEach { $0.cancel() }
        launchGate.cancelAll()
    }

    func joinAll() async {
        for task in owned.values.flatMap(\.all) { await task.value }
    }

    func resetTasks() {
        owned.removeAll()
        runningCount = 0
    }

#if DEBUG
    func debugSetLaunchBarrier(_ barrier: (@MainActor () async -> Void)?) {
        debugLaunchBarrier = barrier
    }

    func debugSeed(record: TaskRecord, metadata: BackgroundTaskMetadata) async throws {
        switch record.plan {
        case .executable(let plan):
            _ = try await coordinator.enqueue(executablePlan: plan)
        case .agent(let plan):
            _ = try await coordinator.enqueue(agentPlan: plan, taskID: record.id)
        }
        try await contextStore.save(metadata, for: record.id)
        await reloadRecords()
    }

    func debugSaveMetadata(_ metadata: BackgroundTaskMetadata, for id: TaskID) async throws {
        try await contextStore.save(metadata, for: id)
    }

    func debugRecord(_ id: TaskID) async -> TaskRecord? {
        await coordinator.record(id: id)
    }

    func debugMetadata(_ id: TaskID) async -> BackgroundTaskMetadata? {
        await contextStore.metadata(for: id)
    }

    @discardableResult
    func debugInstallSetupTask(
        for id: TaskID,
        operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let task = Task { @MainActor [weak self] in
            defer { self?.setHandle(id, \.setup, nil) }
            await operation()
        }
        setHandle(id, \.setup, task)
        return task
    }
#endif
}

@MainActor
struct AgentRunTally {
    private var calls: [String: ToolCall] = [:]
    private(set) var actions: [String] = []
    private(set) var deniedCall: ToolCall?
    private(set) var lastFailure: (call: ToolCall, reason: String)?

    mutating func record(_ event: AgentLoopEvent, isReadOnly: (String) -> Bool) {
        switch event {
        case .toolCallStarted(let call):
            calls[call.id] = call
        case .toolCallFinished(let finished):
            guard let call = calls[finished.callID] else { return }
            if finished.isError {
                let first = finished.content.compactMap { part -> String? in
                    if case .text(let text) = part { return text.components(separatedBy: .newlines).first }
                    return nil
                }.first
                if first == ToolHostError.approvalDenied(name: call.name).localizedDescription {
                    deniedCall = deniedCall ?? call
                } else if !isReadOnly(call.name) {
                    lastFailure = (call, first ?? "the action failed")
                }
            } else if !isReadOnly(call.name) {
                actions.append(call.name)
                lastFailure = nil
            }
        case .textDelta, .draw, .note, .finished:
            break
        }
    }

    func outcome(for finish: AgentFinish) -> DoOutcome {
        var resolved = finish.doOutcome(stepsRun: 0)
        if finish == .completed {
            if let deniedCall {
                resolved = .blocked(reason: BackgroundTaskController.approvalReason(for: deniedCall))
            } else if let lastFailure {
                resolved = .failed(stepSummary: lastFailure.call.name, reason: lastFailure.reason)
            }
        }
        return resolved
    }
}
