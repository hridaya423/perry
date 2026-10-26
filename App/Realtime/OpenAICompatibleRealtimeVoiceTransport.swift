import AVFoundation
import Foundation
import PerryCore

actor OpenAICompatibleRealtimeVoiceTransport: RealtimeVoiceTransport {
    private let task: URLSessionWebSocketTask
    private let configuration: RealtimeVoiceConfiguration
    private let mode: RealtimeVoiceProtocolMode
    private var didResume = false
    private var inputHasAudio = false
    private var correlation = RealtimeVoiceTransportCorrelation()
    private var unechoedResponseMetadata: [String: String]?

    init(configuration: RealtimeVoiceConfiguration, apiKey: String) {
        self.task = URLSession.shared.webSocketTask(with: Self.request(for: configuration, apiKey: apiKey))
        self.configuration = configuration
        self.mode = Self.mode(for: configuration)
    }

    static func mode(for configuration: RealtimeVoiceConfiguration) -> RealtimeVoiceProtocolMode {
        guard configuration.protocolMode == .automatic else { return configuration.protocolMode }
        let host = configuration.endpoint.host ?? ""
        if host.contains("api.openai.com") { return .openAIGA }
        if host.contains("api.x.ai") { return .grok }
        return .compatible
    }

    static func request(for configuration: RealtimeVoiceConfiguration, apiKey: String) -> URLRequest {
        var url = configuration.endpoint
        if mode(for: configuration) == .grok,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.queryItems?.contains(where: { $0.name == "model" }) != true {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "model", value: configuration.model)]
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if configuration.protocolMode == .openAIBeta {
            request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        }
        return request
    }

    func connect() async throws {
        guard !didResume else { return }
        try NetworkEndpointPolicy.requireSafe(configuration.endpoint)
        task.resume()
        didResume = true
        try await send(payload: sessionUpdatePayload())
    }

    func sendAudio(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        inputHasAudio = true
        try await send(payload: [
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString(),
        ])
    }

    func finishInput(tag: RealtimeVoicePacketTag, request: RealtimeVoiceResponseRequest) async throws {
        guard inputHasAudio else { throw RealtimeVoiceError.emptyInput }
        guard request.tag == tag else { throw RealtimeVoiceError.responseCorrelationUnavailable }
        guard correlation.enqueueCommit(tag: tag) else {
            throw RealtimeVoiceError.inputCorrelationLimitReached
        }
        inputHasAudio = false
        var commitSent = false
        do {
            try await send(payload: ["type": "input_audio_buffer.commit"])
            commitSent = true
            try await requestResponse(request)
        } catch {
            if !commitSent {
                correlation.removePendingCommit(tag: tag)
            }
            throw error
        }
    }

    /// Commit without `response.create`: the provider transcribes the
    /// buffered audio and stays silent — Talk's brain owns the reply.
    func commitInput(tag: RealtimeVoicePacketTag) async throws {
        guard inputHasAudio else { throw RealtimeVoiceError.emptyInput }
        guard correlation.enqueueCommit(tag: tag) else {
            throw RealtimeVoiceError.inputCorrelationLimitReached
        }
        inputHasAudio = false
        do {
            try await send(payload: ["type": "input_audio_buffer.commit"])
        } catch {
            correlation.removePendingCommit(tag: tag)
            throw error
        }
    }

    func cancelResponse() async throws {
        try await send(payload: ["type": "response.cancel"])
    }

    func clearInput() async throws {
        inputHasAudio = false
        try await send(payload: ["type": "input_audio_buffer.clear"])
    }

    func sendText(_ text: String, request: RealtimeVoiceResponseRequest) async throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        try await send(payload: [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": normalized]],
            ],
        ])
        try await requestResponse(request)
    }

    private func requestResponse(_ request: RealtimeVoiceResponseRequest) async throws {
        switch mode {
        case .openAIGA:
            try await send(payload: [
                "type": "response.create",
                "response": [
                    "output_modalities": ["audio"],
                    "metadata": request.metadata,
                ],
            ])
        case .openAIBeta, .compatible:
            try await send(payload: [
                "type": "response.create",
                "response": [
                    "modalities": ["audio", "text"],
                    "metadata": request.metadata,
                ],
            ])
        case .grok:
            unechoedResponseMetadata = request.metadata
            try await send(payload: ["type": "response.create"])
        case .automatic:
            break
        }
    }

    func receive() async throws -> RealtimeVoiceTransportEvent {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .data(let value):
            data = value
        case .string(let value):
            data = Data(value.utf8)
        @unknown default:
            return .ignored
        }
        return try decodeEvent(data)
    }

    func decodeEvent(_ data: Data) throws -> RealtimeVoiceTransportEvent {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RealtimeVoiceError.malformedProviderMessage
        }
        let type = (payload["type"] as? String ?? "").lowercased()
        let responseID = payload["response_id"] as? String
        if type == "session.updated" || type == "session.created" {
            return .sessionReady
        }
        if type == "input_audio_buffer.speech_started" {
            return .speechStarted
        }
        if type == "input_audio_buffer.speech_stopped" {
            return .speechStopped
        }
        if type == "input_audio_buffer.committed" {
            let itemID = payload["item_id"] as? String
            guard correlation.acknowledge(itemID: itemID) != nil else {
                if correlation.isAtCapacity {
                    return .error(RealtimeVoiceError.inputCorrelationLimitReached.localizedDescription)
                }
                return .ignored
            }
            return .ignored
        }
        if type.contains("error") {
            let error = payload["error"] as? [String: Any]
            return .error(error?["message"] as? String ?? "realtime voice provider error")
        }
        if type == "response.created" {
            let response = payload["response"] as? [String: Any]
            var metadata = stringMetadata(response?["metadata"])
            if mode == .grok, metadata == nil {
                metadata = unechoedResponseMetadata
                unechoedResponseMetadata = nil
            }
            return .responseStarted(response?["id"] as? String ?? responseID, metadata: metadata)
        }
        if type == "response.done" || type == "response.completed" {
            let response = payload["response"] as? [String: Any]
            return .responseFinished(response?["id"] as? String ?? responseID)
        }
        if type == "response.cancelled" || type == "response.canceled" || type == "response.interrupted" {
            return .responseInterrupted(responseID)
        }
        if type == "response.output_audio.delta" || type == "response.audio.delta" {
            guard let encoded = payload["delta"] as? String,
                  let decoded = Data(base64Encoded: encoded) else { return .ignored }
            return .audio(decoded, responseID: responseID)
        }
        if type == "conversation.item.input_audio_transcription.updated" {
            guard let text = (payload["transcript"] as? String) ?? (payload["delta"] as? String), !text.isEmpty else {
                return .ignored
            }
            return .transcriptDelta(
                text,
                correlation: correlation.transcriptCorrelation(for: payload["item_id"] as? String)
            )
        }
        if type == "conversation.item.input_audio_transcription.delta"
            || type == "input_audio_transcription.delta" {
            guard let text = payload["delta"] as? String, !text.isEmpty else { return .ignored }
            return .transcriptDelta(
                text,
                correlation: correlation.transcriptCorrelation(for: payload["item_id"] as? String)
            )
        }
        if type == "conversation.item.input_audio_transcription.completed"
            || type == "input_audio_transcription.completed" {
            guard let text = payload["transcript"] as? String, !text.isEmpty else { return .ignored }
            return .transcriptFinal(
                text,
                correlation: correlation.transcriptCorrelation(for: payload["item_id"] as? String)
            )
        }
        if type == "response.output_audio_transcript.delta"
            || type == "response.audio_transcript.delta"
            || type == "response.text.delta" {
            guard let text = payload["delta"] as? String, !text.isEmpty else { return .ignored }
            return .assistantTranscriptDelta(text, responseID: responseID)
        }
        if type == "response.output_audio_transcript.done"
            || type == "response.audio_transcript.done"
            || type == "response.text.done" {
            guard let text = (payload["transcript"] as? String) ?? (payload["text"] as? String), !text.isEmpty else {
                return .ignored
            }
            return .assistantTranscriptFinal(text, responseID: responseID)
        }
        return .ignored
    }

    #if DEBUG
    func prepareResponseFixture(_ request: RealtimeVoiceResponseRequest) {
        unechoedResponseMetadata = request.metadata
    }

    func prepareCommitFixture(tag: RealtimeVoicePacketTag) throws {
        guard correlation.enqueueCommit(tag: tag) else {
            throw RealtimeVoiceError.inputCorrelationLimitReached
        }
    }
    #endif

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func send(payload: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func stringMetadata(_ value: Any?) -> [String: String]? {
        guard let metadata = value as? [String: Any] else { return nil }
        let strings = metadata.compactMapValues { $0 as? String }
        guard strings.count == metadata.count else { return nil }
        return strings
    }

    func sessionUpdatePayload() -> [String: Any] {
        let inputFormat: [String: Any] = ["type": "audio/pcm", "rate": 24_000]
        var transcription: [String: Any] = ["model": configuration.transcriptionModel]
        if let inputLanguage = configuration.inputLanguage {
            transcription["language"] = inputLanguage
        }
        switch mode {
        case .openAIGA:
            let input: [String: Any] = [
                "format": inputFormat,
                "transcription": transcription,
                "noise_reduction": ["type": "near_field"],
                "turn_detection": NSNull(),
            ]
            return [
                "type": "session.update",
                "session": [
                    "type": "realtime",
                    "model": configuration.model,
                    "instructions": configuration.instructions,
                    "output_modalities": ["audio"],
                    "audio": [
                        "input": input,
                        "output": [
                            "format": inputFormat,
                            "voice": configuration.voice,
                            "speed": configuration.responseSpeed,
                        ],
                    ],
                ],
            ]
        case .grok:
            var grokTranscription: [String: Any] = ["model": configuration.transcriptionModel]
            if let inputLanguage = configuration.inputLanguage {
                grokTranscription["language_hint"] = inputLanguage
            }
            return [
                "type": "session.update",
                "session": [
                    "instructions": configuration.instructions,
                    "voice": configuration.voice,
                    "turn_detection": NSNull(),
                    "audio": [
                        "input": ["format": inputFormat, "transcription": grokTranscription],
                        "output": ["format": inputFormat, "speed": configuration.responseSpeed],
                    ],
                ],
            ]
        case .openAIBeta, .compatible:
            return [
                "type": "session.update",
                "session": [
                    "model": configuration.model,
                    "instructions": configuration.instructions,
                    "modalities": ["text", "audio"],
                    "voice": configuration.voice,
                    "input_audio_format": "pcm16",
                    "output_audio_format": "pcm16",
                    "input_audio_transcription": transcription,
                    "turn_detection": NSNull(),
                ],
            ]
        case .automatic:
            return [:]
        }
    }
}
