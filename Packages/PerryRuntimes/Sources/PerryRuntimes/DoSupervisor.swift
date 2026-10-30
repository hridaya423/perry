import Foundation
import PerryCore

public struct ConfirmationRequest: Sendable {
    public let id: UUID
    public let actionSummary: String
    public let tier: TrustTier
    public let reason: String
    public let targetSummary: String?
    public let requiredText: String?
    public let reversible: Bool

    public init(
        id: UUID = UUID(),
        actionSummary: String,
        tier: TrustTier,
        reason: String,
        targetSummary: String? = nil,
        requiredText: String? = nil,
        reversible: Bool = false
    ) {
        self.id = id
        self.actionSummary = actionSummary
        self.tier = tier
        self.reason = reason
        self.targetSummary = targetSummary
        self.requiredText = requiredText
        self.reversible = reversible
    }
}

public enum PlanDecision: Sendable {
    case run
    case stepThrough
    case replay
    case edit
    case cancel
}

public protocol Confirmer: Sendable {
    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool
}

public enum DoOutcome: Equatable, Sendable {
    case completed(stepsRun: Int)
    case blocked(reason: String)
    case failed(stepSummary: String, reason: String)

    public var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }

    public var transcriptOutcome: TranscriptEntry.Outcome {
        switch self {
        case .completed: .completed
        case .blocked: .stopped
        case .failed: .failed
        }
    }
}

private enum ActionExecutionError: Error, CustomStringConvertible, LocalizedError {
    var errorDescription: String? { description }

    case timedOut(actionID: ActionID, timeout: TimeInterval)
    case duplicateAction(actionID: ActionID, policy: IdempotencyPolicy)
    case conflictingIdempotencyKey(String)
    case typedResultActionMismatch(expected: ActionID, actual: ActionID)
    case typedResultOperationMismatch
    case verificationFailed(String)

    var description: String {
        switch self {
        case .timedOut(let actionID, let timeout):
            return "action \(actionID) exceeded its \(timeout)-second timeout"
        case .duplicateAction(let actionID, let policy):
            return "action \(actionID) cannot be executed again under \(policy)"
        case .conflictingIdempotencyKey(let key):
            return "idempotency key \(key) was reused for a different action"
        case .typedResultActionMismatch(let expected, let actual):
            return "executor returned result for action \(actual), expected \(expected)"
        case .typedResultOperationMismatch:
            return "executor returned a different operation than the planned action"
        case .verificationFailed(let reason):
            return "verification failed: \(reason)"
        }
    }
}

private enum ActionExecutionOutcome {
    case succeeded
    case cancelled
    case failed(reason: String)
}

public actor DoSupervisor {
    private enum Phase {
        case idle
        case running
        case paused
        case awaitingApproval
        case finished
    }

    private let trustGuard: TrustGuard
    private let activityLog: ActivityLog
    private let confirmer: Confirmer
    private let typedVerifier: any TypedActionVerifier
    private let onEvent: (@Sendable (DoEvent) async -> Void)?
    private let onTypedEvent: (@Sendable (TypedDoEvent) async -> Void)?
    private var phase = Phase.idle
    private var cancelRequested = false
    private var pauseRequested = false
    private var activeTypedExecution: Task<ActionExecutionResult, Error>?
    private var activeOperation: Task<VerificationStatus, Never>?
    private var cancelActiveConfirmation: (@Sendable () -> Void)?
    private var attemptedActionPolicies: [ActionID: IdempotencyPolicy] = [:]
    private var idempotencyKeySignatures: [String: String] = [:]

    public init(
        trustGuard: TrustGuard = TrustGuard(),
        activityLog: ActivityLog = ActivityLog(),
        confirmer: Confirmer,
        typedVerifier: any TypedActionVerifier = NoOpTypedActionVerifier(),
        onEvent: (@Sendable (DoEvent) async -> Void)? = nil,
        onTypedEvent: (@Sendable (TypedDoEvent) async -> Void)? = nil
    ) {
        self.trustGuard = trustGuard
        self.activityLog = activityLog
        self.confirmer = confirmer
        self.typedVerifier = typedVerifier
        self.onEvent = onEvent
        self.onTypedEvent = onTypedEvent
    }

    public func pause() async {
        pauseRequested = true
        if phase == .running {
            phase = .paused
            await emit(.paused)
        }
    }

    public func resume() async {
        pauseRequested = false
        if phase == .paused {
            phase = .running
            await emit(.resumed)
        }
    }

    public func steer(_ instruction: String) async {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase == .running || phase == .paused else { return }
        await emit(.steered(trimmed))
    }

    public func cancel() async {
        cancelRequested = true
        activeTypedExecution?.cancel()
        activeOperation?.cancel()
        cancelActiveConfirmation?()
        guard phase != .idle, phase != .finished else { return }
        phase = .finished
        await emit(.stopped(reason: "user cancelled the task"))
    }

    public func run(
        plan: ExecutionPlan,
        context: ScreenContext = .empty,
        targetWindow: WindowContext? = nil,
        typedExecutor: any ExecutableActionExecutor
    ) async -> DoOutcome {
        guard phase == .idle || phase == .finished else {
            return .blocked(reason: "a run is already in progress")
        }
        phase = .running
        cancelRequested = false
        pauseRequested = false
        await emit(.planned(steps: plan.actions.count))
        let outcome = await execute(plan, context: context, targetWindow: targetWindow, typedExecutor: typedExecutor)
        phase = .finished
        return outcome
    }

    private func execute(
        _ plan: ExecutionPlan,
        context: ScreenContext,
        targetWindow: WindowContext?,
        typedExecutor: any ExecutableActionExecutor
    ) async -> DoOutcome {
        guard !cancelRequested, !Task.isCancelled else {
            await stop(reason: "user cancelled before the task started")
            return .blocked(reason: "user cancelled before the task started")
        }
        await emit(.started)

        var planApprovalGrant: ExecutionApprovalGrant?
        if plan.actions.contains(where: { $0.approvalRequirement == .plan }) {
            do {
                planApprovalGrant = try ExecutionApprovalGrant(plan: plan, scope: .plan)
            } catch {
                let reason = "typed plan approval could not be issued: \(error)"
                await markFailed(stepSummary: "approval", reason: reason)
                return .failed(stepSummary: "approval", reason: reason)
            }
        }

        var stepsRun = 0
        while stepsRun < plan.actions.count {
            guard await waitForStepBoundary() else {
                await stop(reason: "user cancelled the task")
                return .blocked(reason: "user cancelled the task")
            }

            let action = plan.actions[stepsRun]
            let policy = action.policy
            await emitTyped(.actionStarted(index: stepsRun, action: action, tier: policy.trustTier))
            guard !trustGuard.isWindowBlocked(targetWindow) else {
                await finishUnsuccessfully(action: action, bundleID: targetWindow?.appBundleID)
                return .blocked(reason: "target window is on the blocked list")
            }
            if action.operation.kind == .integration || action.operation.kind == .askUser {
                let reason = action.operation.kind == .integration ? "writes to a connected service" : "needs your answer"
                guard await confirm(action: action, tier: policy.trustTier, reason: reason, targetWindow: targetWindow) else {
                    await finishUnsuccessfully(action: action, bundleID: targetWindow?.appBundleID)
                    return cancelRequested || Task.isCancelled
                        ? .blocked(reason: "user cancelled the task")
                        : .blocked(reason: "user denied \(action.summary)")
                }
            }

            let approvedAction: ApprovedExecutableAction
            do {
                approvedAction = try approvedTypedAction(action, plan: plan, planApprovalGrant: planApprovalGrant)
            } catch {
                let reason = "typed action approval failed: \(error)"
                _ = await failAction(action, targetWindow: targetWindow, reason: reason)
                return .failed(stepSummary: action.summary, reason: reason)
            }
            switch await perform(
                action,
                approvedAction: approvedAction,
                typedExecutor: typedExecutor,
                context: context,
                targetWindow: targetWindow,
                stepsRun: &stepsRun
            ) {
            case .succeeded:
                break
            case .cancelled:
                return .blocked(reason: "user cancelled the task")
            case .failed(let reason):
                return .failed(stepSummary: action.summary, reason: reason)
            }
        }

        guard !cancelRequested else {
            await stop(reason: "user cancelled the task")
            return .blocked(reason: "user cancelled the task")
        }
        await emit(.completed(stepsRun: stepsRun))
        return .completed(stepsRun: stepsRun)
    }

    private func approvedTypedAction(
        _ action: ExecutableAction,
        plan: ExecutionPlan,
        planApprovalGrant: ExecutionApprovalGrant?
    ) throws -> ApprovedExecutableAction {
        let grant: ExecutionApprovalGrant
        switch action.approvalRequirement {
        case .action:
            grant = try ExecutionApprovalGrant(plan: plan, scope: .action(action.id))
        case .plan:
            guard let planApprovalGrant else { throw ExecutionApprovalError.grantRequired }
            grant = planApprovalGrant
        case .none:
            throw ExecutionApprovalError.grantRequired
        }
        return try ApprovedExecutableAction(plan: plan, actionID: action.id, grant: grant)
    }

    private func confirm(
        action: ExecutableAction,
        tier: TrustTier,
        reason: String,
        targetWindow: WindowContext?
    ) async -> Bool {
        guard phase == .running || phase == .paused else { return false }
        phase = .awaitingApproval
        let actionTarget = targetWindow.map { "\($0.title) (\($0.appBundleID))" }
        let request = ConfirmationRequest(
            actionSummary: action.summary,
            tier: tier,
            reason: reason,
            targetSummary: actionTarget,
            requiredText: tier >= .red ? (actionTarget ?? action.summary) : nil,
            reversible: action.policy.reversible
        )
        await emit(.confirmationRequested(request))
        guard !cancelRequested && !Task.isCancelled else { return false }
        let approved = await awaitConfirmation(request)
        guard approved, !cancelRequested, !Task.isCancelled, phase == .awaitingApproval else { return false }
        phase = .running
        await emit(.confirmationAccepted(request.id))
        return !cancelRequested && !Task.isCancelled
    }

    private func awaitConfirmation(_ request: ConfirmationRequest) async -> Bool {
        let confirmation = Task { await confirmer.requestConfirmation(request) }
        cancelActiveConfirmation = { confirmation.cancel() }
        defer { cancelActiveConfirmation = nil }
        return await withTaskCancellationHandler(operation: {
            await confirmation.value
        }, onCancel: {
            confirmation.cancel()
        })
    }

    private func reserve(_ action: ExecutableAction) throws {
        let signature = "\(action.id.rawValue)|\(action.summary)|\(action.operation)"
        if let previous = attemptedActionPolicies[action.id], previous != action.idempotency || !action.idempotency.canRepeat {
            throw ActionExecutionError.duplicateAction(actionID: action.id, policy: action.idempotency)
        }
        if case .keyed(let key) = action.idempotency {
            if let previous = idempotencyKeySignatures[key], previous != signature {
                throw ActionExecutionError.conflictingIdempotencyKey(key)
            }
            idempotencyKeySignatures[key] = signature
        }
        attemptedActionPolicies[action.id] = action.idempotency
    }

    private func perform(
        _ action: ExecutableAction,
        approvedAction: ApprovedExecutableAction,
        typedExecutor: any ExecutableActionExecutor,
        context: ScreenContext,
        targetWindow: WindowContext?,
        stepsRun: inout Int
    ) async -> ActionExecutionOutcome {
        guard await waitForStepBoundary() else {
            await stop(reason: "user cancelled the task")
            return .cancelled
        }
        do {
            try reserve(action)
            let result = try await executeWithTimeout(approvedAction, executor: typedExecutor)
            guard !cancelRequested else {
                await stop(reason: "user cancelled the task")
                return .cancelled
            }
            guard result.actionID == action.id else {
                throw ActionExecutionError.typedResultActionMismatch(expected: action.id, actual: result.actionID)
            }
            guard result.operation == action.operation else {
                throw ActionExecutionError.typedResultOperationMismatch
            }
            let verification = await verifyTyped(approvedAction: approvedAction, result: result, context: context)
            guard !cancelRequested && !Task.isCancelled else {
                await stop(reason: "user cancelled the task")
                return .cancelled
            }
            await emitTyped(.verification(action: action, status: verification))
            switch verification {
            case .verified:
                break
            case .notRequired:
                throw ActionExecutionError.verificationFailed("typed action postcondition was not independently verified")
            case .unverified(let reason):
                throw ActionExecutionError.verificationFailed(reason)
            }
            let recorded = await record(
                action.summary,
                bundleID: targetWindow?.appBundleID,
                tier: action.policy.trustTier,
                outcome: .confirmed,
                reversible: action.policy.reversible,
                verified: verificationValue(verification)
            )
            guard recorded else {
                let reason = "could not persist activity log"
                await markFailed(stepSummary: action.summary, reason: reason)
                return .failed(reason: reason)
            }
            guard !cancelRequested else {
                await stop(reason: "user cancelled the task")
                return .cancelled
            }
            stepsRun += 1
            return .succeeded
        } catch is CancellationError {
            await stop(reason: "user cancelled the task")
            return .cancelled
        } catch {
            return await failAction(
                action,
                targetWindow: targetWindow,
                reason: "\(error)"
            )
        }
    }

    private func failAction(
        _ action: ExecutableAction,
        targetWindow: WindowContext?,
        reason: String
    ) async -> ActionExecutionOutcome {
        _ = await record(
            action.summary,
            bundleID: targetWindow?.appBundleID,
            tier: action.policy.trustTier,
            outcome: .denied,
            reversible: action.policy.reversible,
            verified: false
        )
        await markFailed(stepSummary: action.summary, reason: reason)
        return .failed(reason: reason)
    }

    private func executeWithTimeout(
        _ approvedAction: ApprovedExecutableAction,
        executor: any ExecutableActionExecutor
    ) async throws -> ActionExecutionResult {
        let action = approvedAction.action
        let execution = Task<ActionExecutionResult, Error> {
            try await executor.execute(approvedAction)
        }
        activeTypedExecution = execution
        defer { activeTypedExecution = nil }
        return try await withTaskCancellationHandler(operation: {
            try await withThrowingTaskGroup(of: ActionExecutionResult.self) { group in
                group.addTask { try await execution.value }
                group.addTask {
                    try await Task.sleep(nanoseconds: Self.timeoutNanoseconds(for: action.timeout))
                    throw ActionExecutionError.timedOut(actionID: action.id, timeout: action.timeout)
                }
                defer {
                    group.cancelAll()
                    execution.cancel()
                }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
        }, onCancel: {
            execution.cancel()
        })
    }

    private func verifyTyped(
        approvedAction: ApprovedExecutableAction,
        result: ActionExecutionResult,
        context: ScreenContext
    ) async -> VerificationStatus {
        let operation = Task {
            await typedVerifier.verify(approvedAction: approvedAction, result: result, context: context)
        }
        activeOperation = operation
        defer { activeOperation = nil }
        return await withTaskCancellationHandler(operation: {
            await operation.value
        }, onCancel: {
            operation.cancel()
        })
    }

    private static func timeoutNanoseconds(for timeout: TimeInterval) -> UInt64 {
        let nanoseconds = timeout * 1_000_000_000
        guard nanoseconds < Double(UInt64.max) else { return UInt64.max }
        return max(1, UInt64(nanoseconds))
    }

    private func finishUnsuccessfully(action: ExecutableAction, bundleID: String?) async {
        await stop(reason: "operation denied")
        _ = await record(action.summary, bundleID: bundleID, tier: action.policy.trustTier, outcome: .denied, reversible: false)
    }

    private func stop(reason: String) async {
        guard phase != .finished else { return }
        phase = .finished
        await emit(.stopped(reason: reason))
    }

    private func markFailed(stepSummary: String, reason: String) async {
        phase = .finished
        await emit(.failed(stepSummary: stepSummary, reason: reason))
    }

    private func waitForStepBoundary() async -> Bool {
        while pauseRequested {
            if cancelRequested || Task.isCancelled { return false }
            if phase == .running {
                phase = .paused
                await emit(.paused)
            }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return false
            }
        }
        return !cancelRequested && !Task.isCancelled
    }

    private func verificationValue(_ status: VerificationStatus) -> Bool? {
        switch status {
        case .notRequired: return nil
        case .verified: return true
        case .unverified: return false
        }
    }

    private func emit(_ event: DoEvent) async {
        await onEvent?(event)
    }

    private func emitTyped(_ event: TypedDoEvent) async {
        await onTypedEvent?(event)
    }

    private func record(_ summary: String, bundleID: String?, tier: TrustTier, outcome: ActivityEntry.Outcome, reversible: Bool, verified: Bool? = nil) async -> Bool {
        await activityLog.record(
            ActivityEntry(
                actionSummary: summary,
                targetAppBundleID: bundleID,
                tier: tier,
                outcome: outcome,
                reversible: reversible,
                verified: verified
            )
        )
    }
}
