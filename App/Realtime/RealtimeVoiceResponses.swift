import AVFoundation
import Foundation
import PerryCore

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
