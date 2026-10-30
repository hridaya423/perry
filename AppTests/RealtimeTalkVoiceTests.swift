import PerryBrain
import XCTest
@testable import Perry

@MainActor
final class RealtimeTalkVoiceTests: XCTestCase {
    private let endpoint = URL(string: "wss://example.invalid")!

    private func makeVoice(
        transport: ResponseStreamFixture,
        connectBudget: TimeInterval = 2
    ) -> RealtimeTalkVoice {
        RealtimeTalkVoice(
            configuration: RealtimeVoiceConfiguration(endpoint: endpoint, model: "test"),
            apiKey: "fixture",
            makeTransport: { transport },
            fallbackInput: RecordingTalkInput(),
            fallbackOutput: RecordingTalkOutput(),
            connectBudget: connectBudget,
            finalizeBudget: 2
        )
    }

    func testTranscribeOnlyCommitPublishesTranscriptWithoutResponse() async throws {
        let firstCommitGate = SendGate()
        let configuration = RealtimeVoiceConfiguration(endpoint: endpoint, model: "test")
        let transport = ResponseStreamFixture(
            configuration: configuration,
            frames: [
                #"{"type":"input_audio_buffer.committed","item_id":"item_a"}"#,
                #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_a","transcript":"click save"}"#,
            ],
            acceptsFinishInput: true,
            acceptsAudio: true,
            receiveGates: [0: firstCommitGate]
        )
        var events: [RealtimeVoiceEvent] = []
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onEvent: { events.append($0) }
        )
        defer { session.stop() }

        session.beginEmptyInputFixture()
        let ingress = RealtimeVoiceAudioIngress(capacity: 1)
        session.installAudioIngressFixtureForTesting(ingress)
        ingress.yield(RealtimeVoiceAudioPacket(data: Data([1, 0]), sessionID: 1, utteranceGeneration: 1))
        let audioLanded = await transport.waitUntilAudioCount(1, timeout: .seconds(1))
        XCTAssertTrue(audioLanded)

        let receiverTask = Task { await session.receiveCurrentFixtureEvents() }
        session.finishInputTranscribing()
        let commitLanded = await transport.waitUntilOperationCount(1)
        XCTAssertTrue(commitLanded)
        await firstCommitGate.open()
        await receiverTask.value

        let operations = await transport.operationLog()
        let tag = RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: 1)
        XCTAssertEqual(operations, [.commitInput(tag)])
        XCTAssertEqual(events, [.transcriptFinal("click save")])
        XCTAssertEqual(session.state, .listening)
    }

    func testRealtimeInputFinalizesTranscriptFromCommittedAudio() async throws {
        let commitGate = SendGate()
        let transport = ResponseStreamFixture(
            configuration: RealtimeVoiceConfiguration(endpoint: endpoint, model: "test"),
            frames: [
                #"{"type":"input_audio_buffer.committed","item_id":"item_b"}"#,
                #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_b","transcript":"click the save button"}"#,
            ],
            acceptsFinishInput: true,
            acceptsAudio: true,
            receiveGates: [0: commitGate]
        )
        let voice = makeVoice(transport: transport)
        defer { voice.session.stop() }
        voice.session.beginEmptyInputFixture()
        voice.session.audioStartOverrideForTesting = {}

        try await voice.input.start()
        XCTAssertTrue(voice.input.isUsingRealtime)

        let ingress = RealtimeVoiceAudioIngress(capacity: 1)
        voice.session.installAudioIngressFixtureForTesting(ingress)
        ingress.yield(RealtimeVoiceAudioPacket(data: Data([1, 0]), sessionID: 1, utteranceGeneration: 2))
        let audioLanded = await transport.waitUntilAudioCount(1, timeout: .seconds(1))
        XCTAssertTrue(audioLanded)

        let receiverTask = Task { await voice.session.receiveCurrentFixtureEvents() }
        let finalizeTask = Task { @MainActor in await voice.input.finalize() }
        let commitLanded = await transport.waitUntilOperationCount(1)
        XCTAssertTrue(commitLanded)
        await commitGate.open()
        await receiverTask.value
        let result = await finalizeTask.value

        XCTAssertEqual(result.transcript, "click the save button")
        XCTAssertEqual(result.words.map(\.text), ["click", "the", "save", "button"])
        let last = try XCTUnwrap(result.words.last)
        XCTAssertGreaterThan(last.start, 0)
        let operations = await transport.operationLog()
        XCTAssertTrue(operations.contains(.commitInput(RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: 2))))
    }

    func testRealtimeOutputSendsTextWhenRealtimeIsActive() async throws {
        let transport = ResponseStreamFixture(
            configuration: RealtimeVoiceConfiguration(endpoint: endpoint, model: "test"),
            frames: [],
            acceptsText: true
        )
        let voice = makeVoice(transport: transport)
        defer { voice.session.stop() }
        voice.session.beginEmptyInputFixture()
        voice.session.audioStartOverrideForTesting = {}

        try await voice.input.start()
        voice.output.speak("Done.")
        let requestLanded = await transport.waitUntilRequestCount(1)
        XCTAssertTrue(requestLanded)
        let operations = await transport.operationLog()
        XCTAssertTrue(operations.contains(.sendText("Done.")))
    }

    func testInputFallsBackWhenSessionCannotListen() async throws {
        let gate = SendGate()
        let blocked = ConnectionFixture(gate: gate)
        let fallback = RecordingTalkInput()
        let voice = RealtimeTalkVoice(
            configuration: RealtimeVoiceConfiguration(endpoint: endpoint, model: "test"),
            apiKey: "fixture",
            makeTransport: { blocked },
            fallbackInput: fallback,
            connectBudget: 0.2,
            finalizeBudget: 0.5
        )
        defer { voice.session.stop() }

        try await voice.input.start()
        let starts = fallback.startCount()
        XCTAssertEqual(starts, 1)
        XCTAssertFalse(voice.input.isUsingRealtime)
        await gate.open()
    }

    func testSilentHoldSettlesEmptyWithoutCommitting() async throws {
        let transport = ResponseStreamFixture(
            configuration: RealtimeVoiceConfiguration(endpoint: endpoint, model: "test"),
            frames: [],
            acceptsAudio: true
        )
        let voice = makeVoice(transport: transport)
        defer { voice.session.stop() }
        voice.session.beginEmptyInputFixture()
        voice.session.audioStartOverrideForTesting = {}

        try await voice.input.start()
        let result = await voice.input.finalize()
        XCTAssertEqual(result.transcript, "")
        XCTAssertTrue(result.words.isEmpty)
        let operations = await transport.operationLog()
        XCTAssertTrue(operations.isEmpty)
        XCTAssertEqual(voice.session.state, .listening)
    }
}

@MainActor
private final class RecordingTalkInput: TalkSpeechInput {
    private(set) var starts = 0
    func start() async throws { starts += 1 }
    func startCount() -> Int { starts }
    func finalize() async -> (transcript: String, words: [SpokenWord]) { ("fallback", []) }
    func cancel() {}
}

@MainActor
private final class RecordingTalkOutput: TalkSpeechOutput {
    var isSpeaking: Bool { false }
    func speak(_ sentence: String) {}
    func shutUp() {}
}
