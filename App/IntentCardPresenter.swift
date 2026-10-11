import AppKit
import PerryGuide
import PerryRuntimes

/// The one supervisor-path intent card on screen at a time. A card resolves
/// when the user answers, when its task is cancelled, or when the session
/// that asked for it is dismissed.
@MainActor
final class IntentCardPresenter {
    private var window: IntentCardWindow?

    var frame: CGRect? { window?.frame }

    func present(id: UUID, card: IntentCard, allowsStepThrough: Bool) async -> PlanDecision {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancel)
                    return
                }
                let window = IntentCardWindow(approvalID: id, card: card, allowsStepThrough: allowsStepThrough) { [weak self] decision in
                    if self?.window?.approvalID == id {
                        self?.window = nil
                    }
                    continuation.resume(returning: decision)
                }
                self.window = window
                window.show()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.window?.approvalID == id else { return }
                self?.window?.cancel()
            }
        }
    }

    func dismiss() {
        window?.cancel()
        window = nil
    }

#if DEBUG
    func showFixture(_ card: IntentCard) {
        window = IntentCardWindow(card: card) { _ in }
        window?.show()
    }
#endif
}

struct InteractiveConfirmer: Confirmer {
    weak var controller: AppController?

    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool {
        guard let controller = await MainActor.run(body: { controller }) else { return false }
        let card = IntentCard(
            title: "About to \(request.actionSummary)",
            detail: request.reason,
            tier: request.tier,
            targetSummary: request.targetSummary ?? request.actionSummary,
            requiredPhrase: request.requiredText,
            approveLabel: request.actionSummary,
            reversible: request.reversible
        )
        SoundPlayer.play(.receive)
        await MainActor.run { controller.voice.speak(card.spokenLine) }
        return await controller.requestIntentApproval(id: request.id, card: card)
    }

    func requestPlanDecision(_ request: ConfirmationRequest) async -> PlanDecision {
        guard let controller = await MainActor.run(body: { controller }) else { return .cancel }
        let card = IntentCard(
            title: "About to \(request.actionSummary)",
            detail: request.reason,
            tier: request.tier,
            targetSummary: request.targetSummary ?? request.actionSummary,
            requiredPhrase: request.requiredText,
            // The plan card approves the whole rehearsal — the button is the
            // action, not the goal.
            approveLabel: "Run",
            reversible: request.reversible
        )
        SoundPlayer.play(.receive)
        await MainActor.run { controller.voice.speak(card.spokenLine) }
        let decision = await controller.requestPlanDecision(id: request.id, card: card)
        if decision == .edit {
            await controller.presentPrompt(prefill: request.actionSummary, asTask: true)
        }
        return decision
    }
}
