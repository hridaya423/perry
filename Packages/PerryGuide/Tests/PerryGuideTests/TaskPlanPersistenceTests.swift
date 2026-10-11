import Foundation
import XCTest
import PerryCore
import PerryRuntimes
@testable import PerryGuide

final class TaskPlanPersistenceTests: XCTestCase {
    func testExecutablePlanSurvivesRelaunchWithoutEnteringLegacyExecution() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perry-typed-task-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let plan = try makePlan(workspace: directory)
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: plan)
        let restored = TaskCoordinator(storageDirectory: directory)
        let loaded = await restored.record(id: plan.taskID)
        let record = try XCTUnwrap(loaded)
        guard case .executable(let persistedPlan) = record.plan else { return XCTFail("Executable plan changed representation") }
        XCTAssertEqual(try persistedPlan.canonicalData(), try plan.canonicalData())
        XCTAssertEqual(record.revision, queued.revision)
        // A freshly queued typed record needs approval before it can run.
        XCTAssertFalse(record.canResumeWorkspaceTask)
        XCTAssertFalse(record.canStartAutomatically)
        XCTAssertNotNil(record.workspaceActionToApprove)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("report.txt").path))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("tasks.json"))) as? [String: Any])
        XCTAssertEqual(envelope["version"] as? Int, 5)
    }

    func testExecutableRecordRejectsMismatchedIdentityAndMixedLegacyFields() throws {
        let plan = try makePlan(workspace: URL(fileURLWithPath: "/private/tmp/perry-task-codec"))
        let record = TaskRecord(executablePlan: plan)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        for change in ["id", "goal", "planKind", "revision"] {
            var fields = original
            fields[change] = "unrecognized"
            XCTAssertThrowsError(try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: fields)))
        }
    }

    func testVersionThreePlanMigratesOnApprovalAndKeepsOriginalBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perry-v3-migration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let plan = try makePlan(workspace: directory)
        let record = TaskRecord(executablePlan: plan)
        let task = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
        let original = try JSONSerialization.data(withJSONObject: ["version": 3, "tasks": [task]])
        let fileURL = directory.appendingPathComponent("tasks.json")
        try original.write(to: fileURL)

        let restored = TaskCoordinator(storageDirectory: directory)
        let loaded = await restored.record(id: record.id)
        let retained = try XCTUnwrap(loaded)
        XCTAssertEqual(retained.revision, record.revision)
        let approved = try await restored.approveWorkspaceAction(id: record.id, expectedRevision: retained.revision)
        XCTAssertTrue(approved.canStartAutomatically)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        XCTAssertEqual(envelope["version"] as? Int, 5)
        XCTAssertEqual(try Data(contentsOf: fileURL.appendingPathExtension("backup")), original)
        guard case .executable(let migrated) = approved.plan else { return XCTFail("Plan changed representation") }
        XCTAssertEqual(try migrated.canonicalData(), try plan.canonicalData())
    }

    func testAgentPlanSurvivesRelaunchAsResumableQueuedWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perry-agent-task-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let threadID = UUID()
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(agentPlan: AgentTaskPlan(goal: "Reconcile the ledger", threadID: threadID))
        let restored = TaskCoordinator(storageDirectory: directory)
        let loaded = await restored.record(id: queued.id)
        let record = try XCTUnwrap(loaded)
        guard case .agent(let persistedPlan) = record.plan else { return XCTFail("Agent plan changed representation") }
        XCTAssertEqual(persistedPlan.goal, "Reconcile the ledger")
        XCTAssertEqual(persistedPlan.threadID, threadID)
        XCTAssertEqual(record.revision, queued.revision)
        // A queued agent record is safe to relaunch; nothing about it is a
        // workspace step, so workspace predicates stay false.
        XCTAssertTrue(record.canResumeAgentTask)
        XCTAssertFalse(record.canResumeWorkspaceTask)
        XCTAssertNil(record.workspaceActionToApprove)
        XCTAssertEqual(record.plan.actionCount, 0)
    }

    func testAgentRecordRejectsExecutionPlanFields() throws {
        let record = TaskRecord(agentPlan: AgentTaskPlan(goal: "Summarize mail", threadID: UUID()))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        for key in ["executionPlan", "runtimeID", "steps"] {
            var fields = original
            fields[key] = "unrecognized"
            XCTAssertThrowsError(try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: fields)))
        }
    }

    private func makePlan(workspace: URL) throws -> PerryRuntimes.ExecutionPlan {
        let contents = "  e\u{301}\r\n\t🍐\n  "
        let action = try ExecutableAction(
            id: "write", summary: "Write exact report", approvalRequirement: .action,
            operation: .transform(workspace: workspace, command: .createUTF8File(path: "report.txt", contents: contents)),
            postcondition: .fileContents(contents)
        )
        return try PerryRuntimes.ExecutionPlan(taskID: "typed-task", goal: "Write exact report", actions: [action], requestedScopes: [.workspaceWrite])
    }
}
