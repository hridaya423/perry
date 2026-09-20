import Foundation
import NaturalLanguage

enum SpeechLanguageDetector {
    static func localeIdentifier(for transcript: String, supportedIdentifiers: [String]) -> String? {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(normalized)
        guard let language = recognizer.dominantLanguage else { return nil }

        guard let detectedCode = languageCode(for: language.rawValue) else { return nil }
        return supportedIdentifiers.first { languageCode(for: $0) == detectedCode }
    }

    static func rerouteTarget(
        for transcript: String,
        activeIdentifier: String,
        supportedIdentifiers: [String],
        rerouteAlreadyAttempted: Bool
    ) -> String? {
        guard !rerouteAlreadyAttempted,
              let detectedIdentifier = localeIdentifier(
                  for: transcript,
                  supportedIdentifiers: supportedIdentifiers
              ),
              let activeCode = languageCode(for: activeIdentifier),
              let detectedCode = languageCode(for: detectedIdentifier),
              activeCode != detectedCode else { return nil }
        return detectedIdentifier
    }

    private static func languageCode(for identifier: String) -> String? {
        Locale(identifier: identifier).language.languageCode?.identifier.lowercased()
    }
}
