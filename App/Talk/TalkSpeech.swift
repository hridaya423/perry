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

/// Talk output over VoiceController's one synthesizer — a single speech owner
/// means Talk barge-in silences Guide instructions and announcements too, and
/// `isSpeaking` reflects every feature's speech (plan Phase 2.3). Queued via
/// `enqueueSpeech` so streamed sentences play back-to-back.
@MainActor
final class SharedTalkOutput: TalkSpeechOutput {
    private let voice: VoiceController

    init(voice: VoiceController) { self.voice = voice }

    var isSpeaking: Bool { voice.isSpeaking }

    func speak(_ sentence: String) { voice.enqueueSpeech(sentence) }

    func shutUp() { voice.shutUp() }
}

#if DEBUG
/// Lab speech inputs for the talk drill, selected by launch arguments:
/// `--perry-talk-script <text>` feeds a deterministic transcript (no Speech
/// permission needed); `--perry-talk-audio <file>` runs a real
/// SFSpeechURLRecognitionTask over a recording. Neither exists in release.
enum TalkLabInput {
    @MainActor
    static func makeInput(arguments: [String]) -> (any TalkSpeechInput)? {
        if let index = arguments.firstIndex(of: "--perry-talk-audio"),
           arguments.indices.contains(index + 1) {
            return WAVSpeechInput(url: URL(fileURLWithPath: arguments[index + 1]))
        }
        if let index = arguments.firstIndex(of: "--perry-talk-script"),
           arguments.indices.contains(index + 1) {
            return ScriptedSpeechInput(transcript: arguments[index + 1])
        }
        return nil
    }
}

/// Deterministic transcript: one word per 400 ms from start(), the cadence
/// PointerTraceRecorder's 60 Hz samples align against.
@MainActor
final class ScriptedSpeechInput: TalkSpeechInput {
    private let transcript: String
    private var words: [SpokenWord] = []

    init(transcript: String) { self.transcript = transcript }

    func start() async throws {
        var t: TimeInterval = 0
        words = transcript.split(separator: " ").map { part in
            defer { t += 0.4 }
            return SpokenWord(text: String(part), start: t, duration: 0.35)
        }
    }

    func finalize() async -> (transcript: String, words: [SpokenWord]) {
        (transcript, words)
    }

    func cancel() {}
}

/// Real on-device recognition over a pre-recorded file: exercises
/// SFSpeechURLRecognitionTask — the same API family SFSpeechInput drives
/// through DictationController — without a live mic.
@MainActor
final class WAVSpeechInput: TalkSpeechInput {
    private let url: URL
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    private var words: [SpokenWord] = []
    private var settled = false
    private var finalization: CheckedContinuation<Void, Never>?

    init(url: URL) { self.url = url }

    func start() async throws {
        guard await DictationController.requestPermission() else {
            throw DictationController.DictationError.unavailable
        }
        guard let recognizer = SFSpeechRecognizer() else {
            throw DictationController.DictationError.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, !self.settled else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.words = result.bestTranscription.segments.map {
                        SpokenWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                    }
                    if result.isFinal { self.settle() }
                }
                if error != nil { self.settle() }
            }
        }
    }

    func finalize() async -> (transcript: String, words: [SpokenWord]) {
        if !settled {
            await withCheckedContinuation { finalization = $0 }
        }
        return (transcript, words)
    }

    func cancel() {
        task?.cancel()
        settle()
    }

    private func settle() {
        guard !settled else { return }
        settled = true
        finalization?.resume()
        finalization = nil
    }
}
#endif
