import Foundation

struct OpenAIChatWire: WireFormat {
    var requiresKey: Bool { false }
    var fixedCapabilities: ModelCapabilities? { nil }

    func path(model: String) -> String { "v1/chat/completions" }

    func makeDecoder(provider: ProviderID) -> any WireDecoder {
        EventDecoder(provider: provider)
    }

    func body(for request: ModelRequest, model: String) -> [String: JSONValue] {
        var messages: [JSONValue] = []
        if !request.system.isEmpty {
            messages.append(.object(["role": .string("system"), "content": .string(request.system)]))
        }
        for message in ModelMessage.separatingToolImages(in: request.messages) {
            messages.append(contentsOf: Self.chatMessages(for: message))
        }
        var body: [String: JSONValue] = [
            "model": .string(model),
            "stream": .bool(true),
            "messages": .array(messages),
            "stream_options": .object(["include_usage": .bool(true)]),
            "max_tokens": .number(Double(request.maxOutputTokens)),
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                .object([
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.inputSchema,
                    ]),
                ])
            })
        }
        return body
    }

    static func chatMessages(for message: ModelMessage) -> [JSONValue] {
        switch message {
        case .user(let parts):
            return [.object([
                "role": .string("user"),
                "content": .array(parts.map { part in
                    switch part {
                    case .text(let text):
                        return .object(["type": .string("text"), "text": .string(text)])
                    case .image(let data, let mimeType):
                        return .object(["type": .string("image_url"), "image_url": .object(["url": .string(data.dataURL(mimeType: mimeType))])])
                    }
                }),
            ])]
        case .assistant(let text, let toolCalls):
            var object: [String: JSONValue] = ["role": .string("assistant")]
            object["content"] = text.isEmpty ? .null : .string(text)
            if !toolCalls.isEmpty {
                object["tool_calls"] = .array(toolCalls.enumerated().map { index, call in
                    .object([
                        "id": .string(call.id),
                        "index": .number(Double(index)),
                        "type": .string("function"),
                        "function": .object([
                            "name": .string(call.name),
                            "arguments": .string(call.argumentsJSON),
                        ]),
                    ])
                })
            }
            return [.object(object)]
        case .toolResult(let callID, let content, _):
            return [.object([
                "role": .string("tool"),
                "tool_call_id": .string(callID),
                "content": .string(content.joinedText),
            ])]
        }
    }

    private struct EventDecoder: WireDecoder {
        let provider: ProviderID
        var toolBuffers: [Int: (id: String, name: String, arguments: String)] = [:]
        var stopReason: ModelStopReason?
        var isComplete: Bool { false }

        init(provider: ProviderID) { self.provider = provider }

        mutating func consume(_ event: SSEEvent) throws -> [ModelEvent] {
            guard event.data != "[DONE]",
                  let payload = try? JSONValue(parsing: Data(event.data.utf8)) else { return [] }
            if let error = payload["error"]?.objectValue {
                throw ModelProviderError(kind: .malformed, provider: provider, message: error["message"]?.stringValue ?? "stream failed")
            }
            var events: [ModelEvent] = []
            if let usage = payload["usage"]?.objectValue,
               let input = usage["prompt_tokens"]?.doubleValue,
               let output = usage["completion_tokens"]?.doubleValue {
                events.append(.usage(inputTokens: Int(input), outputTokens: Int(output)))
            }
            guard let choice = payload["choices"]?.arrayValue?.first?.objectValue else { return events }
            if let delta = choice["delta"]?.objectValue {
                if let text = delta["content"]?.stringValue {
                    events.append(.textDelta(text))
                }
                for call in delta["tool_calls"]?.arrayValue ?? [] {
                    guard let callObject = call.objectValue, let index = callObject["index"]?.doubleValue else { continue }
                    var buffer = toolBuffers[Int(index)] ?? (id: "", name: "", arguments: "")
                    if let callID = callObject["id"]?.stringValue { buffer.id = callID }
                    if let function = callObject["function"]?.objectValue {
                        if let name = function["name"]?.stringValue { buffer.name = name }
                        if let arguments = function["arguments"]?.stringValue { buffer.arguments += arguments }
                    }
                    toolBuffers[Int(index)] = buffer
                }
            }
            if let finish = choice["finish_reason"]?.stringValue {
                switch finish {
                case "stop": stopReason = .endTurn
                case "tool_calls": stopReason = .toolUse
                case "length": stopReason = .maxTokens
                default: stopReason = .other(finish)
                }
            }
            return events
        }

        mutating func finish() throws -> [ModelEvent] {
            guard let stopReason else {
                throw ModelProviderError(kind: .malformed, provider: provider, message: incompleteStreamMessage)
            }
            var events: [ModelEvent] = []
            for index in toolBuffers.keys.sorted() {
                guard let buffered = toolBuffers[index] else { continue }
                let arguments = buffered.arguments.isEmpty ? .object([:]) : (try? JSONValue(parsing: Data(buffered.arguments.utf8)))
                guard let arguments else {
                    throw ModelProviderError(kind: .malformed, provider: provider, message: "tool call arguments were not valid JSON")
                }
                events.append(.toolCall(ToolCall(id: buffered.id, name: buffered.name, arguments: arguments)))
            }
            toolBuffers = [:]
            events.append(.done(stopReason))
            return events
        }
    }
}
