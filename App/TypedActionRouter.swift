import Foundation
import PerryCore
import PerryRuntimes

/// App-owned typed execution boundary. Routes each approved executable action
/// to the subsystem that owns its effect: Cua for GUI actions, the workspace
/// file runtime for transforms, the remote-integration client for service
/// writes, a sandboxed coding runtime for delegated tasks, and the ask-user
/// surface for questions. Provider runtimes never execute directly.
struct TypedActionRouter: ExecutableActionExecutor {
    let worker: CuaWorkerHandle?
    let workspace: URL?
    let remoteIntegrations: RemoteIntegrationActionRuntime?
    let askUser: (@Sendable (String, [String]) async throws -> Void)?
    let runCodingTask: (@Sendable (String, URL, String) async throws -> Void)?
    /// When bound, workspace transforms run through the shared write-ahead
    /// journal so the run lands durable receipts. Bound means journaling is
    /// mandatory — there is no silent unjournaled fallback.
    var journaledTransforms: (@Sendable (ExecutableAction) async throws -> WorkspaceFileExecutionReceipt)? = nil
    var bindComputerCommand: (@Sendable (ExecutableAction) async throws -> ExecutableAction.ComputerCommand?)? = nil

    func execute(_ approvedAction: ApprovedExecutableAction) async throws -> ActionExecutionResult {
        let action = approvedAction.action
        switch action.operation {
        case .transform(let workspace, _):
            guard let base = self.workspace,
                  base.resolvingSymlinksInPath().standardizedFileURL.path
                      == workspace.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw ExecutionError(message: "typed transform is not bound to this executor's workspace")
            }
            if let journaledTransforms {
                let receipt = try await journaledTransforms(action)
                return ActionExecutionResult(action: action, evidence: .workspaceFile(receipt), journaled: true)
            }
            return try await WorkspaceFileRuntime(baseURL: base).execute(approvedAction)
        case .computer(let window, let command):
            guard let worker else {
                throw ExecutionError(message: "no computer-use worker is attached to this session")
            }
            let boundCommand = try await bindComputerCommand?(action) ?? command
            let computerAction = try ComputerAction(actionID: action.id.rawValue, command: boundCommand, expectedWindow: window)
            let result = try await worker.execute(computerAction)
            guard result.success else {
                throw ExecutionError(message: result.message)
            }
            return ActionExecutionResult(action: action)
        case .integration:
            guard let remoteIntegrations else {
                throw ExecutionError(message: "no remote integration capability is configured")
            }
            return try await remoteIntegrations.execute(approvedAction: approvedAction)
        case .shell(let workspace, _, _, let command):
            switch command {
            case .codingTask(let runtimeID, let prompt):
                guard let runCodingTask else {
                    throw ExecutionError(message: "no sandboxed coding runtime is configured")
                }
                try await runCodingTask(runtimeID, workspace, prompt)
                return ActionExecutionResult(action: action)
            case .registeredCommand:
                throw ExecutionError(message: "registered commands are not executable yet")
            }
        case .askUser(let prompt, let choices):
            guard let askUser else {
                throw ExecutionError(message: "no ask-user surface is configured")
            }
            try await askUser(prompt, choices)
            return ActionExecutionResult(action: action)
        }
    }
}
