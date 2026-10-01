import Foundation
import PerryCore

public enum ActionExecutionEvidence: Sendable, Equatable {
    case workspaceFile(WorkspaceFileExecutionReceipt)
    /// Raw service response body from a remote-integration write; the
    /// verifier checks the postcondition's expected text is echoed back.
    case integrationResponse(Data)
}

public struct ActionExecutionResult: Sendable, Equatable {
    public let actionID: ActionID
    public let operation: ExecutableAction.Operation
    public let evidence: ActionExecutionEvidence?
    /// True when the workspace receipt binds the shared write-ahead journal's
    /// plan record instead of the caller's approved plan — the journal
    /// already verified grant, digest, and postcondition, so the verifier
    /// checks the action and filesystem state rather than plan identity.
    public let journaled: Bool

    public init(action: ExecutableAction, evidence: ActionExecutionEvidence? = nil, journaled: Bool = false) {
        self.actionID = action.id
        self.operation = action.operation
        self.evidence = evidence
        self.journaled = journaled
    }

    public init(actionID: ActionID, operation: ExecutableAction.Operation) {
        self.actionID = actionID
        self.operation = operation
        self.evidence = nil
        self.journaled = false
    }
}

public protocol ExecutableActionExecutor: Sendable {
    func execute(_ approvedAction: ApprovedExecutableAction) async throws -> ActionExecutionResult
}

public typealias TypedActionExecutor = ExecutableActionExecutor

public struct CLIUnavailableError: Error, CustomStringConvertible, LocalizedError {
    public let searchedPaths: [String]
    public var errorDescription: String? { description }

    public init(searchedPaths: [String]) {
        self.searchedPaths = searchedPaths
    }

    public var description: String {
        "no coding-agent CLI found. Searched:\n" + searchedPaths.map { "  \($0)" }.joined(separator: "\n")
    }
}
