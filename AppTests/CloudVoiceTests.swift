@testable import Perry
import PerryBrain
import XCTest

final class CloudVoiceTests: XCTestCase {
    func testKeyShapesMapToProviders() {
        XCTAssertEqual(VoiceService.provider(forKey: "sk_" + String(repeating: "a1", count: 24)), .elevenLabs)
        XCTAssertEqual(VoiceService.provider(forKey: "sk_car_" + String(repeating: "Ab3", count: 8)), .cartesia)
        XCTAssertEqual(VoiceService.provider(forKey: "sk-proj-" + String(repeating: "xY9_", count: 10)), .openAI)
        XCTAssertNil(VoiceService.provider(forKey: "hello there"))
        XCTAssertNil(VoiceService.provider(forKey: "sk_short"))
    }

    func testRequestsAskForRawPCMAt24kHz() throws {
        let eleven = VoiceService.elevenLabs.speechRequest(text: "Hi.", voiceID: "v1", key: "k", previous: "Before.", speed: 1)
        XCTAssertEqual(eleven.url?.absoluteString, "https://api.elevenlabs.io/v1/text-to-speech/v1/stream?output_format=pcm_24000")
        XCTAssertEqual(eleven.value(forHTTPHeaderField: "xi-api-key"), "k")
        let elevenBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(eleven.httpBody)) as? [String: Any])
        XCTAssertEqual(elevenBody["model_id"] as? String, "eleven_flash_v2_5")
        XCTAssertEqual(elevenBody["previous_text"] as? String, "Before.")

        let openAI = VoiceService.openAI.speechRequest(text: "Hi.", voiceID: "marin", key: "k", previous: nil, speed: 1)
        let openAIBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(openAI.httpBody)) as? [String: Any])
        XCTAssertEqual(openAIBody["response_format"] as? String, "pcm")
        XCTAssertEqual(openAI.value(forHTTPHeaderField: "Authorization"), "Bearer k")

        let cartesia = VoiceService.cartesia.speechRequest(text: "Hi.", voiceID: "c1", key: "k", previous: nil, speed: 1)
        let cartesiaBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(cartesia.httpBody)) as? [String: Any])
        let format = try XCTUnwrap(cartesiaBody["output_format"] as? [String: Any])
        XCTAssertEqual(format["encoding"] as? String, "pcm_s16le")
        XCTAssertEqual(format["sample_rate"] as? Int, 24_000)
        XCTAssertNotNil(cartesia.value(forHTTPHeaderField: "Cartesia-Version"))
    }

    func testStreamYieldsAudioAndReportsRejectedKeys() async throws {
        let session = StubSpeechProtocol.session()
        StubSpeechProtocol.status = 200
        StubSpeechProtocol.body = Data(repeating: 7, count: 10_000)
        var received = Data()
        for try await chunk in CloudVoice(provider: .openAI, voiceID: "marin", key: "k", session: session).audio(for: "Hi.", previous: nil) {
            received.append(chunk)
        }
        XCTAssertEqual(received, StubSpeechProtocol.body)

        StubSpeechProtocol.status = 401
        StubSpeechProtocol.body = Data("{}".utf8)
        do {
            for try await _ in CloudVoice(provider: .elevenLabs, voiceID: "v", key: "bad", session: session).audio(for: "Hi.", previous: nil) {}
            XCTFail("a rejected key must throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "ElevenLabs did not accept the voice key.")
        }
    }

    func testElevenLabsVoicesParseAndPreferWarmPremades() {
        let json = Data(#"{"voices":[{"voice_id":"a","name":"Adam","labels":{"accent":"american"}},{"voice_id":"s","name":"Sarah - warm"}]}"#.utf8)
        let voices = VoiceService.elevenLabs.parseVoices(json)
        XCTAssertEqual(voices.map(\.id), ["a", "s"])
        XCTAssertEqual(voices.first?.detail, "american")
        XCTAssertEqual(VoiceService.elevenLabs.preferredVoice(in: voices)?.id, "s")
    }
}

final class StubSpeechProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubSpeechProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct ToneVoice: NeuralVoice {
    var spellsNumbers: Bool { false }
    func audio(for text: String, previous: String?) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Data(repeating: 0, count: 24_000 * 2 / 5))
            continuation.finish()
        }
    }
}

@MainActor
final class NeuralSpeechPlayerTests: XCTestCase {
    func testQueuedSentencesPlayThenReportIdle() async throws {
        let player = NeuralSpeechPlayer()
        let idle = expectation(description: "idle")
        player.onIdle = { idle.fulfill() }
        player.onError = { XCTFail($0) }
        player.enqueue("One.", voice: ToneVoice())
        player.enqueue("Two.", voice: ToneVoice())
        XCTAssertTrue(player.isSpeaking)
        await fulfillment(of: [idle], timeout: 5)
        XCTAssertFalse(player.isSpeaking)
    }

    func testStopSilencesWithoutIdleCallback() async throws {
        let player = NeuralSpeechPlayer()
        player.onIdle = { XCTFail("stop must not report a finished reply") }
        player.enqueue("One.", voice: ToneVoice())
        player.stop()
        XCTAssertFalse(player.isSpeaking)
        try await Task.sleep(for: .seconds(1))
    }
}
