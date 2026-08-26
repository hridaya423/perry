import Foundation

/// PRD §4 Invocation: wake word off by default; nothing happens without the
/// hotkey or an explicit opt-in wake word. This gate encodes that policy so
/// no code path can listen without the user having turned it on.
public struct WakeWordGate: Sendable {
    public static let defaultPhrase = "hey perry"

    public let enabled: Bool
    public let phrase: String

    public init(enabled: Bool = false, phrase: String = WakeWordGate.defaultPhrase) {
        self.enabled = enabled
        self.phrase = Self.normalized(phrase)
    }

    /// Matches the leading portion of a transcript against the phrase
    /// ("Hey Perry, rename the files"). Returns the remainder as command text.
    public func match(inTranscript transcript: String) -> String? {
        guard enabled else { return nil }
        let normalized = Self.normalized(transcript)
        guard normalized.hasPrefix(phrase) else { return nil }
        let remainder = normalized.dropFirst(phrase.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? nil : remainder
    }

    public static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
