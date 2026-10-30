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

    init(
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
        case agentThreadID
        case state
        case nextStepIndex
        case inFlightStepID
        case suspendedStepID
        case intent
        case recoveryDisposition
    }

    public init(from decoder: Decoder) throws {
        try self.init(from: decoder, storeVersion: PersistedTaskStore.currentVersion)
    }

    init(from decoder: Decoder, storeVersion: Int) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(TaskID.self, forKey: .id)
        let revision = try container.decode(UUID.self, forKey: .revision)
        let kind = try container.decode(String.self, forKey: .planKind)
        let plan: TaskPlan
        switch kind {
        case "executable":
            guard !container.contains(.goal), !container.contains(.agentThreadID) else {
                throw DecodingError.dataCorruptedError(forKey: .planKind, in: container, debugDescription: "executable task cannot contain agent plan fields")
            }
            let executable = try container.decode(PerryRuntimes.ExecutionPlan.self, forKey: .executionPlan)
            guard executable.taskID == id else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "task and executable plan identities differ")
            }
            plan = .executable(executable)
        case "agent":
            guard !container.contains(.executionPlan) else {
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
        } else if let storedJournal = try container.decodeIfPresent(WorkspaceActionJournal.self, forKey: .workspaceJournal) {
            guard case .executable(let executable) = plan else {
                throw DecodingError.dataCorruptedError(forKey: .workspaceJournal, in: container, debugDescription: "agent task cannot contain a workspace journal")
            }
            journal = try WorkspaceExecutionJournal(
                legacy: storedJournal,
                plan: executable,
                checkpoint: TaskCheckpoint(nextStepIndex: nextStepIndex, inFlightStepID: inFlightStepID, suspendedStepID: suspendedStepID)
            )
        } else {
            journal = nil
        }
        let checkpoint = TaskCheckpoint(nextStepIndex: nextStepIndex, inFlightStepID: inFlightStepID, suspendedStepID: suspendedStepID)
        if let journal {
            guard case .executable(let executable) = plan else {
                throw DecodingError.dataCorruptedError(forKey: .workspaceJournal, in: container, debugDescription: "agent task cannot contain a workspace journal")
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
        let decodedRecoveryDisposition = try container.decode(TaskRecoveryDisposition.self, forKey: .recoveryDisposition)
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

    func updating(
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
