import Foundation
import PerryCore

/// One semantic resource an action claims for scheduling. The app maps these
/// to its `BackgroundTaskResource` conflicts; the table is the only place that
/// decides which resources an operation touches.
public enum ResourceClaim: Hashable, Sendable {
    case workspace(URL)
    case application(bundleID: String)
    case integration(accountID: String)
}

/// The single source of truth for what an operation means for trust: its tier,
/// the weakest approval it may ever run under, whether its effect can be
/// undone, and the resources it claims. Executors, the supervisor, the parser,
/// and the enqueue validator all read this table — nothing re-derives policy
/// per call site.
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
                // Generic GUI input has no honest inverse; the plan's typed
                // Undo scope covers workspace effects only.
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
                // A sandboxed coding task may create, mutate, or delete
                // arbitrary workspace content; no general inverse exists.
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
            // The question surface itself is the user interaction; it needs an
            // action-scoped grant so it stays valid even in a plan that has no
            // other approvable action.
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

    /// One honest line about where this operation lands — the rehearsal card
    /// shows the real typed target, not the planner's prose summary.
    public var rehearsalTarget: String {
        switch self {
        case .computer(let window, _):
            return "controls \(window.bundleID)"
        case .integration(let accountID, let command):
            // Integration writes show the account, object, and exact payload —
            // the review is the last place the user sees what leaves.
            return "\(command.rehearsalService) as \(accountID): \(command.rehearsalPayload)"
        case .shell(let workspace, let executable, _, _):
            return "runs \(executable.path.lastPathComponent) in \(workspace.lastPathComponent)"
        case .transform(_, let command):
            return command.rehearsalTarget
        case .askUser(let prompt, _):
            return "asks you: \(prompt)"
        }
    }
}

extension ExecutableAction.FileTransform {
    var rehearsalTarget: String {
        switch self {
        case .createUTF8File(let path, _): return "creates \(path)"
        case .createDirectory(let path): return "creates folder \(path)"
        case .rename(let path, let destination): return "renames \(path) → \(destination)"
        case .moveToTrash(let path): return "trashes \(path)"
        case .restoreFromTrash(_, let destination): return "restores \(destination) from the Trash"
        }
    }
}

extension ExecutableAction.IntegrationCommand {
    var rehearsalService: String {
        switch self {
        case .slackSendMessage: return "Slack"
        case .notionCreatePage, .notionUpdatePage, .notionAppendBlock: return "Notion"
        case .linearUpdateIssue: return "Linear"
        }
    }

    /// Object and payload, verbatim — e.g. `channel C123: "launch at 9"`.
    var rehearsalPayload: String {
        switch self {
        case .slackSendMessage(let channelID, let text):
            return "channel \(channelID): \"\(text)\""
        case .notionCreatePage(let parentID, let title):
            return "new page under \(parentID): \"\(title)\""
        case .notionUpdatePage(let pageID, let title):
            return "page \(pageID): \"\(title)\""
        case .notionAppendBlock(let blockID, let text):
            return "block \(blockID): \"\(text)\""
        case .linearUpdateIssue(let issueID, let title):
            return "issue \(issueID): \"\(title)\""
        }
    }
}

/// Pre-publication gate: a plan may only reach a queue or a supervisor when
/// every action is supported by the surface that will execute it, claims the
/// workspace it was bound to, stays inside timeout bounds, and names only
/// configured integration accounts. Per-action shape (postcondition match,
/// approval floor, unique IDs) is already enforced by `ExecutableAction.init`.
public enum ExecutionPlanValidator {
    public struct Capabilities: Sendable {
        public var supportedOperations: Set<ExecutableAction.Operation.Kind>
        /// The single workspace this surface may touch; nil rejects workspace claims.
        public var workspace: URL?
        /// Configured integration account IDs this surface may write through.
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
            // An irreversible effect can never honestly claim bare
            // repeat-safety; keyed dedupe stays allowed.
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
