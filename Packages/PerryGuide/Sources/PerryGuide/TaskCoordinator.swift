import Foundation
import PerryCore
import PerryRuntimes

public typealias TaskID = PerryCore.TaskID

public enum TaskLifecycleState: String, Codable, Equatable, Sendable {
    case queued
    case ready
    case running
    case paused
    case completed
    case blocked
    case failed

    public var isTerminal: Bool {
        switch self {
        case .completed, .blocked, .failed:
            return true
        case .queued, .ready, .running, .paused:
            return false
        }
    }
}

public enum TaskIntent: String, Codable, Equatable, Sendable {
    case none
    case pause
    case cancel
}

public struct TaskCheckpoint: Codable, Equatable, Sendable {
    public let nextStepIndex: Int
    public let inFlightStepID: String?
    public let suspendedStepID: String?

    public init(
        nextStepIndex: Int = 0,
        inFlightStepID: String? = nil,
        suspendedStepID: String? = nil
    ) {
        self.nextStepIndex = nextStepIndex
        self.inFlightStepID = inFlightStepID
        self.suspendedStepID = suspendedStepID
    }

    public var hasUncertainSideEffect: Bool {
        inFlightStepID != nil
    }

    public var isAwaitingApproval: Bool {
        suspendedStepID != nil
    }

    public var suspendedActionID: String? {
        suspendedStepID
    }
}

public enum TaskRecoveryDisposition: String, Codable, Equatable, Sendable {
    case current
    case restoredBackup
    case staleLegacyApproval
}

public struct TaskRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: TaskID
    public let revision: UUID
    public let plan: TaskPlan
    public let state: TaskLifecycleState
    public let checkpoint: TaskCheckpoint
    public let intent: TaskIntent
    public let recoveryDisposition: TaskRecoveryDisposition
    public let workspaceJournal: WorkspaceExecutionJournal?

    public var goal: String {
        plan.goal
    }

    public var pauseRequested: Bool {
        intent == .pause
    }

    public var cancellationRequested: Bool {
        intent == .cancel
    }

    public var isTerminal: Bool {
        state.isTerminal
    }

    public var requiresReconciliation: Bool {
        checkpoint.hasUncertainSideEffect
            || recoveryDisposition == .restoredBackup
            || recoveryDisposition == .staleLegacyApproval
    }

    public var workspaceActionToApprove: ExecutableAction? {
        guard !isTerminal, !cancellationRequested,
              recoveryDisposition == .current || recoveryDisposition == .staleLegacyApproval,
              case .executable(let plan) = plan,
              plan.actions.indices.contains(checkpoint.nextStepIndex),
              checkpoint.inFlightStepID == nil,
              checkpoint.suspendedStepID == nil else { return nil }
        let action = plan.actions[checkpoint.nextStepIndex]
        guard action.approvalRequirement == .action,
              case .transform = action.operation else { return nil }
        if let workspaceJournal {
            if recoveryDisposition == .staleLegacyApproval {
                guard case .prepared = workspaceJournal.current else { return nil }
            } else {
                guard workspaceJournal.current == nil,
                      workspaceJournal.completed.count == checkpoint.nextStepIndex else { return nil }
            }
        } else {
            guard checkpoint.nextStepIndex == 0 else { return nil }
        }
        return action
    }

    public var canResumeWorkspaceTask: Bool {
        if canReportWorkspaceTask {
            return true
        }
        guard !isTerminal, !requiresReconciliation, !cancellationRequested,
              case .executable = plan,
              let workspaceJournal,
              workspaceJournal.completed.count == checkpoint.nextStepIndex,
              case .prepared = workspaceJournal.current else { return false }
        return true
    }

    public var canReportWorkspaceTask: Bool {
        guard !isTerminal, !requiresReconciliation,
              case .executable(let plan) = plan,
              let workspaceJournal,
              workspaceJournal.current == nil,
              workspaceJournal.completed.count == checkpoint.nextStepIndex else { return false }
        if workspaceJournal.completed.count == plan.actions.count {
            return true
        }
        return cancellationRequested && !workspaceJournal.completed.isEmpty
    }

    /// Agent tasks resume by rerunning the goal on the task's thread — the
    /// model sees its earlier turn and continues — so any non-terminal,
    /// uncancelled record is safe to relaunch.
    public var canResumeAgentTask: Bool {
        guard !isTerminal, !requiresReconciliation, !cancellationRequested,
              case .agent = plan else { return false }
        return true
    }

    public var canStartAutomatically: Bool {
        state == .ready && canResumeWorkspaceTask
    }

    public init(executablePlan: PerryRuntimes.ExecutionPlan) {
        self.init(id: executablePlan.taskID, plan: .executable(executablePlan), state: .queued,
                  checkpoint: TaskCheckpoint(), intent: .none)
    }

    public init(agentPlan: AgentTaskPlan, id: TaskID = TaskID()) {
        self.init(id: id, plan: .agent(agentPlan), state: .queued,
                  checkpoint: TaskCheckpoint(), intent: .none)
    }

    public static func == (lhs: TaskRecord, rhs: TaskRecord) -> Bool {
        lhs.id == rhs.id && lhs.revision == rhs.revision
    }

    private init(
        id: TaskID,
        plan: TaskPlan,
        state: TaskLifecycleState,
        checkpoint: TaskCheckpoint,
        intent: TaskIntent,
        recoveryDisposition: TaskRecoveryDisposition = .current,
        revision: UUID = UUID(),
        workspaceJournal: WorkspaceExecutionJournal? = nil
    ) {
        self.id = id
        self.revision = revision
        self.plan = plan
        self.state = state
        self.checkpoint = checkpoint
        self.intent = intent
        self.recoveryDisposition = recoveryDisposition
        self.workspaceJournal = workspaceJournal
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case revision
        case planKind
        case executionPlan
        case workspaceJournal
        case goal
        case runtimeID
        case agentThreadID
        case steps
        case state
        case nextStepIndex
        case inFlightStepID
        case suspendedStepID
        case intent
        case recoveryDisposition
    }

    public init(from decoder: Decoder) throws {
        try self.init(from: decoder, storeVersion: 5)
    }

    fileprivate init(from decoder: Decoder, storeVersion: Int) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(TaskID.self, forKey: .id)
        let revision = storeVersion >= 3 ? try container.decode(UUID.self, forKey: .revision) : UUID()
        let kind = storeVersion >= 3 ? try container.decode(String.self, forKey: .planKind) : "legacy"
        let plan: TaskPlan
        switch kind {
        case "legacy":
            guard !container.contains(.executionPlan) else {
                throw DecodingError.dataCorruptedError(forKey: .executionPlan, in: container, debugDescription: "legacy task cannot contain an executable plan")
            }
            let goal = try container.decode(String.self, forKey: .goal)
            let runtimeID = try container.decode(String.self, forKey: .runtimeID)
            let storedSteps = try container.decode([PersistedTaskStep].self, forKey: .steps)
            plan = .legacy(Plan(goal: goal, runtimeID: runtimeID, steps: try storedSteps.map { try $0.makeStep(decoder: decoder) }))
        case "executable":
            guard !container.contains(.goal), !container.contains(.runtimeID), !container.contains(.steps) else {
                throw DecodingError.dataCorruptedError(forKey: .planKind, in: container, debugDescription: "executable task cannot contain legacy plan fields")
            }
            let executable = try container.decode(PerryRuntimes.ExecutionPlan.self, forKey: .executionPlan)
            guard executable.taskID == id else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "task and executable plan identities differ")
            }
            plan = .executable(executable)
        case "agent":
            guard !container.contains(.executionPlan), !container.contains(.runtimeID), !container.contains(.steps) else {
                throw DecodingError.dataCorruptedError(forKey: .planKind, in: container, debugDescription: "agent task cannot contain execution-plan fields")
            }
            let goal = try container.decode(String.self, forKey: .goal)
            let threadID = try container.decode(UUID.self, forKey: .agentThreadID)
            plan = .agent(AgentTaskPlan(goal: goal, threadID: threadID))
        default:
            throw DecodingError.dataCorruptedError(forKey: .planKind, in: container, debugDescription: "unknown task plan representation")
        }
        let state = try container.decode(TaskLifecycleState.self, forKey: .state)
        let nextStepIndex = try container.decode(Int.self, forKey: .nextStepIndex)
        guard (0...plan.actionCount).contains(nextStepIndex) else {
            throw DecodingError.dataCorruptedError(
                forKey: .nextStepIndex,
                in: container,
                debugDescription: "checkpoint is outside the plan"
            )
        }
        let inFlightStepID = try container.decodeIfPresent(String.self, forKey: .inFlightStepID)
        let suspendedStepID = try container.decodeIfPresent(String.self, forKey: .suspendedStepID)
        guard inFlightStepID == nil || suspendedStepID == nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .inFlightStepID,
                in: container,
                debugDescription: "a checkpoint cannot be in flight and awaiting approval"
            )
        }
        if let stepID = inFlightStepID ?? suspendedStepID {
            guard nextStepIndex < plan.actionCount, plan.actionIDs[nextStepIndex] == stepID else {
                throw DecodingError.dataCorruptedError(
                    forKey: inFlightStepID == nil ? .suspendedStepID : .inFlightStepID,
                    in: container,
                    debugDescription: "checkpoint step does not match the next plan step"
                )
            }
        }
        let intent = try container.decode(TaskIntent.self, forKey: .intent)
        let journal: WorkspaceExecutionJournal?
        if storeVersion >= 5 {
            journal = try container.decodeIfPresent(WorkspaceExecutionJournal.self, forKey: .workspaceJournal)
        } else if storeVersion >= 3 {
            if let legacyJournal = try container.decodeIfPresent(WorkspaceActionJournal.self, forKey: .workspaceJournal) {
                guard case .executable(let executable) = plan else {
                    throw DecodingError.dataCorruptedError(forKey: .workspaceJournal, in: container, debugDescription: "legacy task cannot contain a workspace journal")
                }
                journal = try WorkspaceExecutionJournal(
                    legacy: legacyJournal,
                    plan: executable,
                    checkpoint: TaskCheckpoint(nextStepIndex: nextStepIndex, inFlightStepID: inFlightStepID, suspendedStepID: suspendedStepID)
                )
            } else {
                journal = nil
            }
        } else {
            guard try container.decodeIfPresent(WorkspaceActionJournal.self, forKey: .workspaceJournal) == nil else {
                throw DecodingError.dataCorruptedError(forKey: .workspaceJournal, in: container, debugDescription: "legacy task cannot contain a workspace journal")
            }
            journal = nil
        }
        let checkpoint = TaskCheckpoint(nextStepIndex: nextStepIndex, inFlightStepID: inFlightStepID, suspendedStepID: suspendedStepID)
        if let journal {
            guard case .executable(let executable) = plan else {
                throw DecodingError.dataCorruptedError(forKey: .workspaceJournal, in: container, debugDescription: "legacy task cannot contain a workspace journal")
            }
            try journal.validate(plan: executable, checkpoint: checkpoint)
            let validLifecycle: Bool
            switch journal.current {
            case .prepared:
                validLifecycle = (state == .ready && (intent == .none || intent == .cancel))
                    || (state == .paused && (intent == .pause || intent == .cancel))
            case .dispatched:
                validLifecycle = (state == .running && (intent == .none || intent == .cancel))
                    || (state == .paused && (intent == .pause || intent == .cancel))
            case nil:
                let full = journal.completed.count == executable.actions.count
                // Terminal journaled records are the durable receipts Undo
                // reads: completed when every action verified, blocked when a
                // stopped run kept verified evidence.
                let terminal = full
                    ? (state == .completed || state == .blocked)
                    : (state == .blocked && !journal.completed.isEmpty)
                validLifecycle = terminal
                    || (full && ((state == .running && (intent == .none || intent == .cancel))
                        || (state == .ready && (intent == .none || intent == .cancel))
                        || (state == .paused && (intent == .pause || intent == .cancel))))
                    || (!full && ((state == .paused && (intent == .pause || intent == .cancel))
                        || (state == .running && (intent == .none || intent == .cancel))
                        || (state == .ready && (intent == .none || intent == .cancel))
                        || (state == .queued && journal.completed.isEmpty && (intent == .none || intent == .cancel))))
            }
            guard validLifecycle else {
                throw DecodingError.dataCorruptedError(forKey: .workspaceJournal, in: container, debugDescription: "workspace journal phase does not match task lifecycle")
            }
        } else if case .executable = plan, nextStepIndex != 0 || inFlightStepID != nil || suspendedStepID != nil {
            throw DecodingError.dataCorruptedError(forKey: .workspaceJournal, in: container, debugDescription: "executable checkpoint requires a journal")
        }
        let decodedRecoveryDisposition = storeVersion == 1
            ? (try container.decodeIfPresent(TaskRecoveryDisposition.self, forKey: .recoveryDisposition) ?? .current)
            : try container.decode(TaskRecoveryDisposition.self, forKey: .recoveryDisposition)
        let staleLegacyApproval = journal?.current?.attempt.grant.requiresReapproval == true
        let recoveryDisposition: TaskRecoveryDisposition
        if decodedRecoveryDisposition == .restoredBackup || checkpoint.hasUncertainSideEffect {
            recoveryDisposition = decodedRecoveryDisposition
        } else if staleLegacyApproval {
            recoveryDisposition = .staleLegacyApproval
        } else {
            recoveryDisposition = decodedRecoveryDisposition
        }
        self.init(
            id: id,
            plan: plan,
            state: state,
            checkpoint: checkpoint,
            intent: intent,
            recoveryDisposition: recoveryDisposition,
            revision: revision,
            workspaceJournal: journal
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(revision, forKey: .revision)
        switch plan {
        case .legacy(let legacy):
            try container.encode("legacy", forKey: .planKind)
            try container.encode(legacy.goal, forKey: .goal)
            try container.encode(legacy.runtimeID, forKey: .runtimeID)
            try container.encode(legacy.steps.map(PersistedTaskStep.init), forKey: .steps)
        case .executable(let executable):
            try container.encode("executable", forKey: .planKind)
            try container.encode(executable, forKey: .executionPlan)
        case .agent(let agent):
            try container.encode("agent", forKey: .planKind)
            try container.encode(agent.goal, forKey: .goal)
            try container.encode(agent.threadID, forKey: .agentThreadID)
        }
        try container.encode(state, forKey: .state)
        try container.encode(checkpoint.nextStepIndex, forKey: .nextStepIndex)
        try container.encodeIfPresent(checkpoint.inFlightStepID, forKey: .inFlightStepID)
        try container.encodeIfPresent(checkpoint.suspendedStepID, forKey: .suspendedStepID)
        try container.encode(intent, forKey: .intent)
        try container.encode(recoveryDisposition, forKey: .recoveryDisposition)
        try container.encodeIfPresent(workspaceJournal, forKey: .workspaceJournal)
    }

    fileprivate func updating(
        state: TaskLifecycleState? = nil,
        checkpoint: TaskCheckpoint? = nil,
        intent: TaskIntent? = nil,
        recoveryDisposition: TaskRecoveryDisposition? = nil,
        workspaceJournal: WorkspaceExecutionJournal? = nil
    ) -> TaskRecord {
        TaskRecord(
            id: id,
            plan: plan,
            state: state ?? self.state,
            checkpoint: checkpoint ?? self.checkpoint,
            intent: intent ?? self.intent,
            recoveryDisposition: recoveryDisposition ?? self.recoveryDisposition,
            workspaceJournal: workspaceJournal ?? self.workspaceJournal
        )
    }
}

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
        let loaded = Self.loadRecords(
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

    /// Open-ended goals carry no typed steps: the unattended agent turn
    /// decides tool calls at run time and the task's thread holds the
    /// transcript. Nothing about the goal is validated here — the agent
    /// surface decides what it can do, and unattended runs fail closed on
    /// any action that would need a person to approve it.
    public func enqueue(agentPlan: AgentTaskPlan, taskID: TaskID = TaskID()) throws -> TaskRecord {
        try insert(TaskRecord(agentPlan: agentPlan, id: taskID))
    }

    /// Marks an agent task running. Agent runs checkpoint at the turn rather
    /// than the step — the only lifecycle they need is queued → running →
    /// finish — so this is the single transition issued before the turn
    /// starts consuming the record.
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
        // Retained terminal records are receipts, not queued work — evict them
        // before telling the user the queue is full.
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
        // The durable queue executes through the workspace runtime bound to a
        // single workspace — every transform must claim the same one.
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

    /// Removes a retained terminal record outright — the user deleting a
    /// finished row's receipts. Live records must go through cancel instead.
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
        // Records carrying verified receipts stay in the store as terminal
        // rows — they are the durable evidence Undo reads. Records with no
        // completed actions leave nothing to undo and are removed.
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

        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw PersistenceError.createDirectoryFailed(
                path: directory.path,
                reason: error.localizedDescription
            )
        }

        let payload = PersistedTaskStore(tasks: records.values.sorted { $0.id.rawValue < $1.id.rawValue })
        let data: Data
        do {
            _ = try payload.validatedRecords(maximumTasks: maxTasks)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(payload)
        } catch {
            throw PersistenceError.encodeFailed(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }

        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                let backupURL = fileURL.appendingPathExtension("backup")
                if fileManager.fileExists(atPath: backupURL.path) {
                    do {
                        let backup = try Data(contentsOf: backupURL)
                        let store = try JSONDecoder().decode(PersistedTaskStore.self, from: backup)
                        _ = try store.validatedRecords(maximumTasks: nil)
                    } catch {
                        throw PersistenceError.readFailed(path: backupURL.path, reason: error.localizedDescription)
                    }
                }
                try Data(contentsOf: fileURL).write(to: backupURL, options: .atomic)
            }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw PersistenceError.writeFailed(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
        persistenceIssue = nil
    }

    private static func loadRecords(
        from fileURL: URL?,
        maximumTasks: Int,
        fileManager: FileManager
    ) -> LoadResult {
        guard let fileURL else {
            return LoadResult(records: [:], writesBlocked: false, persistenceIssue: nil)
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            guard fileManager.fileExists(atPath: fileURL.appendingPathExtension("backup").path) else {
                return LoadResult(records: [:], writesBlocked: false, persistenceIssue: nil)
            }
            return recoverCorruptFileOrRestoreBackup(
                at: fileURL, reason: "primary task file is missing",
                maximumTasks: maximumTasks, fileManager: fileManager
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return recoverCorruptFileOrRestoreBackup(
                at: fileURL,
                reason: "read failed: \(error.localizedDescription)",
                maximumTasks: maximumTasks,
                fileManager: fileManager
            )
        }

        do {
            let payload = try JSONDecoder().decode(PersistedTaskStore.self, from: data)
            return LoadResult(
                records: try payload.validatedRecords(maximumTasks: maximumTasks),
                writesBlocked: false,
                persistenceIssue: nil
            )
        } catch TaskPersistenceValidationError.unsupportedVersion(let version) {
            return LoadResult(records: [:], writesBlocked: true, persistenceIssue: .readFailed(
                path: fileURL.path, reason: "Task format version \(version) is unsupported. Open this data with a compatible Perry version."
            ))
        } catch {
            return recoverCorruptFileOrRestoreBackup(
                at: fileURL,
                reason: error.localizedDescription,
                maximumTasks: maximumTasks,
                fileManager: fileManager
            )
        }
    }

    private static func recoverCorruptFileOrRestoreBackup(
        at fileURL: URL,
        reason: String,
        maximumTasks: Int,
        fileManager: FileManager
    ) -> LoadResult {
        let recovered = fileManager.fileExists(atPath: fileURL.path)
            ? recoverCorruptFile(at: fileURL, reason: reason, fileManager: fileManager)
            : LoadResult(records: [:], writesBlocked: false, persistenceIssue: .readFailed(path: fileURL.path, reason: reason))
        guard !recovered.writesBlocked else { return recovered }
        let backupURL = fileURL.appendingPathExtension("backup")
        guard fileManager.fileExists(atPath: backupURL.path) else { return recovered }

        let backupData: Data
        let records: [TaskID: TaskRecord]
        do {
            backupData = try Data(contentsOf: backupURL)
            let payload = try JSONDecoder().decode(PersistedTaskStore.self, from: backupData)
            records = try payload.validatedRecords(maximumTasks: maximumTasks).mapValues {
                $0.updating(
                    state: .paused,
                    intent: $0.cancellationRequested ? .cancel : .pause,
                    recoveryDisposition: .restoredBackup
                )
            }
        } catch TaskPersistenceValidationError.unsupportedVersion(let version) {
            return LoadResult(records: [:], writesBlocked: true, persistenceIssue: .readFailed(
                path: backupURL.path, reason: "Task backup format version \(version) is unsupported. Open this data with a compatible Perry version."
            ))
        } catch {
            let backupRecovery = recoverCorruptFile(
                at: backupURL,
                reason: error.localizedDescription,
                fileManager: fileManager
            )
            return LoadResult(
                records: [:],
                writesBlocked: backupRecovery.writesBlocked,
                persistenceIssue: backupRecovery.persistenceIssue
            )
        }
        do {
            let restored = PersistedTaskStore(tasks: records.values.sorted { $0.id.rawValue < $1.id.rawValue })
            let restoredData = try JSONEncoder().encode(restored)
            try restoredData.write(to: fileURL, options: .atomic)
            return LoadResult(
                records: records,
                writesBlocked: false,
                persistenceIssue: recovered.persistenceIssue
            )
        } catch {
            return LoadResult(
                records: records,
                writesBlocked: true,
                persistenceIssue: .writeFailed(path: fileURL.path, reason: error.localizedDescription)
            )
        }
    }

    private static func recoverCorruptFile(
        at fileURL: URL,
        reason: String,
        fileManager: FileManager
    ) -> LoadResult {
        let quarantineURL = fileURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
        do {
            try fileManager.moveItem(at: fileURL, to: quarantineURL)
            return LoadResult(
                records: [:],
                writesBlocked: false,
                persistenceIssue: .recoveredCorruptFile(
                    path: fileURL.path,
                    quarantinePath: quarantineURL.path,
                    reason: reason
                )
            )
        } catch {
            return LoadResult(
                records: [:],
                writesBlocked: true,
                persistenceIssue: .quarantineFailed(
                    path: fileURL.path,
                    reason: error.localizedDescription
                )
            )
        }
    }

    private struct LoadResult {
        let records: [TaskID: TaskRecord]
        let writesBlocked: Bool
        let persistenceIssue: PersistenceError?
    }

    fileprivate enum TaskPersistenceValidationError: Error, LocalizedError {
        case unsupportedVersion(Int)
        case tooManyTasks(limit: Int, actual: Int)
        case duplicateID(TaskID)
        case terminalTask(TaskID)
        case invalidState(TaskID, String)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "unsupported task persistence version \(version)"
            case .tooManyTasks(let limit, let actual):
                return "task persistence contains \(actual) tasks, maximum is \(limit)"
            case .duplicateID(let id):
                return "task persistence contains duplicate task ID \(id)"
            case .terminalTask(let id):
                return "task persistence contains terminal task \(id)"
            case .invalidState(let id, let reason):
                return "task \(id) has invalid persisted state: \(reason)"
            }
        }
    }
}

private struct PersistedTaskStep: Codable, Equatable {
    let id: String
    let kind: String
    let summary: String
    let payload: [String: String]

    init(_ step: Step) {
        id = step.id
        kind = step.kind.rawValue
        summary = step.summary
        payload = step.payload
    }

    func makeStep(decoder: Decoder) throws -> Step {
        guard let kind = Step.Kind(rawValue: kind) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown task step kind \(kind)")
            )
        }
        return Step(id: id, kind: kind, summary: summary, payload: payload)
    }
}

private struct PersistedTaskStore: Codable {
    static let currentVersion = 5

    let version: Int
    let tasks: [TaskRecord]

    private enum CodingKeys: String, CodingKey {
        case version
        case tasks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard (1...Self.currentVersion).contains(version) else {
            throw TaskCoordinator.TaskPersistenceValidationError.unsupportedVersion(version)
        }
        var storedTasks = try container.nestedUnkeyedContainer(forKey: .tasks)
        var decodedTasks: [TaskRecord] = []
        while !storedTasks.isAtEnd {
            decodedTasks.append(try TaskRecord(from: storedTasks.superDecoder(), storeVersion: version))
        }
        tasks = decodedTasks
    }

    init(tasks: [TaskRecord]) {
        version = Self.currentVersion
        self.tasks = tasks
    }

    func validatedRecords(maximumTasks: Int?) throws -> [TaskID: TaskRecord] {
        guard (1...Self.currentVersion).contains(version) else {
            throw TaskCoordinator.TaskPersistenceValidationError.unsupportedVersion(version)
        }
        if let maximumTasks, tasks.count > maximumTasks {
            throw TaskCoordinator.TaskPersistenceValidationError.tooManyTasks(
                limit: maximumTasks,
                actual: tasks.count
            )
        }

        var records: [TaskID: TaskRecord] = [:]
        var approvalIDs: Set<UUID> = []
        for record in tasks {
            guard records[record.id] == nil else {
                throw TaskCoordinator.TaskPersistenceValidationError.duplicateID(record.id)
            }
            if let journal = record.workspaceJournal {
                let grantIDs = journal.completed.map { $0.attempt.grant.id }
                    + (journal.current.map { [$0.attempt.grant.id] } ?? [])
                for grantID in grantIDs where !approvalIDs.insert(grantID).inserted {
                    throw TaskCoordinator.TaskPersistenceValidationError.invalidState(record.id, "approval identity is reused across tasks")
                }
            }
            try validate(record)
            records[record.id] = record
        }
        return records
    }

    private func validate(_ record: TaskRecord) throws {
        switch record.state {
        case .ready:
            guard case .executable = record.plan,
                  record.workspaceJournal != nil, !record.checkpoint.hasUncertainSideEffect,
                  record.intent == .none || record.intent == .cancel,
                  record.checkpoint.inFlightStepID == nil,
                  record.checkpoint.suspendedStepID == nil else {
                throw TaskCoordinator.TaskPersistenceValidationError.invalidState(record.id, "ready tasks require an approved action or verified receipt")
            }
        case .queued:
            guard record.intent == .none || record.intent == .cancel,
                  record.checkpoint.nextStepIndex == 0,
                  record.checkpoint.inFlightStepID == nil,
                  record.checkpoint.suspendedStepID == nil else {
                throw TaskCoordinator.TaskPersistenceValidationError.invalidState(
                    record.id,
                    "queued tasks must have no pause intent or active checkpoint"
                )
            }
        case .running:
            guard record.intent == .none || record.intent == .cancel,
                  record.checkpoint.suspendedStepID == nil else {
                throw TaskCoordinator.TaskPersistenceValidationError.invalidState(
                    record.id,
                    "running tasks cannot await approval"
                )
            }
            if case .executable = record.plan {
                let validDispatched = record.workspaceJournal?.current.map { current in
                    if case .dispatched = current { return true }
                    return false
                } == true
                let validPrefix = record.workspaceJournal?.current == nil
                    && record.workspaceJournal?.completed.isEmpty == false
                guard validDispatched || validPrefix else {
                    throw TaskCoordinator.TaskPersistenceValidationError.invalidState(
                        record.id,
                        "running executable tasks require a dispatched action or reportable prefix"
                    )
                }
            }
        case .paused:
            guard record.intent == .pause || record.intent == .cancel else {
                throw TaskCoordinator.TaskPersistenceValidationError.invalidState(
                    record.id,
                    "paused tasks must be paused or cancelled"
                )
            }
        case .completed, .blocked:
            // Retained terminal records are the durable receipts Undo reads:
            // a fully-settled journal, no in-flight attempt, no live intent.
            guard let journal = record.workspaceJournal else {
                throw TaskCoordinator.TaskPersistenceValidationError.invalidState(record.id, "terminal record without journal")
            }
            guard journal.current == nil else {
                throw TaskCoordinator.TaskPersistenceValidationError.invalidState(record.id, "terminal record with in-flight action")
            }
            guard !journal.completed.isEmpty else {
                throw TaskCoordinator.TaskPersistenceValidationError.invalidState(record.id, "terminal record without receipts")
            }
            guard record.intent == .none else {
                throw TaskCoordinator.TaskPersistenceValidationError.invalidState(record.id, "terminal record with live intent \(record.intent)")
            }
            guard !record.checkpoint.hasUncertainSideEffect else {
                throw TaskCoordinator.TaskPersistenceValidationError.invalidState(record.id, "terminal record with uncertain side effect")
            }
        case .failed:
            throw TaskCoordinator.TaskPersistenceValidationError.terminalTask(record.id)
        }
    }
}
