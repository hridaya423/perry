import AVFoundation
@testable import Perry
import XCTest

@MainActor
final class RecommendedVoicesTests: XCTestCase {
    func testOnlyPremiumAndEnhancedNonSiriVoicesCount() {
        XCTAssertTrue(VoiceController.isNatural(identifier: "com.apple.voice.premium.en-US.Ava", quality: .premium))
        XCTAssertTrue(VoiceController.isNatural(identifier: "com.apple.voice.enhanced.en-GB.Serena", quality: .enhanced))
        XCTAssertFalse(VoiceController.isNatural(identifier: "com.apple.siri.natural.Simone", quality: .enhanced))
        XCTAssertFalse(VoiceController.isNatural(identifier: "com.apple.voice.compact.en-US.Samantha", quality: .default))
        XCTAssertFalse(VoiceController.isNatural(identifier: "com.apple.eloquence.en-US.Grandpa", quality: .enhanced))
        XCTAssertFalse(VoiceController.isNatural(identifier: "com.apple.speech.synthesis.voice.Bubbles", quality: .enhanced))
    }

    func testRecommendationsAreNaturalVoicesBestQualityFirst() {
        let voices = VoiceController.recommendedSpeechVoices(languageCode: "en", limit: 50)
        for voice in voices {
            XCTAssertTrue(VoiceController.isNaturalVoice(voice), voice.identifier)
            XCTAssertTrue(voice.language.hasPrefix("en"), voice.identifier)
        }
        XCTAssertEqual(voices.map(\.quality.rawValue), voices.map(\.quality.rawValue).sorted(by: >))
        XCTAssertEqual(Set(voices.map(\.name)).count, voices.count)
    }

    func testTheSystemEngineAlwaysHasAVoice() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("system", forKey: PerryPreferences.$speechEngine.key)
        switch VoiceController.speechRoute(engine: .system, defaults: defaults) {
        case .system(let voice): XCTAssertEqual(VoiceController.isNaturalVoice(voice), !VoiceController.naturalVoices().isEmpty)
        case .silent: XCTFail("Perry speaks with the system voice when no natural voice is installed")
        case .neural: XCTFail("system engine never routes to a neural voice")
        }
    }
}
