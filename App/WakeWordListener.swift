import AVFoundation
import os
import Speech
import PerryCore
import PerryGuide

@MainActor
final class WakeWordListener {
    typealias RestartScheduler = (@escaping @MainActor @Sendable () -> Void) -> Void
    typealias StartEngineOverride = (UInt64, @escaping () -> Void) throws -> Void

    private let onWake: (String) -> Void
    private let onHeard: () -> Void
    private let now: () -> TimeInterval
    private let onFailure: (String) -> Void
    private let scheduleRestart: RestartScheduler
    private let startEngineOverride: StartEngineOverride?
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var wantsToListen = false
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private var pendingRestartGeneration: UInt64?
    private var capture: (detector: EndOfTurnDetector, command: String)?
    private let levels = OSAllocatedUnfairLock(initialState: Levels())

    struct Levels {
        var capturing = false
        var recent: [Double] = []

        mutating func record(_ rms: Double) {
            recent.append(rms)
            if recent.count > 75 { recent.removeFirst(recent.count - 75) }
        }

        var floor: Double? {
            guard !recent.isEmpty else { return nil }
            return recent.sorted()[recent.count / 5]
        }
    }

    init(
        onWake: @escaping (String) -> Void,
        onHeard: @escaping () -> Void = {},
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onFailure: @escaping (String) -> Void = { _ in },
        scheduleRestart: @escaping RestartScheduler = { work in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        },
        startEngineOverride: StartEngineOverride? = nil
    ) {
        self.onWake = onWake
        self.onHeard = onHeard
        self.now = now
        self.onFailure = onFailure
        self.scheduleRestart = scheduleRestart
        self.startEngineOverride = startEngineOverride
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    func start() {
        wantsToListen = true
        guard !isRunning else { return }
        pendingRestartGeneration = nil
        do {
            try startListening()
        } catch {
            stopEngine()
            onFailure(error.localizedDescription)
        }
    }

    func stop() {
        wantsToListen = false
        stopEngine()
    }

    private var isRunning: Bool {
        activeGeneration != nil || audioEngine.isRunning || tapInstalled || request != nil || task != nil
    }

    private func startListening() throws {
        generation &+= 1
        let generation = generation
        activeGeneration = generation
        if let startEngineOverride {
            try startEngineOverride(generation) { [weak self] in
                self?.restartAfterTerminal(for: generation)
            }
            return
        }
        try startEngine(for: generation)
    }

    private func startEngine(for generation: UInt64) throws {
        guard let recognizer, recognizer.isAvailable else {
            throw ListenerError.unavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw ListenerError.unavailable
        }
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw ListenerError.unavailable
        }

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.contextualStrings = ["hey", "Perry"]
        recognitionRequest.requiresOnDeviceRecognition = true
        request = recognitionRequest
        let levels = levels
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, when in
            recognitionRequest.append(buffer)
            let rms = DictationController.rms(buffer)
            let capturing = levels.withLock { levels in
                if !levels.capturing { levels.record(rms) }
                return levels.capturing
            }
            guard capturing else { return }
            let time = AVAudioTime.seconds(forHostTime: when.hostTime)
            Task { @MainActor [weak self] in self?.hear(rms: rms, at: time) }
        }
        tapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()
        task = recognizer.recognitionTask(with: recognitionRequest) { result, error in
            if let result {
                let transcript = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.inspect(transcript)
                    if isFinal { self.restartAfterTerminal(for: generation) }
                }
            } else if error != nil {
                Task { @MainActor [weak self] in
                    self?.restartAfterTerminal(for: generation)
                }
            }
        }
    }

    func inspect(_ transcript: String) {
        guard wantsToListen else { return }
        if var capture {
            capture.command = Self.remainder(of: transcript)
            _ = capture.detector.transcript(at: now(), text: capture.command, lastWordEnd: 0)
            self.capture = capture
            return
        }
        guard WakeWordGate(enabled: true).match(inTranscript: transcript) != nil else { return }
        let command = Self.remainder(of: transcript)
        let floor = levels.withLock { levels in
            levels.capturing = true
            return levels.floor
        }
        var detector = EndOfTurnDetector(startedAt: now(), noiseFloor: floor)
        if !command.isEmpty {
            _ = detector.transcript(at: now(), text: command, lastWordEnd: 0)
        }
        capture = (detector, command)
        onHeard()
    }

    func hear(rms: Double, at time: TimeInterval) {
        guard wantsToListen else { return }
        guard var capture else {
            levels.withLock { $0.record(rms) }
            return
        }
        let event = capture.detector.frame(at: time, rms: rms)
        self.capture = capture
        switch event {
        case .commit?, .abort?: finishCapture()
        default: break
        }
    }

    static func remainder(of transcript: String) -> String {
        let phraseWords = WakeWordGate.defaultPhrase.split(separator: " ").count
        return transcript.split(whereSeparator: \.isWhitespace).dropFirst(phraseWords).joined(separator: " ")
    }

    private func finishCapture() {
        guard let capture else { return }
        self.capture = nil
        stop()
        onWake(capture.command)
    }

    private func restartAfterTerminal(for generation: UInt64) {
        if capture != nil, activeGeneration == generation {
            finishCapture()
            return
        }
        guard wantsToListen else {
            stopEngine()
            return
        }
        guard activeGeneration == generation else { return }
        guard pendingRestartGeneration == nil else { return }
        pendingRestartGeneration = generation
        stopEngine()
        scheduleRestart { [weak self] in
            guard let self,
                  self.wantsToListen,
                  self.pendingRestartGeneration == generation else { return }
            self.pendingRestartGeneration = nil
            do {
                try self.startListening()
            } catch {
                self.stopEngine()
                self.onFailure(error.localizedDescription)
            }
        }
    }

    private func stopEngine() {
        activeGeneration = nil
        capture = nil
        levels.withLock { $0 = Levels() }
        if startEngineOverride != nil { return }
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private enum ListenerError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "on-device wake-word recognition is unavailable"
        }
    }
}
