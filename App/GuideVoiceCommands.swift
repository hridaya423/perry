import AVFoundation
import Speech

@MainActor
final class GuideVoiceCommands {
    enum Command: String, CaseIterable {
        case next
        case back
        case skip
        case stop
        case doIt

        init?(normalized: String) {
            switch normalized {
            case "next", "next step": self = .next
            case "back", "go back", "previous": self = .back
            case "skip", "skip it", "skip this": self = .skip
            case "stop", "stop it", "cancel": self = .stop
            case "do it", "do this", "do this step": self = .doIt
            default: return nil
            }
        }
    }

    private let onCommand: (Command) -> Void
    private let isSpeaking: () -> Bool
    private(set) var listening = false
    private var dictation: DictationController?
    private var consumed = ""
    private var consecutiveFailures = 0

    init(onCommand: @escaping (Command) -> Void, isSpeaking: @escaping () -> Bool) {
        self.onCommand = onCommand
        self.isSpeaking = isSpeaking
    }

    func startIfPermitted() {
        guard !listening, DictationController.permissionGranted else { return }
        consecutiveFailures = 0
        let controller = DictationController(
            onTranscript: { [weak self] transcript in
                Task { @MainActor in self?.handleFinal(transcript) }
            },
            onPartial: { [weak self] transcript in
                Task { @MainActor in self?.handlePartial(transcript) }
            },
            onFailure: { [weak self] _ in
                Task { @MainActor in self?.handleFailure() }
            }
        )
        controller.configure(.default)
        do {
            try controller.start()
            dictation = controller
            listening = true
        } catch {
            dictation = nil
        }
    }

    func stop() {
        listening = false
        dictation?.cancel()
        dictation = nil
        consumed = ""
        consecutiveFailures = 0
    }

    private func handlePartial(_ transcript: String) {
        guard listening, !isSpeaking() else { return }
        let normalized = Self.normalize(transcript)
        guard normalized != consumed else { return }
        guard let command = Command(normalized: normalized) else {
            consumed = ""
            return
        }
        consumed = normalized
        onCommand(command)
    }

    private func handleFinal(_ transcript: String) {
        handlePartial(transcript)
        consecutiveFailures = 0
        restartIfListening()
    }

    private func handleFailure() {
        consecutiveFailures += 1
        if consecutiveFailures >= 2 {
            stop()
            return
        }
        restartIfListening()
    }

    private func restartIfListening() {
        guard listening, let dictation else { return }
        consumed = ""
        do {
            try dictation.start()
        } catch {
            handleFailure()
        }
    }

    private static func normalize(_ transcript: String) -> String {
        transcript.lowercased()
            .components(separatedBy: .punctuationCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
