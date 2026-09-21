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

/// The plan-card answer: run the whole plan, walk it one action at a time
/// with a confirmation each, replay the preview, send the goal back for
/// editing, or stop.
public enum PlanDecision: Sendable {
    case run
    case stepThrough
    case replay
    case edit
    case cancel
}

public protocol Confirmer: Sendable {
    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool
    func requestPlanDecision(_ request: ConfirmationRequest) async -> PlanDecision
}

extension Confirmer {
    /// Confirmers without the extra controls degrade to run/cancel.
    public func requestPlanDecision(_ request: ConfirmationRequest) async -> PlanDecision {
        await requestConfirmation(request) ? .run : .cancel
    }
}

public enum DoOutcome: Equatable, Sendable {
    case completed(stepsRun: Int)
    case blocked(reason: String)
    case failed(stepSummary: String, reason: String)
}

private enum ActionExecutionError: Error, CustomStringConvertible {
    case timedOut(actionID: ActionID, timeout: TimeInterval)
    case duplicateAction(actionID: ActionID, policy: IdempotencyPolicy)
    case conflictingIdempotencyKey(String)
    case resultStepMismatch(expected: String, actual: String)
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
        case .resultStepMismatch(let expected, let actual):
            return "executor returned result for step \(actual), expected \(expected)"
        case .typedResultActionMismatch(let expected, let actual):
            return "executor returned result for action \(actual), expected \(expected)"
        case .typedResultOperationMismatch:
            return "executor returned a different operation than the planned action"
        case .verificationFailed(let reason):
            return "verification failed: \(reason)"
        }
    }
}

private final class ActionResultContinuation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        finish(.success(value))
    }

    func resume(throwing error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

private final class ActionResultContinuationSlot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: ActionResultContinuation<Value>?

    func store(_ continuation: ActionResultContinuation<Value>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func take() -> ActionResultContinuation<Value>? {
        lock.lock()
        defer { lock.unlock() }
        return continuation
    }
}

private enum ActionExecutionOutcome {
    case succeeded
    case cancelled
    case failed(reason: String)
}

private enum PlanApprovalResult {
    case approved(tier: TrustTier, stepThrough: Bool)
    case denied
    case edit
    case cancelled
}

public actor DoSupervisor {
    private let trustGuard: TrustGuard
    private let activityLog: ActivityLog
    private var orchestrator: SupervisorStateMachine
    private let confirmer: Confirmer
    private let typedVerifier: any TypedActionVerifier
    private let cancelWindow: TimeInterval
    private let onEvent: (@Sendable (DoEvent) async -> Void)?
    private let onTypedEvent: (@Sendable (TypedDoEvent) async -> Void)?
    private var cancelRequested = false
    private var pauseRequested = false
    private var steeringInstruction: String?
    private var warnings: [String] = []
    private var isRunning = false
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
        cancelWindow: TimeInterval = 0,
        onEvent: (@Sendable (DoEvent) async -> Void)? = nil,
        onTypedEvent: (@Sendable (TypedDoEvent) async -> Void)? = nil
    ) {
        self.trustGuard = trustGuard
        self.activityLog = activityLog
        self.confirmer = confirmer
        self.orchestrator = SupervisorStateMachine()
        self.typedVerifier = typedVerifier
        self.cancelWindow = max(0, cancelWindow)
        self.onEvent = onEvent
        self.onTypedEvent = onTypedEvent
    }

    public var sessionState: SupervisorState { orchestrator.state }

    public func verificationWarnings() -> [String] {
        warnings
    }

    public func pause() async {
        pauseRequested = true
        if orchestrator.state == .executing(.running) {
            guard transition(.pause) else { return }
            await emit(.paused)
        }
    }

    public func resume() async {
        pauseRequested = false
        if orchestrator.state == .executing(.paused) {
            guard transition(.resume) else { return }
            await emit(.resumed)
        }
    }

    public func steer(_ instruction: String) async {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard transition(.steer) else { return }
        steeringInstruction = trimmed
        await emit(.steered(trimmed))
    }

    public func cancel() async {
        cancelRequested = true
        activeTypedExecution?.cancel()
        activeOperation?.cancel()
        cancelActiveConfirmation?()
        let state = orchestrator.state
        if state == .executing(.awaitingApproval) {
            if transition(.denyAction) {
                await emit(.stopped(reason: "user cancelled the task"))
            }
        } else if state == .starting || state == .executing(.running) || state == .executing(.paused) {
            if transition(.cancel) {
                await emit(.stopped(reason: state == .starting ? "user cancelled before the task started" : "user cancelled the task"))
            }
        }
    }

    public func run(
        plan: ExecutionPlan,
        context: ScreenContext = .empty,
        targetWindow: WindowContext? = nil,
        typedExecutor: any TypedActionExecutor
    ) async -> DoOutcome {
        guard await beginRun() else {
            return .blocked(reason: "session machine refused start")
        }
        defer { isRunning = false }
        guard await beginStartWindow() else {
            await stop(reason: "user cancelled before the task started")
            return .blocked(reason: "user cancelled before the task started")
        }
        await emit(.planned(steps: plan.actions.count))
        return await execute(
            plan,
            context: context,
            targetWindow: targetWindow,
            typedExecutor: typedExecutor
        )
    }

    private func beginRun() async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        prepareForRun()
        switch orchestrator.state {
        case .failed:
            guard transition(.retry) else {
                isRunning = false
                return false
            }
        case .reporting, .stopped:
            orchestrator.reset()
        default:
            break
        }
        let accepted = await enterDoing()
        if !accepted { isRunning = false }
        return accepted
    }

    private func prepareForRun() {
        cancelRequested = false
        pauseRequested = false
        steeringInstruction = nil
        warnings.removeAll()
    }

    private func execute(
        _ plan: ExecutionPlan,
        context: ScreenContext,
        targetWindow: WindowContext?,
        typedExecutor: any TypedActionExecutor
    ) async -> DoOutcome {
        guard !cancelRequested else {
            await stop(reason: "user cancelled before the task started")
            return .blocked(reason: "user cancelled before the task started")
        }
        guard transition(.cancelWindowElapsed) else {
            let reason = "session machine refused execution start"
            await emit(.failed(stepSummary: "start", reason: reason))
            return .failed(stepSummary: "start", reason: reason)
        }
        await emit(.started)

        var stepsRun = 0
        var planApprovalChecked = false
        var stepThrough = false
        var planApprovalGrant: ExecutionApprovalGrant?
        while stepsRun < plan.actions.count {
            guard await waitForStepBoundary() else {
                await stop(reason: "user cancelled the task")
                return .blocked(reason: "user cancelled the task")
            }

            if !planApprovalChecked {
                switch await requestTypedPlanApproval(for: plan, targetWindow: targetWindow) {
                case .approved(_, let wantsStepThrough):
                    stepThrough = wantsStepThrough
                    // The rehearsal doubles as the .plan-scope grant only
                    // when an action actually requires it; minting one for a
                    // plan with no .plan action is a scope mismatch.
                    guard plan.actions.contains(where: { $0.approvalRequirement == .plan }) else { break }
                    do {
                        planApprovalGrant = try ExecutionApprovalGrant(plan: plan, scope: .plan)
                    } catch {
                        let reason = "typed plan approval could not be issued: \(error)"
                        await markFailed(stepSummary: "approval", reason: reason)
                        return .failed(stepSummary: "approval", reason: reason)
                    }
                case .denied:
                    await stop(reason: "user denied the execution plan")
                    return .blocked(reason: "user denied the execution plan")
                case .edit:
                    await stop(reason: "goal sent back for editing")
                    return .blocked(reason: "goal sent back for editing")
                case .cancelled:
                    await stop(reason: "user cancelled the task")
                    return .blocked(reason: "user cancelled the task")
                }
                planApprovalChecked = true
            }

            let action = plan.actions[stepsRun]
            let policy = action.policy
            await emitTyped(.actionStarted(index: stepsRun, action: action, tier: policy.trustTier))
            guard !trustGuard.isWindowBlocked(targetWindow) else {
                await finishUnsuccessfully(action: action, bundleID: targetWindow?.appBundleID)
                return .blocked(reason: "target window is on the blocked list")
            }
            let needsConfirmation: Bool
            let confirmationReason: String
            if stepThrough {
                needsConfirmation = true
                confirmationReason = "step-through review"
            } else if policy.trustTier >= .orange {
                needsConfirmation = action.approvalRequirement == .action || planApprovalGrant == nil
                confirmationReason = policy.trustTier >= .red
                    ? "high-risk action requires explicit approval"
                    : "irreversible action needs one confirmation"
            } else {
                needsConfirmation = action.approvalRequirement == .action
                confirmationReason = "execution plan action requires explicit approval"
            }
            if needsConfirmation {
                guard await confirm(
                    action: action,
                    tier: policy.trustTier,
                    reason: confirmationReason,
                    targetWindow: targetWindow
                ) else {
                    await finishUnsuccessfully(action: action, bundleID: targetWindow?.appBundleID)
                    return cancelRequested || Task.isCancelled
                        ? .blocked(reason: "user cancelled the task")
                        : .blocked(reason: "user denied \(action.summary)")
                }
            }

            let approvedAction: ApprovedExecutableAction
            do {
                approvedAction = try approvedTypedAction(
                    action,
                    plan: plan,
                    planApprovalGrant: planApprovalGrant
                )
            } catch {
                let reason = "typed action approval failed: \(error)"
                _ = await failAction(
                    action,
                    targetWindow: targetWindow,
                    reason: reason
                )
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
        guard transition(.taskFinished), transition(.dismiss) else {
            let reason = "session machine refused task completion"
            await emit(.failed(stepSummary: "completion", reason: reason))
            return .failed(stepSummary: "completion", reason: reason)
        }
        await emit(.completed(stepsRun: stepsRun))
        return .completed(stepsRun: stepsRun)
    }

    private func enterDoing() async -> Bool {
        switch orchestrator.state {
        case .idle:
            guard transition(.wake) else { return false }
            return transition(.startTask)
        case .listening:
            return transition(.startTask)
        case .starting, .executing(.running), .executing(.paused):
            return true
        default:
            return false
        }
    }

    private func beginStartWindow() async -> Bool {
        await emit(.starting(deadline: cancelWindow > 0 ? Date().addingTimeInterval(cancelWindow) : nil))
        guard cancelWindow > 0 else { return !cancelRequested && !Task.isCancelled }
        return !(await waitForStartWindow())
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

    private func requestTypedPlanApproval(
        for plan: ExecutionPlan,
        targetWindow: WindowContext?
    ) async -> PlanApprovalResult {
        // Ghost rehearsal: every typed plan is previewed — real actions and
        // targets, not planner prose — before the first dispatch. Approving
        // the preview doubles as the .plan-scope grant; per-action .action
        // requirements still confirm individually at their step.
        let tier = plan.actions
            .map { $0.policy.trustTier }
            .max() ?? .green
        guard transition(.requestConfirmation) else { return .denied }
        let planTarget = targetWindow.map { "\($0.title) (\($0.appBundleID))" }
        let steps = plan.actions.enumerated().map { index, action in
            "\(index + 1). \(action.summary) — \(action.operation.rehearsalTarget)"
        }.joined(separator: "\n")
        let request = ConfirmationRequest(
            actionSummary: plan.goal,
            tier: tier,
            reason: "planned steps:\n\(steps)",
            targetSummary: planTarget,
            requiredText: tier >= .red ? (planTarget ?? plan.goal) : nil,
            reversible: plan.actions.allSatisfy { $0.policy.reversible }
        )
        var decision: PlanDecision
        repeat {
            await emit(.confirmationRequested(request))
            guard !cancelRequested && !Task.isCancelled else { return .cancelled }
            decision = await awaitPlanDecision(request)
            guard !cancelRequested && !Task.isCancelled else { return .cancelled }
            // Replay re-presents the same preview; the surface repaints marks
            // from a fresh observation, so the review never rests on stale targets.
        } while decision == .replay
        switch decision {
        case .cancel: return .denied
        case .edit: return .edit
        case .run, .stepThrough: break
        case .replay: preconditionFailure("replay exits the loop")
        }
        guard transition(.approveAction) else {
            return cancelRequested ? .cancelled : .denied
        }
        await emit(.confirmationAccepted(request.id))
        guard !cancelRequested && !Task.isCancelled else { return .cancelled }
        return .approved(tier: tier, stepThrough: decision == .stepThrough)
    }

    private func awaitPlanDecision(_ request: ConfirmationRequest) async -> PlanDecision {
        let confirmation = Task { await confirmer.requestPlanDecision(request) }
        cancelActiveConfirmation = { confirmation.cancel() }
        defer { cancelActiveConfirmation = nil }
        return await withTaskCancellationHandler(operation: {
            await confirmation.value
        }, onCancel: {
            confirmation.cancel()
        })
    }

    private func confirm(
        action: ExecutableAction,
        tier: TrustTier,
        reason: String,
        targetWindow: WindowContext?
    ) async -> Bool {
        guard transition(.requestConfirmation) else { return false }
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
        guard approved, !cancelRequested, !Task.isCancelled else { return false }
        guard transition(.approveAction) else { return false }
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

    private func validateReplay(_ action: ExecutableAction) throws {
        if let previous = attemptedActionPolicies[action.id], previous != action.idempotency {
            throw ActionExecutionError.duplicateAction(actionID: action.id, policy: action.idempotency)
        }
        if attemptedActionPolicies[action.id] != nil, !action.idempotency.canRepeat {
            throw ActionExecutionError.duplicateAction(actionID: action.id, policy: action.idempotency)
        }
        if case .keyed(let key) = action.idempotency {
            let signature = "\(action.id.rawValue)|\(action.summary)|\(action.operation)"
            if let previous = idempotencyKeySignatures[key], previous != signature {
                throw ActionExecutionError.conflictingIdempotencyKey(key)
            }
        }
    }

    private func reserve(_ action: ExecutableAction) throws {
        try validateReplay(action)
        if case .keyed(let key) = action.idempotency {
            let signature = "\(action.id.rawValue)|\(action.summary)|\(action.operation)"
            idempotencyKeySignatures[key] = signature
        }
        attemptedActionPolicies[action.id] = action.idempotency
    }

    private func perform(
        _ action: ExecutableAction,
        approvedAction: ApprovedExecutableAction,
        typedExecutor: any TypedActionExecutor,
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
        executor: any TypedActionExecutor
    ) async throws -> ActionExecutionResult {
        let execution = Task<ActionExecutionResult, Error> {
            try await executor.execute(approvedAction)
        }
        activeTypedExecution = execution
        defer { activeTypedExecution = nil }
        let timeout = Task<ActionExecutionResult, Error> {
            try await Task.sleep(nanoseconds: Self.timeoutNanoseconds(for: approvedAction.action.timeout))
            throw ActionExecutionError.timedOut(actionID: approvedAction.action.id, timeout: approvedAction.action.timeout)
        }
        do {
            let result = try await firstActionResult(execution: execution, timeout: timeout)
            execution.cancel()
            timeout.cancel()
            return result
        } catch {
            execution.cancel()
            timeout.cancel()
            _ = try? await execution.value
            throw error
        }
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

    private func firstActionResult<Value: Sendable>(
        execution: Task<Value, Error>,
        timeout: Task<Value, Error>
    ) async throws -> Value {
        let slot = ActionResultContinuationSlot<Value>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                let gate = ActionResultContinuation(continuation)
                slot.store(gate)
                if Task.isCancelled {
                    gate.resume(throwing: CancellationError())
                    return
                }
                Task {
                    do {
                        gate.resume(returning: try await execution.value)
                    } catch {
                        gate.resume(throwing: error)
                    }
                }
                Task {
                    do {
                        gate.resume(returning: try await timeout.value)
                    } catch {
                        gate.resume(throwing: error)
                    }
                }
            }
        }, onCancel: {
            execution.cancel()
            timeout.cancel()
            slot.take()?.resume(throwing: CancellationError())
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
        let state = orchestrator.state
        guard state != .stopped else { return }
        let accepted: Bool
        if state == .executing(.awaitingApproval) {
            accepted = transition(.denyAction)
        } else if state == .starting || state == .executing(.running) || state == .executing(.paused) {
            accepted = transition(.cancel)
        } else {
            accepted = transition(.dismiss)
        }
        if accepted {
            await emit(.stopped(reason: reason))
        } else {
            await emit(.failed(stepSummary: "stop", reason: "session machine refused stop: \(reason)"))
        }
    }

    private func markFailed(stepSummary: String, reason: String) async {
        if transition(.taskFailed) {
            await emit(.failed(stepSummary: stepSummary, reason: reason))
        } else {
            await emit(.failed(stepSummary: stepSummary, reason: "\(reason); session machine refused failure transition"))
        }
    }

    private func waitForStartWindow() async -> Bool {
        let deadline = Date().addingTimeInterval(cancelWindow)
        while Date() < deadline {
            if cancelRequested || Task.isCancelled { return true }
            let remaining = deadline.timeIntervalSinceNow
            let interval = min(0.05, max(0.01, remaining))
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return true
            }
        }
        return cancelRequested || Task.isCancelled
    }

    private func waitForStepBoundary() async -> Bool {
        while pauseRequested {
            if cancelRequested || Task.isCancelled { return false }
            if orchestrator.state == .executing(.running) {
                guard transition(.pause) else { return false }
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

    private func transition(_ event: SupervisorEvent) -> Bool {
        do {
            _ = try orchestrator.send(event)
            return true
        } catch {
            warnings.append("\(error)")
            return false
        }
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
