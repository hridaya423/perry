import AVFoundation
import Foundation
import PerryCore

@MainActor
final class RealtimeVoiceSession {
    let configuration: RealtimeVoiceConfiguration
    private let apiKey: String
    private let transport: any RealtimeVoiceTransport
    private let onEvent: (RealtimeVoiceEvent) -> Void
    private let onPerformanceSample: (PerformanceSample) -> Void
    private let onPerformanceMarker: (PerformanceMarker) -> Void
    private let onTaskSnapshot: (RealtimeTaskSnapshot) -> Void
    private let operationPipeline: RealtimeVoicePipeline
    private let outputReservations = RealtimeVoiceOutputReservationLedger()
    private let transcriptBarrier = RealtimeVoiceCommitBarrier()
    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
#if DEBUG
    var audioStartOverrideForTesting: (() throws -> Void)?
    var outputScheduleOverrideForTesting: ((Int, @escaping () -> Void) -> Void)?

    var outputReservationSnapshotForTesting: (frames: Int, buffers: Int) {
        (
            frames: outputReservations.reservedFrames,
            buffers: outputReservations.reservedBuffers
        )
    }

    var outputReservationsForTesting: [RealtimeVoiceOutputReservation] {
        outputReservations.allReservations
    }
#endif
    private var startTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var commitTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var shutdownRequested = false
    private var engineConfigurationObserver: NSObjectProtocol?
    private var inputTapInstalled = false
    private var audioGraphInstalled = false
    private var audioEngineStarted = false
    private var inputConverter: AVAudioConverter?
    private var audioIngress: RealtimeVoiceAudioIngress?
    private var audioIngressTask: Task<Void, Never>?
    private var inputTapGeneration: Int?
    private var audioSendFailed = false
    private var inputFinishRequested = false
    private var inputFinished = false
    private var inputHasAudio = false
    private var inputGeneration = 0
    private var responseTracker = RealtimeVoiceResponseTracker()
    private var firstAudioTimer = RealtimeFirstAudioTimer()
    private var taskLedger = RealtimeTaskLedger()
    private var pipelineWorkerTokens: [RealtimeWorkerRole: [RealtimeWorkerToken]] = [:]
    private var sessionGeneration = 0
    private(set) var state: RealtimeVoiceSessionState = .idle
    private(set) var echoCancellationEnabled = false
    private var meteredHangUp: Task<Void, Never>?
    var meteredIdleTimeout: Duration = .seconds(30)
    var isShutDown: Bool { shutdownRequested }

    var hasPendingInputAudio: Bool { inputHasAudio }

    init(
        configuration: RealtimeVoiceConfiguration,
        apiKey: String,
        transport: (any RealtimeVoiceTransport)? = nil,
        onPerformanceSample: @escaping (PerformanceSample) -> Void = { _ in },
        onPerformanceMarker: @escaping (PerformanceMarker) -> Void = { _ in },
        onTaskSnapshot: @escaping (RealtimeTaskSnapshot) -> Void = { _ in },
        onEvent: @escaping (RealtimeVoiceEvent) -> Void
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        let resolvedTransport = transport ?? OpenAICompatibleRealtimeVoiceTransport(configuration: configuration, apiKey: apiKey)
        self.transport = resolvedTransport
        self.onEvent = onEvent
        self.onPerformanceSample = onPerformanceSample
        self.onPerformanceMarker = onPerformanceMarker
        self.onTaskSnapshot = onTaskSnapshot
        self.operationPipeline = RealtimeVoicePipeline { operation in
            switch operation.kind {
            case .audio(let data):
                try await resolvedTransport.sendAudio(data)
            case .clearInput:
                try await resolvedTransport.clearInput()
            case .cancelResponse:
                try await resolvedTransport.cancelResponse()
            case .finishInput:
                guard let request = operation.responseRequest else {
                    throw RealtimeVoiceError.responseCorrelationUnavailable
                }
                try await resolvedTransport.finishInput(tag: operation.tag, request: request)
            case .commitInput:
                try await resolvedTransport.commitInput(tag: operation.tag)
            case .sendText(let text):
                guard let request = operation.responseRequest else {
                    throw RealtimeVoiceError.responseCorrelationUnavailable
                }
                try await resolvedTransport.sendText(text, request: request)
            }
        }
        self.operationPipeline.onFailure = { [weak self] operation, error in
            guard let self else { return }
            self.handlePipelineFailure(operation, error: error)
        }
        self.operationPipeline.onWorker = { [weak self] role, started, tag in
            self?.recordPipelineWorker(role, started: started, tag: tag)
        }
        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let token = self.startWorker(.routeRecovery)
                defer { self.finishWorker(token) }
                self.recoverAudioRoute()
            }
        }
    }

    deinit {
        meteredHangUp?.cancel()
        startTask?.cancel()
        receiveTask?.cancel()
        commitTask?.cancel()
        shutdownTask?.cancel()
        audioIngressTask?.cancel()
        audioIngress?.finish()
        if let engineConfigurationObserver {
            NotificationCenter.default.removeObserver(engineConfigurationObserver)
        }
    }

    func start() {
        guard state == .idle, shutdownTask == nil, !shutdownRequested else { return }
        state = .connecting
        scheduleMeteredHangUp()
        sessionGeneration += 1
        let sessionID = sessionGeneration
        let workerToken = startWorker(.connection)
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                startTask = nil
                finishWorker(workerToken)
            }
            do {
                guard !apiKey.isEmpty else { throw RealtimeVoiceError.missingAPIKey }
                try await transport.connect()
                guard state == .connecting, sessionGeneration == sessionID else { return }
                guard !inputFinishRequested else { throw RealtimeVoiceError.emptyInput }
                try startAudioGraph()
                try startInputAudio()
                guard state == .connecting, sessionGeneration == sessionID else { return }
                let tag = RealtimeVoicePacketTag(
                    sessionID: sessionID,
                    utteranceGeneration: inputGeneration
                )
                operationPipeline.advance(
                    sessionID: sessionID,
                    utteranceGeneration: inputGeneration
                )
                transcriptBarrier.advance(to: tag)
                state = .listening
                let receiverToken = startWorker(.receiver, tag: tag)
                receiveTask = Task { @MainActor [weak self] in
                    defer {
                        self?.receiveTask = nil
                        self?.finishWorker(receiverToken)
                    }
                    await self?.receiveEvents(sessionID: sessionID)
                }
                onEvent(.sessionReady)
                if inputFinishRequested {
                    finishInput()
                }
            } catch is CancellationError {
                return
            } catch {
                guard state == .connecting, sessionGeneration == sessionID else { return }
                state = .failed(error.localizedDescription)
                onEvent(.error(error.localizedDescription))
                stop()
            }
        }
    }

    func beginInput() {
        scheduleMeteredHangUp()
        commitTask?.cancel()
        commitTask = nil
        let wasResponding = state == .responding
        let cancelResponse = wasResponding
            || responseTracker.authorizedRequestCount > 0
            || operationPipeline.hasQueuedResponseCancellation
        let previousTag = RealtimeVoicePacketTag(
            sessionID: sessionGeneration,
            utteranceGeneration: inputGeneration
        )
        outputReservations.invalidate(tag: previousTag)
        responseTracker.cancel(tag: previousTag)
        inputGeneration += 1
        let generation = inputGeneration
        let tag = RealtimeVoicePacketTag(
            sessionID: sessionGeneration,
            utteranceGeneration: generation
        )
        inputFinishRequested = false
        inputFinished = false
        inputHasAudio = false
        audioSendFailed = false
        firstAudioTimer.reset()
        if state == .listening || wasResponding {
            if wasResponding {
                onPerformanceMarker(PerformanceMarker(name: "voice.barge_in_requested", capturedAt: Date()))
            }
            if audioGraphInstalled {
                player.stop()
                player.play()
            }
        }
        if wasResponding {
            onEvent(.responseInterrupted(nil))
        }
        operationPipeline.advance(
            sessionID: sessionGeneration,
            utteranceGeneration: generation
        )
        transcriptBarrier.advance(to: tag)
        guard state != .idle, state != .connecting else { return }
        if cancelResponse {
            _ = operationPipeline.enqueue(
                .cancelResponse,
                sessionID: sessionGeneration,
                utteranceGeneration: generation
            )
        }
        _ = operationPipeline.enqueue(
            .clearInput,
            sessionID: sessionGeneration,
            utteranceGeneration: generation
        )
        do {
#if DEBUG
            if let audioStartOverrideForTesting {
                try audioStartOverrideForTesting()
            } else {
                try startAudioGraph()
                try startInputAudio()
            }
#else
            try startAudioGraph()
            try startInputAudio()
#endif
            state = .listening
        } catch {
            state = .failed(error.localizedDescription)
            onEvent(.error(error.localizedDescription))
        }
    }

    func stop() {
        guard state != .idle
                || startTask != nil
                || receiveTask != nil
                || commitTask != nil
                || shutdownTask != nil else { return }
        shutdown(failure: nil)
    }

    private func shutdown(failure: String?) {
        guard shutdownTask == nil, !shutdownRequested else {
            if failure == nil {
                state = .idle
            }
            return
        }
        shutdownRequested = true
        if let failure {
            state = .failed(failure)
        } else {
            state = .idle
        }
        sessionGeneration += 1
        inputGeneration += 1
        transcriptBarrier.advance(
            to: RealtimeVoicePacketTag(
                sessionID: sessionGeneration,
                utteranceGeneration: inputGeneration
            )
        )
        startTask?.cancel()
        startTask = nil
        let receiveTask = self.receiveTask
        receiveTask?.cancel()
        self.receiveTask = nil
        commitTask?.cancel()
        commitTask = nil
        audioSendFailed = true
        stopInputAudio()
        outputReservations.invalidateAll()
        audioEngine.stop()
        player.stop()
        let operationPipeline = self.operationPipeline
        let transport = self.transport
        let shutdownToken = startWorker(.shutdown)
        shutdownTask = Task { @MainActor [weak self] in
            defer {
                self?.finishWorker(shutdownToken)
                self?.shutdownTask = nil
            }
            await transport.close()
            await operationPipeline.stop()
            await receiveTask?.value
        }
        echoCancellationEnabled = false
        audioEngineStarted = false
        inputFinishRequested = false
        inputFinished = false
        inputHasAudio = false
        responseTracker.reset()
        firstAudioTimer.reset()
    }

    func finishInput() {
        finishInput(createsResponse: true)
    }

    func finishInputTranscribing() {
        finishInput(createsResponse: false)
    }

    private func finishInput(createsResponse: Bool) {
        inputFinishRequested = true
        guard state == .listening else { return }
        guard !inputFinished else { return }
        inputFinished = true
        firstAudioTimer.markSpeechEnd(at: DispatchTime.now().uptimeNanoseconds)
        let generation = inputGeneration
        let sessionID = sessionGeneration
        let tag = RealtimeVoicePacketTag(
            sessionID: sessionID,
            utteranceGeneration: generation
        )
        let responseRequest = createsResponse ? RealtimeVoiceResponseRequest(tag: tag) : nil
        let audioDrainTask = finishInputAudio()
        let commitToken = startWorker(.commit, tag: tag)
        commitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                commitTask = nil
                finishWorker(commitToken)
            }
            await audioDrainTask?.value
            guard self.sessionGeneration == sessionID,
                  self.inputGeneration == generation,
                  self.state == .listening,
                  self.inputFinished,
                  !self.audioSendFailed else { return }
            guard self.inputHasAudio else {
                self.transcriptBarrier.failInput(tag)
                self.state = .failed(RealtimeVoiceError.emptyInput.localizedDescription)
                self.onEvent(.error(RealtimeVoiceError.emptyInput.localizedDescription))
                return
            }
            if let responseRequest {
                guard self.responseTracker.authorize(responseRequest) else {
                    self.transcriptBarrier.failInput(tag)
                    self.state = .failed(RealtimeVoiceError.responseCorrelationUnavailable.localizedDescription)
                    self.onEvent(.error(RealtimeVoiceError.responseCorrelationUnavailable.localizedDescription))
                    return
                }
                self.state = .responding
            }
            let committedState: RealtimeVoiceSessionState = createsResponse ? .responding : .listening
            do {
                let result = responseRequest != nil
                    ? try await self.operationPipeline.commit(
                        sessionID: sessionID,
                        utteranceGeneration: generation,
                        responseRequest: responseRequest
                    )
                    : try await self.operationPipeline.commitTranscribing(
                        sessionID: sessionID,
                        utteranceGeneration: generation
                    )
                guard result == .committed,
                      self.transcriptBarrier.activeTag == tag,
                      generation == self.inputGeneration,
                      self.state == committedState,
                      !self.audioSendFailed else {
                    if let responseRequest { self.responseTracker.cancel(responseRequest) }
                    return
                }
                if let commit = self.transcriptBarrier.markInputCommitted(tag) {
                    self.publishTranscript(commit)
                }
            } catch is CancellationError {
                if let responseRequest { self.responseTracker.cancel(responseRequest) }
                return
            } catch {
                if let responseRequest { self.responseTracker.cancel(responseRequest) }
                if case .failed = self.state { return }
                guard self.transcriptBarrier.activeTag == tag,
                      generation == self.inputGeneration,
                      !self.audioSendFailed else { return }
                self.transcriptBarrier.failInput(tag)
                state = .failed(error.localizedDescription)
                onEvent(.error(error.localizedDescription))
            }
        }
    }

    func refreshAudioRoute() {
        recoverAudioRoute()
    }

    func cancelCurrentResponse() {
        guard state == .responding || responseTracker.authorizedRequestCount > 0 else { return }
        let tag = RealtimeVoicePacketTag(
            sessionID: sessionGeneration,
            utteranceGeneration: inputGeneration
        )
        outputReservations.invalidate(tag: tag, responseID: responseTracker.activeResponseID)
        responseTracker.cancel()
        if audioGraphInstalled {
            player.stop()
            player.play()
        }
        state = .listening
        onEvent(.responseInterrupted(nil))
        _ = operationPipeline.enqueue(
            .cancelResponse,
            sessionID: sessionGeneration,
            utteranceGeneration: inputGeneration
        )
    }

    private func scheduleMeteredHangUp() {
        guard RealtimeProvider(configuration.provider).billing == .perMinute else { return }
        meteredHangUp?.cancel()
        meteredHangUp = Task { [weak self, meteredIdleTimeout] in
            try? await Task.sleep(for: meteredIdleTimeout)
            guard !Task.isCancelled, let self else { return }
            if state == .responding || inputHasAudio {
                scheduleMeteredHangUp()
            } else {
                stop()
            }
        }
    }

    func speakText(_ text: String) {
        switch state {
        case .idle, .failed:
            return
        case .connecting, .listening, .responding:
            break
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        scheduleMeteredHangUp()
        let cancelResponse = state == .responding || responseTracker.authorizedRequestCount > 0
        let tag = RealtimeVoicePacketTag(
            sessionID: sessionGeneration,
            utteranceGeneration: inputGeneration
        )
        outputReservations.invalidate(tag: tag)
        if audioGraphInstalled {
            player.stop()
            player.play()
        }
        if cancelResponse {
            responseTracker.cancel(tag: tag)
            if audioGraphInstalled {
                player.stop()
                player.play()
            }
            state = .listening
            onEvent(.responseInterrupted(nil))
        }
        let generation = inputGeneration
        let responseRequest = RealtimeVoiceResponseRequest(tag: tag)
        guard responseTracker.authorize(responseRequest) else { return }
        if cancelResponse {
            _ = operationPipeline.enqueue(
                .cancelResponse,
                sessionID: sessionGeneration,
                utteranceGeneration: generation
            )
        }
        let enqueueResult = operationPipeline.enqueue(
            .sendText(text),
            sessionID: sessionGeneration,
            utteranceGeneration: generation,
            responseRequest: responseRequest
        )
        if enqueueResult != .accepted {
            responseTracker.cancel(responseRequest)
        }
    }

    private func startAudioGraph() throws {
        if !audioGraphInstalled {
            let input = audioEngine.inputNode
            do {
                try input.setVoiceProcessingEnabled(true)
                echoCancellationEnabled = input.isVoiceProcessingEnabled
            } catch {
                throw RealtimeVoiceError.echoCancellationUnavailable
            }
            guard echoCancellationEnabled else {
                throw RealtimeVoiceError.echoCancellationUnavailable
            }
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw RealtimeVoiceError.audioUnavailable
            }
            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 24_000,
                channels: 1,
                interleaved: false
            ) else { throw RealtimeVoiceError.audioUnavailable }
            audioEngine.attach(player)
            audioEngine.connect(player, to: audioEngine.mainMixerNode, format: outputFormat)
            audioGraphInstalled = true
        }
        guard !audioEngineStarted || !audioEngine.isRunning else { return }
        audioEngine.prepare()
        try audioEngine.start()
        audioEngineStarted = true
        player.play()
    }

    private func startInputAudio() throws {
        guard audioEngineStarted else { return }
        if inputTapInstalled {
            guard inputTapGeneration == inputGeneration else {
                stopInputAudio()
                return try startInputAudio()
            }
            return
        }
        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RealtimeVoiceError.audioUnavailable
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RealtimeVoiceError.audioUnavailable
        }
        inputConverter = converter
        let sessionID = sessionGeneration
        let generation = inputGeneration
        let ingress = RealtimeVoiceAudioIngress(capacity: operationPipeline.capacityLimit)
        let ingressTag = RealtimeVoicePacketTag(
            sessionID: sessionID,
            utteranceGeneration: generation
        )
        inputTapGeneration = generation
        installAudioIngressConsumer(ingress, tag: ingressTag)
        let tapped = DictationController.installTap(on: input, format: inputFormat) { buffer, _ in
            let data = RealtimePCM16Encoder.encode(buffer, converter: converter)
            guard !data.isEmpty else { return }
            ingress.yield(RealtimeVoiceAudioPacket(
                data: data,
                sessionID: sessionID,
                utteranceGeneration: generation
            ))
        }
        guard tapped else { throw RealtimeVoiceError.audioUnavailable }
        inputTapInstalled = true
    }

    private func installAudioIngressConsumer(
        _ ingress: RealtimeVoiceAudioIngress,
        tag: RealtimeVoicePacketTag
    ) {
        audioIngress = ingress
        let ingressToken = startWorker(.audioIngress, tag: tag)
        audioIngressTask = Task { @MainActor [weak self] in
            defer { self?.finishWorker(ingressToken) }
            for await packet in ingress.stream {
                guard let self,
                      self.sessionGeneration == tag.sessionID,
                      self.inputGeneration == tag.utteranceGeneration else { return }
                if ingress.consumeOverflow() {
                    self.failInputAudio(tag: tag, ingress: ingress)
                    return
                }
                self.enqueueAudio(
                    packet.data,
                    sessionID: packet.sessionID,
                    generation: packet.utteranceGeneration
                )
            }
        }
    }

    private func stopInputAudio() {
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        audioIngress?.finish()
        audioIngress = nil
        audioIngressTask?.cancel()
        audioIngressTask = nil
        inputConverter = nil
    }

    private func finishInputAudio() -> Task<Void, Never>? {
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        audioIngress?.finish()
        audioIngress = nil
        let drainTask = audioIngressTask
        audioIngressTask = nil
        inputConverter = nil
        return drainTask
    }

    private func enqueueAudio(_ data: Data, sessionID: Int, generation: Int) {
        guard sessionID == sessionGeneration,
              generation == inputGeneration,
              generation == inputTapGeneration,
              state == .listening,
              !audioSendFailed else { return }
        switch operationPipeline.enqueueAudio(
            data,
            sessionID: sessionID,
            utteranceGeneration: generation
        ) {
        case .accepted:
            inputHasAudio = true
        case .stale, .failed:
            return
        case .full:
            failInputAudio(
                tag: RealtimeVoicePacketTag(
                    sessionID: sessionID,
                    utteranceGeneration: generation
                )
            )
        }
    }

    private func failInputAudio(
        tag: RealtimeVoicePacketTag,
        ingress: RealtimeVoiceAudioIngress? = nil
    ) {
        guard tag == RealtimeVoicePacketTag(
            sessionID: sessionGeneration,
            utteranceGeneration: inputGeneration
        ) else { return }
        if let ingress, let currentIngress = audioIngress, currentIngress !== ingress { return }
        guard !audioSendFailed else { return }
        audioSendFailed = true
        transcriptBarrier.failInput(tag)
        stopInputAudio()
        onEvent(.error(RealtimeVoiceError.audioBufferFull.localizedDescription))
    }

    private func handlePipelineFailure(
        _ operation: RealtimeVoicePipeline.Operation,
        error: Error
    ) {
        if case .finishInput = operation.kind { return }
        if case .commitInput = operation.kind { return }
        guard !shutdownRequested,
              operation.tag == RealtimeVoicePacketTag(
                  sessionID: sessionGeneration,
                  utteranceGeneration: inputGeneration
              ) else { return }
        let message = error.localizedDescription
        transcriptBarrier.failInput(operation.tag)
        shutdown(failure: message)
        onEvent(.error(message))
    }

    private func receiveEvents(sessionID: Int) async {
        while !Task.isCancelled {
            let receivedGeneration = inputGeneration
            do {
                let event = try await transport.receive()
                guard !Task.isCancelled,
                      sessionGeneration == sessionID else { continue }
                switch event {
                case .transcriptDelta(let text, let correlation):
                    guard case .matched(let tag) = correlation,
                          transcriptBarrier.activeTag == tag else { continue }
                    onEvent(.transcriptDelta(text))
                case .transcriptFinal(let text, let correlation):
                    guard case .matched(let tag) = correlation else { continue }
                    if case .committed(let commit) = transcriptBarrier.offerTranscript(
                        text,
                        source: .realtime,
                        tag: tag
                    ) {
                        publishTranscript(commit)
                    }
                case .sessionReady:
                    guard inputGeneration == receivedGeneration else { continue }
                    onEvent(.sessionReady)
                case .speechStopped:
                    guard inputGeneration == receivedGeneration else { continue }
                    onEvent(.speechStopped)
                case .speechStarted:
                    guard inputGeneration == receivedGeneration else { continue }
                    if state == .responding {
                        outputReservations.invalidate(
                            tag: RealtimeVoicePacketTag(
                                sessionID: sessionID,
                                utteranceGeneration: receivedGeneration
                            ),
                            responseID: responseTracker.activeResponseID
                        )
                        if audioGraphInstalled {
                            player.stop()
                            player.play()
                        }
                        responseTracker.cancel()
                        _ = operationPipeline.enqueue(
                            .cancelResponse,
                            sessionID: sessionID,
                            utteranceGeneration: receivedGeneration
                        )
                    }
                    state = .listening
                    onEvent(.speechStarted)
                case .audio(let data, let responseID):
                    let currentTag = RealtimeVoicePacketTag(
                        sessionID: sessionID,
                        utteranceGeneration: inputGeneration
                    )
                    guard let responseID,
                          let responseTag = responseTracker.activeRequest?.tag,
                          responseTag == currentTag,
                          responseTracker.accepts(responseID, tag: currentTag) else { continue }
                    state = .responding
                    scheduleAudio(data, responseID: responseID, tag: responseTag)
                case .responseStarted(let responseID, let metadata):
                    switch responseTracker.admit(responseID, metadata: metadata) {
                    case .accepted(let request):
                        let currentTag = RealtimeVoicePacketTag(
                            sessionID: sessionID,
                            utteranceGeneration: inputGeneration
                        )
                        guard request.tag == currentTag else {
                            responseTracker.cancel(request)
                            onEvent(.error(RealtimeVoiceError.responseCorrelationUnavailable.localizedDescription))
                            continue
                        }
                        state = .responding
                        onEvent(.responseStarted(responseID))
                    case .duplicateActive:
                        continue
                    case .missingMetadata:
                        responseTracker.cancel()
                        onEvent(.error(RealtimeVoiceError.responseCorrelationUnavailable.localizedDescription))
                    case .stale, .activeResponse:
                        continue
                    }
                case .responseFinished(let responseID):
                    let currentTag = RealtimeVoicePacketTag(
                        sessionID: sessionID,
                        utteranceGeneration: inputGeneration
                    )
                    guard responseTracker.activeRequest?.tag == currentTag else { continue }
                    guard responseTracker.finish(responseID) else { continue }
                    state = .listening
                    scheduleMeteredHangUp()
                    onEvent(.responseFinished(responseID))
                case .responseInterrupted(let responseID):
                    let currentTag = RealtimeVoicePacketTag(
                        sessionID: sessionID,
                        utteranceGeneration: inputGeneration
                    )
                    guard let responseTag = responseTracker.activeRequest?.tag,
                          responseTag == currentTag else { continue }
                    guard responseTracker.interrupt(responseID) else { continue }
                    outputReservations.invalidate(
                        tag: responseTag,
                        responseID: responseID
                    )
                    if audioGraphInstalled {
                        player.stop()
                        player.play()
                    }
                    state = .listening
                    onEvent(.responseInterrupted(responseID))
                case .assistantTranscriptDelta(let text, let responseID):
                    let currentTag = RealtimeVoicePacketTag(
                        sessionID: sessionID,
                        utteranceGeneration: inputGeneration
                    )
                    guard responseTracker.accepts(responseID, tag: currentTag) else { continue }
                    onEvent(.assistantTranscriptDelta(text, responseID: responseID))
                case .assistantTranscriptFinal(let text, let responseID):
                    let currentTag = RealtimeVoicePacketTag(
                        sessionID: sessionID,
                        utteranceGeneration: inputGeneration
                    )
                    guard responseTracker.accepts(responseID, tag: currentTag) else { continue }
                    onEvent(.assistantTranscriptFinal(text, responseID: responseID))
                case .error(let message):
                    guard inputGeneration == receivedGeneration else { continue }
                    transcriptBarrier.failInput(RealtimeVoicePacketTag(
                        sessionID: sessionID,
                        utteranceGeneration: receivedGeneration
                    ))
                    onEvent(.error(message))
                case .ignored:
                    continue
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, sessionGeneration == sessionID else { return }
                state = .failed(error.localizedDescription)
                onEvent(.error(error.localizedDescription))
                return
            }
        }
    }

    func submitTranscript(
        _ text: String,
        source: RealtimeVoiceTranscriptSource
    ) {
        let tag = RealtimeVoicePacketTag(
            sessionID: sessionGeneration,
            utteranceGeneration: inputGeneration
        )
        guard case .committed(let commit) = transcriptBarrier.offerTranscript(
            text,
            source: source,
            tag: tag
        ) else { return }
        publishTranscript(commit)
    }

    private func publishTranscript(_ commit: RealtimeVoiceTranscriptCommit) {
        guard transcriptBarrier.dispatch(commit) == .dispatched else { return }
        onEvent(.transcriptFinal(commit.text))
    }

    private func scheduleAudio(
        _ data: Data,
        responseID: String,
        tag: RealtimeVoicePacketTag
    ) {
        guard !data.isEmpty,
              data.count.isMultiple(of: MemoryLayout<Int16>.size) else { return }
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard let reservation = outputReservations.reserve(
            tag: tag,
            responseID: responseID,
            frameCount: frameCount
        ) else {
            failOutputAudio(responseID: responseID, error: .audioOutputBufferFull)
            return
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let channel = buffer.int16ChannelData?[0] else {
            outputReservations.complete(reservation)
            failOutputAudio(responseID: responseID, error: .audioUnavailable)
            return
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let copied = data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            memcpy(channel, baseAddress, data.count)
            return true
        }
        guard copied else {
            outputReservations.complete(reservation)
            failOutputAudio(responseID: responseID, error: .audioUnavailable)
            return
        }
#if DEBUG
        if let outputScheduleOverrideForTesting {
            outputScheduleOverrideForTesting(frameCount) { [weak self] in
                self?.completeOutputReservation(reservation)
            }
        } else {
            player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.completeOutputReservation(reservation)
                }
            }
        }
#else
        player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.completeOutputReservation(reservation)
            }
        }
#endif
        if let sample = firstAudioTimer.markFirstAudio(at: DispatchTime.now().uptimeNanoseconds) {
            onPerformanceSample(sample)
        }
    }

    private func completeOutputReservation(_ reservation: RealtimeVoiceOutputReservation) {
        outputReservations.complete(reservation)
    }

    private func failOutputAudio(responseID: String, error: RealtimeVoiceError) {
        let tag = RealtimeVoicePacketTag(
            sessionID: sessionGeneration,
            utteranceGeneration: inputGeneration
        )
        outputReservations.invalidate(tag: tag)
        guard responseTracker.accepts(responseID) else { return }
        responseTracker.cancel()
        if audioGraphInstalled {
            player.stop()
            player.play()
        }
        state = .listening
        onEvent(.responseInterrupted(nil))
        _ = operationPipeline.enqueue(
            .cancelResponse,
            sessionID: sessionGeneration,
            utteranceGeneration: inputGeneration
        )
        onEvent(.error(error.localizedDescription))
    }

    private func recoverAudioRoute() {
        guard state == .listening || state == .responding else { return }
        guard state != .listening || (!inputFinishRequested && !inputFinished) else { return }
        let wasListening = state == .listening
        stopInputAudio()
        outputReservations.invalidateAll()
        audioEngine.stop()
        audioEngineStarted = false
        if audioGraphInstalled {
            player.stop()
        }
        do {
            try startAudioGraph()
            if wasListening { try startInputAudio() }
        } catch {
            state = .failed(error.localizedDescription)
            onEvent(.error(error.localizedDescription))
        }
    }

    #if DEBUG
    func receiveFixtureEvents() async {
        beginEmptyInputFixture()
        await receiveEvents(sessionID: sessionGeneration)
    }

    func receiveCurrentFixtureEvents() async {
        await receiveEvents(sessionID: sessionGeneration)
    }

    func beginEmptyInputFixture() {
        sessionGeneration += 1
        inputGeneration += 1
        operationPipeline.advance(sessionID: sessionGeneration, utteranceGeneration: inputGeneration)
        transcriptBarrier.advance(to: RealtimeVoicePacketTag(
            sessionID: sessionGeneration,
            utteranceGeneration: inputGeneration
        ))
        state = .listening
    }

    func installAudioIngressFixtureForTesting(_ ingress: RealtimeVoiceAudioIngress) {
        inputTapGeneration = inputGeneration
        installAudioIngressConsumer(
            ingress,
            tag: RealtimeVoicePacketTag(
                sessionID: sessionGeneration,
                utteranceGeneration: inputGeneration
            )
        )
    }
    #endif

    private func startWorker(
        _ role: RealtimeWorkerRole,
        tag: RealtimeVoicePacketTag? = nil
    ) -> RealtimeWorkerToken {
        let resolvedTag = tag ?? RealtimeVoicePacketTag(
            sessionID: sessionGeneration,
            utteranceGeneration: inputGeneration
        )
        let (token, snapshot) = taskLedger.start(
            role,
            sessionGeneration: resolvedTag.sessionID,
            utteranceGeneration: resolvedTag.utteranceGeneration
        )
        onTaskSnapshot(snapshot)
        return token
    }

    private func finishWorker(_ token: RealtimeWorkerToken) {
        guard let snapshot = taskLedger.finish(token) else { return }
        onTaskSnapshot(snapshot)
    }

    private func recordPipelineWorker(
        _ role: RealtimeWorkerRole,
        started: Bool,
        tag: RealtimeVoicePacketTag
    ) {
        if started {
            pipelineWorkerTokens[role, default: []].append(startWorker(role, tag: tag))
            return
        }
        guard var tokens = pipelineWorkerTokens[role], !tokens.isEmpty else { return }
        let token = tokens.removeFirst()
        pipelineWorkerTokens[role] = tokens.isEmpty ? nil : tokens
        finishWorker(token)
    }
}

private enum RealtimePCM16Encoder {
    static func encode(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) -> Data {
        guard buffer.frameLength > 0 else { return Data() }
        let ratio = converter.outputFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return Data()
        }
        var supplied = false
        var conversionError: NSError?
        _ = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil,
              converted.frameLength > 0,
              let channel = converted.int16ChannelData?[0] else { return Data() }
        return Data(bytes: channel, count: Int(converted.frameLength) * MemoryLayout<Int16>.size)
    }
}
