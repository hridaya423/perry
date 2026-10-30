import Foundation

struct GeminiWire: WireFormat {
    var modelsPath: String { "v1beta/models" }
    var streamQuery: [URLQueryItem] { [URLQueryItem(name: "alt", value: "sse")] }

    func path(model: String) -> String { "v1beta/models/\(model):streamGenerateContent" }

    func authorize(_ request: inout URLRequest, key: String) {
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
    }

    func makeDecoder(provider: ProviderID) -> any WireDecoder {
        EventDecoder(provider: provider)
    }

    func body(for request: ModelRequest, model: String) -> [String: JSONValue] {
        var contents: [JSONValue] = []
        for message in ModelMessage.separatingToolImages(in: request.messages) {
            let content = Self.content(for: message)
            if var previous = contents.last?.objectValue,
               previous["role"] == content["role"],
               let previousParts = previous["parts"]?.arrayValue,
               let parts = content["parts"]?.arrayValue {
                previous["parts"] = .array(previousParts + parts)
                contents[contents.count - 1] = .object(previous)
            } else {
                contents.append(content)
            }
        }
        var body: [String: JSONValue] = [
            "contents": .array(contents),
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
        return body
    }

    static func content(for message: ModelMessage) -> JSONValue {
        switch message {
        case .user(let parts):
            return .object([
                "role": .string("user"),
                "parts": .array(parts.map { part in
                    switch part {
                    case .text(let text):
                        return .object(["text": .string(text)])
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
                parts.append(.object(["functionCall": .object(["name": .string(call.name), "args": call.arguments])]))
            }
            return .object(["role": .string("model"), "parts": .array(parts)])
        case .toolResult(let callID, let content, _):
            return .object([
                "role": .string("user"),
                "parts": .array([.object(["functionResponse": .object([
                    "name": .string(callID),
                    "response": .object(["result": .string(content.joinedText)]),
                ])])]),
            ])
        }
    }

    private struct EventDecoder: WireDecoder {
        let provider: ProviderID
        var toolCallCount = 0
        var stopReason: ModelStopReason?
        var usageEmitted = false
        var isComplete: Bool { false }

        init(provider: ProviderID) { self.provider = provider }

        mutating func consume(_ event: SSEEvent) throws -> [ModelEvent] {
            guard let payload = try? JSONValue(parsing: Data(event.data.utf8)) else { return [] }
            if let error = payload["error"]?.objectValue {
                throw ModelProviderError(kind: .malformed, provider: provider, message: error["message"]?.stringValue ?? "stream failed")
            }
            var events: [ModelEvent] = []
            if let usage = payload["usageMetadata"]?.objectValue, !usageEmitted {
                let input = usage["promptTokenCount"]?.doubleValue ?? 0
                let output = usage["candidatesTokenCount"]?.doubleValue ?? 0
                events.append(.usage(inputTokens: Int(input), outputTokens: Int(output)))
                usageEmitted = true
            }
            guard let candidate = payload["candidates"]?.arrayValue?.first?.objectValue else { return events }
            for part in candidate["content"]?["parts"]?.arrayValue ?? [] {
                if let text = part["text"]?.stringValue {
                    events.append(.textDelta(text))
                }
                if let call = part["functionCall"]?.objectValue, let name = call["name"]?.stringValue {
                    toolCallCount += 1
                    events.append(.toolCall(ToolCall(id: name, name: name, arguments: call["args"] ?? .object([:]))))
                }
            }
            if let finish = candidate["finishReason"]?.stringValue {
                switch finish {
                case "STOP": stopReason = toolCallCount > 0 ? .toolUse : .endTurn
                case "MAX_TOKENS": stopReason = .maxTokens
                default: stopReason = .other(finish)
                }
            }
            return events
        }

        mutating func finish() throws -> [ModelEvent] {
            guard let stopReason else {
                throw ModelProviderError(kind: .malformed, provider: provider, message: incompleteStreamMessage)
            }
            return [.done(stopReason)]
        }
    }
}
