import AppKit
import PerryGuide
import PerryRuntimes

@MainActor
final class IntentCardPresenter {
    static let shared = IntentCardPresenter()

    private let presentation: NotchPresentation
    private var currentID: UUID?

    init(presentation: NotchPresentation = .shared) {
        self.presentation = presentation
    }

    var frame: CGRect? { currentID == nil ? nil : presentation.frame }

    func present(
        id: UUID = UUID(),
        card: IntentCard,
        alwaysAllowLabel: String? = nil,
        onAlwaysAllow: (() -> Void)? = nil
    ) async -> Bool {
        dismiss()
        currentID = id
        let frontmost = NSWorkspace.shared.frontmostApplication
        let previousApplication = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        let decision = await presentation.ask(id: id, priority: .approval, title: card.title, cancelled: false) { answer in
            IntentCardView(
                card: card,
                alwaysAllowLabel: alwaysAllowLabel,
                onAlwaysAllow: onAlwaysAllow,
                onAnswer: answer
            )
        }
        if currentID == id { currentID = nil }
        previousApplication?.activate(options: [.activateAllWindows])
        return decision
    }

    func dismiss() {
        guard let currentID else { return }
        presentation.cancelAsk(currentID)
        self.currentID = nil
    }

#if DEBUG
    func showFixture(_ card: IntentCard) {
        Task { _ = await present(card: card) }
    }
#endif
}

struct InteractiveConfirmer: Confirmer {
    weak var controller: AppController?

    static func question(_ summary: String) -> String {
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".?")))
        return text.prefix(1).uppercased() + text.dropFirst() + "?"
    }

    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool {
        guard let controller = await MainActor.run(body: { controller }) else { return false }
        let card = IntentCard(
            title: Self.question(request.actionSummary),
            detail: request.reason,
            tier: request.tier,
            targetSummary: request.targetSummary ?? request.actionSummary,
            requiredPhrase: request.requiredText,
            reversible: request.reversible
        )
        SoundPlayer.play(.receive)
        await MainActor.run { controller.subsystems.voice.speak(card.spokenLine) }
        return await controller.requestIntentApproval(id: request.id, card: card)
    }
}

extension AppController {
    func requestIntentApproval(id: UUID, card: IntentCard) async -> Bool {
        guard !Task.isCancelled, sessionController.approvalIsCurrent(id) else { return false }
        return await intentCards.present(id: id, card: card)
    }
}

extension AppController {
    func makeConfirmer() -> Confirmer {
        InteractiveConfirmer(controller: self)
    }
}
