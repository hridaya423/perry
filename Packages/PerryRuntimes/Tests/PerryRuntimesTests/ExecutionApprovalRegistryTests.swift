import Foundation
import XCTest
import PerryCore
@testable import PerryRuntimes

final class ExecutionApprovalRegistryTests: XCTestCase {
    private let workspace = URL(fileURLWithPath: "/private/tmp/perry-approval-registry", isDirectory: true)

    func testIssueStoresGrantAndAuthorizeReturnsBoundAction() async throws {
        let plan = try makePlan()
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action("write"))

        let action = try await registry.authorize(grantID: grant.id, plan: plan, actionID: "write")
        XCTAssertEqual(action.id, "write")
    }

    func testForgedDecodedGrantWithCurrentDigestCannotAuthorize() async throws {
        let plan = try makePlan()
        let registry = ExecutionApprovalRegistry()
        let issued = try await registry.issue(plan: plan, scope: .action("write"))
        var fields = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(issued)) as? [String: Any]
        )
        fields["id"] = UUID().uuidString
        let forged = try JSONDecoder().decode(
            ExecutionApprovalGrant.self,
            from: JSONSerialization.data(withJSONObject: fields)
        )

        do {
            _ = try await registry.authorize(grantID: forged.id, plan: plan, actionID: "write")
            XCTFail("A decoded grant must not register itself with the registry")
        } catch {
            XCTAssertEqual(error as? ExecutionApprovalError, .malformedGrant)
        }
    }

    func testRevocationRemovesGrantAndUsesTheUnknownIDRejection() async throws {
        let plan = try makePlan()
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action("write"))

        await registry.revoke(id: grant.id)

        do {
            _ = try await registry.authorize(grantID: grant.id, plan: plan, actionID: "write")
            XCTFail("A revoked grant must not authorize an action")
        } catch {
            XCTAssertEqual(error as? ExecutionApprovalError, .malformedGrant)
        }
    }

    func testChangedTargetOrBytesInvalidateIssuedGrant() async throws {
        let plan = try makePlan()
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action("write"))
        let changedTarget = try makePlan(planID: plan.planID, workspace: workspace.appendingPathComponent("other"))
        let changedBytes = try makePlan(planID: plan.planID, contents: "e\u{301}")

        for changedPlan in [changedTarget, changedBytes] {
            do {
                _ = try await registry.authorize(grantID: grant.id, plan: changedPlan, actionID: "write")
                XCTFail("A changed effect must not match the issued grant")
            } catch {
                XCTAssertEqual(error as? ExecutionApprovalError, .planMismatch)
            }
        }
    }

    func testFreshRegistryRejectsGrantIssuedByAnotherInstance() async throws {
        let plan = try makePlan()
        let issuingRegistry = ExecutionApprovalRegistry()
        let freshRegistry = ExecutionApprovalRegistry()
        let grant = try await issuingRegistry.issue(plan: plan, scope: .action("write"))

        do {
            _ = try await freshRegistry.authorize(grantID: grant.id, plan: plan, actionID: "write")
            XCTFail("A fresh registry must not know an old grant ID")
        } catch {
            XCTAssertEqual(error as? ExecutionApprovalError, .malformedGrant)
        }
    }

    private func makePlan(
        planID: UUID = UUID(),
        contents: String = "é",
        workspace: URL? = nil
    ) throws -> PerryRuntimes.ExecutionPlan {
        let targetWorkspace = workspace ?? self.workspace
        let action = try ExecutableAction(
            id: "write",
            summary: "Write a report",
            approvalRequirement: .action,
            operation: .transform(
                workspace: targetWorkspace,
                command: .createUTF8File(path: "report.txt", contents: contents)
            ),
            postcondition: .fileContents(contents)
        )
        return try PerryRuntimes.ExecutionPlan(
            planID: planID,
            taskID: "task",
            goal: "Write a report",
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
    }
}
