import Foundation
import PerryCore

public struct ScriptedFinderRuntime: TaskPlanner {
    public let id = "scripted.finder"
    public let capabilities = RuntimeCapabilities(guiGrounding: false, fileIO: true, browser: false, latencyClass: .fast)

    public init() {}

    /// Typed scripted demo: creates the demo files inside the request workspace.
    /// Rename/trash steps cannot be planned here — their postconditions bind the
    /// source item's live identity, which only exists after creation.
    public func plan(_ request: PlanningRequest) async throws -> ExecutionPlan {
        let actions = try Self.demoFileNames.map { name in
            try ExecutableAction(
                id: ActionID(UUID().uuidString),
                summary: "create \(name)",
                approvalRequirement: .action,
                operation: .transform(
                    workspace: request.workspace,
                    command: .createUTF8File(path: name, contents: "created by perry demo")
                ),
                postcondition: .fileContents("created by perry demo")
            )
        }
        return try ExecutionPlan(
            taskID: request.taskID,
            goal: request.goal,
            actions: actions,
            requestedScopes: [.workspaceWrite]
        )
    }

    public static let demoFileNames = ["perry-demo-a.txt", "perry-demo-b.txt", "perry-demo-c.txt"]
}
