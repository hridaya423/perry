import Foundation

public enum TierClassifier {
    static let deepSignals: Set<String> = [
        "why", "how", "explain", "compare", "step", "write", "draft",
        "warum", "wie", "erklaer", "vergleich",
        "pourquoi", "comment", "expliqu", "compar",
        "por que", "porque", "como", "explic", "compar",
        "なぜ", "どうやって", "説明", "比較",
    ]

    public static func tier(question: String, bindingCount: Int, elementCount: Int) -> ModelTier {
        if question.count > 160 || bindingCount > 2 || elementCount > 400 {
            return .deep
        }
        let lowered = question.lowercased()
        let words = lowered.split(whereSeparator: { !$0.isLetter }).map(String.init)
        if words.contains(where: { word in deepSignals.contains(where: { word.hasPrefix($0) }) }) {
            return .deep
        }
        return .fast
    }
}
