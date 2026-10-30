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

    private static func languageCode(for identifier: String) -> String? {
        Locale(identifier: identifier).language.languageCode?.identifier.lowercased()
    }
}
