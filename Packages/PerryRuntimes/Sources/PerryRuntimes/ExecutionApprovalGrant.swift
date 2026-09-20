import Foundation
import PerryCore

public enum ExecutionApprovalError: Error, Equatable, Sendable {
    case grantRequired
    case revoked
    case expired
    case future
    case invalidDuration
    case planMismatch
    case actionMissing
    case scopeMismatch
    case malformedGrant
}

public struct ApprovedExecutableAction: Sendable {
    public let action: ExecutableAction
    public let grant: ExecutionApprovalGrant
    public let planID: UUID
    public let planDigest: String
    private let plan: ExecutionPlan

    public init(plan: ExecutionPlan, actionID: ActionID, grant: ExecutionApprovalGrant) throws {
        let action = try grant.authorizedAction(in: plan, actionID: actionID, revokedGrantIDs: [])
        self.action = action
        self.grant = grant
        self.planID = plan.planID
        self.planDigest = try plan.approvalDigest()
        self.plan = plan
    }

    func validatedAction() throws -> ExecutableAction {
        let authorized = try grant.authorizedAction(in: plan, actionID: action.id, revokedGrantIDs: [])
        guard authorized.id == action.id,
              authorized.operation == action.operation else {
            throw ExecutionApprovalError.planMismatch
        }
        return authorized
    }
}

public struct ExecutionApprovalGrant: Codable, Sendable {
    public enum Scope: Codable, Equatable, Sendable {
        case action(ActionID)
        case plan
    }

    public let id: UUID
    public let taskID: TaskID
    public let planID: UUID
    public let planDigest: String
    public let scope: Scope
    public let issuedAt: Date
    public let expiresAt: Date
    public let requiresReapproval: Bool
    public static let maximumValidityDuration: TimeInterval = 5 * 60
    private static let legacyValidityDuration: TimeInterval = 5 * 60

    init(plan: ExecutionPlan, scope: Scope, issuedAt: Date = Date(), expiresAt: Date? = nil) throws {
        guard issuedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ExecutionApprovalError.malformedGrant
        }
        let expiresAt = expiresAt ?? issuedAt.addingTimeInterval(Self.maximumValidityDuration)
        let duration = expiresAt.timeIntervalSince(issuedAt)
        guard expiresAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ExecutionApprovalError.malformedGrant
        }
        guard duration.isFinite, duration > 0, duration <= Self.maximumValidityDuration else {
            throw ExecutionApprovalError.invalidDuration
        }
        switch scope {
        case .action(let actionID):
            guard let action = plan.actions.first(where: { $0.id == actionID }) else {
                throw ExecutionApprovalError.actionMissing
            }
            guard action.approvalRequirement == .action else { throw ExecutionApprovalError.scopeMismatch }
        case .plan:
            guard plan.actions.contains(where: { $0.approvalRequirement == .plan }) else {
                throw ExecutionApprovalError.scopeMismatch
            }
        }
        id = UUID()
        taskID = plan.taskID
        planID = plan.planID
        planDigest = try plan.approvalDigest()
        self.scope = scope
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        requiresReapproval = false
    }

    func authorizedAction(
        in plan: ExecutionPlan,
        actionID: ActionID,
        revokedGrantIDs: Set<UUID>
    ) throws -> ExecutableAction {
        let now = Date()
        try validateForExecution(at: now)
        guard !revokedGrantIDs.contains(id) else { throw ExecutionApprovalError.revoked }
        guard taskID == plan.taskID, planID == plan.planID,
              try planDigest == plan.approvalDigest() else {
            throw ExecutionApprovalError.planMismatch
        }
        guard let action = plan.actions.first(where: { $0.id == actionID }) else {
            throw ExecutionApprovalError.actionMissing
        }
        switch (scope, action.approvalRequirement) {
        case (.action(let approvedID), .action) where approvedID == actionID:
            return action
        case (.plan, .plan):
            return action
        default:
            throw ExecutionApprovalError.scopeMismatch
        }
    }

    public func validateForExecution(at now: Date = Date()) throws {
        let duration = expiresAt.timeIntervalSince(issuedAt)
        guard duration.isFinite, duration > 0, duration <= Self.maximumValidityDuration else {
            throw ExecutionApprovalError.invalidDuration
        }
        guard issuedAt <= now else { throw ExecutionApprovalError.future }
        guard expiresAt > now else { throw ExecutionApprovalError.expired }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, taskID, planID, planDigest, scope, issuedAt, expiresAt
    }

    public init(from decoder: Decoder) throws {
        let fields = try PlanDecodingFields(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        id = try fields.decode(UUID.self, "id")
        taskID = try fields.decode(TaskID.self, "taskID")
        planID = try fields.decode(UUID.self, "planID")
        planDigest = try fields.decode(String.self, "planDigest")
        issuedAt = try fields.decode(Date.self, "issuedAt")
        let now = Date()
        if let decodedExpiry = try fields.optional(Date.self, "expiresAt") {
            expiresAt = decodedExpiry
            requiresReapproval = !(issuedAt <= now && decodedExpiry > now)
        } else {
            let legacyExpiry = issuedAt.addingTimeInterval(Self.legacyValidityDuration)
            expiresAt = legacyExpiry
            requiresReapproval = !(issuedAt <= now && legacyExpiry > now)
        }
        let payload = try PlanDecodingFields.enumPayload(fields.decoder("scope"), cases: ["action": ["_0"], "plan": []])
        switch payload.name {
        case "action": scope = .action(try payload.fields.decode(ActionID.self, "_0"))
        case "plan": scope = .plan
        default: throw ExecutionApprovalError.malformedGrant
        }
        guard issuedAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ExecutionApprovalError.malformedGrant
        }
        let duration = expiresAt.timeIntervalSince(issuedAt)
        guard duration.isFinite, duration > 0, duration <= Self.maximumValidityDuration else {
            throw ExecutionApprovalError.invalidDuration
        }
        guard planDigest.utf8.count == 64,
              planDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ExecutionApprovalError.malformedGrant
        }
    }
}
