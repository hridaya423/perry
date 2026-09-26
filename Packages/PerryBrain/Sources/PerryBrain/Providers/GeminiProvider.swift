import Foundation
import PerryCore

public struct GeminiProvider: ModelProvider {
    public let id: ProviderID
    public let displayName: String
    public let capabilities: ModelCapabilities = [.vision, .tools, .streaming, .longContext]

    private let baseURL: URL
    private let apiKeyProvider: @Sendable () -> String?
    private let models: BrainModelDefaults
    private let transport: any HTTPLineStreaming

    public init(
        id: ProviderID = .gemini,
        displayName: String = "Gemini",
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!,
        apiKeyProvider: @escaping @Sendable () -> String?,
        models: BrainModelDefaults = BrainModelCatalog.gemini,
        transport: any HTTPLineStreaming = URLSessionLineStreaming()
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiKeyProvider = apiKeyProvider
        self.models = models
        self.transport = transport
    }

    public func warm() async {}

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        let provider = self
        return BrainHTTP.eventStream { try await provider.run(request, into: $0) }
    }

    private func run(_ request: ModelRequest, into continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation) async throws {
        let urlRequest = try makeRequest(request)
        let (response, rawLines) = try await transport.lines(for: urlRequest)
        let lines = try await BrainHTTP.requireSuccess(response, lines: rawLines, provider: id)

        var parser = SSEParser()
        var toolCallCount = 0
        var stopReason: ModelStopReason?
        var usageEmitted = false

        func handleEvent(_ event: SSEEvent) throws {
            guard let payload = try? JSONValue(parsing: Data(event.data.utf8)) else { return }
            if let error = payload["error"]?.objectValue {
                throw ModelProviderError(
                    kind: .malformed, provider: id,
                    message: error["message"]?.stringValue ?? "stream failed"
                )
            }
            if let usage = payload["usageMetadata"]?.objectValue, !usageEmitted {
                let input = usage["promptTokenCount"]?.doubleValue ?? 0
                let output = usage["candidatesTokenCount"]?.doubleValue ?? 0
                continuation.yield(.usage(inputTokens: Int(input), outputTokens: Int(output)))
                usageEmitted = true
            }
            guard let candidate = payload["candidates"]?.arrayValue?.first?.objectValue else { return }
            if let parts = candidate["content"]?["parts"]?.arrayValue {
                for part in parts {
                    if let text = part["text"]?.stringValue {
                        continuation.yield(.textDelta(text))
                    }
                    if let call = part["functionCall"]?.objectValue, let name = call["name"]?.stringValue {
                        toolCallCount += 1
                        continuation.yield(.toolCall(ToolCall(
                            id: name,
                            name: name,
                            arguments: call["args"] ?? .object([:])
                        )))
                    }
                }
            }
            if let finish = candidate["finishReason"]?.stringValue {
                switch finish {
                case "STOP": stopReason = toolCallCount > 0 ? .toolUse : .endTurn
                case "MAX_TOKENS": stopReason = .maxTokens
                default: stopReason = .other(finish)
                }
            }
        }

        for try await line in lines {
            try Task.checkCancellation()
            if let event = parser.feed(line: line) {
                try handleEvent(event)
            }
        }
        if let event = parser.finish() {
            try handleEvent(event)
        }
        continuation.yield(.done(stopReason ?? (toolCallCount > 0 ? .toolUse : .endTurn)))
    }

    func makeRequest(_ request: ModelRequest) throws -> URLRequest {
        try NetworkEndpointPolicy.requireSafe(baseURL)
        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw ModelProviderError(kind: .unauthenticated, provider: id, message: "API key is missing")
        }
        let model = models.model(for: request.tier)
        var components = URLComponents(url: baseURL.appendingPathComponent("v1beta/models/\(model):streamGenerateContent"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.timeoutInterval = 120

        var body: [String: JSONValue] = [
            "contents": .array(request.messages.map { Self.content(for: $0) }),
            "generationConfig": .object(["maxOutputTokens": .number(Double(request.maxOutputTokens))]),
        ]
        if !request.system.isEmpty {
            body["systemInstruction"] = .object(["parts": .array([.object(["text": .string(request.system)])])])
        }
        if !request.tools.isEmpty {
            body["tools"] = .array([.object([
                "functionDeclarations": .array(request.tools.map { tool in
                    .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.inputSchema,
                    ])
                }),
            ])])
        }
        urlRequest.httpBody = try JSONValue.object(body).data()
        return urlRequest
    }

    static func content(for message: ModelMessage) -> JSONValue {
        switch message {
        case .user(let parts):
            return .object([
                "role": .string("user"),
                "parts": .array(parts.compactMap { part in
                    switch part {
                    case .text(let text): return .object(["text": .string(text)])
                    case .image(let data, let mimeType):
                        return .object(["inline_data": .object([
                            "mime_type": .string(mimeType),
                            "data": .string(data.base64EncodedString()),
                        ])])
                    }
                }),
            ])
        case .assistant(let text, let toolCalls):
            var parts: [JSONValue] = []
            if !text.isEmpty {
                parts.append(.object(["text": .string(text)]))
            }
            for call in toolCalls {
                parts.append(.object(["functionCall": .object([
                    "name": .string(call.name),
                    "args": call.arguments,
                ])]))
            }
            return .object(["role": .string("model"), "parts": .array(parts)])
        case .toolResult(let callID, let content, _):
            let text = content.compactMap { part -> String? in
                if case .text(let t) = part { return t }
                return nil
            }.joined(separator: "\n")
            return .object([
                "role": .string("user"),
                "parts": .array([.object(["functionResponse": .object([
                    "name": .string(callID),
                    "response": .object(["result": .string(text)]),
                ])])]),
            ])
        }
    }
}
