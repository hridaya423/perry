import AppKit
import AVFoundation
import Speech
import PerryCapture
import PerryCore
import PerryGuide
import PerryOverlay
import PerryRuntimes

/// Owns the voice surface end to end: push-to-talk and wake-word listeners,
/// on-device dictation, realtime voice sessions, speech output, and
/// voice-typed text insertion. Session routing (guide/do/panel) and status
/// text reach the session shell through explicit hooks.
@MainActor
final class VoiceController: NSObject, ObservableObject {
    struct Hooks {
        var setStatus: (String) -> Void = { _ in }
        var setTranscriptPreview: (String) -> Void = { _ in }
        var dispatch: (String?) -> Void = { _ in }
        var wake: () -> Void = {}
        var sessionIsIdle: () -> Bool = { false }
        var refreshStatusItem: () -> Void = {}
        var guideSpeechFinished: (GuideSpeechIdentity) -> Void = { _ in }
    }

    static let speechOutputEnabledKey = "perry.speech.outputEnabled"
    static let speechRateKey = "perry.speech.rate"
    static let speechVoiceKey = "perry.speech.voiceIdentifier"
    static let dictationLanguageKey = "perry.dictation.language"
    static let dictationInputDeviceKey = "perry.dictation.inputDeviceID"
    static let realtimeVoiceEndpointKey = "perry.realtimeVoice.endpoint"
    static let realtimeVoiceModelKey = "perry.realtimeVoice.model"
    static let realtimeVoiceVoiceKey = "perry.realtimeVoice.voice"
    static let realtimeVoiceSpeedKey = "perry.realtimeVoice.speed"
    static let realtimeVoiceInstructionsKey = "perry.realtimeVoice.instructions"
    static let realtimeVoiceProtocolKey = "perry.realtimeVoice.protocol"
    static let realtimeVoiceKeychainAccount = "realtime.voice"

    private let overlayState: PerryCursorState
    private let workers: CuaWorkerService
    private let notifier: any AppNotificationClient
    private let supportDirectory: () -> URL?
    private let hooks: Hooks

    let synthesizer = AVSpeechSynthesizer()
    private var currentSpeechText: String?
    private var guideSpeechIdentities: [ObjectIdentifier: GuideSpeechIdentity] = [:]
    private var realtimeVoiceSession: RealtimeVoiceSession?
    private var realtimeTranscriptBuffer = ""
    private var realtimeCommandDispatched = false
    private var dictationAttemptID: UUID?
    private var dictationWorkerTask: Task<Void, Never>?
    private var dictationInsertionID: UUID?
    /// Post-insert edit watch for learn-on-edit (see scheduleDictationLearnChecks).
    private var dictationLearnCheckTask: Task<Void, Never>?
    private var voiceInvocation = VoiceInvocationGate()
    private var dictationSpeechEndedAt: UInt64?
    private var dictationTargetApplication: NSRunningApplication?
    private var lastDictationLanguageIdentifier: String?

    private lazy var performanceSampleLog: PerformanceSampleLog? = {
        do {
            return try PerformanceSampleLog.shared.get()
        } catch {
            hooks.setStatus("Performance recording is unavailable: \(error.localizedDescription)")
            return nil
        }
    }()

    private lazy var dictation = DictationController(
        onTranscript: { [weak self] transcript in
            guard let invocationID = self?.voiceInvocation.id else { return }
            Task { @MainActor [weak self] in
                guard let self, self.voiceInvocation.claim(invocationID) else { return }
                self.handleTranscript(transcript)
            }
        },
        onPartial: { [weak self] transcript in
            guard let invocationID = self?.voiceInvocation.id else { return }
            Task { @MainActor [weak self] in
                guard let self, self.voiceInvocation.id == invocationID else { return }
                self.handlePartialTranscript(transcript)
            }
        },
        onFailure: { [weak self] error in
            guard let invocationID = self?.voiceInvocation.id else { return }
            Task { @MainActor [weak self] in
                guard let self, self.voiceInvocation.id == invocationID else { return }
                self.handleDictationFailure(error)
            }
        },
        onFallback: { [weak self] in
            guard let invocationID = self?.voiceInvocation.id else { return }
            Task { @MainActor [weak self] in
                guard let self, self.voiceInvocation.id == invocationID else { return }
                self.speak("Your usual microphone stopped responding, so I switched to the built-in microphone.")
            }
        },
        onLanguageDetected: { [weak self] identifier in
            guard let invocationID = self?.voiceInvocation.id else { return }
            Task { @MainActor [weak self] in
                guard let self, self.voiceInvocation.id == invocationID else { return }
                self.handleDetectedLanguage(identifier)
            }
        }
    )

    private lazy var pushToTalk = PushToTalkController(
        shortcut: PushToTalkShortcut(rawValue: UserDefaults.standard.string(forKey: "perry.ptt.shortcut") ?? "") ?? .optionCommandSpace,
        onPress: { [weak self] in self?.beginDictation() },
        onRelease: { [weak self] in self?.finishDictation() }
    )

    private lazy var audioRouteMonitor = AudioRouteMonitor { [weak self] deviceName in
        self?.handleAudioRouteChange(deviceName)
    } onOutputMuted: { [weak self] in
        self?.handleMutedOutput()
    }

    private lazy var wakeWordListener = WakeWordListener(
        onWake: { [weak self] command in
            Task { @MainActor [weak self] in self?.handleWakeWord(command) }
        },
        onFailure: { [weak self] reason in
            Task { @MainActor [weak self] in
                guard let self, UserDefaults.standard.bool(forKey: "perry.wakeWord.enabled") else { return }
                UserDefaults.standard.set(false, forKey: "perry.wakeWord.enabled")
                self.hooks.refreshStatusItem()
                self.hooks.setStatus("Wake word is unavailable: \(reason). Use the hotkey instead.")
            }
        }
    )

    private var wakeWordGate: WakeWordGate {
        WakeWordGate(enabled: UserDefaults.standard.bool(forKey: "perry.wakeWord.enabled"))
    }

    init(
        overlayState: PerryCursorState,
        workers: CuaWorkerService,
        notifier: any AppNotificationClient,
        supportDirectory: @escaping () -> URL?,
        hooks: Hooks
    ) {
        self.overlayState = overlayState
        self.workers = workers
        self.notifier = notifier
        self.supportDirectory = supportDirectory
        self.hooks = hooks
        super.init()
        synthesizer.delegate = self
    }

    /// Starts the global input listeners once the app is up.
    func startInputListeners() {
        pushToTalk.start()
        audioRouteMonitor.start()
    }

    // MARK: Speech out

    static func speakingVoice(for languageIdentifier: String? = nil) -> AVSpeechSynthesisVoice? {
        let preferences = currentSpeechPreferences()
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

    static func currentSpeechPreferences(defaults: UserDefaults = .standard) -> SpeechPreferences {
        let enabled = defaults.object(forKey: speechOutputEnabledKey) as? Bool ?? true
        let rate = defaults.object(forKey: speechRateKey) as? Double ?? 1
        return SpeechPreferences(
            outputEnabled: enabled,
            rateMultiplier: rate,
            voiceIdentifier: defaults.string(forKey: speechVoiceKey)
        )
    }

    func currentDictationPreferences() throws -> DictationPreferences {
        let language: DictationLanguageMode
        if let raw = UserDefaults.standard.string(forKey: Self.dictationLanguageKey), !raw.isEmpty, raw != "automatic" {
            language = .fixed(identifier: raw)
        } else {
            language = .automatic
        }
        let dictionary = try VoiceDictionaryStore(supportDirectory: supportDirectory()).entries()
        let inputDeviceID = UserDefaults.standard.object(forKey: Self.dictationInputDeviceKey).flatMap { value in
            if let number = value as? NSNumber { return number.uint32Value }
            return nil
        }
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
        defaults.set(preferences.outputEnabled, forKey: speechOutputEnabledKey)
        defaults.set(preferences.rateMultiplier, forKey: speechRateKey)
        if let voiceIdentifier = preferences.voiceIdentifier {
            defaults.set(voiceIdentifier, forKey: speechVoiceKey)
        } else {
            defaults.removeObject(forKey: speechVoiceKey)
        }
    }

    func updateSpeechPreferences(_ preferences: SpeechPreferences) {
        Self.saveSpeechPreferences(preferences)
    }

    func updateDictationPreferences(_ preferences: DictationPreferences) {
        switch preferences.language {
        case .automatic:
            UserDefaults.standard.set("automatic", forKey: Self.dictationLanguageKey)
        case .fixed(let identifier):
            UserDefaults.standard.set(identifier, forKey: Self.dictationLanguageKey)
        }
        if let inputDeviceID = preferences.inputDeviceID {
            UserDefaults.standard.set(Int(inputDeviceID), forKey: Self.dictationInputDeviceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.dictationInputDeviceKey)
        }
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
        guard let rawURL = UserDefaults.standard.string(forKey: realtimeVoiceEndpointKey),
              let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["wss", "ws"].contains(scheme),
              url.host != nil else { return nil }
        let configuredModel = UserDefaults.standard.string(forKey: realtimeVoiceModelKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = configuredModel.isEmpty && url.host?.contains("api.openai.com") == true ? "gpt-realtime" : configuredModel
        guard !model.isEmpty else { return nil }
        let protocolMode = UserDefaults.standard.string(forKey: realtimeVoiceProtocolKey)
            .flatMap(RealtimeVoiceProtocolMode.init(rawValue:)) ?? .automatic
        let responseSpeed = UserDefaults.standard.object(forKey: realtimeVoiceSpeedKey) as? Double ?? 1
        let voice = UserDefaults.standard.string(forKey: realtimeVoiceVoiceKey) ?? "marin"
        let instructions = UserDefaults.standard.string(forKey: realtimeVoiceInstructionsKey)
            ?? "You are Perry, a concise and helpful desktop voice assistant. Speak naturally and keep replies short unless the user asks for detail."
        return RealtimeVoiceConfiguration(
            endpoint: url,
            model: model,
            voice: voice,
            responseSpeed: responseSpeed,
            instructions: instructions,
            protocolMode: protocolMode
        )
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

    // MARK: Dictation input

    func beginDictation() {
        dictationAttemptID = nil
        dictation.cancel()
        voiceInvocation.begin()
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        dictationTargetApplication = frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            ? nil
            : frontmostApplication
        if let realtimeVoiceSession {
            switch realtimeVoiceSession.state {
            case .connecting, .listening, .responding:
                wakeWordListener.stop()
                synthesizer.stopSpeaking(at: .immediate)
                realtimeTranscriptBuffer = ""
                realtimeCommandDispatched = false
                realtimeVoiceSession.beginInput()
                overlayState.voiceState = .listening
                overlayState.buddyState = .listening
                hooks.setStatus("Listening via realtime voice — release the shortcut when you’re done.")
                return
            case .idle, .failed:
                realtimeVoiceSession.stop()
                self.realtimeVoiceSession = nil
            }
        }
        realtimeTranscriptBuffer = ""
        realtimeCommandDispatched = false
        if let configuration = Self.currentRealtimeVoiceConfiguration() {
            let apiKey: String?
            do {
                apiKey = try KeychainStore().readChecked(account: Self.realtimeVoiceKeychainAccount)
            } catch {
                hooks.setStatus("Perry could not read the realtime voice credential from Keychain; continuing with on-device dictation.")
                beginLocalDictation()
                return
            }
            if let apiKey, !apiKey.isEmpty {
                wakeWordListener.stop()
                synthesizer.stopSpeaking(at: .word)
                lastDictationLanguageIdentifier = nil
                overlayState.voiceState = .listening
                overlayState.buddyState = .listening
                hooks.setStatus("Connecting to realtime voice…")
                let session = RealtimeVoiceSession(
                    configuration: configuration,
                    apiKey: apiKey,
                    onPerformanceSample: { [weak self] sample in
                        self?.recordPerformanceSample(sample)
                    },
                    onPerformanceMarker: { [weak self] marker in
                        self?.recordPerformanceMarker(marker)
                    },
                    onTaskSnapshot: { [weak self] snapshot in
                        self?.recordTaskSnapshot(snapshot)
                    },
                    onEvent: { [weak self] event in
                        self?.handleRealtimeVoiceEvent(event)
                    }
                )
                realtimeVoiceSession = session
                session.start()
                return
            }
        }
        beginLocalDictation()
    }

    private func beginLocalDictation() {
        wakeWordListener.stop()
        synthesizer.stopSpeaking(at: .word)
        lastDictationLanguageIdentifier = nil
        do {
            dictation.configure(try currentDictationPreferences())
        } catch {
            dictation.configure(.default)
            hooks.setStatus("Voice dictionary unavailable: \(error.localizedDescription)")
        }
        overlayState.voiceState = .listening
        overlayState.buddyState = .listening
        hooks.setStatus("Listening on \(dictation.activeInputDeviceName()) — release ⌥⌘Space when you’re done.")
        let attemptID = UUID()
        dictationAttemptID = attemptID
        Task { @MainActor in
            let granted = await DictationController.requestPermission()
            guard dictationAttemptID == attemptID else { return }
            guard granted else {
                dictationAttemptID = nil
                voiceInvocation.cancel()
                overlayState.voiceState = .idle
                overlayState.buddyState = .idle
                hooks.setStatus("Microphone permission is optional; type your request instead.")
                speak("Allow microphone access and I'll listen.")
                return
            }
            do {
                try dictation.start()
                dictationAttemptID = nil
            } catch {
                dictationAttemptID = nil
                overlayState.voiceState = .idle
                overlayState.buddyState = .idle
                handleDictationFailure(error)
                speak("Couldn't start listening: \(error.localizedDescription)")
            }
        }
    }

    func finishDictation() {
        voiceInvocation.finishInput()
        dictationAttemptID = nil
        dictationSpeechEndedAt = DispatchTime.now().uptimeNanoseconds
        if let realtimeVoiceSession {
            realtimeVoiceSession.finishInput()
            overlayState.voiceState = .processing
            overlayState.buddyState = .thinking
            hooks.setStatus("Finalizing your request…")
            return
        }
        dictation.finish()
        overlayState.voiceState = .idle
        overlayState.buddyState = .idle
    }

    func cancelInput() {
        voiceInvocation.cancel()
        dictationAttemptID = nil
        dictationSpeechEndedAt = nil
        dictationTargetApplication = nil
        dictationInsertionID = nil
        dictationWorkerTask?.cancel()
        dictationLearnCheckTask?.cancel()
        realtimeVoiceSession?.stop()
        realtimeVoiceSession = nil
        realtimeTranscriptBuffer = ""
        dictation.cancel()
        overlayState.voiceState = .idle
        overlayState.buddyState = .idle
    }

    /// Waits for in-flight dictation insertion work; used before worker shutdown.
    func joinInputWork() async {
        dictationLearnCheckTask?.cancel()
        await dictationWorkerTask?.value
    }

    private func handlePartialTranscript(_ text: String) {
        hooks.setTranscriptPreview(text)
        overlayState.voiceState = .listening
        overlayState.taskBubbleText = text
        hooks.setStatus(text)
    }

    private func handleDetectedLanguage(_ identifier: String?) {
        lastDictationLanguageIdentifier = identifier
        guard let identifier else { return }
        hooks.setStatus("Detected \(DictationController.languageName(for: identifier)).")
    }

    private func handleRealtimeVoiceEvent(_ event: RealtimeVoiceEvent) {
        switch event {
        case .transcriptDelta(let text):
            if realtimeTranscriptBuffer.isEmpty || !text.hasPrefix(realtimeTranscriptBuffer) {
                realtimeTranscriptBuffer += text
            } else {
                realtimeTranscriptBuffer = text
            }
            handlePartialTranscript(realtimeTranscriptBuffer)
        case .transcriptFinal(let text):
            let transcript = text.isEmpty ? realtimeTranscriptBuffer : text
            realtimeTranscriptBuffer = ""
            guard !realtimeCommandDispatched, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard let invocationID = voiceInvocation.id, voiceInvocation.claim(invocationID) else { return }
            realtimeCommandDispatched = true
            handleTranscript(transcript)
        case .error(let message):
            guard realtimeVoiceSession != nil else { return }
            realtimeVoiceSession?.stop()
            realtimeVoiceSession = nil
            realtimeTranscriptBuffer = ""
            if message == RealtimeVoiceError.emptyInput.localizedDescription {
                handleDictationFailure()
                hooks.setStatus("No audio was recorded. Hold the shortcut to try again, or type your request.")
            } else if voiceInvocation.inputOpen {
                hooks.setStatus("Realtime voice failed; continuing with on-device dictation.")
                beginLocalDictation()
            } else {
                voiceInvocation.cancel()
                handleDictationFailure()
                hooks.setStatus("Realtime voice failed after recording ended. Hold the shortcut to try again, or type your request.")
            }
            if !message.isEmpty {
                hooks.setTranscriptPreview(message)
            }
        case .assistantTranscriptDelta(let text, _):
            overlayState.voiceState = .responding
            overlayState.taskBubbleText = text
        case .assistantTranscriptFinal(let text, _):
            overlayState.voiceState = .responding
            overlayState.taskBubbleText = text
            hooks.setStatus(text)
        case .responseStarted:
            overlayState.voiceState = .responding
            overlayState.animation = .waving
            hooks.setStatus("Perry is replying…")
        case .responseFinished:
            overlayState.voiceState = .idle
            overlayState.buddyState = .idle
        case .responseInterrupted:
            overlayState.voiceState = .listening
            overlayState.buddyState = .listening
        case .speechStarted:
            overlayState.voiceState = .listening
        case .sessionReady, .speechStopped, .audio, .ignored:
            break
        }
    }

    private func recordPerformanceSample(_ sample: PerformanceSample) {
        guard let performanceSampleLog else { return }
        Task { @MainActor [weak self] in
            do {
                try await performanceSampleLog.append(sample)
            } catch {
                self?.hooks.setStatus("Performance recording failed: \(error.localizedDescription)")
            }
        }
    }

    private func recordPerformanceMarker(_ marker: PerformanceMarker) {
        guard let performanceSampleLog else { return }
        Task { @MainActor [weak self] in
            do {
                try await performanceSampleLog.append(marker)
            } catch {
                self?.hooks.setStatus("Performance recording failed: \(error.localizedDescription)")
            }
        }
    }

    private func recordTaskSnapshot(_ snapshot: RealtimeTaskSnapshot) {
        guard let performanceSampleLog else { return }
        Task { @MainActor [weak self] in
            do {
                try await performanceSampleLog.append(snapshot)
            } catch {
                self?.hooks.setStatus("Performance recording failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleDictationFailure(_ error: Error? = nil) {
        voiceInvocation.cancel()
        overlayState.voiceState = .idle
        overlayState.buddyState = .blocked
        hooks.setStatus(error?.localizedDescription ?? "Voice input failed; you can type the request.")
    }

    private func handleAudioRouteChange(_ deviceName: String) {
        realtimeVoiceSession?.refreshAudioRoute()
        guard synthesizer.isSpeaking else { return }
        let reply = currentSpeechText
        let routeMessage = "I switched the reply to \(deviceName)."
        hooks.setStatus("Audio moved to \(deviceName).")
        speak(routeMessage)
        guard let reply else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.synthesizer.isSpeaking, self.currentSpeechText == routeMessage else { return }
            self.speak(reply)
        }
    }

    private func handleMutedOutput() {
        guard synthesizer.isSpeaking, let currentSpeechText else { return }
        copyReplyToClipboard(
            currentSpeechText,
            status: "Audio output was muted; the reply is on your clipboard."
        )
    }

    private func handleTranscript(_ text: String) {
        hooks.setTranscriptPreview("")
        overlayState.voiceState = .processing
        realtimeVoiceSession?.cancelCurrentResponse()
        let frontmostApplication = dictationTargetApplication
        dictationTargetApplication = nil
        let frontmostBundleID = frontmostApplication?.bundleIdentifier
        let normalized: String
        do {
            normalized = try VoiceTextNormalizer.normalize(
                text,
                frontmostBundleID: frontmostBundleID,
                supportDirectory: supportDirectory()
            )
        } catch {
            hooks.setStatus("Voice dictionary unavailable: \(error.localizedDescription)")
            deliverVoiceReply("I couldn't read your voice dictionary, so I stopped before dispatching that request.")
            return
        }
        let request: String
        if let command = wakeWordGate.match(inTranscript: normalized) {
            deliverVoiceReply("Wake word heard.")
            request = command
        } else {
            request = normalized
        }
        if let insertion = VoiceTextPolicy.insertionText(
            from: request,
            frontmostBundleID: frontmostBundleID,
            dictionary: [:]
        ) {
            guard let frontmostApplication else {
                dictationSpeechEndedAt = nil
                deliverVoiceReply("I couldn't identify the target app, so I stopped.")
                return
            }
            insertTextIntoFrontmostApp(insertion, target: frontmostApplication)
            return
        }
        dictationSpeechEndedAt = nil
        hooks.dispatch(request.isEmpty ? nil : request)
    }

    private func insertTextIntoFrontmostApp(_ text: String, target: NSRunningApplication) {
        guard let bundleID = target.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else {
            dictationInsertionID = nil
            dictationWorkerTask?.cancel()
            hooks.setStatus("Keep the target app focused and I’ll type there.")
            return
        }
        let speechEndedAt = dictationSpeechEndedAt
        dictationSpeechEndedAt = nil
        let language = lastDictationLanguageIdentifier
        let targetHint = CuaTargetHint(bundleID: bundleID, processID: target.processIdentifier)
        let insertionID = UUID()
        let previousTask = dictationWorkerTask
        dictationInsertionID = insertionID
        dictationLearnCheckTask?.cancel()
        previousTask?.cancel()
        hooks.setStatus("Typing through Cua…")
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if let previousTask {
                await previousTask.value
            }
            guard self.dictationInsertionID == insertionID else {
                if self.dictationInsertionID == nil {
                    self.dictationWorkerTask = nil
                }
                return
            }
            do {
                try await self.workers.withWorker(
                    scope: .dictation,
                    resources: [.application(bundleID)]
                ) { @MainActor worker in
                    _ = try await worker.insertText(text, target: targetHint)
                    guard let speechEndedAt,
                          let performanceSampleLog = self.performanceSampleLog else { return }
                    let elapsed = DispatchTime.now().uptimeNanoseconds - speechEndedAt
                    do {
                        try await performanceSampleLog.append(PerformanceSample(
                            metricID: "dictation.speech_end_to_insert",
                            collector: "perry.app.cua-dictation-insert.v1",
                            unit: "ms",
                            value: Double(elapsed) / 1_000_000,
                            scenario: "cua-verified-text-insertion"
                        ))
                    } catch {
                        guard self.dictationInsertionID == insertionID, !Task.isCancelled else { return }
                        self.hooks.setStatus("Performance recording failed: \(error.localizedDescription)")
                    }
                }
                guard self.dictationInsertionID == insertionID else {
                    if self.dictationInsertionID == nil {
                        self.dictationWorkerTask = nil
                    }
                    return
                }
                self.dictationInsertionID = nil
                self.dictationWorkerTask = nil
                self.deliverVoiceReply("Typed it.")
                self.recordDictationBackup(text, language: language)
                self.scheduleDictationLearnChecks(
                    inserted: text, target: targetHint, bundleID: bundleID, insertedAt: Date()
                )
            } catch {
                guard self.dictationInsertionID == insertionID else {
                    if self.dictationInsertionID == nil {
                        self.dictationWorkerTask = nil
                    }
                    return
                }
                self.dictationInsertionID = nil
                self.dictationWorkerTask = nil
                guard !Task.isCancelled else { return }
                self.hooks.setStatus("Perry did not type because Cua could not verify the target field: \(error.localizedDescription)")
                self.deliverVoiceReply("I couldn't verify the text insertion, so I stopped.")
            }
        }
        dictationWorkerTask = task
    }

    /// Phase 8: every delivered dictation lands in the 7-day rolling backup
    /// (text only — audio is never stored).
    private func recordDictationBackup(_ text: String, language: String?) {
        guard let support = supportDirectory() else { return }
        try? DictationBackupStore(
            directory: support.appendingPathComponent("dictation-backup", isDirectory: true)
        ).record(text: text, language: language)
    }

    /// Learn-on-edit: re-read the target window ~8s and ~17s after insertion
    /// and, if the field the text landed in has been edited, merge the
    /// word substitutions into the voice dictionary. Token-count equality
    /// inside `PersonalDictionaryLearner` keeps unrelated edits from
    /// teaching anything.
    private func scheduleDictationLearnChecks(
        inserted text: String, target: CuaTargetHint, bundleID: String, insertedAt: Date
    ) {
        dictationLearnCheckTask?.cancel()
        dictationLearnCheckTask = Task { @MainActor [weak self] in
            for delay in [8.0, 9.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                await self.learnDictationEdits(
                    inserted: text, target: target, bundleID: bundleID, insertedAt: insertedAt
                )
            }
        }
    }

    private static let dictationTextRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXWebArea", "AXScrollArea", "AXStaticText", "AXComboBox",
    ]

    private func learnDictationEdits(
        inserted: String, target: CuaTargetHint, bundleID: String, insertedAt: Date
    ) async {
        let insertedTokens = DictationCleanupGuard.tokens(inserted)
        guard !insertedTokens.isEmpty else { return }
        do {
            let captured = try await workers.withWorker(
                scope: .dictation, resources: [.application(bundleID)]
            ) { worker in
                try await worker.capture(target: target)
            }
            let candidates = (captured.accessibilitySnapshotModel?.elements ?? [])
                .filter { Self.dictationTextRoles.contains($0.rawRole ?? "") }
                .compactMap(\.value)
            // The element holding the insertion shares the most tokens with it.
            let best = candidates.max {
                DictationCleanupGuard.tokens($0).filter { Set(insertedTokens).contains($0) }.count
                    < DictationCleanupGuard.tokens($1).filter { Set(insertedTokens).contains($0) }.count
            }
            guard let best else { return }
            let learned = PersonalDictionaryLearner.learn(
                inserted: inserted, observed: best, insertedAt: insertedAt, observedAt: Date()
            )
            guard !learned.isEmpty else { return }
            for (spoken, replacement) in learned {
                try? VoiceDictionaryStore(supportDirectory: supportDirectory())
                    .set(spoken: spoken, replacement: replacement)
            }
        } catch {
            // Best-effort: a new dictation holds the .dictation worker, and
            // the target may have closed — nothing to learn either way.
        }
    }

    // MARK: Shortcuts and wake word

    func updatePushToTalkShortcut(_ shortcut: PushToTalkShortcut) {
        pushToTalk.update(shortcut: shortcut)
    }

    func updateWakeWordEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "perry.wakeWord.enabled")
        hooks.refreshStatusItem()
        if enabled {
            Task { @MainActor in
                guard await DictationController.requestPermission() else {
                    UserDefaults.standard.set(false, forKey: "perry.wakeWord.enabled")
                    self.hooks.refreshStatusItem()
                    self.hooks.setStatus("Wake word needs microphone and speech permission; the hotkey still works.")
                    return
                }
                self.refreshWakeWordListener()
            }
        } else {
            wakeWordListener.stop()
        }
    }

    func refreshWakeWordListener() {
        guard UserDefaults.standard.bool(forKey: "perry.wakeWord.enabled"), hooks.sessionIsIdle() else {
            wakeWordListener.stop()
            return
        }
        if let realtimeVoiceSession, realtimeVoiceSession.state != .idle {
            wakeWordListener.stop()
            return
        }
        guard PerryPermissionProbe.checkMicrophone() == .granted,
              SFSpeechRecognizer.authorizationStatus() == .authorized else {
            UserDefaults.standard.set(false, forKey: "perry.wakeWord.enabled")
            hooks.refreshStatusItem()
            hooks.setStatus("Wake word is off because microphone or speech permission is unavailable.")
            return
        }
        wakeWordListener.start()
    }

    private func handleWakeWord(_ command: String) {
        guard hooks.sessionIsIdle() else { return }
        hooks.wake()
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            speak("I’m listening.")
        } else {
            hooks.dispatch(trimmed)
        }
    }

#if DEBUG
    func debugSimulateDictationFailure() {
        dictation.simulateInputFailure()
    }

    func debugSimulateAudioRouteChange(_ deviceName: String) {
        handleAudioRouteChange(deviceName)
    }
#endif
}

extension VoiceController: AVSpeechSynthesizerDelegate {
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
