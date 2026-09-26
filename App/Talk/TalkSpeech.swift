import AppKit
import AVFoundation
import PerryBrain
import Speech

/// Word-timestamped speech input for a Talk hold. Implementations produce
/// `SpokenWord`s whose `start` is seconds since `start()` — the same epoch
/// PointerTraceRecorder samples use, so DeixisResolver can align them.
@MainActor
protocol TalkSpeechInput: AnyObject {
    func start() async throws
    /// Stops capture and returns the final transcript plus word segments.
    func finalize() async -> (transcript: String, words: [SpokenWord])
    func cancel()
}

/// Sentence-level speech output. `shutUp()` is the barge-in path and must
/// reach silence within ~150 ms (§8 budget).
@MainActor
protocol TalkSpeechOutput: AnyObject {
    var isSpeaking: Bool { get }
    func speak(_ sentence: String)
    func shutUp()
}

/// On-device SFSpeechRecognizer input: reuses DictationController's hardened
/// audio engine (route fallback, buffering) and reads segment timestamps from
/// each recognition event for deixis.
@MainActor
final class SFSpeechInput: TalkSpeechInput {
    private var dictation: DictationController?
    private var latestWords: [SpokenWord] = []
    private var latestTranscript = ""
    private var settled = false
    private var finalization: CheckedContinuation<Void, Never>?

    func start() async throws {
        latestWords = []
        latestTranscript = ""
        settled = false
        let controller = DictationController(
            onTranscript: { [weak self] transcript in
                Task { @MainActor in self?.finish(transcript: transcript) }
            },
            onPartial: { [weak self] transcript in
                Task { @MainActor in self?.latestTranscript = transcript }
            },
            onFailure: { [weak self] _ in
                Task { @MainActor in self?.finish(transcript: nil) }
            },
            onSegments: { [weak self] segments in
                Task { @MainActor [weak self] in
                    self?.latestWords = segments.map {
                        SpokenWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                    }
                }
            }
        )
        controller.configure(.default)
        dictation = controller
        guard await DictationController.requestPermission() else {
            throw DictationController.DictationError.unavailable
        }
        try controller.start()
    }

    func finalize() async -> (transcript: String, words: [SpokenWord]) {
        guard !settled else { return (latestTranscript, latestWords) }
        dictation?.finish()
        await withCheckedContinuation { continuation in
            if settled {
                continuation.resume()
            } else {
                finalization = continuation
            }
        }
        return (latestTranscript, latestWords)
    }

    func cancel() {
        dictation?.cancel()
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
}

/// AVSpeechSynthesizer output — queued utterances, honours the user's speech
/// prefs (voice, 0.5–1.5× rate, output disabled), immediate cut on barge-in.
@MainActor
final class SystemVoiceOutput: NSObject, TalkSpeechOutput {
    private let synthesizer = AVSpeechSynthesizer()
    private(set) var isSpeaking = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ sentence: String) {
        let cleaned = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let preferences = VoiceController.currentSpeechPreferences()
        guard preferences.outputEnabled else { return }
        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.voice = VoiceController.speakingVoice
        utterance.rate = VoiceController.speechRate(for: preferences.rateMultiplier)
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func shutUp() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }
}

extension SystemVoiceOutput: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.isSpeaking = synthesizer.isSpeaking }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.isSpeaking = synthesizer.isSpeaking }
    }
}
