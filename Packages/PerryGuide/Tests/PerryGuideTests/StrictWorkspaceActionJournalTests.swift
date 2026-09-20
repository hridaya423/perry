import Foundation
import XCTest
import PerryRuntimes
@testable import PerryGuide

final class StrictWorkspaceActionJournalTests: XCTestCase {
    func testJournalRejectsUnknownPhaseField() async throws {
        let journal = try await makePreparedJournal()
        var fields = try jsonObject(try JSONEncoder().encode(journal))
        fields["futurePhase"] = [:] as [String: Any]

        XCTAssertThrowsError(try JSONDecoder().decode(
            WorkspaceActionJournal.self,
            from: jsonData(fields)
        ))
    }

    func testPreparedLiteralFixtureRetainsOriginalAssociatedValueWrapper() async throws {
        let plan = try makePlan(
            taskID: TaskID("fixture"),
            planID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        )
        let planDigest = try plan.approvalDigest()
        let fixture = Data(#"""
        {
          "prepared": {
            "_0": {
              "id": "00000000-0000-0000-0000-000000000001",
              "actionIndex": 0,
              "grant": {
                "id": "00000000-0000-0000-0000-000000000002",
                "taskID": "fixture",
                "planID": "00000000-0000-0000-0000-000000000003",
                "planDigest": "\#(planDigest)",
                "scope": { "action": { "_0": "write" } },
                "issuedAt": 0
              }
            }
          }
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(WorkspaceActionJournal.self, from: fixture)
        XCTAssertTrue(decoded.attempt.grant.requiresReapproval)
        let registry = ExecutionApprovalRegistry(restoringOwnedGrants: [decoded.attempt.grant])
        do {
            _ = try await registry.authorize(
                grantID: decoded.attempt.grant.id,
                plan: plan,
                actionID: "write"
            )
            XCTFail("A stale legacy grant was authorized")
        } catch ExecutionApprovalError.expired {
        }
        let fields = try jsonObject(try JSONEncoder().encode(decoded))
        let payload = try XCTUnwrap(fields["prepared"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), Set(["_0"]))
    }

    func testAttemptRejectsUnknownField() async throws {
        let journal = try await makePreparedJournal()
        var fields = try jsonObject(try JSONEncoder().encode(journal))
        var prepared = try XCTUnwrap(fields["prepared"] as? [String: Any])
        var attempt = try XCTUnwrap(prepared["_0"] as? [String: Any])
        attempt["unexpected"] = true
        prepared["_0"] = attempt
        fields["prepared"] = prepared

        XCTAssertThrowsError(try JSONDecoder().decode(
            WorkspaceActionJournal.self,
            from: jsonData(fields)
        ))
    }

    func testVerifiedJournalRejectsUnknownPayloadField() async throws {
        let journal = try await makeVerifiedJournal()
        var fields = try jsonObject(try JSONEncoder().encode(journal))
        var payload = try XCTUnwrap(fields["verified"] as? [String: Any])
        payload["unexpected"] = true
        fields["verified"] = payload

        XCTAssertThrowsError(try JSONDecoder().decode(
            WorkspaceActionJournal.self,
            from: jsonData(fields)
        ))
    }

    func testReceiptRejectsUnknownField() throws {
        let receipt = try makeReceipt()
        var fields = try jsonObject(try JSONEncoder().encode(receipt))
        fields["unexpected"] = true

        XCTAssertThrowsError(try JSONDecoder().decode(
            WorkspaceFileExecutionReceipt.self,
            from: jsonData(fields)
        ))
    }

    func testReceiptRejectsMixedLegacyAndTypedEffects() throws {
        let receipt = try makeReceipt()
        var fields = try jsonObject(try JSONEncoder().encode(receipt))
        fields["effect"] = ["createdDirectory": ["path": "report.txt"]]

        XCTAssertThrowsError(try JSONDecoder().decode(
            WorkspaceFileExecutionReceipt.self,
            from: jsonData(fields)
        ))
    }

    func testReceiptRejectsInvalidLegacyEffect() throws {
        let plan = try makePlan()
        let fields: [String: Any] = [
            "planID": plan.planID.uuidString,
            "actionID": "write",
            "planDigest": try plan.approvalDigest(),
            "path": "",
            "byteCount": -1,
        ]

        XCTAssertThrowsError(try JSONDecoder().decode(
            WorkspaceFileExecutionReceipt.self,
            from: jsonData(fields)
        ))
    }

    func testTypedReceiptEffectRejectsUnknownPayloadField() throws {
        let plan = try makePlan()
        let fields: [String: Any] = [
            "planID": plan.planID.uuidString,
            "actionID": "write",
            "planDigest": try plan.approvalDigest(),
            "effect": [
                "createdDirectory": [
                    "path": "reports",
                    "unexpected": true,
                ],
            ],
        ]

        XCTAssertThrowsError(try JSONDecoder().decode(
            WorkspaceFileExecutionReceipt.self,
            from: jsonData(fields)
        ))
    }

    func testEncodingRetainsAssociatedValueWireShape() async throws {
        let journal = try await makeVerifiedJournal()
        let fields = try jsonObject(try JSONEncoder().encode(journal))
        XCTAssertEqual(Set(fields.keys), Set(["verified"]))

        let payload = try XCTUnwrap(fields["verified"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), Set(["_0", "_1"]))

        let attempt = try XCTUnwrap(payload["_0"] as? [String: Any])
        XCTAssertEqual(Set(attempt.keys), Set(["id", "actionIndex", "grant"]))

        let receipt = try XCTUnwrap(payload["_1"] as? [String: Any])
        XCTAssertEqual(Set(receipt.keys), Set(["planID", "actionID", "planDigest", "path", "byteCount"]))
    }

    private func makePreparedJournal() async throws -> WorkspaceActionJournal {
        let plan = try makePlan()
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action("write"))
        return .prepared(.init(actionIndex: 0, grant: grant))
    }

    private func makeVerifiedJournal() async throws -> WorkspaceActionJournal {
        let plan = try makePlan()
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action("write"))
        return .verified(
            .init(actionIndex: 0, grant: grant),
            try makeReceipt(for: plan)
        )
    }

    private func makeReceipt() throws -> WorkspaceFileExecutionReceipt {
        try makeReceipt(for: makePlan())
    }

    private func makeReceipt(for plan: PerryRuntimes.ExecutionPlan) throws -> WorkspaceFileExecutionReceipt {
        let fields: [String: Any] = [
            "planID": plan.planID.uuidString,
            "actionID": "write",
            "planDigest": try plan.approvalDigest(),
            "path": "report.txt",
            "byteCount": 2,
        ]
        return try JSONDecoder().decode(
            WorkspaceFileExecutionReceipt.self,
            from: jsonData(fields)
        )
    }

    private func makePlan(
        taskID: TaskID = TaskID("strict-journal"),
        planID: UUID = UUID()
    ) throws -> PerryRuntimes.ExecutionPlan {
        let workspace = URL(fileURLWithPath: "/private/tmp/perry-strict-journal", isDirectory: true)
        let action = try ExecutableAction(
            id: "write",
            summary: "Write report",
            approvalRequirement: .action,
            operation: .transform(
                workspace: workspace,
                command: .createUTF8File(path: "report.txt", contents: "é")
            ),
            postcondition: .fileContents("é")
        )
        return try PerryRuntimes.ExecutionPlan(
            planID: planID,
            taskID: taskID,
            goal: "Write report",
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
