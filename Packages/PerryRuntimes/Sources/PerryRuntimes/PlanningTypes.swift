import Foundation
import PerryCore

public struct PlanningRequest: Sendable {
    public let goal: String
    public let taskID: TaskID
    public let workspace: URL
    public let context: PlanningContext

    public init(
        goal: String,
        taskID: TaskID,
        workspace: URL,
        context: PlanningContext
    ) throws {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlanningError.invalidRequest("planning goal must not be empty")
        }
        guard !taskID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlanningError.invalidRequest("planning task ID must not be empty")
        }
        guard workspace.isFileURL, workspace.host == nil, workspace.path.hasPrefix("/") else {
            throw PlanningError.invalidRequest("planning workspace must be an absolute local file URL")
        }
        self.init(
            validatedGoal: goal,
            taskID: taskID,
            normalizedWorkspace: Self.normalizedWorkspace(workspace),
            context: context
        )
    }

    public func withScreenContext(_ context: ScreenContext) -> PlanningRequest {
        PlanningRequest(
            validatedGoal: goal,
            taskID: taskID,
            normalizedWorkspace: workspace,
            context: .screen(context)
        )
    }

    private init(
        validatedGoal goal: String,
        taskID: TaskID,
        normalizedWorkspace workspace: URL,
        context: PlanningContext
    ) {
        self.goal = goal
        self.taskID = taskID
        self.workspace = workspace
        self.context = context
    }

    func matchesWorkspace(_ candidate: URL) -> Bool {
        guard candidate.isFileURL, candidate.host == nil, candidate.path.hasPrefix("/") else {
            return false
        }
        return Array(candidate.standardizedFileURL.path.utf8) == Array(workspace.path.utf8)
    }

    private static func normalizedWorkspace(_ workspace: URL) -> URL {
        workspace.resolvingSymlinksInPath().standardizedFileURL
    }
}

public enum PlanningContext: Sendable {
    case none
    case screen(ScreenContext)
}

public enum PlanningError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case invalidRequest(String)
    case contextRequired
    case typedPlanRejected(String)

    public var description: String {
        switch self {
        case .invalidRequest(let reason):
            return "planning request is invalid: \(reason)"
        case .contextRequired:
            return "screen context is required for this planning request"
        case .typedPlanRejected(let reason):
            return "typed plan was rejected: \(reason)"
        }
    }

    public var errorDescription: String? { description }
}

public protocol TaskPlanner: Sendable {
    var id: String { get }
    var capabilities: RuntimeCapabilities { get }
    func plan(_ request: PlanningRequest) async throws -> ExecutionPlan
}
