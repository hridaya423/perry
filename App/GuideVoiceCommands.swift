import AVFoundation
import Speech

/// Guide-scoped voice commands (plan §3.4): while the guide controls are
/// up, a dedicated DictationController listens for "next", "back",
/// "skip", "stop", and "do it" and routes them to the same affordances
/// the panel exposes.
///
/// Design constraints: it never prompts — listening only starts when mic
/// + speech permission is already granted, so a guide can't surface a TCC
/// sheet mid-task. A command fires only when the whole utterance IS the
/// command, so "next" inside a sentence never advances the guide. Perry's
/// own speech output gates matching, so a spoken instruction can't echo
/// back in as a command. Each recognition task final re-arms the engine;
/// a second consecutive failure stops the listener instead of spinning.
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
    /// The last transcript consumed as a command — it fires once, and only
    /// fires again after the transcription moves on.
    private var consumed = ""
    /// Consecutive recognition failures; the listener gives up after two
    /// rather than restarting on a dead mic forever.
    private var consecutiveFailures = 0

    init(onCommand: @escaping (Command) -> Void, isSpeaking: @escaping () -> Bool) {
        self.onCommand = onCommand
        self.isSpeaking = isSpeaking
    }

    /// Begins listening when permission is already on file; otherwise a
    /// no-op — commands stay button-only until the user grants mic access
    /// through the normal permission flow.
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

    /// The recognition task ended (utterance boundary or task timeout) —
    /// start() re-arms the same engine + recognizer so listening survives.
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
