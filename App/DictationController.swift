import AVFoundation
import Speech

/// Push-to-talk dictation via Apple's on-device Speech framework (PRD §4:
/// free Apple frameworks, type and talk co-equal). Final transcript lands
/// in the handler. macOS has no AVAudioSession; the input tap is enough.
final class DictationController {
    private let onTranscript: (String) -> Void
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    init(onTranscript: @escaping (String) -> Void) {
        self.onTranscript = onTranscript
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    static func requestPermission() async -> Bool {
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func start() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw DictationError.unavailable
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw DictationError.unavailable
        }

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        self.request = recognitionRequest

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }
            if let result, result.isFinal {
                let transcript = result.bestTranscription.formattedString
                if !transcript.isEmpty {
                    self.onTranscript(transcript)
                }
                self.finish()
            } else if error != nil {
                self.finish()
            }
        }
    }

    func finish() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    enum DictationError: Error {
        case unavailable
    }
}
