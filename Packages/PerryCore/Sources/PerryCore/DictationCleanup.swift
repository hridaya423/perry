import Foundation

/// Guard for model-based dictation cleanup: punctuation and fillers may move,
/// words may not be invented. Rejects outputs that drift too far or add
/// punctuation that was never spoken ("—", "…").
public enum DictationCleanupGuard {
    public static func isAcceptable(raw: String, cleaned: String) -> Bool {
        if cleaned.contains("—") && !raw.contains("—") { return false }
        if cleaned.contains("…") && !raw.contains("…") { return false }
        let rawWords = tokens(raw).filter { !fillers.contains($0) }
        let cleanedWords = tokens(cleaned)
        let budget = max(2, Int(ceil(Double(rawWords.count) * 0.2)))
        return editDistance(rawWords, cleanedWords) <= budget
    }

    static let fillers: Set<String> = ["um", "uh", "erm", "ah", "like", "so", "basically", "actually"]

    /// Word tokens: alphanumerics plus in-word apostrophes ("they're" is one token).
    public static func tokens(_ text: String) -> [String] {
        var separators = CharacterSet.alphanumerics.inverted
        separators.remove(charactersIn: "'’")
        return text.lowercased()
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'’")) }
            .filter { !$0.isEmpty }
    }

    /// Same segmentation as `tokens` but preserving case.
    static func caseSensitiveTokens(_ text: String) -> [String] {
        var separators = CharacterSet.alphanumerics.inverted
        separators.remove(charactersIn: "'’")
        return text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'’")) }
            .filter { !$0.isEmpty }
    }

    /// Word-level Levenshtein.
    public static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

/// Learn-on-edit: when the user fixes a dictated word within `learnWindow`,
/// the substitution pair is learned for the dictionary.
public enum PersonalDictionaryLearner {
    public static let learnWindow: TimeInterval = 20

    public static func learn(
        inserted: String, observed: String, insertedAt: Date, observedAt: Date
    ) -> [String: String] {
        guard observedAt.timeIntervalSince(insertedAt) <= learnWindow,
              observedAt >= insertedAt else { return [:] }
        let insertedTokens = DictationCleanupGuard.tokens(inserted)
        let observedTokens = DictationCleanupGuard.tokens(observed)
        guard insertedTokens.count == observedTokens.count else { return [:] }
        let observedCased = DictationCleanupGuard.caseSensitiveTokens(observed)
        var learned: [String: String] = [:]
        for (index, (from, to)) in zip(insertedTokens, observedTokens).enumerated() where from != to {
            learned[from] = observedCased[index]
        }
        return learned
    }
}
