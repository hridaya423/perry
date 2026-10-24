import AVFoundation
@testable import Perry
import XCTest

@MainActor
final class RecommendedVoicesTests: XCTestCase {
    func testRecommendationsAreNaturalVoicesInTheRequestedLanguageBestQualityFirst() {
        let voices = VoiceController.recommendedSpeechVoices(languageCode: "en", limit: 50)
        XCTAssertFalse(voices.isEmpty)
        for voice in voices {
            XCTAssertTrue(voice.language.hasPrefix("en"), voice.identifier)
            XCTAssertFalse(voice.identifier.contains("speech.synthesis"), voice.identifier)
            XCTAssertFalse(voice.identifier.contains("eloquence"), voice.identifier)
        }
        XCTAssertEqual(voices.map(\.quality.rawValue), voices.map(\.quality.rawValue).sorted(by: >))
        XCTAssertEqual(Set(voices.map(\.name)).count, voices.count)
    }
}
