import PerryBrain
import PerryCore
import QuartzCore

@MainActor
final class RealtimeTalkVoice {
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
        finalizeBudget: TimeInterval = 5
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
            inputLanguage: configuration.inputLanguage,
            transcriptionModel: configuration.transcriptionModel,
            provider: configuration.provider
        )
        let sessionFactory = {
            RealtimeVoiceSession(
                configuration: talkConfiguration,
                apiKey: apiKey,
                transport: makeTransport?(),
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

    static func configured(
        keychain: KeychainStore = KeychainStore(),
        fallbackInput: (any TalkSpeechInput)? = nil,
        fallbackOutput: (any TalkSpeechOutput)? = nil
    ) -> RealtimeTalkVoice? {
        guard let provider = RealtimeProvider.current,
              let configuration = provider.configuration(),
              let apiKey = try? provider.apiKey(keychain: keychain),
              !apiKey.isEmpty else { return nil }
        return RealtimeTalkVoice(
            configuration: configuration,
            apiKey: apiKey,
            fallbackInput: fallbackInput,
            fallbackOutput: fallbackOutput
        )
    }

    func warmUp() {
        guard RealtimeProvider(session.configuration.provider).billing == .perToken else { return }
        ensureSession().start()
    }

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
        if session.isShutDown {
            session = makeSession()
        } else if case .failed = session.state {
            session = makeSession()
        }
        return session
    }
}

@MainActor
final class RealtimeTalkInput: TalkSpeechInput {
    private let fallback: any TalkSpeechInput
    private weak var voice: RealtimeTalkVoice?

    var finalizeBudget: TimeInterval = 5
    private var beganAt: TimeInterval = 0
    private var endedAt: TimeInterval = 0
    private var latestTranscript = ""
    private var settled = false
    private var finalization: CheckedContinuation<Void, Never>?

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

@MainActor
private final class SilentTalkOutput: TalkSpeechOutput {
    var isSpeaking: Bool { false }
    func speak(_ sentence: String) {}
    func shutUp() {}
}

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
