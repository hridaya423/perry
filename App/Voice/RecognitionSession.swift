import AVFoundation
import PerryBrain
import Speech

protocol RecognitionSession: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    func endAudio()
    func cancel()
}

final class SystemRecognitionSession: RecognitionSession {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var task: SFSpeechRecognitionTask?

    init(recognizer: SFSpeechRecognizer?, request: SFSpeechAudioBufferRecognitionRequest, onEvent: @escaping (DictationRecognitionEvent) -> Void) {
        self.request = request
        task = recognizer?.recognitionTask(with: request) { result, error in
            guard let event = DictationRecognitionEvent(result: result, error: error) else { return }
            onEvent(event)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }

    func endAudio() {
        request.endAudio()
    }

    func cancel() {
        request.endAudio()
        task?.cancel()
        task = nil
    }
}

struct AnalyzerTarget {
    let locale: Locale
    let format: AVAudioFormat

    private static let lock = NSLock()
    private static var prepared: [String: AnalyzerTarget] = [:]

    static func cached(for locale: Locale) -> AnalyzerTarget? {
        lock.withLock { prepared[locale.identifier] }
    }

    static func remember(_ target: AnalyzerTarget, for locale: Locale) {
        lock.withLock { prepared[locale.identifier] = target }
    }
}

@available(macOS 26, *)
final class AnalyzerRecognitionSession: RecognitionSession, @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private var results: Task<Void, Never>?

    init(target: AnalyzerTarget, words: [String], onEvent: @escaping (DictationRecognitionEvent) -> Void) {
        let transcriber = Self.transcriber(for: target.locale)
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        self.analyzer = analyzer
        self.input = input
        format = target.format
        results = Task {
            var settled = AttributedString()
            do {
                for try await result in transcriber.results {
                    let heard: AttributedString
                    if result.isFinal {
                        settled += result.text
                        heard = settled
                    } else {
                        heard = settled + result.text
                    }
                    onEvent(.transcript(Self.plain(heard), isFinal: false, words: Self.words(in: heard)))
                }
                onEvent(.transcript(Self.plain(settled), isFinal: true, words: Self.words(in: settled)))
            } catch {
                onEvent(.failure(error))
            }
        }
        Task {
            if !words.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = words
                try? await analyzer.setContext(context)
            }
            do {
                try await analyzer.start(inputSequence: stream)
            } catch {
                onEvent(.failure(error))
            }
        }
    }

    static func transcriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
    }

    static func prepare(locale: Locale) async -> AnalyzerTarget? {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        let modules = [transcriber(for: supported)]
        do {
            try await AssetInventory.assetInstallationRequest(supporting: modules)?.downloadAndInstall()
        } catch {
            return nil
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else { return nil }
        return AnalyzerTarget(locale: supported, format: format)
    }

    static func plain(_ text: AttributedString) -> String {
        String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func words(in text: AttributedString) -> [SpokenWord] {
        text.runs.compactMap { run in
            guard let range = run.audioTimeRange else { return nil }
            let word = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { return nil }
            return SpokenWord(text: word, start: range.start.seconds, duration: range.duration.seconds)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    func endAudio() {
        input.finish()
        let analyzer = analyzer
        Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
    }

    func cancel() {
        input.finish()
        results?.cancel()
        results = nil
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return DictationController.copyBuffer(buffer) }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}
