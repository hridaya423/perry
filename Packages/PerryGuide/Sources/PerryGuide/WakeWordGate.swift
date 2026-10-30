import Foundation

public struct WakeWordGate: Sendable {
    public static let defaultPhrase = "hey perry"

    public let enabled: Bool
    public let phrase: String

    public init(enabled: Bool = false, phrase: String = WakeWordGate.defaultPhrase) {
        self.enabled = enabled
        self.phrase = Self.normalized(phrase)
    }

    public func match(inTranscript transcript: String) -> String? {
        guard enabled else { return nil }
        let normalized = Self.normalized(transcript)
        guard normalized == phrase || normalized.hasPrefix(phrase + " ") else { return nil }
        return normalized.dropFirst(phrase.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
