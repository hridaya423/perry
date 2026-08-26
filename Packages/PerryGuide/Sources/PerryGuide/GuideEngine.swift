import Foundation
import PerryCore

/// Drives step-follows-you teaching: present step N, wait for the user to act,
/// confirm the screen changed, advance. Pure over injectable readers so the
/// whole loop is testable without a live UI.
public actor GuideEngine {
    public enum Phase: Equatable, Sendable {
        case idle
        case presenting(stepIndex: Int)
        case waitingForUser(stepIndex: Int)
        case finished
    }

    private let planner: GuidePlanning
    private let reader: AXTreeReading
    private let changeDetector: ScreenChangeDetector
    private(set) public var phase: Phase
    private(set) public var plan: GuidePlan?

    public init(
        planner: GuidePlanning,
        reader: AXTreeReading,
        changeDetector: ScreenChangeDetector = ScreenChangeDetector()
    ) {
        self.planner = planner
        self.reader = reader
        self.changeDetector = changeDetector
        self.phase = .idle
    }

    public func start(goal: String) async throws -> GuideStep? {
        let snapshot = try await reader.readFrontmost()
        let builtPlan = try await planner.plan(goal: goal, snapshot: snapshot)
        plan = builtPlan
        if builtPlan.steps.isEmpty {
            phase = .finished
            return nil
        }
        phase = .presenting(stepIndex: 0)
        return builtPlan.steps[0]
    }

    /// Called when the user reports acting (or a timeout fires). Advances only
    /// when the screen actually changed; otherwise stays waiting.
    public func userActed() async -> AdvanceResult {
        guard case .presenting(let index) = phase, let currentPlan = plan else {
            return .notPresenting
        }

        let before = (try? await reader.readFrontmost())
        // Give the UI a beat to settle after the user's action.
        try? await Task.sleep(nanoseconds: 250_000_000)
        let after = try? await reader.readFrontmost()

        if let before, let after, changeDetector.didChange(from: before, to: after) {
            return advance(from: index, plan: currentPlan)
        }
        phase = .waitingForUser(stepIndex: index)
        return .stillWaiting(stepIndex: index)
    }

    public func skip() async -> AdvanceResult {
        guard case .presenting(let index) = phase, let currentPlan = plan else {
            return .notPresenting
        }
        return advance(from: index, plan: currentPlan)
    }

    public func stop() {
        phase = .idle
        plan = nil
    }

    private func advance(from index: Int, plan currentPlan: GuidePlan) -> AdvanceResult {
        let next = index + 1
        if next >= currentPlan.steps.count {
            phase = .finished
            return .finished
        }
        phase = .presenting(stepIndex: next)
        return .advanced(toStep: currentPlan.steps[next], stepIndex: next)
    }
}

public enum AdvanceResult: Equatable, Sendable {
    case advanced(toStep: GuideStep, stepIndex: Int)
    case stillWaiting(stepIndex: Int)
    case finished
    case notPresenting
}
