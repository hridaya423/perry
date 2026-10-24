import AVFoundation
import AudioToolbox
import CoreAudio
import Speech
import PerryCore

struct DictationInputDevice: Equatable, Identifiable, Sendable {
    let id: UInt32
    let name: String
    let isBuiltIn: Bool
}

enum DictationRecognitionEvent {
    case transcript(String, isFinal: Bool, segments: [SFTranscriptionSegment])
    case failure(Error)

    init?(result: SFSpeechRecognitionResult?, error: Error?) {
        if let error {
            self = .failure(error)
        } else if let result {
            self = .transcript(
                result.bestTranscription.formattedString,
                isFinal: result.isFinal,
                segments: result.bestTranscription.segments
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
    private let onFailure: (Error) -> Void
    private let onFallback: () -> Void
    private let onLanguageDetected: (String?) -> Void
    private let onSegments: ([SFTranscriptionSegment]) -> Void
    private let selectFallbackInput: (AVAudioEngine) -> Bool
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
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
    private(set) var voiceProcessingEnabled = false
    private(set) var isRunning = false

    init(
        onTranscript: @escaping (String) -> Void,
        onPartial: @escaping (String) -> Void = { _ in },
        onFailure: @escaping (Error) -> Void = { _ in },
        onFallback: @escaping () -> Void = {},
        onLanguageDetected: @escaping (String?) -> Void = { _ in },
        /// Word-timestamped segments per recognition event — the Talk loop's
        /// deixis alignment input. Not used by plain dictation.
        onSegments: @escaping ([SFTranscriptionSegment]) -> Void = { _ in },
        selectFallbackInput: @escaping (AVAudioEngine) -> Bool = {
            MicrophoneDeviceSelector.select(on: $0.inputNode)
        }
    ) {
        self.onTranscript = onTranscript
        self.onPartial = onPartial
        self.onFailure = onFailure
        self.onFallback = onFallback
        self.onLanguageDetected = onLanguageDetected
        self.onSegments = onSegments
        self.selectFallbackInput = selectFallbackInput
        recognizer = Self.makeRecognizer(for: .automatic)
    }

    func configure(_ preferences: DictationPreferences) {
        guard !isRunning else { return }
        languageMode = preferences.language
        customWords = preferences.customWords
        inputDeviceID = preferences.inputDeviceID.map { AudioDeviceID($0) }
        recognizer = Self.makeRecognizer(for: preferences.language)
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
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
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
        guard isRunning || inputTapInstalled || request != nil || task != nil || voiceProcessingEnabled else { return }
        stopAudioCapture()
        request?.endAudio()
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
        request = try Self.makeOnDeviceRequest(supported: true, customWords: [])
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
        guard let recognizer, recognizer.isAvailable else {
            throw DictationError.unavailable
        }
        let recognitionRequest = try Self.makeOnDeviceRequest(
            supported: recognizer.supportsOnDeviceRecognition,
            customWords: customWords
        )
        let input = audioEngine.inputNode
        if !fallbackAttempted, let inputDeviceID, !MicrophoneDeviceSelector.select(on: input, deviceID: inputDeviceID) {
            throw DictationError.deviceUnavailable
        }
        do {
            try input.setVoiceProcessingEnabled(true)
            voiceProcessingEnabled = input.isVoiceProcessingEnabled
        } catch {
            voiceProcessingEnabled = false
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw DictationError.unavailable
        }

        request = recognitionRequest

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.retainAudio(buffer)
            recognitionRequest.append(buffer)
        }
        inputTapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true

        let generation = recognitionGate.generation
        task = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let event = DictationRecognitionEvent(result: result, error: error) else { return }
            self?.handleRecognition(event, generation: generation)
        }
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
        case .transcript(let transcript, isFinal: true, let segments):
            onSegments(segments)
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
        case .transcript(let transcript, isFinal: false, let segments):
            onSegments(segments)
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
        task?.cancel()
        request?.endAudio()
        task = nil
        request = nil
        recognizer = nextRecognizer
        request = nextRequest
        let generation = recognitionGate.advance()
        recognitionGate.finishInput()
        task = nextRecognizer.recognitionTask(with: nextRequest) { [weak self] result, error in
            guard let event = DictationRecognitionEvent(result: result, error: error) else { return }
            self?.handleReroutedRecognition(
                event,
                generation: generation,
                detectedIdentifier: identifier
            )
        }
        for buffer in replay {
            nextRequest.append(buffer)
        }
        nextRequest.endAudio()
        scheduleFinalizationTimeout()
    }

    func handleReroutedRecognition(
        _ event: DictationRecognitionEvent,
        generation: Int,
        detectedIdentifier: String
    ) {
        guard recognitionGate.accepts(generation) else { return }
        switch event {
        case .transcript(let transcript, isFinal: true, let segments):
            onSegments(segments)
            rerouting = false
            detectedLanguageIdentifier = detectedIdentifier
            onLanguageDetected(detectedIdentifier)
            guard !transcript.isEmpty else {
                abortRecognition()
                onFailure(DictationError.unavailable)
                return
            }
            deliverTranscript(transcript, generation: generation)
        case .transcript(let transcript, isFinal: false, let segments):
            onSegments(segments)
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
        voiceProcessingEnabled = false
    }

    private func abortRecognition() {
        recognitionGate.invalidate()
        finishCancellationWorkItem?.cancel()
        finishCancellationWorkItem = nil
        stopAudioCapture()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
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

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
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

    static func makeOnDeviceRequest(
        supported: Bool,
        customWords: [String]
    ) throws -> SFSpeechAudioBufferRecognitionRequest {
        guard supported else { throw DictationError.onDeviceUnavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
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
                "Perry needs microphone and speech recognition access to hear you."
            case .unavailable:
                "Speech recognition is unavailable. Type your request instead."
            case .deviceUnavailable:
                "The selected microphone is unavailable. Choose another microphone in Settings."
            case .onDeviceUnavailable:
                "On-device speech recognition is unavailable for this language. Choose another dictation language or type your request."
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
