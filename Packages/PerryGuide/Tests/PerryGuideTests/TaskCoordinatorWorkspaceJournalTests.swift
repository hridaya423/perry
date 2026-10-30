import Darwin
import Foundation
import XCTest
import PerryCore
import PerryRuntimes
@testable import PerryGuide

final class TaskCoordinatorWorkspaceJournalTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-task-coordinator-journal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let directory {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testCancellationRejectsStaleRevisionBeforeClearingPreparedAction() async throws {
        let plan = try makePlan()
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: plan)
        let prepared = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)

        do {
            _ = try await coordinator.requestCancellation(id: queued.id, expectedRevision: queued.revision)
            XCTFail("A stale cancellation notification was accepted")
        } catch TaskCoordinatorError.invalidTransition {
        }

        let unchangedRecord = await coordinator.record(id: queued.id)
        let unchanged = try XCTUnwrap(unchangedRecord)
        XCTAssertEqual(unchanged.revision, prepared.revision)
        XCTAssertFalse(unchanged.cancellationRequested)
        XCTAssertNotNil(unchanged.workspaceJournal?.current)

        let cancelled = try await coordinator.requestCancellation(id: queued.id, expectedRevision: prepared.revision)
        XCTAssertTrue(cancelled.cancellationRequested)
        XCTAssertNil(cancelled.workspaceJournal?.current)
        XCTAssertTrue(cancelled.workspaceJournal?.completed.isEmpty == true)
        XCTAssertFalse(cancelled.canReportWorkspaceTask)
    }

    func testLegacyPreparedGrantWithoutExpiryRequiresReapprovalBeforeDispatch() async throws {
        let fileURL = directory.appendingPathComponent("tasks.json")
        let source = TaskCoordinator(fileURL: fileURL)
        let plan = try makePlan()
        let queued = try await source.enqueue(executablePlan: plan)
        let prepared = try await source.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)

        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        var tasks = try XCTUnwrap(envelope["tasks"] as? [[String: Any]])
        var task = try XCTUnwrap(tasks.first)
        var journal = try XCTUnwrap(task["workspaceJournal"] as? [String: Any])
        var current = try XCTUnwrap(journal["current"] as? [String: Any])
        var preparedPayload = try XCTUnwrap(current["prepared"] as? [String: Any])
        var attempt = try XCTUnwrap(preparedPayload["_0"] as? [String: Any])
        var grant = try XCTUnwrap(attempt["grant"] as? [String: Any])
        grant.removeValue(forKey: "expiresAt")
        grant["issuedAt"] = 0
        attempt["grant"] = grant
        preparedPayload["_0"] = attempt
        current["prepared"] = preparedPayload
        journal["current"] = current
        task["workspaceJournal"] = journal
        tasks[0] = task
        envelope["tasks"] = tasks
        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: fileURL, options: .atomic)

        let restored = TaskCoordinator(fileURL: fileURL)
        let staleRecordValue = await restored.record(id: plan.taskID)
        let staleRecord = try XCTUnwrap(staleRecordValue)
        XCTAssertEqual(staleRecord.recoveryDisposition, .staleLegacyApproval)
        XCTAssertTrue(staleRecord.requiresReconciliation)
        XCTAssertFalse(staleRecord.canResumeWorkspaceTask)
        XCTAssertNotNil(staleRecord.workspaceActionToApprove)

        do {
            _ = try await restored.beginWorkspaceDispatch(id: plan.taskID, expectedRevision: staleRecord.revision)
            XCTFail("A stale legacy grant was dispatched")
        } catch TaskCoordinatorError.invalidTransition {
        }

        let reapproved = try await restored.approveWorkspaceAction(id: plan.taskID, expectedRevision: staleRecord.revision)
        XCTAssertEqual(reapproved.recoveryDisposition, .current)
        XCTAssertFalse(reapproved.requiresReconciliation)
        XCTAssertTrue(reapproved.canResumeWorkspaceTask)
        XCTAssertNotEqual(reapproved.workspaceJournal?.current?.attempt.grant.id, prepared.workspaceJournal?.current?.attempt.grant.id)
    }

    func testExpiredModernPreparedGrantCannotDispatchOrCallExecutorBeforeReapproval() async throws {
        let fileURL = directory.appendingPathComponent("tasks.json")
        let workspace = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let source = TaskCoordinator(fileURL: fileURL)
        let plan = try makePlan(workspace: workspace, taskID: TaskID("expired-modern-grant"))
        let queued = try await source.enqueue(executablePlan: plan)
        let prepared = try await source.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)

        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        var tasks = try XCTUnwrap(envelope["tasks"] as? [[String: Any]])
        var task = try XCTUnwrap(tasks.first)
        var journal = try XCTUnwrap(task["workspaceJournal"] as? [String: Any])
        var current = try XCTUnwrap(journal["current"] as? [String: Any])
        var preparedPayload = try XCTUnwrap(current["prepared"] as? [String: Any])
        var attempt = try XCTUnwrap(preparedPayload["_0"] as? [String: Any])
        var grant = try XCTUnwrap(attempt["grant"] as? [String: Any])
        grant["issuedAt"] = 0
        grant["expiresAt"] = 60
        attempt["grant"] = grant
        preparedPayload["_0"] = attempt
        current["prepared"] = preparedPayload
        journal["current"] = current
        task["workspaceJournal"] = journal
        tasks[0] = task
        envelope["tasks"] = tasks
        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: fileURL, options: .atomic)

        let restored = TaskCoordinator(fileURL: fileURL)
        let staleRecordValue = await restored.record(id: plan.taskID)
        let staleRecord = try XCTUnwrap(staleRecordValue)
        XCTAssertEqual(staleRecord.recoveryDisposition, .staleLegacyApproval)
        XCTAssertTrue(staleRecord.requiresReconciliation)
        XCTAssertNotNil(staleRecord.workspaceActionToApprove)

        do {
            _ = try await restored.executeWorkspaceAction(
                id: plan.taskID,
                expectedRevision: staleRecord.revision,
                runtime: WorkspaceFileRuntime(baseURL: workspace)
            )
            XCTFail("An expired modern grant was dispatched")
        } catch TaskCoordinatorError.invalidTransition {
        }

        let retainedRecordValue = await restored.record(id: plan.taskID)
        let retained = try XCTUnwrap(retainedRecordValue)
        guard case .prepared = retained.workspaceJournal?.current else {
            return XCTFail("Expired grant changed the journal to a dispatched phase")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("report.txt").path))
        let reapproved = try await restored.approveWorkspaceAction(id: plan.taskID, expectedRevision: retained.revision)
        XCTAssertEqual(reapproved.recoveryDisposition, .current)
        XCTAssertFalse(reapproved.requiresReconciliation)
        XCTAssertNotEqual(reapproved.workspaceJournal?.current?.attempt.grant.id, prepared.workspaceJournal?.current?.attempt.grant.id)
    }

    func testRestoredBackupDominatesExpiredGrantUntilExplicitReconciliation() async throws {
        let fileURL = directory.appendingPathComponent("tasks.json")
        let source = TaskCoordinator(fileURL: fileURL)
        let plan = try makePlan(taskID: TaskID("backup-expired-grant"))
        let queued = try await source.enqueue(executablePlan: plan)
        let prepared = try await source.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        _ = try await source.pause(id: queued.id, expectedRevision: prepared.revision)
        try Data("corrupt-primary".utf8).write(to: fileURL, options: .atomic)

        let restored = TaskCoordinator(fileURL: fileURL)
        let restoredRecordValue = await restored.record(id: plan.taskID)
        let restoredRecord = try XCTUnwrap(restoredRecordValue)
        XCTAssertEqual(restoredRecord.recoveryDisposition, .restoredBackup)

        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        var tasks = try XCTUnwrap(envelope["tasks"] as? [[String: Any]])
        var task = try XCTUnwrap(tasks.first)
        var journal = try XCTUnwrap(task["workspaceJournal"] as? [String: Any])
        var current = try XCTUnwrap(journal["current"] as? [String: Any])
        var preparedPayload = try XCTUnwrap(current["prepared"] as? [String: Any])
        var attempt = try XCTUnwrap(preparedPayload["_0"] as? [String: Any])
        var grant = try XCTUnwrap(attempt["grant"] as? [String: Any])
        grant["issuedAt"] = 0
        grant["expiresAt"] = 60
        attempt["grant"] = grant
        preparedPayload["_0"] = attempt
        current["prepared"] = preparedPayload
        journal["current"] = current
        task["workspaceJournal"] = journal
        tasks[0] = task
        envelope["tasks"] = tasks
        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: fileURL, options: .atomic)

        let reloaded = TaskCoordinator(fileURL: fileURL)
        let blockedRecordValue = await reloaded.record(id: plan.taskID)
        let blockedRecord = try XCTUnwrap(blockedRecordValue)
        XCTAssertEqual(blockedRecord.recoveryDisposition, .restoredBackup)
        XCTAssertTrue(blockedRecord.requiresReconciliation)
        XCTAssertNil(blockedRecord.workspaceActionToApprove)

        do {
            _ = try await reloaded.approveWorkspaceAction(id: plan.taskID, expectedRevision: blockedRecord.revision)
            XCTFail("Reapproval cleared a backup recovery barrier")
        } catch TaskCoordinatorError.invalidTransition {
        }
        do {
            _ = try await reloaded.beginWorkspaceDispatch(id: plan.taskID, expectedRevision: blockedRecord.revision)
            XCTFail("A backup-recovered action was dispatched")
        } catch TaskCoordinatorError.invalidTransition {
        }
        let retainedAfterRejectionValue = await reloaded.record(id: plan.taskID)
        let retainedAfterRejection = try XCTUnwrap(retainedAfterRejectionValue)
        XCTAssertEqual(retainedAfterRejection.recoveryDisposition, .restoredBackup)
        guard case .prepared = retainedAfterRejection.workspaceJournal?.current else {
            return XCTFail("Backup recovery changed the prepared journal before reconciliation")
        }

        let reconciled = try await reloaded.reconcileWorkspaceAction(id: plan.taskID, expectedRevision: blockedRecord.revision)
        XCTAssertEqual(reconciled.recoveryDisposition, .current)
        XCTAssertFalse(reconciled.requiresReconciliation)
        XCTAssertNil(reconciled.workspaceJournal?.current)
        XCTAssertNotNil(reconciled.workspaceActionToApprove)

        let reapproved = try await reloaded.approveWorkspaceAction(id: plan.taskID, expectedRevision: reconciled.revision)
        XCTAssertEqual(reapproved.recoveryDisposition, .current)
        XCTAssertNotNil(reapproved.workspaceJournal?.current)
    }

    func testPartialCancellationReportsPrefixThenRemovesOnlyAfterFinish() async throws {
        let workspace = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let plan = try makePlan(workspace: workspace, actionCount: 2)
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: plan)
        let firstPrepared = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        let partial = try await coordinator.executeWorkspaceAction(
            id: queued.id,
            expectedRevision: firstPrepared.revision,
            runtime: WorkspaceFileRuntime(baseURL: workspace)
        )
        let secondPrepared = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: partial.revision)
        let cancelled = try await coordinator.requestCancellation(id: queued.id, expectedRevision: secondPrepared.revision)

        XCTAssertEqual(cancelled.workspaceJournal?.completed.count, 1)
        XCTAssertNil(cancelled.workspaceJournal?.current)
        XCTAssertTrue(cancelled.canReportWorkspaceTask)
        XCTAssertTrue(cancelled.canResumeWorkspaceTask)

        let outcome = try await coordinator.workspaceReportOutcome(id: queued.id, expectedRevision: cancelled.revision)
        XCTAssertEqual(outcome, .blocked(reason: "user cancelled the task"))
        let retained = await coordinator.record(id: queued.id)
        XCTAssertNotNil(retained)

        let finished = try await coordinator.finishWorkspaceTask(id: queued.id, expectedRevision: cancelled.revision)
        XCTAssertEqual(finished, outcome)
        let terminal = await coordinator.record(id: queued.id)
        XCTAssertEqual(terminal?.state, .blocked)
        XCTAssertTrue(terminal?.isTerminal ?? false)
        XCTAssertEqual(terminal?.workspaceJournal?.completed.count, 1)
        let reloaded = TaskCoordinator(storageDirectory: directory)
        let persisted = await reloaded.record(id: queued.id)
        XCTAssertEqual(persisted?.state, .blocked)
        XCTAssertEqual(persisted?.workspaceJournal?.completed.count, 1)
        try await reloaded.remove(id: queued.id)
        let afterRemoval = await reloaded.records()
        XCTAssertTrue(afterRemoval.isEmpty)
    }

    func testFullPrefixReportRequiresExplicitFinishAndPersistsV5Journal() async throws {
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: try makePlan())
        let prepared = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        let completed = try await coordinator.executeWorkspaceAction(
            id: queued.id,
            expectedRevision: prepared.revision,
            runtime: WorkspaceFileRuntime(baseURL: directory)
        )

        XCTAssertTrue(completed.canReportWorkspaceTask)
        XCTAssertTrue(completed.canResumeWorkspaceTask)
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("tasks.json"))
            ) as? [String: Any]
        )
        XCTAssertEqual(envelope["version"] as? Int, 5)

        let outcome = try await coordinator.workspaceReportOutcome(id: queued.id, expectedRevision: completed.revision)
        XCTAssertEqual(outcome, .completed(stepsRun: 1))
        let retained = await coordinator.record(id: queued.id)
        XCTAssertNotNil(retained)
        let finished = try await coordinator.finishWorkspaceTask(id: queued.id, expectedRevision: completed.revision)
        XCTAssertEqual(finished, outcome)
        let terminal = await coordinator.record(id: queued.id)
        XCTAssertEqual(terminal?.state, .completed)
        XCTAssertTrue(terminal?.isTerminal ?? false)
        XCTAssertEqual(terminal?.workspaceJournal?.completed.count, 1)
    }

    func testVersionFourRunningVerifiedRecordMigratesToCompletedPrefix() async throws {
        let workspace = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let plan = try makePlan(workspace: workspace, actionCount: 2)
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action(plan.actions[0].id))
        let receipt = try await WorkspaceFileRuntime(baseURL: workspace).execute(
            plan: plan,
            actionID: plan.actions[0].id,
            grantID: grant.id,
            registry: registry
        )
        let attempt = WorkspaceActionJournal.Attempt(actionIndex: 0, grant: grant)
        let encoder = JSONEncoder()
        let task: [String: Any] = [
            "id": plan.taskID.rawValue,
            "revision": UUID().uuidString,
            "planKind": "executable",
            "executionPlan": try JSONSerialization.jsonObject(with: encoder.encode(plan)),
            "state": "running",
            "nextStepIndex": 1,
            "intent": "none",
            "recoveryDisposition": "current",
            "workspaceJournal": ["verified": [
                "_0": try JSONSerialization.jsonObject(with: encoder.encode(attempt)),
                "_1": try JSONSerialization.jsonObject(with: encoder.encode(receipt)),
            ]],
        ]
        let fileURL = directory.appendingPathComponent("tasks.json")
        try JSONSerialization.data(withJSONObject: ["version": 4, "tasks": [task]])
            .write(to: fileURL, options: .atomic)

        let coordinator = TaskCoordinator(fileURL: fileURL)
        let loadedRecord = await coordinator.record(id: plan.taskID)
        let loaded = try XCTUnwrap(loadedRecord)
        XCTAssertEqual(loaded.state, .running)
        XCTAssertEqual(loaded.checkpoint.nextStepIndex, 1)
        XCTAssertEqual(loaded.workspaceJournal?.completed.count, 1)
        XCTAssertNil(loaded.workspaceJournal?.current)

        _ = try await coordinator.recoverInterruptedRuns()
        let recoveredRecord = await coordinator.record(id: plan.taskID)
        let recovered = try XCTUnwrap(recoveredRecord)
        XCTAssertEqual(recovered.state, .paused)
        XCTAssertEqual(recovered.intent, .pause)
        XCTAssertEqual(recovered.workspaceJournal?.completed.count, 1)
    }

    func testMalformedDispatchedPlanScopeIsRejectedBeforeRecordAdoption() async throws {
        let sourceDirectory = directory.appendingPathComponent("source")
        let targetDirectory = directory.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: false)
        let workspace = sourceDirectory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let plan = try makePlan(workspace: workspace)
        let sourceFile = sourceDirectory.appendingPathComponent("tasks.json")
        let source = TaskCoordinator(fileURL: sourceFile)
        let queued = try await source.enqueue(executablePlan: plan)
        let prepared = try await source.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        _ = try await source.beginWorkspaceDispatch(id: queued.id, expectedRevision: prepared.revision)

        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sourceFile)) as? [String: Any])
        var tasks = try XCTUnwrap(envelope["tasks"] as? [[String: Any]])
        var task = try XCTUnwrap(tasks.first)
        var journal = try XCTUnwrap(task["workspaceJournal"] as? [String: Any])
        var current = try XCTUnwrap(journal["current"] as? [String: Any])
        var dispatched = try XCTUnwrap(current["dispatched"] as? [String: Any])
        var attempt = try XCTUnwrap(dispatched["_0"] as? [String: Any])
        var grant = try XCTUnwrap(attempt["grant"] as? [String: Any])
        grant["scope"] = ["plan": [:]]
        attempt["grant"] = grant
        dispatched["_0"] = attempt
        current["dispatched"] = dispatched
        journal["current"] = current
        task["workspaceJournal"] = journal
        tasks[0] = task
        envelope["tasks"] = tasks
        let targetFile = targetDirectory.appendingPathComponent("tasks.json")
        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
            .write(to: targetFile, options: .atomic)

        let restored = TaskCoordinator(fileURL: targetFile)
        let records = await restored.records()
        XCTAssertTrue(records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetFile.path))
        guard case .recoveredCorruptFile = await restored.lastPersistenceError else {
            return XCTFail("Malformed dispatched grant was adopted")
        }
    }

    func testUnsupportedTypedActionsAreRejectedBeforeAnyStoreMutation() async throws {
        let window = ExecutableAction.WindowIdentity(
            bundleID: "com.example.App",
            processID: 1,
            windowID: 1,
            connectionGeneration: 1
        )
        let executable = ExecutableAction.ExecutableIdentity(
            path: URL(fileURLWithPath: "/usr/bin/true"),
            version: "1",
            sha256: String(repeating: "a", count: 64)
        )
        let oversizedContents = String(
            repeating: "x",
            count: WorkspaceFileRuntime.maximumFileCreationBytes + 1
        )
        let plans = [
            try makeTypedPlan(
                taskID: "unsupported-computer",
                action: try makeAction(
                    id: "computer-action",
                    operation: .computer(
                        window: window,
                        command: .click(.accessibilityID("save"))
                    ),
                    postcondition: .elementValue("saved")
                )
            ),
            try makeTypedPlan(
                taskID: "unsupported-integration",
                action: try makeAction(
                    id: "integration-action",
                    operation: .integration(
                        accountID: "slack",
                        command: .slackSendMessage(channelID: "C123", text: "hello")
                    ),
                    postcondition: .integrationResource(identifier: "message", expectedText: "hello")
                )
            ),
            try makeTypedPlan(
                taskID: "unsupported-shell",
                action: try makeAction(
                    id: "shell-action",
                    operation: .shell(
                        workspace: directory,
                        executable: executable,
                        confinement: .workspaceReadOnly,
                        command: .registeredCommand(arguments: ["true"])
                    ),
                    postcondition: .workspaceFileContents(path: "output.txt", contents: "")
                )
            ),
            try makeTypedPlan(
                taskID: "unsupported-plan-approval",
                action: try makeAction(
                    id: "plan-approved-action",
                    operation: .transform(
                        workspace: directory,
                        command: .createUTF8File(path: "plan.txt", contents: "hello")
                    ),
                    postcondition: .fileContents("hello"),
                    approvalRequirement: .plan
                )
            ),
            try makeTypedPlan(
                taskID: "unsupported-large-file",
                action: try makeAction(
                    id: "large-file-action",
                    operation: .transform(
                        workspace: directory,
                        command: .createUTF8File(path: "large.txt", contents: oversizedContents)
                    ),
                    postcondition: .fileContents(oversizedContents)
                )
            ),
        ]

        for (index, plan) in plans.enumerated() {
            let caseDirectory = directory.appendingPathComponent("unsupported-\(index)")
            try FileManager.default.createDirectory(at: caseDirectory, withIntermediateDirectories: false)
            let fileURL = caseDirectory.appendingPathComponent("tasks.json")
            let coordinator = TaskCoordinator(fileURL: fileURL)
            let actionID = try XCTUnwrap(plan.actions.first?.id)

            do {
                _ = try await coordinator.enqueue(executablePlan: plan)
                XCTFail("Unsupported typed action was queued")
            } catch TaskCoordinatorError.unsupportedExecutableAction(let rejectedID, let reason) {
                XCTAssertEqual(rejectedID, actionID)
                XCTAssertFalse(reason.isEmpty)
            } catch {
                XCTFail("Unexpected enqueue error: \(error)")
            }

            let records = await coordinator.records()
            XCTAssertTrue(records.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    func testUnsupportedLaterTypedActionIsRejectedBeforeAnyStoreMutation() async throws {
        let first = try makeAction(
            id: "first-file",
            operation: .transform(
                workspace: directory,
                command: .createUTF8File(path: "first.txt", contents: "first")
            ),
            postcondition: .fileContents("first")
        )
        let later = try makeAction(
            id: "later-computer",
            operation: .computer(
                window: .init(
                    bundleID: "com.apple.TextEdit",
                    processID: 1,
                    windowID: 1,
                    connectionGeneration: 1
                ),
                command: .click(.accessibilityID("save"))
            ),
            postcondition: .elementValue("saved")
        )
        let plan = try PerryRuntimes.ExecutionPlan(
            taskID: TaskID("unsupported-later-action"),
            goal: "Create a file and folder",
            actions: [first, later],
            requestedScopes: [.workspaceWrite, .computerControl]
        )
        let fileURL = directory.appendingPathComponent("later-action-tasks.json")
        let coordinator = TaskCoordinator(fileURL: fileURL)

        do {
            _ = try await coordinator.enqueue(executablePlan: plan)
            XCTFail("A plan with a later unsupported action was queued")
        } catch TaskCoordinatorError.unsupportedExecutableAction(let actionID, _) {
            XCTAssertEqual(actionID, later.id)
        } catch {
            XCTFail("Unexpected enqueue error: \(error)")
        }

        let records = await coordinator.records()
        XCTAssertTrue(records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testMultiCreateTypedPlanEnqueuesAsOneQueuedRecord() async throws {
        let plan = try makePlan(
            workspace: directory,
            actionCount: 3,
            taskID: TaskID("multi-create")
        )
        let fileURL = directory.appendingPathComponent("multi-create-tasks.json")
        let coordinator = TaskCoordinator(fileURL: fileURL)

        let record = try await coordinator.enqueue(executablePlan: plan)

        guard case .executable(let storedPlan) = record.plan else {
            return XCTFail("Typed plan was not retained")
        }
        XCTAssertEqual(storedPlan.actions.map(\.id), plan.actions.map(\.id))
        XCTAssertEqual(record.workspaceActionToApprove?.id, plan.actions[0].id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let reloaded = TaskCoordinator(fileURL: fileURL)
        let loadedRecord = await reloaded.record(id: plan.taskID)
        let reloadedRecord = try XCTUnwrap(loadedRecord)
        guard case .executable(let reloadedPlan) = reloadedRecord.plan else {
            return XCTFail("Reloaded typed plan changed representation")
        }
        XCTAssertEqual(reloadedPlan.actions.map(\.id), plan.actions.map(\.id))
    }

    func testDirectoryCreationCompletesThroughDurableApprovalAndExecution() async throws {
        let action = try makeAction(
            id: "mkdir",
            operation: .transform(
                workspace: directory,
                command: .createDirectory(path: "reports")
            ),
            postcondition: .directoryExists
        )
        let plan = try makeTypedPlan(taskID: "durable-directory", action: action)
        let fileURL = directory.appendingPathComponent("durable-directory-tasks.json")
        let coordinator = TaskCoordinator(fileURL: fileURL)
        let queued = try await coordinator.enqueue(executablePlan: plan)

        let approved = try await coordinator.approveWorkspaceAction(
            id: plan.taskID,
            expectedRevision: queued.revision
        )
        let executed = try await coordinator.executeWorkspaceAction(
            id: plan.taskID,
            expectedRevision: approved.revision,
            runtime: WorkspaceFileRuntime(baseURL: directory)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("reports").path))
        XCTAssertEqual(executed.checkpoint.nextStepIndex, 1)
        XCTAssertNil(executed.workspaceJournal?.current)
        XCTAssertEqual(executed.workspaceJournal?.completed.count, 1)

        let reloaded = TaskCoordinator(fileURL: fileURL)
        let loaded = await reloaded.record(id: plan.taskID)
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.checkpoint.nextStepIndex, 1)
        XCTAssertEqual(restored.workspaceJournal?.completed.first?.receipt.path, "reports")
        XCTAssertEqual(restored.workspaceJournal?.completed.first?.receipt.byteCount, 0)
    }

    func testRenameCompletesThroughDurableApprovalAndExecution() async throws {
        let source = directory.appendingPathComponent("source.txt")
        try Data("source".utf8).write(to: source)
        var sourceInfo = stat()
        XCTAssertEqual(Darwin.lstat(source.path, &sourceInfo), 0)
        let action = try makeAction(
            id: "rename",
            operation: .transform(
                workspace: directory,
                command: .rename(path: "source.txt", destination: "renamed.txt")
            ),
            postcondition: .renamedItem(
                device: UInt64(sourceInfo.st_dev),
                inode: UInt64(sourceInfo.st_ino)
            )
        )
        let plan = try makeTypedPlan(taskID: "durable-rename", action: action)
        let fileURL = directory.appendingPathComponent("durable-rename-tasks.json")
        let coordinator = TaskCoordinator(fileURL: fileURL)
        let queued = try await coordinator.enqueue(executablePlan: plan)
        let approved = try await coordinator.approveWorkspaceAction(
            id: plan.taskID,
            expectedRevision: queued.revision
        )

        let executed = try await coordinator.executeWorkspaceAction(
            id: plan.taskID,
            expectedRevision: approved.revision,
            runtime: WorkspaceFileRuntime(baseURL: directory)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("renamed.txt")),
            Data("source".utf8)
        )
        XCTAssertEqual(executed.workspaceJournal?.completed.first?.receipt.path, "renamed.txt")
        let reloaded = TaskCoordinator(fileURL: fileURL)
        let loaded = await reloaded.record(id: plan.taskID)
        XCTAssertEqual(loaded?.workspaceJournal?.completed.first?.receipt.path, "renamed.txt")
    }

    func testTrashApprovalPersistsWithoutDispatchingTheEffect() async throws {
        let source = directory.appendingPathComponent("obsolete.txt")
        try Data("obsolete".utf8).write(to: source)
        var sourceInfo = stat()
        XCTAssertEqual(Darwin.lstat(source.path, &sourceInfo), 0)
        let action = try makeAction(
            id: "trash",
            operation: .transform(
                workspace: directory,
                command: .moveToTrash(path: "obsolete.txt")
            ),
            postcondition: .trashedItem(
                device: UInt64(sourceInfo.st_dev),
                inode: UInt64(sourceInfo.st_ino)
            )
        )
        let plan = try makeTypedPlan(taskID: "durable-trash-approval", action: action)
        let fileURL = directory.appendingPathComponent("durable-trash-approval.json")
        let coordinator = TaskCoordinator(fileURL: fileURL)
        let queued = try await coordinator.enqueue(executablePlan: plan)

        let approved = try await coordinator.approveWorkspaceAction(
            id: plan.taskID,
            expectedRevision: queued.revision
        )

        guard case .prepared = approved.workspaceJournal?.current else {
            return XCTFail("Trash approval was not persisted as prepared")
        }
        XCTAssertEqual(try Data(contentsOf: source), Data("obsolete".utf8))
        let reloaded = TaskCoordinator(fileURL: fileURL)
        let loaded = await reloaded.record(id: plan.taskID)
        guard case .prepared = loaded?.workspaceJournal?.current else {
            return XCTFail("Prepared trash approval did not survive relaunch")
        }
    }

    func testStoredUnsupportedTypedPlanRemainsAvailableForInspection() async throws {
        let plan = try makeTypedPlan(
            taskID: "stored-unsupported",
            action: try makeAction(
                id: "stored-computer",
                operation: .computer(
                    window: .init(
                        bundleID: "com.apple.TextEdit",
                        processID: 1,
                        windowID: 1,
                        connectionGeneration: 1
                    ),
                    command: .click(.accessibilityID("save"))
                ),
                postcondition: .elementValue("saved")
            )
        )
        let fileURL = directory.appendingPathComponent("stored-unsupported-tasks.json")
        let executionPlan = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(plan)
        )
        let task: [String: Any] = [
            "id": plan.taskID.rawValue,
            "revision": UUID().uuidString,
            "planKind": "executable",
            "executionPlan": executionPlan,
            "state": "queued",
            "nextStepIndex": 0,
            "intent": "none",
            "recoveryDisposition": "current",
        ]
        let original = try JSONSerialization.data(
            withJSONObject: ["version": 5, "tasks": [task]],
            options: [.sortedKeys]
        )
        try original.write(to: fileURL, options: .atomic)

        let coordinator = TaskCoordinator(fileURL: fileURL)
        let loadedRecord = await coordinator.record(id: plan.taskID)
        let record = try XCTUnwrap(loadedRecord)
        guard case .executable(let storedPlan) = record.plan else {
            return XCTFail("Stored typed plan was not retained for inspection")
        }
        XCTAssertEqual(storedPlan.actions.map(\.id), plan.actions.map(\.id))
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    private func makeAction(
        id: String,
        operation: ExecutableAction.Operation,
        postcondition: ExecutableAction.Postcondition,
        approvalRequirement: ApprovalScope = .action
    ) throws -> ExecutableAction {
        try ExecutableAction(
            id: ActionID(id),
            summary: "Test \(id)",
            approvalRequirement: approvalRequirement,
            operation: operation,
            postcondition: postcondition
        )
    }

    private func makeTypedPlan(
        taskID: String,
        action: ExecutableAction
    ) throws -> PerryRuntimes.ExecutionPlan {
        try PerryRuntimes.ExecutionPlan(
            taskID: TaskID(taskID),
            goal: "Test typed action",
            actions: [action],
            requestedScopes: action.operation.requiredScopes
        )
    }

    private func makePlan(
        workspace: URL? = nil,
        actionCount: Int = 1,
        taskID: TaskID = TaskID("coordinator-workspace-task")
    ) throws -> PerryRuntimes.ExecutionPlan {
        let workspace = try XCTUnwrap(workspace ?? directory)
        let actions = try (0..<actionCount).map { index in
            let name = index == 0 ? "report" : "report-\(index)"
            return try ExecutableAction(
                id: ActionID(index == 0 ? "write" : "write-\(index)"),
                summary: "Create \(name).txt",
                approvalRequirement: .action,
                operation: .transform(
                    workspace: workspace,
                    command: .createUTF8File(
                        path: "\(name).txt",
                        contents: name
                    )
                ),
                postcondition: .fileContents(name)
            )
        }
        return try PerryRuntimes.ExecutionPlan(
            taskID: taskID,
            goal: "Create workspace reports",
            actions: actions,
            requestedScopes: [.workspaceWrite]
        )
    }
}
