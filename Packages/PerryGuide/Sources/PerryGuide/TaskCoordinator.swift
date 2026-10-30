import Foundation
import PerryCore
import PerryRuntimes

public enum TaskCoordinatorError: LocalizedError, Equatable, Sendable {
    case duplicateID(TaskID)
    case capacityReached
    case invalidID
    case notFound(TaskID)
    case invalidCheckpoint(nextStepIndex: Int, stepCount: Int)
    case invalidTransition(id: TaskID, state: TaskLifecycleState)
    case invalidApproval(id: TaskID, stepID: String)
    case unsupportedExecutableAction(actionID: ActionID, reason: String)
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateID:
            return "This task is already saved. Refresh the task list before trying again."
        case .capacityReached:
            return "The saved-task limit has been reached. Finish or discard a task before adding another."
        case .invalidID:
            return "The task identifier is invalid. Create a new task."
        case .notFound:
            return "This task is no longer saved. Refresh the task list."
        case .invalidCheckpoint:
            return "The saved task position does not match its plan. Review the task before continuing."
        case .invalidTransition:
            return "The task cannot perform this action in its current state. Refresh the task list and review its status."
        case .invalidApproval:
            return "The approval does not match the pending action. Review the current action before approving it."
        case .unsupportedExecutableAction(let actionID, let reason):
            return "Cannot queue typed action '\(actionID.rawValue)': \(reason). The current executor supports only action-scoped UTF-8 file creation up to 8 MiB."
        case .persistenceFailed(let reason):
            return reason
        }
    }
}

public actor TaskCoordinator {
    public static let defaultMaximumTasks = 8

    public let maxTasks: Int

    private let fileURL: URL?
    private let fileManager: FileManager
    private var storedRecords: [TaskID: TaskRecord]
    private var writesBlocked: Bool
    private var persistenceIssue: PersistenceError?
    private let workspaceApprovals: ExecutionApprovalRegistry
    private var workspaceExecutions: [TaskID: (attemptID: UUID, task: Task<WorkspaceFileExecutionReceipt, Error>)] = [:]

    public init(
        maxTasks: Int = TaskCoordinator.defaultMaximumTasks,
        storageDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.init(
            maxTasks: maxTasks,
            storageFileURL: storageDirectory?.appendingPathComponent("tasks.json"),
            fileManager: fileManager
        )
    }

    public init(
        maxTasks: Int = TaskCoordinator.defaultMaximumTasks,
        fileURL: URL,
        fileManager: FileManager = .default
    ) {
        self.init(maxTasks: maxTasks, storageFileURL: fileURL, fileManager: fileManager)
    }

    private init(maxTasks: Int, storageFileURL: URL?, fileManager: FileManager) {
        precondition(maxTasks > 0)
        self.maxTasks = maxTasks
        self.fileURL = storageFileURL
        self.fileManager = fileManager
        let loaded = TaskStoreFile.load(
            from: storageFileURL,
            maximumTasks: maxTasks,
            fileManager: fileManager
        )
        self.storedRecords = loaded.records
        self.writesBlocked = loaded.writesBlocked
        self.persistenceIssue = loaded.persistenceIssue
        workspaceApprovals = ExecutionApprovalRegistry(restoringOwnedGrants: loaded.records.values.compactMap {
            guard $0.recoveryDisposition == .current, !$0.cancellationRequested,
                  let journal = $0.workspaceJournal,
                  let current = journal.current,
                  case .prepared(let attempt) = current else { return nil }
            return attempt.grant
        })
    }

    public var lastPersistenceError: PersistenceError? {
        persistenceIssue
    }

    @discardableResult
    public func enqueue(executablePlan: PerryRuntimes.ExecutionPlan) throws -> TaskRecord {
        let record = TaskRecord(executablePlan: executablePlan)
        try validateExecutablePlanForEnqueue(executablePlan)
        return try insert(record)
    }

    public func enqueue(agentPlan: AgentTaskPlan, taskID: TaskID = TaskID()) throws -> TaskRecord {
        try insert(TaskRecord(agentPlan: agentPlan, id: taskID))
    }

    @discardableResult
    public func beginAgentRun(id: TaskID, expectedRevision: UUID) throws -> TaskRecord {
        let record = try requireRecord(id)
        if record.revision != expectedRevision {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        guard case .agent = record.plan,
              !record.state.isTerminal, !record.cancellationRequested else {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        if record.state == .running { return record }
        return try replace(record.updating(state: .running))
    }

    private func insert(_ record: TaskRecord) throws -> TaskRecord {
        guard storedRecords[record.id] == nil else { throw TaskCoordinatorError.duplicateID(record.id) }
        var nextRecords = storedRecords
        if nextRecords.count >= maxTasks {
            for terminalID in nextRecords.values.filter(\.isTerminal).map(\.id).sorted(by: { $0.rawValue < $1.rawValue }) {
                nextRecords.removeValue(forKey: terminalID)
                if nextRecords.count < maxTasks { break }
            }
        }
        guard nextRecords.count < maxTasks else { throw TaskCoordinatorError.capacityReached }
        nextRecords[record.id] = record
        try save(nextRecords)
        return record
    }

    private func validateExecutablePlanForEnqueue(_ plan: PerryRuntimes.ExecutionPlan) throws {
        let workspaces = Set(plan.actions.compactMap { action -> String? in
            guard case .transform(let workspace, _) = action.operation else { return nil }
            return workspace.resolvingSymlinksInPath().standardizedFileURL.path
        })
        guard workspaces.count <= 1 else {
            throw TaskCoordinatorError.unsupportedExecutableAction(
                actionID: plan.actions[0].id,
                reason: "plan actions span more than one workspace"
            )
        }
        for action in plan.actions {
            guard case .transform(_, let command) = action.operation else {
                throw TaskCoordinatorError.unsupportedExecutableAction(
                    actionID: action.id,
                    reason: "this operation is not implemented by the workspace executor"
                )
            }
            guard action.approvalRequirement == .action else {
                throw TaskCoordinatorError.unsupportedExecutableAction(
                    actionID: action.id,
                    reason: "this action must use action-scoped approval"
                )
            }
            if case .createUTF8File(_, let contents) = command {
                guard contents.utf8.count <= WorkspaceFileRuntime.maximumFileCreationBytes else {
                    throw TaskCoordinatorError.unsupportedExecutableAction(
                        actionID: action.id,
                        reason: "its UTF-8 contents exceed the 8 MiB limit"
                    )
                }
            }
        }
    }

    public func record(id: TaskID) -> TaskRecord? {
        storedRecords[id]
    }

    public func remove(id: TaskID) throws {
        let record = try requireRecord(id)
        guard record.isTerminal else {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        var nextRecords = storedRecords
        nextRecords.removeValue(forKey: id)
        try save(nextRecords)
    }

    @discardableResult
    public func approveWorkspaceAction(id: TaskID, expectedRevision: UUID) async throws -> TaskRecord {
        try Task.checkCancellation()
        let record = try requireApprovalRecord(id, expectedRevision: expectedRevision)
        guard case .executable(let plan) = record.plan,
              record.checkpoint.inFlightStepID == nil else {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        if let journal = record.workspaceJournal, journal.current != nil {
            guard record.recoveryDisposition == .staleLegacyApproval,
                  case .prepared = journal.current else {
                throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
            }
        }
        let index = record.workspaceJournal?.completed.count ?? record.checkpoint.nextStepIndex
        guard plan.actions.indices.contains(index), index == record.checkpoint.nextStepIndex else {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        let action = plan.actions[index]
        guard case .transform(_, let command) = action.operation,
              action.approvalRequirement == .action else {
            throw TaskCoordinatorError.invalidApproval(id: id, stepID: action.id.rawValue)
        }
        if case .createUTF8File(_, let contents) = command,
           contents.utf8.count > WorkspaceFileRuntime.maximumFileCreationBytes {
            throw TaskCoordinatorError.invalidApproval(id: id, stepID: action.id.rawValue)
        }
        let grant = try await workspaceApprovals.issue(plan: plan, scope: .action(action.id))
        do {
            try Task.checkCancellation()
            let current = try requireApprovalRecord(id, expectedRevision: expectedRevision)
            let attempt = WorkspaceActionJournal.Attempt(actionIndex: index, grant: grant)
            let journal = WorkspaceExecutionJournal(
                completed: current.workspaceJournal?.completed ?? [],
                current: .prepared(attempt)
            )
            try journal.validate(plan: plan, checkpoint: journal.checkpoint)
            return try replace(current.updating(
                state: .ready,
                checkpoint: journal.checkpoint,
                intent: TaskIntent.none,
                recoveryDisposition: .current,
                workspaceJournal: journal
            ))
        } catch {
            await workspaceApprovals.revoke(id: grant.id)
            throw error
        }
    }

    @discardableResult
    public func reconcileWorkspaceAction(id: TaskID, expectedRevision: UUID) throws -> TaskRecord {
        let record = try requireRecord(id)
        guard fileURL != nil, record.revision == expectedRevision,
              record.recoveryDisposition == .restoredBackup,
              !record.isTerminal, !record.cancellationRequested,
              case .executable(let plan) = record.plan,
              let journal = record.workspaceJournal,
              case .prepared = journal.current else {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        let reconciledJournal = WorkspaceExecutionJournal(completed: journal.completed, current: nil)
        try reconciledJournal.validate(plan: plan, checkpoint: reconciledJournal.checkpoint)
        return try replace(record.updating(
            state: .ready,
            checkpoint: reconciledJournal.checkpoint,
            intent: TaskIntent.none,
            recoveryDisposition: .current,
            workspaceJournal: reconciledJournal
        ))
    }

    @discardableResult
    public func beginWorkspaceDispatch(id: TaskID, expectedRevision: UUID) throws -> TaskRecord {
        let record = try requireWorkspaceRecord(id, expectedRevision: expectedRevision)
        guard case .executable(let plan) = record.plan,
              (record.state == .ready && record.intent == .none) || (record.state == .paused && record.intent == .pause),
              let journal = record.workspaceJournal,
              case .prepared(let attempt) = journal.current else {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        try journal.validate(plan: plan, checkpoint: record.checkpoint)
        do {
            try attempt.grant.validateForExecution()
        } catch {
            _ = try replace(record.updating(
                state: .ready,
                intent: TaskIntent.none,
                recoveryDisposition: .staleLegacyApproval
            ))
            throw error
        }
        let dispatched = WorkspaceExecutionJournal(completed: journal.completed, current: .dispatched(attempt))
        try dispatched.validate(plan: plan, checkpoint: dispatched.checkpoint)
        let remainsPaused = record.state == .paused && record.intent == .pause
        return try replace(record.updating(
            state: remainsPaused ? .paused : .running,
            checkpoint: dispatched.checkpoint,
            intent: remainsPaused ? .pause : TaskIntent.none,
            workspaceJournal: dispatched
        ))
    }

    @discardableResult
    public func executeWorkspaceAction(
        id: TaskID,
        expectedRevision: UUID,
        runtime: WorkspaceFileRuntime
    ) async throws -> TaskRecord {
        try Task.checkCancellation()
        let dispatched = try beginWorkspaceDispatch(id: id, expectedRevision: expectedRevision)
        guard case .executable(let plan) = dispatched.plan,
              let dispatchedJournal = dispatched.workspaceJournal,
              case .dispatched(let attempt) = dispatchedJournal.current else {
            throw TaskCoordinatorError.invalidTransition(id: id, state: dispatched.state)
        }
        let approvals = workspaceApprovals
        let execution = Task {
            try await runtime.execute(
                plan: plan, actionID: plan.actions[attempt.actionIndex].id,
                grantID: attempt.grant.id, registry: approvals
            )
        }
        workspaceExecutions[id] = (attempt.id, execution)
        defer {
            if workspaceExecutions[id]?.attemptID == attempt.id { workspaceExecutions[id] = nil }
        }
        do {
            let receipt = try await withTaskCancellationHandler {
                try await execution.value
            } onCancel: {
                execution.cancel()
            }
            let current = try requireRecord(id)
            guard case .executable = current.plan,
                  let currentJournal = current.workspaceJournal,
                  case .dispatched(let active) = currentJournal.current,
                  active.id == attempt.id else {
                throw TaskCoordinatorError.invalidTransition(id: id, state: current.state)
            }
            let journal = WorkspaceExecutionJournal(
                completed: currentJournal.completed + [
                    WorkspaceExecutionJournal.CompletedAction(attempt: attempt, receipt: receipt)
                ],
                current: nil
            )
            try journal.validate(plan: plan, checkpoint: journal.checkpoint)
            let complete = journal.completed.count == plan.actions.count
            let remainsCancelled = current.cancellationRequested
            let remainsPaused = current.state == .paused || current.intent == .pause
            let verified = try replace(current.updating(
                state: complete && !remainsCancelled && !remainsPaused ? .ready : .paused,
                checkpoint: journal.checkpoint,
                intent: remainsCancelled ? .cancel : (remainsPaused || !complete ? .pause : TaskIntent.none),
                workspaceJournal: journal
            ))
            await workspaceApprovals.revoke(id: attempt.grant.id)
            return verified
        } catch {
            if let current = storedRecords[id],
               let journal = current.workspaceJournal,
               case .dispatched(let active) = journal.current,
               active.id == attempt.id {
                do {
                    _ = try replace(current.updating(state: .paused, intent: current.cancellationRequested ? .cancel : .pause))
                } catch let persistenceError {
                    throw TaskCoordinatorError.persistenceFailed("\(error); could not retain stopped action: \(persistenceError)")
                }
            }
            throw error
        }
    }

    private func requireWorkspaceRecord(_ id: TaskID, expectedRevision: UUID) throws -> TaskRecord {
        let record = try requireRecord(id)
        guard fileURL != nil, record.revision == expectedRevision,
              record.recoveryDisposition == .current, !record.isTerminal,
              !record.cancellationRequested, case .executable = record.plan else {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        return record
    }

    private func requireApprovalRecord(_ id: TaskID, expectedRevision: UUID) throws -> TaskRecord {
        let record = try requireRecord(id)
        guard fileURL != nil, record.revision == expectedRevision,
              !record.isTerminal, !record.cancellationRequested,
              case .executable = record.plan else {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        if record.recoveryDisposition != .current {
            guard record.recoveryDisposition == .staleLegacyApproval,
                  case .prepared = record.workspaceJournal?.current else {
                throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
            }
        }
        return record
    }

    @discardableResult
    public func finishWorkspaceTask(id: TaskID, expectedRevision: UUID) throws -> DoOutcome {
        let outcome = try workspaceReportOutcome(id: id, expectedRevision: expectedRevision)
        let record = try requireRecord(id)
        guard record.workspaceJournal?.completed.isEmpty == false else {
            var remaining = storedRecords
            remaining.removeValue(forKey: id)
            try save(remaining)
            return outcome
        }
        let terminal: TaskLifecycleState
        switch outcome {
        case .completed: terminal = .completed
        case .blocked, .failed: terminal = .blocked
        }
        _ = try replace(record.updating(state: terminal, intent: TaskIntent.none))
        return outcome
    }

    public func workspaceReportOutcome(id: TaskID, expectedRevision: UUID) throws -> DoOutcome {
        let record = try requireRecord(id)
        guard fileURL != nil, record.revision == expectedRevision,
              record.recoveryDisposition == .current, !record.isTerminal,
              case .executable(let plan) = record.plan,
              let journal = record.workspaceJournal,
              journal.current == nil,
              journal.completed.count == record.checkpoint.nextStepIndex,
              !record.requiresReconciliation, workspaceExecutions[id] == nil else {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        try journal.validate(plan: plan, checkpoint: record.checkpoint)
        if journal.completed.count == plan.actions.count {
            return .completed(stepsRun: plan.actions.count)
        }
        guard record.cancellationRequested, !journal.completed.isEmpty else {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        return .blocked(reason: "user cancelled the task")
    }

    public func records() -> [TaskRecord] {
        storedRecords.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    @discardableResult
    public func recoverInterruptedRuns() throws -> [TaskRecord] {
        var nextRecords = storedRecords
        var changed = false
        for record in storedRecords.values where record.state == .running {
            let intent: TaskIntent = record.cancellationRequested ? .cancel : .pause
            nextRecords[record.id] = record.updating(state: .paused, intent: intent)
            changed = true
        }
        if changed {
            try save(nextRecords)
        }
        return nextRecords.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    @discardableResult
    public func pause(id: TaskID, expectedRevision: UUID? = nil) throws -> TaskRecord {
        let record = try requireRecord(id)
        if let expectedRevision, record.revision != expectedRevision {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        guard !record.state.isTerminal, record.intent != .cancel || record.canResumeWorkspaceTask else {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        if record.state == .paused {
            return record
        }
        return try replace(record.updating(state: .paused, intent: record.cancellationRequested ? .cancel : .pause))
    }

    @discardableResult
    public func queueWorkspaceReport(id: TaskID, expectedRevision: UUID) throws -> TaskRecord {
        let record = try requireRecord(id)
        _ = try workspaceReportOutcome(id: id, expectedRevision: expectedRevision)
        return try replace(record.updating(
            state: .ready,
            intent: record.cancellationRequested ? .cancel : TaskIntent.none
        ))
    }

    @discardableResult
    public func requestCancellation(id: TaskID, expectedRevision: UUID? = nil) async throws -> TaskRecord {
        let mutation = try markCancellationRequested(id: id, expectedRevision: expectedRevision)
        if let grantID = mutation.grantID {
            await workspaceApprovals.revoke(id: grantID)
        }
        return mutation.record
    }

    private func markCancellationRequested(
        id: TaskID,
        expectedRevision: UUID? = nil
    ) throws -> (record: TaskRecord, grantID: UUID?) {
        let record = try requireRecord(id)
        if let expectedRevision, record.revision != expectedRevision {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        guard !record.state.isTerminal else {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        let mutation: (record: TaskRecord, grantID: UUID?)
        if case .executable(let plan) = record.plan,
           let journal = record.workspaceJournal,
           let current = journal.current {
            let cleared: WorkspaceExecutionJournal
            let state: TaskLifecycleState
            switch current {
            case .prepared:
                cleared = WorkspaceExecutionJournal(completed: journal.completed, current: nil)
                state = .paused
            case .dispatched:
                cleared = journal
                state = record.state
            }
            try cleared.validate(plan: plan, checkpoint: cleared.checkpoint)
            let cancelled = try replace(record.updating(
                state: state,
                checkpoint: cleared.checkpoint,
                intent: .cancel,
                workspaceJournal: cleared
            ))
            mutation = (cancelled, current.attempt.grant.id)
        } else {
            let cancellationState: TaskLifecycleState
            if case .executable = record.plan, record.workspaceJournal != nil {
                cancellationState = .paused
            } else {
                cancellationState = record.state
            }
            let cancelled = record.cancellationRequested
                ? record
                : try replace(record.updating(state: cancellationState, intent: .cancel))
            mutation = (cancelled, nil)
        }
        workspaceExecutions[id]?.task.cancel()
        return mutation
    }

    @discardableResult
    public func finish(id: TaskID, outcome: DoOutcome) throws -> DoOutcome {
        let record = try requireRecord(id)
        if case .executable = record.plan {
            guard !record.requiresReconciliation, workspaceExecutions[id] == nil else {
                throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
            }
            if let journal = record.workspaceJournal,
               journal.current != nil || !journal.completed.isEmpty {
                throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
            }
        }
        guard !record.state.isTerminal else {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        if case .completed = outcome, record.recoveryDisposition != .current {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        if case .completed = outcome, case .executable = record.plan {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        if record.cancellationRequested, case .completed = outcome {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        if case .completed(let stepsRun) = outcome,
           !(0...record.plan.actionCount).contains(stepsRun) {
            throw TaskCoordinatorError.invalidCheckpoint(
                nextStepIndex: stepsRun,
                stepCount: record.plan.actionCount
            )
        }

        var nextRecords = storedRecords
        nextRecords.removeValue(forKey: id)
        try save(nextRecords)
        return outcome
    }

    @discardableResult
    public func finishCancellation(
        id: TaskID,
        reason: String,
        expectedRevision: UUID? = nil
    ) throws -> DoOutcome {
        let record = try requireRecord(id)
        if let expectedRevision, record.revision != expectedRevision {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        guard !record.state.isTerminal, record.cancellationRequested else {
            throw TaskCoordinatorError.invalidTransition(id: id, state: record.state)
        }
        let outcome = DoOutcome.blocked(reason: reason)
        let hasCompletedEvidence = record.workspaceJournal?.completed.isEmpty == false
        guard record.requiresReconciliation || workspaceExecutions[id] != nil || hasCompletedEvidence else {
            return try finish(id: id, outcome: outcome)
        }
        if record.state != .paused {
            _ = try replace(record.updating(state: .paused))
        }
        return outcome
    }

    @discardableResult
    public func cancel(id: TaskID, reason: String = "user cancelled the task") async throws -> DoOutcome {
        if case .executable = try requireRecord(id).plan {
            let mutation = try markCancellationRequested(id: id)
            let outcome = Result { try finishCancellation(id: id, reason: reason) }
            if let grantID = mutation.grantID {
                await workspaceApprovals.revoke(id: grantID)
            }
            return try outcome.get()
        }
        return try finish(id: id, outcome: .blocked(reason: reason))
    }

    private func requireRecord(_ id: TaskID) throws -> TaskRecord {
        guard let record = storedRecords[id] else {
            throw TaskCoordinatorError.notFound(id)
        }
        return record
    }

    private func replace(_ record: TaskRecord) throws -> TaskRecord {
        var nextRecords = storedRecords
        nextRecords[record.id] = record
        try save(nextRecords)
        return record
    }

    private func save(_ records: [TaskID: TaskRecord]) throws {
        do {
            try persist(records)
            storedRecords = records
        } catch let error as PersistenceError {
            persistenceIssue = error
            throw TaskCoordinatorError.persistenceFailed(error.localizedDescription)
        } catch {
            let issue = PersistenceError.writeFailed(
                path: fileURL?.path ?? "in-memory",
                reason: error.localizedDescription
            )
            persistenceIssue = issue
            throw TaskCoordinatorError.persistenceFailed(issue.localizedDescription)
        }
    }

    private func persist(_ records: [TaskID: TaskRecord]) throws {
        guard let fileURL else {
            persistenceIssue = nil
            return
        }
        if writesBlocked {
            if fileManager.fileExists(atPath: fileURL.path) || fileManager.fileExists(atPath: fileURL.appendingPathExtension("backup").path) {
                throw persistenceIssue ?? PersistenceError.writeFailed(
                    path: fileURL.path,
                    reason: "writes are blocked while the persistence file is unavailable"
                )
            }
            writesBlocked = false
        }
        try TaskStoreFile.write(records, to: fileURL, maximumTasks: maxTasks, fileManager: fileManager)
        persistenceIssue = nil
    }
}
