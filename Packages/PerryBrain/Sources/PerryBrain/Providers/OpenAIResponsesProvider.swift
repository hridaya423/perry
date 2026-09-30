import Foundation
import PerryCore

public struct OpenAIResponsesProvider: ModelProvider {
    public let id: ProviderID
    public let displayName: String
    public let capabilities: ModelCapabilities = [.vision, .tools, .streaming, .longContext]

    private let baseURL: URL
    private let apiKeyProvider: @Sendable () -> String?
    private let models: BrainModelDefaults
    private let transport: any HTTPLineStreaming

    public init(
        id: ProviderID = .openAI,
        displayName: String = "OpenAI",
        baseURL: URL = URL(string: "https://api.openai.com")!,
        apiKeyProvider: @escaping @Sendable () -> String?,
        models: BrainModelDefaults = BrainModelCatalog.openAI,
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
        var pendingCalls: [String: (callID: String, name: String, arguments: String)] = [:]
        var emittedToolCall = false
        var finished = false

        func emitToolCall(from item: JSONValue) throws {
            guard let object = item.objectValue,
                  let name = object["name"]?.stringValue else {
                throw ModelProviderError(kind: .malformed, provider: id, message: "function_call item missing name")
            }
            let callID = object["call_id"]?.stringValue ?? object["id"]?.stringValue ?? UUID().uuidString
            let argumentsText = object["arguments"]?.stringValue ?? "{}"
            guard let arguments = try? JSONValue(parsing: Data(argumentsText.utf8)) else {
                throw ModelProviderError(kind: .malformed, provider: id, message: "tool call \(name) has malformed arguments")
            }
            continuation.yield(.toolCall(ToolCall(id: callID, name: name, arguments: arguments)))
            emittedToolCall = true
        }

        func handleEvent(_ event: SSEEvent) throws {
            guard event.data != "[DONE]" else { return }
            guard let payload = try? JSONValue(parsing: Data(event.data.utf8)),
                  let type = payload["type"]?.stringValue else { return }
            switch type {
            case "response.output_text.delta":
                if let delta = payload["delta"]?.stringValue {
                    continuation.yield(.textDelta(delta))
                }
            case "response.output_item.added":
                if let item = payload["item"], item["type"]?.stringValue == "function_call",
                   let itemID = item["id"]?.stringValue {
                    pendingCalls[itemID] = (
                        callID: item["call_id"]?.stringValue ?? itemID,
                        name: item["name"]?.stringValue ?? "",
                        arguments: ""
                    )
                }
            case "response.function_call_arguments.delta":
                if let itemID = payload["item_id"]?.stringValue, let delta = payload["delta"]?.stringValue {
                    pendingCalls[itemID]?.arguments += delta
                }
            case "response.output_item.done":
                if let item = payload["item"], item["type"]?.stringValue == "function_call" {
                    var merged = item.objectValue ?? [:]
                    if let itemID = item["id"]?.stringValue, let pending = pendingCalls.removeValue(forKey: itemID) {
                        merged["call_id"] = merged["call_id"] ?? .string(pending.callID)
                        merged["name"] = merged["name"] ?? .string(pending.name)
                        merged["arguments"] = .string(pending.arguments)
                    }
                    try emitToolCall(from: .object(merged))
                }
            case "response.completed":
                if let usage = payload["response"]?["usage"],
                   let input = usage["input_tokens"]?.doubleValue,
                   let output = usage["output_tokens"]?.doubleValue {
                    continuation.yield(.usage(inputTokens: Int(input), outputTokens: Int(output)))
                }
                continuation.yield(.done(emittedToolCall ? .toolUse : .endTurn))
                finished = true
            case "response.incomplete":
                let reason = payload["response"]?["status_details"]?["reason"]?.stringValue
                continuation.yield(.done(reason == "max_output_tokens" ? .maxTokens : .other(reason ?? "incomplete")))
                finished = true
            case "response.failed", "error":
                let message = payload["response"]?["error"]?["message"]?.stringValue
                    ?? payload["message"]?.stringValue ?? "stream failed"
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
            throw ModelProviderError(kind: .malformed, provider: id, message: "The response ended before the model confirmed completion.")
        }
    }

    func makeRequest(_ request: ModelRequest) throws -> URLRequest {
        var urlRequest = try BrainHTTP.post(baseURL, path: "v1/responses", provider: id)
        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw ModelProviderError(kind: .unauthenticated, provider: id, message: "API key is missing")
        }
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var input: [JSONValue] = []
        for message in request.messages {
            input.append(contentsOf: Self.inputItems(for: message, provider: id))
        }

        var body: [String: JSONValue] = [
            "model": .string(models.model(for: request.tier)),
            "stream": .bool(true),
            "input": .array(input),
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
        urlRequest.httpBody = try JSONValue.object(body).data()
        return urlRequest
    }

    private static func inputContent(_ parts: [ModelContentPart]) -> [JSONValue] {
        parts.map { part in
            switch part {
            case .text(let text):
                return .object(["type": .string("input_text"), "text": .string(text)])
            case .image(let data, let mimeType):
                return .object([
                    "type": .string("input_image"),
                    "image_url": .string("data:\(mimeType);base64,\(data.base64EncodedString())")
                ])
            }
        }
    }

    static func inputItems(for message: ModelMessage, provider: ProviderID) -> [JSONValue] {
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
                    "arguments": .string(String(decoding: (try? call.arguments.data()) ?? Data(), as: UTF8.self)),
                ]))
            }
            return items
        case .toolResult(let callID, let content, _):
            let text = content.compactMap { part -> String? in
                if case .text(let t) = part { return t }
                return nil
            }.joined(separator: "\n")
            return [.object([
                "type": .string("function_call_output"),
                "call_id": .string(callID),
                "output": content.contains { if case .image = $0 { return true }; return false }
                    ? .array(inputContent(content)) : .string(text),
            ])]
        }
    }
}
