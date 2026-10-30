import Foundation
import PerryCore
import PerryGuide
import PerryRuntimes

struct TypedActionRouter: ExecutableActionExecutor {
    let worker: CuaWorkerHandle?
    let workspace: URL?
    let remoteIntegrations: RemoteIntegrationActionRuntime?
    let askUser: (@Sendable (String, [String]) async throws -> Void)?
    let runCodingTask: (@Sendable (String, URL, String) async throws -> Void)?
    var journaledTransforms: (@Sendable (ExecutableAction) async throws -> WorkspaceFileExecutionReceipt)? = nil
    var bindComputerCommand: (@Sendable (ExecutableAction) async throws -> RoutineStepBinding?)? = nil

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
                throw ExecutionError(message: "Perry can’t control apps right now. Restart Perry.")
            }
            let binding = try await bindComputerCommand?(action)
            let computerAction = try ComputerAction(actionID: action.id.rawValue, command: binding?.command ?? command, expectedWindow: window)
            let result = try await worker.execute(computerAction)
            guard result.success else {
                throw ExecutionError(message: result.message)
            }
            return ActionExecutionResult(action: action, evidence: binding?.baselineSHA256.map(ActionExecutionEvidence.windowBaseline))
        case .integration:
            guard let remoteIntegrations else {
                throw ExecutionError(message: "no remote integration capability is configured")
            }
            return try await remoteIntegrations.execute(approvedAction: approvedAction)
        case .shell(let workspace, _, _, let command):
            switch command {
            case .codingTask(let runtimeID, let prompt):
                guard let runCodingTask else {
                    throw ExecutionError(message: "No coding agent is set up. Choose one in Settings > Brain.")
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
