import AppKit
import AVFoundation
import PerryBrain
import PerryCore
import Speech

@MainActor
protocol TalkSpeechInput: AnyObject {
    func startIfReady() throws -> Bool
    func start() async throws
    func finalize() async -> (transcript: String, words: [SpokenWord])
    func cancel()
}

extension TalkSpeechInput {
    func startIfReady() throws -> Bool { false }
}

@MainActor
protocol TalkSpeechOutput: AnyObject {
    var isSpeaking: Bool { get }
    func speak(_ sentence: String)
    func shutUp()
}

@MainActor
final class SFSpeechInput: TalkSpeechInput {
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
            onWords: { [weak self] words in
                Task { @MainActor [weak self] in self?.latestWords = words }
            }
        )
        return controller
    }()
    var preferences: () -> DictationPreferences = { .default }
    private var latestWords: [SpokenWord] = []
    private var latestTranscript = ""
    private var settled = false
    private var recording = false
    private var abandoned = false
    private var finalization: CheckedContinuation<Void, Never>?

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
        dictation.configure(preferences())
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

@MainActor
final class SharedTalkOutput: TalkSpeechOutput {
    private let voice: VoiceController

    init(voice: VoiceController) { self.voice = voice }

    var isSpeaking: Bool { voice.isSpeaking }

    func speak(_ sentence: String) { voice.enqueueSpeech(sentence) }

    func shutUp() { voice.shutUp() }
}

#if DEBUG
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
