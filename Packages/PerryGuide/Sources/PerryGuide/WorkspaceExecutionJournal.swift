import Foundation
import PerryCore
import PerryRuntimes

public enum WorkspaceExecutionJournalError: Error, Equatable, Sendable {
    case completedIndexMismatch(expected: Int, actual: Int)
    case currentIndexMismatch(expected: Int, actual: Int)
    case currentAfterCompletedPlan
    case invalidCompletedAction(index: Int)
    case invalidCurrentAction(index: Int)
    case duplicateAttempt(UUID)
    case duplicateGrant(UUID)
    case checkpointMismatch(expected: TaskCheckpoint, actual: TaskCheckpoint)
    case legacyMissingPrefix(index: Int)
    case invalidLegacyJournal
}

public struct WorkspaceExecutionJournal: Codable, Sendable {
    public struct CompletedAction: Codable, Sendable {
        public let attempt: WorkspaceActionJournal.Attempt
        public let receipt: WorkspaceFileExecutionReceipt

        init(attempt: WorkspaceActionJournal.Attempt, receipt: WorkspaceFileExecutionReceipt) {
            self.attempt = attempt
            self.receipt = receipt
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case attempt, receipt
        }

        public init(from decoder: Decoder) throws {
            let fields = try WorkspaceJournalDecodingFields(
                decoder,
                allowed: Set(CodingKeys.allCases.map(\.rawValue))
            )
            attempt = try fields.decode(WorkspaceActionJournal.Attempt.self, "attempt")
            receipt = try fields.decode(WorkspaceFileExecutionReceipt.self, "receipt")
        }

        public func encode(to encoder: Encoder) throws {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(attempt, forKey: .attempt)
            try fields.encode(receipt, forKey: .receipt)
        }
    }

    public enum CurrentAction: Codable, Sendable {
        case prepared(WorkspaceActionJournal.Attempt)
        case dispatched(WorkspaceActionJournal.Attempt)

        public var attempt: WorkspaceActionJournal.Attempt {
            switch self {
            case .prepared(let attempt), .dispatched(let attempt): return attempt
            }
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case prepared, dispatched
        }

        private enum PayloadCodingKeys: String, CodingKey, CaseIterable {
            case attempt = "_0"
        }

        public init(from decoder: Decoder) throws {
            let fields = try WorkspaceJournalDecodingFields(
                decoder,
                allowed: Set(CodingKeys.allCases.map(\.rawValue))
            )
            guard fields.allKeys.count == 1, let name = fields.allKeys.first else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "workspace execution journal requires exactly one current phase"
                ))
            }
            let payload = try WorkspaceJournalDecodingFields(
                fields.decoder(name),
                allowed: Set(PayloadCodingKeys.allCases.map(\.rawValue))
            )
            let attempt = try WorkspaceActionJournal.Attempt(from: payload.decoder("_0"))
            switch name {
            case CodingKeys.prepared.rawValue:
                self = .prepared(attempt)
            case CodingKeys.dispatched.rawValue:
                self = .dispatched(attempt)
            default:
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown workspace execution journal current phase"
                ))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .prepared(let attempt):
                var payload = fields.nestedContainer(keyedBy: PayloadCodingKeys.self, forKey: .prepared)
                try payload.encode(attempt, forKey: .attempt)
            case .dispatched(let attempt):
                var payload = fields.nestedContainer(keyedBy: PayloadCodingKeys.self, forKey: .dispatched)
                try payload.encode(attempt, forKey: .attempt)
            }
        }
    }

    public let completed: [CompletedAction]
    public let current: CurrentAction?

    init(completed: [CompletedAction], current: CurrentAction?) {
        self.completed = completed
        self.current = current
    }

    public var checkpoint: TaskCheckpoint {
        let nextStepIndex = completed.count
        switch current {
        case .prepared, nil:
            return TaskCheckpoint(nextStepIndex: nextStepIndex)
        case .dispatched(let attempt):
            return TaskCheckpoint(nextStepIndex: nextStepIndex, inFlightStepID: attempt.grant.scope.actionID)
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case completed, current
    }

    public init(from decoder: Decoder) throws {
        let fields = try WorkspaceJournalDecodingFields(
            decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue))
        )
        completed = try fields.decode([CompletedAction].self, "completed")
        current = fields.allKeys.contains(CodingKeys.current.rawValue)
            ? try CurrentAction(from: fields.decoder(CodingKeys.current.rawValue))
            : nil
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(completed, forKey: .completed)
        try fields.encodeIfPresent(current, forKey: .current)
    }

    init(legacy: WorkspaceActionJournal, plan: PerryRuntimes.ExecutionPlan, checkpoint: TaskCheckpoint) throws {
        do {
            try legacy.validate(plan: plan, checkpoint: checkpoint)
        } catch {
            throw WorkspaceExecutionJournalError.invalidLegacyJournal
        }
        guard legacy.attempt.actionIndex == 0 else {
            throw WorkspaceExecutionJournalError.legacyMissingPrefix(index: legacy.attempt.actionIndex)
        }

        switch legacy {
        case .prepared(let attempt):
            self.init(completed: [], current: .prepared(attempt))
        case .dispatched(let attempt):
            self.init(completed: [], current: .dispatched(attempt))
        case .verified(let attempt, let receipt):
            self.init(completed: [CompletedAction(attempt: attempt, receipt: receipt)], current: nil)
        }
        do {
            try validate(plan: plan, checkpoint: checkpoint)
        } catch {
            throw WorkspaceExecutionJournalError.invalidLegacyJournal
        }
    }

    func validate(plan: PerryRuntimes.ExecutionPlan, checkpoint: TaskCheckpoint) throws {
        guard completed.count <= plan.actions.count else {
            throw WorkspaceExecutionJournalError.completedIndexMismatch(
                expected: plan.actions.count,
                actual: completed.count
            )
        }

        var attemptIDs: Set<UUID> = []
        var grantIDs: Set<UUID> = []
        for (index, completedAction) in completed.enumerated() {
            let attempt = completedAction.attempt
            guard attempt.actionIndex == index else {
                throw WorkspaceExecutionJournalError.completedIndexMismatch(
                    expected: index,
                    actual: attempt.actionIndex
                )
            }
            guard attemptIDs.insert(attempt.id).inserted else {
                throw WorkspaceExecutionJournalError.duplicateAttempt(attempt.id)
            }
            guard grantIDs.insert(attempt.grant.id).inserted else {
                throw WorkspaceExecutionJournalError.duplicateGrant(attempt.grant.id)
            }
            do {
                try WorkspaceActionJournal.verified(attempt, completedAction.receipt).validate(
                    plan: plan,
                    checkpoint: TaskCheckpoint(nextStepIndex: index + 1)
                )
            } catch {
                throw WorkspaceExecutionJournalError.invalidCompletedAction(index: index)
            }
        }

        if let current {
            guard completed.count < plan.actions.count else {
                throw WorkspaceExecutionJournalError.currentAfterCompletedPlan
            }
            let attempt = current.attempt
            guard attempt.actionIndex == completed.count else {
                throw WorkspaceExecutionJournalError.currentIndexMismatch(
                    expected: completed.count,
                    actual: attempt.actionIndex
                )
            }
            guard attemptIDs.insert(attempt.id).inserted else {
                throw WorkspaceExecutionJournalError.duplicateAttempt(attempt.id)
            }
            guard grantIDs.insert(attempt.grant.id).inserted else {
                throw WorkspaceExecutionJournalError.duplicateGrant(attempt.grant.id)
            }
            do {
                switch current {
                case .prepared:
                    try WorkspaceActionJournal.prepared(attempt).validate(
                        plan: plan,
                        checkpoint: TaskCheckpoint(nextStepIndex: completed.count)
                    )
                case .dispatched:
                    try WorkspaceActionJournal.dispatched(attempt).validate(
                        plan: plan,
                        checkpoint: TaskCheckpoint(
                            nextStepIndex: completed.count,
                            inFlightStepID: plan.actions[completed.count].id.rawValue
                        )
                    )
                }
            } catch {
                throw WorkspaceExecutionJournalError.invalidCurrentAction(index: completed.count)
            }
        }

        let expectedCheckpoint = self.checkpoint
        guard checkpoint == expectedCheckpoint else {
            throw WorkspaceExecutionJournalError.checkpointMismatch(
                expected: expectedCheckpoint,
                actual: checkpoint
            )
        }
    }
}

private extension ExecutionApprovalGrant.Scope {
    var actionID: String? {
        switch self {
        case .action(let id): return id.rawValue
        case .plan: return nil
        }
    }
}
