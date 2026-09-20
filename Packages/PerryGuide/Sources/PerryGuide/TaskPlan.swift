import PerryRuntimes

public enum TaskPlan: Sendable {
    case legacy(Plan)
    case executable(PerryRuntimes.ExecutionPlan)

    public var goal: String {
        switch self {
        case .legacy(let plan): return plan.goal
        case .executable(let plan): return plan.goal
        }
    }

    public var actionCount: Int {
        switch self {
        case .legacy(let plan): return plan.steps.count
        case .executable(let plan): return plan.actions.count
        }
    }

    public var actionSummaries: [String] {
        switch self {
        case .legacy(let plan): return plan.steps.map(\.summary)
        case .executable(let plan): return plan.actions.map(\.summary)
        }
    }

    var actionIDs: [String] {
        switch self {
        case .legacy(let plan): return plan.steps.map(\.id)
        case .executable(let plan): return plan.actions.map { $0.id.rawValue }
        }
    }
}
