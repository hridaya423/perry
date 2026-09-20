import Foundation
import XCTest
import PerryCore
import PerryRuntimes
@testable import PerryGuide

final class WorkspaceActionJournalTests: XCTestCase {
    private var directory: URL!
    private let contents = "  e\u{301}\r\n\t🍐\n  "

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("perry-workspace-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testSavedApprovalSurvivesRelaunchAndVerifiedReceiptIsPersisted() async throws {
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: makePlan())
        let prepared = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        XCTAssertEqual(prepared.state, .ready)
        XCTAssertTrue(prepared.canStartAutomatically)
        guard let preparedJournal = prepared.workspaceJournal,
              case .prepared(let approved) = preparedJournal.current else { return XCTFail("Approval was not journaled") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        let restored = TaskCoordinator(storageDirectory: directory)
        let loaded = await restored.record(id: queued.id)
        let retained = try XCTUnwrap(loaded)
        XCTAssertTrue(retained.canStartAutomatically)
        guard case .executable(let restoredPlan) = retained.plan,
              case .transform(let restoredWorkspace, _) = restoredPlan.actions[0].operation else {
            return XCTFail("Stored workspace plan changed operation")
        }
        XCTAssertEqual(restoredWorkspace.standardizedFileURL.path, directory.resolvingSymlinksInPath().standardizedFileURL.path)
        let verified = try await restored.executeWorkspaceAction(
            id: retained.id, expectedRevision: retained.revision, runtime: WorkspaceFileRuntime(baseURL: directory)
        )
        guard let verifiedJournal = verified.workspaceJournal,
              let completed = verifiedJournal.completed.first else { return XCTFail("Receipt was not journaled") }
        let attempt = completed.attempt
        let receipt = completed.receipt
        XCTAssertEqual(attempt.id, approved.id)
        XCTAssertEqual(attempt.grant.id, approved.grant.id)
        XCTAssertEqual(receipt.actionID, "write")
        XCTAssertEqual(verified.checkpoint.nextStepIndex, 1)
        XCTAssertFalse(verified.requiresReconciliation)
        XCTAssertEqual(try Data(contentsOf: output), Data(contents.utf8))
        let reloaded = TaskCoordinator(storageDirectory: directory)
        let final = await reloaded.record(id: queued.id)
        guard let finalJournal = final?.workspaceJournal,
              let persisted = finalJournal.completed.first else {
            return XCTFail("Verified journal did not survive relaunch")
        }
        let persistedAttempt = persisted.attempt
        let persistedReceipt = persisted.receipt
        XCTAssertEqual(persistedAttempt.id, attempt.id)
        XCTAssertEqual(persistedReceipt, receipt)
    }

    func testCancelledApprovalDoesNotAuthorizeQueuedWork() async throws {
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: makePlan())
        let approval = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        }
        do {
            _ = try await approval.value
            XCTFail("Cancelled approval authorized an action")
        } catch is CancellationError {
        }
        let loaded = await coordinator.record(id: queued.id)
        let retained = try XCTUnwrap(loaded)
        XCTAssertEqual(retained.revision, queued.revision)
        XCTAssertNil(retained.workspaceJournal)
        XCTAssertFalse(retained.canStartAutomatically)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testVersionFourPartialPlanRetainsFirstReceiptWithoutExecutingSecondAction() async throws {
        let first = try makePlan().actions[0]
        let second = try ExecutableAction(
            id: "write-second", summary: "Write second report", approvalRequirement: .action,
            operation: .transform(workspace: directory, command: .createUTF8File(path: "second.txt", contents: "second")),
            postcondition: .fileContents("second")
        )
        let plan = try PerryRuntimes.ExecutionPlan(
            taskID: "partial-v4", goal: "Write two reports", actions: [first, second], requestedScopes: [.workspaceWrite]
        )
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action(first.id))
        let receipt = try await WorkspaceFileRuntime(baseURL: directory).execute(
            plan: plan, actionID: first.id, grantID: grant.id, registry: registry
        )
        let attemptID = UUID()
        let revision = UUID()
        let encoder = JSONEncoder()
        let record: [String: Any] = [
            "id": "partial-v4", "revision": revision.uuidString, "planKind": "executable",
            "executionPlan": try JSONSerialization.jsonObject(with: encoder.encode(plan)),
            "state": "paused", "nextStepIndex": 1, "intent": "pause", "recoveryDisposition": "current",
            "workspaceJournal": ["verified": [
                "_0": ["id": attemptID.uuidString, "actionIndex": 0,
                       "grant": try JSONSerialization.jsonObject(with: encoder.encode(grant))],
                "_1": try JSONSerialization.jsonObject(with: encoder.encode(receipt))
            ]]
        ]
        let original = try JSONSerialization.data(withJSONObject: ["version": 4, "tasks": [record]])
        let store = directory.appendingPathComponent("tasks.json")
        try original.write(to: store)

        let coordinator = TaskCoordinator(storageDirectory: directory)
        let loaded = await coordinator.record(id: plan.taskID)
        let retained = try XCTUnwrap(loaded)
        XCTAssertEqual(retained.revision, revision)
        XCTAssertEqual(retained.checkpoint.nextStepIndex, 1)
        XCTAssertEqual(retained.intent, .pause)
        guard let journal = retained.workspaceJournal,
              let completed = journal.completed.first else {
            return XCTFail("The first action's receipt was lost")
        }
        let attempt = completed.attempt
        let restoredReceipt = completed.receipt
        XCTAssertEqual(attempt.id, attemptID)
        XCTAssertEqual(attempt.grant.id, grant.id)
        XCTAssertEqual(restoredReceipt, receipt)
        XCTAssertEqual(try Data(contentsOf: store), original)
        XCTAssertEqual(try Data(contentsOf: output), Data(contents.utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("second.txt").path))
    }

    func testPausedApprovalSurvivesRelaunchWithoutAutomaticRetry() async throws {
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: makePlan())
        XCTAssertFalse(queued.canStartAutomatically)
        _ = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        let paused = try await coordinator.pause(id: queued.id)
        XCTAssertFalse(paused.canStartAutomatically)
        XCTAssertTrue(paused.canResumeWorkspaceTask)

        let restored = TaskCoordinator(storageDirectory: directory)
        let loaded = await restored.record(id: queued.id)
        let retained = try XCTUnwrap(loaded)
        XCTAssertEqual(retained.state, .paused)
        XCTAssertFalse(retained.canStartAutomatically)
        XCTAssertTrue(retained.canResumeWorkspaceTask)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        let verified = try await restored.executeWorkspaceAction(
            id: retained.id, expectedRevision: retained.revision, runtime: WorkspaceFileRuntime(baseURL: directory)
        )
        XCTAssertEqual(verified.state, .paused)
        XCTAssertEqual(verified.intent, .pause)
        XCTAssertFalse(verified.canStartAutomatically)
        XCTAssertEqual(try Data(contentsOf: output), Data(contents.utf8))
    }

    func testPausedDispatchSurvivesRelaunchWithoutReplayAndCancellationRetainsUncertainty() async throws {
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: makePlan())
        let prepared = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        let paused = try await coordinator.pause(id: queued.id, expectedRevision: prepared.revision)
        let dispatched = try await coordinator.beginWorkspaceDispatch(id: queued.id, expectedRevision: paused.revision)
        XCTAssertEqual(dispatched.state, .paused)
        XCTAssertEqual(dispatched.intent, .pause)
        XCTAssertTrue(dispatched.requiresReconciliation)
        XCTAssertFalse(dispatched.canStartAutomatically)
        XCTAssertFalse(dispatched.canResumeWorkspaceTask)

        let restored = TaskCoordinator(storageDirectory: directory)
        let loaded = await restored.record(id: queued.id)
        let retained = try XCTUnwrap(loaded)
        XCTAssertEqual(retained.state, .paused)
        XCTAssertEqual(retained.intent, .pause)
        XCTAssertTrue(retained.requiresReconciliation)
        XCTAssertFalse(retained.canStartAutomatically)
        XCTAssertFalse(retained.canResumeWorkspaceTask)
        do {
            _ = try await restored.executeWorkspaceAction(
                id: retained.id, expectedRevision: retained.revision, runtime: WorkspaceFileRuntime(baseURL: directory)
            )
            XCTFail("A restored dispatched action must not replay")
        } catch TaskCoordinatorError.invalidTransition {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        let outcome = try await restored.cancel(id: retained.id, reason: "cancelled")
        XCTAssertEqual(outcome, .blocked(reason: "cancelled"))
        let cancelledCoordinator = TaskCoordinator(storageDirectory: directory)
        let cancelledLoaded = await cancelledCoordinator.record(id: retained.id)
        let cancelled = try XCTUnwrap(cancelledLoaded)
        XCTAssertEqual(cancelled.state, .paused)
        XCTAssertEqual(cancelled.intent, .cancel)
        XCTAssertTrue(cancelled.requiresReconciliation)
        XCTAssertFalse(cancelled.canStartAutomatically)
        XCTAssertFalse(cancelled.canResumeWorkspaceTask)
        guard let journal = cancelled.workspaceJournal,
              case .dispatched = journal.current else { return XCTFail("Cancellation discarded uncertainty") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCrashAfterDispatchRequiresInspectionAndCancellationPreservesUncertainty() async throws {
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: makePlan())
        let prepared = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        let dispatched = try await coordinator.beginWorkspaceDispatch(id: queued.id, expectedRevision: prepared.revision)
        XCTAssertTrue(dispatched.requiresReconciliation)
        try Data(contents.utf8).write(to: output)

        let restored = TaskCoordinator(storageDirectory: directory)
        _ = try await restored.recoverInterruptedRuns()
        let loaded = await restored.record(id: queued.id)
        let uncertain = try XCTUnwrap(loaded)
        do {
            _ = try await restored.executeWorkspaceAction(id: uncertain.id, expectedRevision: uncertain.revision, runtime: WorkspaceFileRuntime(baseURL: directory))
            XCTFail("An uncertain action must not replay")
        } catch TaskCoordinatorError.invalidTransition {
        }
        _ = try await restored.requestCancellation(id: queued.id)
        _ = try await restored.finishCancellation(id: queued.id, reason: "cancelled")
        let retained = await restored.record(id: queued.id)
        XCTAssertTrue(retained?.requiresReconciliation == true)
        guard let journal = retained?.workspaceJournal,
              case .dispatched = journal.current else { return XCTFail("Uncertain journal was discarded") }
        XCTAssertEqual(try Data(contentsOf: output), Data(contents.utf8))
    }

    func testFailedActionDoesNotRequeueOrBlockAnotherApprovedTaskAfterRelaunch() async throws {
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let first = try await coordinator.enqueue(executablePlan: makePlan())
        let firstApproved = try await coordinator.approveWorkspaceAction(id: first.id, expectedRevision: first.revision)
        let action = try ExecutableAction(
            id: "second-write", summary: "Write second file", approvalRequirement: .action,
            operation: .transform(workspace: directory, command: .createUTF8File(path: "second.txt", contents: "second")),
            postcondition: .fileContents("second")
        )
        let secondPlan = try PerryRuntimes.ExecutionPlan(taskID: "second", goal: "Write second file", actions: [action], requestedScopes: [.workspaceWrite])
        let second = try await coordinator.enqueue(executablePlan: secondPlan)
        _ = try await coordinator.approveWorkspaceAction(id: second.id, expectedRevision: second.revision)
        try Data("existing".utf8).write(to: output)
        do {
            _ = try await coordinator.executeWorkspaceAction(id: first.id, expectedRevision: firstApproved.revision, runtime: WorkspaceFileRuntime(baseURL: directory))
            XCTFail("Existing file was overwritten")
        } catch is ExecutionError {
        }

        let restored = TaskCoordinator(storageDirectory: directory)
        let records = try await restored.recoverInterruptedRuns()
        let candidates = records.filter(\.canStartAutomatically)
        XCTAssertEqual(candidates.map(\.id), [second.id])
        let failed = try XCTUnwrap(records.first { $0.id == first.id })
        XCTAssertEqual(failed.state, .paused)
        XCTAssertTrue(failed.requiresReconciliation)
        let candidate = try XCTUnwrap(candidates.first)
        _ = try await restored.executeWorkspaceAction(id: candidate.id, expectedRevision: candidate.revision, runtime: WorkspaceFileRuntime(baseURL: directory))
        XCTAssertEqual(try Data(contentsOf: output), Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("second.txt")), Data("second".utf8))
    }

    func testDuplicateDispatchCallbacksPerformOneFileCreation() async throws {
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: makePlan())
        let prepared = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        let runtime = WorkspaceFileRuntime(baseURL: directory)
        let successes = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        _ = try await coordinator.executeWorkspaceAction(id: prepared.id, expectedRevision: prepared.revision, runtime: runtime)
                        return true
                    } catch TaskCoordinatorError.invalidTransition {
                        return false
                    }
                }
            }
            var successes = 0
            for try await succeeded in group where succeeded { successes += 1 }
            return successes
        }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(try Data(contentsOf: output), Data(contents.utf8))
    }

    func testCancelledApprovalCannotDispatchAfterRelaunch() async throws {
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: makePlan())
        _ = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        _ = try await coordinator.requestCancellation(id: queued.id)
        let restored = TaskCoordinator(storageDirectory: directory)
        let loaded = await restored.record(id: queued.id)
        let cancelled = try XCTUnwrap(loaded)
        do {
            _ = try await restored.executeWorkspaceAction(id: cancelled.id, expectedRevision: cancelled.revision, runtime: WorkspaceFileRuntime(baseURL: directory))
            XCTFail("Cancelled approval must not dispatch")
        } catch TaskCoordinatorError.invalidTransition {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testDispatchPersistenceFailurePreventsFileCreation() async throws {
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: makePlan())
        let prepared = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        let store = directory.appendingPathComponent("tasks.json")
        try FileManager.default.moveItem(at: store, to: directory.appendingPathComponent("tasks.saved"))
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false)
        do {
            _ = try await coordinator.executeWorkspaceAction(id: queued.id, expectedRevision: prepared.revision, runtime: WorkspaceFileRuntime(baseURL: directory))
            XCTFail("Failed dispatch persistence must prevent execution")
        } catch TaskCoordinatorError.persistenceFailed {
        }
        let retained = await coordinator.record(id: queued.id)
        XCTAssertEqual(retained?.revision, prepared.revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    private var output: URL { directory.appendingPathComponent("report.txt") }

    func testCompletionRequiresCurrentVerifiedReceiptAndRemainsDurable() async throws {
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: makePlan())
        do {
            _ = try await coordinator.finishWorkspaceTask(id: queued.id, expectedRevision: queued.revision)
            XCTFail("Unverified task completed")
        } catch TaskCoordinatorError.invalidTransition {
        }
        let prepared = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        let verified = try await coordinator.executeWorkspaceAction(id: queued.id, expectedRevision: prepared.revision, runtime: WorkspaceFileRuntime(baseURL: directory))
        do {
            _ = try await coordinator.finishWorkspaceTask(id: queued.id, expectedRevision: prepared.revision)
            XCTFail("Stale task revision completed")
        } catch TaskCoordinatorError.invalidTransition {
        }
        let restored = TaskCoordinator(storageDirectory: directory)
        let outcome = try await restored.finishWorkspaceTask(id: queued.id, expectedRevision: verified.revision)
        XCTAssertEqual(outcome, .completed(stepsRun: 1))
        let reloaded = TaskCoordinator(storageDirectory: directory)
        let remaining = await reloaded.records()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(try Data(contentsOf: output), Data(contents.utf8))
    }

    func testOriginalSinglePhaseJournalFormatStillDecodes() async throws {
        let plan = try makePlan()
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action("write"))
        let grantObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(grant))
        let attemptID = UUID()
        let attempt: [String: Any] = ["id": attemptID.uuidString, "actionIndex": 0, "grant": grantObject]
        for phase in ["prepared", "dispatched"] {
            let original = try JSONSerialization.data(withJSONObject: [phase: ["_0": attempt]])
            let restored = try JSONDecoder().decode(WorkspaceActionJournal.self, from: original)
            XCTAssertEqual(restored.attempt.id, attemptID)
            XCTAssertEqual(restored.attempt.grant.id, grant.id)
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
            let payload = try XCTUnwrap(encoded[phase] as? [String: Any])
            XCTAssertEqual(Set(payload.keys), ["_0"])
        }
    }

    func testFailedCompletionPersistenceRetainsVerifiedRecord() async throws {
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: makePlan())
        let prepared = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        let verified = try await coordinator.executeWorkspaceAction(id: queued.id, expectedRevision: prepared.revision, runtime: WorkspaceFileRuntime(baseURL: directory))
        let store = directory.appendingPathComponent("tasks.json")
        try FileManager.default.moveItem(at: store, to: directory.appendingPathComponent("tasks.saved"))
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false)
        do {
            _ = try await coordinator.finishWorkspaceTask(id: verified.id, expectedRevision: verified.revision)
            XCTFail("Completion succeeded without persistent removal")
        } catch TaskCoordinatorError.persistenceFailed {
        }
        let retained = await coordinator.record(id: verified.id)
        XCTAssertEqual(retained?.revision, verified.revision)
        guard let journal = retained?.workspaceJournal,
              journal.completed.count == 1,
              journal.current == nil else { return XCTFail("Verified receipt was lost") }
        XCTAssertEqual(try Data(contentsOf: output), Data(contents.utf8))
    }

    func testCancelRetainsDispatchedJournalAcrossRelaunch() async throws {
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: makePlan())
        let prepared = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        _ = try await coordinator.beginWorkspaceDispatch(id: queued.id, expectedRevision: prepared.revision)
        _ = try await coordinator.cancel(id: queued.id)
        let restored = TaskCoordinator(storageDirectory: directory)
        let retained = await restored.record(id: queued.id)
        XCTAssertTrue(retained?.cancellationRequested == true)
        XCTAssertTrue(retained?.requiresReconciliation == true)
        guard let journal = retained?.workspaceJournal,
              case .dispatched = journal.current else { return XCTFail("Cancel discarded an uncertain action") }
    }

    func testFinishCannotDiscardDispatchedWorkspaceAction() async throws {
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: makePlan())
        let prepared = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        _ = try await coordinator.beginWorkspaceDispatch(id: queued.id, expectedRevision: prepared.revision)
        do {
            _ = try await coordinator.finish(id: queued.id, outcome: .blocked(reason: "stopped"))
            XCTFail("Finish discarded an uncertain action")
        } catch TaskCoordinatorError.invalidTransition {
        }
        let retained = await coordinator.record(id: queued.id)
        XCTAssertTrue(retained?.requiresReconciliation == true)
    }

    func testPreparedApprovalCannotDecodeAsQueuedOrRunning() async throws {
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: makePlan())
        let prepared = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(prepared)) as? [String: Any])
        for state in ["queued", "running"] {
            object["state"] = state
            object["intent"] = "none"
            let malformed = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(TaskRecord.self, from: malformed), state)
        }
    }

    func testMalformedPreparedLifecycleRestoresBackupWithoutExecutionAuthority() async throws {
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: makePlan())
        let prepared = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(prepared)) as? [String: Any])
        object["state"] = "queued"
        object["intent"] = "none"
        let malformed = try JSONSerialization.data(withJSONObject: ["version": 5, "tasks": [object]])
        try malformed.write(to: directory.appendingPathComponent("tasks.json"), options: .atomic)

        let restored = TaskCoordinator(storageDirectory: directory)
        let loaded = await restored.record(id: queued.id)
        let recovered = try XCTUnwrap(loaded)
        XCTAssertEqual(recovered.recoveryDisposition, .restoredBackup)
        XCTAssertTrue(recovered.requiresReconciliation)
        do {
            _ = try await restored.executeWorkspaceAction(id: recovered.id, expectedRevision: recovered.revision, runtime: WorkspaceFileRuntime(baseURL: directory))
            XCTFail("Backup recovery restored execution authority")
        } catch TaskCoordinatorError.invalidTransition {
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let quarantine = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("tasks.json.corrupt-") })
        XCTAssertEqual(try Data(contentsOf: quarantine), malformed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    private func makePlan() throws -> PerryRuntimes.ExecutionPlan {
        let action = try ExecutableAction(
            id: "write", summary: "Write report", approvalRequirement: .action,
            operation: .transform(workspace: directory, command: .createUTF8File(path: "report.txt", contents: contents)),
            postcondition: .fileContents(contents)
        )
        return try PerryRuntimes.ExecutionPlan(taskID: "task", goal: "Write report", actions: [action], requestedScopes: [.workspaceWrite])
    }
}
