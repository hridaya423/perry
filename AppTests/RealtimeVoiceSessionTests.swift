import Foundation
import PerryCore
import XCTest
@testable import Perry

let responseRequestTokenPlaceholder = "__PERRY_RESPONSE_REQUEST_TOKEN__"
let firstResponseRequestTokenPlaceholder = "__PERRY_FIRST_RESPONSE_REQUEST_TOKEN__"

enum FixtureTransportError: Error, LocalizedError, Equatable, Sendable {
    case textSend
    case responseCancellation
    case audioSend

    var errorDescription: String? {
        switch self {
        case .textSend:
            return "Fixture text send failed."
        case .responseCancellation:
            return "Fixture response cancellation failed."
        case .audioSend:
            return "Fixture audio send failed."
        }
    }
}

@MainActor
final class RealtimeVoiceSessionTests: XCTestCase {
    func testOpenAIConnectionsUseTheCurrentInterfaceUnlessBetaIsChosen() {
        let openAI = URL(string: "wss://api.openai.com/v1/realtime")!
        let automatic = OpenAICompatibleRealtimeVoiceTransport.request(
            for: RealtimeVoiceConfiguration(endpoint: openAI, model: "gpt-realtime-2.1"), apiKey: "key"
        )
        XCTAssertNil(automatic.value(forHTTPHeaderField: "OpenAI-Beta"))
        XCTAssertEqual(automatic.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        let beta = OpenAICompatibleRealtimeVoiceTransport.request(
            for: RealtimeVoiceConfiguration(endpoint: openAI, model: "gpt-realtime-2.1", protocolMode: .openAIBeta), apiKey: "key"
        )
        XCTAssertEqual(beta.value(forHTTPHeaderField: "OpenAI-Beta"), "realtime=v1")
    }

    func testTranscriptionModelComesFromTheConfiguration() async {
        let transport = OpenAICompatibleRealtimeVoiceTransport(
            configuration: RealtimeVoiceConfiguration(
                endpoint: URL(string: "wss://api.openai.com/v1/realtime")!, model: "gpt-realtime-2.1", transcriptionModel: "gpt-transcribe"
            ),
            apiKey: "key"
        )
        let payload = await transport.sessionUpdatePayload()
        let session = payload["session"] as? [String: Any]
        let audio = session?["audio"] as? [String: Any]
        let input = audio?["input"] as? [String: Any]
        let transcription = input?["transcription"] as? [String: Any]
        XCTAssertEqual(transcription?["model"] as? String, "gpt-transcribe")
        XCTAssertTrue(input?["turn_detection"] is NSNull)
    }

    func testOpenAIDefaultsToTheSupportedRealtimeModel() {
        let defaults = UserDefaults.standard
        let keys = [PerryPreferences.$realtimeVoiceEndpoint.key, PerryPreferences.$realtimeVoiceModel.key]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set("wss://api.openai.com/v1/realtime", forKey: keys[0])
        for stored in ["", "gpt-realtime"] {
            defaults.set(stored, forKey: keys[1])
            XCTAssertEqual(VoiceController.currentRealtimeVoiceConfiguration()?.model, "gpt-realtime-2.1", "stored \"\(stored)\"")
        }
        defaults.set("gpt-realtime-2.1-mini", forKey: keys[1])
        XCTAssertEqual(VoiceController.currentRealtimeVoiceConfiguration()?.model, "gpt-realtime-2.1-mini")
    }

    func testProviderJSONKeepsLateTranscriptsBoundToTheirOriginalUtterance() async throws {
        let transport = OpenAICompatibleRealtimeVoiceTransport(
            configuration: RealtimeVoiceConfiguration(endpoint: URL(string: "wss://example.invalid")!, model: "test"),
            apiKey: "fixture"
        )
        let oldTag = RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: 1)
        let newTag = RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: 2)
        try await transport.prepareCommitFixture(tag: oldTag)
        try await transport.prepareCommitFixture(tag: newTag)
        for json in [
            #"{"type":"input_audio_buffer.committed","item_id":"old"}"#,
            #"{"type":"input_audio_buffer.committed","item_id":"old"}"#,
            #"{"type":"input_audio_buffer.committed","item_id":"new"}"#,
        ] {
            let event = try await transport.decodeEvent(Data(json.utf8))
            XCTAssertEqual(event, .ignored)
        }
        let oldFinal = try await transport.decodeEvent(Data(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"old","transcript":"old command"}"#.utf8
        ))
        let newDelta = try await transport.decodeEvent(Data(
            #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"new","delta":"new"}"#.utf8
        ))
        let newFinal = try await transport.decodeEvent(Data(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"new","transcript":"new command"}"#.utf8
        ))

        XCTAssertEqual(oldFinal, .transcriptFinal("old command", correlation: .matched(oldTag)))
        XCTAssertEqual(newDelta, .transcriptDelta("new", correlation: .matched(newTag)))
        XCTAssertEqual(newFinal, .transcriptFinal("new command", correlation: .matched(newTag)))
        let barrier = RealtimeVoiceCommitBarrier()
        barrier.advance(to: newTag)
        for event in [oldFinal, newFinal, newFinal] {
            guard case .transcriptFinal(let text, .matched(let tag)) = event else {
                XCTFail("Expected correlated final")
                continue
            }
            let result = barrier.offerTranscript(text, source: .realtime, tag: tag)
            if case .committed = result { XCTFail("Dispatched before local input commit") }
        }
        let commit = try XCTUnwrap(barrier.markInputCommitted(newTag))
        XCTAssertEqual(commit.text, "new command")
        XCTAssertEqual(barrier.dispatch(commit), .dispatched)
        XCTAssertNil(barrier.markInputCommitted(newTag))
    }

    func testProviderJSONCannotAssignMissingOrUnknownItemIDsToPendingInput() async throws {
        let transport = OpenAICompatibleRealtimeVoiceTransport(
            configuration: RealtimeVoiceConfiguration(endpoint: URL(string: "wss://example.invalid")!, model: "test"),
            apiKey: "fixture"
        )
        try await transport.prepareCommitFixture(tag: RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: 1))
        let missingID = try await transport.decodeEvent(Data(
            #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"unidentified"}"#.utf8
        ))
        let unknownID = try await transport.decodeEvent(Data(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"unknown","transcript":"unidentified"}"#.utf8
        ))
        XCTAssertEqual(missingID, .transcriptFinal("unidentified", correlation: .uncorrelated(itemID: nil)))
        XCTAssertEqual(unknownID, .transcriptFinal("unidentified", correlation: .uncorrelated(itemID: "unknown")))
        for json in ["{", "[]", "null"] {
            do {
                _ = try await transport.decodeEvent(Data(json.utf8))
                XCTFail("Malformed provider JSON was accepted")
            } catch {}
        }
    }

    func testReceiverRetainsFinalTranscriptAfterAudioEndsAndRejectsStaleText() async {
        let secondResponseGate = SendGate()
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(configuration: configuration, frames: [
            responseCreatedFrame(responseID: "first"),
            #"{"type":"response.output_audio.done","response_id":"first"}"#,
            #"{"type":"response.output_audio_transcript.done","response_id":"first","transcript":"First answer"}"#,
            #"{"type":"response.done","response":{"id":"first","status":"completed"}}"#,
            responseCreatedFrame(responseID: "second"),
            #"{"type":"response.output_audio_transcript.delta","response_id":"first","delta":"Stale delta"}"#,
            #"{"type":"response.output_audio_transcript.done","response_id":"first","transcript":"Stale final"}"#,
            #"{"type":"response.output_audio_transcript.delta","delta":"Missing identity"}"#,
            #"{"type":"response.output_audio_transcript.delta","response_id":"second","delta":"Second"}"#,
            #"{"type":"response.output_audio_transcript.done","response_id":"second","transcript":"Second answer"}"#,
            #"{"type":"response.done","response":{"id":"second","status":"completed"}}"#,
        ],
            acceptsText: true,
            receiveGates: [4: secondResponseGate]
        )
        var events: [RealtimeVoiceEvent] = []
        let session = RealtimeVoiceSession(
            configuration: configuration, apiKey: "fixture", transport: transport,
            onEvent: { events.append($0) }
        )

        defer { session.stop() }

        let firstRequestReady = await beginFixtureTextRequest(
            session: session,
            transport: transport,
            text: "first request"
        )
        XCTAssertTrue(firstRequestReady)
        guard firstRequestReady else { return }

        let receiverTask = Task {
            await session.receiveCurrentFixtureEvents()
        }
        let secondResponseBlocked = await secondResponseGate.waitUntilBlocked()
        XCTAssertTrue(secondResponseBlocked)
        guard secondResponseBlocked else {
            await receiverTask.value
            return
        }
        session.speakText("second request")
        let secondRequestReady = await transport.waitUntilRequestCount(2)
        XCTAssertTrue(secondRequestReady)
        await secondResponseGate.open()
        await receiverTask.value

        XCTAssertEqual(events, [
            .responseStarted("first"),
            .assistantTranscriptFinal("First answer", responseID: "first"),
            .responseFinished("first"),
            .responseStarted("second"),
            .assistantTranscriptDelta("Second", responseID: "second"),
            .assistantTranscriptFinal("Second answer", responseID: "second"),
            .responseFinished("second"),
        ])
        XCTAssertEqual(session.state, .listening)
    }

    func testActualReceiverDropsLateAssistantTranscriptAfterCancellation() async {
        let gate = SendGate()
        let cancelGate = SendGate()
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(configuration: configuration, frames: [
            responseCreatedFrame(responseID: "first"),
            #"{"type":"response.output_audio_transcript.done","response_id":"first","transcript":"Late answer"}"#,
            #"{"type":"response.done","response":{"id":"first","status":"completed"}}"#,
        ],
            receiveGate: gate,
            cancelResponseGate: cancelGate,
            acceptsText: true
        )
        var events: [RealtimeVoiceEvent] = []
        let session = RealtimeVoiceSession(
            configuration: configuration, apiKey: "fixture", transport: transport,
            onEvent: { events.append($0) }
        )
        defer { session.stop() }

        let firstRequestReady = await beginFixtureTextRequest(session: session, transport: transport, text: "first request")
        XCTAssertTrue(firstRequestReady)
        guard firstRequestReady else { return }
        let receiverTask = Task { await session.receiveCurrentFixtureEvents() }
        let receiverBlocked = await gate.waitUntilBlocked()
        XCTAssertTrue(receiverBlocked)
        session.cancelCurrentResponse()
        let cancelSent = await cancelGate.waitUntilOpen()
        XCTAssertTrue(cancelSent)
        await gate.open()
        await receiverTask.value

        XCTAssertEqual(events, [
            .responseStarted("first"),
            .responseInterrupted(nil),
        ])
        let operations = await transport.operationLog()
        XCTAssertEqual(operations, [.sendText("first request"), .cancelResponse])
        XCTAssertEqual(session.state, .listening)
    }

    func testBeginInputWithoutAudioGraphReportsAudioStartFailure() async {
        let cancelGate = SendGate()
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(
            configuration: configuration,
            frames: [
                responseCreatedFrame(responseID: "first"),
            ],
            cancelResponseGate: cancelGate,
            acceptsText: true
        )
        var events: [RealtimeVoiceEvent] = []
        var audioStartCalls = 0
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onEvent: { events.append($0) }
        )
        session.audioStartOverrideForTesting = {
            audioStartCalls += 1
            throw RealtimeVoiceError.audioUnavailable
        }
        defer { session.stop() }

        let firstRequestReady = await beginFixtureTextRequest(session: session, transport: transport, text: "first request")
        XCTAssertTrue(firstRequestReady)
        guard firstRequestReady else { return }
        await session.receiveCurrentFixtureEvents()
        XCTAssertEqual(events, [.responseStarted("first")])

        session.beginInput()
        let cancelSent = await cancelGate.waitUntilOpen()

        XCTAssertTrue(cancelSent)
        XCTAssertEqual(audioStartCalls, 1)
        XCTAssertEqual(session.state, .failed(RealtimeVoiceError.audioUnavailable.localizedDescription))
        XCTAssertEqual(events, [
            .responseStarted("first"),
            .responseInterrupted(nil),
            .error(RealtimeVoiceError.audioUnavailable.localizedDescription),
        ])
    }

    func testBeginInputCancelsPendingTextResponseBeforeProviderStartsIt() async {
        let cancelGate = SendGate()
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(
            configuration: configuration,
            frames: [],
            cancelResponseGate: cancelGate,
            acceptsText: true
        )
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onEvent: { _ in }
        )
        session.audioStartOverrideForTesting = {}
        defer { session.stop() }

        let requestSent = await beginFixtureTextRequest(
            session: session, transport: transport, text: "pending answer"
        )
        XCTAssertTrue(requestSent)
        guard requestSent else { return }
        XCTAssertEqual(session.state, .listening)

        session.beginInput()

        let canceled = await cancelGate.waitUntilOpen()
        XCTAssertTrue(canceled)
        let operations = await transport.operationLog()
        XCTAssertEqual(operations, [.sendText("pending answer"), .cancelResponse])
        XCTAssertEqual(session.state, .listening)
    }

    func testFailedTextSendTerminatesSessionAndClearsPendingState() async {
        let ingressFinished = expectation(description: "audio ingress worker finished")
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(
            configuration: configuration,
            frames: [responseCreatedFrame(responseID: "failed-text")],
            acceptsText: true,
            sendTextError: .textSend
        )
        let failed = expectation(description: "text send failure reported")
        var events: [RealtimeVoiceEvent] = []
        var sawIngressWorker = false
        var ingressWorkerFinished = false
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onTaskSnapshot: { snapshot in
                let role = RealtimeWorkerRole.audioIngress.rawValue
                if snapshot.startedByRole[role, default: 0] > 0 {
                    sawIngressWorker = true
                }
                if sawIngressWorker,
                   snapshot.activeByRole[role] == nil,
                   !ingressWorkerFinished {
                    ingressWorkerFinished = true
                    ingressFinished.fulfill()
                }
            },
            onEvent: {
                events.append($0)
                if case .error = $0 { failed.fulfill() }
            }
        )
        defer { session.stop() }

        session.beginEmptyInputFixture()
        let ingress = RealtimeVoiceAudioIngress(capacity: 1)
        session.installAudioIngressFixtureForTesting(ingress)
        session.submitTranscript("partial", source: .realtime)
        session.speakText("failed text")

        let requestSent = await transport.waitUntilRequestCount(1)
        XCTAssertTrue(requestSent)
        await fulfillment(of: [failed], timeout: 1)
        await fulfillment(of: [ingressFinished], timeout: 1)
        let closeStarted = await transport.waitUntilCloseCount(1)
        XCTAssertTrue(closeStarted)
        let closeCount = await transport.closeCallCount()
        XCTAssertEqual(closeCount, 1)

        session.submitTranscript("late", source: .realtime)
        await session.receiveCurrentFixtureEvents()

        XCTAssertEqual(session.state, .failed(FixtureTransportError.textSend.localizedDescription))
        XCTAssertEqual(events, [.error(FixtureTransportError.textSend.localizedDescription)])
        let operations = await transport.operationLog()
        XCTAssertEqual(operations, [.sendText("failed text")])
    }

    func testPipelineFailureAndCallbackStopCloseTransportOnce() async {
        let closeGate = SendGate()
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(
            configuration: configuration,
            frames: [],
            acceptsText: true,
            sendTextError: .textSend,
            closeGate: closeGate
        )
        let failed = expectation(description: "text send failure reported")
        var session: RealtimeVoiceSession?
        session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onEvent: { event in
                if case .error = event {
                    session?.stop()
                    failed.fulfill()
                }
            }
        )
        defer {
            session?.stop()
            session = nil
            Task { await closeGate.open() }
        }

        session?.beginEmptyInputFixture()
        session?.speakText("failed text")

        let requestSent = await transport.waitUntilRequestCount(1)
        XCTAssertTrue(requestSent)
        await fulfillment(of: [failed], timeout: 1)
        let closeStarted = await transport.waitUntilCloseCount(1)
        XCTAssertTrue(closeStarted)
        let closeCount = await transport.closeCallCount()
        XCTAssertEqual(closeCount, 1)

        await closeGate.open()
        await Task.yield()
        let finalCloseCount = await transport.closeCallCount()
        XCTAssertEqual(finalCloseCount, 1)
    }

    func testStoppedPipelineFailureDoesNotReportLateErrorOrCloseAgain() async {
        let sendErrorGate = SendGate()
        let closeGate = SendGate()
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(
            configuration: configuration,
            frames: [],
            acceptsText: true,
            sendTextError: .textSend,
            sendTextErrorGate: sendErrorGate,
            closeGate: closeGate
        )
        let lateError = expectation(description: "stopped session reports no late error")
        lateError.isInverted = true
        var events: [RealtimeVoiceEvent] = []
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onEvent: { event in
                events.append(event)
                if case .error = event {
                    lateError.fulfill()
                }
            }
        )
        defer {
            session.stop()
            Task {
                await sendErrorGate.open()
                await closeGate.open()
            }
        }

        session.beginEmptyInputFixture()
        session.speakText("delayed failure")
        let requestSent = await transport.waitUntilRequestCount(1)
        XCTAssertTrue(requestSent)
        let sendBlocked = await sendErrorGate.waitUntilBlocked()
        XCTAssertTrue(sendBlocked)
        guard sendBlocked else {
            await sendErrorGate.open()
            return
        }

        session.stop()
        let closeStarted = await transport.waitUntilCloseCount(1)
        XCTAssertTrue(closeStarted)
        await sendErrorGate.open()
        let failedSend = await transport.waitUntilFailedTextSendCount(1)
        XCTAssertTrue(failedSend)
        let lateResult = await XCTWaiter.fulfillment(of: [lateError], timeout: 0.1)
        XCTAssertEqual(lateResult, .completed)
        XCTAssertTrue(events.isEmpty)

        await closeGate.open()
        await Task.yield()
        let closeCount = await transport.closeCallCount()
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(session.state, .idle)
    }

    func testFailedResponseCancellationTerminatesSessionAndRejectsLateResponse() async {
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(
            configuration: configuration,
            frames: [responseCreatedFrame(responseID: "late-cancel")],
            acceptsText: true,
            cancelResponseError: .responseCancellation
        )
        let failed = expectation(description: "response cancellation failure reported")
        var events: [RealtimeVoiceEvent] = []
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onEvent: {
                events.append($0)
                if case .error = $0 { failed.fulfill() }
            }
        )
        defer { session.stop() }

        let requestSent = await beginFixtureTextRequest(
            session: session,
            transport: transport,
            text: "cancel me"
        )
        XCTAssertTrue(requestSent)
        guard requestSent else { return }

        session.cancelCurrentResponse()
        await fulfillment(of: [failed], timeout: 1)
        let closeStarted = await transport.waitUntilCloseCount(1)
        XCTAssertTrue(closeStarted)
        let closeCount = await transport.closeCallCount()
        XCTAssertEqual(closeCount, 1)
        await session.receiveCurrentFixtureEvents()

        XCTAssertEqual(session.state, .failed(FixtureTransportError.responseCancellation.localizedDescription))
        XCTAssertEqual(events, [
            .responseInterrupted(nil),
            .error(FixtureTransportError.responseCancellation.localizedDescription),
        ])
        let operations = await transport.operationLog()
        XCTAssertEqual(operations, [.sendText("cancel me"), .cancelResponse])
    }

    func testFailedAudioSendStopsIngressAndFailsTranscriptBarrier() async {
        let ingressFinished = expectation(description: "audio ingress worker finished")
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(
            configuration: configuration,
            frames: [],
            acceptsAudio: true,
            audioError: .audioSend
        )
        let failed = expectation(description: "audio send failure reported")
        var events: [RealtimeVoiceEvent] = []
        var sawIngressWorker = false
        var ingressWorkerFinished = false
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onTaskSnapshot: { snapshot in
                let role = RealtimeWorkerRole.audioIngress.rawValue
                if snapshot.startedByRole[role, default: 0] > 0 {
                    sawIngressWorker = true
                }
                if sawIngressWorker,
                   snapshot.activeByRole[role] == nil,
                   !ingressWorkerFinished {
                    ingressWorkerFinished = true
                    ingressFinished.fulfill()
                }
            },
            onEvent: {
                events.append($0)
                if case .error = $0 { failed.fulfill() }
            }
        )
        defer { session.stop() }

        session.beginEmptyInputFixture()
        let ingress = RealtimeVoiceAudioIngress(capacity: 2)
        session.installAudioIngressFixtureForTesting(ingress)
        session.submitTranscript("partial", source: .realtime)
        ingress.yield(RealtimeVoiceAudioPacket(
            data: Data([1, 0]),
            sessionID: 1,
            utteranceGeneration: 1
        ))

        let audioSent = await transport.waitUntilAudioCount(1, timeout: .seconds(1))
        XCTAssertTrue(audioSent)
        await fulfillment(of: [failed], timeout: 1)
        await fulfillment(of: [ingressFinished], timeout: 1)
        let closeStarted = await transport.waitUntilCloseCount(1)
        XCTAssertTrue(closeStarted)
        let closeCount = await transport.closeCallCount()
        XCTAssertEqual(closeCount, 1)
        ingress.yield(RealtimeVoiceAudioPacket(
            data: Data([2, 0]),
            sessionID: 1,
            utteranceGeneration: 1
        ))
        await Task.yield()
        session.submitTranscript("late", source: .realtime)

        XCTAssertEqual(session.state, .failed(FixtureTransportError.audioSend.localizedDescription))
        XCTAssertEqual(events, [.error(FixtureTransportError.audioSend.localizedDescription)])
        let audioPayloads = await transport.audioPayloads()
        XCTAssertEqual(audioPayloads, [Data([1, 0])])
    }

    func testSpeakTextWhileListeningWithoutAudioGraphSendsText() async {
        let textGate = SendGate()
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(
            configuration: configuration,
            frames: [],
            sendTextGate: textGate,
            acceptsText: true
        )
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onEvent: { _ in }
        )
        defer { session.stop() }

        session.beginEmptyInputFixture()
        session.speakText("read this")
        let textSent = await textGate.waitUntilOpen()

        XCTAssertTrue(textSent)
        let operations = await transport.operationLog()
        XCTAssertEqual(operations, [.sendText("read this")])
        let requests = await transport.responseRequestLog()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].tag, RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: 1))
        XCTAssertFalse(requests[0].nonce.isEmpty)
        XCTAssertEqual(requests[0].metadata[RealtimeVoiceResponseRequest.metadataKey], requests[0].nonce)
        XCTAssertEqual(session.state, .listening)
    }

    func testBeginInputPreservesCancellationQueuedBehindAudio() async {
        let audioGate = SendGate()
        let cancelGate = SendGate()
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(
            configuration: configuration,
            frames: [],
            cancelResponseGate: cancelGate,
            acceptsText: true,
            audioGate: audioGate,
            acceptsAudio: true
        )
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onEvent: { _ in }
        )
        session.audioStartOverrideForTesting = {}
        defer {
            session.stop()
            Task { await audioGate.open() }
        }
        let requestSent = await beginFixtureTextRequest(
            session: session, transport: transport, text: "pending"
        )
        XCTAssertTrue(requestSent)
        guard requestSent else { return }
        let ingress = RealtimeVoiceAudioIngress(capacity: 2)
        session.installAudioIngressFixtureForTesting(ingress)
        ingress.yield(RealtimeVoiceAudioPacket(
            data: Data([0, 0]), sessionID: 1, utteranceGeneration: 1
        ))
        let audioBlocked = await audioGate.waitUntilBlocked()
        XCTAssertTrue(audioBlocked)
        guard audioBlocked else { return }

        session.cancelCurrentResponse()
        session.beginInput()
        await audioGate.open()

        let canceled = await cancelGate.waitUntilOpen()
        XCTAssertTrue(canceled)
        let operations = await transport.operationLog()
        XCTAssertEqual(operations, [.sendText("pending"), .cancelResponse])
        XCTAssertEqual(session.state, .listening)
    }

    func testEachPendingTextReplacementCancelsItsPredecessor() async {
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(
            configuration: configuration,
            frames: [],
            cancelResponseGate: SendGate(),
            acceptsText: true
        )
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onEvent: { _ in }
        )
        defer { session.stop() }

        let firstSent = await beginFixtureTextRequest(
            session: session, transport: transport, text: "first"
        )
        XCTAssertTrue(firstSent)
        guard firstSent else { return }
        session.speakText("second")
        let secondSent = await transport.waitUntilRequestCount(2)
        XCTAssertTrue(secondSent)
        guard secondSent else { return }
        session.speakText("third")
        let thirdSent = await transport.waitUntilRequestCount(3)
        XCTAssertTrue(thirdSent)

        let operations = await transport.operationLog()
        XCTAssertEqual(operations, [
            .sendText("first"), .cancelResponse,
            .sendText("second"), .cancelResponse,
            .sendText("third"),
        ])
        let requests = await transport.responseRequestLog()
        XCTAssertEqual(Set(requests.map(\.nonce)).count, 3)
    }

    func testSpeakTextWhileRespondingWithoutAudioGraphPreservesResponseCancellation() async {
        let gate = SendGate()
        let cancelGate = SendGate()
        let textGate = SendGate()
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(
            configuration: configuration,
            frames: [
                responseCreatedFrame(responseID: "first"),
                #"{"type":"response.output_audio_transcript.done","response_id":"first","transcript":"Canceled answer"}"#,
            ],
            receiveGate: gate,
            cancelResponseGate: cancelGate,
            sendTextGate: textGate,
            acceptsText: true
        )
        var events: [RealtimeVoiceEvent] = []
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onEvent: { events.append($0) }
        )
        defer { session.stop() }

        let firstRequestReady = await beginFixtureTextRequest(session: session, transport: transport, text: "first request")
        XCTAssertTrue(firstRequestReady)
        guard firstRequestReady else { return }
        let receiverTask = Task { await session.receiveCurrentFixtureEvents() }
        let receiverBlocked = await gate.waitUntilBlocked()
        XCTAssertTrue(receiverBlocked)
        guard receiverBlocked else {
            await gate.open()
            await receiverTask.value
            return
        }

        session.speakText("read this")
        let cancelSent = await cancelGate.waitUntilOpen()
        let textSent = await transport.waitUntilRequestCount(2)

        XCTAssertTrue(cancelSent)
        XCTAssertTrue(textSent)
        let operations = await transport.operationLog()
        XCTAssertEqual(operations, [
            .sendText("first request"),
            .cancelResponse,
            .sendText("read this"),
        ])
        XCTAssertEqual(events, [.responseStarted("first"), .responseInterrupted(nil)])
        XCTAssertEqual(session.state, .listening)
        await gate.open()
        await receiverTask.value
    }

    func testSpeechStartedWithoutAudioGraphPreservesListeningState() async {
        let gate = SendGate()
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(configuration: configuration, frames: [
            responseCreatedFrame(responseID: "first"),
            #"{"type":"input_audio_buffer.speech_started"}"#,
        ], receiveGate: gate, acceptsText: true)
        var events: [RealtimeVoiceEvent] = []
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onEvent: { events.append($0) }
        )

        let firstRequestReady = await beginFixtureTextRequest(session: session, transport: transport, text: "first request")
        XCTAssertTrue(firstRequestReady)
        guard firstRequestReady else { return }
        let receiverTask = Task { await session.receiveCurrentFixtureEvents() }
        let receiverBlocked = await gate.waitUntilBlocked()
        XCTAssertTrue(receiverBlocked)
        await gate.open()
        await receiverTask.value

        XCTAssertEqual(events, [.responseStarted("first"), .speechStarted])
        XCTAssertEqual(session.state, .listening)
        session.stop()
    }

    func testResponseInterruptedWithoutAudioGraphPreservesListeningState() async {
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(configuration: configuration, frames: [
            responseCreatedFrame(responseID: "first"),
            #"{"type":"response.cancelled","response_id":"first"}"#,
        ], acceptsText: true)
        var events: [RealtimeVoiceEvent] = []
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onEvent: { events.append($0) }
        )

        let firstRequestReady = await beginFixtureTextRequest(session: session, transport: transport, text: "first request")
        XCTAssertTrue(firstRequestReady)
        guard firstRequestReady else { return }
        await session.receiveCurrentFixtureEvents()

        XCTAssertEqual(events, [.responseStarted("first"), .responseInterrupted("first")])
        XCTAssertEqual(session.state, .listening)
        session.stop()
    }

    func testProviderJSONRejectsCanceledResponseTranscriptAfterNewResponse() async throws {
        let transport = OpenAICompatibleRealtimeVoiceTransport(
            configuration: RealtimeVoiceConfiguration(endpoint: URL(string: "wss://example.invalid")!, model: "test"),
            apiKey: "fixture"
        )
        var tracker = RealtimeVoiceResponseTracker()
        let oldRequest = RealtimeVoiceResponseRequest(
            tag: RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: 1),
            nonce: "old-request"
        )
        XCTAssertTrue(tracker.authorize(oldRequest))
        XCTAssertEqual(tracker.admit("response-old", metadata: oldRequest.metadata), .accepted(oldRequest))
        tracker.cancel()
        let newRequest = RealtimeVoiceResponseRequest(
            tag: RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: 2),
            nonce: "new-request"
        )
        XCTAssertTrue(tracker.authorize(newRequest))
        XCTAssertEqual(tracker.admit("response-new", metadata: newRequest.metadata), .accepted(newRequest))

        let event = try await transport.decodeEvent(Data(
            #"{"type":"response.output_audio_transcript.done","response_id":"response-old","transcript":"old reply"}"#.utf8
        ))
        guard case .assistantTranscriptFinal(let text, let responseID) = event else {
            XCTFail("Expected assistant transcript final")
            return
        }
        XCTAssertEqual(text, "old reply")
        XCTAssertEqual(responseID, "response-old")
        XCTAssertFalse(tracker.accepts(responseID))
        XCTAssertTrue(tracker.accepts("response-new"))
    }

    func testProviderJSONRejectsCompletedResponseTranscriptAfterNewResponse() async throws {
        let transport = OpenAICompatibleRealtimeVoiceTransport(
            configuration: RealtimeVoiceConfiguration(endpoint: URL(string: "wss://example.invalid")!, model: "test"),
            apiKey: "fixture"
        )
        var tracker = RealtimeVoiceResponseTracker()
        let oldRequest = RealtimeVoiceResponseRequest(
            tag: RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: 1),
            nonce: "old-request"
        )
        XCTAssertTrue(tracker.authorize(oldRequest))
        XCTAssertEqual(tracker.admit("response-old", metadata: oldRequest.metadata), .accepted(oldRequest))
        XCTAssertTrue(tracker.finish("response-old"))
        let newRequest = RealtimeVoiceResponseRequest(
            tag: RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: 2),
            nonce: "new-request"
        )
        XCTAssertTrue(tracker.authorize(newRequest))
        XCTAssertEqual(tracker.admit("response-new", metadata: newRequest.metadata), .accepted(newRequest))

        let event = try await transport.decodeEvent(Data(
            #"{"type":"response.output_audio_transcript.delta","response_id":"response-old","delta":"old"}"#.utf8
        ))
        guard case .assistantTranscriptDelta(let text, let responseID) = event else {
            XCTFail("Expected assistant transcript delta")
            return
        }
        XCTAssertEqual(text, "old")
        XCTAssertEqual(responseID, "response-old")
        XCTAssertFalse(tracker.accepts(responseID))
        XCTAssertTrue(tracker.accepts("response-new"))
    }

    func testProviderJSONRequiresResponseIDForAssistantTranscriptDelivery() async throws {
        let transport = OpenAICompatibleRealtimeVoiceTransport(
            configuration: RealtimeVoiceConfiguration(endpoint: URL(string: "wss://example.invalid")!, model: "test"),
            apiKey: "fixture"
        )
        var tracker = RealtimeVoiceResponseTracker()
        let request = RealtimeVoiceResponseRequest(
            tag: RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: 1),
            nonce: "current-request"
        )
        XCTAssertTrue(tracker.authorize(request))
        XCTAssertEqual(tracker.admit("response-current", metadata: request.metadata), .accepted(request))

        let event = try await transport.decodeEvent(Data(
            #"{"type":"response.output_audio_transcript.delta","delta":"unidentified"}"#.utf8
        ))
        guard case .assistantTranscriptDelta(let text, let responseID) = event else {
            XCTFail("Expected assistant transcript delta")
            return
        }
        XCTAssertEqual(text, "unidentified")
        XCTAssertNil(responseID)
        XCTAssertFalse(tracker.accepts(responseID))
        XCTAssertFalse(tracker.accepts(nil))
        XCTAssertEqual(tracker.authorizedRequestCount, 1)
    }

    func testResponseTrackerBoundsPendingRequestsAndCancelsExactRequest() {
        var tracker = RealtimeVoiceResponseTracker()
        let first = RealtimeVoiceResponseRequest(
            tag: RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: 1),
            nonce: "first-request"
        )
        let second = RealtimeVoiceResponseRequest(
            tag: RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: 1),
            nonce: "second-request"
        )

        XCTAssertTrue(tracker.authorize(first))
        XCTAssertFalse(tracker.authorize(second))
        XCTAssertEqual(tracker.authorizedRequestCount, 1)
        tracker.cancel(first)
        XCTAssertEqual(tracker.authorizedRequestCount, 0)
        XCTAssertTrue(tracker.authorize(second))
        tracker.cancel(tag: second.tag)
        XCTAssertEqual(tracker.authorizedRequestCount, 0)
    }

    func testResponseTrackerKeepsActiveResponseAcrossDuplicateAndMismatchedCreatedEvents() {
        var tracker = RealtimeVoiceResponseTracker()
        let request = RealtimeVoiceResponseRequest(
            tag: RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: 1),
            nonce: "active-request"
        )

        XCTAssertTrue(tracker.authorize(request))
        XCTAssertEqual(tracker.admit("active", metadata: request.metadata), .accepted(request))
        XCTAssertEqual(tracker.admit("active", metadata: request.metadata), .duplicateActive)
        XCTAssertEqual(tracker.admit(
            "other",
            metadata: [RealtimeVoiceResponseRequest.metadataKey: "other-request"]
        ), .activeResponse)
        XCTAssertTrue(tracker.accepts("active", tag: request.tag))
        XCTAssertFalse(tracker.accepts("other", tag: request.tag))
    }

    func testLateCanceledResponseCreatedDoesNotErrorOrStopReplacementResponse() async {
        let responseGate = SendGate()
        let cancelGate = SendGate()
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(
            configuration: configuration,
            frames: [
                responseCreatedFrame(responseID: "old", metadata: firstResponseRequestTokenPlaceholder),
                responseCreatedFrame(responseID: "new"),
            ],
            cancelResponseGate: cancelGate,
            acceptsText: true,
            receiveGates: [0: responseGate]
        )
        var events: [RealtimeVoiceEvent] = []
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onEvent: { events.append($0) }
        )
        defer {
            Task { await responseGate.open() }
            session.stop()
        }

        let firstRequestReady = await beginFixtureTextRequest(
            session: session,
            transport: transport,
            text: "old request"
        )
        XCTAssertTrue(firstRequestReady)
        guard firstRequestReady else { return }
        let receiverTask = Task { await session.receiveCurrentFixtureEvents() }
        let receiverBlocked = await responseGate.waitUntilBlocked()
        XCTAssertTrue(receiverBlocked)
        guard receiverBlocked else {
            await receiverTask.value
            return
        }

        session.cancelCurrentResponse()
        let cancelSent = await cancelGate.waitUntilOpen()
        XCTAssertTrue(cancelSent)
        session.speakText("new request")
        let replacementRequestReady = await transport.waitUntilRequestCount(2)
        XCTAssertTrue(replacementRequestReady)
        guard replacementRequestReady else {
            await responseGate.open()
            await receiverTask.value
            return
        }
        let requests = await transport.responseRequestLog()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].tag, requests[1].tag)
        XCTAssertNotEqual(requests[0].nonce, requests[1].nonce)
        await responseGate.open()
        await receiverTask.value

        XCTAssertEqual(events, [.responseInterrupted(nil), .responseStarted("new")])
        XCTAssertFalse(events.contains {
            if case .error = $0 { return true }
            return false
        })
        XCTAssertEqual(session.state, .responding)
    }

    func testMissingResponseMetadataForPendingRequestReportsCorrelationFailure() async {
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(
            configuration: configuration,
            frames: [responseCreatedFrame(responseID: "missing", metadata: nil)],
            acceptsText: true
        )
        var events: [RealtimeVoiceEvent] = []
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onEvent: { events.append($0) }
        )
        defer { session.stop() }

        let requestReady = await beginFixtureTextRequest(session: session, transport: transport)
        XCTAssertTrue(requestReady)
        guard requestReady else { return }
        await session.receiveCurrentFixtureEvents()

        XCTAssertEqual(events, [.error(RealtimeVoiceError.responseCorrelationUnavailable.localizedDescription)])
        XCTAssertEqual(session.state, .listening)
    }

    func testFinishInputSendsCorrelatedResponseRequestWhileReceiveIsPending() async {
        let responseGate = SendGate()
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(
            configuration: configuration,
            frames: [responseCreatedFrame(responseID: "finish")],
            acceptsFinishInput: true,
            acceptsAudio: true,
            receiveGates: [0: responseGate]
        )
        var events: [RealtimeVoiceEvent] = []
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onEvent: { events.append($0) }
        )
        defer {
            Task { await responseGate.open() }
            session.stop()
        }

        session.beginEmptyInputFixture()
        let ingress = RealtimeVoiceAudioIngress(capacity: 1)
        session.installAudioIngressFixtureForTesting(ingress)
        ingress.yield(RealtimeVoiceAudioPacket(
            data: Data([1, 0]), sessionID: 1, utteranceGeneration: 1
        ))
        let audioReady = await transport.waitUntilAudioCount(1, timeout: .seconds(1))
        XCTAssertTrue(audioReady)
        guard audioReady else { return }

        let receiverTask = Task { await session.receiveCurrentFixtureEvents() }
        let receiverBlocked = await responseGate.waitUntilBlocked()
        XCTAssertTrue(receiverBlocked)
        guard receiverBlocked else {
            await responseGate.open()
            await receiverTask.value
            return
        }
        session.finishInput()
        let requestReady = await transport.waitUntilRequestCount(1)
        XCTAssertTrue(requestReady)
        guard requestReady else {
            await responseGate.open()
            await receiverTask.value
            return
        }
        let requests = await transport.responseRequestLog()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].tag, RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: 1))
        XCTAssertFalse(requests[0].nonce.isEmpty)
        XCTAssertEqual(requests[0].metadata[RealtimeVoiceResponseRequest.metadataKey], requests[0].nonce)
        await responseGate.open()
        await receiverTask.value

        let operations = await transport.operationLog()
        XCTAssertEqual(operations, [.finishInput(RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: 1))])
        XCTAssertEqual(events, [.responseStarted("finish")])
    }

    func testPushToTalkDisablesAutomaticAudioCommitsInEveryProtocol() async throws {
        for mode in [RealtimeVoiceProtocolMode.openAIGA, .openAIBeta, .compatible, .automatic] {
            let configuration = RealtimeVoiceConfiguration(
                endpoint: URL(string: "wss://api.openai.com/v1/realtime")!,
                model: "test",
                protocolMode: mode
            )
            let transport = OpenAICompatibleRealtimeVoiceTransport(configuration: configuration, apiKey: "fixture")
            let payload = await transport.sessionUpdatePayload()
            let encoded = try JSONSerialization.data(withJSONObject: payload)
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(decoded["type"] as? String, "session.update")
            let session = try XCTUnwrap(decoded["session"] as? [String: Any])
            if mode == .openAIGA || mode == .automatic {
                let audio = try XCTUnwrap(session["audio"] as? [String: Any])
                let input = try XCTUnwrap(audio["input"] as? [String: Any])
                XCTAssertTrue(input["turn_detection"] is NSNull, "\(mode) must commit only on release")
                XCTAssertNotNil(input["transcription"])
            } else {
                XCTAssertTrue(session["turn_detection"] is NSNull, "\(mode) must commit only on release")
                XCTAssertNotNil(session["input_audio_transcription"])
            }
        }
    }

    func testTransportCorrelationBindsCommittedItemIDsToQueuedTagsAndDeduplicatesAcknowledgements() {
        var correlation = RealtimeVoiceTransportCorrelation()
        let first = RealtimeVoicePacketTag(sessionID: 2, utteranceGeneration: 11)
        let second = RealtimeVoicePacketTag(sessionID: 2, utteranceGeneration: 12)

        XCTAssertTrue(correlation.enqueueCommit(tag: first))
        XCTAssertTrue(correlation.enqueueCommit(tag: second))
        XCTAssertEqual(correlation.acknowledge(itemID: "item-1"), first)
        XCTAssertEqual(correlation.acknowledge(itemID: "item-2"), second)
        XCTAssertEqual(correlation.acknowledge(itemID: "item-1"), first)
        XCTAssertEqual(correlation.transcriptCorrelation(for: "item-1"), .matched(first))
        XCTAssertEqual(correlation.transcriptCorrelation(for: "item-2"), .matched(second))
        XCTAssertEqual(correlation.pendingCommitCount, 0)
    }

    func testTransportCorrelationFailsClosedForUnknownIDsAndBoundsBothQueues() {
        var correlation = RealtimeVoiceTransportCorrelation()
        let tag = RealtimeVoicePacketTag(sessionID: 3, utteranceGeneration: 1)

        XCTAssertEqual(correlation.transcriptCorrelation(for: nil), .uncorrelated(itemID: nil))
        XCTAssertEqual(correlation.transcriptCorrelation(for: "unknown"), .uncorrelated(itemID: "unknown"))

        for generation in 0..<RealtimeVoiceTransportCorrelation.limit {
            XCTAssertTrue(correlation.enqueueCommit(tag: RealtimeVoicePacketTag(
                sessionID: tag.sessionID,
                utteranceGeneration: generation
            )))
        }
        XCTAssertFalse(correlation.enqueueCommit(tag: tag))
        XCTAssertEqual(correlation.pendingCommitCount, RealtimeVoiceTransportCorrelation.limit)

        for generation in 0..<RealtimeVoiceTransportCorrelation.limit {
            XCTAssertNotNil(correlation.acknowledge(itemID: "item-\(generation)"))
        }
        XCTAssertEqual(correlation.correlatedItemCount, RealtimeVoiceTransportCorrelation.limit)
    }

    func testTransportCorrelationDoesNotReuseAnOldItemIDAtCapacity() {
        var correlation = RealtimeVoiceTransportCorrelation()
        let first = RealtimeVoicePacketTag(sessionID: 6, utteranceGeneration: 0)

        for generation in 0..<(RealtimeVoiceTransportCorrelation.limit - 1) {
            let tag = RealtimeVoicePacketTag(sessionID: first.sessionID, utteranceGeneration: generation)
            XCTAssertTrue(correlation.enqueueCommit(tag: tag))
            XCTAssertEqual(correlation.acknowledge(itemID: "item-\(generation)"), tag)
        }

        let pendingFirst = RealtimeVoicePacketTag(sessionID: first.sessionID, utteranceGeneration: 128)
        let pendingSecond = RealtimeVoicePacketTag(sessionID: first.sessionID, utteranceGeneration: 129)
        XCTAssertTrue(correlation.enqueueCommit(tag: pendingFirst))
        XCTAssertTrue(correlation.enqueueCommit(tag: pendingSecond))
        XCTAssertEqual(correlation.acknowledge(itemID: "item-127"), pendingFirst)
        XCTAssertTrue(correlation.isAtCapacity)

        XCTAssertEqual(correlation.acknowledge(itemID: "item-0"), first)
        XCTAssertFalse(correlation.enqueueCommit(tag: RealtimeVoicePacketTag(
            sessionID: first.sessionID,
            utteranceGeneration: 130
        )))
        XCTAssertNil(correlation.acknowledge(itemID: "item-new"))
        XCTAssertEqual(correlation.pendingCommitCount, 1)
        XCTAssertEqual(correlation.transcriptCorrelation(for: "item-0"), .matched(first))
    }

    func testCommitBarrierDoesNotDispatchDuplicateAcknowledgementOrFinalTranscript() throws {
        let barrier = RealtimeVoiceCommitBarrier()
        let tag = RealtimeVoicePacketTag(sessionID: 4, utteranceGeneration: 9)
        barrier.advance(to: tag)

        XCTAssertEqual(
            barrier.offerTranscript("first", source: .realtime, tag: tag),
            .pending
        )
        let commit = try XCTUnwrap(barrier.markInputCommitted(tag))
        XCTAssertEqual(barrier.dispatch(commit), .dispatched)
        XCTAssertNil(barrier.markInputCommitted(tag))
        XCTAssertEqual(
            barrier.offerTranscript("duplicate", source: .realtime, tag: tag),
            .duplicate
        )
        XCTAssertEqual(barrier.dispatch(commit), .duplicate)
    }

    func testEmptyInputEndsWithoutRestartingRecording() async {
        let failed = expectation(description: "Empty input reported")
        var errors: [String] = []
        let session = RealtimeVoiceSession(
            configuration: RealtimeVoiceConfiguration(endpoint: URL(string: "wss://example.invalid")!, model: "test"),
            apiKey: "fixture"
        ) { event in
            if case .error(let message) = event {
                errors.append(message)
                failed.fulfill()
            }
        }
        session.beginEmptyInputFixture()
        session.finishInput()
        session.refreshAudioRoute()
        await fulfillment(of: [failed], timeout: 2)

        XCTAssertEqual(errors, [RealtimeVoiceError.emptyInput.localizedDescription])
        XCTAssertEqual(session.state, .failed(RealtimeVoiceError.emptyInput.localizedDescription))
        session.refreshAudioRoute()
        session.finishInput()
        XCTAssertEqual(errors.count, 1)
        session.stop()
    }

    func testReleaseBeforeConnectionCompletesDoesNotStartRecording() async {
        let failed = expectation(description: "Released input rejected")
        let gate = SendGate()
        let transport = ConnectionFixture(gate: gate)
        var errors: [String] = []
        let session = RealtimeVoiceSession(
            configuration: RealtimeVoiceConfiguration(endpoint: URL(string: "wss://example.invalid")!, model: "test"),
            apiKey: "fixture",
            transport: transport
        ) { event in
            if case .error(let message) = event {
                errors.append(message)
                failed.fulfill()
            }
            if case .sessionReady = event { XCTFail("Released input became ready") }
        }
        session.start()
        session.finishInput()
        await gate.open()
        await fulfillment(of: [failed], timeout: 2)

        XCTAssertEqual(errors, [RealtimeVoiceError.emptyInput.localizedDescription])
        XCTAssertEqual(session.state, .idle)
        let received = await transport.receiveCount
        XCTAssertEqual(received, 0)
    }

    func testStoppedSessionDoesNotReconnectOrReachListening() async {
        let connectionGate = SendGate()
        let shutdownFinished = expectation(description: "shutdown finished")
        let transport = ConnectionFixture(gate: connectionGate)
        var sawShutdown = false
        var shutdownWasFinished = false
        let session = RealtimeVoiceSession(
            configuration: RealtimeVoiceConfiguration(endpoint: URL(string: "wss://example.invalid")!, model: "test"),
            apiKey: "fixture",
            transport: transport,
            onTaskSnapshot: { snapshot in
                let role = RealtimeWorkerRole.shutdown.rawValue
                if snapshot.startedByRole[role, default: 0] > 0 {
                    sawShutdown = true
                }
                if sawShutdown,
                   snapshot.activeByRole[role] == nil,
                   !shutdownWasFinished {
                    shutdownWasFinished = true
                    shutdownFinished.fulfill()
                }
            },
            onEvent: { event in
                if case .sessionReady = event {
                    XCTFail("Stopped session became ready")
                }
            }
        )
        defer { session.stop() }

        session.start()
        let connectionBlocked = await connectionGate.waitUntilBlocked()
        XCTAssertTrue(connectionBlocked)
        guard connectionBlocked else {
            session.stop()
            await connectionGate.open()
            return
        }

        session.stop()
        await connectionGate.open()
        await fulfillment(of: [shutdownFinished], timeout: 1)

        session.start()
        let reconnected = await transport.waitUntilConnectCount(2, timeout: .milliseconds(100))
        XCTAssertFalse(reconnected)
        let connectCount = await transport.connectCount
        XCTAssertEqual(connectCount, 1)
        XCTAssertEqual(session.state, .idle)
    }

    func testTaskLedgerBalancesWorkersAndIgnoresDuplicateFinish() {
        var ledger = RealtimeTaskLedger()

        let (connection, first) = ledger.start(.connection, sessionGeneration: 4, utteranceGeneration: 1)
        let (receiver, second) = ledger.start(.receiver, sessionGeneration: 4, utteranceGeneration: 1)
        let third = ledger.finish(connection)
        let duplicate = ledger.finish(connection)
        let fourth = ledger.finish(receiver)

        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(first.active, 1)
        XCTAssertEqual(second.sequence, 2)
        XCTAssertEqual(second.active, 2)
        XCTAssertEqual(second.started, 2)
        XCTAssertEqual(third?.active, 1)
        XCTAssertEqual(third?.finished, 1)
        XCTAssertNil(duplicate)
        XCTAssertEqual(fourth?.sequence, 4)
        XCTAssertEqual(fourth?.active, 0)
        XCTAssertEqual(fourth?.started, 2)
        XCTAssertEqual(fourth?.finished, 2)
        XCTAssertEqual(fourth?.startedByRole, ["connection": 1, "receiver": 1])
        XCTAssertEqual(fourth?.finishedByRole, ["connection": 1, "receiver": 1])
    }

    func testPipelineReportsBalancedWorkerLifecycle() async throws {
        let pipeline = RealtimeVoicePipeline { _ in }
        var lifecycle: [(RealtimeWorkerRole, Bool, RealtimeVoicePacketTag)] = []
        pipeline.onWorker = { role, started, tag in
            lifecycle.append((role, started, tag))
        }
        pipeline.advance(sessionID: 3, utteranceGeneration: 8)

        let commit = Task { try await pipeline.commit(sessionID: 3, utteranceGeneration: 8) }
        let commitResult = try await commit.value
        XCTAssertEqual(commitResult, .committed)
        await pipeline.stop()

        XCTAssertEqual(lifecycle.count, 2)
        XCTAssertEqual(lifecycle.map(\.0), [.pipeline, .pipeline])
        XCTAssertEqual(lifecycle.map(\.1), [true, false])
        XCTAssertEqual(lifecycle.map(\.2), [
            RealtimeVoicePacketTag(sessionID: 3, utteranceGeneration: 8),
            RealtimeVoicePacketTag(sessionID: 3, utteranceGeneration: 8),
        ])
    }

    func testCommitOperationCarriesItsPacketTagToTheTransportBoundary() async throws {
        let recorder = OperationRecorder()
        let pipeline = RealtimeVoicePipeline { operation in
            await recorder.append(operation)
        }
        let tag = RealtimeVoicePacketTag(sessionID: 5, utteranceGeneration: 6)
        pipeline.advance(sessionID: tag.sessionID, utteranceGeneration: tag.utteranceGeneration)

        let commitResult = try await pipeline.commit(
            sessionID: tag.sessionID,
            utteranceGeneration: tag.utteranceGeneration
        )
        XCTAssertEqual(commitResult, .committed)
        let finishTags = await recorder.finishTags()
        XCTAssertEqual(finishTags, [tag])
        await pipeline.stop()
    }

    func testFirstAudioTimerEmitsOneSamplePerSpeechEnd() throws {
        var timer = RealtimeFirstAudioTimer()
        timer.markSpeechEnd(at: 1_000_000_000)

        let sample = try XCTUnwrap(timer.markFirstAudio(at: 1_240_000_000))

        XCTAssertEqual(sample.metricID, "voice.realtime_first_audio")
        XCTAssertEqual(sample.collector, "perry.app.realtime-first-audio.v1")
        XCTAssertEqual(sample.unit, "ms")
        XCTAssertEqual(sample.value, 240)
        XCTAssertNil(timer.markFirstAudio(at: 1_260_000_000))
    }

    func testFirstAudioTimerRejectsInvalidAndResetIntervals() {
        var timer = RealtimeFirstAudioTimer()
        timer.markSpeechEnd(at: 2_000)
        XCTAssertNil(timer.markFirstAudio(at: 1_999))
        timer.reset()
        XCTAssertNil(timer.markFirstAudio(at: 3_000))
    }

    func testInterruptedResponseRejectsLateAudioFromItsResponseID() {
        var tracker = RealtimeVoiceResponseTracker()
        let firstRequest = RealtimeVoiceResponseRequest(
            tag: RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: 1),
            nonce: "request-1"
        )
        XCTAssertTrue(tracker.authorize(firstRequest))
        XCTAssertEqual(tracker.admit("response-1", metadata: firstRequest.metadata), .accepted(firstRequest))

        XCTAssertTrue(tracker.accepts("response-1"))
        tracker.cancel()
        XCTAssertFalse(tracker.accepts("response-1"))
        XCTAssertFalse(tracker.interrupt("response-1"))
        let secondRequest = RealtimeVoiceResponseRequest(
            tag: RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: 2),
            nonce: "request-2"
        )
        XCTAssertTrue(tracker.authorize(secondRequest))
        XCTAssertEqual(tracker.admit("response-2", metadata: secondRequest.metadata), .accepted(secondRequest))

        XCTAssertTrue(tracker.accepts("response-2"))
        XCTAssertFalse(tracker.accepts("response-1"))
    }

    func testResponseTombstonesStayBoundedDuringLongSessions() {
        var tracker = RealtimeVoiceResponseTracker()

        for index in 0..<10_000 {
            let responseID = "response-\(index)"
            let request = RealtimeVoiceResponseRequest(
                tag: RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: index),
                nonce: "request-\(index)"
            )
            XCTAssertTrue(tracker.authorize(request))
            XCTAssertEqual(tracker.admit(responseID, metadata: request.metadata), .accepted(request))
            XCTAssertTrue(tracker.finish(responseID))
        }

        XCTAssertEqual(tracker.ignoredResponseCount, 128)
        XCTAssertFalse(tracker.accepts("response-0"))
        let currentRequest = RealtimeVoiceResponseRequest(
            tag: RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: 10_000),
            nonce: "request-current"
        )
        XCTAssertTrue(tracker.authorize(currentRequest))
        XCTAssertEqual(tracker.admit("response-current", metadata: currentRequest.metadata), .accepted(currentRequest))
        XCTAssertTrue(tracker.accepts("response-current"))
        XCTAssertTrue(tracker.finish("response-current"))
        XCTAssertFalse(tracker.accepts("response-9999"))
    }

    func testPlaintextRemoteVoiceEndpointIsRejectedBeforeConnecting() async {
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "ws://api.example.com/realtime")!,
            model: "test"
        )
        let transport = OpenAICompatibleRealtimeVoiceTransport(configuration: configuration, apiKey: "secret")

        do {
            try await transport.connect()
            XCTFail("expected unsafe endpoint to fail")
        } catch let error as NetworkEndpointError {
            XCTAssertEqual(error, .insecureRemoteEndpoint)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCommitWaitsForAllQueuedAudioInItsGeneration() async throws {
        let gate = SendGate()
        let recorder = OperationRecorder()
        let pipeline = RealtimeVoicePipeline(capacity: 2) { operation in
            await recorder.append(operation)
            await gate.wait()
        }
        pipeline.advance(to: 1)

        XCTAssertEqual(pipeline.enqueueAudio(Data([1]), generation: 1), .accepted)
        XCTAssertEqual(pipeline.enqueueAudio(Data([2]), generation: 1), .accepted)
        let operationBlocked = await gate.waitUntilBlocked()
        XCTAssertTrue(operationBlocked)

        let commitTask = Task { try await pipeline.commit(generation: 1) }
        await Task.yield()
        let blockedPayloads = await recorder.audioPayloads()
        XCTAssertEqual(blockedPayloads, [Data([1])])

        await gate.open()
        let commitResult = try await commitTask.value
        XCTAssertEqual(commitResult, .committed)
        let payloads = await recorder.audioPayloads()
        XCTAssertEqual(payloads, [Data([1]), Data([2])])
        await pipeline.stop()
    }

    func testGenerationAdvanceDropsQueuedAudioFromThePreviousUtterance() async throws {
        let gate = SendGate()
        let recorder = OperationRecorder()
        let pipeline = RealtimeVoicePipeline(capacity: 2) { operation in
            await recorder.append(operation)
            await gate.wait()
        }
        pipeline.advance(to: 1)

        XCTAssertEqual(pipeline.enqueueAudio(Data([10]), generation: 1), .accepted)
        XCTAssertEqual(pipeline.enqueueAudio(Data([11]), generation: 1), .accepted)
        let operationBlocked = await gate.waitUntilBlocked()
        XCTAssertTrue(operationBlocked)

        pipeline.advance(to: 2)
        XCTAssertEqual(pipeline.enqueueAudio(Data([20]), generation: 2), .accepted)
        let commitTask = Task { try await pipeline.commit(generation: 2) }

        await gate.open()
        let commitResult = try await commitTask.value
        XCTAssertEqual(commitResult, .committed)
        let payloads = await recorder.audioPayloads()
        XCTAssertEqual(payloads, [Data([10]), Data([20])])
        await pipeline.stop()
    }

    func testGenerationAdvanceSupersedesPendingCommit() async throws {
        let gate = SendGate()
        let recorder = OperationRecorder()
        let pipeline = RealtimeVoicePipeline(capacity: 2) { operation in
            await recorder.append(operation)
            await gate.wait()
        }
        pipeline.advance(to: 1)

        XCTAssertEqual(pipeline.enqueueAudio(Data([30]), generation: 1), .accepted)
        let operationBlocked = await gate.waitUntilBlocked()
        XCTAssertTrue(operationBlocked)

        let commitTask = Task { try await pipeline.commit(generation: 1) }
        await Task.yield()
        pipeline.advance(to: 2)

        let commitResult = try await commitTask.value
        XCTAssertEqual(commitResult, .superseded)
        await gate.open()
        await pipeline.stop()
    }

    func testAudioQueueHasABoundedCapacity() async throws {
        let gate = SendGate()
        let pipeline = RealtimeVoicePipeline(capacity: 2) { _ in
            await gate.wait()
        }
        pipeline.advance(to: 1)

        XCTAssertEqual(pipeline.enqueueAudio(Data([1]), generation: 1), .accepted)
        let operationBlocked = await gate.waitUntilBlocked()
        XCTAssertTrue(operationBlocked)
        XCTAssertEqual(pipeline.enqueueAudio(Data([2]), generation: 1), .accepted)
        XCTAssertEqual(pipeline.enqueueAudio(Data([3]), generation: 1), .accepted)
        XCTAssertEqual(pipeline.enqueueAudio(Data([4]), generation: 1), .full)

        await gate.open()
        await pipeline.stop()
    }

    func testCommitQueuesBehindASaturatedAudioBufferWithoutDroppingAudio() async throws {
        let gate = SendGate()
        let recorder = OperationRecorder()
        let pipeline = RealtimeVoicePipeline(capacity: 2) { operation in
            await recorder.append(operation)
            await gate.wait()
        }
        pipeline.advance(to: 1)

        XCTAssertEqual(pipeline.enqueueAudio(Data([1]), generation: 1), .accepted)
        let operationBlocked = await gate.waitUntilBlocked()
        XCTAssertTrue(operationBlocked)
        XCTAssertEqual(pipeline.enqueueAudio(Data([2]), generation: 1), .accepted)
        XCTAssertEqual(pipeline.enqueueAudio(Data([3]), generation: 1), .accepted)
        XCTAssertEqual(pipeline.pendingCount, 2)

        let commitTask = Task { try await pipeline.commit(generation: 1) }
        await Task.yield()
        XCTAssertEqual(pipeline.pendingCount, 3)

        await gate.open()
        let commitResult = try await commitTask.value
        let payloads = await recorder.audioPayloads()
        let finishCount = await recorder.finishCount()
        XCTAssertEqual(commitResult, .committed)
        XCTAssertEqual(payloads, [Data([1]), Data([2]), Data([3])])
        XCTAssertEqual(finishCount, 1)
        await pipeline.stop()
    }

    func testFallbackAndLateRealtimeTranscriptsDispatchOnceAcrossTenThousandUtterances() {
        let barrier = RealtimeVoiceCommitBarrier()

        for generation in 1...10_000 {
            let tag = RealtimeVoicePacketTag(sessionID: 1, utteranceGeneration: generation)
            barrier.advance(to: tag)

            XCTAssertEqual(
                barrier.offerTranscript("realtime \(generation)", source: .realtime, tag: tag),
                .pending
            )
            let fallback = barrier.offerTranscript("fallback \(generation)", source: .fallback, tag: tag)
            guard case .committed(let commit) = fallback else {
                XCTFail("fallback did not commit for generation \(generation)")
                return
            }
            XCTAssertEqual(barrier.dispatch(commit), .dispatched)
            XCTAssertEqual(barrier.dispatch(commit), .duplicate)
            XCTAssertEqual(
                barrier.offerTranscript("late \(generation)", source: .realtime, tag: tag),
                .duplicate
            )
            XCTAssertNil(barrier.markInputCommitted(tag))
        }
    }

    func testAudioIngressKeepsOnlyTheNewestPacketsWithinCapacity() async {
        let ingress = RealtimeVoiceAudioIngress(capacity: 2)
        ingress.yield(RealtimeVoiceAudioPacket(data: Data([1]), sessionID: 1, utteranceGeneration: 1))
        ingress.yield(RealtimeVoiceAudioPacket(data: Data([2]), sessionID: 1, utteranceGeneration: 1))
        ingress.yield(RealtimeVoiceAudioPacket(data: Data([3]), sessionID: 1, utteranceGeneration: 1))

        XCTAssertTrue(ingress.consumeOverflow())
        var iterator = ingress.stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        ingress.finish()

        XCTAssertEqual(first?.data, Data([2]))
        XCTAssertEqual(second?.data, Data([3]))
    }

    func testFinishingIngressDrainsBufferedAudioBeforeConsumerCompletes() async {
        let ingress = RealtimeVoiceAudioIngress(capacity: 2)
        let consumer = Task { @MainActor in
            var packets: [RealtimeVoiceAudioPacket] = []
            for await packet in ingress.stream {
                packets.append(packet)
            }
            return packets
        }

        ingress.yield(RealtimeVoiceAudioPacket(data: Data([1]), sessionID: 1, utteranceGeneration: 1))
        ingress.yield(RealtimeVoiceAudioPacket(data: Data([2]), sessionID: 1, utteranceGeneration: 1))
        ingress.finish()

        let packets = await consumer.value
        XCTAssertEqual(packets.map(\.data), [Data([1]), Data([2])])
    }

    func testSessionStopsIngressWhenPipelineAudioQueueFillsAndAllowsRecovery() async {
        let sendGate = SendGate()
        let ingressFinished = expectation(description: "audio ingress worker finished")
        let pipelineFinished = expectation(description: "pipeline worker finished")
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(
            configuration: configuration,
            frames: [],
            audioGate: sendGate,
            acceptsAudio: true
        )
        var events: [RealtimeVoiceEvent] = []
        var sawIngressWorker = false
        var ingressWorkerFinished = false
        var sawPipelineWorker = false
        var pipelineWorkerFinished = false
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onTaskSnapshot: { snapshot in
                let ingressRole = RealtimeWorkerRole.audioIngress.rawValue
                let pipelineRole = RealtimeWorkerRole.pipeline.rawValue
                if snapshot.startedByRole[ingressRole, default: 0] > 0 {
                    sawIngressWorker = true
                }
                if snapshot.startedByRole[pipelineRole, default: 0] > 0 {
                    sawPipelineWorker = true
                }
                if sawIngressWorker,
                   snapshot.activeByRole[ingressRole] == nil,
                   !ingressWorkerFinished {
                    ingressWorkerFinished = true
                    ingressFinished.fulfill()
                }
                if sawPipelineWorker,
                   snapshot.activeByRole[pipelineRole] == nil,
                   !pipelineWorkerFinished {
                    pipelineWorkerFinished = true
                    pipelineFinished.fulfill()
                }
            },
            onEvent: { events.append($0) }
        )
        defer { session.stop() }

        session.beginEmptyInputFixture()
        let ingress = RealtimeVoiceAudioIngress(capacity: 64)
        session.installAudioIngressFixtureForTesting(ingress)
        ingress.yield(RealtimeVoiceAudioPacket(data: Data([1]), sessionID: 1, utteranceGeneration: 1))
        let sendBlocked = await sendGate.waitUntilBlocked()
        XCTAssertTrue(sendBlocked)
        guard sendBlocked else {
            await sendGate.open()
            return
        }

        for value in 2...34 {
            ingress.yield(RealtimeVoiceAudioPacket(
                data: Data([UInt8(value)]), sessionID: 1, utteranceGeneration: 1
            ))
        }
        await fulfillment(of: [ingressFinished], timeout: 1)

        let sendsBeforeRecovery = await transport.audioPayloads()
        XCTAssertEqual(sendsBeforeRecovery, [Data([1])])
        ingress.yield(RealtimeVoiceAudioPacket(data: Data([255]), sessionID: 1, utteranceGeneration: 1))
        await Task.yield()
        let sendsAfterStoppedIngress = await transport.audioPayloads()
        XCTAssertEqual(sendsAfterStoppedIngress, sendsBeforeRecovery)

        session.submitTranscript("partial input", source: .realtime)
        XCTAssertEqual(events, [.error(RealtimeVoiceError.audioBufferFull.localizedDescription)])

        await sendGate.open()
        await fulfillment(of: [pipelineFinished], timeout: 1)
        let sendsBeforeNewInput = await transport.audioPayloads()
        XCTAssertEqual(sendsBeforeNewInput.count, 33)
        XCTAssertFalse(sendsBeforeNewInput.contains(Data([255])))

        session.audioStartOverrideForTesting = {}
        session.beginInput()
        let recoveredIngress = RealtimeVoiceAudioIngress(capacity: 1)
        session.installAudioIngressFixtureForTesting(recoveredIngress)
        recoveredIngress.yield(RealtimeVoiceAudioPacket(
            data: Data([99]), sessionID: 1, utteranceGeneration: 2
        ))
        let recovered = await transport.waitUntilAudioCount(
            sendsBeforeNewInput.count + 1,
            timeout: .seconds(1)
        )
        XCTAssertTrue(recovered)
        let sendsAfterRecovery = await transport.audioPayloads()
        XCTAssertEqual(sendsAfterRecovery.last, Data([99]))
    }

    func testSessionStopsIngressWhenSharedIngressDropsAPacket() async {
        let ingressFinished = expectation(description: "audio ingress worker finished")
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(configuration: configuration, frames: [])
        var events: [RealtimeVoiceEvent] = []
        var sawIngressWorker = false
        var ingressWorkerFinished = false
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onTaskSnapshot: { snapshot in
                let role = RealtimeWorkerRole.audioIngress.rawValue
                if snapshot.startedByRole[role, default: 0] > 0 {
                    sawIngressWorker = true
                }
                if sawIngressWorker,
                   snapshot.activeByRole[role] == nil,
                   !ingressWorkerFinished {
                    ingressWorkerFinished = true
                    ingressFinished.fulfill()
                }
            },
            onEvent: { events.append($0) }
        )
        defer { session.stop() }

        session.beginEmptyInputFixture()
        let ingress = RealtimeVoiceAudioIngress(capacity: 1)
        session.installAudioIngressFixtureForTesting(ingress)
        ingress.yield(RealtimeVoiceAudioPacket(data: Data([1]), sessionID: 1, utteranceGeneration: 1))
        ingress.yield(RealtimeVoiceAudioPacket(data: Data([2]), sessionID: 1, utteranceGeneration: 1))

        await fulfillment(of: [ingressFinished], timeout: 1)
        let sends = await transport.audioPayloads()
        XCTAssertEqual(sends, [])
        session.submitTranscript("partial input", source: .realtime)
        XCTAssertEqual(events, [.error(RealtimeVoiceError.audioBufferFull.localizedDescription)])
    }

    func testOutputCompletionReleasesExactReservationAndIgnoresStaleCompletion() async {
        let cancelGate = SendGate()
        let newResponseGate = SendGate()
        let oldScheduled = SendGate()
        let newScheduled = SendGate()
        let oldAudio = Data([1, 0, 2, 0])
        let newAudio = Data([3, 0, 4, 0])
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let transport = ResponseStreamFixture(
            configuration: configuration,
            frames: [
                responseCreatedFrame(responseID: "old"),
                responseCreatedFrame(responseID: "old"),
                audioFrame(oldAudio, responseID: "old"),
                responseCreatedFrame(responseID: "new"),
                audioFrame(newAudio, responseID: "new"),
            ],
            cancelResponseGate: cancelGate,
            acceptsText: true,
            receiveGates: [3: newResponseGate]
        )
        var events: [RealtimeVoiceEvent] = []
        var scheduledCompletions: [() -> Void] = []
        var scheduledFrames: [Int] = []
        var oldReservation: RealtimeVoiceOutputReservation?
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onEvent: { events.append($0) }
        )
        session.audioStartOverrideForTesting = {}
        session.outputScheduleOverrideForTesting = { frameCount, completion in
            scheduledFrames.append(frameCount)
            scheduledCompletions.append(completion)
            if scheduledCompletions.count == 1 {
                oldReservation = session.outputReservationsForTesting.first
                Task { await oldScheduled.open() }
            } else if scheduledCompletions.count == 2 {
                Task { await newScheduled.open() }
            }
        }
        defer { session.stop() }

        let firstRequestReady = await beginFixtureTextRequest(session: session, transport: transport, text: "old request")
        XCTAssertTrue(firstRequestReady)
        guard firstRequestReady else { return }
        let receiverTask = Task { await session.receiveCurrentFixtureEvents() }
        defer {
            receiverTask.cancel()
            Task { await newResponseGate.open() }
        }
        let oldReady = await oldScheduled.waitUntilOpen()
        XCTAssertTrue(oldReady)
        guard oldReady else {
            return
        }
        guard let oldReservation else {
            XCTFail("Expected an output reservation for the old response")
            return
        }

        XCTAssertEqual(session.outputReservationSnapshotForTesting.frames, oldAudio.count / 2)
        XCTAssertEqual(session.outputReservationSnapshotForTesting.buffers, 1)
        let newReceiveBlocked = await newResponseGate.waitUntilBlocked()
        XCTAssertTrue(newReceiveBlocked)
        guard newReceiveBlocked else { return }
        session.beginInput()
        let cancelSent = await cancelGate.waitUntilOpen()
        XCTAssertTrue(cancelSent)
        XCTAssertEqual(session.outputReservationSnapshotForTesting.frames, 0)
        XCTAssertEqual(session.outputReservationSnapshotForTesting.buffers, 0)
        scheduledCompletions[0]()
        XCTAssertEqual(session.outputReservationSnapshotForTesting.frames, 0)
        XCTAssertEqual(session.outputReservationSnapshotForTesting.buffers, 0)

        session.speakText("new request")
        let newRequestReady = await transport.waitUntilRequestCount(2)
        XCTAssertTrue(newRequestReady)
        guard newRequestReady else {
            await newResponseGate.open()
            await receiverTask.value
            return
        }
        await newResponseGate.open()

        let newReady = await newScheduled.waitUntilOpen()
        XCTAssertTrue(newReady)
        guard newReady else {
            await receiverTask.value
            return
        }
        guard let newReservation = session.outputReservationsForTesting.first else {
            XCTFail("Expected an output reservation for the new response")
            await receiverTask.value
            return
        }

        XCTAssertEqual(scheduledFrames, [oldAudio.count / 2, newAudio.count / 2])
        XCTAssertEqual(newReservation.tag.utteranceGeneration, oldReservation.tag.utteranceGeneration + 1)
        XCTAssertEqual(newReservation.responseID, "new")
        XCTAssertNotEqual(newReservation.token, oldReservation.token)
        XCTAssertEqual(session.outputReservationSnapshotForTesting.frames, newAudio.count / 2)
        XCTAssertEqual(session.outputReservationSnapshotForTesting.buffers, 1)

        scheduledCompletions[0]()
        XCTAssertEqual(session.outputReservationSnapshotForTesting.frames, newAudio.count / 2)
        XCTAssertEqual(session.outputReservationSnapshotForTesting.buffers, 1)
        scheduledCompletions[1]()
        XCTAssertEqual(session.outputReservationSnapshotForTesting.frames, 0)
        XCTAssertEqual(session.outputReservationSnapshotForTesting.buffers, 0)

        await receiverTask.value
        XCTAssertEqual(events, [
            .responseStarted("old"),
            .responseInterrupted(nil),
            .responseStarted("new"),
        ])
    }

    func testOutputFrameOverflowFailsBeforeSchedulingPCM() async {
        let cancelGate = SendGate()
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let oversizedAudio = Data(
            repeating: 0,
            count: (RealtimeVoiceOutputReservationLedger.maximumFrames + 1) * MemoryLayout<Int16>.size
        )
        let transport = ResponseStreamFixture(
            configuration: configuration,
            frames: [
                responseCreatedFrame(responseID: "response"),
                audioFrame(oversizedAudio, responseID: "response"),
            ],
            cancelResponseGate: cancelGate,
            acceptsText: true
        )
        var events: [RealtimeVoiceEvent] = []
        var scheduledCount = 0
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onEvent: { events.append($0) }
        )
        session.outputScheduleOverrideForTesting = { _, _ in scheduledCount += 1 }
        defer { session.stop() }

        let firstRequestReady = await beginFixtureTextRequest(session: session, transport: transport, text: "response request")
        XCTAssertTrue(firstRequestReady)
        guard firstRequestReady else { return }
        await session.receiveCurrentFixtureEvents()

        let cancelSent = await cancelGate.waitUntilOpen()
        XCTAssertTrue(cancelSent)
        XCTAssertEqual(scheduledCount, 0)
        XCTAssertEqual(session.outputReservationSnapshotForTesting.frames, 0)
        XCTAssertEqual(session.outputReservationSnapshotForTesting.buffers, 0)
        XCTAssertEqual(session.state, .listening)
        XCTAssertEqual(events, [
            .responseStarted("response"),
            .responseInterrupted(nil),
            .error(RealtimeVoiceError.audioOutputBufferFull.localizedDescription),
        ])
        let operations = await transport.operationLog()
        XCTAssertEqual(operations, [.sendText("response request"), .cancelResponse])
    }

    func testOutputBufferOverflowCancelsAfterTheExplicitBufferLimit() async {
        let cancelGate = SendGate()
        let tinyAudio = Data([0, 0])
        let configuration = RealtimeVoiceConfiguration(
            endpoint: URL(string: "wss://example.invalid")!, model: "test"
        )
        let frames = [
            responseCreatedFrame(responseID: "response"),
        ] + (0..<RealtimeVoiceOutputReservationLedger.maximumBuffers + 1).map { _ in
            audioFrame(tinyAudio, responseID: "response")
        }
        let transport = ResponseStreamFixture(
            configuration: configuration,
            frames: frames,
            cancelResponseGate: cancelGate,
            acceptsText: true
        )
        var events: [RealtimeVoiceEvent] = []
        var scheduledCount = 0
        var scheduledCompletions: [() -> Void] = []
        let session = RealtimeVoiceSession(
            configuration: configuration,
            apiKey: "fixture",
            transport: transport,
            onEvent: { events.append($0) }
        )
        session.outputScheduleOverrideForTesting = { _, completion in
            scheduledCount += 1
            scheduledCompletions.append(completion)
        }
        defer { session.stop() }

        let firstRequestReady = await beginFixtureTextRequest(session: session, transport: transport, text: "response request")
        XCTAssertTrue(firstRequestReady)
        guard firstRequestReady else { return }
        await session.receiveCurrentFixtureEvents()

        let cancelSent = await cancelGate.waitUntilOpen()
        XCTAssertTrue(cancelSent)
        XCTAssertEqual(scheduledCount, RealtimeVoiceOutputReservationLedger.maximumBuffers)
        XCTAssertEqual(session.outputReservationSnapshotForTesting.frames, 0)
        XCTAssertEqual(session.outputReservationSnapshotForTesting.buffers, 0)
        scheduledCompletions[0]()
        XCTAssertEqual(session.outputReservationSnapshotForTesting.frames, 0)
        let operations = await transport.operationLog()
        XCTAssertEqual(operations, [.sendText("response request"), .cancelResponse])
        XCTAssertEqual(events, [
            .responseStarted("response"),
            .responseInterrupted(nil),
            .error(RealtimeVoiceError.audioOutputBufferFull.localizedDescription),
        ])
    }

    private func audioFrame(_ data: Data, responseID: String) -> String {
        #"{"type":"response.output_audio.delta","response_id":"\#(responseID)","delta":"\#(data.base64EncodedString())"}"#
    }

    private func responseCreatedFrame(responseID: String, metadata: String? = responseRequestTokenPlaceholder) -> String {
        guard let metadata else {
            return #"{"type":"response.created","response":{"id":"\#(responseID)"}}"#
        }
        return #"{"type":"response.created","response":{"id":"\#(responseID)","metadata":{"\#(RealtimeVoiceResponseRequest.metadataKey)":"\#(metadata)"}}}"#
    }

    private func beginFixtureTextRequest(
        session: RealtimeVoiceSession,
        transport: ResponseStreamFixture,
        text: String = "fixture request"
    ) async -> Bool {
        session.beginEmptyInputFixture()
        session.speakText(text)
        return await transport.waitUntilRequestCount(1)
    }

}
