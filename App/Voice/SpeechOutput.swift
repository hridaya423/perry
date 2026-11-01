import AppKit
import ApplicationServices
import AVFoundation
import Speech
import PerryBrain
import PerryCore
import PerryGuide
import PerryOverlay
import PerryRuntimes

extension VoiceController {
    private static var voiceCache: [String: AVSpeechSynthesisVoice?] = [:]
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

    static func speechRate(for multiplier: Double) -> Float {
        let clamped = min(max(multiplier, 0.5), 1.5)
        return Float(0.42 + ((clamped - 0.5) / 1.0) * 0.24)
    }

    var isSpeaking: Bool { synthesizer.isSpeaking || neuralSpeech.isSpeaking }

    func shutUp() {
        stopSpeech(at: .immediate)
        currentSpeechText = nil
    }

    func stopSpeech(at boundary: AVSpeechBoundary) {
        synthesizer.stopSpeaking(at: boundary)
        neuralSpeech.stop()
        speechStream = SpeechText.Stream()
    }

    func neuralSpeechFinished() {
        if !dictation.isRunning { overlayState.voiceState = .idle }
        overlayState.expireTaskBubble(after: 1.5)
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

    func speakAndWait(_ text: String, limit: Duration = .seconds(15)) async {
        speak(text)
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        let started = clock.now + .seconds(1)
        while clock.now < deadline, isSpeaking || clock.now < started, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func speak(_ text: String, copiesReplyWhenMuted: Bool = false) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let preferences = Self.currentSpeechPreferences()
        if overlayState.panelScreenFrame == nil { overlayState.taskBubbleText = cleaned }
        guard preferences.outputEnabled else {
            currentSpeechText = nil
            overlayState.voiceState = .idle
            return
        }
        let (outputAvailable, outputMuted) = outputRoute()
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
        play(cleaned, route: route, rate: preferences.rateMultiplier)
        PerfMark.mark("talk.speak.start")
    }

    private func respelled(_ text: String) -> String {
        PronunciationStore.respell(text, with: PronunciationStore(directory: supportDirectory()).entries())
    }

    private func play(_ text: String, route: SpeechRoute, rate: Double) {
        switch route {
        case .system(let voice):
            let spoken = respelled(speechStream.next(text))
            guard !spoken.isEmpty else { return }
            overlayState.voiceState = .responding
            speakWithSystem(spoken, voice: voice, rate: rate)
        case .neural(let voice):
            let spoken = respelled(speechStream.next(text, spellNumbers: voice.spellsNumbers))
            guard !spoken.isEmpty else { return }
            overlayState.voiceState = .responding
            neuralSpeech.enqueue(spoken, voice: voice)
        case .silent:
            overlayState.voiceState = .idle
            hooks.setStatus(KokoroInstaller.shared.downloading
                ? "My voice is still downloading, so this reply is in text."
                : "Perry has no natural voice yet, so replies stay in text. Choose one in Settings > Voice.")
        }
    }

    func speakWithSystemVoice(_ text: String) {
        guard let voice = Self.speakingVoice(for: lastDictationLanguageIdentifier) else { return }
        speakWithSystem(text, voice: voice, rate: Self.currentSpeechPreferences().rateMultiplier)
    }

    private func speakWithSystem(_ text: String, voice: AVSpeechSynthesisVoice, rate: Double) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = Self.speechRate(for: rate)
        synthesizer.speak(utterance)
    }

    func deliverVoiceReply(_ text: String) {
        deliver(text, copiesWhenMuted: false)
    }

    func deliverAnswer(_ text: String) {
        deliver(text, copiesWhenMuted: true)
    }

    private func deliver(_ text: String, copiesWhenMuted: Bool) {
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
        speak(cleaned, copiesReplyWhenMuted: copiesWhenMuted)
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
        speakWithSystem("This is Perry's voice.", voice: voice, rate: Self.currentSpeechPreferences().rateMultiplier)
    }

    func copyReplyToClipboard(_ text: String, status: String) {
        synthesizer.stopSpeaking(at: .immediate)
        currentSpeechText = nil
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
            if !self.dictation.isRunning {
                self.overlayState.voiceState = .idle
            }
            if !self.synthesizer.isSpeaking {
                self.overlayState.expireTaskBubble(after: 1.5)
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.synthesizer.isSpeaking {
                self.overlayState.expireTaskBubble(after: 1.5)
            }
        }
    }
}
