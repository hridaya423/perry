import AppKit
import AVFoundation
import PerryBrain
import Speech

/// Word-timestamped speech input for a Talk hold. Implementations produce
/// `SpokenWord`s whose `start` is seconds since `start()` — the same epoch
/// PointerTraceRecorder samples use, so DeixisResolver can align them.
@MainActor
protocol TalkSpeechInput: AnyObject {
    /// Starts synchronously when the mic path is already warm (permission
    /// cached, engine reusable) so key-down never suspends on async setup —
    /// plan Phase-1 H7. Returns false when `start()` is still required.
    func startIfReady() throws -> Bool
    func start() async throws
    /// Stops capture and returns the final transcript plus word segments.
    func finalize() async -> (transcript: String, words: [SpokenWord])
    func cancel()
}

extension TalkSpeechInput {
    func startIfReady() throws -> Bool { false }
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
    /// One engine + recognizer per Talk lifetime, re-armed per hold —
    /// plan Phase-1 H7. Reuse is safe: start() aborts any in-flight
    /// recognition before re-installing the tap, and the recognition gate
    /// rejects callbacks from older generations.
    private lazy var dictation: DictationController = {
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
        return controller
    }()
    private var latestWords: [SpokenWord] = []
    private var latestTranscript = ""
    private var settled = false
    private var recording = false
    private var abandoned = false
    private var finalization: CheckedContinuation<Void, Never>?

    /// Constructs the engine + recognizer at launch so the first hold only
    /// pays re-arming (tap install + engine start), not audio setup.
    func warmUp() {
        _ = dictation
    }

    func startIfReady() throws -> Bool {
        guard DictationController.permissionGranted else { return false }
        try begin()
        return true
    }

    func start() async throws {
        if try startIfReady() { return }
        latestWords = []
        latestTranscript = ""
        settled = false
        abandoned = false
        guard await DictationController.ensurePermission() else {
            throw DictationController.DictationError.permissionDenied
        }
        guard !abandoned else { return }
        try begin()
    }

    private func begin() throws {
        latestWords = []
        latestTranscript = ""
        settled = false
        try dictation.start()
        recording = true
    }

    func finalize() async -> (transcript: String, words: [SpokenWord]) {
        guard !settled else { return (latestTranscript, latestWords) }
        guard recording else {
            abandoned = true
            finish(transcript: nil)
            return (latestTranscript, latestWords)
        }
        dictation.finish()
        let stablePartial = Task { @MainActor [weak self] in
            var previous = self?.latestTranscript ?? ""
            var updatedSinceRelease = false
            var unchanged = Duration.zero
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.partialStability)
                guard let self, !self.settled, !Task.isCancelled else { return }
                let current = self.latestTranscript
                if current != previous {
                    updatedSinceRelease = true
                    unchanged = .zero
                    previous = current
                    continue
                }
                unchanged += Self.partialStability
                if !current.isEmpty, updatedSinceRelease || unchanged >= Self.unchangedSinceRelease {
                    self.dictation.cancel()
                    self.finish(transcript: current)
                    return
                }
            }
        }
        await withCheckedContinuation { continuation in
            if settled {
                continuation.resume()
            } else {
                finalization = continuation
            }
        }
        stablePartial.cancel()
        return (latestTranscript, latestWords)
    }

    private static let partialStability = Duration.milliseconds(200)
    private static let unchangedSinceRelease = Duration.milliseconds(600)

    func cancel() {
        abandoned = true
        dictation.cancel()
        finish(transcript: nil)
    }

    private func finish(transcript: String?) {
        guard !settled else { return }
        settled = true
        recording = false
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
        guard await DictationController.ensurePermission() else {
            throw DictationController.DictationError.permissionDenied
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
