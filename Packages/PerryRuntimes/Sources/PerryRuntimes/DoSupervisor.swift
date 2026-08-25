import Foundation
import PerryCore

public struct ConfirmationRequest: Sendable {
    public let actionSummary: String
    public let tier: TrustTier
    public let reason: String

    public init(actionSummary: String, tier: TrustTier, reason: String) {
        self.actionSummary = actionSummary
        self.tier = tier
        self.reason = reason
    }
}

public protocol Confirmer: Sendable {
    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool
}

public enum DoOutcome: Equatable, Sendable {
    case completed(stepsRun: Int)
    case blocked(reason: String)
    case failed(stepSummary: String, reason: String)
}

public actor DoSupervisor {
    private let trustGuard: TrustGuard
    private let activityLog: ActivityLog
    private let orchestrator: AsyncSessionOrchestrator
    private let confirmer: Confirmer

    public init(
        trustGuard: TrustGuard = TrustGuard(),
        activityLog: ActivityLog = ActivityLog(),
        confirmer: Confirmer
    ) {
        self.trustGuard = trustGuard
        self.activityLog = activityLog
        self.confirmer = confirmer
        self.orchestrator = AsyncSessionOrchestrator()
    }

    public var sessionState: SessionState {
        get async { await orchestrator.state }
    }

    public func run(
        goal: String,
        runtime: any AgentRuntime,
        context: ScreenContext = .empty,
        targetWindow: WindowContext? = nil,
        executor: (any AgentRuntime)? = nil
    ) async -> DoOutcome {
        guard await enterDoing() else {
            return .blocked(reason: "session machine refused start")
        }
        do {
            let plan = try await runtime.plan(goal: goal, context: context)
            return await execute(plan, targetWindow: targetWindow, executor: executor ?? runtime)
        } catch {
            await stop()
            await record("planning failed for \(goal)", bundleID: targetWindow?.appBundleID, tier: .green, outcome: .denied, reversible: true)
            return .failed(stepSummary: "plan", reason: "\(error)")
        }
    }

    public func run(
        plan: Plan,
        targetWindow: WindowContext? = nil,
        executor: (any AgentRuntime)? = nil
    ) async -> DoOutcome {
        guard await enterDoing() else {
            return .blocked(reason: "session machine refused start")
        }
        return await execute(plan, targetWindow: targetWindow, executor: executor)
    }

    private func execute(
        _ plan: Plan,
        targetWindow: WindowContext?,
        executor: (any AgentRuntime)?
    ) async -> DoOutcome {
        var stepsRun = 0
        for step in plan.steps {
            let descriptor = StepActionMapper.descriptor(for: step, goal: plan.goal, targetAppBundleID: targetWindow?.appBundleID)
            let decision = trustGuard.decide(action: descriptor, targetWindow: targetWindow)

            switch decision {
            case .deny(let reason):
                await finishUnsuccessfully(descriptor: descriptor, bundleID: targetWindow?.appBundleID)
                return .blocked(reason: reason)

            case .requireConfirmation(let tier, let reason):
                _ = try? await orchestrator.send(.requestConfirmation)
                let approved = await confirmer.requestConfirmation(
                    ConfirmationRequest(actionSummary: descriptor.summary, tier: tier, reason: reason)
                )
                guard approved else {
                    await finishUnsuccessfully(descriptor: descriptor, bundleID: targetWindow?.appBundleID)
                    return .blocked(reason: "user denied \(descriptor.summary)")
                }
                _ = try? await orchestrator.send(.approveAction)
                let consent = ConsentHandle(stepID: step.id, tier: tier)
                if !(await perform(step, descriptor: descriptor, consent: consent, executor: executor, targetWindow: targetWindow, stepsRun: &stepsRun)) {
                    return .failed(stepSummary: step.summary, reason: "execution failed")
                }

            case .allowAutonomous:
                if !(await perform(step, descriptor: descriptor, consent: nil, executor: executor, targetWindow: targetWindow, stepsRun: &stepsRun)) {
                    return .failed(stepSummary: step.summary, reason: "execution failed")
                }
            }
        }

        _ = try? await orchestrator.send(.taskFinished)
        _ = try? await orchestrator.send(.dismiss)
        return .completed(stepsRun: stepsRun)
    }

    private func enterDoing() async -> Bool {
        switch await orchestrator.state {
        case .doing:
            return true
        case .idle:
            guard (try? await orchestrator.send(.wake)) != nil else { return false }
            return (try? await orchestrator.send(.startDoing)) != nil
        case .listening:
            return (try? await orchestrator.send(.startDoing)) != nil
        default:
            return false
        }
    }

    private func perform(
        _ step: Step,
        descriptor: ActionDescriptor,
        consent: ConsentHandle?,
        executor: (any AgentRuntime)?,
        targetWindow: WindowContext?,
        stepsRun: inout Int
    ) async -> Bool {
        guard let executor else {
            await record("\(descriptor.summary) skipped: no executor bound", bundleID: targetWindow?.appBundleID, tier: trustGuard.classify(descriptor), outcome: .denied, reversible: true)
            await stop()
            return false
        }
        do {
            let result = try await executor.execute(step, consent: consent)
            await record(
                descriptor.summary,
                bundleID: targetWindow?.appBundleID,
                tier: trustGuard.classify(descriptor),
                outcome: consent == nil ? .allowed : .confirmed,
                reversible: descriptor.kind != .moveToTrash
            )
            guard result.success else {
                await stop()
                return false
            }
            stepsRun += 1
            return true
        } catch {
            await record("\(descriptor.summary) threw", bundleID: targetWindow?.appBundleID, tier: trustGuard.classify(descriptor), outcome: .denied, reversible: true)
            await stop()
            return false
        }
    }

    private func finishUnsuccessfully(descriptor: ActionDescriptor, bundleID: String?) async {
        await stop()
        await record(descriptor.summary, bundleID: bundleID, tier: trustGuard.classify(descriptor), outcome: .denied, reversible: false)
    }

    private func stop() async {
        if (try? await orchestrator.send(.denyAction)) == nil {
            _ = try? await orchestrator.send(.dismiss)
        }
    }

    private func record(_ summary: String, bundleID: String?, tier: TrustTier, outcome: ActivityEntry.Outcome, reversible: Bool) async {
        await activityLog.record(
            ActivityEntry(
                actionSummary: summary,
                targetAppBundleID: bundleID,
                tier: tier,
                outcome: outcome,
                reversible: reversible
            )
        )
    }
}
