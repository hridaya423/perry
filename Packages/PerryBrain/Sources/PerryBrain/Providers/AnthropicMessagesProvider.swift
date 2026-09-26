import Foundation
import PerryCore

public struct AnthropicMessagesProvider: ModelProvider {
    public let id: ProviderID
    public let displayName: String
    public let capabilities: ModelCapabilities = [.vision, .tools, .streaming, .longContext]

    private let baseURL: URL
    private let apiKeyProvider: @Sendable () -> String?
    private let models: BrainModelDefaults
    private let transport: any HTTPLineStreaming

    public init(
        id: ProviderID = .anthropic,
        displayName: String = "Anthropic",
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        apiKeyProvider: @escaping @Sendable () -> String?,
        models: BrainModelDefaults = BrainModelCatalog.anthropic,
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
        var blocks: [Int: (id: String, name: String, json: String)] = [:]
        var sawToolCall = false
        var inputTokens = 0
        var outputTokens = 0
        var stopReason: ModelStopReason?
        var finished = false

        func handleEvent(_ event: SSEEvent) throws {
            guard let payload = try? JSONValue(parsing: Data(event.data.utf8)),
                  let type = payload["type"]?.stringValue else { return }
            switch type {
            case "message_start":
                if let usage = payload["message"]?["usage"]?.objectValue,
                   let input = usage["input_tokens"]?.doubleValue {
                    inputTokens = Int(input)
                }
            case "content_block_start":
                guard let index = payload["index"]?.doubleValue,
                      let block = payload["content_block"]?.objectValue else { return }
                if block["type"]?.stringValue == "tool_use" {
                    blocks[Int(index)] = (
                        id: block["id"]?.stringValue ?? UUID().uuidString,
                        name: block["name"]?.stringValue ?? "",
                        json: ""
                    )
                }
            case "content_block_delta":
                guard let index = payload["index"]?.doubleValue,
                      let delta = payload["delta"]?.objectValue else { return }
                switch delta["type"]?.stringValue {
                case "text_delta":
                    if let text = delta["text"]?.stringValue {
                        continuation.yield(.textDelta(text))
                    }
                case "input_json_delta":
                    if let partial = delta["partial_json"]?.stringValue {
                        blocks[Int(index)]?.json += partial
                    }
                default:
                    break
                }
            case "content_block_stop":
                guard let index = payload["index"]?.doubleValue,
                      let block = blocks.removeValue(forKey: Int(index)) else { return }
                let argumentsText = block.json.isEmpty ? "{}" : block.json
                guard let arguments = try? JSONValue(parsing: Data(argumentsText.utf8)) else {
                    throw ModelProviderError(kind: .malformed, provider: id, message: "tool_use input was not valid JSON")
                }
                continuation.yield(.toolCall(ToolCall(id: block.id, name: block.name, arguments: arguments)))
                sawToolCall = true
            case "message_delta":
                if let usage = payload["usage"]?.objectValue,
                   let output = usage["output_tokens"]?.doubleValue {
                    outputTokens = Int(output)
                }
                if let reason = payload["delta"]?["stop_reason"]?.stringValue {
                    switch reason {
                    case "end_turn": stopReason = .endTurn
                    case "tool_use": stopReason = .toolUse
                    case "max_tokens": stopReason = .maxTokens
                    default: stopReason = .other(reason)
                    }
                }
            case "message_stop":
                if inputTokens > 0 || outputTokens > 0 {
                    continuation.yield(.usage(inputTokens: inputTokens, outputTokens: outputTokens))
                }
                continuation.yield(.done(stopReason ?? (sawToolCall ? .toolUse : .endTurn)))
                finished = true
            case "error":
                let message = payload["error"]?["message"]?.stringValue ?? "stream failed"
                throw ModelProviderError(kind: .malformed, provider: id, message: message)
            default:
                break
            }
        }

        for try await line in lines {
            try Task.checkCancellation()
            if let event = parser.feed(line: line) {
                try handleEvent(event)
                if finished { break }
            }
        }
        if !finished, let event = parser.finish() {
            try handleEvent(event)
        }
        if !finished {
            continuation.yield(.done(stopReason ?? .endTurn))
        }
    }

    func makeRequest(_ request: ModelRequest) throws -> URLRequest {
        var urlRequest = try BrainHTTP.post(baseURL, path: "v1/messages", provider: id)
        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw ModelProviderError(kind: .unauthenticated, provider: id, message: "API key is missing")
        }
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var body: [String: JSONValue] = [
            "model": .string(models.model(for: request.tier)),
            "max_tokens": .number(Double(request.maxOutputTokens)),
            "stream": .bool(true),
            "messages": .array(request.messages.flatMap { Self.messages(for: $0) }),
        ]
        if !request.system.isEmpty {
            body["system"] = .string(request.system)
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.inputSchema,
                ])
            })
        }
        urlRequest.httpBody = try JSONValue.object(body).data()
        return urlRequest
    }

    static func messages(for message: ModelMessage) -> [JSONValue] {
        switch message {
        case .user(let parts):
            return [.object([
                "role": .string("user"),
                "content": .array(parts.compactMap { part in
                    switch part {
                    case .text(let text):
                        return .object(["type": .string("text"), "text": .string(text)])
                    case .image(let data, let mimeType):
                        return .object([
                            "type": .string("image"),
                            "source": .object([
                                "type": .string("base64"),
                                "media_type": .string(mimeType),
                                "data": .string(data.base64EncodedString()),
                            ]),
                        ])
                    }
                }),
            ])]
        case .assistant(let text, let toolCalls):
            var content: [JSONValue] = []
            if !text.isEmpty {
                content.append(.object(["type": .string("text"), "text": .string(text)]))
            }
            for call in toolCalls {
                content.append(.object([
                    "type": .string("tool_use"),
                    "id": .string(call.id),
                    "name": .string(call.name),
                    "input": call.arguments,
                ]))
            }
            return [.object(["role": .string("assistant"), "content": .array(content)])]
        case .toolResult(let callID, let content, let isError):
            return [.object([
                "role": .string("user"),
                "content": .array([.object([
                    "type": .string("tool_result"),
                    "tool_use_id": .string(callID),
                    "is_error": .bool(isError),
                    "content": .array(content.compactMap { part in
                        switch part {
                        case .text(let text):
                            return .object(["type": .string("text"), "text": .string(text)])
                        case .image(let data, let mimeType):
                            return .object([
                                "type": .string("image"),
                                "source": .object([
                                    "type": .string("base64"),
                                    "media_type": .string(mimeType),
                                    "data": .string(data.base64EncodedString()),
                                ]),
                            ])
                        }
                    }),
                ])]),
            ])]
        }
    }
}
