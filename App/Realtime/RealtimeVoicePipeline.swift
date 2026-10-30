import AVFoundation
import Foundation
import PerryCore

protocol RealtimeVoiceTransport: Sendable {
    func connect() async throws
    func sendAudio(_ data: Data) async throws
    func finishInput(tag: RealtimeVoicePacketTag, request: RealtimeVoiceResponseRequest) async throws
    func commitInput(tag: RealtimeVoicePacketTag) async throws
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
        case commitInput
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
        let tag = RealtimeVoicePacketTag(
            sessionID: sessionID,
            utteranceGeneration: utteranceGeneration
        )
        let request = responseRequest ?? RealtimeVoiceResponseRequest(tag: tag)
        guard request.tag == tag else { throw RealtimeVoiceError.responseCorrelationUnavailable }
        return try await enqueueCommit(tag: tag, operation: Operation(
            sessionID: sessionID,
            utteranceGeneration: utteranceGeneration,
            kind: .finishInput,
            responseRequest: request
        ))
    }

    func commitTranscribing(
        sessionID: Int,
        utteranceGeneration: Int
    ) async throws -> CommitResult {
        let tag = RealtimeVoicePacketTag(
            sessionID: sessionID,
            utteranceGeneration: utteranceGeneration
        )
        return try await enqueueCommit(tag: tag, operation: Operation(
            sessionID: sessionID,
            utteranceGeneration: utteranceGeneration,
            kind: .commitInput
        ))
    }

    private func enqueueCommit(
        tag: RealtimeVoicePacketTag,
        operation: Operation
    ) async throws -> CommitResult {
        try Task.checkCancellation()
        guard tag == activeTag, !isStopped else { return .superseded }
        if commitCompleted.contains(tag) { return .committed }
        if let failure = failures[tag] { throw failure }
        if !commitEnqueued.contains(tag) {
            append(operation)
            commitEnqueued.insert(tag)
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
                if case .finishInput = operation.kind, operation.tag == activeTag {
                    commitCompleted.insert(operation.tag)
                    resolveCommit(operation.tag, result: .committed)
                } else if case .commitInput = operation.kind, operation.tag == activeTag {
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

extension RealtimeVoicePipeline.Operation {
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
        case .audio, .finishInput, .commitInput, .sendText:
            return false
        }
    }
}
