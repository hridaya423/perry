import AppKit
import ApplicationServices
import AVFoundation
import Speech
import PerryCapture
import PerryCore
import PerryGuide
import PerryOverlay
import PerryRuntimes

extension VoiceController {
    // MARK: Speech out

    /// Resolution enumerates every installed voice — cache per
    /// (identifier, language) pair so a per-utterance lookup stays cheap;
    /// a preference change produces a new key and re-resolves (H6).
    private static var voiceCache: [String: AVSpeechSynthesisVoice?] = [:]
    /// A voice downloaded while Perry runs must win over the cached compact one.
    private static let voiceCacheInvalidation: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: .main
    ) { _ in
        MainActor.assumeIsolated { voiceCache.removeAll() }
    }

    static func speakingVoice(for languageIdentifier: String? = nil) -> AVSpeechSynthesisVoice? {
        _ = voiceCacheInvalidation
        let preferences = currentSpeechPreferences()
        let key = "\(preferences.voiceIdentifier ?? "")\u{1F}\(languageIdentifier ?? "")"
        if let cached = voiceCache[key] { return cached }
        let resolved = resolveSpeakingVoice(for: languageIdentifier, preferences: preferences)
        voiceCache[key] = resolved
        return resolved
    }

    private static func resolveSpeakingVoice(for languageIdentifier: String?, preferences: SpeechPreferences) -> AVSpeechSynthesisVoice? {
        if let identifier = preferences.voiceIdentifier,
           let selected = AVSpeechSynthesisVoice(identifier: identifier) {
            return selected
        }
        if let languageIdentifier,
           let languageCode = Locale(identifier: languageIdentifier).language.languageCode,
           let detectedVoice = availableSpeechVoices().first(where: {
               Locale(identifier: $0.language).language.languageCode == languageCode
           }) {
            return detectedVoice
        }
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        return english.first { $0.quality == .premium }
            ?? english.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    static var speakingVoice: AVSpeechSynthesisVoice? {
        speakingVoice(for: nil)
    }

    static func availableSpeechVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted {
            let left = "\($0.language) \($0.name)"
            let right = "\($1.language) \($1.name)"
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
    }

    static func recommendedSpeechVoices(
        from voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices(),
        languageCode: String = Locale.current.language.languageCode?.identifier ?? "en",
        limit: Int = 5
    ) -> [AVSpeechSynthesisVoice] {
        let natural = voices.filter { voice in
            !voice.identifier.contains("speech.synthesis") && !voice.identifier.contains("eloquence")
                && Locale(identifier: voice.language).language.languageCode?.identifier == languageCode
        }
        let ranked = natural.sorted { left, right in
            if left.quality != right.quality { return left.quality.rawValue > right.quality.rawValue }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
        var seenNames = Set<String>()
        return Array(ranked.filter { seenNames.insert($0.name).inserted }.prefix(limit))
    }

    static func speechIsAudible() -> Bool {
        currentSpeechPreferences().outputEnabled
            && AudioRouteMonitor.defaultOutputAvailable()
            && !AudioRouteMonitor.defaultOutputMuted()
    }

    static func currentSpeechPreferences(defaults: UserDefaults = .standard) -> SpeechPreferences {
        let enabled = defaults.object(forKey: PerryPreferences.$speechOutputEnabled.key) as? Bool ?? true
        let rate = defaults.object(forKey: PerryPreferences.$speechRate.key) as? Double ?? 1
        return SpeechPreferences(
            outputEnabled: enabled,
            rateMultiplier: rate,
            voiceIdentifier: defaults.string(forKey: PerryPreferences.$speechVoiceIdentifier.key)
        )
    }

    func currentDictationPreferences() throws -> DictationPreferences {
        let language: DictationLanguageMode
        let dictationLanguageRaw = PerryPreferences.dictationLanguage
        if !dictationLanguageRaw.isEmpty, dictationLanguageRaw != "automatic" {
            language = .fixed(identifier: dictationLanguageRaw)
        } else {
            language = .automatic
        }
        let dictionary = try VoiceDictionaryStore(supportDirectory: supportDirectory()).entries()
        let inputDeviceID = PerryPreferences.dictationInputDeviceID.map { UInt32(truncatingIfNeeded: $0) }
        return DictationPreferences(
            language: language,
            customWords: Array(dictionary.keys) + Array(dictionary.values),
            inputDeviceID: inputDeviceID
        )
    }

    static func saveSpeechPreferences(
        _ preferences: SpeechPreferences,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(preferences.outputEnabled, forKey: PerryPreferences.$speechOutputEnabled.key)
        defaults.set(preferences.rateMultiplier, forKey: PerryPreferences.$speechRate.key)
        if let voiceIdentifier = preferences.voiceIdentifier {
            defaults.set(voiceIdentifier, forKey: PerryPreferences.$speechVoiceIdentifier.key)
        } else {
            defaults.removeObject(forKey: PerryPreferences.$speechVoiceIdentifier.key)
        }
    }

    func updateSpeechPreferences(_ preferences: SpeechPreferences) {
        Self.saveSpeechPreferences(preferences)
    }

    func updateDictationPreferences(_ preferences: DictationPreferences) {
        switch preferences.language {
        case .automatic:
            PerryPreferences.dictationLanguage = "automatic"
        case .fixed(let identifier):
            PerryPreferences.dictationLanguage = identifier
        }
        PerryPreferences.dictationInputDeviceID = preferences.inputDeviceID.map { Int($0) }
        dictation.configure(preferences)
    }

    func voiceDictionaryEntries() throws -> [String: String] {
        try VoiceDictionaryStore(supportDirectory: supportDirectory()).entries()
    }

    func saveVoiceDictionaryEntry(spoken: String, replacement: String) throws {
        try VoiceDictionaryStore(supportDirectory: supportDirectory()).set(spoken: spoken, replacement: replacement)
    }

    func removeVoiceDictionaryEntry(spoken: String) throws {
        try VoiceDictionaryStore(supportDirectory: supportDirectory()).remove(spoken: spoken)
    }

    static func speakingVoiceDisplayName() -> String? {
        speakingVoice?.name
    }

    static func speechRate(for multiplier: Double) -> Float {
        let clamped = min(max(multiplier, 0.5), 1.5)
        return Float(0.42 + ((clamped - 0.5) / 1.0) * 0.24)
    }

    static func currentRealtimeVoiceConfiguration() -> RealtimeVoiceConfiguration? {
        guard let rawURL = PerryPreferences.realtimeVoiceEndpoint,
              let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["wss", "ws"].contains(scheme),
              url.host != nil else { return nil }
        let configuredModel = PerryPreferences.realtimeVoiceModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = configuredModel.isEmpty && url.host?.contains("api.openai.com") == true ? "gpt-realtime" : configuredModel
        guard !model.isEmpty else { return nil }
        let protocolMode = RealtimeVoiceProtocolMode(rawValue: PerryPreferences.realtimeVoiceProtocol) ?? .automatic
        let responseSpeed = PerryPreferences.realtimeVoiceSpeed
        let voice = PerryPreferences.realtimeVoiceVoice
        let instructions = PerryPreferences.realtimeVoiceInstructions
        return RealtimeVoiceConfiguration(
            endpoint: url,
            model: model,
            voice: voice,
            responseSpeed: responseSpeed,
            instructions: instructions,
            protocolMode: protocolMode
        )
    }

    /// Whether the shared speech engine is mid-utterance — Talk barge-in and
    /// the output adapter read this so every feature's speech is observed.
    var isSpeaking: Bool { synthesizer.isSpeaking }

    /// Global barge-in. All speech routes through this one synthesizer, so a
    /// single immediate stop silences Talk, Guide, and announcements alike.
    func shutUp() {
        synthesizer.stopSpeaking(at: .immediate)
        currentSpeechText = nil
    }

    /// Queued speech for Talk's sentence-chunked answers — unlike `speak`,
    /// which announces by interrupting, this appends to the synthesizer queue
    /// so streamed sentences play back-to-back.
    func enqueueSpeech(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let preferences = Self.currentSpeechPreferences()
        guard preferences.outputEnabled else { return }
        overlayState.taskBubbleText = cleaned
        let outputAvailable = AudioRouteMonitor.defaultOutputAvailable()
        guard outputAvailable, !AudioRouteMonitor.defaultOutputMuted() else {
            currentSpeechText = nil
            overlayState.voiceState = .idle
            hooks.setStatus(outputAvailable ? "Audio output is muted." : "No audio output is available.")
            return
        }
        overlayState.voiceState = .responding
        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.voice = Self.speakingVoice(for: lastDictationLanguageIdentifier)
        utterance.rate = Self.speechRate(for: preferences.rateMultiplier)
        synthesizer.speak(utterance)
    }

    /// `copiesReplyWhenMuted` is reserved for reply content — acknowledgments
    /// and prompts must never clobber the user's clipboard.
    func speak(_ text: String, guideSpeechIdentity: GuideSpeechIdentity? = nil, copiesReplyWhenMuted: Bool = false) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let preferences = Self.currentSpeechPreferences()
        overlayState.taskBubbleText = cleaned
        guard preferences.outputEnabled else {
            currentSpeechText = nil
            overlayState.voiceState = .idle
            return
        }
        let outputAvailable = AudioRouteMonitor.defaultOutputAvailable()
        let outputMuted = AudioRouteMonitor.defaultOutputMuted()
        guard outputAvailable, !outputMuted else {
            if copiesReplyWhenMuted {
                PerfMark.mark("talk.muted_clipboard")
                copyReplyToClipboard(
                    cleaned,
                    status: outputAvailable
                        ? "Audio output is muted; the reply is on your clipboard."
                        : "No audio output is available; the reply is on your clipboard."
                )
            } else {
                PerfMark.mark("talk.speak.muted")
                currentSpeechText = nil
                hooks.setStatus(outputAvailable ? "Audio output is muted." : "No audio output is available.")
            }
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        currentSpeechText = cleaned
        overlayState.voiceState = .responding
        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.voice = Self.speakingVoice(for: lastDictationLanguageIdentifier)
        utterance.rate = Self.speechRate(for: preferences.rateMultiplier)
        if let guideSpeechIdentity {
            guideSpeechIdentities[ObjectIdentifier(utterance)] = guideSpeechIdentity
        }
        synthesizer.speak(utterance)
        PerfMark.mark("talk.speak.start")
    }

    func deliverVoiceReply(_ text: String, guideSpeechIdentity: GuideSpeechIdentity? = nil) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if let realtimeVoiceSession {
            switch realtimeVoiceSession.state {
            case .connecting, .listening, .responding:
                realtimeVoiceSession.speakText(cleaned)
                return
            case .idle, .failed:
                break
            }
        }
        speak(cleaned, guideSpeechIdentity: guideSpeechIdentity, copiesReplyWhenMuted: true)
    }

    func previewSpeechVoice(_ voice: AVSpeechSynthesisVoice) {
        guard AudioRouteMonitor.defaultOutputAvailable(), !AudioRouteMonitor.defaultOutputMuted() else {
            hooks.setStatus("Audio output is unavailable; choose a voice after reconnecting it.")
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "This is Perry's voice.")
        utterance.voice = voice
        utterance.rate = Self.speechRate(for: Self.currentSpeechPreferences().rateMultiplier)
        synthesizer.speak(utterance)
    }

    func copyReplyToClipboard(_ text: String, status: String) {
        synthesizer.stopSpeaking(at: .immediate)
        currentSpeechText = nil
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        hooks.setStatus(status)
        Task {
            await notifier.deliver(
                TaskNotification(kind: .stopped, title: "Perry reply copied", body: text)
            )
        }
    }
}

extension VoiceController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in PerfMark.mark("talk.speak.audible") }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            PerfMark.mark("talk.speak.end")
            let guideIdentity = self.guideSpeechIdentities.removeValue(forKey: ObjectIdentifier(utterance))
            if !self.dictation.isRunning {
                self.overlayState.voiceState = .idle
            }
            if let guideIdentity {
                self.hooks.guideSpeechFinished(guideIdentity)
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let guideIdentity = self.guideSpeechIdentities.removeValue(forKey: ObjectIdentifier(utterance))
            if let guideIdentity {
                self.hooks.guideSpeechFinished(guideIdentity)
            }
        }
    }
}
