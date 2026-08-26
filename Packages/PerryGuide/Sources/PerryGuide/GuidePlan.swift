import Foundation
import PerryCore
import PerryOverlay

public struct GuideStep: Codable, Equatable, Sendable, Identifiable {
    public enum Target: Codable, Equatable, Sendable {
        case axElement(stableID: String)
        case screenPoint(CGPointShim)
        case verbalOnly

        public var isVerbal: Bool {
            if case .verbalOnly = self { return true }
            return false
        }
    }

    public let id: UUID
    public let instruction: String
    public let target: Target
    public let waitForUserAction: Bool

    public init(
        id: UUID = UUID(),
        instruction: String,
        target: Target,
        waitForUserAction: Bool = true
    ) {
        self.id = id
        self.instruction = instruction
        self.target = target
        self.waitForUserAction = waitForUserAction
    }
}

public struct GuidePlan: Codable, Equatable, Sendable {
    public let goal: String
    public let steps: [GuideStep]

    public init(goal: String, steps: [GuideStep]) {
        self.goal = goal
        self.steps = steps
    }
}

/// Produces GuidePlans. The default implementation derives steps from an AX
/// snapshot deterministically; a runtime-backed planner (CLI/BYOK) can be
/// swapped in behind the same protocol in later milestones.
public protocol GuidePlanning: Sendable {
    func plan(goal: String, snapshot: AXSnapshot) async throws -> GuidePlan
}

public struct AXGuidePlanner: GuidePlanning {
    public init() {}

    public func plan(goal: String, snapshot: AXSnapshot) async throws -> GuidePlan {
        let actionable = snapshot.actionableElements()
        guard !actionable.isEmpty else {
            return GuidePlan(goal: goal, steps: [
                GuideStep(instruction: "I can't see any controls I can point at in \"\(snapshot.windowTitle)\" — describe what you're trying to reach and I'll talk you through it.", target: .verbalOnly, waitForUserAction: false),
            ])
        }

        var steps: [GuideStep] = []
        for (index, element) in actionable.prefix(8).enumerated() {
            let label = element.label.map { " \($0)" } ?? ""
            let article = index == 0 ? "this" : "next"
            steps.append(
                GuideStep(
                    instruction: "\(article) one\(label), the \(Self.readableRole(element.role))",
                    target: .axElement(stableID: element.stableID)
                )
            )
        }
        return GuidePlan(goal: goal, steps: steps)
    }

    static func readableRole(_ role: AXElement.Role) -> String {
        switch role {
        case .button: return "button"
        case .textField: return "text field"
        case .slider: return "slider"
        case .checkBox: return "checkbox"
        case .menu: return "menu"
        case .menuItem: return "menu item"
        case .tabGroup: return "tab group"
        case .staticText: return "label"
        case .image: return "image"
        case .other: return "control"
        }
    }
}
