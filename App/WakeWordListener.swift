import AVFoundation
import os
import Speech
import PerryCore
import PerryGuide

struct WakeWordMatcher {
    private var recent: [Double] = []
    private var capture: (detector: EndOfTurnDetector, command: String)?

    mutating func tap(rms: Double) -> Bool {
        if capture == nil { record(rms) }
        return capture != nil
    }

    mutating func inspect(_ transcript: String, at now: TimeInterval) -> Bool {
        if var current = capture {
            current.command = Self.remainder(of: transcript)
            _ = current.detector.transcript(at: now, text: current.command, lastWordEnd: 0)
            capture = current
            return false
        }
        guard WakeWordGate(enabled: true).match(inTranscript: transcript) != nil else { return false }
        let command = Self.remainder(of: transcript)
        var detector = EndOfTurnDetector(startedAt: now, noiseFloor: floor)
        if !command.isEmpty {
            _ = detector.transcript(at: now, text: command, lastWordEnd: 0)
        }
        capture = (detector, command)
        return true
    }

    mutating func hear(rms: Double, at time: TimeInterval) -> String? {
        guard var current = capture else {
            record(rms)
            return nil
        }
        let event = current.detector.frame(at: time, rms: rms)
        capture = current
        switch event {
        case .commit?, .abort?:
            capture = nil
            return current.command
        default:
            return nil
        }
    }

    mutating func takeCommand() -> String? {
        defer { capture = nil }
        return capture?.command
    }

    mutating func reset() {
        self = WakeWordMatcher()
    }

    static func remainder(of transcript: String) -> String {
        let phraseWords = WakeWordGate.defaultPhrase.split(separator: " ").count
        return transcript.split(whereSeparator: \.isWhitespace).dropFirst(phraseWords).joined(separator: " ")
    }

    private var floor: Double? {
        guard !recent.isEmpty else { return nil }
        return recent.sorted()[recent.count / 5]
    }

    private mutating func record(_ rms: Double) {
        recent.append(rms)
        if recent.count > 75 { recent.removeFirst(recent.count - 75) }
    }
}

@MainActor
final class WakeWordListener {
    private let onWake: (String) -> Void
    private let onHeard: () -> Void
    private let onFailure: (String) -> Void
    private let mic = MicCapture()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var wantsToListen = false
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private var pendingRestartGeneration: UInt64?
    private let matcher = OSAllocatedUnfairLock(initialState: WakeWordMatcher())

    init(
        onWake: @escaping (String) -> Void,
        onHeard: @escaping () -> Void = {},
        onFailure: @escaping (String) -> Void = { _ in }
    ) {
        self.onWake = onWake
        self.onHeard = onHeard
        self.onFailure = onFailure
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
        activeGeneration != nil || mic.isRunning || request != nil || task != nil
    }

    private func startListening() throws {
        generation &+= 1
        let generation = generation
        activeGeneration = generation
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw ListenerError.unavailable
        }
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.contextualStrings = ["hey", "Perry"]
        recognitionRequest.requiresOnDeviceRecognition = true
        request = recognitionRequest
        let matcher = matcher
        try mic.start(deviceID: nil) { buffer, when in
            recognitionRequest.append(buffer)
            let rms = MicCapture.rms(buffer)
            guard matcher.withLock({ $0.tap(rms: rms) }) else { return }
            let time = AVAudioTime.seconds(forHostTime: when.hostTime)
            Task { @MainActor [weak self] in self?.hear(rms: rms, at: time) }
        }
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
        guard wantsToListen else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if matcher.withLock({ $0.inspect(transcript, at: now) }) {
            onHeard()
        }
    }

    private func hear(rms: Double, at time: TimeInterval) {
        guard wantsToListen else { return }
        if let command = matcher.withLock({ $0.hear(rms: rms, at: time) }) {
            finish(with: command)
        }
    }

    private func finish(with command: String) {
        stop()
        onWake(command)
    }

    private func restartAfterTerminal(for generation: UInt64) {
        if activeGeneration == generation, let command = matcher.withLock({ $0.takeCommand() }) {
            finish(with: command)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
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
        matcher.withLock { $0.reset() }
        mic.stop()
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
