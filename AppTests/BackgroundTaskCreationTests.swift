import Foundation
import XCTest
import PerryCore
import PerryCapture
import PerryGuide
import PerryRuntimes
@testable import Perry

@MainActor
final class BackgroundTaskCreationTests: XCTestCase {
    func testUndoingAnUndoRepeatsTheOriginalGoal() {
        XCTAssertEqual(BackgroundTaskController.undoGoal(for: "create file a.txt"), "Undo “create file a.txt”")
        XCTAssertEqual(BackgroundTaskController.undoGoal(for: "Undo “create file a.txt”"), "create file a.txt")
    }

    func testStoppedAgentTaskOffersResume() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-background-creation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let controller = makeController(directory: directory, probe: BackgroundCreationProbe())

        _ = try await controller.backgroundTaskCoordinator.enqueue(
            agentPlan: AgentTaskPlan(goal: "tidy the downloads folder", threadID: UUID()), taskID: TaskID()
        )
        await controller.backgroundTasks.reloadRecords()

        let record = try XCTUnwrap(controller.backgroundTasks.records.first)
        XCTAssertTrue(controller.backgroundTasks.canResume(record))
    }

    /// The canonical workspace task: an executable plan enqueued against a
    /// BackgroundWorkspaces slot approves, executes, reports, and notifies —
    /// all without touching desktop permissions or captures.
    func testCanonicalFileTaskApprovesExecutesAndReportsWithoutDesktopCapture() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-background-creation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try TestTempDirectory.remove(directory) }

        let probe = BackgroundCreationProbe()
        let controller = makeController(directory: directory, probe: probe)

        let goal = #"create file "report.txt" with "hello from queue""#
        let taskID = TaskID()
        let workspace = directory
            .appendingPathComponent("BackgroundWorkspaces", isDirectory: true)
            .appendingPathComponent(taskID.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let proposed = try await WorkspaceFilePlanFabricator().workspaceExecutionPlan(
            goal: goal, workspace: workspace, taskID: taskID
        )
        let plan = try XCTUnwrap(proposed)
        let queued = try await controller.backgroundTaskCoordinator.enqueue(executablePlan: plan)
        await controller.backgroundTasks.reloadRecords()

        guard case .executable(let storedPlan) = queued.plan else {
            return XCTFail("expected canonical executable plan")
        }
        let action = try XCTUnwrap(storedPlan.actions.first)
        XCTAssertEqual(storedPlan.taskID, queued.id)
        XCTAssertEqual(storedPlan.goal, goal)
        XCTAssertEqual(queued.workspaceActionToApprove?.id, action.id)
        let fileURL = workspace.appendingPathComponent("report.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        guard case .transform(let actionWorkspace, _) = action.operation else {
            return XCTFail("expected a workspace file action")
        }
        XCTAssertEqual(actionWorkspace.standardizedFileURL.path, workspace.standardizedFileURL.path)

        controller.backgroundTasks.approveWorkspace(queued)
        let fileCompleted = await waitUntil {
            await controller.backgroundTasks.reloadRecords()
            let history = await TranscriptStore(directory: directory).snapshot()
            return await controller.backgroundTasks.debugRecord(queued.id).map(\.isTerminal) ?? true
                && FileManager.default.fileExists(atPath: fileURL.path)
                && history.count == 1
                && probe.notifications.contains(where: { $0.kind == .completed && $0.taskID == queued.id })
        }
        XCTAssertTrue(fileCompleted)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "hello from queue")
        let history = await TranscriptStore(directory: directory).snapshot()
        XCTAssertEqual(history.first?.id, plan.planID)
        XCTAssertEqual(history.first?.outcome, .completed)
        XCTAssertEqual(history.first?.steps, [action.summary])
        XCTAssertEqual(probe.permissionCalls, 0)
        XCTAssertEqual(probe.captureCalls, 0)
        XCTAssertEqual(probe.notifications.filter { $0.kind == .completed }.map(\.taskID), [queued.id])
    }

    /// Undo must run its typed inverse through the journaled path, refuse
    /// re-entry while a pass is in flight, and stop honestly at a conflict
    /// instead of re-dispatching or touching intervening state.
    func testUndoRunsOncePerRecordAndStopsAtConflict() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let trash = directory.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let probe = BackgroundCreationProbe()
        let controller = makeController(directory: directory, probe: probe)
        controller.backgroundTasks.debugTrashURL = trash

        let queued = try await enqueueFileTask(
            on: controller,
            directory: directory,
            goal: #"create file "undo-me.txt" with "revert me""#
        )
        controller.backgroundTasks.approveWorkspace(queued)
        // The record reaches terminal inside the runner before the
        // report-write lands its status message — wait for the whole tail
        // so the undo can't race it.
        let settled = await waitUntil {
            await controller.backgroundTasks.reloadRecords()
            let terminal = await controller.backgroundTasks.debugRecord(queued.id)?.isTerminal ?? false
            return terminal && controller.backgroundTasks.message(for: queued.id) != nil
                && !controller.backgroundTasks.isRunning(queued.id)
        }
        XCTAssertTrue(settled)
        let record = try XCTUnwrap(controller.backgroundTasks.records.first)
        guard case .executable(let plan) = record.plan,
              case .transform(let workspace, _)? = plan.actions.first?.operation else {
            return XCTFail("expected a workspace file plan")
        }
        let fileURL = workspace.appendingPathComponent("undo-me.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(controller.backgroundTasks.undoableDescriptions(for: record).isEmpty)

        controller.backgroundTasks.undoWorkspaceChanges(record)
        XCTAssertTrue(controller.backgroundTasks.isUndoing(record.id))
        // A second request while the pass is in flight must be refused —
        // the inverses cannot dispatch twice.
        controller.backgroundTasks.undoWorkspaceChanges(record)

        let undone = await waitUntil {
            !controller.backgroundTasks.isUndoing(record.id)
                && !FileManager.default.fileExists(atPath: fileURL.path)
        }
        XCTAssertTrue(undone)
        XCTAssertEqual(controller.backgroundTasks.message(for: record.id), "Undid 1 change.")
        let trashEntries = try FileManager.default.contentsOfDirectory(atPath: trash.path)
        XCTAssertEqual(trashEntries.count, 1)

        // A later Undo on the same record hits the conflict check and stops
        // without touching anything — no silent second dispatch.
        controller.backgroundTasks.undoWorkspaceChanges(record)
        let conflicted = await waitUntil {
            !controller.backgroundTasks.isUndoing(record.id)
                && (controller.backgroundTasks.message(for: record.id) ?? "").hasPrefix("Nothing was undone")
        }
        XCTAssertTrue(conflicted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// An in-flight Undo is a live handle: worker-stop (erasure/termination)
    /// must drain it rather than let inverses run against deleted workspaces,
    /// and no new recovery may start once controls are closed.
    func testWorkerStopDrainsAnInFlightUndoAndRefusesNewRecovery() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let trash = directory.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let probe = BackgroundCreationProbe()
        let controller = makeController(directory: directory, probe: probe)
        controller.backgroundTasks.debugTrashURL = trash

        let queued = try await enqueueFileTask(
            on: controller,
            directory: directory,
            goal: #"create file "drain-me.txt" with "revert me""#
        )
        controller.backgroundTasks.approveWorkspace(queued)
        let settled = await waitUntil {
            await controller.backgroundTasks.reloadRecords()
            let terminal = await controller.backgroundTasks.debugRecord(queued.id)?.isTerminal ?? false
            return terminal && controller.backgroundTasks.message(for: queued.id) != nil
                && !controller.backgroundTasks.isRunning(queued.id)
        }
        XCTAssertTrue(settled)
        let record = try XCTUnwrap(controller.backgroundTasks.records.first)
        guard case .executable(let plan) = record.plan,
              case .transform(let workspace, _)? = plan.actions.first?.operation else {
            return XCTFail("expected a workspace file plan")
        }
        let fileURL = workspace.appendingPathComponent("drain-me.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        controller.backgroundTasks.undoWorkspaceChanges(record)
        XCTAssertTrue(controller.backgroundTasks.isUndoing(record.id))

        try await controller.backgroundTasks.pauseAllOwnedForWorkerStop()
        XCTAssertFalse(controller.backgroundTasks.isUndoing(record.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(controller.backgroundTasks.message(for: record.id), "Undid 1 change.")

        controller.backgroundTasks.undoWorkspaceChanges(record)
        XCTAssertFalse(controller.backgroundTasks.isUndoing(record.id))
    }

    func testMetadataWriteFailureRollsBackTheQueuedPlan() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let contextPath = directory.appendingPathComponent("background-task-context.json")
        try FileManager.default.createDirectory(at: contextPath, withIntermediateDirectories: false)
        let probe = BackgroundCreationProbe()
        let controller = makeController(directory: directory, probe: probe)
        controller.backgroundTasks.queue(goal: "summarize my downloads folder")

        let failed = await waitUntil { controller.sessionStatus.hasPrefix("Couldn’t queue the background task:") }
        XCTAssertTrue(failed)
        let workspaces = try? FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("BackgroundWorkspaces"),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(workspaces?.isEmpty ?? true)
        let records = await TaskCoordinator(storageDirectory: directory).records()
        let metadata = await BackgroundTaskContextStore(storageDirectory: directory).snapshot()
        let history = await TranscriptStore(directory: directory).snapshot()
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(metadata.isEmpty)
        XCTAssertTrue(history.isEmpty)
        XCTAssertTrue(probe.notifications.isEmpty)
        XCTAssertEqual(probe.permissionCalls, 0)
        XCTAssertEqual(probe.captureCalls, 0)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-background-creation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeController(
        directory: URL,
        probe: BackgroundCreationProbe
    ) -> AppController {
        let inspector = RuntimeInventoryInspector(
            readDirectProvider: { nil },
            commandLineProviders: []
        )
        return AppController(
            debugStorageDirectory: directory,
            runtimeInventoryLoader: { workingDirectory in
                try await inspector.inspect(workingDirectory: workingDirectory)
            },
            permissionSnapshotLoader: {
                probe.incrementPermission()
                XCTFail("background task tests must not request desktop permissions")
                return PerryPermissionSnapshot(
                    accessibility: true,
                    screenRecording: .granted,
                    microphone: .granted
                )
            },
            screenContextLoader: { _, _ in
                probe.incrementCapture()
                XCTFail("background task tests must not capture the desktop")
                return (ScreenContext.empty, nil)
            },
            notifier: probe
        )
    }

    /// Fabricates a canonical workspace-file task the way the retired planner
    /// produced it — direct enqueue keeps workspace-task coverage honest.
    private func enqueueFileTask(
        on controller: AppController,
        directory: URL,
        goal: String
    ) async throws -> TaskRecord {
        let taskID = TaskID()
        let workspace = directory
            .appendingPathComponent("BackgroundWorkspaces", isDirectory: true)
            .appendingPathComponent(taskID.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let proposed = try await WorkspaceFilePlanFabricator().workspaceExecutionPlan(
            goal: goal, workspace: workspace, taskID: taskID
        )
        let plan = try XCTUnwrap(proposed)
        let queued = try await controller.backgroundTaskCoordinator.enqueue(executablePlan: plan)
        await controller.backgroundTasks.reloadRecords()
        XCTAssertNotNil(queued.workspaceActionToApprove)
        return queued
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            do {
                try await Task.sleep(
                    until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(10))),
                    clock: .continuous
                )
            } catch {
                return false
            }
        }
        return await condition()
    }
}

private final class BackgroundCreationProbe: AppNotificationClient, @unchecked Sendable {
    private let lock = NSLock()
    private var permissionCount = 0
    private var captureCount = 0
    private var notificationAuthorizationCount = 0
    private var deliveredNotifications: [TaskNotification] = []

    var notifications: [TaskNotification] {
        lock.withLock { deliveredNotifications }
    }

    func configure(
        onApprove: @escaping @MainActor @Sendable (TaskID, String, UUID) -> Void,
        onDeny: @escaping @MainActor @Sendable (TaskID, UUID) -> Void,
        onOpen: @escaping @MainActor @Sendable () -> Void
    ) {}

    func requestAuthorization() async -> Bool {
        lock.withLock { notificationAuthorizationCount += 1 }
        return true
    }

    func deliver(_ notification: TaskNotification) async {
        lock.withLock { deliveredNotifications.append(notification) }
    }

    var permissionCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return permissionCount
    }

    var captureCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return captureCount
    }

    var notificationAuthorizationCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return notificationAuthorizationCount
    }

    func incrementPermission() {
        lock.lock()
        permissionCount += 1
        lock.unlock()
    }

    func incrementCapture() {
        lock.lock()
        captureCount += 1
        lock.unlock()
    }

}

