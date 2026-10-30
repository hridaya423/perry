import XCTest
@testable import Perry

actor SendGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func waitUntilBlocked(timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while waiters.isEmpty && !isOpen {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            do {
                try await Task.sleep(
                    until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(5))),
                    clock: .continuous
                )
            } catch {
                return false
            }
        }
        return !waiters.isEmpty
    }

    func waitUntilOpen(timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !isOpen {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            do {
                try await Task.sleep(
                    until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(5))),
                    clock: .continuous
                )
            } catch {
                return false
            }
        }
        return true
    }
}

enum ResponseOperation: Equatable, Sendable {
    case cancelResponse
    case finishInput(RealtimeVoicePacketTag)
    case commitInput(RealtimeVoicePacketTag)
    case sendText(String)
}

actor ResponseStreamFixture: RealtimeVoiceTransport {
    let decoder: OpenAICompatibleRealtimeVoiceTransport
    var frames: ArraySlice<String>
    let receiveGate: SendGate?
    let receiveGates: [Int: SendGate]
    let cancelResponseGate: SendGate?
    let sendTextGate: SendGate?
    let audioGate: SendGate?
    let closeGate: SendGate?
    let acceptsText: Bool
    let acceptsFinishInput: Bool
    let acceptsAudio: Bool
    let cancelResponseError: FixtureTransportError?
    let sendTextError: FixtureTransportError?
    let sendTextErrorGate: SendGate?
    let audioError: FixtureTransportError?
    var operations: [ResponseOperation] = []
    var responseRequests: [RealtimeVoiceResponseRequest] = []
    var sentAudioPayloads: [Data] = []
    var receiveCount = 0
    var closeCalls = 0
    var failedTextSendCalls = 0

    init(
        configuration: RealtimeVoiceConfiguration,
        frames: [String],
        receiveGate: SendGate? = nil,
        cancelResponseGate: SendGate? = nil,
        sendTextGate: SendGate? = nil,
        acceptsText: Bool = false,
        acceptsFinishInput: Bool = false,
        audioGate: SendGate? = nil,
        acceptsAudio: Bool = false,
        receiveGates: [Int: SendGate] = [:],
        cancelResponseError: FixtureTransportError? = nil,
        sendTextError: FixtureTransportError? = nil,
        sendTextErrorGate: SendGate? = nil,
        audioError: FixtureTransportError? = nil,
        closeGate: SendGate? = nil
    ) {
        decoder = OpenAICompatibleRealtimeVoiceTransport(configuration: configuration, apiKey: "fixture")
        self.frames = frames[...]
        self.receiveGate = receiveGate
        var gates = receiveGates
        if let receiveGate {
            gates[1] = receiveGate
        }
        self.receiveGates = gates
        self.cancelResponseGate = cancelResponseGate
        self.sendTextGate = sendTextGate
        self.audioGate = audioGate
        self.closeGate = closeGate
        self.acceptsText = acceptsText
        self.acceptsFinishInput = acceptsFinishInput
        self.acceptsAudio = acceptsAudio
        self.cancelResponseError = cancelResponseError
        self.sendTextError = sendTextError
        self.sendTextErrorGate = sendTextErrorGate
        self.audioError = audioError
    }

    func connect() async throws { XCTFail("Unexpected connection") }
    func sendAudio(_ data: Data) async throws {
        guard acceptsAudio else {
            XCTFail("Unexpected microphone audio")
            return
        }
        sentAudioPayloads.append(data)
        if let audioError {
            throw audioError
        }
        await audioGate?.wait()
    }
    func finishInput(tag: RealtimeVoicePacketTag, request: RealtimeVoiceResponseRequest) async throws {
        guard acceptsFinishInput else {
            XCTFail("Unexpected input commit")
            return
        }
        operations.append(.finishInput(tag))
        responseRequests.append(request)
    }
    func commitInput(tag: RealtimeVoicePacketTag) async throws {
        guard acceptsFinishInput else {
            XCTFail("Unexpected transcription commit")
            return
        }
        try await decoder.prepareCommitFixture(tag: tag)
        operations.append(.commitInput(tag))
    }
    func cancelResponse() async throws {
        guard receiveGate != nil || cancelResponseGate != nil || cancelResponseError != nil else {
            XCTFail("Unexpected response cancellation")
            return
        }
        operations.append(.cancelResponse)
        if let cancelResponseError {
            throw cancelResponseError
        }
        await cancelResponseGate?.open()
    }
    func sendText(_ text: String, request: RealtimeVoiceResponseRequest) async throws {
        guard acceptsText else {
            XCTFail("Unexpected text input")
            return
        }
        operations.append(.sendText(text))
        responseRequests.append(request)
        if let sendTextError {
            await sendTextErrorGate?.wait()
            failedTextSendCalls += 1
            throw sendTextError
        }
        await sendTextGate?.open()
    }
    func operationLog() -> [ResponseOperation] {
        operations
    }
    func audioPayloads() -> [Data] {
        sentAudioPayloads
    }
    func responseRequestLog() -> [RealtimeVoiceResponseRequest] {
        responseRequests
    }
    func closeCallCount() -> Int {
        closeCalls
    }
    func failedTextSendCount() -> Int {
        failedTextSendCalls
    }
    func waitUntilRequestCount(_ count: Int, timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while responseRequests.count < count {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            do {
                try await Task.sleep(
                    until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(5))),
                    clock: .continuous
                )
            } catch {
                return false
            }
        }
        return true
    }
    func waitUntilAudioCount(_ count: Int, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while sentAudioPayloads.count < count {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            do {
                try await Task.sleep(
                    until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(5))),
                    clock: .continuous
                )
            } catch {
                return false
            }
        }
        return true
    }
    func waitUntilCloseCount(_ count: Int, timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while closeCalls < count {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            do {
                try await Task.sleep(
                    until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(5))),
                    clock: .continuous
                )
            } catch {
                return false
            }
        }
        return true
    }
    func waitUntilFailedTextSendCount(_ count: Int, timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while failedTextSendCalls < count {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            do {
                try await Task.sleep(
                    until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(5))),
                    clock: .continuous
                )
            } catch {
                return false
            }
        }
        return true
    }
    func receive() async throws -> RealtimeVoiceTransportEvent {
        guard let frame = frames.popFirst() else { throw CancellationError() }
        let receiveIndex = receiveCount
        receiveCount += 1
        if let receiveGate = receiveGates[receiveIndex] {
            await receiveGate.wait()
        }
        let resolvedFrame = frame
            .replacingOccurrences(
                of: firstResponseRequestTokenPlaceholder,
                with: responseRequests.first?.nonce ?? ""
            )
            .replacingOccurrences(
                of: responseRequestTokenPlaceholder,
                with: responseRequests.last?.nonce ?? ""
            )
        return try await decoder.decodeEvent(Data(resolvedFrame.utf8))
    }
    func close() async {
        closeCalls += 1
        await closeGate?.wait()
    }
    func waitUntilOperationCount(_ count: Int, timeout: Duration = .seconds(1)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while operations.count < count {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            do {
                try await Task.sleep(
                    until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(5))),
                    clock: .continuous
                )
            } catch {
                return false
            }
        }
        return true
    }
}

actor ConnectionFixture: RealtimeVoiceTransport {
    let gate: SendGate
    private(set) var connectCount = 0
    private(set) var receiveCount = 0

    init(gate: SendGate) { self.gate = gate }
    func connect() async throws {
        connectCount += 1
        guard connectCount == 1 else { throw CancellationError() }
        await gate.wait()
    }
    func sendAudio(_ data: Data) async throws { XCTFail("Unexpected audio") }
    func finishInput(tag: RealtimeVoicePacketTag, request: RealtimeVoiceResponseRequest) async throws {
        XCTFail("Unexpected input commit")
    }
    func commitInput(tag: RealtimeVoicePacketTag) async throws {
        XCTFail("Unexpected transcription commit")
    }
    func cancelResponse() async throws { XCTFail("Unexpected response cancellation") }
    func sendText(_ text: String, request: RealtimeVoiceResponseRequest) async throws {
        XCTFail("Unexpected text")
    }
    func receive() async throws -> RealtimeVoiceTransportEvent {
        receiveCount += 1
        throw CancellationError()
    }
    func waitUntilConnectCount(_ count: Int, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while connectCount < count {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            do {
                try await Task.sleep(
                    until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(5))),
                    clock: .continuous
                )
            } catch {
                return false
            }
        }
        return true
    }
    func close() async {}
}

actor OperationRecorder {
    private var operations: [RealtimeVoicePipeline.Operation] = []

    func append(_ operation: RealtimeVoicePipeline.Operation) {
        operations.append(operation)
    }

    func audioPayloads() -> [Data] {
        operations.compactMap { operation in
            guard case .audio(let data) = operation.kind else { return nil }
            return data
        }
    }

    func finishCount() -> Int {
        operations.filter {
            if case .finishInput = $0.kind { return true }
            return false
        }.count
    }

    func finishTags() -> [RealtimeVoicePacketTag] {
        operations.compactMap { operation in
            guard case .finishInput = operation.kind else { return nil }
            return RealtimeVoicePacketTag(
                sessionID: operation.sessionID,
                utteranceGeneration: operation.utteranceGeneration
            )
        }
    }
}
