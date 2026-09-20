import Foundation
import XCTest
import PerryGuide

final class TaskEnvelopeCompatibilityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-envelope-compatibility-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let directory {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testVersionOneRetainsExactPayloadAndSuspendedActionAcrossRewrite() async throws {
        let file = directory.appendingPathComponent("tasks.json")
        try Data(Self.versionOne.utf8).write(to: file, options: .atomic)
        let coordinator = TaskCoordinator(fileURL: file)
        let loaded = await coordinator.record(id: "legacy-approval")
        let record = try XCTUnwrap(loaded)
        guard case .legacy(let plan) = record.plan else { return XCTFail("Version one must remain legacy") }

        XCTAssertEqual(record.goal, "Create the exact report, then rename it")
        XCTAssertEqual(plan.runtimeID, "local.workspace-files")
        XCTAssertEqual(plan.steps.map(\.id), ["create-original", "rename-original"])
        XCTAssertEqual(record.checkpoint.nextStepIndex, 1)
        XCTAssertEqual(record.checkpoint.suspendedActionID, "rename-original")
        XCTAssertNil(record.checkpoint.inFlightStepID)
        XCTAssertEqual(record.state, .paused)
        XCTAssertEqual(record.intent, .pause)
        XCTAssertEqual(record.recoveryDisposition, .current)
        let contents = try XCTUnwrap(plan.steps[0].payload["contents"])
        XCTAssertEqual(Array(contents.utf8), Array("  e\u{301}\r\n\t🍐\n  ".utf8))
        XCTAssertEqual(plan.steps[1].payload["name"], "report.txt")
        XCTAssertEqual(plan.steps[1].payload["newName"], "final report.txt")

        // Retired-format records decode for inspection but can never execute.
        XCTAssertFalse(record.canResumeWorkspaceTask)
        XCTAssertFalse(record.canStartAutomatically)
        XCTAssertEqual(try Data(contentsOf: file), Data(Self.versionOne.utf8))

        _ = try await coordinator.requestCancellation(id: record.id)
        let reloaded = TaskCoordinator(fileURL: file)
        let stored = await reloaded.record(id: record.id)
        let rewritten = try XCTUnwrap(stored)
        guard case .legacy(let rewrittenPlan) = rewritten.plan else { return XCTFail("Rewritten task changed plan representation") }
        XCTAssertEqual(rewrittenPlan, plan)
        XCTAssertEqual(Array((rewrittenPlan.steps[0].payload["contents"] ?? "").utf8), Array(contents.utf8))
        XCTAssertEqual(rewritten.checkpoint, record.checkpoint)
        XCTAssertTrue(rewritten.cancellationRequested)
        XCTAssertFalse(rewritten.canResumeWorkspaceTask)
        XCTAssertFalse(rewritten.canStartAutomatically)
        XCTAssertEqual(
            try Data(contentsOf: file.appendingPathExtension("backup")),
            Data(Self.versionOne.utf8)
        )
    }

    func testVersionTwoKeepsUncertainDispatchAndCancellationAfterRecovery() async throws {
        let file = directory.appendingPathComponent("tasks.json")
        try Data(Self.versionTwo.utf8).write(to: file, options: .atomic)
        let coordinator = TaskCoordinator(fileURL: file)
        let initial = await coordinator.record(id: "legacy-dispatched")
        let record = try XCTUnwrap(initial)
        guard case .legacy(let plan) = record.plan else { return XCTFail("Version two must remain legacy") }

        XCTAssertEqual(record.checkpoint.inFlightStepID, "send-original")
        XCTAssertEqual(record.checkpoint.nextStepIndex, 0)
        XCTAssertTrue(record.requiresReconciliation)
        XCTAssertFalse(record.canResumeWorkspaceTask)
        XCTAssertTrue(record.cancellationRequested)
        XCTAssertEqual(plan.steps[0].payload["channel"], "C012345")
        XCTAssertEqual(plan.steps[0].payload["text"], "Keep this exact message\n")
        XCTAssertEqual(plan.steps[0].payload["path"], "/chat.postMessage")
        XCTAssertEqual(
            plan.steps[0].payload["body"],
            #"{"channel":"C012345","text":"Keep this exact message\n"}"#
        )

        _ = try await coordinator.recoverInterruptedRuns()
        let afterRecovery = await coordinator.record(id: record.id)
        XCTAssertFalse(afterRecovery?.canResumeWorkspaceTask == true)
        XCTAssertFalse(afterRecovery?.canStartAutomatically == true)
        let outcome = try await coordinator.finishCancellation(id: record.id, reason: "cancelled")
        XCTAssertEqual(outcome, .blocked(reason: "cancelled"))

        let reloaded = TaskCoordinator(fileURL: file)
        let stored = await reloaded.record(id: record.id)
        let recovered = try XCTUnwrap(stored)
        guard case .legacy(let recoveredPlan) = recovered.plan else { return XCTFail("Recovered task changed plan representation") }
        XCTAssertEqual(recoveredPlan, plan)
        XCTAssertEqual(recovered.checkpoint, record.checkpoint)
        XCTAssertEqual(recovered.state, .paused)
        XCTAssertTrue(recovered.cancellationRequested)
        XCTAssertTrue(recovered.requiresReconciliation)
        XCTAssertFalse(recovered.canResumeWorkspaceTask)
    }

    private static let versionOne = #"""
    {
      "version": 1,
      "tasks": [{
        "id": "legacy-approval",
        "goal": "Create the exact report, then rename it",
        "runtimeID": "local.workspace-files",
        "steps": [
          {
            "id": "create-original", "kind": "createFile", "summary": "Write report",
            "payload": {"name": "report.txt", "contents": "  e\u0301\r\n\t🍐\n  "}
          },
          {
            "id": "rename-original", "kind": "renameFile", "summary": "Rename report",
            "payload": {"name": "report.txt", "newName": "final report.txt"}
          }
        ],
        "state": "paused", "nextStepIndex": 1,
        "suspendedStepID": "rename-original", "intent": "pause"
      }]
    }
    """#

    private static let versionTwo = #"""
    {
      "version": 2,
      "tasks": [{
        "id": "legacy-dispatched", "goal": "Send the approved message",
        "runtimeID": "remote-integrations",
        "steps": [{
          "id": "send-original", "kind": "remoteWrite", "summary": "Post message",
          "payload": {
            "integrationID": "slack", "operation": "slack.sendMessage",
            "method": "POST", "path": "/chat.postMessage",
            "body": "{\"channel\":\"C012345\",\"text\":\"Keep this exact message\\n\"}",
            "channel": "C012345", "text": "Keep this exact message\n"
          }
        }],
        "state": "running", "nextStepIndex": 0,
        "inFlightStepID": "send-original", "intent": "cancel",
        "recoveryDisposition": "current"
      }]
    }
    """#
}
