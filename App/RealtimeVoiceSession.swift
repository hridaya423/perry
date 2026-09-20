import AVFoundation
import Foundation
import PerryCore

enum RealtimeVoiceProtocolMode: String, CaseIterable, Sendable {
    case automatic
    case openAIGA
    case openAIBeta
    case compatible

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .openAIGA: return "OpenAI current"
        case .openAIBeta: return "OpenAI beta"
        case .compatible: return "Compatible endpoint"
        }
    }
}

enum RealtimeVoiceSessionState: Equatable {
    case idle
    case connecting
    case listening
    case responding
    case failed(String)
}

enum RealtimeVoiceEvent: Equatable, Sendable {
    case sessionReady
    case speechStarted
    case speechStopped
    case transcriptDelta(String)
    case transcriptFinal(String)
    case assistantTranscriptDelta(String, responseID: String?)
    case assistantTranscriptFinal(String, responseID: String?)
    case responseStarted(String?)
    case responseFinished(String?)
    case responseInterrupted(String?)
    case audio(Data, responseID: String?)
    case ignored
    case error(String)
}

struct RealtimeFirstAudioTimer {
    private var speechEndedAt: UInt64?

    mutating func markSpeechEnd(at timestamp: UInt64) {
        speechEndedAt = timestamp
    }

    mutating func markFirstAudio(at timestamp: UInt64) -> PerformanceSample? {
        guard let speechEndedAt, timestamp >= speechEndedAt else { return nil }
        self.speechEndedAt = nil
        return PerformanceSample(
            metricID: "voice.realtime_first_audio",
            collector: "perry.app.realtime-first-audio.v1",
            unit: "ms",
            value: Double(timestamp - speechEndedAt) / 1_000_000,
            scenario: "speech end to first scheduled realtime audio"
        )
    }

    mutating func reset() {
        speechEndedAt = nil
    }
}

enum RealtimeWorkerRole: String, CaseIterable, Sendable {
    case connection
    case receiver
    case commit
    case audioIngress = "audio_ingress"
    case shutdown
    case pipeline
    case cancellationCleanup = "cancellation_cleanup"
    case routeRecovery = "route_recovery"
}

struct RealtimeWorkerToken: Hashable, Sendable {
    let id: UUID
    let role: RealtimeWorkerRole
    let sessionGeneration: Int
    let utteranceGeneration: Int
}

struct RealtimeTaskLedger {
    private var activeWorkers: [UUID: RealtimeWorkerRole] = [:]
    private var startedByRole: [RealtimeWorkerRole: Int] = [:]
    private var finishedByRole: [RealtimeWorkerRole: Int] = [:]
    private var sequence = 0

    mutating func start(
        _ role: RealtimeWorkerRole,
        sessionGeneration: Int,
        utteranceGeneration: Int
    ) -> (RealtimeWorkerToken, RealtimeTaskSnapshot) {
        let token = RealtimeWorkerToken(
            id: UUID(),
            role: role,
            sessionGeneration: sessionGeneration,
            utteranceGeneration: utteranceGeneration
        )
        activeWorkers[token.id] = role
        startedByRole[role, default: 0] += 1
        return (token, snapshot(sessionGeneration: sessionGeneration, utteranceGeneration: utteranceGeneration))
    }

    mutating func finish(_ token: RealtimeWorkerToken) -> RealtimeTaskSnapshot? {
        guard activeWorkers.removeValue(forKey: token.id) == token.role else { return nil }
        finishedByRole[token.role, default: 0] += 1
        return snapshot(
            sessionGeneration: token.sessionGeneration,
            utteranceGeneration: token.utteranceGeneration
        )
    }

    private mutating func snapshot(
        sessionGeneration: Int,
        utteranceGeneration: Int
    ) -> RealtimeTaskSnapshot {
        sequence += 1
        let activeByRole = Dictionary(grouping: activeWorkers.values, by: { $0 })
            .mapValues(\.count)
            .stringKeys
        return RealtimeTaskSnapshot(
            sequence: sequence,
            sessionGeneration: sessionGeneration,
            utteranceGeneration: utteranceGeneration,
            active: activeWorkers.count,
            started: startedByRole.values.reduce(0, +),
            finished: finishedByRole.values.reduce(0, +),
            activeByRole: activeByRole,
            startedByRole: startedByRole.stringKeys,
            finishedByRole: finishedByRole.stringKeys
        )
    }
}

private extension Dictionary where Key == RealtimeWorkerRole, Value == Int {
    var stringKeys: [String: Int] {
        reduce(into: [:]) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
    }
}

struct RealtimeVoiceConfiguration: Equatable, Sendable {
    let endpoint: URL
    let model: String
    let voice: String
    let responseSpeed: Double
    let instructions: String
    let protocolMode: RealtimeVoiceProtocolMode
    let inputLanguage: String?

    init(
        endpoint: URL,
        model: String,
        voice: String = "marin",
        responseSpeed: Double = 1,
        instructions: String = "You are Perry, a concise and helpful desktop voice assistant. Speak naturally and keep replies short unless the user asks for detail.",
        protocolMode: RealtimeVoiceProtocolMode = .automatic,
        inputLanguage: String? = nil
    ) {
        self.endpoint = endpoint
        self.model = model
        let normalizedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voice = normalizedVoice.isEmpty ? "marin" : normalizedVoice
        self.responseSpeed = min(max(responseSpeed, 0.25), 1.5)
        self.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        self.protocolMode = protocolMode
        let normalizedLanguage = inputLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.inputLanguage = normalizedLanguage?.isEmpty == true ? nil : normalizedLanguage
    }
}

enum RealtimeVoiceError: Error, LocalizedError {
    case missingAPIKey
    case echoCancellationUnavailable
    case audioUnavailable
    case audioBufferFull
    case audioOutputBufferFull
    case responseCorrelationUnavailable
    case malformedProviderMessage
    case emptyInput
    case inputCorrelationLimitReached

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No realtime voice provider key is configured."
        case .echoCancellationUnavailable:
            return "macOS could not enable microphone echo cancellation."
        case .audioUnavailable:
            return "macOS could not start the realtime audio route."
        case .audioBufferFull:
            return "Realtime voice input is arriving faster than the connection can send it."
        case .audioOutputBufferFull:
            return "Realtime voice response audio exceeded its playback buffer limit; try again."
        case .responseCorrelationUnavailable:
            return "Realtime voice response correlation metadata was missing or unknown; the response was not admitted."
        case .malformedProviderMessage:
            return "The realtime voice provider returned an unreadable event."
        case .emptyInput:
            return "No microphone audio was captured for that turn."
        case .inputCorrelationLimitReached:
            return "Realtime voice reached its input correlation limit; start a new session."
        }
    }
}

struct RealtimeVoicePacketTag: Equatable, Hashable, Sendable {
    let sessionID: Int
    let utteranceGeneration: Int

    init(sessionID: Int, utteranceGeneration: Int) {
        self.sessionID = sessionID
        self.utteranceGeneration = utteranceGeneration
    }
}

struct RealtimeVoiceResponseRequest: Equatable, Sendable {
    static let metadataKey = "perry_response_request_nonce"

    let tag: RealtimeVoicePacketTag
    let nonce: String

    init(tag: RealtimeVoicePacketTag, nonce: String = UUID().uuidString) {
        self.tag = tag
        self.nonce = nonce
    }

    var metadata: [String: String] {
        [Self.metadataKey: nonce]
    }
}

struct RealtimeVoiceOutputReservation: Equatable, Sendable {
    let token: UUID
    let tag: RealtimeVoicePacketTag
    let responseID: String
    let frameCount: Int
}

@MainActor
final class RealtimeVoiceOutputReservationLedger {
    static let maximumFrames = 720_000
    static let maximumBuffers = 2_048

    private var reservations: [UUID: RealtimeVoiceOutputReservation] = [:]
    private(set) var reservedFrames = 0

    var reservedBuffers: Int { reservations.count }
    var allReservations: [RealtimeVoiceOutputReservation] { Array(reservations.values) }

    func reserve(
        tag: RealtimeVoicePacketTag,
        responseID: String,
        frameCount: Int
    ) -> RealtimeVoiceOutputReservation? {
        guard !responseID.isEmpty,
              frameCount > 0,
              frameCount <= Self.maximumFrames - reservedFrames,
              reservations.count < Self.maximumBuffers else { return nil }
        let reservation = RealtimeVoiceOutputReservation(
            token: UUID(),
            tag: tag,
            responseID: responseID,
            frameCount: frameCount
        )
        reservations[reservation.token] = reservation
        reservedFrames += frameCount
        return reservation
    }

    func complete(_ reservation: RealtimeVoiceOutputReservation) {
        guard let current = reservations[reservation.token], current == reservation else { return }
        reservations.removeValue(forKey: reservation.token)
        reservedFrames -= current.frameCount
    }

    func invalidate(tag: RealtimeVoicePacketTag, responseID: String? = nil) {
        let matches = reservations.values.filter { reservation in
            reservation.tag == tag && (responseID == nil || reservation.responseID == responseID)
        }
        for reservation in matches {
            complete(reservation)
        }
    }

    func invalidateAll() {
        let current = Array(reservations.values)
        for reservation in current {
            complete(reservation)
        }
    }
}

enum RealtimeVoiceTranscriptCorrelation: Equatable, Sendable {
    case matched(RealtimeVoicePacketTag)
    case uncorrelated(itemID: String?)
}

enum RealtimeVoiceTransportEvent: Equatable, Sendable {
    case sessionReady
    case speechStarted
    case speechStopped
    case transcriptDelta(String, correlation: RealtimeVoiceTranscriptCorrelation)
    case transcriptFinal(String, correlation: RealtimeVoiceTranscriptCorrelation)
    case assistantTranscriptDelta(String, responseID: String?)
    case assistantTranscriptFinal(String, responseID: String?)
    case responseStarted(String?, metadata: [String: String]?)
    case responseFinished(String?)
    case responseInterrupted(String?)
    case audio(Data, responseID: String?)
    case ignored
    case error(String)
}

struct RealtimeVoiceTransportCorrelation: Equatable, Sendable {
    static let limit = 128

    private var pendingCommitTags: [RealtimeVoicePacketTag] = []
    private var itemTags: [String: RealtimeVoicePacketTag] = [:]

    var pendingCommitCount: Int { pendingCommitTags.count }
    var correlatedItemCount: Int { itemTags.count }
    var isAtCapacity: Bool { itemTags.count >= Self.limit }

    mutating func enqueueCommit(tag: RealtimeVoicePacketTag) -> Bool {
        guard pendingCommitTags.count < Self.limit,
              itemTags.count < Self.limit else { return false }
        pendingCommitTags.append(tag)
        return true
    }

    mutating func removePendingCommit(tag: RealtimeVoicePacketTag) {
        guard let index = pendingCommitTags.firstIndex(of: tag) else { return }
        pendingCommitTags.remove(at: index)
    }

    mutating func acknowledge(itemID: String?) -> RealtimeVoicePacketTag? {
        guard let itemID, !itemID.isEmpty else { return nil }
        if let existing = itemTags[itemID] { return existing }
        guard itemTags.count < Self.limit else { return nil }
        guard !pendingCommitTags.isEmpty else { return nil }
        let tag = pendingCommitTags.removeFirst()
        itemTags[itemID] = tag
        return tag
    }

    func transcriptCorrelation(for itemID: String?) -> RealtimeVoiceTranscriptCorrelation {
        guard let itemID, !itemID.isEmpty, let tag = itemTags[itemID] else {
            return .uncorrelated(itemID: itemID)
        }
        return .matched(tag)
    }
}

enum RealtimeVoiceTranscriptSource: Equatable, Sendable {
    case realtime
    case fallback
    case rerouted
}

struct RealtimeVoiceTranscriptCommit: Equatable, Sendable {
    let tag: RealtimeVoicePacketTag
    let text: String
    let source: RealtimeVoiceTranscriptSource
}

struct RealtimeVoiceResponseTracker: Equatable, Sendable {
    enum Admission: Equatable {
        case accepted(RealtimeVoiceResponseRequest)
        case missingMetadata
        case activeResponse
        case duplicateActive
        case stale
    }

    private(set) var activeResponseID: String?
    private(set) var activeRequest: RealtimeVoiceResponseRequest?
    private(set) var pendingRequest: RealtimeVoiceResponseRequest?
    private var ignoredResponseIDs: [String] = []
    private static let ignoredResponseLimit = 128

    var ignoredResponseCount: Int { ignoredResponseIDs.count }
    var authorizedRequestCount: Int {
        pendingRequest == nil && activeRequest == nil ? 0 : 1
    }

    mutating func authorize(_ request: RealtimeVoiceResponseRequest) -> Bool {
        guard !request.nonce.isEmpty,
              pendingRequest == nil,
              activeRequest == nil,
              activeResponseID == nil else { return false }
        pendingRequest = request
        return true
    }

    mutating func admit(
        _ responseID: String?,
        metadata: [String: String]?
    ) -> Admission {
        guard let responseID, !responseID.isEmpty else {
            return pendingRequest == nil ? .stale : .missingMetadata
        }
        guard activeResponseID == nil else {
            if responseID == activeResponseID,
               metadata?[RealtimeVoiceResponseRequest.metadataKey] == activeRequest?.nonce {
                return .duplicateActive
            }
            if responseID == activeResponseID {
                return .activeResponse
            }
            ignore(responseID)
            return .activeResponse
        }
        guard !ignoredResponseIDs.contains(responseID) else { return .stale }
        guard let nonce = metadata?[RealtimeVoiceResponseRequest.metadataKey], !nonce.isEmpty else {
            ignore(responseID)
            return pendingRequest == nil ? .stale : .missingMetadata
        }
        guard let pendingRequest, pendingRequest.nonce == nonce else {
            ignore(responseID)
            return .stale
        }
        self.pendingRequest = nil
        activeResponseID = responseID
        activeRequest = pendingRequest
        return .accepted(pendingRequest)
    }

    mutating func cancel() {
        ignore(activeResponseID)
        activeResponseID = nil
        activeRequest = nil
        pendingRequest = nil
    }

    mutating func cancel(tag: RealtimeVoicePacketTag) {
        if pendingRequest?.tag == tag {
            pendingRequest = nil
        }
        guard activeRequest?.tag == tag else { return }
        ignore(activeResponseID)
        activeResponseID = nil
        activeRequest = nil
    }

    mutating func cancel(_ request: RealtimeVoiceResponseRequest) {
        if pendingRequest == request {
            pendingRequest = nil
        }
        guard activeRequest == request else { return }
        ignore(activeResponseID)
        activeResponseID = nil
        activeRequest = nil
    }

    func accepts(_ responseID: String?) -> Bool {
        guard let responseID, !responseID.isEmpty,
              let activeResponseID else { return false }
        guard !ignoredResponseIDs.contains(responseID) else { return false }
        return activeResponseID == responseID
    }

    func accepts(_ responseID: String?, tag: RealtimeVoicePacketTag) -> Bool {
        guard activeRequest?.tag == tag else { return false }
        return accepts(responseID)
    }

    mutating func finish(_ responseID: String?) -> Bool {
        guard accepts(responseID) else { return false }
        ignore(responseID ?? activeResponseID)
        activeResponseID = nil
        activeRequest = nil
        return true
    }

    mutating func interrupt(_ responseID: String?) -> Bool {
        guard accepts(responseID) else { return false }
        ignore(responseID ?? activeResponseID)
        activeResponseID = nil
        activeRequest = nil
        return true
    }

    mutating func reset() {
        activeResponseID = nil
        activeRequest = nil
        pendingRequest = nil
        ignoredResponseIDs.removeAll()
    }

    private mutating func ignore(_ responseID: String?) {
        guard let responseID, !ignoredResponseIDs.contains(responseID) else { return }
        ignoredResponseIDs.append(responseID)
        if ignoredResponseIDs.count > Self.ignoredResponseLimit {
            ignoredResponseIDs.removeFirst(ignoredResponseIDs.count - Self.ignoredResponseLimit)
        }
    }
}

@MainActor
final class RealtimeVoiceCommitBarrier {
    enum TranscriptResult: Equatable {
        case pending
        case committed(RealtimeVoiceTranscriptCommit)
        case duplicate
        case stale
        case failed
    }

    enum DispatchResult: Equatable {
        case dispatched
        case duplicate
        case stale
    }

    private(set) var activeTag: RealtimeVoicePacketTag?
    private var inputCommitComplete = Set<RealtimeVoicePacketTag>()
    private var committedTranscript: Set<RealtimeVoicePacketTag> = []
    private var dispatchedTranscript: Set<RealtimeVoicePacketTag> = []
    private var failedInput = Set<RealtimeVoicePacketTag>()
    private var pendingTranscripts: [RealtimeVoicePacketTag: RealtimeVoiceTranscriptCommit] = [:]

    func advance(to tag: RealtimeVoicePacketTag) {
        guard activeTag == nil || isNewer(tag, than: activeTag!) else { return }
        activeTag = tag
        inputCommitComplete = inputCommitComplete.filter { $0 == tag }
        committedTranscript = committedTranscript.filter { $0 == tag }
        dispatchedTranscript = dispatchedTranscript.filter { $0 == tag }
        failedInput = failedInput.filter { $0 == tag }
        pendingTranscripts = pendingTranscripts.filter { $0.key == tag }
    }

    func markInputCommitted(_ tag: RealtimeVoicePacketTag) -> RealtimeVoiceTranscriptCommit? {
        guard tag == activeTag, !failedInput.contains(tag) else { return nil }
        inputCommitComplete.insert(tag)
        guard let pending = pendingTranscripts.removeValue(forKey: tag) else { return nil }
        return commit(pending)
    }

    func failInput(_ tag: RealtimeVoicePacketTag) {
        guard tag == activeTag else { return }
        failedInput.insert(tag)
        pendingTranscripts.removeValue(forKey: tag)
    }

    func offerTranscript(
        _ text: String,
        source: RealtimeVoiceTranscriptSource,
        tag: RealtimeVoicePacketTag
    ) -> TranscriptResult {
        guard tag == activeTag else { return .stale }
        guard !failedInput.contains(tag) else { return .failed }
        guard !committedTranscript.contains(tag) else { return .duplicate }
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return .stale }
        let candidate = RealtimeVoiceTranscriptCommit(tag: tag, text: normalizedText, source: source)
        if source == .realtime, !inputCommitComplete.contains(tag) {
            pendingTranscripts[tag] = pendingTranscripts[tag] ?? candidate
            return .pending
        }
        guard let committed = commit(candidate) else { return .duplicate }
        return .committed(committed)
    }

    func dispatch(_ commit: RealtimeVoiceTranscriptCommit) -> DispatchResult {
        guard commit.tag == activeTag,
              committedTranscript.contains(commit.tag) else { return .stale }
        guard dispatchedTranscript.insert(commit.tag).inserted else { return .duplicate }
        return .dispatched
    }

    private func commit(_ candidate: RealtimeVoiceTranscriptCommit) -> RealtimeVoiceTranscriptCommit? {
        guard committedTranscript.insert(candidate.tag).inserted else { return nil }
        return candidate
    }

    private func isNewer(_ tag: RealtimeVoicePacketTag, than previous: RealtimeVoicePacketTag) -> Bool {
        tag.sessionID > previous.sessionID
            || (tag.sessionID == previous.sessionID && tag.utteranceGeneration > previous.utteranceGeneration)
    }
}

protocol RealtimeVoiceTransport: Sendable {
    func connect() async throws
    func sendAudio(_ data: Data) async throws
    func finishInput(tag: RealtimeVoicePacketTag, request: RealtimeVoiceResponseRequest) async throws
    func cancelResponse() async throws
    func sendText(_ text: String, request: RealtimeVoiceResponseRequest) async throws
    func clearInput() async throws
    func receive() async throws -> RealtimeVoiceTransportEvent
    func close() async
}

extension RealtimeVoiceTransport {
    func clearInput() async throws {}
}

@MainActor
final class RealtimeVoicePipeline {
    enum EnqueueResult: Equatable {
        case accepted
        case stale
        case full
        case failed
    }

    enum CommitResult: Equatable {
        case committed
        case superseded
    }

    enum OperationKind: Equatable, Sendable {
        case audio(Data)
        case clearInput
        case cancelResponse
        case finishInput
        case sendText(String)
    }

    struct Operation: Equatable, Sendable {
        let sessionID: Int
        let utteranceGeneration: Int
        var generation: Int { utteranceGeneration }
        let kind: OperationKind
        let responseRequest: RealtimeVoiceResponseRequest?

        init(
            sessionID: Int = 0,
            utteranceGeneration: Int,
            kind: OperationKind,
            responseRequest: RealtimeVoiceResponseRequest? = nil
        ) {
            self.sessionID = sessionID
            self.utteranceGeneration = utteranceGeneration
            self.kind = kind
            self.responseRequest = responseRequest
        }

        init(
            sessionID: Int = 0,
            generation: Int,
            kind: OperationKind,
            responseRequest: RealtimeVoiceResponseRequest? = nil
        ) {
            self.init(
                sessionID: sessionID,
                utteranceGeneration: generation,
                kind: kind,
                responseRequest: responseRequest
            )
        }
    }

    typealias Executor = @Sendable (Operation) async throws -> Void
    typealias FailureHandler = @MainActor (Operation, Error) -> Void
    typealias WorkerHandler = @MainActor (RealtimeWorkerRole, Bool, RealtimeVoicePacketTag) -> Void

    private let capacity: Int
    private let executor: Executor
    private var queue: [Operation] = []
    private var activeTag = RealtimeVoicePacketTag(sessionID: 0, utteranceGeneration: 0)
    private var worker: Task<Void, Never>?
    private var commitEnqueued: Set<RealtimeVoicePacketTag> = []
    private var commitCompleted: Set<RealtimeVoicePacketTag> = []
    private var commitWaiters: [RealtimeVoicePacketTag: [UUID: CheckedContinuation<CommitResult, Error>]] = [:]
    private var failures: [RealtimeVoicePacketTag: Error] = [:]
    private var isStopped = false
    var onFailure: FailureHandler?
    var onWorker: WorkerHandler?

    var pendingCount: Int { queue.count }
    var capacityLimit: Int { capacity }
    var currentTag: RealtimeVoicePacketTag { activeTag }
    var hasQueuedResponseCancellation: Bool {
        queue.contains { $0.kind == .cancelResponse }
    }

    init(capacity: Int = 32, executor: @escaping Executor) {
        self.capacity = max(capacity, 1)
        self.executor = executor
    }

    func advance(to generation: Int) {
        advance(sessionID: activeTag.sessionID, utteranceGeneration: generation)
    }

    func advance(sessionID: Int, generation: Int) {
        advance(sessionID: sessionID, utteranceGeneration: generation)
    }

    func advance(sessionID: Int, utteranceGeneration: Int) {
        let nextTag = RealtimeVoicePacketTag(
            sessionID: sessionID,
            utteranceGeneration: utteranceGeneration
        )
        guard isNewerOrEqual(nextTag, than: activeTag), !isStopped else { return }
        guard nextTag != activeTag else { return }
        activeTag = nextTag
        queue.removeAll { $0.tag != nextTag }
        failures = failures.filter { $0.key == nextTag }
        commitEnqueued = commitEnqueued.filter { $0 == nextTag }
        commitCompleted = commitCompleted.filter { $0 == nextTag }
        resolveSupersededCommits(before: nextTag)
    }

    func enqueueAudio(_ data: Data, generation: Int) -> EnqueueResult {
        enqueueAudio(data, sessionID: activeTag.sessionID, utteranceGeneration: generation)
    }

    func enqueueAudio(
        _ data: Data,
        sessionID: Int,
        generation: Int
    ) -> EnqueueResult {
        enqueueAudio(data, sessionID: sessionID, utteranceGeneration: generation)
    }

    func enqueueAudio(
        _ data: Data,
        sessionID: Int,
        utteranceGeneration: Int
    ) -> EnqueueResult {
        guard !data.isEmpty else { return .accepted }
        let tag = RealtimeVoicePacketTag(
            sessionID: sessionID,
            utteranceGeneration: utteranceGeneration
        )
        guard tag == activeTag else { return .stale }
        guard !isStopped else { return .stale }
        guard failures[tag] == nil else { return .failed }
        guard queue.count < capacity else { return .full }
        append(Operation(sessionID: sessionID, utteranceGeneration: utteranceGeneration, kind: .audio(data)))
        return .accepted
    }

    func enqueue(_ kind: OperationKind, generation: Int) -> EnqueueResult {
        enqueue(
            kind,
            sessionID: activeTag.sessionID,
            utteranceGeneration: generation
        )
    }

    func enqueue(
        _ kind: OperationKind,
        sessionID: Int,
        generation: Int,
        responseRequest: RealtimeVoiceResponseRequest? = nil
    ) -> EnqueueResult {
        enqueue(
            kind,
            sessionID: sessionID,
            utteranceGeneration: generation,
            responseRequest: responseRequest
        )
    }

    func enqueue(
        _ kind: OperationKind,
        sessionID: Int,
        utteranceGeneration: Int,
        responseRequest: RealtimeVoiceResponseRequest? = nil
    ) -> EnqueueResult {
        let tag = RealtimeVoicePacketTag(
            sessionID: sessionID,
            utteranceGeneration: utteranceGeneration
        )
        guard tag == activeTag else { return .stale }
        guard !isStopped else { return .stale }
        guard failures[tag] == nil else { return .failed }
        if queue.count >= capacity {
            guard kind.isPriorityControl,
                  let audioIndex = queue.firstIndex(where: { $0.kind.isAudio }) else {
                return .full
            }
            queue.remove(at: audioIndex)
        }
        append(Operation(
            sessionID: sessionID,
            utteranceGeneration: utteranceGeneration,
            kind: kind,
            responseRequest: responseRequest
        ))
        return .accepted
    }

    func commit(generation: Int) async throws -> CommitResult {
        try await commit(sessionID: activeTag.sessionID, utteranceGeneration: generation)
    }

    func commit(sessionID: Int, generation: Int) async throws -> CommitResult {
        try await commit(sessionID: sessionID, utteranceGeneration: generation)
    }

    func commit(
        sessionID: Int,
        utteranceGeneration: Int,
        responseRequest: RealtimeVoiceResponseRequest? = nil
    ) async throws -> CommitResult {
        try Task.checkCancellation()
        let tag = RealtimeVoicePacketTag(
            sessionID: sessionID,
            utteranceGeneration: utteranceGeneration
        )
        guard tag == activeTag, !isStopped else { return .superseded }
        if commitCompleted.contains(tag) { return .committed }
        if let failure = failures[tag] { throw failure }
        if !commitEnqueued.contains(tag) {
            let request = responseRequest ?? RealtimeVoiceResponseRequest(tag: tag)
            guard request.tag == tag else { throw RealtimeVoiceError.responseCorrelationUnavailable }
            commitEnqueued.insert(tag)
            append(Operation(
                sessionID: sessionID,
                utteranceGeneration: utteranceGeneration,
                kind: .finishInput,
                responseRequest: request
            ))
        }
        return try await waitForCommit(tag: tag)
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        queue.removeAll()
        resolveAllCommits(as: .superseded)
        let worker = self.worker
        worker?.cancel()
        await worker?.value
        self.worker = nil
    }

    private func append(_ operation: Operation) {
        queue.append(operation)
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !isStopped else { return }
        let tag = activeTag
        onWorker?(.pipeline, true, tag)
        worker = Task { @MainActor [weak self] in
            defer { self?.onWorker?(.pipeline, false, tag) }
            await self?.drain()
        }
    }

    private func drain() async {
        defer {
            worker = nil
            if !Task.isCancelled, !isStopped, !queue.isEmpty {
                startWorkerIfNeeded()
            }
        }
        while !Task.isCancelled {
            guard let operation = nextOperation() else { return }
            do {
                try await executor(operation)
                if case .finishInput = operation.kind,
                   operation.tag == activeTag {
                    commitCompleted.insert(operation.tag)
                    resolveCommit(operation.tag, result: .committed)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, operation.tag == activeTag else { continue }
                failures[operation.tag] = error
                queue.removeAll { $0.tag == operation.tag }
                resolveCommit(operation.tag, error: error)
                onFailure?(operation, error)
            }
        }
    }

    private func nextOperation() -> Operation? {
        while !queue.isEmpty {
            let operation = queue.removeFirst()
            guard operation.tag == activeTag else { continue }
            return operation
        }
        return nil
    }

    private func waitForCommit(tag: RealtimeVoicePacketTag) async throws -> CommitResult {
        let waiterID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                commitWaiters[tag, default: [:]][waiterID] = continuation
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.onWorker?(.cancellationCleanup, true, tag)
                defer { self?.onWorker?(.cancellationCleanup, false, tag) }
                self?.cancelCommitWaiter(tag: tag, id: waiterID)
            }
        })
    }

    private func cancelCommitWaiter(tag: RealtimeVoicePacketTag, id: UUID) {
        guard var waiters = commitWaiters[tag], let waiter = waiters.removeValue(forKey: id) else { return }
        if waiters.isEmpty {
            commitWaiters.removeValue(forKey: tag)
        } else {
            commitWaiters[tag] = waiters
        }
        waiter.resume(throwing: CancellationError())
    }

    private func resolveCommit(_ tag: RealtimeVoicePacketTag, result: CommitResult) {
        guard let waiters = commitWaiters.removeValue(forKey: tag) else { return }
        for waiter in waiters.values {
            waiter.resume(returning: result)
        }
    }

    private func resolveCommit(_ tag: RealtimeVoicePacketTag, error: Error) {
        guard let waiters = commitWaiters.removeValue(forKey: tag) else { return }
        for waiter in waiters.values {
            waiter.resume(throwing: error)
        }
    }

    private func resolveSupersededCommits(before tag: RealtimeVoicePacketTag) {
        let superseded = commitWaiters.keys.filter { isOlder($0, than: tag) }
        for key in superseded {
            resolveCommit(key, result: .superseded)
        }
    }

    private func resolveAllCommits(as result: CommitResult) {
        let tags = Array(commitWaiters.keys)
        for tag in tags {
            resolveCommit(tag, result: result)
        }
    }

    private func isOlder(_ tag: RealtimeVoicePacketTag, than other: RealtimeVoicePacketTag) -> Bool {
        tag.sessionID < other.sessionID
            || (tag.sessionID == other.sessionID && tag.utteranceGeneration < other.utteranceGeneration)
    }

    private func isNewerOrEqual(_ tag: RealtimeVoicePacketTag, than other: RealtimeVoicePacketTag) -> Bool {
        !isOlder(tag, than: other)
    }
}

private extension RealtimeVoicePipeline.Operation {
    var tag: RealtimeVoicePacketTag {
        RealtimeVoicePacketTag(sessionID: sessionID, utteranceGeneration: utteranceGeneration)
    }
}

private extension RealtimeVoicePipeline.OperationKind {
    var isAudio: Bool {
        if case .audio = self { return true }
        return false
    }

    var isPriorityControl: Bool {
        switch self {
        case .clearInput, .cancelResponse:
            return true
        case .audio, .finishInput, .sendText:
            return false
        }
    }
}

actor OpenAICompatibleRealtimeVoiceTransport: RealtimeVoiceTransport {
    private let task: URLSessionWebSocketTask
    private let configuration: RealtimeVoiceConfiguration
    private let mode: RealtimeVoiceProtocolMode
    private var didResume = false
    private var inputHasAudio = false
    private var correlation = RealtimeVoiceTransportCorrelation()

    init(configuration: RealtimeVoiceConfiguration, apiKey: String) {
        var request = URLRequest(url: configuration.endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if configuration.protocolMode == .openAIBeta || (configuration.protocolMode == .automatic && configuration.endpoint.host?.contains("api.openai.com") == true) {
            request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        }
        self.task = URLSession.shared.webSocketTask(with: request)
        self.configuration = configuration
        switch configuration.protocolMode {
        case .automatic:
            self.mode = configuration.endpoint.host?.contains("api.openai.com") == true ? .openAIGA : .compatible
        case .openAIGA, .openAIBeta, .compatible:
            self.mode = configuration.protocolMode
        }
    }

    func connect() async throws {
        guard !didResume else { return }
        try NetworkEndpointPolicy.requireSafe(configuration.endpoint)
        task.resume()
        didResume = true
        try await send(payload: sessionUpdatePayload())
    }

    func sendAudio(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        inputHasAudio = true
        try await send(payload: [
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString(),
        ])
    }

    func finishInput(tag: RealtimeVoicePacketTag, request: RealtimeVoiceResponseRequest) async throws {
        guard inputHasAudio else { throw RealtimeVoiceError.emptyInput }
        guard request.tag == tag else { throw RealtimeVoiceError.responseCorrelationUnavailable }
        guard correlation.enqueueCommit(tag: tag) else {
            throw RealtimeVoiceError.inputCorrelationLimitReached
        }
        inputHasAudio = false
        var commitSent = false
        do {
            try await send(payload: ["type": "input_audio_buffer.commit"])
            commitSent = true
            switch mode {
            case .openAIGA:
                try await send(payload: [
                    "type": "response.create",
                    "response": [
                        "output_modalities": ["audio"],
                        "metadata": request.metadata,
                    ],
                ])
            case .openAIBeta, .compatible:
                try await send(payload: [
                    "type": "response.create",
                    "response": [
                        "modalities": ["audio", "text"],
                        "metadata": request.metadata,
                    ],
                ])
            case .automatic:
                break
            }
        } catch {
            if !commitSent {
                correlation.removePendingCommit(tag: tag)
            }
            throw error
        }
    }

    func cancelResponse() async throws {
        try await send(payload: ["type": "response.cancel"])
    }

    func clearInput() async throws {
        inputHasAudio = false
        try await send(payload: ["type": "input_audio_buffer.clear"])
    }

    func sendText(_ text: String, request: RealtimeVoiceResponseRequest) async throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        try await send(payload: [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": normalized]],
            ],
        ])
        switch mode {
        case .openAIGA:
            try await send(payload: [
                "type": "response.create",
                "response": [
                    "output_modalities": ["audio"],
                    "metadata": request.metadata,
                ],
            ])
        case .openAIBeta, .compatible:
            try await send(payload: [
                "type": "response.create",
                "response": [
                    "modalities": ["audio", "text"],
                    "metadata": request.metadata,
                ],
            ])
        case .automatic:
            break
        }
    }

    func receive() async throws -> RealtimeVoiceTransportEvent {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .data(let value):
            data = value
        case .string(let value):
            data = Data(value.utf8)
        @unknown default:
            return .ignored
        }
        return try decodeEvent(data)
    }

    func decodeEvent(_ data: Data) throws -> RealtimeVoiceTransportEvent {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RealtimeVoiceError.malformedProviderMessage
        }
        let type = (payload["type"] as? String ?? "").lowercased()
        let responseID = payload["response_id"] as? String
        if type == "session.updated" || type == "session.created" {
            return .sessionReady
        }
        if type == "input_audio_buffer.speech_started" {
            return .speechStarted
        }
        if type == "input_audio_buffer.speech_stopped" {
            return .speechStopped
        }
        if type == "input_audio_buffer.committed" {
            let itemID = payload["item_id"] as? String
            guard correlation.acknowledge(itemID: itemID) != nil else {
                if correlation.isAtCapacity {
                    return .error(RealtimeVoiceError.inputCorrelationLimitReached.localizedDescription)
                }
                return .ignored
            }
            return .ignored
        }
        if type.contains("error") {
            let error = payload["error"] as? [String: Any]
            return .error(error?["message"] as? String ?? "realtime voice provider error")
        }
        if type == "response.created" {
            let response = payload["response"] as? [String: Any]
            return .responseStarted(
                response?["id"] as? String ?? responseID,
                metadata: stringMetadata(response?["metadata"])
            )
        }
        if type == "response.done" || type == "response.completed" {
            let response = payload["response"] as? [String: Any]
            return .responseFinished(response?["id"] as? String ?? responseID)
        }
        if type == "response.cancelled" || type == "response.canceled" || type == "response.interrupted" {
            return .responseInterrupted(responseID)
        }
        if type == "response.output_audio.delta" || type == "response.audio.delta" {
            guard let encoded = payload["delta"] as? String,
                  let decoded = Data(base64Encoded: encoded) else { return .ignored }
            return .audio(decoded, responseID: responseID)
        }
        if type == "conversation.item.input_audio_transcription.delta"
            || type == "input_audio_transcription.delta" {
            guard let text = payload["delta"] as? String, !text.isEmpty else { return .ignored }
            return .transcriptDelta(
                text,
                correlation: correlation.transcriptCorrelation(for: payload["item_id"] as? String)
            )
        }
        if type == "conversation.item.input_audio_transcription.completed"
            || type == "input_audio_transcription.completed" {
            guard let text = payload["transcript"] as? String, !text.isEmpty else { return .ignored }
            return .transcriptFinal(
                text,
                correlation: correlation.transcriptCorrelation(for: payload["item_id"] as? String)
            )
        }
        if type == "response.output_audio_transcript.delta"
            || type == "response.audio_transcript.delta"
            || type == "response.text.delta" {
            guard let text = payload["delta"] as? String, !text.isEmpty else { return .ignored }
            return .assistantTranscriptDelta(text, responseID: responseID)
        }
        if type == "response.output_audio_transcript.done"
            || type == "response.audio_transcript.done"
            || type == "response.text.done" {
            guard let text = (payload["transcript"] as? String) ?? (payload["text"] as? String), !text.isEmpty else {
                return .ignored
            }
            return .assistantTranscriptFinal(text, responseID: responseID)
        }
        return .ignored
    }

    #if DEBUG
    func prepareCommitFixture(tag: RealtimeVoicePacketTag) throws {
        guard correlation.enqueueCommit(tag: tag) else {
            throw RealtimeVoiceError.inputCorrelationLimitReached
        }
    }
    #endif

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func send(payload: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func stringMetadata(_ value: Any?) -> [String: String]? {
        guard let metadata = value as? [String: Any] else { return nil }
        let strings = metadata.compactMapValues { $0 as? String }
        guard strings.count == metadata.count else { return nil }
        return strings
    }

    func sessionUpdatePayload() -> [String: Any] {
        let inputFormat: [String: Any] = ["type": "audio/pcm", "rate": 24_000]
        var transcription: [String: Any] = ["model": "gpt-4o-transcribe"]
        if let inputLanguage = configuration.inputLanguage {
            transcription["language"] = inputLanguage
        }
        switch mode {
        case .openAIGA:
            let input: [String: Any] = [
                "format": inputFormat,
                "transcription": transcription,
                "noise_reduction": ["type": "near_field"],
                "turn_detection": NSNull(),
            ]
            return [
                "type": "session.update",
                "session": [
                    "type": "realtime",
                    "model": configuration.model,
                    "instructions": configuration.instructions,
                    "output_modalities": ["audio"],
                    "audio": [
                        "input": input,
                        "output": [
                            "format": inputFormat,
                            "voice": configuration.voice,
                            "speed": configuration.responseSpeed,
                        ],
                    ],
                ],
            ]
        case .openAIBeta, .compatible:
            return [
                "type": "session.update",
                "session": [
                    "model": configuration.model,
                    "instructions": configuration.instructions,
                    "modalities": ["text", "audio"],
                    "voice": configuration.voice,
                    "input_audio_format": "pcm16",
                    "output_audio_format": "pcm16",
                    "input_audio_transcription": transcription,
                    "turn_detection": NSNull(),
                ],
            ]
        case .automatic:
            return [:]
        }
    }
}

struct RealtimeVoiceAudioPacket: Equatable, Sendable {
    let data: Data
    let sessionID: Int
    let utteranceGeneration: Int
}

final class RealtimeVoiceAudioIngress: @unchecked Sendable {
    let stream: AsyncStream<RealtimeVoiceAudioPacket>

    private let continuation: AsyncStream<RealtimeVoiceAudioPacket>.Continuation
    private let lock = NSLock()
    private var overflowed = false

    init(capacity: Int) {
        let pair = AsyncStream<RealtimeVoiceAudioPacket>.makeStream(
            bufferingPolicy: .bufferingNewest(max(capacity, 1))
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func yield(_ packet: RealtimeVoiceAudioPacket) {
        guard case .dropped = continuation.yield(packet) else { return }
        lock.lock()
        overflowed = true
        lock.unlock()
    }

    func consumeOverflow() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = overflowed
        overflowed = false
        return value
    }

    func finish() {
        continuation.finish()
    }
}

@MainActor
final class RealtimeVoiceSession {
    private let configuration: RealtimeVoiceConfiguration
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
        let responseRequest = RealtimeVoiceResponseRequest(tag: tag)
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
            guard self.responseTracker.authorize(responseRequest) else {
                self.transcriptBarrier.failInput(tag)
                self.state = .failed(RealtimeVoiceError.responseCorrelationUnavailable.localizedDescription)
                self.onEvent(.error(RealtimeVoiceError.responseCorrelationUnavailable.localizedDescription))
                return
            }
            self.state = .responding
            do {
                let result = try await self.operationPipeline.commit(
                    sessionID: sessionID,
                    utteranceGeneration: generation,
                    responseRequest: responseRequest
                )
                guard result == .committed,
                      self.transcriptBarrier.activeTag == tag,
                      generation == self.inputGeneration,
                      self.state == .responding,
                      !self.audioSendFailed else {
                    self.responseTracker.cancel(responseRequest)
                    return
                }
                if let commit = self.transcriptBarrier.markInputCommitted(tag) {
                    self.publishTranscript(commit)
                }
            } catch is CancellationError {
                self.responseTracker.cancel(responseRequest)
                return
            } catch {
                self.responseTracker.cancel(responseRequest)
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

    func speakText(_ text: String) {
        switch state {
        case .idle, .failed:
            return
        case .connecting, .listening, .responding:
            break
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            let data = RealtimePCM16Encoder.encode(buffer, converter: converter)
            guard !data.isEmpty else { return }
            ingress.yield(RealtimeVoiceAudioPacket(
                data: data,
                sessionID: sessionID,
                utteranceGeneration: generation
            ))
        }
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
