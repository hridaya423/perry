import Foundation
import PerryCore

/// The inline intent card from PRD §4 Confirmation UX: Perry highlights the
/// exact target and floats a card ("About to move 34 files to Trash ·
/// Approve / Stop") answerable by click or hotkey.
public struct IntentCard: Codable, Equatable, Sendable, Identifiable {
    public enum Choice: String, Codable, Sendable {
        case approve
        case stop
    }

    public let id: UUID
    public let title: String
    public let detail: String?
    public let tier: TrustTier
    public let targetSummary: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String? = nil,
        tier: TrustTier,
        targetSummary: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.tier = tier
        self.targetSummary = targetSummary
        self.createdAt = createdAt
    }

    /// Spoken line that accompanies the card (PRD: a spoken line accompanies
    /// it; voice-only confirmation never suffices for red).
    public var spokenLine: String {
        switch tier {
        case .orange:
            return "\(title). Approve or stop."
        case .red:
            return "This one needs real attention. \(title). Confirm on screen; I won't take a voice yes for this."
        default:
            return title
        }
    }
}

/// Routes intent-card answers with the PRD's rules enforced: orange accepts
/// click or hotkey; red additionally requires an explicit typed-style confirm
/// flag (the UI binds this to a text field, never speech).
public struct IntentCardPolicy: Sendable {
    public init() {}

    public func resolve(
        _ card: IntentCard,
        choice: IntentCard.Choice?,
        typedConfirmation: String?,
        sourceIsVoice: Bool
    ) -> Bool {
        guard choice == .approve else { return false }
        if card.tier >= .red {
            guard !sourceIsVoice else { return false }
            guard let typed = typedConfirmation?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !typed.isEmpty else { return false }
        }
        return true
    }
}
