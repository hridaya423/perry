import Foundation
import XCTest
@testable import Perry
import PerryGuide
import PerryCore
import PerryRuntimes

@MainActor
final class BackgroundTaskRecoveryNoticeTests: XCTestCase {
    func testActiveUnverifiedActionKeepsLiveControlsButInterruptedActionExplainsRecovery() async throws {
        let directory = try temporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let plan = try executablePlan(taskID: "action", workspace: directory)
        let queued = try await coordinator.enqueue(executablePlan: plan)
        let prepared = try await coordinator.approveWorkspaceAction(
            id: "action", expectedRevision: queued.revision
        )
        let inFlight = try await coordinator.beginWorkspaceDispatch(
            id: "action", expectedRevision: prepared.revision
        )

        XCTAssertNil(BackgroundTaskRecoveryNotice(record: inFlight, isRunning: true))
        XCTAssertEqual(
            BackgroundTaskRecoveryNotice(record: inFlight, isRunning: false), .unverifiedAction
        )
        XCTAssertEqual(
            BackgroundTaskLaunchGate.blocker(record: inFlight),
            BackgroundTaskRecoveryNotice.unverifiedAction.message
        )
        let paused = try await coordinator.pause(id: "action")
        XCTAssertNil(BackgroundTaskRecoveryNotice(record: paused, isRunning: true))
        XCTAssertEqual(
            BackgroundTaskRecoveryNotice(record: paused, isRunning: false), .unverifiedAction
        )
    }

    func testOrdinaryApprovalDoesNotShowRecoveryWarning() async throws {
        let directory = try temporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(
            executablePlan: try executablePlan(taskID: "approval", workspace: directory)
        )
        XCTAssertNil(BackgroundTaskRecoveryNotice(record: queued, isRunning: false))
        XCTAssertNotNil(BackgroundTaskLaunchGate.blocker(record: queued))
        let prepared = try await coordinator.approveWorkspaceAction(
            id: "approval", expectedRevision: queued.revision
        )
        XCTAssertNil(BackgroundTaskRecoveryNotice(record: prepared, isRunning: false))
        XCTAssertNil(BackgroundTaskLaunchGate.blocker(record: prepared))
    }

    func testRestoredBackupTakesPrecedenceOverPreparedApprovalAndLiveFlag() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let fileURL = directory.appendingPathComponent("tasks.json")
        let coordinator = TaskCoordinator(fileURL: fileURL)
        let queued = try await coordinator.enqueue(
            executablePlan: try executablePlan(taskID: "restored", workspace: directory)
        )
        _ = try await coordinator.approveWorkspaceAction(id: "restored", expectedRevision: queued.revision)
        _ = try await coordinator.pause(id: "restored")
        try Data("corrupt-primary".utf8).write(to: fileURL)
        let restored = TaskCoordinator(fileURL: fileURL)
        let record = await restored.record(id: "restored")
        let pending = try XCTUnwrap(record)
        XCTAssertEqual(pending.recoveryDisposition, .restoredBackup)
        XCTAssertEqual(
            BackgroundTaskRecoveryNotice(record: pending, isRunning: false), .restoredBackup
        )
        XCTAssertEqual(
            BackgroundTaskRecoveryNotice(record: pending, isRunning: true), .restoredBackup
        )
        XCTAssertEqual(
            BackgroundTaskLaunchGate.blocker(record: pending),
            BackgroundTaskRecoveryNotice.restoredBackup.message
        )
    }

    func testLaunchPolicyRejectsCancelledAndRetiredPlanTasks() async throws {
        let directory = try temporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(
            executablePlan: try executablePlan(taskID: "cancelled", workspace: directory)
        )
        let cancelled = try await coordinator.requestCancellation(
            id: "cancelled", expectedRevision: queued.revision
        )
        XCTAssertNotNil(BackgroundTaskLaunchGate.blocker(record: cancelled))

        let legacyDirectory = directory.appendingPathComponent("legacy-store", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyStore = """
        {"version":5,"tasks":[{"id":"retired","revision":"\(UUID().uuidString)","planKind":"legacy","goal":"Send the reviewed update","runtimeID":"test","steps":[{"id":"send","kind":"remoteWrite","summary":"Send the update","payload":{}}],"state":"paused","nextStepIndex":0,"intent":"pause","recoveryDisposition":"current"}]}
        """
        try Data(legacyStore.utf8).write(to: legacyDirectory.appendingPathComponent("tasks.json"))
        let legacyCoordinator = TaskCoordinator(storageDirectory: legacyDirectory)
        let retiredRecord = await legacyCoordinator.record(id: "retired")
        let retired = try XCTUnwrap(retiredRecord)
        XCTAssertEqual(
            BackgroundTaskRecoveryNotice(record: retired, isRunning: false), .legacyPlan
        )
        XCTAssertEqual(
            BackgroundTaskLaunchGate.blocker(record: retired),
            BackgroundTaskRecoveryNotice.legacyPlan.message
        )
    }

    private func executablePlan(taskID: TaskID, workspace: URL) throws -> ExecutionPlan {
        let action = try ExecutableAction(
            id: ActionID("create"),
            summary: "Create result.txt",
            approvalRequirement: .action,
            operation: .transform(
                workspace: workspace,
                command: .createUTF8File(path: "result.txt", contents: "done")
            ),
            postcondition: .fileContents("done")
        )
        return try ExecutionPlan(
            taskID: taskID,
            goal: "Create the result file",
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerryRecoveryNotice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
