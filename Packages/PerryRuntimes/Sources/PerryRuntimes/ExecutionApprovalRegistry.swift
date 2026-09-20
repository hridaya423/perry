import Foundation
import PerryCore

public actor ExecutionApprovalRegistry {
    private var issuedGrants: [UUID: ExecutionApprovalGrant] = [:]

    public init() {}

    public init(restoringOwnedGrants grants: [ExecutionApprovalGrant]) {
        for grant in grants {
            issuedGrants[grant.id] = grant
        }
    }

    public func issue(
        plan: ExecutionPlan,
        scope: ExecutionApprovalGrant.Scope
    ) throws -> ExecutionApprovalGrant {
        let grant = try ExecutionApprovalGrant(plan: plan, scope: scope)
        issuedGrants[grant.id] = grant
        return grant
    }

    public func revoke(id: UUID) {
        issuedGrants.removeValue(forKey: id)
    }

    public func authorize(
        grantID: UUID,
        plan: ExecutionPlan,
        actionID: ActionID
    ) throws -> ExecutableAction {
        guard let grant = issuedGrants[grantID] else {
            throw ExecutionApprovalError.malformedGrant
        }
        return try grant.authorizedAction(in: plan, actionID: actionID, revokedGrantIDs: [])
    }
}
