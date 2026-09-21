import Foundation
import XCTest
import PerryCore
import PerryCapture
import PerryGuide
import PerryRuntimes
@testable import Perry

@MainActor
final class BackgroundTaskCreationTests: XCTestCase {
    func testCanonicalFileQueueApprovesExecutesAndReportsWithoutDesktopCapture() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-background-creation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }

        let probe = BackgroundCreationProbe()
        let inspector = RuntimeInventoryInspector(readDirectProvider: { nil }, commandLineProviders: [])
        let controller = AppController(
            debugStorageDirectory: directory,
            runtimeInventoryLoader: { workingDirectory in
                try await inspector.inspect(workingDirectory: workingDirectory)
            },
            permissionSnapshotLoader: {
                probe.incrementPermission()
                XCTFail("canonical file planning must not request desktop permissions")
                return PerryPermissionSnapshot(
                    accessibility: true,
                    screenRecording: .granted,
                    microphone: .granted
                )
            },
            screenContextLoader: { _, _ in
                probe.incrementCapture()
                XCTFail("canonical file planning must not capture the desktop")
                return (ScreenContext.empty, nil)
            },
            notifier: probe
        )

        let goal = #"create file "report.txt" with "hello from queue""#
        controller.backgroundTasks.queue(goal: goal)
        let queuedAppeared = await waitUntil {
            await controller.backgroundTasks.reloadRecords()
            guard let record = controller.backgroundTasks.records.first,
                  record.workspaceActionToApprove != nil else { return false }
            guard let metadata = await controller.backgroundTasks.debugMetadata(record.id),
                  metadata.workspacePath != nil,
                  metadata.runtimeRoutingSummary?.contains("Perry local planner") == true else { return false }
            return true
        }
        XCTAssertTrue(queuedAppeared)
        let queued = try XCTUnwrap(controller.backgroundTasks.records.first)
        guard case .executable(let plan) = queued.plan else {
            return XCTFail("expected canonical executable plan")
        }
        let action = try XCTUnwrap(plan.actions.first)
        XCTAssertEqual(plan.taskID, queued.id)
        XCTAssertEqual(plan.goal, goal)
        XCTAssertEqual(queued.workspaceActionToApprove?.id, action.id)
        let storedMetadata = await controller.backgroundTasks.debugMetadata(queued.id)
        let metadata = try XCTUnwrap(storedMetadata)
        XCTAssertNil(metadata.targetAppBundleID)
        XCTAssertNil(metadata.targetWindowTitle)
        XCTAssertNil(metadata.targetProcessID)
        XCTAssertNil(metadata.targetWindowID)
        XCTAssertTrue(metadata.runtimeRoutingSummary?.contains("Perry local planner") == true)
        let workspacePath = try XCTUnwrap(metadata.workspacePath)
        XCTAssertTrue(workspacePath.hasPrefix(directory.appendingPathComponent("BackgroundWorkspaces").path + "/"))
        let fileURL = URL(fileURLWithPath: workspacePath).appendingPathComponent("report.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        guard case .transform(let actionWorkspace, _) = action.operation else {
            return XCTFail("expected a workspace file action")
        }
        XCTAssertEqual(actionWorkspace.standardizedFileURL.path, URL(fileURLWithPath: workspacePath).standardizedFileURL.path)

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
        let removedMetadata = await controller.backgroundTasks.debugMetadata(queued.id)
        XCTAssertNil(removedMetadata)
        XCTAssertEqual(probe.permissionCalls, 0)
        XCTAssertEqual(probe.captureCalls, 0)
        XCTAssertEqual(probe.notificationAuthorizationCalls, 1)
        XCTAssertEqual(probe.notifications.filter { $0.kind == .completed }.map(\.taskID), [queued.id])
    }

    /// Undo must run its typed inverse through the journaled path, refuse
    /// re-entry while a pass is in flight, and stop honestly at a conflict
    /// instead of re-dispatching or touching intervening state.
    func testUndoRunsOncePerRecordAndStopsAtConflict() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let trash = directory.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let probe = BackgroundCreationProbe()
        let controller = makeController(
            directory: directory,
            planner: LocalTaskPlannerRuntime(),
            probe: probe
        )
        controller.backgroundTasks.debugTrashURL = trash

        controller.backgroundTasks.queue(goal: #"create file "undo-me.txt" with "revert me""#)
        let queuedAppeared = await waitUntil {
            await controller.backgroundTasks.reloadRecords()
            return controller.backgroundTasks.records.first?.workspaceActionToApprove != nil
        }
        XCTAssertTrue(queuedAppeared)
        let queued = try XCTUnwrap(controller.backgroundTasks.records.first)
        controller.backgroundTasks.approveWorkspace(queued)
        let settled = await waitUntil {
            await controller.backgroundTasks.reloadRecords()
            return await controller.backgroundTasks.debugRecord(queued.id)?.isTerminal ?? false
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

    func testPlanningFailureLeavesNoRecordOrMetadata() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let probe = BackgroundCreationProbe()
        let planner = FailingTaskPlanner(error: PlanningError.typedPlanRejected("fixture failure"))
        let controller = makeController(
            directory: directory,
            planner: planner,
            probe: probe
        )

        controller.backgroundTasks.queue(goal: "a planner failure")
        let called = await waitUntil {
            planner.callCount > 0
        }
        XCTAssertTrue(called)
        let taskID = try XCTUnwrap(planner.requestedTaskID)
        let settled = await waitUntil {
            let record = await controller.backgroundTasks.debugRecord(taskID)
            let metadata = await controller.backgroundTasks.debugMetadata(taskID)
            return !controller.backgroundTasks.isRunning(taskID) && record == nil && metadata == nil
        }
        XCTAssertTrue(settled)
        XCTAssertTrue(controller.backgroundTasks.records.isEmpty)
        XCTAssertEqual(probe.permissionCalls, 0)
        XCTAssertEqual(probe.captureCalls, 0)
        XCTAssertEqual(probe.notificationAuthorizationCalls, 1)
    }

    func testPlanningCancellationLeavesNoRecordOrMetadata() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let probe = BackgroundCreationProbe()
        let planner = FailingTaskPlanner(error: CancellationError())
        let controller = makeController(
            directory: directory,
            planner: planner,
            probe: probe
        )

        controller.backgroundTasks.queue(goal: "a cancelled planning request")
        let called = await waitUntil {
            planner.callCount > 0
        }
        XCTAssertTrue(called)
        let taskID = try XCTUnwrap(planner.requestedTaskID)
        let settled = await waitUntil {
            let record = await controller.backgroundTasks.debugRecord(taskID)
            let metadata = await controller.backgroundTasks.debugMetadata(taskID)
            return !controller.backgroundTasks.isRunning(taskID) && record == nil && metadata == nil
        }
        XCTAssertTrue(settled)
        XCTAssertTrue(controller.backgroundTasks.records.isEmpty)
        XCTAssertEqual(probe.permissionCalls, 0)
        XCTAssertEqual(probe.captureCalls, 0)
        XCTAssertEqual(probe.notificationAuthorizationCalls, 1)
    }

    func testCancellationReachesSuspendedPlannerAndRejectsItsLatePlan() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let probe = BackgroundCreationProbe()
        let planner = SuspendedTaskPlanner()
        let controller = makeController(directory: directory, planner: planner, probe: probe)
        controller.backgroundTasks.queue(goal: #"create file "late.txt" with "must not execute""#)
        let started = await waitUntil { await planner.requestedTaskID != nil }
        XCTAssertTrue(started)
        let requestedID = await planner.requestedTaskID
        let taskID = try XCTUnwrap(requestedID)
        XCTAssertTrue(controller.backgroundTasks.isRunning(taskID))
        let unpublishedRecord = await controller.backgroundTasks.debugRecord(taskID)
        XCTAssertNil(unpublishedRecord)

        let cancelledAt = ContinuousClock.now
        controller.backgroundTasks.cancel(taskID)
        let settled = await waitUntil { !controller.backgroundTasks.isRunning(taskID) }
        let elapsed = cancelledAt.duration(to: .now)
        XCTAssertTrue(settled)
        XCTAssertLessThanOrEqual(elapsed, .milliseconds(500))
        let cancellationObserved = await planner.cancellationObserved
        XCTAssertTrue(cancellationObserved)
        let record = await controller.backgroundTasks.debugRecord(taskID)
        let metadata = await controller.backgroundTasks.debugMetadata(taskID)
        let history = await TranscriptStore(directory: directory).snapshot()
        XCTAssertNil(record)
        XCTAssertNil(metadata)
        XCTAssertTrue(history.isEmpty)
        let file = directory.appendingPathComponent("BackgroundWorkspaces")
            .appendingPathComponent(taskID.rawValue).appendingPathComponent("late.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        XCTAssertEqual(probe.permissionCalls, 0)
        XCTAssertEqual(probe.captureCalls, 0)
    }

    func testMetadataWriteFailureRollsBackTheQueuedPlan() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let contextPath = directory.appendingPathComponent("background-task-context.json")
        try FileManager.default.createDirectory(at: contextPath, withIntermediateDirectories: false)
        let probe = BackgroundCreationProbe()
        let controller = makeController(directory: directory, planner: LocalTaskPlannerRuntime(), probe: probe)
        controller.backgroundTasks.queue(goal: #"create file "blocked.txt" with "must not execute""#)

        let failed = await waitUntil { controller.sessionStatus.hasPrefix("Couldn’t queue the background task:") }
        XCTAssertTrue(failed)
        let workspaces = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("BackgroundWorkspaces"),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(workspaces.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("tasks.json").path))
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
        planner: any TaskPlanner,
        probe: BackgroundCreationProbe
    ) -> AppController {
        let descriptor = RuntimeProviderDescriptor(
            id: RuntimeProviderID(planner.id),
            displayName: "Failure fixture",
            kind: .local,
            capabilities: planner.capabilities,
            operations: [.planning],
            installation: .notApplicable(.local),
            authentication: .notRequired,
            health: .healthy,
            confinement: .workspace,
            priority: 100
        )
        let inventory = RuntimeInventory(
            registry: RuntimeProviderRegistry(providers: [
                RuntimeProvider(planner: planner, descriptor: descriptor)
            ]),
            setup: RuntimeSetupSnapshot(summary: "Failure fixture", records: []),
            choices: [RuntimeChoice(id: planner.id, name: planner.id)],
            automaticPreference: RuntimeProviderID(planner.id),
            credentialFailure: nil
        )
        return AppController(
            debugStorageDirectory: directory,
            runtimeInventoryLoader: { _ in inventory },
            permissionSnapshotLoader: {
                probe.incrementPermission()
                XCTFail("planning failure tests must not request desktop permissions")
                return PerryPermissionSnapshot(
                    accessibility: true,
                    screenRecording: .granted,
                    microphone: .granted
                )
            },
            screenContextLoader: { _, _ in
                probe.incrementCapture()
                XCTFail("planning failure tests must not capture the desktop")
                return (ScreenContext.empty, nil)
            },
            notifier: probe
        )
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

private final class FailingTaskPlanner: TaskPlanner, @unchecked Sendable {
    let id = "fixture.failure"
    let capabilities = RuntimeCapabilities(fileIO: true, latencyClass: .fast)
    private let error: Error
    private let lock = NSLock()
    private var calls = 0
    private var task: TaskID?

    init(error: Error) {
        self.error = error
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var requestedTaskID: TaskID? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }

    func plan(_ request: PlanningRequest) async throws -> ExecutionPlan {
        lock.withLock {
            calls += 1
            task = request.taskID
        }
        throw error
    }
}

private actor SuspendedTaskPlanner: TaskPlanner {
    nonisolated let id = "fixture.suspended"
    nonisolated let capabilities = RuntimeCapabilities(fileIO: true, latencyClass: .fast)
    private(set) var requestedTaskID: TaskID?
    private(set) var cancellationObserved = false

    func plan(_ request: PlanningRequest) async throws -> ExecutionPlan {
        let result = try await LocalTaskPlannerRuntime().plan(request)
        requestedTaskID = request.taskID
        do {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        } catch is CancellationError {
            cancellationObserved = true
        }
        return result
    }
}
