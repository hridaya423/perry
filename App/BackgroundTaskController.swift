import AppKit
import Foundation
import PerryCore
import PerryGuide
import PerryRuntimes

/// Owns durable background work end to end: task creation (plan → validate →
/// persist → launch), the launch gate and control scope, per-task task
/// handles, approval/cancel/pause/resume/discard/replan controls, workspace
/// directories, recovery after relaunch, and the records/messages the
/// Background tasks window renders. Durable records stay in `TaskCoordinator`;
/// this controller owns the live control plane around it.
@MainActor
final class BackgroundTaskController: ObservableObject {
    struct Hooks {
        var setStatus: (String) -> Void = { _ in }
        var isErasureInProgress: () -> Bool = { false }
        var requestOnboarding: () -> Void = {}
        /// Fired with the visible record count after each reload — the shell
        /// uses it for the status-item menu label.
        var statusCountsChanged: (_ total: Int, _ active: Int, _ awaitingApproval: Int) -> Void = { _, _, _ in }
    }

    private let workers: CuaWorkerService
    private let coordinator: TaskCoordinator
    private let runner: ResumableTaskRunner
    private let contextStore: BackgroundTaskContextStore
    private let transcriptStore: TranscriptStore
    private let notifier: any AppNotificationClient
    private let runtimes: RuntimeCatalog
    private let probe: EnvironmentProbe
    private let remoteIntegrationExecutor: RemoteIntegrationActionRuntime
    private let storageDirectory: () -> URL?
    private let hooks: Hooks

    private var runTasks: [TaskID: Task<Void, Never>] = [:]
    private var setupTasks: [TaskID: Task<Void, Never>] = [:]
    private var launchTasks: [TaskID: Task<Void, Never>] = [:]
    private let controlScope = BackgroundTaskControlScope()
    private let launchGate = BackgroundTaskLaunchGate()
    private var messages: [TaskID: String] = [:]

    @Published private(set) var records: [TaskRecord] = []
    @Published private(set) var persistenceError: PersistenceError?
    @Published private(set) var runningCount = 0
    /// Records with an undo pass in flight — re-entry is refused so a
    /// double-click or late callback cannot dispatch the inverses twice.
    @Published private(set) var undoingIDs: Set<TaskID> = []

    private static let maximumConcurrentTasks = 3
    private static let joinTimeout: Duration = .milliseconds(500)

#if DEBUG
    private var debugLaunchBarrier: (@MainActor () async -> Void)?
    /// Overrides the Undo Trash root so tests never touch the user's real
    /// Trash; nil keeps the system default.
    var debugTrashURL: URL?
#endif

    init(
        workers: CuaWorkerService,
        coordinator: TaskCoordinator,
        runner: ResumableTaskRunner,
        contextStore: BackgroundTaskContextStore,
        transcriptStore: TranscriptStore,
        notifier: any AppNotificationClient,
        runtimes: RuntimeCatalog,
        probe: EnvironmentProbe,
        remoteIntegrationExecutor: RemoteIntegrationActionRuntime,
        storageDirectory: @escaping () -> URL?,
        hooks: Hooks
    ) {
        self.workers = workers
        self.coordinator = coordinator
        self.runner = runner
        self.contextStore = contextStore
        self.transcriptStore = transcriptStore
        self.notifier = notifier
        self.runtimes = runtimes
        self.probe = probe
        self.remoteIntegrationExecutor = remoteIntegrationExecutor
        self.storageDirectory = storageDirectory
        self.hooks = hooks
    }

    var acceptsControls: Bool { controlScope.acceptsControls }
    var hasRunningTasks: Bool { !runTasks.isEmpty }

    func isRunning(_ id: TaskID) -> Bool {
        runTasks[id] != nil || setupTasks[id] != nil || launchTasks[id] != nil
    }

    func message(for id: TaskID) -> String? {
        messages[id]
    }

    // MARK: Undo

    /// The receipt-derived inverses a terminal task still supports, in the
    /// order Undo would apply them (last change first). Empty means nothing
    /// reversible is on record — the row shows no Undo control.
    func undoableDescriptions(for record: TaskRecord) -> [String] {
        guard let workspace = undoWorkspace(for: record),
              let journal = record.workspaceJournal else { return [] }
        let engine = WorkspaceUndoEngine(workspace: workspace)
        return journal.completed.reversed().compactMap { engine.inverseDescription(for: $0.receipt) }
    }

    /// Reverses a terminal task's completed workspace effects, last change
    /// first, stopping at the first conflict so intervening user work is
    /// never touched. The inverses run as approved typed actions through the
    /// shared write-ahead journal, so an undo lands its own durable receipts —
    /// and is itself undoable.
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
                let engine: WorkspaceUndoEngine
#if DEBUG
                if let trash = self.debugTrashURL {
                    engine = WorkspaceUndoEngine(workspace: workspace, trashURL: trash)
                } else {
                    engine = WorkspaceUndoEngine(workspace: workspace)
                }
#else
                engine = WorkspaceUndoEngine(workspace: workspace)
#endif
                let plan = try engine.inversePlan(
                    receipts: receipts,
                    goal: "Undo “\(record.goal)”"
                )
#if DEBUG
                let journal = WorkspaceRunJournal(
                    plan: plan, workspace: workspace, coordinator: self.coordinator,
                    trashURL: self.debugTrashURL
                )
#else
                let journal = WorkspaceRunJournal(
                    plan: plan, workspace: workspace, coordinator: self.coordinator
                )
#endif
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
                        ? "Nothing was undone — \(stopped)"
                        : "Undid \(undone) change\(undone == 1 ? "" : "s"), then stopped: \(stopped)"
                } ?? "Undid \(undone) change\(undone == 1 ? "" : "s")."
            } catch {
                self.messages[record.id] = "Nothing was undone — \(error.localizedDescription)"
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

    // MARK: Records

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
        runningCount = runTasks.count
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

    /// Records parked on an approval-gated action — the signal the notch pill
    /// and status surfaces count as "needs review" rather than just running.
    var awaitingApprovalCount: Int {
        records.filter { $0.workspaceActionToApprove != nil }.count
    }

    /// Called once after launch: recovers interrupted runs, reloads the visible
    /// records, then starts anything the queue allows.
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

    // MARK: Creation

    func queue(goal: String, preferredRuntimeID: String? = nil) {
        guard !hooks.isErasureInProgress() else {
            hooks.setStatus("Perry is finishing a data erase.")
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
            defer { self.setupTasks[id] = nil }
            _ = await self.notifier.requestAuthorization()
            do {
                let queued = try await self.workers.withWorker(
                    scope: .background,
                    resources: []
                ) { @MainActor worker in
                    let workspace = try self.makeWorkspace(for: id)
                    try await worker.claimResources([.workspace(workspace.standardizedFileURL.path)])
                    guard let runtimeSelection = await self.runtimes.select(
                        workingDirectory: workspace,
                        preferredProviderID: RuntimeCatalog.providerID(from: preferredRuntimeID)
                    ) else {
                        throw CuaDriverError.unavailable
                    }
                    let request = try PlanningRequest(
                        goal: trimmed,
                        taskID: id,
                        workspace: workspace,
                        context: .none
                    )
                    var capturedTarget: CuaWindowTarget?
                    var plan: ExecutionPlan
                    do {
                        plan = try await runtimeSelection.provider.plan(request)
                    } catch PlanningError.contextRequired {
                        let permissions = await self.probe.permissionSnapshot()
                        guard permissions.requiredPermissionsGranted else {
                            self.hooks.setStatus("Accessibility and Screen Recording are required for a grounded background task.")
                            self.hooks.requestOnboarding()
                            throw CancellationError()
                        }
                        let captured = await self.probe.captureScreenContext(worker: worker)
                        guard EnvironmentProbe.captureIsUsable(captured.context), let target = captured.target else {
                            throw CuaDriverError.noTargetWindow
                        }
                        capturedTarget = target
                        try Task.checkCancellation()
                        plan = try await runtimeSelection.provider.plan(request.withScreenContext(captured.context))
                    }
                    try Task.checkCancellation()
                    // Publication is bound to the actual background executor:
                    // WorkspaceFileRuntime runs typed file transforms only, so
                    // computer/integration/shell plans are refused before a
                    // record is ever enqueued.
                    try ExecutionPlanValidator.validate(
                        plan,
                        capabilities: ExecutionPlanValidator.Capabilities(
                            supportedOperations: [.transform],
                            workspace: workspace
                        )
                    )
                    let record = try await self.coordinator.enqueue(executablePlan: plan)
                    try await self.contextStore.save(
                        BackgroundTaskMetadata(
                            targetAppBundleID: capturedTarget?.bundleID,
                            targetWindowTitle: capturedTarget?.title,
                            targetProcessID: capturedTarget?.processID,
                            targetWindowID: capturedTarget?.windowID,
                            workspacePath: workspace.path,
                            preferredRuntimeID: RuntimeCatalog.providerID(from: preferredRuntimeID),
                            runtimeRoutingSummary: runtimeSelection.routingSummary
                        ),
                        for: id
                    )
                    try Task.checkCancellation()
                    return (record, runtimeSelection.routingSummary)
                }
                guard !Task.isCancelled,
                      !self.hooks.isErasureInProgress(),
                      self.controlScope.acceptsControls else {
                    try await self.rollbackCreation(for: id)
                    return
                }
                messages[id] = queued.1
                start(record: queued.0)
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
        setupTasks[id] = setupTask
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

    // MARK: Controls

    func pause(_ id: TaskID) {
        guard records.contains(where: { $0.id == id }) else { return }
        guard controlScope.acceptsControls else { return }
        launchGate.cancel(id)
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

    func resume(_ id: TaskID) {
        launch(id)
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

    private func launch(_ id: TaskID, expectedRevision: UUID? = nil) {
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
            defer { self?.launchTasks[id] = nil }
            guard let self else { return }
#if DEBUG
            if let barrier = self.debugLaunchBarrier {
                await barrier()
            }
#endif
            guard let record = await self.runner.records().first(where: { $0.id == id }),
                  self.launchGate.contains(launchLease),
                  !Task.isCancelled,
                  !self.hooks.isErasureInProgress(),
                  self.controlScope.acceptsControls else {
                self.launchGate.release(launchLease)
                return
            }
            if let expectedRevision, record.revision != expectedRevision {
                self.messages[id] = "That approval request is no longer current"
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
        launchTasks[id] = launchTask
        guard controlScope.start({ @MainActor in
            await launchTask.value
        }) else {
            launchTask.cancel()
            launchGate.release(launchLease)
            return
        }
    }

    func resumeAll() {
        let ids = records
            .filter { $0.canResumeWorkspaceTask && !$0.checkpoint.isAwaitingApproval && !isRunning($0.id) }
            .map(\.id)
        ids.forEach(resume)
    }

    func cancel(_ id: TaskID, expectedRevision: UUID? = nil) {
        guard setupTasks[id] != nil
            || records.contains(where: { $0.id == id }) else { return }
        guard controlScope.acceptsControls else { return }
        if expectedRevision == nil {
            setupTasks[id]?.cancel()
        }
        messages[id] = "Stopping"
        _ = controlScope.start { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.runner.cancel(id: id, expectedRevision: expectedRevision)
            } catch {
                // Gone or already terminal — either way the task is finished
                // and there is nothing left to cancel.
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
        setupTasks[id]?.cancel()
        launchTasks[id]?.cancel()
        runTasks[id]?.cancel()
    }

    private func waitForOwnershipToEnd(_ id: TaskID) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: Self.joinTimeout)
        while setupTasks[id] != nil
            || launchTasks[id] != nil
            || runTasks[id] != nil {
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
        guard runTasks[id] == nil else { return }
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

    func replan(_ id: TaskID) {
        guard runTasks[id] == nil else { return }
        guard controlScope.acceptsControls else { return }
        _ = controlScope.start { @MainActor [weak self] in
            guard let self else { return }
            guard let record = await self.runner.records().first(where: { $0.id == id }),
                  case .legacy(let plan) = record.plan else { return }
            let goal = record.goal
            let preferredRuntimeID = plan.runtimeID
            do {
                try await self.runner.discard(id: id)
                try Self.removeWorkspace(for: id, root: self.workspaceRoot())
                try await self.contextStore.remove(for: id)
            } catch {
                self.messages[id] = "Couldn’t remove the saved task: \(error.localizedDescription)"
                return
            }
            self.refreshRecords()
            self.queue(goal: goal, preferredRuntimeID: preferredRuntimeID)
        }
    }

    @discardableResult
    private func start(
        record: TaskRecord,
        launchLease: BackgroundTaskLaunchLease? = nil
    ) -> Bool {
        guard controlScope.acceptsControls,
              !hooks.isErasureInProgress(),
              runTasks[record.id] == nil else { return false }
        if case .executable = record.plan {
            return startWorkspaceTask(record: record, launchLease: launchLease)
        }
        // Legacy-format records survive for inspection only. They can be
        // replanned as a new typed task or discarded — never executed.
        messages[record.id] = "This saved task uses a retired plan format. Replan or discard it."
        return false
    }

    private func launchIsCurrent(_ lease: BackgroundTaskLaunchLease?) -> Bool {
        guard let lease else { return true }
        return launchGate.contains(lease)
    }

    private func startWorkspaceTask(record: TaskRecord, launchLease: BackgroundTaskLaunchLease?) -> Bool {
        guard record.canResumeWorkspaceTask, case .executable(let plan) = record.plan else {
            messages[record.id] = "Review the file and approve its creation before running."
            return false
        }
        guard runTasks.count < Self.maximumConcurrentTasks else {
            messages[record.id] = "Queued until another background task finishes"
            return false
        }
        messages[record.id] = "Running approved file task"
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var reported = false
            var canAdvanceQueue = true
            do {
                try Task.checkCancellation()
                guard self.launchIsCurrent(launchLease), self.controlScope.acceptsControls, !self.hooks.isErasureInProgress() else { throw CancellationError() }
                let metadata = await self.contextStore.metadata(for: record.id)
                let progress: WorkspaceTaskProgress
                if record.canReportWorkspaceTask {
                    self.messages[record.id] = "Saving verified task report"
                    progress = .reported(try await self.runner.reportWorkspaceTask(record: record, history: self.transcriptStore, startedAt: metadata?.createdAt ?? Date()))
                } else {
                    let workspace = try self.workspaceURL(for: record.id, metadata: metadata)
                    progress = try await self.workers.withWorker(scope: .background, resources: [.workspace(workspace.standardizedFileURL.path)]) { _ in
                        try await self.runner.runWorkspaceTask(record: record, runtime: WorkspaceFileRuntime(baseURL: workspace), history: self.transcriptStore, startedAt: metadata?.createdAt ?? Date())
                    }
                }
                switch progress {
                case .awaitingApproval:
                    self.messages[record.id] = "Action verified. Review and approve the next action."
                case .reported:
                    reported = true
                    _ = await self.runner.takeReportedWorkspaceOutcome(for: plan.planID)
                    self.messages[record.id] = "Report saved to history"
                    try await self.contextStore.remove(for: record.id)
                }
            } catch {
                // A retained terminal record means the report already landed —
                // finishWorkspaceTask keeps evidence rows instead of removing
                // them, so "reported" is terminal-or-gone, not just gone.
                let recordIsFinished = await self.coordinator.record(id: record.id).map(\.isTerminal) ?? true
                if !reported, recordIsFinished,
                   await self.runner.takeReportedWorkspaceOutcome(for: plan.planID) != nil {
                    reported = true
                    do {
                        try await self.contextStore.remove(for: record.id)
                        self.messages[record.id] = "Report saved to history"
                    } catch {
                        self.messages[record.id] = "History saved, but metadata cleanup failed: \(error.localizedDescription)"
                    }
                } else {
                    self.messages[record.id] = reported
                        ? "History saved, but metadata cleanup failed: \(error.localizedDescription)"
                        : "Task stopped: \(error.localizedDescription). Review its saved state before retrying."
                }
                if !reported, let current = await self.coordinator.record(id: record.id),
                   current.revision == record.revision,
                   !current.cancellationRequested || current.canResumeWorkspaceTask {
                    do {
                        _ = try await self.coordinator.pause(id: record.id, expectedRevision: current.revision)
                    } catch TaskCoordinatorError.invalidTransition {
                    } catch {
                        canAdvanceQueue = false
                        self.messages[record.id] = "Could not save the paused task: \(error.localizedDescription). The queue is stopped until storage recovers."
                    }
                }
                if await self.coordinator.lastPersistenceError != nil {
                    canAdvanceQueue = false
                }
            }
            if let launchLease { self.launchGate.release(launchLease) }
            self.runTasks[record.id] = nil
            self.runningCount = self.runTasks.count
            await self.reloadRecords()
            if canAdvanceQueue { self.startQueuedTasks() }
        }
        runTasks[record.id] = task
        runningCount = runTasks.count
        return true
    }

    private func startQueuedTasks() {
        guard controlScope.acceptsControls else { return }
        guard runTasks.count < Self.maximumConcurrentTasks else { return }
        records
            .filter { $0.canStartAutomatically && runTasks[$0.id] == nil }
            .forEach { resume($0.id) }
    }

    private func handleOutcome(
        record: TaskRecord,
        metadata: BackgroundTaskMetadata?,
        outcome reportedOutcome: DoOutcome?
    ) async {
        let outcome: DoOutcome
        if let reportedOutcome {
            outcome = reportedOutcome
        } else {
            guard let currentRecord = await coordinator.record(id: record.id),
                  !currentRecord.isTerminal else {
                // Terminal records are retained receipts — already reported.
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
        // "Persisted" means a live record the user can still act on; retained
        // terminal receipts don't count — the task is done, its evidence stays.
        let persisted = await runner.records().contains { $0.id == record.id && !$0.isTerminal }
        switch outcome {
        case .completed:
            messages[record.id] = "Finished"
            await recordToTranscript(record: record, metadata: metadata, outcome: outcome)
            do {
                try await contextStore.remove(for: record.id)
            } catch {
                messages[record.id] = "Finished, but cleanup failed: \(error.localizedDescription)"
            }
        case .blocked(let reason):
            if persisted {
                messages[record.id] = "Paused: \(reason)"
            } else {
                messages[record.id] = "Stopped: \(reason)"
                await recordToTranscript(record: record, metadata: metadata, outcome: outcome)
                do {
                    try await contextStore.remove(for: record.id)
                } catch {
                    messages[record.id] = "Stopped, but cleanup failed: \(error.localizedDescription)"
                }
            }
        case .failed(let step, let reason):
            messages[record.id] = persisted
                ? "Paused after \(step): \(reason)"
                : "Failed at \(step): \(reason)"
            if !persisted {
                await recordToTranscript(record: record, metadata: metadata, outcome: outcome)
                do {
                    try await contextStore.remove(for: record.id)
                } catch {
                    messages[record.id] = "Failed, and cleanup also failed: \(error.localizedDescription)"
                }
            }
        }
        hooks.setStatus("Background task \(record.goal) \(messages[record.id]?.lowercased() ?? "updated").")
    }

    private func recordToTranscript(
        record: TaskRecord,
        metadata: BackgroundTaskMetadata?,
        outcome: DoOutcome
    ) async {
        let transcriptOutcome: TranscriptEntry.Outcome
        let summary: String
        let steps: [String]
        switch outcome {
        case .completed(let stepsRun):
            transcriptOutcome = .completed
            summary = "Finished \(stepsRun) step\(stepsRun == 1 ? "" : "s") in the background."
            steps = Array(record.plan.actionSummaries.prefix(stepsRun))
        case .blocked(let reason):
            transcriptOutcome = .stopped
            summary = "Stopped safely in the background: \(reason)."
            steps = Array(record.plan.actionSummaries.prefix(record.checkpoint.nextStepIndex))
        case .failed(let step, let reason):
            transcriptOutcome = .failed
            summary = "Stopped in the background at \(step): \(reason)."
            steps = Array(record.plan.actionSummaries.prefix(record.checkpoint.nextStepIndex))
        }
        let startedAt = metadata?.createdAt ?? Date()
        await transcriptStore.append(
            TranscriptEntry(
                request: record.goal,
                appBundleID: metadata?.targetAppBundleID,
                summary: summary,
                outcome: transcriptOutcome,
                startedAt: startedAt,
                finishedAt: Date(),
                steps: steps,
                verified: nil
            )
        )
    }

    // MARK: Workspaces

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
#if DEBUG
        if let override = storageDirectory() {
            return override.appendingPathComponent("BackgroundWorkspaces", isDirectory: true)
        }
#endif
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

    // MARK: Shutdown and erasure lifecycle

    func closeControls() {
        controlScope.close()
    }

    func reopenControls() {
        controlScope.reopen()
    }

    /// Pauses every owned record that can still be resumed, then cancels all
    /// live task handles. Runs before workers stop for erasure or termination.
    func pauseAllOwnedForWorkerStop() async throws {
        try await controlScope.closeAndDrain()
        let records = await runner.records()
        let ownedIDs = Set(runTasks.keys)
            .union(setupTasks.keys)
            .union(launchTasks.keys)
        for record in records where ownedIDs.contains(record.id) && !record.isTerminal && !record.cancellationRequested {
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
        for task in setupTasks.values { task.cancel() }
        for task in launchTasks.values { task.cancel() }
        for task in runTasks.values { task.cancel() }
    }

    /// Cancels every owned handle and the launch gate. Used on the erasure path.
    func cancelAllOwned() {
        for task in setupTasks.values { task.cancel() }
        for task in launchTasks.values { task.cancel() }
        for task in runTasks.values { task.cancel() }
        launchGate.cancelAll()
    }

    /// Awaits every owned handle; used after workers shut down.
    func joinAll() async {
        for task in Array(setupTasks.values) { await task.value }
        for task in Array(launchTasks.values) { await task.value }
        for task in Array(runTasks.values) { await task.value }
    }

    /// Drops all handles and clears the running count after a full stop.
    func resetTasks() {
        setupTasks.removeAll()
        launchTasks.removeAll()
        runTasks.removeAll()
        runningCount = 0
    }

#if DEBUG
    func debugSetLaunchBarrier(_ barrier: (@MainActor () async -> Void)?) {
        debugLaunchBarrier = barrier
    }

    func debugSeed(record: TaskRecord, metadata: BackgroundTaskMetadata) async throws {
        switch record.plan {
        case .legacy:
            throw ExecutionError(message: "legacy task records are read-only")
        case .executable(let plan):
            _ = try await coordinator.enqueue(executablePlan: plan)
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
            defer { self?.setupTasks[id] = nil }
            await operation()
        }
        setupTasks[id] = task
        return task
    }
#endif
}
