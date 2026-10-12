import PerryBrain
import PerryGuide
import QuartzCore

/// BYOK realtime voice inside Talk (plan §1.5): one RealtimeVoiceSession
/// per app lifetime, `beginInput()` per hold, commits for transcription
/// only — Perry's brain still owns the answer — and renders replies through
/// the provider voice via `speakText`. Falls back to the on-device stack
/// whenever the session can't reach `.listening`.
@MainActor
final class RealtimeTalkVoice {
    /// The session's only response channel is output rendering, so its
    /// instructions constrain it to speaking exactly what it is handed —
    /// the standard realtime-TTS pattern over conversation.item.create.
    private static let instructions = """
        You are Perry's voice. Repeat each message you receive verbatim in \
        natural speech — no preamble, no extra words, no answers.
        """

    let input: RealtimeTalkInput
    let output: RealtimeTalkOutput
    private let connectBudget: TimeInterval
    private let makeSession: () -> RealtimeVoiceSession
    private(set) var session: RealtimeVoiceSession

    init(
        configuration: RealtimeVoiceConfiguration,
        apiKey: String,
        makeTransport: (@Sendable () -> any RealtimeVoiceTransport)? = nil,
        fallbackInput: (any TalkSpeechInput)? = nil,
        fallbackOutput: (any TalkSpeechOutput)? = nil,
        connectBudget: TimeInterval = 2,
        finalizeBudget: TimeInterval = 5,
        onPerformanceSample: @escaping (PerformanceSample) -> Void = { _ in },
        onPerformanceMarker: @escaping (PerformanceMarker) -> Void = { _ in },
        onTaskSnapshot: @escaping (RealtimeTaskSnapshot) -> Void = { _ in }
    ) {
        let input = RealtimeTalkInput(fallback: fallbackInput ?? SFSpeechInput())
        input.finalizeBudget = finalizeBudget
        let output = RealtimeTalkOutput(fallback: fallbackOutput)
        let talkConfiguration = RealtimeVoiceConfiguration(
            endpoint: configuration.endpoint,
            model: configuration.model,
            voice: configuration.voice,
            responseSpeed: configuration.responseSpeed,
            instructions: Self.instructions,
            protocolMode: configuration.protocolMode,
            inputLanguage: configuration.inputLanguage
        )
        let sessionFactory = {
            RealtimeVoiceSession(
                configuration: talkConfiguration,
                apiKey: apiKey,
                transport: makeTransport?(),
                onPerformanceSample: onPerformanceSample,
                onPerformanceMarker: onPerformanceMarker,
                onTaskSnapshot: onTaskSnapshot,
                onEvent: { [weak input] event in input?.handle(event) }
            )
        }
        self.connectBudget = connectBudget
        self.makeSession = sessionFactory
        self.input = input
        self.output = output
        self.session = sessionFactory()
        input.attach(voice: self)
        output.attach(voice: self)
        output.isRealtimeActive = { [weak input] in input?.isUsingRealtime ?? false }
    }

    /// Builds a realtime Talk voice when BYOK realtime is configured and a
    /// keychain key exists; nil keeps Talk on the on-device stack.
    static func configured(
        keychain: KeychainStore = KeychainStore(),
        fallbackInput: (any TalkSpeechInput)? = nil,
        fallbackOutput: (any TalkSpeechOutput)? = nil,
        onPerformanceSample: @escaping (PerformanceSample) -> Void = { _ in },
        onPerformanceMarker: @escaping (PerformanceMarker) -> Void = { _ in },
        onTaskSnapshot: @escaping (RealtimeTaskSnapshot) -> Void = { _ in }
    ) -> RealtimeTalkVoice? {
        guard let configuration = VoiceController.currentRealtimeVoiceConfiguration(),
              let apiKey = try? keychain.readChecked(account: VoiceController.realtimeVoiceKeychainAccount),
              !apiKey.isEmpty else { return nil }
        return RealtimeTalkVoice(
            configuration: configuration,
            apiKey: apiKey,
            fallbackInput: fallbackInput,
            fallbackOutput: fallbackOutput,
            onPerformanceSample: onPerformanceSample,
            onPerformanceMarker: onPerformanceMarker,
            onTaskSnapshot: onTaskSnapshot
        )
    }

    /// Connect at launch so the first realtime hold never pays it.
    func warmUp() {
        ensureSession().start()
    }

    /// A usable session: rebuilds a failed one (a stopped session cannot
    /// restart — `shutdownRequested` is terminal) and starts an idle one.
    /// Callers still bound the wait to `.listening` themselves.
    func ensureListening() async -> Bool {
        let session = ensureSession()
        if session.state == .idle { session.start() }
        let deadline = CACurrentMediaTime() + connectBudget
        while session.state == .connecting, CACurrentMediaTime() < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        return session.state == .listening
    }

    private func ensureSession() -> RealtimeVoiceSession {
        if case .failed = session.state {
            session = makeSession()
        }
        return session
    }
}

/// TalkSpeechInput over the realtime session: `beginInput()` re-arms the
/// buffer per hold, `finishInputTranscribing()` commits for transcription
/// without a provider response, and `cancel()` clears the utterance.
/// Realtime transcription carries no word timestamps, so `finalize()`
/// spreads the words evenly across the hold — the deixis epoch stays
/// seconds-since-start like every other input.
@MainActor
final class RealtimeTalkInput: TalkSpeechInput {
    private let fallback: any TalkSpeechInput
    private weak var voice: RealtimeTalkVoice?

    /// Bound on the provider's transcription reply — a dropped commit must
    /// not hang the turn.
    var finalizeBudget: TimeInterval = 5
    private var beganAt: TimeInterval = 0
    private var endedAt: TimeInterval = 0
    private var latestTranscript = ""
    private var settled = false
    private var finalization: CheckedContinuation<Void, Never>?

    /// True while the current turn is driven by the realtime session — the
    /// output adapter reads it so input/output never straddle the two
    /// stacks mid-turn. Cleared on cancel; kept through the answer.
    private(set) var isUsingRealtime = false

    init(fallback: any TalkSpeechInput) {
        self.fallback = fallback
    }

    func attach(voice: RealtimeTalkVoice) {
        self.voice = voice
    }

    func handle(_ event: RealtimeVoiceEvent) {
        switch event {
        case .transcriptDelta(let text):
            latestTranscript = text
        case .transcriptFinal(let text):
            finish(transcript: text)
        case .error:
            finish(transcript: nil)
        default:
            break
        }
    }

    func startIfReady() throws -> Bool {
        guard let session = voice?.session, session.state == .listening else { return false }
        begin()
        session.beginInput()
        return true
    }

    func start() async throws {
        if try startIfReady() { return }
        guard let voice, await voice.ensureListening() else {
            isUsingRealtime = false
            try await fallback.start()
            return
        }
        begin()
        voice.session.beginInput()
    }

    private func begin() {
        beganAt = CACurrentMediaTime()
        endedAt = 0
        latestTranscript = ""
        settled = false
        isUsingRealtime = true
    }

    func finalize() async -> (transcript: String, words: [SpokenWord]) {
        guard isUsingRealtime, let session = voice?.session else {
            return await fallback.finalize()
        }
        endedAt = CACurrentMediaTime()
        if !settled {
            if session.hasPendingInputAudio {
                session.finishInputTranscribing()
            } else {
                // Nothing reached the buffer — committing would only fail
                // the session on emptyInput.
                finish(transcript: nil)
            }
            let timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(finalizeBudget))
                if !Task.isCancelled { self?.finish(transcript: nil) }
            }
            await withCheckedContinuation { continuation in
                if settled {
                    continuation.resume()
                } else {
                    finalization = continuation
                }
            }
            timeout.cancel()
        }
        return (latestTranscript, words(for: latestTranscript))
    }

    func cancel() {
        if isUsingRealtime {
            // Discards the buffered utterance and re-arms listening — the
            // bumped generation also settles out any in-flight commit.
            voice?.session.beginInput()
        } else {
            fallback.cancel()
        }
        isUsingRealtime = false
        finish(transcript: nil)
    }

    private func finish(transcript: String?) {
        guard !settled else { return }
        settled = true
        if let transcript, !transcript.isEmpty {
            latestTranscript = transcript
        }
        finalization?.resume()
        finalization = nil
    }

    private func words(for transcript: String) -> [SpokenWord] {
        let parts = transcript.split(separator: " ")
        guard !parts.isEmpty else { return [] }
        let span = max(0.25, (endedAt > 0 ? endedAt : CACurrentMediaTime()) - beganAt)
        let step = span / Double(parts.count)
        return parts.enumerated().map { index, part in
            SpokenWord(text: String(part), start: Double(index) * step, duration: step)
        }
    }
}

/// TalkSpeechOutput over the realtime session: `speak` sends the sentence
/// for verbatim rendering, `shutUp` is the barge-in path. Routes to the
/// on-device fallback whenever the turn's input isn't realtime-driven.
@MainActor
final class RealtimeTalkOutput: TalkSpeechOutput {
    private let fallback: any TalkSpeechOutput
    private weak var voice: RealtimeTalkVoice?
    var isRealtimeActive: () -> Bool = { false }

    init(fallback: (any TalkSpeechOutput)?) {
        self.fallback = fallback ?? SilentTalkOutput()
    }

    func attach(voice: RealtimeTalkVoice) {
        self.voice = voice
    }

    var isSpeaking: Bool {
        isRealtimeActive() ? voice?.session.state == .responding : fallback.isSpeaking
    }

    func speak(_ sentence: String) {
        if isRealtimeActive() {
            voice?.session.speakText(sentence)
        } else {
            fallback.speak(sentence)
        }
    }

    func shutUp() {
        voice?.session.cancelCurrentResponse()
        fallback.shutUp()
    }
}

/// Used only when no fallback output is injected — realtime output without
/// a local owner should still be safe to silence.
@MainActor
private final class SilentTalkOutput: TalkSpeechOutput {
    var isSpeaking: Bool { false }
    func speak(_ sentence: String) {}
    func shutUp() {}
}

/// TalkSession's single output seam: hands speech to the realtime voice
/// while a realtime hold is live and to the on-device synthesizer
/// otherwise, so `Services.output` never has to be rebuilt per turn.
@MainActor
final class TalkSpeechOutputRouter: TalkSpeechOutput {
    private let realtime: () -> RealtimeTalkOutput?
    private let fallback: any TalkSpeechOutput

    init(realtime: @escaping () -> RealtimeTalkOutput?, fallback: any TalkSpeechOutput) {
        self.realtime = realtime
        self.fallback = fallback
    }

    var isSpeaking: Bool {
        (realtime()?.isSpeaking ?? false) || fallback.isSpeaking
    }

    func speak(_ sentence: String) {
        if let realtime = realtime(), realtime.isRealtimeActive() {
            realtime.speak(sentence)
        } else {
            fallback.speak(sentence)
        }
    }

    func shutUp() {
        realtime()?.shutUp()
        fallback.shutUp()
    }
}
