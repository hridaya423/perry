import AVFoundation
import CoreAudio
import Speech
import PerryBrain
import PerryCore

final class DictationController {
    private let onTranscript: (String) -> Void
    private let onPartial: (String) -> Void
    private let onLevel: (TimeInterval, Double) -> Void
    private let onFailure: (Error) -> Void
    private let onFallback: () -> Void
    private let onLanguageDetected: (String?) -> Void
    private let onWords: ([SpokenWord]) -> Void
    private let mic = MicCapture()
    private var recognizer: SFSpeechRecognizer?
    private var analyzerTarget: AnalyzerTarget?
    private var fallbackAttempted = false
    private var customWords: [String] = []
    private var inputDeviceID: AudioDeviceID?
    private let audioBufferLock = NSLock()
    private var bufferedAudio: [AVAudioPCMBuffer] = []
    private var bufferedFrameCount = 0
    private let maximumBufferedFrames = 30 * 48_000
    private var finishCancellationWorkItem: DispatchWorkItem?
    var session: RecognitionSession?
    var languageMode: DictationLanguageMode = .automatic
    var recognitionGate = DictationRecognitionGate()
    var isRunning: Bool { mic.isRunning }

    init(
        onTranscript: @escaping (String) -> Void,
        onPartial: @escaping (String) -> Void = { _ in },
        onLevel: @escaping (TimeInterval, Double) -> Void = { _, _ in },
        onFailure: @escaping (Error) -> Void = { _ in },
        onFallback: @escaping () -> Void = {},
        onLanguageDetected: @escaping (String?) -> Void = { _ in },
        onWords: @escaping ([SpokenWord]) -> Void = { _ in }
    ) {
        self.onTranscript = onTranscript
        self.onPartial = onPartial
        self.onLevel = onLevel
        self.onFailure = onFailure
        self.onFallback = onFallback
        self.onLanguageDetected = onLanguageDetected
        self.onWords = onWords
        recognizer = Self.makeRecognizer(for: .automatic)
        prepareAnalyzer()
    }

    func configure(_ preferences: DictationPreferences) {
        guard !isRunning else { return }
        languageMode = preferences.language
        customWords = preferences.customWords
        inputDeviceID = preferences.inputDeviceID.map { AudioDeviceID($0) }
        recognizer = Self.makeRecognizer(for: preferences.language)
        prepareAnalyzer()
    }

    private func prepareAnalyzer() {
        guard #available(macOS 26, *), let locale = recognizer?.locale else {
            analyzerTarget = nil
            return
        }
        analyzerTarget = AnalyzerTarget.cached(for: locale)
        guard analyzerTarget == nil, SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
        Task { @MainActor [weak self] in
            guard let target = await AnalyzerRecognitionSession.prepare(locale: locale) else { return }
            AnalyzerTarget.remember(target, for: locale)
            guard let self, self.recognizer?.locale == locale else { return }
            self.analyzerTarget = target
        }
    }

    static func availableInputDevices() -> [DictationInputDevice] {
        MicrophoneDeviceSelector.inputDevices().map { deviceID in
            let name = MicrophoneDeviceSelector.name(for: deviceID)
            return DictationInputDevice(
                id: deviceID,
                name: name.isEmpty ? "Unknown microphone" : name,
                isBuiltIn: MicrophoneDeviceSelector.isBuiltIn(name: name)
            )
        }
    }

    func activeInputDeviceName() -> String {
        let resolved = inputDeviceID ?? MicrophoneDeviceSelector.preferredDeviceID()
        guard let resolved else { return "microphone" }
        let name = MicrophoneDeviceSelector.name(for: resolved)
        return name.isEmpty ? "microphone" : name
    }

    static func supportedLanguageIdentifiers() -> [String] {
        SFSpeechRecognizer.supportedLocales()
            .map(\.identifier)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func languageName(for identifier: String) -> String {
        Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
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

    private(set) static var permissionGranted = false

    static func warmPermissionCache() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
        permissionGranted = true
    }

    static func ensurePermission() async -> Bool {
        if permissionGranted { return true }
        let granted = await requestPermission()
        if granted { permissionGranted = true }
        return granted
    }

    func start() throws {
        guard !isRunning else { return }
        abortRecognition()
        _ = recognitionGate.advance()
        fallbackAttempted = false
        guard analyzerTarget != nil || recognizer?.supportsOnDeviceRecognition == true else {
            throw DictationError.onDeviceUnavailable
        }
        do {
            try startCapture(deviceID: inputDeviceID)
        } catch {
            abortRecognition()
            guard let fallback = MicrophoneDeviceSelector.preferredDeviceID() else { throw error }
            fallbackAttempted = true
            do {
                try startCapture(deviceID: fallback)
                onFallback()
            } catch {
                abortRecognition()
                throw error
            }
        }
    }

    func finish() {
        recognitionGate.finishInput()
        guard isRunning || session != nil else { return }
        mic.stop()
        session?.endAudio()
        scheduleFinalizationTimeout()
    }

    func cancel() {
        abortRecognition()
    }

#if DEBUG
    func simulateInputFailure() {
        if isRunning {
            recoverFromInputFailure()
        } else {
            onFallback()
            onFailure(DictationError.unavailable)
        }
    }
#endif

    private func scheduleFinalizationTimeout() {
        let generation = recognitionGate.generation
        finishCancellationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.recognitionGate.generation == generation else { return }
            self.abortRecognition()
            self.onFailure(DictationError.unavailable)
        }
        finishCancellationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: workItem)
    }

    private func startCapture(deviceID: AudioDeviceID?) throws {
        let generation = recognitionGate.generation
        let recognitionSession = try makeSession { [weak self] event in
            self?.handleRecognition(event, generation: generation)
        }
        do {
            try mic.start(deviceID: deviceID) { [weak self] buffer, when in
                self?.retainAudio(buffer)
                recognitionSession.append(buffer)
                self?.onLevel(AVAudioTime.seconds(forHostTime: when.hostTime), MicCapture.rms(buffer))
            }
        } catch {
            recognitionSession.cancel()
            throw error
        }
        session = recognitionSession
    }

    private func makeSession(onEvent: @escaping (DictationRecognitionEvent) -> Void) throws -> RecognitionSession {
        if #available(macOS 26, *), let analyzerTarget {
            return AnalyzerRecognitionSession(target: analyzerTarget, words: customWords, onEvent: onEvent)
        }
        guard let recognizer, recognizer.isAvailable else {
            throw DictationError.unavailable
        }
        return SystemRecognitionSession(
            recognizer: recognizer,
            request: try Self.makeOnDeviceRequest(supported: recognizer.supportsOnDeviceRecognition, customWords: customWords),
            onEvent: onEvent
        )
    }

    private func recoverFromInputFailure() {
        guard recognitionGate.inputOpen, !fallbackAttempted else {
            abortRecognition()
            onFailure(DictationError.unavailable)
            return
        }
        abortRecognition()
        _ = recognitionGate.advance()
        guard let fallback = MicrophoneDeviceSelector.preferredDeviceID() else {
            abortRecognition()
            onFailure(DictationError.deviceUnavailable)
            return
        }
        fallbackAttempted = true
        do {
            try startCapture(deviceID: fallback)
            onFallback()
        } catch {
            onFailure(error)
            abortRecognition()
        }
    }

    func handleRecognition(_ event: DictationRecognitionEvent, generation: Int, reroutedTo: String? = nil) {
        guard recognitionGate.accepts(generation) else { return }
        switch event {
        case .transcript(let transcript, isFinal: true, let words):
            onWords(words)
            guard !transcript.isEmpty else {
                abortRecognition()
                onFailure(DictationError.unavailable)
                return
            }
            let detected = reroutedTo ?? (languageMode == .automatic
                ? SpeechLanguageDetector.localeIdentifier(
                    for: transcript,
                    supportedIdentifiers: Self.supportedLanguageIdentifiers()
                )
                : nil)
            onLanguageDetected(detected)
            if reroutedTo == nil, let detected, shouldReroute(to: detected) {
                do {
                    try rerouteRecognition(to: detected)
                } catch {
                    abortRecognition()
                    onFailure(error)
                }
                return
            }
            deliverTranscript(transcript, generation: generation)
        case .transcript(let transcript, isFinal: false, let words):
            onWords(words)
            if !transcript.isEmpty {
                onPartial(transcript)
            }
        case .failure(let error):
            if reroutedTo == nil {
                recoverFromInputFailure()
            } else {
                abortRecognition()
                onFailure(error)
            }
        }
    }

    private func shouldReroute(to detectedIdentifier: String) -> Bool {
        guard let activeLocale = recognizer?.locale.language.languageCode,
              let detectedLanguage = Locale(identifier: detectedIdentifier).language.languageCode else { return false }
        return activeLocale.identifier.caseInsensitiveCompare(detectedLanguage.identifier) != .orderedSame
    }

    private func rerouteRecognition(to identifier: String) throws {
        guard let locale = SFSpeechRecognizer.supportedLocales().first(where: {
            $0.identifier.caseInsensitiveCompare(identifier) == .orderedSame
                || $0.language.languageCode?.identifier.caseInsensitiveCompare(Locale(identifier: identifier).language.languageCode?.identifier ?? "") == .orderedSame
        }),
        let nextRecognizer = SFSpeechRecognizer(locale: locale),
        nextRecognizer.isAvailable else { throw DictationError.unavailable }
        let nextRequest = try Self.makeOnDeviceRequest(
            supported: nextRecognizer.supportsOnDeviceRecognition,
            customWords: customWords
        )
        let replay = audioBufferSnapshot()
        guard !replay.isEmpty else { throw DictationError.unavailable }

        session?.cancel()
        recognizer = nextRecognizer
        prepareAnalyzer()
        let generation = recognitionGate.advance()
        recognitionGate.finishInput()
        let nextSession = SystemRecognitionSession(recognizer: nextRecognizer, request: nextRequest) { [weak self] event in
            self?.handleRecognition(event, generation: generation, reroutedTo: identifier)
        }
        session = nextSession
        for buffer in replay {
            nextSession.append(buffer)
        }
        nextSession.endAudio()
        scheduleFinalizationTimeout()
    }

    private func deliverTranscript(_ transcript: String, generation: Int) {
        guard recognitionGate.claim(generation) else { return }
        finishCancellationWorkItem?.cancel()
        finishCancellationWorkItem = nil
        onTranscript(transcript)
        abortRecognition()
    }

    private func abortRecognition() {
        recognitionGate.invalidate()
        finishCancellationWorkItem?.cancel()
        finishCancellationWorkItem = nil
        mic.stop()
        session?.cancel()
        session = nil
        clearAudioBuffer()
    }

    private func retainAudio(_ buffer: AVAudioPCMBuffer) {
        guard let copy = MicCapture.copy(buffer) else { return }
        audioBufferLock.lock()
        defer { audioBufferLock.unlock() }
        guard bufferedFrameCount + Int(copy.frameLength) <= maximumBufferedFrames else { return }
        bufferedAudio.append(copy)
        bufferedFrameCount += Int(copy.frameLength)
    }

    private func audioBufferSnapshot() -> [AVAudioPCMBuffer] {
        audioBufferLock.lock()
        defer { audioBufferLock.unlock() }
        return bufferedAudio.compactMap(MicCapture.copy)
    }

    private func clearAudioBuffer() {
        audioBufferLock.lock()
        bufferedAudio.removeAll(keepingCapacity: true)
        bufferedFrameCount = 0
        audioBufferLock.unlock()
    }

    static func makeOnDeviceRequest(
        supported: Bool,
        customWords: [String]
    ) throws -> SFSpeechAudioBufferRecognitionRequest {
        guard supported else { throw DictationError.onDeviceUnavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = customWords
        return request
    }

    enum DictationError: LocalizedError {
        case unavailable
        case permissionDenied
        case deviceUnavailable
        case onDeviceUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "I need microphone and speech recognition access to hear you."
            case .unavailable:
                "Speech recognition isn’t available. Type your message instead."
            case .deviceUnavailable:
                "That microphone isn’t available. Choose another one in Settings."
            case .onDeviceUnavailable:
                "Speech recognition on this Mac doesn’t support this language. Choose another language or type your message."
            }
        }
    }

    private static func makeRecognizer(for language: DictationLanguageMode) -> SFSpeechRecognizer? {
        let supported = SFSpeechRecognizer.supportedLocales()
        switch language {
        case .fixed(let identifier):
            guard let locale = supported.first(where: { $0.identifier.caseInsensitiveCompare(identifier) == .orderedSame }) else {
                return nil
            }
            return SFSpeechRecognizer(locale: locale)
        case .automatic:
            let preferred = Locale.preferredLanguages + [Locale.current.identifier, "en-US"]
            for identifier in preferred {
                if let locale = supported.first(where: { $0.identifier.caseInsensitiveCompare(identifier) == .orderedSame }) {
                    return SFSpeechRecognizer(locale: locale)
                }
                if let languageCode = Locale(identifier: identifier).language.languageCode,
                   let locale = supported.first(where: { $0.language.languageCode == languageCode }) {
                    return SFSpeechRecognizer(locale: locale)
                }
            }
            guard let locale = supported.first else { return nil }
            return SFSpeechRecognizer(locale: locale)
        }
    }
}
