import Foundation
import XCTest
import PerryCore
import PerryRuntimes
@testable import PerryGuide

final class WorkspaceTaskRunnerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("perry-workspace-report-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testApprovedFileIsVerifiedAndHistorySurvivesTaskRemoval() async throws {
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: plan())
        let prepared = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        let notifications = Notifications()
        let runner = ResumableTaskRunner(coordinator: coordinator, notifier: notifications)
        let progress = try await runner.runWorkspaceTask(record: prepared, runtime: WorkspaceFileRuntime(baseURL: directory), history: TranscriptStore(directory: directory), startedAt: Date())
        guard case .reported(let outcome) = progress else { return XCTFail("Completed plan still awaits approval") }
        XCTAssertEqual(outcome, .completed(stepsRun: 1))
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "report")
        let tasks = await TaskCoordinator(storageDirectory: directory).records()
        let history = await TranscriptStore(directory: directory).snapshot()
        let delivered = await notifications.values
        XCTAssertEqual(tasks.map(\.state), [.completed])
        XCTAssertEqual(tasks.first?.workspaceJournal?.completed.count, 1)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.verified, true)
        XCTAssertEqual(delivered.map(\.kind), [.completed])
    }

    func testHistoryFailureRetainsReceiptAndRelaunchRetriesOnlyReporting() async throws {
        let blockedHistory = directory.appendingPathComponent("Transcripts")
        try Data("blocked".utf8).write(to: blockedHistory)
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: plan())
        let prepared = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        let notifications = Notifications()
        let runner = ResumableTaskRunner(coordinator: coordinator, notifier: notifications)
        do {
            _ = try await runner.runWorkspaceTask(record: prepared, runtime: WorkspaceFileRuntime(baseURL: directory), history: TranscriptStore(directory: directory), startedAt: Date())
            XCTFail("History failure was reported as completion")
        } catch TaskCoordinatorError.persistenceFailed {
        }
        let retained = await coordinator.record(id: queued.id)
        XCTAssertEqual(retained?.workspaceJournal?.completed.count, 1)
        XCTAssertNil(retained?.workspaceJournal?.current)
        let beforeRetry = await notifications.values
        XCTAssertTrue(beforeRetry.isEmpty)
        try FileManager.default.moveItem(at: blockedHistory, to: directory.appendingPathComponent("history-blocker.saved"))
        let restored = TaskCoordinator(storageDirectory: directory)
        let loaded = await restored.record(id: queued.id)
        let record = try XCTUnwrap(loaded)
        let restarted = ResumableTaskRunner(coordinator: restored, notifier: notifications)
        let outcome = try await restarted.reportWorkspaceTask(record: record, history: TranscriptStore(directory: directory), startedAt: Date())
        XCTAssertEqual(outcome, .completed(stepsRun: 1))
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "report")
        let entries = await TranscriptStore(directory: directory).snapshot()
        XCTAssertEqual(entries.count, 1)
    }

    func testUnapprovedRecordCreatesNeitherFileNorHistory() async throws {
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: plan())
        let history = TranscriptStore(directory: directory)
        let runner = ResumableTaskRunner(coordinator: coordinator, notifier: Notifications())
        do {
            _ = try await runner.runWorkspaceTask(record: queued, runtime: WorkspaceFileRuntime(baseURL: directory), history: history, startedAt: Date())
            XCTFail("An unapproved record executed")
        } catch TaskCoordinatorError.invalidTransition {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let entries = await history.snapshot()
        XCTAssertTrue(entries.isEmpty)
    }

    func testCancellationAfterHistoryWriteRetainsReceiptAndReportsCompletionOnce() async throws {
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let executionPlan = try plan()
        let queued = try await coordinator.enqueue(executablePlan: executionPlan)
        let approved = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        let verified = try await coordinator.executeWorkspaceAction(id: queued.id, expectedRevision: approved.revision, runtime: WorkspaceFileRuntime(baseURL: directory))
        let history = TranscriptStore(directory: directory)
        let saved = await history.append(TranscriptEntry(
            id: executionPlan.planID, sessionID: executionPlan.planID, request: executionPlan.goal,
            appBundleID: nil, summary: "Created report.txt", outcome: .completed,
            startedAt: Date(), finishedAt: Date(), steps: ["Create report.txt"], verified: true
        ))
        XCTAssertTrue(saved)
        _ = try await coordinator.requestCancellation(id: queued.id)
        do {
            _ = try await coordinator.finishWorkspaceTask(id: queued.id, expectedRevision: verified.revision)
            XCTFail("A stale reporting callback removed the cancelled task")
        } catch TaskCoordinatorError.invalidTransition {
        }
        _ = try await coordinator.finishCancellation(id: queued.id, reason: "stop")
        let restored = TaskCoordinator(storageDirectory: directory)
        let loaded = await restored.record(id: queued.id)
        let retained = try XCTUnwrap(loaded)
        XCTAssertTrue(retained.cancellationRequested)
        XCTAssertTrue(retained.canResumeWorkspaceTask)
        XCTAssertFalse(retained.canStartAutomatically)
        XCTAssertEqual(retained.workspaceJournal?.completed.count, 1)
        XCTAssertNil(retained.workspaceJournal?.current)

        let waiting = try await restored.queueWorkspaceReport(id: retained.id, expectedRevision: retained.revision)
        XCTAssertTrue(waiting.canStartAutomatically)
        let relaunched = TaskCoordinator(storageDirectory: directory)
        let waitingRecords = await relaunched.records()
        let pendingReport = try XCTUnwrap(waitingRecords.first)
        XCTAssertTrue(pendingReport.canStartAutomatically)
        let pausedReport = try await relaunched.pause(id: pendingReport.id)
        XCTAssertTrue(pausedReport.cancellationRequested)
        XCTAssertFalse(pausedReport.canStartAutomatically)
        XCTAssertTrue(pausedReport.canResumeWorkspaceTask)

        let notifications = Notifications()
        let runner = ResumableTaskRunner(coordinator: relaunched, notifier: notifications)
        let outcome = try await runner.reportWorkspaceTask(record: pausedReport, history: history, startedAt: Date())
        XCTAssertEqual(outcome, .completed(stepsRun: 1))
        let entries = await history.snapshot()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.outcome, .completed)
        XCTAssertEqual(entries.first?.verified, true)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "report")
        let remaining = await relaunched.records()
        XCTAssertEqual(remaining.map(\.state), [.completed])
        XCTAssertEqual(remaining.first?.workspaceJournal?.completed.count, 1)
    }

    func testDiscardCannotRemoveVerifiedWorkAwaitingHistory() async throws {
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: plan())
        let approved = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        _ = try await coordinator.executeWorkspaceAction(id: queued.id, expectedRevision: approved.revision, runtime: WorkspaceFileRuntime(baseURL: directory))
        let runner = ResumableTaskRunner(coordinator: coordinator, notifier: Notifications())
        do {
            try await runner.discard(id: queued.id)
            XCTFail("Verified work was discarded without history")
        } catch TaskCoordinatorError.invalidTransition {
        }
        let retained = await coordinator.record(id: queued.id)
        XCTAssertEqual(retained?.workspaceJournal?.completed.count, 1)
        XCTAssertNil(retained?.workspaceJournal?.current)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "report")
    }

    func testReportingUsesReceiptWithoutRecreatingMovedWorkspace() async throws {
        let workspace = directory.appendingPathComponent("workspace")
        let moved = directory.appendingPathComponent("moved-workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let action = try ExecutableAction(
            id: "write", summary: "Create report.txt", approvalRequirement: .action,
            operation: .transform(workspace: workspace, command: .createUTF8File(path: "report.txt", contents: "report")),
            postcondition: .fileContents("report")
        )
        let executionPlan = try PerryRuntimes.ExecutionPlan(taskID: "task", goal: "Create report", actions: [action], requestedScopes: [.workspaceWrite])
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: executionPlan)
        let approved = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        let runner = ResumableTaskRunner(coordinator: coordinator, notifier: Notifications())
        let history = TranscriptStore(directory: directory)
        do {
            _ = try await runner.reportWorkspaceTask(record: approved, history: history, startedAt: Date())
            XCTFail("An approval without a receipt was reported as completion")
        } catch TaskCoordinatorError.invalidTransition {
        }
        let beforeExecution = await history.snapshot()
        XCTAssertTrue(beforeExecution.isEmpty)
        let verified = try await coordinator.executeWorkspaceAction(id: queued.id, expectedRevision: approved.revision, runtime: WorkspaceFileRuntime(baseURL: workspace))
        try FileManager.default.moveItem(at: workspace, to: moved)
        _ = try await runner.reportWorkspaceTask(record: verified, history: history, startedAt: Date())
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("report.txt"), encoding: .utf8), "report")
        let entries = await history.snapshot()
        XCTAssertEqual(entries.map(\.outcome), [.completed])
    }

    func testFirstActionSurvivesRelaunchAndSecondRequiresItsOwnApproval() async throws {
        let executionPlan = try twoActionPlan()
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: executionPlan)
        let approved = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        let notifications = Notifications()
        let history = TranscriptStore(directory: directory)
        let runner = ResumableTaskRunner(coordinator: coordinator, notifier: notifications)
        let progress = try await runner.runWorkspaceTask(record: approved, runtime: WorkspaceFileRuntime(baseURL: directory), history: history, startedAt: Date())
        guard case .awaitingApproval(let partial) = progress else { return XCTFail("Partial plan was reported as finished") }
        XCTAssertEqual(partial.workspaceJournal?.completed.count, 1)
        XCTAssertEqual(partial.workspaceActionToApprove?.id, executionPlan.actions[1].id)
        XCTAssertFalse(partial.canStartAutomatically)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "report")
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondOutput.path))
        let initialHistory = await history.snapshot()
        XCTAssertTrue(initialHistory.isEmpty)
        let prompts = await notifications.values
        XCTAssertEqual(prompts.map(\.kind), [.needsConfirmation])
        XCTAssertEqual(prompts.first?.actionID, executionPlan.actions[1].id.rawValue)
        XCTAssertEqual(prompts.first?.taskRevision, partial.revision)

        let restored = TaskCoordinator(storageDirectory: directory)
        let loaded = await restored.record(id: queued.id)
        let retained = try XCTUnwrap(loaded)
        XCTAssertEqual(retained.workspaceJournal?.completed.first?.attempt.id, partial.workspaceJournal?.completed.first?.attempt.id)
        let restarted = ResumableTaskRunner(coordinator: restored, notifier: notifications)
        do {
            _ = try await restarted.runWorkspaceTask(record: retained, runtime: WorkspaceFileRuntime(baseURL: directory), history: history, startedAt: Date())
            XCTFail("Second action ran without fresh approval")
        } catch TaskCoordinatorError.invalidTransition {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondOutput.path))
        let secondApproval = try await restored.approveWorkspaceAction(id: queued.id, expectedRevision: retained.revision)
        let finished = try await restarted.runWorkspaceTask(record: secondApproval, runtime: WorkspaceFileRuntime(baseURL: directory), history: history, startedAt: Date())
        guard case .reported(let outcome) = finished else { return XCTFail("Full plan did not report") }
        XCTAssertEqual(outcome, .completed(stepsRun: 2))
        XCTAssertEqual(try String(contentsOf: secondOutput, encoding: .utf8), "second")
        let remaining = await restored.records()
        let entries = await TranscriptStore(directory: directory).snapshot()
        XCTAssertEqual(remaining.map(\.state), [.completed])
        XCTAssertEqual(remaining.first?.workspaceJournal?.completed.count, 2)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.steps, executionPlan.actions.map(\.summary))
        XCTAssertEqual(entries.first?.outcome, .completed)
    }

    func testCancelledPartialPlanRetriesOnlyItsStoppedReportAfterHistoryFailure() async throws {
        let executionPlan = try twoActionPlan()
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: executionPlan)
        let approved = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        let partial = try await coordinator.executeWorkspaceAction(id: queued.id, expectedRevision: approved.revision, runtime: WorkspaceFileRuntime(baseURL: directory))
        _ = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: partial.revision)
        let cancelled = try await coordinator.requestCancellation(id: queued.id)
        XCTAssertNil(cancelled.workspaceJournal?.current)
        XCTAssertEqual(cancelled.workspaceJournal?.completed.count, 1)
        XCTAssertTrue(cancelled.canReportWorkspaceTask)

        let blocker = directory.appendingPathComponent("Transcripts")
        try Data("blocked".utf8).write(to: blocker)
        let notifications = Notifications()
        let runner = ResumableTaskRunner(coordinator: coordinator, notifier: notifications)
        do {
            _ = try await runner.reportWorkspaceTask(record: cancelled, history: TranscriptStore(directory: directory), startedAt: Date())
            XCTFail("Failed history write removed the partial task")
        } catch TaskCoordinatorError.persistenceFailed {
        }
        let retained = await coordinator.record(id: queued.id)
        XCTAssertEqual(retained, cancelled)
        let beforeRetry = await notifications.values
        XCTAssertTrue(beforeRetry.isEmpty)
        try FileManager.default.moveItem(at: blocker, to: directory.appendingPathComponent("history-blocker.saved"))
        let restored = TaskCoordinator(storageDirectory: directory)
        let loaded = await restored.record(id: queued.id)
        let record = try XCTUnwrap(loaded)
        let restarted = ResumableTaskRunner(coordinator: restored, notifier: notifications)
        let outcome = try await restarted.reportWorkspaceTask(record: record, history: TranscriptStore(directory: directory), startedAt: Date())
        guard case .blocked = outcome else { return XCTFail("Cancelled partial work was reported as completed") }
        let entries = await TranscriptStore(directory: directory).snapshot()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, executionPlan.planID)
        XCTAssertEqual(entries.first?.outcome, .stopped)
        XCTAssertEqual(entries.first?.steps, [executionPlan.actions[0].summary])
        XCTAssertEqual(entries.first?.verified, true)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "report")
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondOutput.path))
        let delivered = await notifications.values
        XCTAssertEqual(delivered.map(\.kind), [.stopped])
        let wrongPlan = await restarted.takeReportedWorkspaceOutcome(for: UUID())
        let saved = await restarted.takeReportedWorkspaceOutcome(for: executionPlan.planID)
        let consumed = await restarted.takeReportedWorkspaceOutcome(for: executionPlan.planID)
        XCTAssertNil(wrongPlan)
        XCTAssertEqual(saved, outcome)
        XCTAssertNil(consumed)
    }

    func testReportUsesStoredPlanInsteadOfCallerFieldsWithMatchingIdentity() async throws {
        let executionPlan = try plan()
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: executionPlan)
        let approved = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        let verified = try await coordinator.executeWorkspaceAction(id: queued.id, expectedRevision: approved.revision, runtime: WorkspaceFileRuntime(baseURL: directory))
        let otherPlan = try PerryRuntimes.ExecutionPlan(taskID: executionPlan.taskID, goal: "Unrelated request", actions: executionPlan.actions, requestedScopes: [.workspaceWrite])
        let encoded = try JSONEncoder().encode(TaskRecord(executablePlan: otherPlan))
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        fields["revision"] = verified.revision.uuidString
        let caller = try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: fields))
        let history = TranscriptStore(directory: directory)
        let runner = ResumableTaskRunner(coordinator: coordinator, notifier: Notifications())
        _ = try await runner.reportWorkspaceTask(record: caller, history: history, startedAt: Date())
        let entries = await history.snapshot()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, executionPlan.planID)
        XCTAssertEqual(entries.first?.request, executionPlan.goal)
        XCTAssertEqual(entries.first?.steps, executionPlan.actions.map(\.summary))
    }

    private var output: URL { directory.appendingPathComponent("report.txt") }
    private var secondOutput: URL { directory.appendingPathComponent("second.txt") }

    private func twoActionPlan() throws -> PerryRuntimes.ExecutionPlan {
        let first = try plan().actions[0]
        let second = try ExecutableAction(id: "write-second", summary: "Create second.txt", approvalRequirement: .action, operation: .transform(workspace: directory, command: .createUTF8File(path: "second.txt", contents: "second")), postcondition: .fileContents("second"))
        return try PerryRuntimes.ExecutionPlan(taskID: "task", goal: "Create two files", actions: [first, second], requestedScopes: [.workspaceWrite])
    }

    private func plan() throws -> PerryRuntimes.ExecutionPlan {
        let action = try ExecutableAction(id: "write", summary: "Create report.txt", approvalRequirement: .action, operation: .transform(workspace: directory, command: .createUTF8File(path: "report.txt", contents: "report")), postcondition: .fileContents("report"))
        return try PerryRuntimes.ExecutionPlan(taskID: "task", goal: "Create report", actions: [action], requestedScopes: [.workspaceWrite])
    }

    private actor Notifications: Notifying {
        var values: [TaskNotification] = []
        func deliver(_ notification: TaskNotification) { values.append(notification) }
    }
}
