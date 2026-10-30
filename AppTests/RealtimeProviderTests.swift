import Foundation
import PerryCore
import XCTest
@testable import Perry

private actor CountingTransport: RealtimeVoiceTransport {
    private(set) var connects = 0

    func connect() async throws {
        connects += 1
        try await Task.sleep(for: .seconds(30))
    }
    func sendAudio(_ data: Data) async throws {}
    func finishInput(tag: RealtimeVoicePacketTag, request: RealtimeVoiceResponseRequest) async throws {}
    func commitInput(tag: RealtimeVoicePacketTag) async throws {}
    func cancelResponse() async throws {}
    func sendText(_ text: String, request: RealtimeVoiceResponseRequest) async throws {}
    func receive() async throws -> RealtimeVoiceTransportEvent {
        try await Task.sleep(for: .seconds(30))
        return .ignored
    }
    func close() async {}
}

@MainActor
final class RealtimeProviderTests: XCTestCase {
    private let preferenceKeys = [
        PerryPreferences.$realtimeVoiceProvider.key,
        PerryPreferences.$realtimeVoiceEndpoint.key,
        PerryPreferences.$realtimeVoiceModel.key,
        PerryPreferences.$realtimeVoiceVoice.key,
        PerryPreferences.$realtimeVoiceProtocol.key,
    ]
    private var savedPreferences: [Any?] = []

    override func setUp() async throws {
        savedPreferences = preferenceKeys.map { UserDefaults.standard.object(forKey: $0) }
        preferenceKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() async throws {
        for (key, value) in zip(preferenceKeys, savedPreferences) {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    private func grokConfiguration() throws -> RealtimeVoiceConfiguration {
        PerryPreferences.realtimeVoiceProvider = RealtimeProviderID.grok.rawValue
        return try XCTUnwrap(RealtimeProvider.current?.configuration())
    }

    func testGrokUsesItsOwnEndpointModelAndVoiceWhateverWasStoredForOpenAI() throws {
        PerryPreferences.realtimeVoiceEndpoint = "wss://api.openai.com/v1/realtime"
        PerryPreferences.realtimeVoiceModel = "gpt-realtime-2.1"
        PerryPreferences.realtimeVoiceVoice = "marin"
        let configuration = try grokConfiguration()
        XCTAssertEqual(configuration.endpoint.absoluteString, "wss://api.x.ai/v1/realtime")
        XCTAssertEqual(configuration.model, "grok-voice-latest")
        XCTAssertEqual(configuration.voice, "eve")
        XCTAssertEqual(configuration.protocolMode, .grok)
        XCTAssertEqual(configuration.transcriptionModel, "grok-transcribe")
        XCTAssertEqual(configuration.provider, .grok)
    }

    func testAnXAIEndpointFromBeforeProvidersIsReadAsGrok() {
        PerryPreferences.realtimeVoiceEndpoint = "wss://api.x.ai/v1/realtime"
        XCTAssertEqual(RealtimeProvider.current?.id, .grok)
        PerryPreferences.realtimeVoiceEndpoint = "wss://voice.example.com/realtime"
        XCTAssertEqual(RealtimeProvider.current?.id, .custom)
        PerryPreferences.realtimeVoiceEndpoint = nil
        XCTAssertNil(RealtimeProvider.current)
    }

    func testGrokNamesTheModelInTheURLAndSendsNoOpenAIHeader() throws {
        let request = OpenAICompatibleRealtimeVoiceTransport.request(for: try grokConfiguration(), apiKey: "xai-key")
        XCTAssertEqual(request.url?.absoluteString, "wss://api.x.ai/v1/realtime?model=grok-voice-latest")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer xai-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "OpenAI-Beta"))
    }

    func testGrokSessionPutsVoiceAndTurnsAtTheTopAndCommitsOnlyWhenPerrySays() async throws {
        let transport = OpenAICompatibleRealtimeVoiceTransport(configuration: try grokConfiguration(), apiKey: "key")
        let payload = await transport.sessionUpdatePayload()
        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let session = try XCTUnwrap(decoded["session"] as? [String: Any])
        XCTAssertEqual(session["voice"] as? String, "eve")
        XCTAssertTrue(session["turn_detection"] is NSNull)
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24_000)
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "grok-transcribe")
    }

    func testGrokEventFixturesMapToTransportEvents() async throws {
        let transport = OpenAICompatibleRealtimeVoiceTransport(configuration: try grokConfiguration(), apiKey: "key")
        let request = RealtimeVoiceResponseRequest(tag: RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: 1))
        await transport.prepareResponseFixture(request)
        let fixtures: [(String, RealtimeVoiceTransportEvent)] = [
            (#"{"type":"session.updated","session":{}}"#, .sessionReady),
            (#"{"type":"conversation.item.input_audio_transcription.updated","item_id":"i1","transcript":"open the"}"#,
             .transcriptDelta("open the", correlation: .uncorrelated(itemID: "i1"))),
            (#"{"type":"conversation.item.input_audio_transcription.updated","item_id":"i1","transcript":"open the notes"}"#,
             .transcriptDelta("open the notes", correlation: .uncorrelated(itemID: "i1"))),
            (#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"i1","transcript":"Open the notes."}"#,
             .transcriptFinal("Open the notes.", correlation: .uncorrelated(itemID: "i1"))),
            (#"{"type":"response.created","response":{"id":"r1","status":"in_progress"}}"#,
             .responseStarted("r1", metadata: request.metadata)),
            (#"{"type":"response.created","response":{"id":"r2"}}"#, .responseStarted("r2", metadata: nil)),
            (#"{"type":"response.output_audio.delta","response_id":"r1","delta":"AQI="}"#, .audio(Data([1, 2]), responseID: "r1")),
            (#"{"type":"response.output_audio_transcript.delta","response_id":"r1","delta":"Opening"}"#,
             .assistantTranscriptDelta("Opening", responseID: "r1")),
            (#"{"type":"response.done","response":{"id":"r1"}}"#, .responseFinished("r1")),
        ]
        for (json, expected) in fixtures {
            let event = try await transport.decodeEvent(Data(json.utf8))
            XCTAssertEqual(event, expected, json)
        }
    }

    func testAKeyFromBeforeProvidersMovesToTheProviderItWasFor() throws {
        let keychain = KeychainStore(service: "dev.perry.keys.tests.\(UUID().uuidString)")
        defer {
            try? keychain.deleteChecked(account: RealtimeProvider.legacyKeychainAccount)
            for id in RealtimeProviderID.allCases { try? keychain.deleteChecked(account: RealtimeProvider(id).keychainAccount) }
        }
        try keychain.save("sk-openai", account: RealtimeProvider.legacyKeychainAccount)
        PerryPreferences.realtimeVoiceProvider = RealtimeProviderID.grok.rawValue
        XCTAssertNil(try RealtimeProvider(.grok).apiKey(keychain: keychain))

        PerryPreferences.realtimeVoiceProvider = nil
        PerryPreferences.realtimeVoiceEndpoint = "wss://api.openai.com/v1/realtime"
        let provider = try XCTUnwrap(RealtimeProvider.current)
        XCTAssertEqual(try provider.apiKey(keychain: keychain), "sk-openai")
        XCTAssertEqual(try keychain.readChecked(account: "realtime.voice.openAI"), "sk-openai")
        XCTAssertNil(try keychain.readChecked(account: RealtimeProvider.legacyKeychainAccount))
        XCTAssertEqual(PerryPreferences.realtimeVoiceProvider, "openAI")
    }

    func testPerMinuteProvidersNeverConnectAtLaunch() async throws {
        let grok = CountingTransport()
        let grokVoice = RealtimeTalkVoice(configuration: try grokConfiguration(), apiKey: "key", makeTransport: { grok })
        grokVoice.warmUp()
        let openAITransport = CountingTransport()
        let openAI = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://api.openai.com/v1/realtime")!, model: "gpt-realtime-2.1", provider: .openAI
        )
        let openAIVoice = RealtimeTalkVoice(configuration: openAI, apiKey: "key", makeTransport: { openAITransport })
        openAIVoice.warmUp()
        try await Task.sleep(for: .milliseconds(200))
        defer { grokVoice.session.stop(); openAIVoice.session.stop() }
        let grokConnects = await grok.connects
        let openAIConnects = await openAITransport.connects
        XCTAssertEqual(grokConnects, 0)
        XCTAssertEqual(openAIConnects, 1)
    }

    func testPerMinuteSessionsHangUpWhenIdleAndTheNextTurnRedials() async throws {
        let transport = CountingTransport()
        let voice = RealtimeTalkVoice(
            configuration: try grokConfiguration(), apiKey: "key", makeTransport: { transport }, connectBudget: 0.05
        )
        voice.session.meteredIdleTimeout = .milliseconds(100)
        let first = voice.session
        _ = await voice.ensureListening()
        XCTAssertFalse(first.isShutDown)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(first.isShutDown)
        _ = await voice.ensureListening()
        XCTAssertFalse(voice.session === first)
        let connects = await transport.connects
        XCTAssertEqual(connects, 2)

        let tokenTransport = CountingTransport()
        let tokenSession = RealtimeVoiceSession(
            configuration: RealtimeVoiceConfiguration(
                endpoint: URL(string: "wss://api.openai.com/v1/realtime")!, model: "gpt-realtime-2.1", provider: .openAI
            ),
            apiKey: "key",
            transport: tokenTransport,
            onEvent: { _ in }
        )
        tokenSession.meteredIdleTimeout = .milliseconds(100)
        tokenSession.start()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(tokenSession.isShutDown)
        tokenSession.stop()
    }
}
