import Accelerate
import AVFoundation
import AudioToolbox
import CoreAudio
import Speech
import PerryBrain
import PerryCore

struct DictationInputDevice: Equatable, Identifiable, Sendable {
    let id: UInt32
    let name: String
    let isBuiltIn: Bool
}

enum DictationRecognitionEvent {
    case transcript(String, isFinal: Bool, words: [SpokenWord])
    case failure(Error)

    init?(result: SFSpeechRecognitionResult?, error: Error?) {
        if let error {
            self = .failure(error)
        } else if let result {
            self = .transcript(
                result.bestTranscription.formattedString,
                isFinal: result.isFinal,
                words: result.bestTranscription.segments.map {
                    SpokenWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                }
            )
        } else {
            return nil
        }
    }
}

struct DictationRecognitionGate: Equatable, Sendable {
    private(set) var generation = 0
    private var deliveredGeneration: Int?
    private(set) var inputOpen = false

    mutating func advance() -> Int {
        generation += 1
        deliveredGeneration = nil
        inputOpen = true
        return generation
    }

    mutating func invalidate() {
        generation += 1
        deliveredGeneration = nil
        inputOpen = false
    }

    mutating func finishInput() {
        inputOpen = false
    }

    func accepts(_ callbackGeneration: Int) -> Bool {
        generation == callbackGeneration && deliveredGeneration != callbackGeneration
    }

    mutating func claim(_ callbackGeneration: Int) -> Bool {
        guard accepts(callbackGeneration) else { return false }
        deliveredGeneration = callbackGeneration
        return true
    }
}

struct VoiceInvocationGate {
    private enum State {
        case idle
        case recording(UUID)
        case finalizing(UUID)
    }

    private var state = State.idle

    var id: UUID? {
        switch state {
        case .idle: nil
        case .recording(let id), .finalizing(let id): id
        }
    }

    var inputOpen: Bool {
        if case .recording = state { return true }
        return false
    }

    mutating func begin() {
        state = .recording(UUID())
    }

    mutating func finishInput() {
        if case .recording(let id) = state { state = .finalizing(id) }
    }

    mutating func cancel() {
        state = .idle
    }

    mutating func claim(_ id: UUID) -> Bool {
        guard self.id == id else { return false }
        state = .idle
        return true
    }
}

final class DictationController {
    private let onTranscript: (String) -> Void
    private let onPartial: (String) -> Void
    private let onLevel: (TimeInterval, Double) -> Void
    private let onFailure: (Error) -> Void
    private let onFallback: () -> Void
    private let onLanguageDetected: (String?) -> Void
    private let onWords: ([SpokenWord]) -> Void
    private let selectFallbackInput: (AVAudioEngine) -> Bool
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var session: RecognitionSession?
    private var analyzerTarget: AnalyzerTarget?
    private var inputTapInstalled = false
    private var fallbackAttempted = false
    private var languageMode: DictationLanguageMode = .automatic
    private var customWords: [String] = []
    private var inputDeviceID: AudioDeviceID?
    private let audioBufferLock = NSLock()
    private var bufferedAudio: [AVAudioPCMBuffer] = []
    private var bufferedFrameCount = 0
    private let maximumBufferedFrames = 30 * 48_000
    private var recognitionGate = DictationRecognitionGate()
    private var finishCancellationWorkItem: DispatchWorkItem?
    private var rerouting = false
    private(set) var detectedLanguageIdentifier: String?
    private(set) var isRunning = false

    init(
        onTranscript: @escaping (String) -> Void,
        onPartial: @escaping (String) -> Void = { _ in },
        onLevel: @escaping (TimeInterval, Double) -> Void = { _, _ in },
        onFailure: @escaping (Error) -> Void = { _ in },
        onFallback: @escaping () -> Void = {},
        onLanguageDetected: @escaping (String?) -> Void = { _ in },
        onWords: @escaping ([SpokenWord]) -> Void = { _ in },
        selectFallbackInput: @escaping (AVAudioEngine) -> Bool = {
            MicrophoneDeviceSelector.select(on: $0.inputNode)
        }
    ) {
        self.onTranscript = onTranscript
        self.onPartial = onPartial
        self.onLevel = onLevel
        self.onFailure = onFailure
        self.onFallback = onFallback
        self.onLanguageDetected = onLanguageDetected
        self.onWords = onWords
        self.selectFallbackInput = selectFallbackInput
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

    /// Name of the input route dictation captures on — mirrors the engine's
    /// own selection (configured device, else the built-in/first fallback) so
    /// the active route is visible without technical noise.
    func activeInputDeviceName() -> String {
        let resolved = inputDeviceID ?? MicrophoneDeviceSelector.preferredDeviceID()
        guard let resolved else { return "microphone" }
        let name = MicrophoneDeviceSelector.name(for: resolved)
        return name.isEmpty ? "microphone" : name
    }

    static func inputDeviceIsAvailable(_ deviceID: UInt32?) -> Bool {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceID {
            guard MicrophoneDeviceSelector.select(on: input, deviceID: AudioDeviceID(deviceID)) else { return false }
        }
        let format = input.outputFormat(forBus: 0)
        return format.sampleRate > 0 && format.channelCount > 0
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

    /// Mic + speech grant, cached so the hold path never suspends key-down
    /// on a TCC round-trip once the answer is known (plan Phase-1 H7).
    /// Set by `warmPermissionCache()` at launch and by `ensurePermission()`
    /// on first grant. Denials are not cached — the user can reverse them
    /// in Settings, so the next request re-checks.
    private(set) static var permissionGranted = false

    /// Records an already-determined grant without prompting. Called once
    /// at launch; an undetermined status stays uncached and the first real
    /// request populates the cache instead.
    static func warmPermissionCache() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
        permissionGranted = true
    }

    /// Returns immediately once granted; otherwise requests (prompting if
    /// undetermined) and caches the grant.
    static func ensurePermission() async -> Bool {
        if permissionGranted { return true }
        let granted = await requestPermission()
        if granted { permissionGranted = true }
        return granted
    }

    func start() throws {
        guard !isRunning else { return }
        abortRecognition()
        clearAudioBuffer()
        rerouting = false
        _ = recognitionGate.advance()
        fallbackAttempted = false
        guard analyzerTarget != nil || recognizer?.supportsOnDeviceRecognition == true else {
            throw DictationError.onDeviceUnavailable
        }
        do {
            try startEngine()
        } catch {
            abortRecognition()
            guard selectFallbackInput(audioEngine) else { throw error }
            fallbackAttempted = true
            do {
                try startEngine()
                onFallback()
            } catch {
                abortRecognition()
                throw error
            }
        }
    }

    func finish() {
        recognitionGate.finishInput()
        guard isRunning || inputTapInstalled || session != nil else { return }
        stopAudioCapture()
        session?.endAudio()
        scheduleFinalizationTimeout()
    }

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

    func cancel() {
        abortRecognition()
    }

#if DEBUG
    func beginRecognitionFixture() throws -> Int {
        abortRecognition()
        languageMode = .fixed(identifier: "en-US")
        session = SystemRecognitionSession(recognizer: nil, request: try Self.makeOnDeviceRequest(supported: true, customWords: []), onEvent: { _ in })
        return recognitionGate.advance()
    }

    func simulateInputFailure() {
        if isRunning {
            recoverFromInputFailure()
        } else {
            onFallback()
            onFailure(DictationError.unavailable)
        }
    }
#endif

    private func startEngine() throws {
        let generation = recognitionGate.generation
        let recognitionSession = try makeSession { [weak self] event in
            self?.handleRecognition(event, generation: generation)
        }
        let input = audioEngine.inputNode
        if !fallbackAttempted, let inputDeviceID, !MicrophoneDeviceSelector.select(on: input, deviceID: inputDeviceID) {
            throw DictationError.deviceUnavailable
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw DictationError.unavailable
        }

        session = recognitionSession

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            self?.retainAudio(buffer)
            recognitionSession.append(buffer)
            self?.onLevel(AVAudioTime.seconds(forHostTime: when.hostTime), Self.rms(buffer))
        }
        inputTapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true
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
        clearAudioBuffer()
        _ = recognitionGate.advance()
        guard selectFallbackInput(audioEngine) else {
            abortRecognition()
            onFailure(DictationError.deviceUnavailable)
            return
        }
        fallbackAttempted = true
        do {
            try startEngine()
            onFallback()
        } catch {
            onFailure(error)
            abortRecognition()
        }
    }

    func handleRecognition(_ event: DictationRecognitionEvent, generation: Int) {
        guard recognitionGate.accepts(generation) else { return }
        switch event {
        case .transcript(let transcript, isFinal: true, let words):
            onWords(words)
            guard !transcript.isEmpty else {
                abortRecognition()
                onFailure(DictationError.unavailable)
                return
            }
            let detected = languageMode == .automatic
                ? SpeechLanguageDetector.localeIdentifier(
                    for: transcript,
                    supportedIdentifiers: Self.supportedLanguageIdentifiers()
                )
                : nil
            detectedLanguageIdentifier = detected
            onLanguageDetected(detected)
            if let detected,
               languageMode == .automatic,
               shouldReroute(to: detected),
               !rerouting {
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
        case .failure:
            if !rerouting { recoverFromInputFailure() }
        }
    }

    private func shouldReroute(to detectedIdentifier: String) -> Bool {
        guard let activeRecognizer = recognizer,
              let activeLocale = activeRecognizer.locale.language.languageCode,
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

        rerouting = true
        session?.cancel()
        recognizer = nextRecognizer
        prepareAnalyzer()
        let generation = recognitionGate.advance()
        recognitionGate.finishInput()
        let nextSession = SystemRecognitionSession(recognizer: nextRecognizer, request: nextRequest) { [weak self] event in
            self?.handleReroutedRecognition(event, generation: generation, detectedIdentifier: identifier)
        }
        session = nextSession
        for buffer in replay {
            nextSession.append(buffer)
        }
        nextSession.endAudio()
        scheduleFinalizationTimeout()
    }

    func handleReroutedRecognition(
        _ event: DictationRecognitionEvent,
        generation: Int,
        detectedIdentifier: String
    ) {
        guard recognitionGate.accepts(generation) else { return }
        switch event {
        case .transcript(let transcript, isFinal: true, let words):
            onWords(words)
            rerouting = false
            detectedLanguageIdentifier = detectedIdentifier
            onLanguageDetected(detectedIdentifier)
            guard !transcript.isEmpty else {
                abortRecognition()
                onFailure(DictationError.unavailable)
                return
            }
            deliverTranscript(transcript, generation: generation)
        case .transcript(let transcript, isFinal: false, let words):
            onWords(words)
            if !transcript.isEmpty { onPartial(transcript) }
        case .failure(let error):
            abortRecognition()
            onFailure(error)
        }
    }

    private func deliverTranscript(_ transcript: String, generation: Int) {
        guard recognitionGate.claim(generation) else { return }
        finishCancellationWorkItem?.cancel()
        finishCancellationWorkItem = nil
        onTranscript(transcript)
        abortRecognition()
    }

    private func stopAudioCapture() {
        audioEngine.stop()
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        isRunning = false
    }

    private func abortRecognition() {
        recognitionGate.invalidate()
        finishCancellationWorkItem?.cancel()
        finishCancellationWorkItem = nil
        stopAudioCapture()
        session?.cancel()
        session = nil
        rerouting = false
        clearAudioBuffer()
    }

    private func retainAudio(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copyBuffer(buffer) else { return }
        audioBufferLock.lock()
        defer { audioBufferLock.unlock() }
        guard bufferedFrameCount + Int(copy.frameLength) <= maximumBufferedFrames else { return }
        bufferedAudio.append(copy)
        bufferedFrameCount += Int(copy.frameLength)
    }

    private func audioBufferSnapshot() -> [AVAudioPCMBuffer] {
        audioBufferLock.lock()
        defer { audioBufferLock.unlock() }
        return bufferedAudio.compactMap(Self.copyBuffer)
    }

    private func clearAudioBuffer() {
        audioBufferLock.lock()
        bufferedAudio.removeAll(keepingCapacity: true)
        bufferedFrameCount = 0
        audioBufferLock.unlock()
    }

    static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            let byteCount = frameCount * MemoryLayout<Float>.size
            for channel in 0..<channelCount {
                memcpy(destination[channel], source[channel], byteCount)
            }
            return copy
        }
        if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            let byteCount = frameCount * MemoryLayout<Int16>.size
            for channel in 0..<channelCount {
                memcpy(destination[channel], source[channel], byteCount)
            }
            return copy
        }
        return nil
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(samples, 1, &value, vDSP_Length(buffer.frameLength))
        return Double(value)
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

private enum MicrophoneDeviceSelector {
    static func select(on input: AVAudioInputNode, deviceID: AudioDeviceID? = nil) -> Bool {
        guard let audioUnit = input.audioUnit,
              let selectedDeviceID = deviceID ?? preferredDeviceID() else { return false }
        var selectedDevice = selectedDeviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDevice,
            size
        ) == noErr
    }

    static func inputDevices() -> [AudioDeviceID] {
        let devices = allDevices()
        return devices.filter { inputChannelCount(for: $0) > 0 }
    }

    static func name(for deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              let value else { return "" }
        return value.takeUnretainedValue() as String
    }

    static func isBuiltIn(name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("built-in") || lowered.contains("internal") || lowered.contains("macbook")
    }

    static func preferredDeviceID() -> AudioDeviceID? {
        let devices = inputDevices()
        return devices.first { isBuiltIn(name: name(for: $0)) }
            ?? devices.first
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func inputChannelCount(for deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return 0 }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(pointer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + $1.mNumberChannels }
    }

}

@MainActor
final class MicrophoneLevelMeter: ObservableObject {
    @Published private(set) var level = 0.0
    @Published private(set) var isRunning = false
    @Published private(set) var problem: String?
    private var engine: AVAudioEngine?
    private var timeout: Task<Void, Never>?

    func start(deviceID: UInt32?) async {
        stop()
        problem = nil
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined where await AVCaptureDevice.requestAccess(for: .audio):
            break
        default:
            problem = "I can’t hear the microphone. Turn on Microphone in Privacy."
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceID, !MicrophoneDeviceSelector.select(on: input, deviceID: AudioDeviceID(deviceID)) {
            problem = "That microphone isn’t available, so I’ll use the built-in one."
            return
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            problem = "That microphone isn’t available, so I’ll use the built-in one."
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let value = Self.normalized(DictationController.rms(buffer))
            Task { @MainActor in self?.level = value }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            problem = "I couldn’t open that microphone."
            return
        }
        self.engine = engine
        isRunning = true
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        timeout?.cancel()
        timeout = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        level = 0
    }

    nonisolated static func normalized(_ rms: Double) -> Double {
        min(max((20 * log10(max(rms, 1e-7)) + 60) / 50, 0), 1)
    }
}
