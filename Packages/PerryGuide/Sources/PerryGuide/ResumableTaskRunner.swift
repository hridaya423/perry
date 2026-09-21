import Foundation
import PerryCore
import PerryRuntimes

public enum WorkspaceTaskProgress: Sendable {
    case awaitingApproval(TaskRecord)
    case reported(DoOutcome)
}

public actor ResumableTaskRunner {
    public let coordinator: TaskCoordinator
    private let notifier: any Notifying
    private let activityLog: ActivityLog
    private var outcomes: [TaskID: DoOutcome] = [:]
    private var workspaceReportOutcomes: [UUID: DoOutcome] = [:]
    private var runningIDs: Set<TaskID> = []

    public init(
        coordinator: TaskCoordinator,
        notifier: any Notifying,
        activityLog: ActivityLog = ActivityLog()
    ) {
        self.coordinator = coordinator
        self.notifier = notifier
        self.activityLog = activityLog
    }

    public func records() async -> [TaskRecord] {
        await coordinator.records()
    }

    public func outcome(for id: TaskID) -> DoOutcome? {
        outcomes[id]
    }

    public func takeReportedWorkspaceOutcome(for planID: UUID) -> DoOutcome? {
        workspaceReportOutcomes.removeValue(forKey: planID)
    }

    public func runWorkspaceTask(
        record: TaskRecord,
        runtime: WorkspaceFileRuntime,
        history: TranscriptStore,
        startedAt: Date
    ) async throws -> WorkspaceTaskProgress {
        guard !runningIDs.contains(record.id),
              case .executable = record.plan else {
            throw TaskCoordinatorError.invalidTransition(id: record.id, state: record.state)
        }
        runningIDs.insert(record.id)
        defer { runningIDs.remove(record.id) }
        guard await coordinator.record(id: record.id) == record,
              record.canResumeWorkspaceTask else {
            throw TaskCoordinatorError.invalidTransition(id: record.id, state: record.state)
        }
        try Task.checkCancellation()
        let verified = try await coordinator.executeWorkspaceAction(
            id: record.id, expectedRevision: record.revision, runtime: runtime
        )
        if verified.canReportWorkspaceTask {
            return .reported(try await saveWorkspaceReport(record: verified, history: history, startedAt: startedAt))
        }
        guard let nextAction = verified.workspaceActionToApprove else {
            throw TaskCoordinatorError.invalidTransition(id: verified.id, state: verified.state)
        }
        await notifier.deliver(TaskNotification(
            kind: .needsConfirmation,
            title: "Approval needed",
            body: nextAction.summary,
            taskID: verified.id,
            actionID: nextAction.id.rawValue,
            taskRevision: verified.revision
        ))
        return .awaitingApproval(verified)
    }

    public func reportWorkspaceTask(record: TaskRecord, history: TranscriptStore, startedAt: Date) async throws -> DoOutcome {
        guard !runningIDs.contains(record.id) else {
            throw TaskCoordinatorError.invalidTransition(id: record.id, state: record.state)
        }
        runningIDs.insert(record.id)
        defer { runningIDs.remove(record.id) }
        return try await saveWorkspaceReport(record: record, history: history, startedAt: startedAt)
    }

    private func saveWorkspaceReport(record: TaskRecord, history: TranscriptStore, startedAt: Date) async throws -> DoOutcome {
        guard let current = await coordinator.record(id: record.id), current == record,
              case .executable(let plan) = current.plan else {
            throw TaskCoordinatorError.invalidTransition(id: record.id, state: record.state)
        }
        let record = current
        let report = try await coordinator.workspaceReportOutcome(id: record.id, expectedRevision: record.revision)
        let completed: Bool
        switch report {
        case .completed: completed = true
        case .blocked: completed = false
        case .failed:
            throw TaskCoordinatorError.invalidTransition(id: record.id, state: record.state)
        }
        let completedCount = record.checkpoint.nextStepIndex
        let completedSummary = completedCount == 1
            ? "Created and verified the file in Perry’s workspace."
            : "Created and verified \(completedCount) files in Perry’s workspace."
        let entry = TranscriptEntry(
            id: plan.planID,
            sessionID: plan.planID,
            request: plan.goal,
            appBundleID: nil,
            summary: completed
                ? completedSummary
                : "Stopped after verifying \(completedCount) of \(plan.actions.count) actions. Remaining actions were not run.",
            outcome: completed ? .completed : .stopped,
            startedAt: startedAt,
            finishedAt: Date(),
            steps: plan.actions.prefix(completedCount).map(\.summary),
            verified: true
        )
        let outcome: DoOutcome
        do {
            guard await history.append(entry) else {
                let issue = await history.lastPersistenceError
                throw TaskCoordinatorError.persistenceFailed(issue?.localizedDescription ?? "could not save verified task history")
            }
            outcome = try await coordinator.finishWorkspaceTask(id: record.id, expectedRevision: record.revision)
        } catch {
            do {
                _ = try await coordinator.pause(id: record.id, expectedRevision: record.revision)
            } catch TaskCoordinatorError.invalidTransition {
            } catch TaskCoordinatorError.notFound {
            } catch let persistenceError {
                throw TaskCoordinatorError.persistenceFailed("\(error.localizedDescription); could not retain the report for retry: \(persistenceError.localizedDescription)")
            }
            throw error
        }
        outcomes[record.id] = outcome
        workspaceReportOutcomes[plan.planID] = outcome
        await notifier.deliver(TaskNotification(
            kind: completed ? .completed : .stopped,
            title: completed ? "Background task finished" : "Background task stopped",
            body: plan.goal,
            taskID: record.id
        ))
        return outcome
    }

    public func pause(id: TaskID) async throws {
        _ = try await coordinator.pause(id: id)
    }

    public func cancel(id: TaskID, expectedRevision: UUID? = nil) async throws {
        _ = try await coordinator.requestCancellation(id: id, expectedRevision: expectedRevision)
    }

    public func discard(id: TaskID) async throws {
        if let record = await coordinator.record(id: id), record.isTerminal {
            try await coordinator.remove(id: id)
        } else {
            _ = try await coordinator.cancel(id: id)
            if let retained = await coordinator.record(id: id) {
                throw TaskCoordinatorError.invalidTransition(id: id, state: retained.state)
            }
        }
        outcomes[id] = nil
    }
}
