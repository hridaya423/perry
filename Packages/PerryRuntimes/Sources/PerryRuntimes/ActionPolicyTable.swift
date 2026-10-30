import Foundation
import PerryCore

public enum ResourceClaim: Hashable, Sendable {
    case workspace(URL)
    case application(bundleID: String)
    case integration(accountID: String)
}

public struct ActionPolicy: Sendable, Equatable {
    public let trustTier: TrustTier
    public let minimumApproval: ApprovalScope
    public let reversible: Bool
    public let claims: Set<ResourceClaim>

    public init(trustTier: TrustTier, minimumApproval: ApprovalScope, reversible: Bool, claims: Set<ResourceClaim>) {
        self.trustTier = trustTier
        self.minimumApproval = minimumApproval
        self.reversible = reversible
        self.claims = claims
    }
}

extension ExecutableAction {
    public var policy: ActionPolicy { operation.policy }
}

extension ExecutableAction.Operation {
    public var policy: ActionPolicy {
        switch self {
        case .computer(let window, _):
            return ActionPolicy(
                trustTier: .yellow,
                minimumApproval: .plan,
                reversible: false,
                claims: [.application(bundleID: window.bundleID.lowercased())]
            )
        case .integration(let accountID, _):
            return ActionPolicy(
                trustTier: .orange,
                minimumApproval: .action,
                reversible: false,
                claims: [.integration(accountID: accountID)]
            )
        case .shell(let workspace, _, _, _):
            return ActionPolicy(
                trustTier: .yellow,
                minimumApproval: .plan,
                reversible: false,
                claims: [.workspace(workspace)]
            )
        case .transform(let workspace, let command):
            switch command {
            case .moveToTrash, .restoreFromTrash:
                return ActionPolicy(
                    trustTier: .orange,
                    minimumApproval: .action,
                    reversible: false,
                    claims: [.workspace(workspace)]
                )
            case .createUTF8File, .createDirectory, .rename:
                return ActionPolicy(
                    trustTier: .yellow,
                    minimumApproval: .plan,
                    reversible: true,
                    claims: [.workspace(workspace)]
                )
            }
        case .askUser:
            return ActionPolicy(trustTier: .green, minimumApproval: .action, reversible: true, claims: [])
        }
    }
}

extension ExecutableAction.Operation {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case computer, integration, shell, transform, askUser
    }

    public var kind: Kind {
        switch self {
        case .computer: return .computer
        case .integration: return .integration
        case .shell: return .shell
        case .transform: return .transform
        case .askUser: return .askUser
        }
    }
}

public enum ExecutionPlanValidator {
    public struct Capabilities: Sendable {
        public var supportedOperations: Set<ExecutableAction.Operation.Kind>
        public var workspace: URL?
        public var integrationAccounts: Set<String>
        public var maxActionTimeout: TimeInterval

        public init(
            supportedOperations: Set<ExecutableAction.Operation.Kind>,
            workspace: URL? = nil,
            integrationAccounts: Set<String> = [],
            maxActionTimeout: TimeInterval = 600
        ) {
            self.supportedOperations = supportedOperations
            self.workspace = workspace
            self.integrationAccounts = integrationAccounts
            self.maxActionTimeout = maxActionTimeout
        }
    }

    public static func validate(_ plan: ExecutionPlan, capabilities: Capabilities) throws {
        let allowedWorkspace = capabilities.workspace?.resolvingSymlinksInPath().standardizedFileURL.path
        for action in plan.actions {
            guard capabilities.supportedOperations.contains(action.operation.kind) else {
                throw ExecutablePlanError.invalid("operation \(action.operation.kind.rawValue) is not supported by this executor")
            }
            guard action.timeout <= capabilities.maxActionTimeout else {
                throw ExecutablePlanError.invalid("action timeout exceeds the \(Int(capabilities.maxActionTimeout))s bound")
            }
            if case .shell(_, _, _, .registeredCommand) = action.operation {
                throw ExecutablePlanError.invalid("registered commands have no executor")
            }
            guard action.policy.reversible || action.idempotency != .idempotent else {
                throw ExecutablePlanError.invalid("a non-reversible action cannot be declared idempotent")
            }
            for claim in action.policy.claims {
                switch claim {
                case .workspace(let workspace):
                    guard workspace.resolvingSymlinksInPath().standardizedFileURL.path == allowedWorkspace else {
                        throw ExecutablePlanError.invalid("action claims a workspace outside this executor's binding")
                    }
                case .integration(let accountID):
                    guard capabilities.integrationAccounts.contains(accountID) else {
                        throw ExecutablePlanError.invalid("action writes through an unconfigured integration account")
                    }
                case .application:
                    break
                }
            }
        }
    }
}
