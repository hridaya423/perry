import Foundation

public struct EndOfTurnDetector: Sendable {
    public enum Event: Equatable, Sendable {
        case speechStarted
        case silence(since: TimeInterval, progress: Double)
        case commit(CommitReason)
        case abort(AbortReason)
    }

    public enum CommitReason: Equatable, Sendable {
        case silence, hardCap, turnCap
    }

    public enum AbortReason: Equatable, Sendable {
        case noSpeech
    }

    public struct Parameters: Sendable {
        public var onsetDecibels = 9.0
        public var voicedDecibels = 6.0
        public var onsetDuration: TimeInterval = 0.12
        public var baseSilence: TimeInterval = 0.7
        public var unpunctuatedSilence: TimeInterval = 1.0
        public var continuationSilence: TimeInterval = 1.2
        public var clearEndSilence: TimeInterval = 0.5
        public var hardCap: TimeInterval = 2.5
        public var noSpeechAbort: TimeInterval = 8
        public var turnCap: TimeInterval = 60
        public var widening: TimeInterval = 0.3
        public var maxWidenings = 3
        public var nearMiss = 0.6

        public init() {}
    }

    public static let continuationWords: Set<String> = [
        "and", "but", "so", "or", "um", "uh", "er", "like", "then", "because",
        "to", "the", "a", "an", "of", "for", "with", "my", "your", "in", "on", "at", "is", "are", "i"
    ]

    public let parameters: Parameters
    public private(set) var finished = false
    public private(set) var widenings = 0
    private let startedAt: TimeInterval
    private var floor: Double?
    private var loudSince: TimeInterval?
    private var speaking = false
    private var lastVoiceAt: TimeInterval = 0
    private var lastWordEnd: TimeInterval = 0
    private var transcript = ""
    private var silenceProgress = 0.0

    public init(startedAt: TimeInterval, noiseFloor: Double? = nil, parameters: Parameters = Parameters()) {
        self.startedAt = startedAt
        self.parameters = parameters
        floor = noiseFloor.map { 20 * log10(max($0, 1e-7)) }
    }

    public var requiredSilence: TimeInterval {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split(whereSeparator: \.isWhitespace)
        let last = words.last.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
        let ended = text.hasSuffix(".") || text.hasSuffix("?") || text.hasSuffix("!")
        let base: TimeInterval
        if text.hasSuffix(",") || Self.continuationWords.contains(last) {
            base = parameters.continuationSilence
        } else if ended {
            base = words.count >= 4 ? parameters.clearEndSilence : parameters.baseSilence
        } else {
            base = text.isEmpty ? parameters.baseSilence : parameters.unpunctuatedSilence
        }
        return min(base + parameters.widening * Double(widenings), parameters.hardCap)
    }

    public mutating func frame(at t: TimeInterval, rms: Double) -> Event? {
        guard !finished else { return nil }
        let level = 20 * log10(max(rms, 1e-7))
        let floor = self.floor ?? level
        let loud = level > floor + parameters.onsetDecibels
        let voiced = level > floor + parameters.voicedDecibels
        if !voiced {
            self.floor = floor + (level - floor) * (level < floor ? 0.3 : 0.02)
        }

        guard speaking else {
            if loud {
                let since = loudSince ?? t
                loudSince = since
                if t - since >= parameters.onsetDuration {
                    return startSpeech(at: t)
                }
            } else {
                loudSince = nil
            }
            if t - startedAt >= parameters.noSpeechAbort { return finish(.abort(.noSpeech)) }
            return nil
        }

        if t - startedAt >= parameters.turnCap { return finish(.commit(.turnCap)) }
        if voiced {
            heardVoice(at: t)
            return nil
        }
        let since = max(lastVoiceAt, lastWordEnd)
        let elapsed = t - since
        if elapsed >= parameters.hardCap { return finish(.commit(.hardCap)) }
        let required = requiredSilence
        if elapsed >= required { return finish(.commit(.silence)) }
        silenceProgress = max(silenceProgress, elapsed / required)
        return .silence(since: since, progress: elapsed / required)
    }

    public mutating func transcript(at t: TimeInterval, text: String, lastWordEnd: TimeInterval) -> Event? {
        guard !finished, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        transcript = text
        if lastWordEnd > self.lastWordEnd {
            self.lastWordEnd = lastWordEnd
        }
        return speaking ? nil : startSpeech(at: t)
    }

    private mutating func startSpeech(at t: TimeInterval) -> Event {
        speaking = true
        lastVoiceAt = t
        return .speechStarted
    }

    private mutating func heardVoice(at t: TimeInterval) {
        if silenceProgress >= parameters.nearMiss, widenings < parameters.maxWidenings {
            widenings += 1
        }
        silenceProgress = 0
        lastVoiceAt = t
    }

    private mutating func finish(_ event: Event) -> Event {
        finished = true
        return event
    }
}
