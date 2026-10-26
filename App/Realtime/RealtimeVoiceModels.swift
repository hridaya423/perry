import AVFoundation
import Foundation
import PerryCore

enum RealtimeVoiceProtocolMode: String, CaseIterable, Sendable {
    case automatic
    case openAIGA
    case openAIBeta
    case compatible

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .openAIGA: return "OpenAI current"
        case .openAIBeta: return "OpenAI beta"
        case .compatible: return "Compatible endpoint"
        }
    }
}

enum RealtimeVoiceSessionState: Equatable {
    case idle
    case connecting
    case listening
    case responding
    case failed(String)
}

enum RealtimeVoiceEvent: Equatable, Sendable {
    case sessionReady
    case speechStarted
    case speechStopped
    case transcriptDelta(String)
    case transcriptFinal(String)
    case assistantTranscriptDelta(String, responseID: String?)
    case assistantTranscriptFinal(String, responseID: String?)
    case responseStarted(String?)
    case responseFinished(String?)
    case responseInterrupted(String?)
    case audio(Data, responseID: String?)
    case ignored
    case error(String)
}

struct RealtimeFirstAudioTimer {
    private var speechEndedAt: UInt64?

    mutating func markSpeechEnd(at timestamp: UInt64) {
        speechEndedAt = timestamp
    }

    mutating func markFirstAudio(at timestamp: UInt64) -> PerformanceSample? {
        guard let speechEndedAt, timestamp >= speechEndedAt else { return nil }
        self.speechEndedAt = nil
        return PerformanceSample(
            metricID: "voice.realtime_first_audio",
            collector: "perry.app.realtime-first-audio.v1",
            unit: "ms",
            value: Double(timestamp - speechEndedAt) / 1_000_000,
            scenario: "speech end to first scheduled realtime audio"
        )
    }

    mutating func reset() {
        speechEndedAt = nil
    }
}

struct RealtimeVoiceConfiguration: Equatable, Sendable {
    let endpoint: URL
    let model: String
    let voice: String
    let responseSpeed: Double
    let instructions: String
    let protocolMode: RealtimeVoiceProtocolMode
    let inputLanguage: String?

    init(
        endpoint: URL,
        model: String,
        voice: String = "marin",
        responseSpeed: Double = 1,
        instructions: String = "You are Perry, a concise and helpful desktop voice assistant. Speak naturally and keep replies short unless the user asks for detail.",
        protocolMode: RealtimeVoiceProtocolMode = .automatic,
        inputLanguage: String? = nil
    ) {
        self.endpoint = endpoint
        self.model = model
        let normalizedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voice = normalizedVoice.isEmpty ? "marin" : normalizedVoice
        self.responseSpeed = min(max(responseSpeed, 0.25), 1.5)
        self.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        self.protocolMode = protocolMode
        let normalizedLanguage = inputLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.inputLanguage = normalizedLanguage?.isEmpty == true ? nil : normalizedLanguage
    }
}

enum RealtimeVoiceError: Error, LocalizedError {
    case missingAPIKey
    case echoCancellationUnavailable
    case audioUnavailable
    case audioBufferFull
    case audioOutputBufferFull
    case responseCorrelationUnavailable
    case malformedProviderMessage
    case emptyInput
    case inputCorrelationLimitReached

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No realtime voice provider key is configured."
        case .echoCancellationUnavailable:
            return "macOS could not enable microphone echo cancellation."
        case .audioUnavailable:
            return "macOS could not start the realtime audio route."
        case .audioBufferFull:
            return "Realtime voice input is arriving faster than the connection can send it."
        case .audioOutputBufferFull:
            return "Realtime voice response audio exceeded its playback buffer limit; try again."
        case .responseCorrelationUnavailable:
            return "Realtime voice response correlation metadata was missing or unknown; the response was not admitted."
        case .malformedProviderMessage:
            return "The realtime voice provider returned an unreadable event."
        case .emptyInput:
            return "No microphone audio was captured for that turn."
        case .inputCorrelationLimitReached:
            return "Realtime voice reached its input correlation limit; start a new session."
        }
    }
}
