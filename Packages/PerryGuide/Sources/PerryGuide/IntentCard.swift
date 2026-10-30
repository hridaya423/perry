import Foundation
import PerryCore

/// The confirmation card Perry floats over the exact target before a risky action.
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
    public let requiredPhrase: String?
    public let approveLabel: String?
    public let reversible: Bool?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String? = nil,
        tier: TrustTier,
        targetSummary: String,
        requiredPhrase: String? = nil,
        approveLabel: String? = nil,
        reversible: Bool? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.tier = tier
        self.targetSummary = targetSummary
        self.requiredPhrase = requiredPhrase
        self.approveLabel = approveLabel
        self.reversible = reversible
        self.createdAt = createdAt
    }

    /// The phrase a red-tier answer must match: the exact displayed target, never a generic word.
    public var redPhrase: String {
        requiredPhrase ?? targetSummary
    }

    public var spokenLine: String {
        switch tier {
        case .orange:
            return "\(title) Approve or deny."
        case .red:
            return "\(title) Confirm on screen. I can’t take a voice yes for this."
        default:
            return title
        }
    }
}
