import Foundation
import PerryCore

public struct WorkspaceFilePlanFabricator: Sendable {
    public let id = "local.task-planner"

    public init() {}

    public func workspaceExecutionPlan(
        goal: String,
        workspace: URL,
        taskID: TaskID
    ) async throws -> ExecutionPlan? {
        try Task.checkCancellation()
        guard let fileRequest = try Self.canonicalFileRequest(for: goal) else {
            return nil
        }
        try Task.checkCancellation()
        let action = try ExecutableAction(
            id: ActionID(UUID().uuidString),
            summary: goal,
            approvalRequirement: .action,
            operation: .transform(
                workspace: workspace,
                command: .createUTF8File(path: fileRequest.name, contents: fileRequest.contents)
            ),
            postcondition: .fileContents(fileRequest.contents)
        )
        return try ExecutionPlan(
            taskID: taskID,
            goal: goal,
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
    }

    private static func canonicalFileRequest(
        for goal: String
    ) throws -> (name: String, contents: String)? {
        let creationPrefix = #"\A\s*(?:create|make|write)\s+(?:a\s+)?(?:file|document)\b"#
        guard goal.range(of: creationPrefix, options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        let supportedRequest = try NSRegularExpression(
            pattern: #"\A\s*(?:create|make|write)\s+(?:a\s+)?(?:file|document)\s+"([^"]+)"(?:\s+with\s+"([^"]*)")?\s*\z"#,
            options: .caseInsensitive
        )
        guard let match = supportedRequest.firstMatch(in: goal, range: NSRange(goal.startIndex..., in: goal)),
              let nameRange = Range(match.range(at: 1), in: goal) else {
            throw PlanError(message: "The local file planner needs one explicit request, such as create file \"report.txt\" with \"contents\". Compound requests require another planner.")
        }
        let name = String(goal[nameRange])
        let contents = Range(match.range(at: 2), in: goal).map { String(goal[$0]) } ?? ""
        guard contents.utf8.count <= WorkspaceFileRuntime.maximumFileCreationBytes else {
            throw PlanError(message: "File contents exceed the 8 MiB workspace limit. Use a smaller file.")
        }
        return (name, contents)
    }
}
