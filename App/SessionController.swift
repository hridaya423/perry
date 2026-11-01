import Combine
import Foundation
import PerryBrain
import PerryCore
import PerryRuntimes

struct InvocationState: Equatable {
    let id: UUID
    let startedAt: Date

    init(id: UUID = UUID(), startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
    }
}

struct GuideSessionState: Equatable {
    let id: UUID
    var threadID: UUID = UUID()
    let goal: String
    let startedAt: Date
    let appBundleID: String?
    var plannedSteps: [String] = []
    var steps: [String] = []
    var presentedStepIDs: Set<UUID> = []
    var actionableStepIDs: Set<UUID> = []
}

struct AskSessionState: Equatable {
    let id: UUID
    var threadID: UUID? = nil
    var pendingGuideRequest: PerryThread.WaitingInput? = nil
    let startedAt: Date
    var question: String
    var answerText: String?
    var followUpPrompt: String?
    var turnCount = 0
    var isWorking = false
}

struct TalkSessionState: Equatable {
    let id: UUID
    var threadID: UUID? = nil
    let startedAt: Date
    var transcript: String
    var answerText: String?
    var turnCount = 0
    var isListening = false
    var isWorking = false
}

enum ExecutionPhase: Equatable {
    case starting
    case running
    case paused
    case awaitingApproval
    case verifying
    case stopping
}

enum ExecutionFinalizationPhase: Equatable {
    case verifying
    case stopping
}

enum ExecutionLifecycle: Equatable {
    case starting
    case running
    case paused
    case awaitingApproval(ExecutionApproval)
    case verifying
    case stopping
    case finalizing(ExecutionFinalizationPhase)
}

struct ExecutionApproval: Equatable {
    let id: UUID
    let actionSummary: String
    let tier: TrustTier

    init(id: UUID, actionSummary: String = "", tier: TrustTier = .green) {
        self.id = id
        self.actionSummary = actionSummary
        self.tier = tier
    }
}

struct ExecutionStepEvidence: Equatable {
    let id: String
    let summary: String
    let tier: TrustTier
    let reversible: Bool
    let startedAt: Date
    let index: Int
    fileprivate(set) var verificationNote: String?

    init(
        id: String,
        summary: String,
        tier: TrustTier = .green,
        reversible: Bool = true,
        startedAt: Date = .distantPast,
        index: Int = 0,
        verificationNote: String? = nil
    ) {
        self.id = id
        self.summary = summary
        self.tier = tier
        self.reversible = reversible
        self.startedAt = startedAt
        self.index = index
        self.verificationNote = verificationNote
    }
}

struct ExecutionVerificationEvidence: Equatable {
    let stepID: String
    let verified: Bool
    let warning: String?
    let evidence: String?

    init(stepID: String, verified: Bool, warning: String? = nil, evidence: String? = nil) {
        self.stepID = stepID
        self.verified = verified
        self.warning = warning
        self.evidence = evidence
    }
}

struct ExecutionSessionState: Equatable {
    let taskID: UUID
    let goal: String
    let startedAt: Date
    let appBundleID: String?
    let providerRoute: String?
    let workspace: URL
    fileprivate(set) var lifecycle: ExecutionLifecycle
    fileprivate(set) var stepEvidence: [ExecutionStepEvidence]
    fileprivate(set) var verificationEvidence: [ExecutionVerificationEvidence]
    fileprivate(set) var initialWarnings: [String]
    fileprivate(set) var totalSteps: Int
    fileprivate(set) var stopRequested: Bool
    fileprivate(set) var finalizationOutcome: DoOutcome?

    init(
        taskID: UUID,
        goal: String,
        startedAt: Date,
        appBundleID: String?,
        providerRoute: String? = nil,
        workspace: URL,
        lifecycle: ExecutionLifecycle,
        stepEvidence: [ExecutionStepEvidence] = [],
        verificationEvidence: [ExecutionVerificationEvidence] = [],
        initialWarnings: [String] = [],
        totalSteps: Int = 0,
        stopRequested: Bool = false,
        finalizationOutcome: DoOutcome? = nil
    ) {
        precondition(totalSteps >= 0)
        self.taskID = taskID
        self.goal = goal
        self.startedAt = startedAt
        self.appBundleID = appBundleID
        self.providerRoute = providerRoute
        self.workspace = workspace
        self.lifecycle = lifecycle
        self.stepEvidence = stepEvidence
        self.verificationEvidence = verificationEvidence
        self.initialWarnings = initialWarnings
        self.totalSteps = totalSteps
        self.stopRequested = stopRequested
        self.finalizationOutcome = finalizationOutcome
    }

    var phase: ExecutionPhase {
        switch lifecycle {
        case .starting:
            return .starting
        case .running:
            return .running
        case .paused:
            return .paused
        case .awaitingApproval:
            return .awaitingApproval
        case .verifying:
            return .verifying
        case .stopping:
            return .stopping
        case .finalizing(.verifying):
            return .verifying
        case .finalizing(.stopping):
            return .stopping
        }
    }

    var isFinalized: Bool {
        if case .finalizing = lifecycle {
            return true
        }
        return false
    }

    var pendingApprovalID: UUID? {
        guard case .awaitingApproval(let approval) = lifecycle else { return nil }
        return approval.id
    }

    var steps: [String] { stepEvidence.map(\.summary) }
    var verificationResults: [Bool] { verificationEvidence.map(\.verified) }
    var warnings: [String] { initialWarnings + verificationEvidence.compactMap(\.warning) }
    var progress: Double {
        guard !stepEvidence.isEmpty || totalSteps > 0 else { return lifecycle == .starting ? 0 : 1 }
        guard totalSteps > 0 else { return 0.99 }
        let index = stepEvidence.last?.index ?? 0
        return min(max(Double(index) / Double(totalSteps), 0), 0.99)
    }

    var currentTier: TrustTier? {
        if case .awaitingApproval(let approval) = lifecycle {
            return approval.tier
        }
        return stepEvidence.last?.tier
    }

}

enum ReportOutcome: Equatable {
    case completed
    case stopped
}

struct ReportState: Equatable {
    let taskID: UUID
    let summary: String
    let outcome: ReportOutcome

    init(taskID: UUID, summary: String, outcome: ReportOutcome = .completed) {
        self.taskID = taskID
        self.summary = summary
        self.outcome = outcome
    }
}

struct SessionFailure: Error, Equatable {
    let taskID: UUID?
    let goal: String?
    let message: String

    init(taskID: UUID? = nil, goal: String? = nil, message: String) {
        self.taskID = taskID
        self.goal = goal
        self.message = message
    }
}

enum SessionState: Equatable {
    case idle
    case invoking(InvocationState)
    case guiding(GuideSessionState)
    case asking(AskSessionState)
    case talking(TalkSessionState)
    case executing(ExecutionSessionState)
    case reporting(ReportState)
    case failed(SessionFailure)
}

enum DismissalDirective: Equatable {
    case dismiss
    case stopExecution
}

extension SessionState {
    var isTalkingSession: Bool {
        if case .talking = self { return true }
        return false
    }

    var isAskingSession: Bool {
        if case .asking = self { return true }
        return false
    }
}

struct IllegalSessionTransitionError: Error, Equatable {
    let state: SessionState
    let operation: String
}

@MainActor
final class SessionController: ObservableObject {
    @Published private(set) var state: SessionState = .idle
    var onTransitionRejected: (() -> Void)?

    @discardableResult
    func transition(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return true
        } catch {
            onTransitionRejected?()
            return false
        }
    }

#if DEBUG
    func debugSet(_ state: SessionState) {
        self.state = state
    }
#endif

    func wake(at date: Date = Date(), attemptID: UUID = UUID()) throws {
        guard case .idle = state else {
            throw IllegalSessionTransitionError(state: state, operation: "wake")
        }
        state = .invoking(InvocationState(id: attemptID, startedAt: date))
    }

    func retry(at date: Date = Date(), attemptID: UUID = UUID()) throws -> String {
        guard case .failed(let failure) = state,
              let goal = failure.goal,
              !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IllegalSessionTransitionError(state: state, operation: "retry")
        }
        state = .invoking(InvocationState(id: attemptID, startedAt: date))
        return goal
    }

    func cancelInvocation(_ attemptID: UUID) throws {
        guard case .invoking(let invocation) = state, invocation.id == attemptID else {
            throw IllegalSessionTransitionError(state: state, operation: "cancel invocation")
        }
        state = .idle
    }

    var currentOrFreshAttemptID: UUID {
        if case .invoking(let invocation) = state { return invocation.id }
        return UUID()
    }

    func isInvoking(_ attemptID: UUID) -> Bool {
        guard case .invoking(let invocation) = state else { return false }
        return invocation.id == attemptID
    }

    func beginInvokingIfNeeded(attemptID: UUID = UUID()) -> Bool {
        switch state {
        case .idle:
            return (try? wake(attemptID: attemptID)) != nil
        case .reporting, .failed:
            return (try? completeDismissal()) != nil && (try? wake(attemptID: attemptID)) != nil
        case .invoking(let invocation):
            return invocation.id == attemptID
        default:
            return false
        }
    }

    func startGuide(_ guide: GuideSessionState, attemptID: UUID) throws {
        guard case .invoking(let invocation) = state, invocation.id == attemptID else {
            throw IllegalSessionTransitionError(state: state, operation: "start guide")
        }
        state = .guiding(guide)
    }

    func startAsk(_ ask: AskSessionState, attemptID: UUID) throws {
        guard case .invoking(let invocation) = state, invocation.id == attemptID else {
            throw IllegalSessionTransitionError(state: state, operation: "start ask")
        }
        state = .asking(ask)
    }

    func updateAsk(_ update: (inout AskSessionState) -> Void) {
        guard case .asking(var ask) = state else { return }
        update(&ask)
        state = .asking(ask)
    }

    func startTalk(_ talk: TalkSessionState, attemptID: UUID) throws {
        guard case .invoking(let invocation) = state, invocation.id == attemptID else {
            throw IllegalSessionTransitionError(state: state, operation: "start talk")
        }
        state = .talking(talk)
    }

    func updateTalk(_ update: (inout TalkSessionState) -> Void) {
        guard case .talking(var talk) = state else { return }
        update(&talk)
        state = .talking(talk)
    }

    func startExecution(_ execution: ExecutionSessionState, attemptID: UUID) throws {
        guard case .invoking(let invocation) = state,
              invocation.id == attemptID,
              execution.lifecycle == .starting,
              execution.stepEvidence.isEmpty,
              execution.verificationEvidence.isEmpty,
              execution.totalSteps == 0 else {
            throw IllegalSessionTransitionError(state: state, operation: "start execution")
        }
        state = .executing(execution)
    }

    func setExecutionPhase(_ phase: ExecutionPhase) throws {
        guard case .executing(var execution) = state, !execution.isFinalized else {
            throw IllegalSessionTransitionError(state: state, operation: "set execution phase")
        }
        guard phase != .awaitingApproval else {
            throw IllegalSessionTransitionError(state: state, operation: "set execution phase to awaiting approval")
        }
        guard Self.canTransition(from: execution.phase, to: phase) else {
            throw IllegalSessionTransitionError(state: state, operation: "set execution phase to \(phase)")
        }
        switch phase {
        case .starting: execution.lifecycle = .starting
        case .running: execution.lifecycle = .running
        case .paused: execution.lifecycle = .paused
        case .verifying: execution.lifecycle = .verifying
        case .stopping: execution.lifecycle = .stopping
        case .awaitingApproval:
            throw IllegalSessionTransitionError(state: state, operation: "await approval without an ID")
        }
        state = .executing(execution)
    }

    func awaitApproval(
        _ approvalID: UUID,
        actionSummary: String = "",
        tier: TrustTier = .green
    ) throws {
        guard case .executing(var execution) = state,
              !execution.isFinalized,
              Self.canTransition(from: execution.phase, to: .awaitingApproval) else {
            throw IllegalSessionTransitionError(state: state, operation: "await approval")
        }
        execution.lifecycle = .awaitingApproval(
            ExecutionApproval(id: approvalID, actionSummary: actionSummary, tier: tier)
        )
        state = .executing(execution)
    }

    func approvalIsCurrent(_ approvalID: UUID) -> Bool {
        guard case .executing(let execution) = state else { return false }
        return execution.phase == .awaitingApproval && execution.pendingApprovalID == approvalID
    }

    func acceptApproval(_ approvalID: UUID) throws {
        guard case .executing(var execution) = state,
              case .awaitingApproval(let approval) = execution.lifecycle,
              approval.id == approvalID else {
            throw IllegalSessionTransitionError(state: state, operation: "accept stale approval")
        }
        execution.lifecycle = .running
        state = .executing(execution)
    }

    func replaceGuidePlan(steps: [(id: UUID, instruction: String, actionable: Bool)]) throws {
        guard case .guiding(var guide) = state else {
            throw IllegalSessionTransitionError(state: state, operation: "replace guide plan")
        }
        guide.plannedSteps = steps.map(\.instruction)
        state = .guiding(guide)
    }

    func recordGuideStep(id: UUID, instruction: String, actionable: Bool) throws {
        guard case .guiding(var guide) = state else {
            throw IllegalSessionTransitionError(state: state, operation: "record guide step")
        }
        if guide.presentedStepIDs.insert(id).inserted {
            guide.steps.append(instruction)
            if actionable {
                guide.actionableStepIDs.insert(id)
            }
        }
        state = .guiding(guide)
    }

    func setPlannedStepCount(_ count: Int) throws {
        guard count >= 0, case .executing(var execution) = state, !execution.isFinalized else {
            throw IllegalSessionTransitionError(state: state, operation: "set planned step count")
        }
        execution.totalSteps = count
        state = .executing(execution)
    }

    func recordExecutionStep(
        id: String,
        summary: String,
        tier: TrustTier = .green,
        reversible: Bool = true,
        index: Int = 0,
        startedAt: Date = Date()
    ) throws {
        guard case .executing(var execution) = state, execution.lifecycle == .running else {
            throw IllegalSessionTransitionError(state: state, operation: "record execution step")
        }
        guard index >= 0 else {
            throw IllegalSessionTransitionError(state: state, operation: "record execution step with negative index")
        }
        if let existing = execution.stepEvidence.first(where: { $0.id == id }) {
            guard existing.summary == summary else {
                throw IllegalSessionTransitionError(state: state, operation: "record conflicting execution step")
            }
            return
        }
        execution.stepEvidence.append(
            ExecutionStepEvidence(
                id: id,
                summary: summary,
                tier: tier,
                reversible: reversible,
                startedAt: startedAt,
                index: index
            )
        )
        state = .executing(execution)
    }

    func recordVerification(
        stepID: String,
        verified: Bool,
        warning: String? = nil,
        evidence: String? = nil
    ) throws {
        guard case .executing(var execution) = state, !execution.isFinalized else {
            throw IllegalSessionTransitionError(state: state, operation: "record verification")
        }
        let normalizedWarning = warning.flatMap { $0.isEmpty ? nil : $0 }
        let normalizedEvidence = evidence.flatMap { $0.isEmpty ? nil : $0 }
        let verification = ExecutionVerificationEvidence(
            stepID: stepID,
            verified: verified,
            warning: normalizedWarning,
            evidence: normalizedEvidence
        )
        if let existing = execution.verificationEvidence.first(where: { $0.stepID == stepID }) {
            guard existing == verification else {
                throw IllegalSessionTransitionError(state: state, operation: "record conflicting verification")
            }
            return
        }
        guard execution.stepEvidence.contains(where: { $0.id == stepID }) else {
            throw IllegalSessionTransitionError(state: state, operation: "record verification for unknown step")
        }
        execution.verificationEvidence.append(verification)
        state = .executing(execution)
    }

    func recordVerificationNote(stepID: String, note: String) throws {
        guard case .executing(var execution) = state, !execution.isFinalized else {
            throw IllegalSessionTransitionError(state: state, operation: "record verification note")
        }
        guard let index = execution.stepEvidence.firstIndex(where: { $0.id == stepID }) else {
            throw IllegalSessionTransitionError(state: state, operation: "record verification note for unknown step")
        }
        guard execution.stepEvidence[index].verificationNote == nil || execution.stepEvidence[index].verificationNote == note else {
            throw IllegalSessionTransitionError(state: state, operation: "record conflicting verification note")
        }
        execution.stepEvidence[index].verificationNote = note
        state = .executing(execution)
    }

    func beginFinalization(outcome reportedOutcome: DoOutcome) throws -> (execution: ExecutionSessionState, outcome: DoOutcome) {
        guard case .executing(var execution) = state,
              !execution.isFinalized else {
            throw IllegalSessionTransitionError(state: state, operation: "begin finalization")
        }
        let outcome: DoOutcome
        switch reportedOutcome {
        case .completed:
            switch execution.lifecycle {
            case .stopping where execution.stopRequested:
                outcome = .blocked(reason: "stop was requested while finishing; completed actions were not undone")
                execution.lifecycle = .finalizing(.stopping)
            case .running, .paused, .verifying:
                outcome = reportedOutcome
                execution.lifecycle = .finalizing(.verifying)
            case .stopping:
                outcome = .failed(stepSummary: "completion", reason: "completion arrived while execution was stopping")
                execution.lifecycle = .finalizing(.stopping)
            case .starting, .awaitingApproval, .finalizing:
                outcome = .failed(stepSummary: "completion", reason: "completion arrived before execution was allowed to finish")
                execution.lifecycle = .finalizing(.stopping)
            }
        case .blocked, .failed:
            outcome = reportedOutcome
            execution.lifecycle = .finalizing(.stopping)
        }
        state = .executing(execution)
        return (execution, outcome)
    }

    func commitFinalization(taskID: UUID, outcome reportedOutcome: DoOutcome) throws -> (execution: ExecutionSessionState, outcome: DoOutcome) {
        guard case .executing(var execution) = state,
              execution.taskID == taskID,
              execution.isFinalized,
              execution.finalizationOutcome == nil else {
            throw IllegalSessionTransitionError(state: state, operation: "commit finalization")
        }
        let outcome: DoOutcome
        if execution.stopRequested {
            outcome = .blocked(reason: "stop was requested while finishing; completed actions were not undone")
            execution.lifecycle = .finalizing(.stopping)
        } else {
            outcome = reportedOutcome
        }
        execution.finalizationOutcome = outcome
        state = .executing(execution)
        return (execution, outcome)
    }

    func report(summary: String, outcome: ReportOutcome = .completed) throws {
        guard case .executing(let execution) = state,
              execution.isFinalized,
              execution.phase == .verifying || execution.phase == .stopping else {
            throw IllegalSessionTransitionError(state: state, operation: "report")
        }
        let effectiveOutcome: ReportOutcome
        if let finalizationOutcome = execution.finalizationOutcome {
            switch finalizationOutcome {
            case .completed:
                effectiveOutcome = .completed
            case .blocked:
                effectiveOutcome = .stopped
            case .failed:
                throw IllegalSessionTransitionError(state: state, operation: "report failed finalization")
            }
        } else {
            effectiveOutcome = execution.stopRequested ? .stopped : outcome
        }
        state = .reporting(ReportState(taskID: execution.taskID, summary: summary, outcome: effectiveOutcome))
    }

    func finishGuide(summary: String, outcome: ReportOutcome = .stopped) throws {
        guard case .guiding(let guide) = state else {
            throw IllegalSessionTransitionError(state: state, operation: "finish guide")
        }
        state = .reporting(ReportState(taskID: guide.id, summary: summary, outcome: outcome))
    }

    func fail(_ failure: SessionFailure) throws {
        switch state {
        case .invoking, .guiding, .asking, .talking, .executing:
            state = .failed(failure)
        case .idle, .reporting, .failed:
            throw IllegalSessionTransitionError(state: state, operation: "fail")
        }
    }

    func requestDismissal() -> DismissalDirective {
        guard case .executing = state else {
            state = .idle
            return .dismiss
        }
        return requestStop()
    }

    func requestStop() -> DismissalDirective {
        guard case .executing(var execution) = state else {
            return .dismiss
        }
        guard execution.finalizationOutcome == nil else {
            return .dismiss
        }
        switch execution.lifecycle {
        case .finalizing(.verifying):
            execution.stopRequested = true
            execution.lifecycle = .finalizing(.stopping)
            state = .executing(execution)
        case .finalizing(.stopping):
            break
        default:
            execution.stopRequested = true
            execution.lifecycle = .stopping
            state = .executing(execution)
        }
        return .stopExecution
    }

    func completeDismissal() throws {
        switch state {
        case .reporting, .failed:
            state = .idle
        case .executing:
            throw IllegalSessionTransitionError(state: state, operation: "complete dismissal")
        case .idle, .invoking, .guiding, .asking, .talking:
            state = .idle
        }
    }

    private static func canTransition(from current: ExecutionPhase, to next: ExecutionPhase) -> Bool {
        switch (current, next) {
        case (.starting, .running),
             (.starting, .stopping),
             (.running, .paused),
             (.running, .awaitingApproval),
             (.running, .verifying),
             (.running, .stopping),
             (.paused, .running),
             (.paused, .awaitingApproval),
             (.paused, .stopping),
             (.awaitingApproval, .stopping),
             (.verifying, .running),
             (.verifying, .stopping):
            return true
        default:
            return current == next
        }
    }
}
