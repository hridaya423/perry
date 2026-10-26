import XCTest
@testable import PerryBrain

final class SetupAdvisorTests: XCTestCase {
    func testMachineTable() {
        let rows: [(String, SetupFacts, SetupRecommendation.Brain, SetupRecommendation.Voice, SetupRecommendation.Hearing, Bool)] = [
            ("recommended: 16 GB, signed in, no keys",
             SetupFacts(memoryGB: 16, macOSMajor: 27, cloudBrainReady: true), .cloud, .installKokoro, .speechAnalyzer, true),
            ("best quality without a key asks for ElevenLabs",
             SetupFacts(memoryGB: 16, macOSMajor: 27, cloudBrainReady: true, priority: .quality), .cloud, .getKey(.elevenLabs), .speechAnalyzer, false),
            ("best quality with a key, no redaction",
             SetupFacts(memoryGB: 16, macOSMajor: 27, voiceKeys: [.cartesia], cloudBrainReady: true, priority: .quality), .cloud, .cloud(.cartesia), .speechAnalyzer, false),
            ("recommended uses an existing voice key, ElevenLabs first",
             SetupFacts(memoryGB: 16, macOSMajor: 27, voiceKeys: [.openAI, .elevenLabs], cloudBrainReady: true), .cloud, .cloud(.elevenLabs), .speechAnalyzer, true),
            ("private user keeps the voice local even with a key",
             SetupFacts(memoryGB: 16, macOSMajor: 27, voiceKeys: [.elevenLabs], cloudBrainReady: true, priority: .privacy), .cloud, .installKokoro, .speechAnalyzer, true),
            ("8 GB gets the guided Apple voice",
             SetupFacts(memoryGB: 8, macOSMajor: 15, speechAnalyzerSupportsLocale: true), .cloud, .guidedPremium, .onDevice, true),
            ("installed premium voice is used",
             SetupFacts(memoryGB: 8, macOSMajor: 26, premiumSystemVoice: "Ava (Premium)"), .cloud, .system("Ava (Premium)"), .speechAnalyzer, true),
            ("installed Kokoro beats a premium Apple voice",
             SetupFacts(memoryGB: 32, macOSMajor: 26, premiumSystemVoice: "Ava (Premium)", kokoroInstalled: true), .cloud, .kokoro, .speechAnalyzer, true),
            ("capable local brain for a private user",
             SetupFacts(memoryGB: 64, macOSMajor: 27, cloudBrainReady: true, localBrainCapable: true, priority: .privacy), .local, .installKokoro, .speechAnalyzer, false),
            ("capable local brain, not signed in",
             SetupFacts(memoryGB: 64, macOSMajor: 27, localBrainCapable: true), .local, .installKokoro, .speechAnalyzer, false),
            ("unsupported locale falls back to on-device recognizer",
             SetupFacts(memoryGB: 16, macOSMajor: 27, speechAnalyzerSupportsLocale: false), .cloud, .installKokoro, .onDevice, true),
        ]
        for (name, facts, brain, voice, hearing, hides) in rows {
            let pick = SetupAdvisor.recommend(facts)
            XCTAssertEqual(pick.brain, brain, name)
            XCTAssertEqual(pick.voice, voice, name)
            XCTAssertEqual(pick.hearing, hearing, name)
            XCTAssertEqual(pick.hidesPersonalDetails, hides, name)
        }
    }

    func testPrivateUserWithSmallMacGetsAPlainNote() {
        let pick = SetupAdvisor.recommend(SetupFacts(memoryGB: 16, macOSMajor: 27, priority: .privacy))
        XCTAssertEqual(pick.brain, .cloud)
        XCTAssertNotNil(pick.brainNote)
    }
}
