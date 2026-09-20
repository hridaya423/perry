import XCTest
@testable import Perry
import PerryGuide
import PerryRuntimes

@MainActor
final class BackgroundTaskLaunchGateTests: XCTestCase {
    func testTypedTaskRequiresApprovalBeforeLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perry-typed-launch-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let proposed = try await LocalTaskPlannerRuntime().workspaceExecutionPlan(goal: #"create file "report.txt" with "report""#, workspace: directory, taskID: "task")
        let plan = try XCTUnwrap(proposed)
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: plan)
        XCTAssertNotNil(queued.workspaceActionToApprove)
        XCTAssertNotNil(BackgroundTaskLaunchGate.blocker(record: queued))
        let prepared = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        XCTAssertNil(prepared.workspaceActionToApprove)
        XCTAssertNil(BackgroundTaskLaunchGate.blocker(record: prepared))
        _ = try await coordinator.requestCancellation(id: queued.id)
        let loaded = await coordinator.record(id: queued.id)
        let cancelled = try XCTUnwrap(loaded)
        XCTAssertNotNil(BackgroundTaskLaunchGate.blocker(record: cancelled))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("report.txt").path))
    }

    func testCancelledVerifiedTaskCanLaunchReportingWithoutNewApproval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perry-report-launch-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let proposed = try await LocalTaskPlannerRuntime().workspaceExecutionPlan(goal: #"create file "report.txt" with "report""#, workspace: directory, taskID: "task")
        let plan = try XCTUnwrap(proposed)
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: plan)
        let prepared = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        _ = try await coordinator.executeWorkspaceAction(id: queued.id, expectedRevision: prepared.revision, runtime: WorkspaceFileRuntime(baseURL: directory))
        let cancelled = try await coordinator.requestCancellation(id: queued.id)
        XCTAssertNil(BackgroundTaskLaunchGate.blocker(record: cancelled))
        XCTAssertNil(cancelled.workspaceActionToApprove)
        XCTAssertFalse(cancelled.canStartAutomatically)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("report.txt"), encoding: .utf8), "report")
    }

    func testOnlyOneLaunchCanReserveATask() {
        let gate = BackgroundTaskLaunchGate()
        let taskID = TaskID("task")

        XCTAssertNotNil(gate.acquire(for: taskID))
        XCTAssertNil(gate.acquire(for: taskID))
    }

    func testCancelledLaunchCannotBecomeCurrentAgain() throws {
        let gate = BackgroundTaskLaunchGate()
        let taskID = TaskID("task")
        let oldLease = try XCTUnwrap(gate.acquire(for: taskID))

        gate.cancel(taskID)
        let replacement = try XCTUnwrap(gate.acquire(for: taskID))

        XCTAssertFalse(gate.contains(oldLease))
        XCTAssertTrue(gate.contains(replacement))
    }

    func testStaleReleaseCannotClearReplacementLaunch() throws {
        let gate = BackgroundTaskLaunchGate()
        let taskID = TaskID("task")
        let oldLease = try XCTUnwrap(gate.acquire(for: taskID))
        gate.cancel(taskID)
        let replacement = try XCTUnwrap(gate.acquire(for: taskID))

        gate.release(oldLease)

        XCTAssertTrue(gate.contains(replacement))
    }

    func testResourcesSerializeTheSameApplication() {
        let gate = BackgroundTaskResourceGate()

        XCTAssertTrue(gate.reserve([.application("com.apple.finder")], for: "first"))
        XCTAssertFalse(gate.reserve([.application("com.apple.finder")], for: "second"))
        XCTAssertTrue(gate.reserve([.application("com.apple.TextEdit")], for: "third"))
    }

    func testReleasedResourcesCanBeReservedByTheNextTask() {
        let gate = BackgroundTaskResourceGate()

        XCTAssertTrue(gate.reserve([.integration("slack")], for: "first"))
        gate.release("first")

        XCTAssertTrue(gate.reserve([.integration("slack")], for: "second"))
    }
}
