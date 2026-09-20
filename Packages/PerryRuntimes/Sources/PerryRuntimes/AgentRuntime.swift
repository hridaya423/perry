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

    public init(action: ExecutableAction, evidence: ActionExecutionEvidence? = nil) {
        self.actionID = action.id
        self.operation = action.operation
        self.evidence = evidence
    }

    public init(actionID: ActionID, operation: ExecutableAction.Operation) {
        self.actionID = actionID
        self.operation = operation
        self.evidence = nil
    }
}

public protocol ExecutableActionExecutor: Sendable {
    func execute(_ approvedAction: ApprovedExecutableAction) async throws -> ActionExecutionResult
}

public typealias TypedActionExecutor = ExecutableActionExecutor

public struct CLIUnavailableError: Error, CustomStringConvertible {
    public let searchedPaths: [String]

    public init(searchedPaths: [String]) {
        self.searchedPaths = searchedPaths
    }

    public var description: String {
        "no coding-agent CLI found. Searched:\n" + searchedPaths.map { "  \($0)" }.joined(separator: "\n")
    }
}
