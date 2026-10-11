import Foundation
import PerryRuntimes

/// An open-ended background goal executed as an unattended agent turn on a
/// dedicated conversation thread. Unlike `ExecutionPlan` there is no fixed
/// action list: the agent decides tool calls at run time, so progress is
/// reported as status text rather than step checkpoints.
public struct AgentTaskPlan: Sendable, Equatable {
    public let goal: String
    /// The `PerryThread` the run writes its turns to. Relaunching a task
    /// reuses the same thread so the model sees its prior attempt.
    public let threadID: UUID

    public init(goal: String, threadID: UUID) {
        self.goal = goal
        self.threadID = threadID
    }
}

public enum TaskPlan: Sendable {
    case legacy(Plan)
    case executable(PerryRuntimes.ExecutionPlan)
    case agent(AgentTaskPlan)

    public var goal: String {
        switch self {
        case .legacy(let plan): return plan.goal
        case .executable(let plan): return plan.goal
        case .agent(let plan): return plan.goal
        }
    }

    public var actionCount: Int {
        switch self {
        case .legacy(let plan): return plan.steps.count
        case .executable(let plan): return plan.actions.count
        case .agent: return 0
        }
    }

    public var actionSummaries: [String] {
        switch self {
        case .legacy(let plan): return plan.steps.map(\.summary)
        case .executable(let plan): return plan.actions.map(\.summary)
        case .agent: return []
        }
    }

    var actionIDs: [String] {
        switch self {
        case .legacy(let plan): return plan.steps.map(\.id)
        case .executable(let plan): return plan.actions.map { $0.id.rawValue }
        case .agent: return []
        }
    }
}
