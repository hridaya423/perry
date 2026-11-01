import PerryBrain
import XCTest
@testable import Perry

@MainActor
final class RealtimeCancelRoughEdgeTests: XCTestCase {
    func testCancelStopsInputWithoutRestartingTheAudioTap() async throws {
        let configuration = RealtimeVoiceConfiguration(endpoint: URL(string: "wss://example.invalid")!, model: "test")
        let transport = ResponseStreamFixture(configuration: configuration, frames: [], acceptsAudio: true)
        let voice = RealtimeTalkVoice(
            configuration: configuration,
            apiKey: "fixture",
            makeTransport: { transport },
            connectBudget: 2,
            finalizeBudget: 2
        )
        defer { voice.session.stop() }
        voice.session.beginEmptyInputFixture()
        voice.session.audioStartOverrideForTesting = {}
        try await voice.input.start()
        let ingress = RealtimeVoiceAudioIngress(capacity: 4)
        voice.session.installAudioIngressFixtureForTesting(ingress)

        voice.session.audioStartOverrideForTesting = { XCTFail("Cancel restarted the audio tap") }
        voice.input.cancel()
        ingress.yield(RealtimeVoiceAudioPacket(data: Data([1, 0]), sessionID: 1, utteranceGeneration: 2))
        let leaked = await transport.waitUntilAudioCount(1, timeout: .milliseconds(200))

        XCTAssertFalse(leaked)
        XCTAssertFalse(voice.input.isUsingRealtime)
        XCTAssertFalse(voice.session.hasPendingInputAudio)
    }
}
