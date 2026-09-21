import Foundation
import PerryCore
import PerryRuntimes

/// The shared write-ahead performer for workspace transforms. Each action is
/// journaled "prepared" before dispatch and lands a durable receipt after
/// verification — the TaskCoordinator record owns the evidence, so foreground
/// Do runs, the background queue, and Undo all produce receipts Undo can
/// reach. The record is enqueued lazily on the first action so a run that
/// never touches the workspace leaves no empty record behind.
public actor WorkspaceRunJournal {
    private let coordinator: TaskCoordinator
    private let plan: ExecutionPlan
    private let runtime: WorkspaceFileRuntime
    private var record: TaskRecord?

    public init(plan: ExecutionPlan, workspace: URL, coordinator: TaskCoordinator, trashURL: URL? = nil) {
        self.coordinator = coordinator
        self.plan = plan
        self.runtime = trashURL.map { WorkspaceFileRuntime(baseURL: workspace, trashURL: $0) }
            ?? WorkspaceFileRuntime(baseURL: workspace)
    }

    /// Journals and executes `action` as the record's next step. Fails closed
    /// when the action is not the journal's next expected transform — the
    /// durable record and the live plan can never silently diverge.
    @discardableResult
    public func perform(_ action: ExecutableAction) async throws -> WorkspaceFileExecutionReceipt {
        var current: TaskRecord
        if let record {
            current = record
        } else {
            current = try await coordinator.enqueue(executablePlan: plan)
            record = current
        }
        guard let next = current.workspaceActionToApprove, next.id == action.id else {
            throw TaskCoordinatorError.invalidTransition(id: current.id, state: current.state)
        }
        let prepared = try await coordinator.approveWorkspaceAction(
            id: current.id, expectedRevision: current.revision
        )
        let verified = try await coordinator.executeWorkspaceAction(
            id: prepared.id, expectedRevision: prepared.revision, runtime: runtime
        )
        record = verified
        guard let completed = verified.workspaceJournal?.completed.last,
              completed.receipt.actionID == action.id else {
            throw TaskCoordinatorError.invalidTransition(id: verified.id, state: verified.state)
        }
        return completed.receipt
    }

    /// Drives the journaled record to a durable end state once the run is
    /// over: a complete journal reports `.completed`, a partial journal is
    /// cancelled and reports `.blocked`, and a record that never executed is
    /// removed. Records with evidence stay in the store — that is what Undo
    /// reads — while uncertain in-flight work stays paused for recovery.
    public func settle() async {
        guard var record else { return }
        while true {
            if record.canReportWorkspaceTask {
                _ = try? await coordinator.finishWorkspaceTask(id: record.id, expectedRevision: record.revision)
                return
            }
            guard !record.isTerminal else { return }
            if !record.cancellationRequested {
                guard let cancelled = try? await coordinator.requestCancellation(
                    id: record.id, expectedRevision: record.revision
                ) else { return }
                record = cancelled
                continue
            }
            if record.workspaceJournal?.completed.isEmpty != false,
               record.workspaceJournal?.current == nil {
                _ = try? await coordinator.finishCancellation(
                    id: record.id,
                    reason: "stopped before any workspace action completed",
                    expectedRevision: record.revision
                )
            }
            return
        }
    }
}
