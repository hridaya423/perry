import XCTest
@testable import PerryGuide
import PerryCore
import PerryRuntimes

final class TaskCoordinatorTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-task-coordinator-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        super.tearDown()
    }

    func testEnqueuePersistsTypedRecordAndRejectsDuplicateID() async throws {
        let coordinator = TaskCoordinator(maxTasks: 2, storageDirectory: directory)
        let id = TaskID("rename-notes")
        let plan = try makePlan(taskID: id, goal: "rename notes")

        let record = try await coordinator.enqueue(executablePlan: plan)

        XCTAssertEqual(record.id, id)
        guard case .executable(let storedPlan) = record.plan else { return XCTFail("Typed enqueue changed plan representation") }
        XCTAssertEqual(try storedPlan.canonicalData(), try plan.canonicalData())
        XCTAssertEqual(record.state, .queued)
        XCTAssertEqual(record.checkpoint.nextStepIndex, 0)
        XCTAssertEqual(record.intent, .none)
        let records = await coordinator.records()
        XCTAssertEqual(records.map(\.id), [id])

        let secondID = TaskID("rename-settings")
        _ = try await coordinator.enqueue(executablePlan: makePlan(taskID: secondID, goal: "rename settings"))
        let multipleRecords = await coordinator.records()
        XCTAssertEqual(multipleRecords.map(\.id), [id, secondID])

        do {
            _ = try await coordinator.enqueue(executablePlan: plan)
            XCTFail("expected duplicate task ID to be rejected")
        } catch TaskCoordinatorError.duplicateID(let duplicateID) {
            XCTAssertEqual(duplicateID, id)
        }

        let reloaded = TaskCoordinator(storageDirectory: directory)
        let reloadedRecord = await reloaded.record(id: id)
        XCTAssertEqual(reloadedRecord, record)
    }

    func testApprovalSurvivesReloadAndPausedTaskStaysResumable() async throws {
        let id = TaskID("organize-files")
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: makePlan(taskID: id, goal: "organize files"))

        let approved = try await coordinator.approveWorkspaceAction(id: id, expectedRevision: queued.revision)
        XCTAssertEqual(approved.state, .ready)
        XCTAssertTrue(approved.canStartAutomatically)

        let reloaded = TaskCoordinator(storageDirectory: directory)
        let listed = await reloaded.record(id: id)
        XCTAssertEqual(listed?.revision, approved.revision)
        XCTAssertTrue(listed?.canResumeWorkspaceTask == true)

        let paused = try await reloaded.pause(id: id, expectedRevision: approved.revision)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertTrue(paused.pauseRequested)
        XCTAssertTrue(paused.canResumeWorkspaceTask)
    }

    func testCapacityIsBoundedUntilTerminalCleanup() async throws {
        let coordinator = TaskCoordinator(maxTasks: 1, storageDirectory: directory)
        let firstID = TaskID("first")
        let secondID = TaskID("second")

        _ = try await coordinator.enqueue(executablePlan: makePlan(taskID: firstID))

        do {
            _ = try await coordinator.enqueue(executablePlan: makePlan(taskID: secondID))
            XCTFail("expected the coordinator capacity to be enforced")
        } catch TaskCoordinatorError.capacityReached {
        }

        _ = try await coordinator.cancel(id: firstID)
        _ = try await coordinator.enqueue(executablePlan: makePlan(taskID: secondID))
        let records = await coordinator.records()
        XCTAssertEqual(records.map(\.id), [secondID])
    }

    func testTerminalCleanupRemovesTaskFromDisk() async throws {
        let id = TaskID("delete-after-finish")
        let coordinator = TaskCoordinator(storageDirectory: directory)
        _ = try await coordinator.enqueue(executablePlan: makePlan(taskID: id))
        let requested = try await coordinator.requestCancellation(id: id)
        XCTAssertTrue(requested.cancellationRequested)

        let reloadedBeforeFinish = TaskCoordinator(storageDirectory: directory)
        let requestedRecord = await reloadedBeforeFinish.record(id: id)
        XCTAssertTrue(requestedRecord?.cancellationRequested == true)
        XCTAssertFalse(requestedRecord?.canResumeWorkspaceTask == true)

        let outcome = try await coordinator.finishCancellation(id: id, reason: "user cancelled the task")
        XCTAssertEqual(outcome, .blocked(reason: "user cancelled the task"))
        let removedRecord = await coordinator.record(id: id)
        XCTAssertNil(removedRecord)

        let reloaded = TaskCoordinator(storageDirectory: directory)
        let reloadedRecords = await reloaded.records()
        XCTAssertTrue(reloadedRecords.isEmpty)
    }

    func testCorruptFileIsQuarantinedAndCanBeReplaced() async throws {
        let fileURL = directory.appendingPathComponent("tasks.json")
        let corruptData = Data("{ not valid json".utf8)
        try corruptData.write(to: fileURL)

        let coordinator = TaskCoordinator(storageDirectory: directory)
        let records = await coordinator.records()
        XCTAssertTrue(records.isEmpty)

        let issue = await coordinator.lastPersistenceError
        guard case .recoveredCorruptFile(let path, let quarantinePath, _) = issue else {
            return XCTFail("expected corrupt task recovery, got \(String(describing: issue))")
        }
        XCTAssertEqual(path, fileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: quarantinePath)), corruptData)

        let id = TaskID("recovered")
        _ = try await coordinator.enqueue(executablePlan: makePlan(taskID: id, goal: "recover"))
        let persistenceError = await coordinator.lastPersistenceError
        XCTAssertNil(persistenceError)

        let reloaded = TaskCoordinator(storageDirectory: directory)
        let reloadedRecords = await reloaded.records()
        XCTAssertEqual(reloadedRecords.map(\.id), [id])
    }

    func testInterruptedWriteIsQuarantinedWithoutLoadingPartialEnvelope() async throws {
        let fileURL = directory.appendingPathComponent("tasks.json")
        let coordinator = TaskCoordinator(fileURL: fileURL)
        _ = try await coordinator.enqueue(executablePlan: makePlan(taskID: "interrupted-write"))

        let persisted = try Data(contentsOf: fileURL)
        let interruptedData = Data(persisted.prefix(max(1, persisted.count / 2)))
        try interruptedData.write(to: fileURL)

        let reloaded = TaskCoordinator(fileURL: fileURL)
        let initialRecords = await reloaded.records()
        XCTAssertTrue(initialRecords.isEmpty)

        let issue = await reloaded.lastPersistenceError
        guard case .recoveredCorruptFile(let path, let quarantinePath, _) = issue else {
            return XCTFail("expected interrupted write recovery, got \(String(describing: issue))")
        }
        XCTAssertEqual(path, fileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: quarantinePath)), interruptedData)

        _ = try await reloaded.enqueue(executablePlan: makePlan(taskID: "after-interrupted-write"))
        let recovered = await reloaded.records()
        XCTAssertEqual(recovered.map(\.id), [TaskID("after-interrupted-write")])
    }

    func testCorruptPrimaryRestoresTheLastValidTaskBackup() async throws {
        let fileURL = directory.appendingPathComponent("tasks.json")
        let backupURL = fileURL.appendingPathExtension("backup")
        let id = TaskID("recover-from-backup")
        let coordinator = TaskCoordinator(fileURL: fileURL)
        let queued = try await coordinator.enqueue(executablePlan: makePlan(taskID: id))
        _ = try await coordinator.approveWorkspaceAction(id: id, expectedRevision: queued.revision)
        let backupData = try Data(contentsOf: backupURL)
        let corruptData = Data("truncated-primary".utf8)
        try corruptData.write(to: fileURL)

        let recovered = TaskCoordinator(fileURL: fileURL)

        let records = await recovered.records()
        XCTAssertEqual(records.map(\.id), [id])
        XCTAssertEqual(records.first?.recoveryDisposition, .restoredBackup)
        XCTAssertEqual(try Data(contentsOf: backupURL), backupData)
        guard case .recoveredCorruptFile(_, let quarantinePath, _) = await recovered.lastPersistenceError else {
            return XCTFail("expected primary corruption to remain visible")
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: quarantinePath)), corruptData)
    }

    func testRestoredBackupRejectsExecutionUntilExplicitReconciliation() async throws {
        let fileURL = directory.appendingPathComponent("tasks.json")
        let id = TaskID("stale-approval")
        let coordinator = TaskCoordinator(fileURL: fileURL)
        let queued = try await coordinator.enqueue(executablePlan: makePlan(taskID: id))
        let approved = try await coordinator.approveWorkspaceAction(id: id, expectedRevision: queued.revision)
        _ = try await coordinator.pause(id: id, expectedRevision: approved.revision)
        try Data("lost-approved-dispatch".utf8).write(to: fileURL)
        let restored = TaskCoordinator(fileURL: fileURL)
        let restoredRecord = await restored.record(id: id)
        let revision = try XCTUnwrap(restoredRecord?.revision)
        XCTAssertEqual(restoredRecord?.recoveryDisposition, .restoredBackup)
        XCTAssertFalse(restoredRecord?.canResumeWorkspaceTask == true)

        do {
            _ = try await restored.executeWorkspaceAction(
                id: id,
                expectedRevision: revision,
                runtime: WorkspaceFileRuntime(baseURL: directory)
            )
            XCTFail("A stale backup must not authorize replay")
        } catch TaskCoordinatorError.invalidTransition {
        }
        do {
            _ = try await restored.approveWorkspaceAction(id: id, expectedRevision: revision)
            XCTFail("A stale backup must not reapprove without reconciliation")
        } catch TaskCoordinatorError.invalidTransition {
        }

        let reconciled = try await restored.reconcileWorkspaceAction(id: id, expectedRevision: revision)
        XCTAssertFalse(reconciled.requiresReconciliation)
        XCTAssertNotNil(reconciled.workspaceActionToApprove)
        XCTAssertFalse(reconciled.canStartAutomatically)

        _ = try await restored.cancel(id: id)
        let remaining = await restored.records()
        XCTAssertTrue(remaining.isEmpty)
        let fresh = try await restored.enqueue(executablePlan: makePlan(taskID: "fresh"))
        XCTAssertEqual(fresh.state, .queued)
    }

    func testOnlyLegacyEnvelopeMayOmitRecoveryDisposition() async throws {
        for version in [1, 2] {
            let fileURL = directory.appendingPathComponent("version-\(version).json")
            var encodedTask = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(TaskRecord(executablePlan: makePlan(taskID: "legacy")))) as? [String: Any])
            encodedTask["planKind"] = "legacy"
            encodedTask["goal"] = "legacy goal"
            encodedTask["runtimeID"] = "local.test"
            encodedTask["steps"] = [["id": "step-1", "kind": "highlight", "summary": "legacy step", "payload": [:]]]
            encodedTask.removeValue(forKey: "executionPlan")
            encodedTask.removeValue(forKey: "revision")
            encodedTask.removeValue(forKey: "recoveryDisposition")
            let data = try JSONSerialization.data(withJSONObject: ["version": version, "tasks": [encodedTask]])
            try data.write(to: fileURL)
            let coordinator = TaskCoordinator(fileURL: fileURL)
            let records = await coordinator.records()
            if version == 1 {
                XCTAssertEqual(records.count, 1)
                XCTAssertEqual(records.first?.recoveryDisposition, .current)
                XCTAssertFalse(records.first?.canResumeWorkspaceTask == true)
                _ = try await coordinator.pause(id: "legacy")
                let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
                XCTAssertEqual(envelope["version"] as? Int, 5)
            } else {
                XCTAssertTrue(records.isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
            }
        }
    }

    func testUnsupportedPrimaryPreservesBothFilesAndBlocksReplacement() async throws {
        let fileURL = directory.appendingPathComponent("tasks.json")
        let backupURL = fileURL.appendingPathExtension("backup")
        let original = TaskCoordinator(fileURL: fileURL)
        let queued = try await original.enqueue(executablePlan: makePlan(taskID: "old"))
        _ = try await original.pause(id: "old", expectedRevision: queued.revision)
        let backup = try Data(contentsOf: backupURL)
        let future = Data(#"{"version":9001,"tasks":[],"futureField":"preserve"}"#.utf8)
        try future.write(to: fileURL)

        let restored = TaskCoordinator(fileURL: fileURL)
        let records = await restored.records()
        XCTAssertTrue(records.isEmpty)
        do {
            _ = try await restored.enqueue(executablePlan: makePlan(taskID: "replacement"))
            XCTFail("Unsupported task data was overwritten")
        } catch TaskCoordinatorError.persistenceFailed {
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), future)
        XCTAssertEqual(try Data(contentsOf: backupURL), backup)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(files), ["tasks.json", "tasks.json.backup"])
    }

    func testUnsupportedBackupWithMissingPrimaryBlocksNewStoreCreation() async throws {
        let fileURL = directory.appendingPathComponent("tasks.json")
        let backupURL = fileURL.appendingPathExtension("backup")
        let future = Data(#"{"version":9001,"tasks":[],"futureField":"preserve"}"#.utf8)
        try future.write(to: backupURL)
        let restored = TaskCoordinator(fileURL: fileURL)
        do {
            _ = try await restored.enqueue(executablePlan: makePlan(taskID: "replacement"))
            XCTFail("Missing primary bypassed the unsupported backup protection")
        } catch TaskCoordinatorError.persistenceFailed {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: backupURL), future)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, ["tasks.json.backup"])
    }

    func testUnsupportedBackupBesideValidPrimaryIsNotOverwritten() async throws {
        let fileURL = directory.appendingPathComponent("tasks.json")
        let backupURL = fileURL.appendingPathExtension("backup")
        let original = TaskCoordinator(fileURL: fileURL)
        _ = try await original.enqueue(executablePlan: makePlan(taskID: "old"))
        let primary = try Data(contentsOf: fileURL)
        let future = Data(#"{"version":9001,"tasks":[],"futureField":"preserve"}"#.utf8)
        try future.write(to: backupURL)
        let restored = TaskCoordinator(fileURL: fileURL)
        do {
            _ = try await restored.enqueue(executablePlan: makePlan(taskID: "replacement"))
            XCTFail("A valid primary allowed destruction of an unsupported backup")
        } catch TaskCoordinatorError.persistenceFailed {
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), primary)
        XCTAssertEqual(try Data(contentsOf: backupURL), future)
        let records = await restored.records()
        XCTAssertEqual(records.map(\.id), [TaskID("old")])
    }

    func testMalformedBackupBesideValidPrimaryIsNotOverwritten() async throws {
        let fileURL = directory.appendingPathComponent("tasks.json")
        let backupURL = fileURL.appendingPathExtension("backup")
        let original = TaskCoordinator(fileURL: fileURL)
        _ = try await original.enqueue(executablePlan: makePlan(taskID: "old"))
        let primary = try Data(contentsOf: fileURL)
        let malformed = Data(#"{"version":4,"tasks":[{"id":"recoverable-task","state":"running"}]}"#.utf8)
        try malformed.write(to: backupURL)
        let restored = TaskCoordinator(fileURL: fileURL)
        do {
            _ = try await restored.enqueue(executablePlan: makePlan(taskID: "replacement"))
            XCTFail("A valid primary allowed destruction of a malformed backup")
        } catch TaskCoordinatorError.persistenceFailed {
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), primary)
        XCTAssertEqual(try Data(contentsOf: backupURL), malformed)
        let records = await restored.records()
        XCTAssertEqual(records.map(\.id), [TaskID("old")])
    }

    func testLowerTaskLimitDoesNotInvalidateLargerHistoricalBackup() async throws {
        let fileURL = directory.appendingPathComponent("tasks.json")
        let original = TaskCoordinator(maxTasks: 2, fileURL: fileURL)
        _ = try await original.enqueue(executablePlan: makePlan(taskID: "kept"))
        _ = try await original.enqueue(executablePlan: makePlan(taskID: "finished"))
        _ = try await original.cancel(id: "finished")

        let reduced = TaskCoordinator(maxTasks: 1, fileURL: fileURL)
        let keptRecord = await reduced.record(id: "kept")
        let kept = try XCTUnwrap(keptRecord)
        _ = try await reduced.pause(id: "kept", expectedRevision: kept.revision)
        let reloaded = TaskCoordinator(maxTasks: 1, fileURL: fileURL)
        let record = await reloaded.record(id: "kept")
        XCTAssertEqual(record?.state, .paused)
        XCTAssertEqual(record?.intent, .pause)
        do {
            _ = try await reloaded.enqueue(executablePlan: makePlan(taskID: "over-limit"))
            XCTFail("The current task limit was not enforced")
        } catch TaskCoordinatorError.capacityReached {
        }
    }

    func testMissingPrimaryRetainsBackupTasksForInspection() async throws {
        let fileURL = directory.appendingPathComponent("tasks.json")
        let coordinator = TaskCoordinator(fileURL: fileURL)
        let queued = try await coordinator.enqueue(executablePlan: makePlan(taskID: "retained"))
        _ = try await coordinator.pause(id: "retained", expectedRevision: queued.revision)
        try FileManager.default.removeItem(at: fileURL)
        let reloaded = TaskCoordinator(fileURL: fileURL)
        let records = await reloaded.records()
        XCTAssertEqual(records.map(\.id), [TaskID("retained")])
        XCTAssertEqual(records.first?.recoveryDisposition, .restoredBackup)
        XCTAssertFalse(records.first?.canResumeWorkspaceTask == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testRecoverInterruptedRunMovesOnlyRunningRecordToPaused() async throws {
        let id = TaskID("interrupted")
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: makePlan(taskID: id))
        let approved = try await coordinator.approveWorkspaceAction(id: id, expectedRevision: queued.revision)
        _ = try await coordinator.beginWorkspaceDispatch(id: id, expectedRevision: approved.revision)

        let reloaded = TaskCoordinator(storageDirectory: directory)
        let recovered = try await reloaded.recoverInterruptedRuns()

        XCTAssertEqual(recovered.first?.state, .paused)
        XCTAssertEqual(recovered.first?.intent, .pause)
    }

    func testCancellationIntentSurvivesRecoveryAndCannotResume() async throws {
        let id = TaskID("cancelled")
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: makePlan(taskID: id))
        let approved = try await coordinator.approveWorkspaceAction(id: id, expectedRevision: queued.revision)
        _ = try await coordinator.beginWorkspaceDispatch(id: id, expectedRevision: approved.revision)
        _ = try await coordinator.requestCancellation(id: id)

        let reloaded = TaskCoordinator(storageDirectory: directory)
        _ = try await reloaded.recoverInterruptedRuns()

        let recovered = await reloaded.record(id: id)
        XCTAssertEqual(recovered?.state, .paused)
        XCTAssertTrue(recovered?.cancellationRequested == true)
        XCTAssertFalse(recovered?.canResumeWorkspaceTask == true)
        XCTAssertFalse(recovered?.canStartAutomatically == true)
    }

    func testPausePersistenceFailureIsReturnedAndStateStaysUnchanged() async throws {
        let fileURL = directory.appendingPathComponent("tasks.json")
        let coordinator = TaskCoordinator(fileURL: fileURL)
        let id = TaskID("persistence")
        let queued = try await coordinator.enqueue(executablePlan: makePlan(taskID: id))

        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)

        do {
            _ = try await coordinator.pause(id: id, expectedRevision: queued.revision)
            XCTFail("expected persistence failure")
        } catch TaskCoordinatorError.persistenceFailed {
        } catch {
            XCTFail("expected persistence failure, got \(error)")
        }
        guard case .writeFailed(let path, _) = await coordinator.lastPersistenceError else {
            return XCTFail("expected a surfaced write failure")
        }
        XCTAssertEqual(path, fileURL.path)
        let unchanged = await coordinator.record(id: id)
        XCTAssertEqual(unchanged?.state, .queued)
        XCTAssertEqual(unchanged?.checkpoint.nextStepIndex, 0)
    }

    private func makePlan(taskID: TaskID, goal: String = "demo task") throws -> PerryRuntimes.ExecutionPlan {
        let action = try ExecutableAction(
            id: ActionID("write"),
            summary: "Write report",
            approvalRequirement: .action,
            operation: .transform(
                workspace: directory,
                command: .createUTF8File(path: "report.txt", contents: "contents")
            ),
            postcondition: .fileContents("contents")
        )
        return try PerryRuntimes.ExecutionPlan(
            taskID: taskID,
            goal: goal,
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
    }
}
