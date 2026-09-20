import AVFoundation
import Speech
import PerryGuide

@MainActor
final class WakeWordListener {
    typealias RestartScheduler = (@escaping @MainActor @Sendable () -> Void) -> Void
    typealias StartEngineOverride = (UInt64, @escaping () -> Void) throws -> Void

    private let onWake: (String) -> Void
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

    init(
        onWake: @escaping (String) -> Void,
        onFailure: @escaping (String) -> Void = { _ in },
        scheduleRestart: @escaping RestartScheduler = { work in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        },
        startEngineOverride: StartEngineOverride? = nil
    ) {
        self.onWake = onWake
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
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            recognitionRequest.append(buffer)
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

    private func inspect(_ transcript: String) {
        guard wantsToListen,
              let command = WakeWordGate(enabled: true).match(inTranscript: transcript) else { return }
        stop()
        onWake(command)
    }

    private func restartAfterTerminal(for generation: UInt64) {
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
