import Foundation
import XCTest
import PerryCore
import PerryRuntimes
@testable import PerryGuide

final class TaskRecordRevisionTests: XCTestCase {
    func testReusedTaskIDDoesNotAcceptAnOldLaunchRequest() async throws {
        let coordinator = TaskCoordinator()
        let original = try await coordinator.enqueue(executablePlan: makePlan(taskID: "same-id"))
        _ = try await coordinator.cancel(id: original.id)
        let replacement = try await coordinator.enqueue(executablePlan: makePlan(taskID: "same-id"))

        XCTAssertNotEqual(original.revision, replacement.revision)
        do {
            _ = try await coordinator.approveWorkspaceAction(id: original.id, expectedRevision: original.revision)
            XCTFail("A stale revision must not approve a replaced task")
        } catch TaskCoordinatorError.invalidTransition {
        }
        let retained = await coordinator.record(id: original.id)
        XCTAssertEqual(retained?.revision, replacement.revision)
        XCTAssertEqual(retained?.state, .queued)
    }

    func testMutationIdentitySurvivesRelaunchAndChangesOnPause() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perry-task-revision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: makePlan(taskID: "task"))
        let approved = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        XCTAssertNotEqual(queued.revision, approved.revision)

        let restored = TaskCoordinator(storageDirectory: directory)
        let persisted = await restored.record(id: queued.id)
        XCTAssertEqual(persisted?.revision, approved.revision)
        let paused = try await restored.pause(id: queued.id, expectedRevision: approved.revision)
        XCTAssertNotEqual(paused.revision, approved.revision)
        do {
            _ = try await restored.pause(id: queued.id, expectedRevision: approved.revision)
            XCTFail("A stale revision must not mutate the record")
        } catch TaskCoordinatorError.invalidTransition {
        }
    }

    private func makePlan(taskID: String) throws -> PerryRuntimes.ExecutionPlan {
        let workspace = FileManager.default.temporaryDirectory
        let action = try ExecutableAction(
            id: ActionID("write"),
            summary: "Write report",
            approvalRequirement: .action,
            operation: .transform(
                workspace: workspace,
                command: .createUTF8File(path: "report.txt", contents: "original")
            ),
            postcondition: .fileContents("original")
        )
        return try PerryRuntimes.ExecutionPlan(
            taskID: TaskID(taskID),
            goal: "Write the original report",
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
    }
}
