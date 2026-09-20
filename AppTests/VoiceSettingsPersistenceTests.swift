import XCTest
import PerryCore
@testable import Perry

@MainActor
final class VoiceSettingsPersistenceTests: XCTestCase {
    func testSpeechSettingsRoundTripAndClearVoiceSelection() throws {
        let suiteName = "VoiceSettingsPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        VoiceController.saveSpeechPreferences(
            SpeechPreferences(
                outputEnabled: false,
                rateMultiplier: 1.25,
                voiceIdentifier: "voice.fixture"
            ),
            defaults: defaults
        )
        XCTAssertEqual(
            VoiceController.currentSpeechPreferences(defaults: defaults),
            SpeechPreferences(
                outputEnabled: false,
                rateMultiplier: 1.25,
                voiceIdentifier: "voice.fixture"
            )
        )

        VoiceController.saveSpeechPreferences(
            SpeechPreferences(outputEnabled: true, rateMultiplier: 0.75),
            defaults: defaults
        )
        XCTAssertEqual(
            VoiceController.currentSpeechPreferences(defaults: defaults),
            SpeechPreferences(outputEnabled: true, rateMultiplier: 0.75)
        )
        XCTAssertNil(defaults.object(forKey: VoiceController.speechVoiceKey))
    }

    func testSpeechSettingsUseProductDefaultsWhenUnset() throws {
        let suiteName = "VoiceSettingsPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            VoiceController.currentSpeechPreferences(defaults: defaults),
            .default
        )
    }
}
