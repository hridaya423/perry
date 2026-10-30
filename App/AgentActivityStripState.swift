import Combine
import Foundation
import PerryCore

enum AgentActivityPhase: Equatable {
    case idle
    case starting
    case working
    case paused
    case confirming
    case verifying
    case reporting
    case failed
}

struct AgentActivityStep: Equatable, Identifiable {
    let id: String
    let summary: String
    let tier: TrustTier
    let reversible: Bool
    let timestamp: Date
    var verification: String?
}

@MainActor
final class AgentActivityStripState: ObservableObject {
    @Published var phase: AgentActivityPhase = .idle
    @Published var title = "Perry is ready"
    @Published var detail = ""
    @Published var progress: Double?
    @Published var tier: TrustTier?
    @Published var verification: String?
    @Published var steps: [AgentActivityStep] = []
    @Published var startedAt: Date?
    @Published var isExpanded = false
    @Published var canRetry = false
    @Published var handedToHuman = false

    var steeringIsAvailable: Bool {
        phase == .working || phase == .paused
    }

    var takeOverIsAvailable: Bool {
        phase == .working
    }

    var stopIsAvailable: Bool {
        phase != .idle && phase != .reporting && phase != .failed
    }

    var retryIsAvailable: Bool {
        phase == .failed && canRetry
    }

    func apply(sessionState: SessionState) {
        let expanded = isExpanded
        reset()
        isExpanded = expanded
        switch sessionState {
        case .idle:
            return
        case .invoking:
            phase = .starting
            title = "Starting"
            detail = "Getting ready"
        case .guiding:
            phase = .working
            title = "Guiding you"
            detail = "Waiting for the next step"
        case .asking(let ask):
            phase = .working
            title = "Answering a question"
            detail = ask.question
        case .talking(let talk):
            phase = .working
            title = talk.isListening ? "Listening" : "Answering"
            detail = talk.transcript.isEmpty ? "Point and speak" : talk.transcript
        case .executing(let execution):
            startedAt = execution.startedAt
            progress = execution.progress
            tier = execution.currentTier
            steps = execution.stepEvidence.map { evidence in
                let verification = execution.verificationEvidence.first(where: { $0.stepID == evidence.id })
                return AgentActivityStep(
                    id: evidence.id,
                    summary: evidence.summary,
                    tier: evidence.tier,
                    reversible: evidence.reversible,
                    timestamp: evidence.startedAt,
                    verification: Self.verificationLabel(for: verification) ?? evidence.verificationNote
                )
            }
            if let verification = execution.verificationEvidence.last {
                self.verification = Self.verificationLabel(for: verification)
            }
            if let finalizationOutcome = execution.finalizationOutcome {
                switch finalizationOutcome {
                case .completed:
                    phase = .reporting
                    title = "Done"
                    detail = "Saving to History"
                case .blocked:
                    phase = .reporting
                    title = "Stopped"
                    detail = "Saving to History"
                case .failed:
                    phase = .failed
                    title = "Failed"
                    detail = "Saving to History"
                }
            } else {
                switch execution.lifecycle {
                case .starting:
                    phase = .starting
                    title = "Starting"
                    detail = "You have 5 seconds to stop"
                case .running:
                    phase = .working
                    title = "Working"
                    if let step = execution.stepEvidence.last {
                        title = "Step \(step.index + 1) of \(max(execution.totalSteps, step.index + 1))"
                        detail = step.summary
                    } else {
                        detail = "Starting the first step"
                    }
                case .paused:
                    phase = .paused
                    title = "Paused"
                    detail = "Resume or stop when ready"
                case .awaitingApproval(let approval):
                    phase = .confirming
                    title = "Needs your OK"
                    detail = approval.actionSummary
                case .verifying:
                    phase = .verifying
                    title = "Done"
                    detail = "Checking the result"
                case .stopping:
                    phase = .reporting
                    title = "Stopped"
                    detail = "Stopping…"
                case .finalizing(.verifying):
                    phase = .verifying
                    title = "Done"
                    detail = "Checking the result"
                case .finalizing(.stopping):
                    phase = .reporting
                    title = "Stopped"
                    detail = "Stopping…"
                }
            }
        case .reporting(let report):
            phase = .reporting
            title = report.outcome == .completed ? "Done" : "Stopped"
            detail = report.summary
        case .failed(let failure):
            phase = .failed
            title = "Failed"
            detail = failure.message
            canRetry = failure.goal != nil
        }
    }

    func reset() {
        phase = .idle
        title = "Perry is ready"
        detail = ""
        progress = nil
        tier = nil
        verification = nil
        steps = []
        startedAt = nil
        isExpanded = false
        canRetry = false
        handedToHuman = false
    }

    private static func verificationLabel(for evidence: ExecutionVerificationEvidence?) -> String? {
        guard let evidence else { return nil }
        if evidence.verified {
            return evidence.evidence.map { "Checked: \($0)" } ?? "Checked"
        }
        return evidence.warning.map { "Needs checking: \($0)" } ?? "Needs checking"
    }
}
