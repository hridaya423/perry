import Foundation

struct OpenAIResponsesWire: WireFormat {
    func path(model: String) -> String { "v1/responses" }

    func makeDecoder(provider: ProviderID) -> any WireDecoder {
        EventDecoder(provider: provider)
    }

    func body(for request: ModelRequest, model: String) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "stream": .bool(true),
            "input": .array(request.messages.flatMap(Self.inputItems)),
            "max_output_tokens": .number(Double(request.maxOutputTokens)),
        ]
        if !request.system.isEmpty {
            body["instructions"] = .string(request.system)
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                .object([
                    "type": .string("function"),
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "parameters": tool.inputSchema,
                ])
            })
        }
        return body
    }

    private static func inputContent(_ parts: [ModelContentPart]) -> [JSONValue] {
        parts.map { part in
            switch part {
            case .text(let text):
                return .object(["type": .string("input_text"), "text": .string(text)])
            case .image(let data, let mimeType):
                return .object(["type": .string("input_image"), "image_url": .string(data.dataURL(mimeType: mimeType))])
            }
        }
    }

    static func inputItems(for message: ModelMessage) -> [JSONValue] {
        switch message {
        case .user(let parts):
            return [.object([
                "type": .string("message"),
                "role": .string("user"),
                "content": .array(inputContent(parts)),
            ])]
        case .assistant(let text, let toolCalls):
            var items: [JSONValue] = []
            if !text.isEmpty {
                items.append(.object([
                    "type": .string("message"),
                    "role": .string("assistant"),
                    "content": .array([.object(["type": .string("output_text"), "text": .string(text)])]),
                ]))
            }
            for call in toolCalls {
                items.append(.object([
                    "type": .string("function_call"),
                    "call_id": .string(call.id),
                    "name": .string(call.name),
                    "arguments": .string(call.argumentsJSON),
                ]))
            }
            return items
        case .toolResult(let callID, let content, _):
            return [.object([
                "type": .string("function_call_output"),
                "call_id": .string(callID),
                "output": content.containsImage ? .array(inputContent(content)) : .string(content.joinedText),
            ])]
        }
    }

    private struct EventDecoder: WireDecoder {
        let provider: ProviderID
        var pendingCalls: [String: (callID: String, name: String, arguments: String)] = [:]
        var emittedToolCall = false
        var isComplete = false

        init(provider: ProviderID) { self.provider = provider }

        mutating func consume(_ event: SSEEvent) throws -> [ModelEvent] {
            guard event.data != "[DONE]",
                  let payload = try? JSONValue(parsing: Data(event.data.utf8)),
                  let type = payload["type"]?.stringValue else { return [] }
            switch type {
            case "response.output_text.delta":
                guard let delta = payload["delta"]?.stringValue else { return [] }
                return [.textDelta(delta)]
            case "response.output_item.added":
                if let item = payload["item"], item["type"]?.stringValue == "function_call",
                   let itemID = item["id"]?.stringValue {
                    pendingCalls[itemID] = (
                        callID: item["call_id"]?.stringValue ?? itemID,
                        name: item["name"]?.stringValue ?? "",
                        arguments: ""
                    )
                }
                return []
            case "response.function_call_arguments.delta":
                if let itemID = payload["item_id"]?.stringValue, let delta = payload["delta"]?.stringValue {
                    pendingCalls[itemID]?.arguments += delta
                }
                return []
            case "response.output_item.done":
                guard let item = payload["item"], item["type"]?.stringValue == "function_call" else { return [] }
                var merged = item.objectValue ?? [:]
                if let itemID = item["id"]?.stringValue, let pending = pendingCalls.removeValue(forKey: itemID) {
                    merged["call_id"] = merged["call_id"] ?? .string(pending.callID)
                    merged["name"] = merged["name"] ?? .string(pending.name)
                    merged["arguments"] = .string(pending.arguments)
                }
                return [.toolCall(try makeToolCall(from: merged))]
            case "response.completed":
                var events: [ModelEvent] = []
                if let usage = payload["response"]?["usage"],
                   let input = usage["input_tokens"]?.doubleValue,
                   let output = usage["output_tokens"]?.doubleValue {
                    events.append(.usage(inputTokens: Int(input), outputTokens: Int(output)))
                }
                events.append(.done(emittedToolCall ? .toolUse : .endTurn))
                isComplete = true
                return events
            case "response.incomplete":
                let reason = payload["response"]?["status_details"]?["reason"]?.stringValue
                isComplete = true
                return [.done(reason == "max_output_tokens" ? .maxTokens : .other(reason ?? "incomplete"))]
            case "response.failed", "error":
                let message = payload["response"]?["error"]?["message"]?.stringValue
                    ?? payload["message"]?.stringValue ?? "stream failed"
                throw ModelProviderError(kind: .malformed, provider: provider, message: message)
            default:
                return []
            }
        }

        mutating func finish() throws -> [ModelEvent] {
            guard isComplete else {
                throw ModelProviderError(kind: .malformed, provider: provider, message: incompleteStreamMessage)
            }
            return []
        }

        private mutating func makeToolCall(from object: [String: JSONValue]) throws -> ToolCall {
            guard let name = object["name"]?.stringValue else {
                throw ModelProviderError(kind: .malformed, provider: provider, message: "function_call item missing name")
            }
            let callID = object["call_id"]?.stringValue ?? object["id"]?.stringValue ?? UUID().uuidString
            let argumentsText = object["arguments"]?.stringValue ?? "{}"
            guard let arguments = try? JSONValue(parsing: Data(argumentsText.utf8)) else {
                throw ModelProviderError(kind: .malformed, provider: provider, message: "tool call \(name) has malformed arguments")
            }
            emittedToolCall = true
            return ToolCall(id: callID, name: name, arguments: arguments)
        }
    }
}
