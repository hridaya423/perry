import AppKit
import ApplicationServices
import AVFoundation
import Speech
import PerryBrain
import PerryCore
import PerryGuide
import PerryOverlay
import PerryRuntimes

@MainActor
final class VoiceController: NSObject, ObservableObject {
    struct Hooks {
        var setStatus: (String) -> Void = { _ in }
        var setTranscriptPreview: (String) -> Void = { _ in }
        var dispatch: (_ text: String?, _ taskScope: UUID?) -> Void = { _, _ in }
        var wake: () -> Void = {}
        var sessionIsIdle: () -> Bool = { false }
        var wakeListeningChanged: (Bool) -> Void = { _ in }
        var executingTaskID: () -> UUID? = { nil }
    }

    let overlayState: PerryCursorState
    let workers: ScreenWorkerService
    let notifier: any AppNotificationClient
    let supportDirectory: () -> URL?
    let hooks: Hooks

    let synthesizer = AVSpeechSynthesizer()
    let neuralSpeech = NeuralSpeechPlayer()
    var speechStream = SpeechText.Stream()
    var currentSpeechText: String?
    var realtimeVoiceSession: RealtimeVoiceSession?
    private var realtimeTranscriptBuffer = ""
    private var realtimeCommandDispatched = false
    private var dictationAttemptID: UUID?
    var dictationScopedTaskID: UUID?
    var dictationInsertsWithoutPrefix = false
    var dictationWorkerTask: Task<Void, Never>?
    var dictationInsertionID: UUID?
    var dictationLearnCheckTask: Task<Void, Never>?
    private var voiceInvocation = VoiceInvocationGate()
    var dictationSpeechEndedAt: UInt64?
    var dictationTargetApplication: NSRunningApplication?
    var lastDictationLanguageIdentifier: String?
    var pasteboard = NSPasteboard.general
    var outputRoute: () -> (available: Bool, muted: Bool) = {
        (AudioRouteMonitor.defaultOutputAvailable(), AudioRouteMonitor.defaultOutputMuted())
    }

    lazy var performanceSampleLog: PerformanceSampleLog? = {
        do {
            return try PerformanceSampleLog.shared.get()
        } catch {
            hooks.setStatus("Performance recording is unavailable: \(error.localizedDescription)")
            return nil
        }
    }()

    var requestDictationPermission: () async -> Bool = DictationController.ensurePermission
    var readRealtimeVoiceAPIKey: @MainActor () throws -> String? = {
        try RealtimeProvider.current?.apiKey()
    }
    lazy var startDictationCapture: @MainActor () throws -> Void = { [weak self] in
        guard let self else { return }
        try self.dictation.start()
    }
    lazy var makeRealtimeVoiceSession: @MainActor (
        _ configuration: RealtimeVoiceConfiguration,
        _ apiKey: String,
        _ onEvent: @escaping (RealtimeVoiceEvent) -> Void
    ) -> RealtimeVoiceSession = { [weak self] configuration, apiKey, onEvent in
        RealtimeVoiceSession(
            configuration: configuration,
            apiKey: apiKey,
            onPerformanceSample: { sample in self?.recordPerformance { try await $0.append(sample) } },
            onPerformanceMarker: { marker in self?.recordPerformance { try await $0.append(marker) } },
            onTaskSnapshot: { snapshot in self?.recordPerformance { try await $0.append(snapshot) } },
            onEvent: onEvent
        )
    }

    lazy var dictation = DictationController(
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
        gesture: PerryPreferences.dictateGesture,
        onPress: { [weak self] in self?.beginDictation(insertsWithoutPrefix: true) },
        onRelease: { [weak self] in self?.finishDictation() }
    )

    private lazy var audioRouteMonitor = AudioRouteMonitor { [weak self] deviceName in
        self?.handleAudioRouteChange(deviceName)
    } onOutputMuted: { [weak self] in
        self?.handleMutedOutput()
    }

    lazy var wakeWordListener: WakeWordListener = WakeWordListener(
        onWake: { [weak self] command in
            Task { @MainActor [weak self] in self?.handleWakeWord(command) }
        },
        onHeard: { [weak self] in
            Task { @MainActor [weak self] in self?.handleWakeHeard() }
        },
        onFailure: { [weak self] reason in
            Task { @MainActor [weak self] in
                guard let self, !self.wakeWordListener.isRunning else { return }
                self.hooks.wakeListeningChanged(false)
                guard PerryPreferences.wakeWordEnabled, !self.wakeWordFailureReported else { return }
                self.wakeWordFailureReported = true
                self.hooks.setStatus("Wake word is unavailable: \(reason). Use the hotkey instead.")
            }
        },
        onStarted: { [weak self] in
            self?.wakeWordFailureReported = false
            self?.hooks.wakeListeningChanged(true)
        }
    )

    private var wakeWordFailureReported = false

    var wakeWordGate: WakeWordGate {
        WakeWordGate(enabled: PerryPreferences.wakeWordEnabled)
    }

    init(
        overlayState: PerryCursorState,
        workers: ScreenWorkerService,
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
        neuralSpeech.onIdle = { [weak self] in self?.neuralSpeechFinished() }
        neuralSpeech.onError = { [weak self] message in self?.hooks.setStatus(message) }
        neuralSpeech.onFailure = { [weak self] text in self?.speakWithSystemVoice(text) }
    }

    func startInputListeners() {
        pushToTalk.start()
        audioRouteMonitor.start()
    }

    func beginDictation(steering: Bool = false, insertsWithoutPrefix: Bool = false) {
        dictationAttemptID = nil
        dictationInsertsWithoutPrefix = insertsWithoutPrefix
        dictation.cancel()
        overlayState.voiceState = .idle
        overlayState.buddyState = .idle
        voiceInvocation.begin()
        dictationScopedTaskID = steering ? hooks.executingTaskID() : nil
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        dictationTargetApplication = frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            ? nil
            : frontmostApplication
        if let realtimeVoiceSession {
            switch realtimeVoiceSession.state {
            case .connecting, .listening, .responding:
                wakeWordListener.stop()
                stopSpeech(at: .immediate)
                realtimeTranscriptBuffer = ""
                realtimeCommandDispatched = false
                realtimeVoiceSession.beginInput()
                switch realtimeVoiceSession.state {
                case .listening:
                    overlayState.voiceState = .listening
                    overlayState.buddyState = .listening
                    hooks.setStatus(dictationScopedTaskID == nil
                        ? "Listening through realtime voice. Release the shortcut when you’re done."
                        : "Listening. Release to steer the task.")
                case .connecting:
                    hooks.setStatus("Connecting to realtime voice…")
                case .idle, .responding, .failed:
                    break
                }
                return
            case .idle, .failed:
                realtimeVoiceSession.stop()
                self.realtimeVoiceSession = nil
            }
        }
        realtimeTranscriptBuffer = ""
        realtimeCommandDispatched = false
        if let configuration = RealtimeProvider.current?.configuration() {
            let apiKey: String?
            do {
                apiKey = try readRealtimeVoiceAPIKey()
            } catch {
                hooks.setStatus("I couldn’t read the live voice sign-in from the Keychain, so I’ll use dictation on this Mac.")
                beginLocalDictation()
                return
            }
            if let apiKey, !apiKey.isEmpty {
                wakeWordListener.stop()
                stopSpeech(at: .word)
                lastDictationLanguageIdentifier = nil
                hooks.setStatus("Connecting to realtime voice…")
                let session = makeRealtimeVoiceSession(configuration, apiKey) { [weak self] event in
                    self?.handleRealtimeVoiceEvent(event)
                }
                realtimeVoiceSession = session
                session.start()
                return
            }
        }
        beginLocalDictation()
    }

    private func beginLocalDictation() {
        overlayState.voiceState = .idle
        overlayState.buddyState = .idle
        hooks.setStatus("Getting the microphone ready…")
        wakeWordListener.stop()
        stopSpeech(at: .word)
        lastDictationLanguageIdentifier = nil
        do {
            dictation.configure(try currentDictationPreferences())
        } catch {
            dictation.configure(.default)
            hooks.setStatus("I couldn’t read your word replacements.")
        }
        let attemptID = UUID()
        dictationAttemptID = attemptID
        Task { @MainActor in
            let granted = await self.requestDictationPermission()
            guard dictationAttemptID == attemptID else { return }
            guard granted else {
                dictationAttemptID = nil
                voiceInvocation.cancel()
                overlayState.voiceState = .idle
                overlayState.buddyState = .idle
                hooks.setStatus("The microphone is off. Type your message instead.")
                speak("Turn on microphone access and I’ll listen.")
                return
            }
            do {
                try startDictationCapture()
                dictationAttemptID = nil
                overlayState.voiceState = .listening
                overlayState.buddyState = .listening
                hooks.setStatus(dictationScopedTaskID == nil
                    ? "Listening on \(dictation.activeInputDeviceName()). \(pushToTalk.gesture.releaseHint)."
                    : "Listening. Release to steer the task.")
            } catch {
                dictationAttemptID = nil
                overlayState.voiceState = .idle
                overlayState.buddyState = .idle
                handleDictationFailure(error)
                speak("I couldn’t start listening. Check your microphone.")
            }
        }
    }

    func finishDictation() {
        voiceInvocation.finishInput()
        dictationAttemptID = nil
        dictationSpeechEndedAt = DispatchTime.now().uptimeNanoseconds
        if let realtimeVoiceSession {
            realtimeVoiceSession.finishInputTranscribing()
            overlayState.voiceState = .processing
            overlayState.buddyState = .thinking
            hooks.setStatus("Working on it…")
            return
        }
        dictation.finish()
        overlayState.voiceState = .idle
        overlayState.buddyState = .idle
    }

    func cancelInput() {
        voiceInvocation.cancel()
        dictationAttemptID = nil
        dictationScopedTaskID = nil
        dictationInsertsWithoutPrefix = false
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
                hooks.setStatus("I didn’t hear anything. Hold the shortcut to try again, or type your message.")
            } else if voiceInvocation.inputOpen {
                hooks.setStatus("Realtime voice failed; continuing with on-device dictation.")
                beginLocalDictation()
            } else {
                voiceInvocation.cancel()
                handleDictationFailure()
                hooks.setStatus("Live voice stopped after you finished talking. Hold the shortcut to try again, or type your message.")
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
            hooks.setStatus("Replying…")
        case .responseFinished:
            overlayState.voiceState = .idle
            overlayState.buddyState = .idle
            overlayState.expireTaskBubble(after: 1.5)
        case .responseInterrupted, .speechStarted, .sessionReady:
            if voiceInvocation.inputOpen, realtimeVoiceSession?.state == .listening {
                overlayState.voiceState = .listening
                overlayState.buddyState = .listening
                hooks.setStatus(dictationScopedTaskID == nil
                    ? "Listening through realtime voice. Release the shortcut when you’re done."
                    : "Listening. Release to steer the task.")
            }
        case .speechStopped, .audio, .ignored:
            break
        }
    }

    private func recordPerformance(_ write: @escaping (PerformanceSampleLog) async throws -> Void) {
        guard let performanceSampleLog else { return }
        Task { @MainActor [weak self] in
            do {
                try await write(performanceSampleLog)
            } catch {
                self?.hooks.setStatus("Performance recording failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleDictationFailure(_ error: Error? = nil) {
        voiceInvocation.cancel()
        overlayState.voiceState = .idle
        overlayState.buddyState = .blocked
        hooks.setStatus(error?.localizedDescription ?? "I couldn’t hear you. Type your message instead.")
    }

    static func bluetoothPrerollDelay(isBluetooth: Bool) -> TimeInterval {
        isBluetooth ? 0.6 : 0
    }

    private func handleAudioRouteChange(_ deviceName: String) {
        realtimeVoiceSession?.refreshAudioRoute()
        guard isSpeaking else { return }
        let preroll = Self.bluetoothPrerollDelay(
            isBluetooth: AudioRouteMonitor.defaultOutputIsBluetooth()
        )
        if preroll > 0 {
            PerfMark.markDynamic("audio.preroll.bt")
            DispatchQueue.main.asyncAfter(deadline: .now() + preroll) { [weak self] in
                self?.announceRouteSwitch(deviceName)
            }
        } else {
            announceRouteSwitch(deviceName)
        }
    }

    private func announceRouteSwitch(_ deviceName: String) {
        guard isSpeaking else { return }
        let reply = currentSpeechText
        let routeMessage = "I switched the reply to \(deviceName)."
        hooks.setStatus("Audio moved to \(deviceName).")
        speak(routeMessage)
        guard let reply else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.isSpeaking, self.currentSpeechText == routeMessage else { return }
            self.speak(reply)
        }
    }

    private func handleMutedOutput() {
        guard isSpeaking, let currentSpeechText else { return }
        copyReplyToClipboard(
            currentSpeechText,
            status: "Audio output was muted; the reply is on your clipboard."
        )
    }

    func updatePushToTalkGesture(_ gesture: Gesture) {
        pushToTalk.update(gesture: gesture)
    }

    func updateWakeWordEnabled(_ enabled: Bool) {
        PerryPreferences.wakeWordEnabled = enabled
        wakeWordFailureReported = false
        if enabled {
            Task { @MainActor in
                guard await self.requestDictationPermission() else {
                    PerryPreferences.wakeWordEnabled = false
                    self.hooks.wakeListeningChanged(false)
                    self.hooks.setStatus("Wake word needs microphone and speech permission; the hotkey still works.")
                    return
                }
                self.refreshWakeWordListener()
            }
        } else {
            stopWakeWordListener()
        }
    }

    func refreshWakeWordListener() {
        guard PerryPreferences.wakeWordEnabled, hooks.sessionIsIdle() else {
            stopWakeWordListener()
            return
        }
        if let realtimeVoiceSession, realtimeVoiceSession.state != .idle {
            stopWakeWordListener()
            return
        }
        guard PerryPermissionProbe.checkMicrophone() == .granted,
              SFSpeechRecognizer.authorizationStatus() == .authorized else {
            PerryPreferences.wakeWordEnabled = false
            hooks.wakeListeningChanged(false)
            hooks.setStatus("Wake word is off because microphone or speech permission is unavailable.")
            return
        }
        wakeWordListener.start()
    }

    private func stopWakeWordListener() {
        wakeWordListener.stop()
        hooks.wakeListeningChanged(false)
    }

    private func handleWakeHeard() {
        SoundPlayer.play(.wake)
        overlayState.voiceState = .listening
    }

    private func handleWakeWord(_ command: String) {
        hooks.wakeListeningChanged(false)
        overlayState.voiceState = .idle
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hooks.sessionIsIdle(), !trimmed.isEmpty else {
            refreshWakeWordListener()
            return
        }
        hooks.wake()
        hooks.dispatch(trimmed, nil)
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
