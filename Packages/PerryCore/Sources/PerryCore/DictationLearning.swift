import Foundation

public enum DictationWords {
    public static func tokens(_ text: String) -> [String] {
        var separators = CharacterSet.alphanumerics.inverted
        separators.remove(charactersIn: "'’")
        return text.lowercased()
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'’")) }
            .filter { !$0.isEmpty }
    }

    static func caseSensitiveTokens(_ text: String) -> [String] {
        var separators = CharacterSet.alphanumerics.inverted
        separators.remove(charactersIn: "'’")
        return text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'’")) }
            .filter { !$0.isEmpty }
    }
}

public enum PersonalDictionaryLearner {
    public static let learnWindow: TimeInterval = 20

    public static func learn(
        inserted: String, observed: String, insertedAt: Date, observedAt: Date
    ) -> [String: String] {
        guard observedAt.timeIntervalSince(insertedAt) <= learnWindow,
              observedAt >= insertedAt else { return [:] }
        let insertedTokens = DictationWords.tokens(inserted)
        let observedTokens = DictationWords.tokens(observed)
        guard insertedTokens.count == observedTokens.count else { return [:] }
        let observedCased = DictationWords.caseSensitiveTokens(observed)
        var learned: [String: String] = [:]
        for (index, (from, to)) in zip(insertedTokens, observedTokens).enumerated() where from != to {
            learned[from] = observedCased[index]
        }
        return learned
    }
}
