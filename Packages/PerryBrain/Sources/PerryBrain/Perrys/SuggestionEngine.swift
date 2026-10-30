import Foundation

public struct SuggestionCard: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var title: String
    public var body: String
    public var sourcePerryID: UUID?
    public var sourceServiceID: String?
    public var sourceServiceName: String?
    public var score: Double

    public init(id: UUID = UUID(), title: String, body: String,
                sourcePerryID: UUID? = nil, score: Double) {
        self.id = id
        self.title = title
        self.body = body
        self.sourcePerryID = sourcePerryID
        self.score = score
    }
}

public enum SuggestionRules {
    public static let maxCards = 3
    public static let backoffStep = 0.15
    public static let scoreCeiling = 0.9

    public static func rank(
        _ cards: [SuggestionCard], minScore: Double = 0.3, limit: Int = maxCards
    ) -> [SuggestionCard] {
        cards
            .filter { $0.score >= minScore }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    public static func effectiveMinScore(base: Double, ignoredDays: Int) -> Double {
        min(base + backoffStep * Double(max(0, ignoredDays)), scoreCeiling)
    }
}
