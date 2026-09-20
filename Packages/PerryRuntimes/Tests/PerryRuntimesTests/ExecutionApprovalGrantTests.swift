import Foundation
import XCTest
import PerryCore
@testable import PerryRuntimes

final class ExecutionApprovalGrantTests: XCTestCase {
    func testActionGrantSurvivesEncodingButCannotAuthorizeAnotherAction() throws {
        let plan = try makePlan()
        let grant = try ExecutionApprovalGrant(plan: plan, scope: .action("first"))
        let restored = try JSONDecoder().decode(ExecutionApprovalGrant.self, from: JSONEncoder().encode(grant))

        let action = try restored.authorizedAction(in: plan, actionID: "first", revokedGrantIDs: [])
        XCTAssertEqual(action.id, "first")
        XCTAssertEqual(restored.id, grant.id)
        XCTAssertEqual(restored.issuedAt, grant.issuedAt)
        XCTAssertThrowsError(try restored.authorizedAction(in: plan, actionID: "second", revokedGrantIDs: [])) {
            XCTAssertEqual($0 as? ExecutionApprovalError, .scopeMismatch)
        }
    }

    func testRevocationAndPlanReplacementInvalidateGrant() throws {
        let plan = try makePlan()
        let grant = try ExecutionApprovalGrant(plan: plan, scope: .action("first"))
        XCTAssertThrowsError(try grant.authorizedAction(in: plan, actionID: "first", revokedGrantIDs: [grant.id])) {
            XCTAssertEqual($0 as? ExecutionApprovalError, .revoked)
        }
        let replacement = try makePlan()
        XCTAssertThrowsError(try grant.authorizedAction(in: replacement, actionID: "first", revokedGrantIDs: [])) {
            XCTAssertEqual($0 as? ExecutionApprovalError, .planMismatch)
        }
        let changed = try makePlan(planID: plan.planID, contents: "e\u{301}")
        XCTAssertThrowsError(try grant.authorizedAction(in: changed, actionID: "first", revokedGrantIDs: [])) {
            XCTAssertEqual($0 as? ExecutionApprovalError, .planMismatch)
        }
    }

    func testPlanGrantDoesNotReplaceRequiredPerActionApproval() throws {
        let plan = try makePlan(firstRequirement: .plan)
        let grant = try ExecutionApprovalGrant(plan: plan, scope: .plan)
        XCTAssertEqual(try grant.authorizedAction(in: plan, actionID: "first", revokedGrantIDs: []).id, "first")
        XCTAssertThrowsError(try grant.authorizedAction(in: plan, actionID: "second", revokedGrantIDs: [])) {
            XCTAssertEqual($0 as? ExecutionApprovalError, .scopeMismatch)
        }
        XCTAssertThrowsError(try ExecutionApprovalGrant(plan: plan, scope: .action("first"))) {
            XCTAssertEqual($0 as? ExecutionApprovalError, .scopeMismatch)
        }
    }

    func testGrantDecoderRejectsUnrecognizedFields() throws {
        let grant = try ExecutionApprovalGrant(plan: makePlan(), scope: .action("first"))
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(grant)) as? [String: Any])
        fields["allowUnapprovedActions"] = true
        XCTAssertThrowsError(try JSONDecoder().decode(
            ExecutionApprovalGrant.self, from: JSONSerialization.data(withJSONObject: fields)
        ))
    }

    func testExpiredAndFutureGrantsCannotAuthorize() throws {
        let plan = try makePlan()
        let expiredIssuedAt = Date(timeIntervalSince1970: 1_000)
        let expired = try ExecutionApprovalGrant(
            plan: plan,
            scope: .action("first"),
            issuedAt: expiredIssuedAt,
            expiresAt: expiredIssuedAt.addingTimeInterval(60)
        )
        XCTAssertThrowsError(try expired.authorizedAction(in: plan, actionID: "first", revokedGrantIDs: [])) {
            XCTAssertEqual($0 as? ExecutionApprovalError, .expired)
        }

        let futureIssuedAt = Date(timeIntervalSinceNow: 60)
        let future = try ExecutionApprovalGrant(
            plan: plan,
            scope: .action("first"),
            issuedAt: futureIssuedAt,
            expiresAt: futureIssuedAt.addingTimeInterval(60)
        )
        XCTAssertThrowsError(try future.authorizedAction(in: plan, actionID: "first", revokedGrantIDs: [])) {
            XCTAssertEqual($0 as? ExecutionApprovalError, .future)
        }
    }

    func testGrantRejectsInvalidDuration() throws {
        let plan = try makePlan()
        let issuedAt = Date()
        XCTAssertThrowsError(try ExecutionApprovalGrant(
            plan: plan,
            scope: .action("first"),
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(ExecutionApprovalGrant.maximumValidityDuration + 1)
        )) {
            XCTAssertEqual($0 as? ExecutionApprovalError, .invalidDuration)
        }
    }

    private func makePlan(
        planID: UUID = UUID(),
        contents: String = "é",
        firstRequirement: ApprovalScope = .action
    ) throws -> PerryRuntimes.ExecutionPlan {
        let workspace = URL(fileURLWithPath: "/private/tmp/perry-grant-fixture", isDirectory: true)
        let first = try ExecutableAction(
            id: "first", summary: "Write first", approvalRequirement: firstRequirement,
            operation: .transform(workspace: workspace, command: .createUTF8File(path: "first.txt", contents: contents)),
            postcondition: .fileContents(contents)
        )
        let second = try ExecutableAction(
            id: "second", summary: "Write second", approvalRequirement: .action,
            operation: .transform(workspace: workspace, command: .createDirectory(path: "second")),
            postcondition: .directoryExists
        )
        return try PerryRuntimes.ExecutionPlan(
            planID: planID, taskID: "task", goal: "Write files", actions: [first, second], requestedScopes: [.workspaceWrite]
        )
    }
}
