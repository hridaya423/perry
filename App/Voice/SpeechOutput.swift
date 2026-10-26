import AppKit
import ApplicationServices
import AVFoundation
import Speech
import PerryBrain
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
        let natural = naturalVoices()
        if let identifier = preferences.voiceIdentifier,
           let selected = natural.first(where: { $0.identifier == identifier }) {
            return selected
        }
        let languageCode = languageIdentifier.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
        return recommendedSpeechVoices(from: natural, languageCode: languageCode ?? "en", limit: 1).first
    }

    static var speakingVoice: AVSpeechSynthesisVoice? {
        speakingVoice(for: nil)
    }

    static func isNaturalVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        isNatural(identifier: voice.identifier, quality: voice.quality)
    }

    static func isNatural(identifier: String, quality: AVSpeechSynthesisVoiceQuality) -> Bool {
        let identifier = identifier.lowercased()
        return (quality == .premium || quality == .enhanced)
            && !identifier.contains("siri") && !identifier.contains("eloquence")
            && !identifier.contains("speech.synthesis") && !identifier.contains("compact")
    }

    static func naturalVoices(from voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()) -> [AVSpeechSynthesisVoice] {
        voices.filter(isNaturalVoice)
    }

    static func recommendedSpeechVoices(
        from voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices(),
        languageCode: String = Locale.current.language.languageCode?.identifier ?? "en",
        limit: Int = 5
    ) -> [AVSpeechSynthesisVoice] {
        let region = Locale.current.region?.identifier
        let natural = naturalVoices(from: voices).filter {
            Locale(identifier: $0.language).language.languageCode?.identifier == languageCode
        }
        let ranked = natural.sorted { left, right in
            if left.quality != right.quality { return left.quality.rawValue > right.quality.rawValue }
            let leftLocal = Locale(identifier: left.language).region?.identifier == region
            let rightLocal = Locale(identifier: right.language).region?.identifier == region
            if leftLocal != rightLocal { return leftLocal }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
        var seenNames = Set<String>()
        return Array(ranked.filter { seenNames.insert($0.name).inserted }.prefix(limit))
    }

    enum SpeechRoute {
        case system(AVSpeechSynthesisVoice)
        case neural(any NeuralVoice)
        case silent
    }

    static func speechRoute(for languageIdentifier: String? = nil, engine: SpeechEngineChoice = .current, voiceID: String? = nil,
                            defaults: UserDefaults = .standard) -> SpeechRoute {
        let rate = currentSpeechPreferences(defaults: defaults).rateMultiplier
        switch engine {
        case .cloud(let provider):
            if let key = provider.storedKey() {
                let voiceID = voiceID ?? defaults.string(forKey: provider.voicePreferenceKey) ?? provider.defaultVoice.id
                return .neural(CloudVoice(provider: provider, voiceID: voiceID, key: key, speed: rate))
            }
        case .kokoro:
            if var kokoro = KokoroVoice.installed(speed: rate) {
                if let voiceID { kokoro = KokoroVoice(voice: voiceID, speed: rate) }
                return .neural(kokoro)
            }
        case .system:
            break
        }
        return speakingVoice(for: languageIdentifier).map(SpeechRoute.system) ?? .silent
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
            customWords: Array(dictionary.keys) + Array(dictionary.values)
                + PronunciationStore(directory: supportDirectory()).entries().map(\.written),
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

    /// Whether the shared speech engine is mid-utterance — Talk barge-in and
    /// the output adapter read this so every feature's speech is observed.
    var isSpeaking: Bool { synthesizer.isSpeaking || neuralSpeech.isSpeaking }

    func shutUp() {
        stopSpeech(at: .immediate)
        currentSpeechText = nil
    }

    func stopSpeech(at boundary: AVSpeechBoundary) {
        synthesizer.stopSpeaking(at: boundary)
        neuralSpeech.stop()
        speechStream = SpeechText.Stream()
        if let identity = pendingGuideIdentity {
            pendingGuideIdentity = nil
            hooks.guideSpeechFinished(identity)
        }
    }

    func neuralSpeechFinished() {
        if !dictation.isRunning { overlayState.voiceState = .idle }
        overlayState.expireTaskBubble(after: 1.5)
        if let identity = pendingGuideIdentity {
            pendingGuideIdentity = nil
            hooks.guideSpeechFinished(identity)
        }
    }

    func enqueueSpeech(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let preferences = Self.currentSpeechPreferences()
        guard preferences.outputEnabled else { return }
        if overlayState.panelScreenFrame == nil { overlayState.taskBubbleText = cleaned }
        let outputAvailable = AudioRouteMonitor.defaultOutputAvailable()
        guard outputAvailable, !AudioRouteMonitor.defaultOutputMuted() else {
            currentSpeechText = nil
            overlayState.voiceState = .idle
            hooks.setStatus(outputAvailable ? "Audio output is muted." : "No audio output is available.")
            return
        }
        if !isSpeaking { speechStream = SpeechText.Stream() }
        play(cleaned, route: Self.speechRoute(for: lastDictationLanguageIdentifier), rate: preferences.rateMultiplier)
    }

    func speak(_ text: String, guideSpeechIdentity: GuideSpeechIdentity? = nil, copiesReplyWhenMuted: Bool = false) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let preferences = Self.currentSpeechPreferences()
        if overlayState.panelScreenFrame == nil { overlayState.taskBubbleText = cleaned }
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
        stopSpeech(at: .immediate)
        currentSpeechText = cleaned
        let route = Self.speechRoute(for: lastDictationLanguageIdentifier)
        if case .system = route, let guideSpeechIdentity {
            play(cleaned, route: route, rate: preferences.rateMultiplier) { utterance in
                self.guideSpeechIdentities[ObjectIdentifier(utterance)] = guideSpeechIdentity
            }
        } else {
            play(cleaned, route: route, rate: preferences.rateMultiplier)
            if let guideSpeechIdentity {
                if case .neural = route { pendingGuideIdentity = guideSpeechIdentity } else { hooks.guideSpeechFinished(guideSpeechIdentity) }
            }
        }
        PerfMark.mark("talk.speak.start")
    }

    private func respelled(_ text: String) -> String {
        PronunciationStore.respell(text, with: PronunciationStore(directory: supportDirectory()).entries())
    }

    private func play(_ text: String, route: SpeechRoute, rate: Double, prepare: (AVSpeechUtterance) -> Void = { _ in }) {
        switch route {
        case .system(let voice):
            let spoken = respelled(speechStream.next(text))
            guard !spoken.isEmpty else { return }
            overlayState.voiceState = .responding
            let utterance = AVSpeechUtterance(string: spoken)
            utterance.voice = voice
            utterance.rate = Self.speechRate(for: rate)
            prepare(utterance)
            synthesizer.speak(utterance)
        case .neural(let voice):
            let spoken = respelled(speechStream.next(text, spellNumbers: voice.spellsNumbers))
            guard !spoken.isEmpty else { return }
            overlayState.voiceState = .responding
            neuralSpeech.enqueue(spoken, voice: voice)
        case .silent:
            overlayState.voiceState = .idle
            hooks.setStatus("Perry has no natural voice yet, so replies stay in text. Choose one in Settings > Voice.")
        }
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

    func preview(_ text: String, engine: SpeechEngineChoice, voiceID: String? = nil) {
        guard AudioRouteMonitor.defaultOutputAvailable(), !AudioRouteMonitor.defaultOutputMuted() else {
            hooks.setStatus("Audio output is unavailable. Turn the sound on to hear the voice.")
            return
        }
        stopSpeech(at: .immediate)
        play(text, route: Self.speechRoute(engine: engine, voiceID: voiceID), rate: Self.currentSpeechPreferences().rateMultiplier)
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
            if !self.synthesizer.isSpeaking {
                self.overlayState.expireTaskBubble(after: 1.5)
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
            if !self.synthesizer.isSpeaking {
                self.overlayState.expireTaskBubble(after: 1.5)
            }
            if let guideIdentity {
                self.hooks.guideSpeechFinished(guideIdentity)
            }
        }
    }
}
