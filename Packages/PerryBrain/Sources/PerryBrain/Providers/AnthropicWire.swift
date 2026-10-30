import Foundation

struct AnthropicWire: WireFormat {
    func path(model: String) -> String { "v1/messages" }

    func authorize(_ request: inout URLRequest, key: String) {
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }

    func makeDecoder(provider: ProviderID) -> any WireDecoder {
        EventDecoder(provider: provider)
    }

    func body(for request: ModelRequest, model: String) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(request.maxOutputTokens)),
            "stream": .bool(true),
            "messages": .array(request.messages.map(Self.message)),
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
        return body
    }

    private static func blocks(_ parts: [ModelContentPart]) -> JSONValue {
        .array(parts.map { part in
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
        })
    }

    static func message(for message: ModelMessage) -> JSONValue {
        switch message {
        case .user(let parts):
            return .object(["role": .string("user"), "content": blocks(parts)])
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
            return .object(["role": .string("assistant"), "content": .array(content)])
        case .toolResult(let callID, let content, let isError):
            return .object([
                "role": .string("user"),
                "content": .array([.object([
                    "type": .string("tool_result"),
                    "tool_use_id": .string(callID),
                    "is_error": .bool(isError),
                    "content": blocks(content),
                ])]),
            ])
        }
    }

    private struct EventDecoder: WireDecoder {
        let provider: ProviderID
        var blocks: [Int: (id: String, name: String, json: String)] = [:]
        var inputTokens = 0
        var outputTokens = 0
        var stopReason: ModelStopReason?
        var isComplete = false

        init(provider: ProviderID) { self.provider = provider }

        mutating func consume(_ event: SSEEvent) throws -> [ModelEvent] {
            guard let payload = try? JSONValue(parsing: Data(event.data.utf8)),
                  let type = payload["type"]?.stringValue else { return [] }
            switch type {
            case "message_start":
                if let input = payload["message"]?["usage"]?["input_tokens"]?.doubleValue {
                    inputTokens = Int(input)
                }
            case "content_block_start":
                if let index = payload["index"]?.doubleValue,
                   let block = payload["content_block"]?.objectValue,
                   block["type"]?.stringValue == "tool_use" {
                    blocks[Int(index)] = (
                        id: block["id"]?.stringValue ?? UUID().uuidString,
                        name: block["name"]?.stringValue ?? "",
                        json: ""
                    )
                }
            case "content_block_delta":
                guard let index = payload["index"]?.doubleValue,
                      let delta = payload["delta"]?.objectValue else { return [] }
                switch delta["type"]?.stringValue {
                case "text_delta":
                    guard let text = delta["text"]?.stringValue else { return [] }
                    return [.textDelta(text)]
                case "input_json_delta":
                    if let partial = delta["partial_json"]?.stringValue {
                        blocks[Int(index)]?.json += partial
                    }
                default:
                    break
                }
            case "content_block_stop":
                guard let index = payload["index"]?.doubleValue,
                      let block = blocks.removeValue(forKey: Int(index)) else { return [] }
                guard let arguments = try? JSONValue(parsing: Data((block.json.isEmpty ? "{}" : block.json).utf8)) else {
                    throw ModelProviderError(kind: .malformed, provider: provider, message: "tool_use input was not valid JSON")
                }
                return [.toolCall(ToolCall(id: block.id, name: block.name, arguments: arguments))]
            case "message_delta":
                if let output = payload["usage"]?["output_tokens"]?.doubleValue {
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
                guard let stopReason, blocks.isEmpty else {
                    throw ModelProviderError(kind: .malformed, provider: provider, message: "The response ended without a complete result.")
                }
                isComplete = true
                var events: [ModelEvent] = []
                if inputTokens > 0 || outputTokens > 0 {
                    events.append(.usage(inputTokens: inputTokens, outputTokens: outputTokens))
                }
                events.append(.done(stopReason))
                return events
            case "error":
                let message = payload["error"]?["message"]?.stringValue ?? "stream failed"
                throw ModelProviderError(kind: .malformed, provider: provider, message: message)
            default:
                break
            }
            return []
        }

        mutating func finish() throws -> [ModelEvent] {
            guard isComplete else {
                throw ModelProviderError(kind: .malformed, provider: provider, message: incompleteStreamMessage)
            }
            return []
        }
    }
}
