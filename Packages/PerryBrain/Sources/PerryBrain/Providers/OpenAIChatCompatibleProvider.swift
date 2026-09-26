import Foundation
import PerryCore

public struct OpenAIChatCompatibleProvider: ModelProvider {
    public let id: ProviderID
    public let displayName: String
    public let capabilities: ModelCapabilities

    private let baseURL: URL
    private let apiKeyProvider: @Sendable () -> String?
    private let models: BrainModelDefaults
    private let transport: any HTTPLineStreaming

    public init(
        id: ProviderID,
        displayName: String,
        baseURL: URL,
        apiKeyProvider: @escaping @Sendable () -> String? = { nil },
        models: BrainModelDefaults,
        capabilities: ModelCapabilities = [.tools, .streaming],
        transport: any HTTPLineStreaming = URLSessionLineStreaming()
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiKeyProvider = apiKeyProvider
        self.models = models
        var resolved = capabilities
        if let host = baseURL.host?.lowercased(),
           host == "localhost" || host == "::1" || host.hasPrefix("127.") {
            resolved.insert(.local)
        }
        self.capabilities = resolved
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
        var toolBuffers: [Int: (id: String, name: String, arguments: String)] = [:]
        var stopReason: ModelStopReason?
        var sawToolCalls = false

        func flushToolCalls() throws {
            for index in toolBuffers.keys.sorted() {
                guard let buffered = toolBuffers[index] else { continue }
                let arguments = buffered.arguments.isEmpty ? .object([:]) : (try? JSONValue(parsing: Data(buffered.arguments.utf8)))
                guard let arguments else {
                    throw ModelProviderError(kind: .malformed, provider: id, message: "tool call arguments were not valid JSON")
                }
                continuation.yield(.toolCall(ToolCall(id: buffered.id, name: buffered.name, arguments: arguments)))
                sawToolCalls = true
            }
            toolBuffers = [:]
        }

        func handleEvent(_ event: SSEEvent) throws {
            guard event.data != "[DONE]" else { return }
            guard let payload = try? JSONValue(parsing: Data(event.data.utf8)) else { return }
            if let error = payload["error"]?.objectValue {
                let message = error["message"]?.stringValue ?? "stream failed"
                throw ModelProviderError(kind: .malformed, provider: id, message: message)
            }
            if let usage = payload["usage"]?.objectValue,
               let input = usage["prompt_tokens"]?.doubleValue,
               let output = usage["completion_tokens"]?.doubleValue {
                continuation.yield(.usage(inputTokens: Int(input), outputTokens: Int(output)))
            }
            guard let choice = payload["choices"]?.arrayValue?.first?.objectValue else { return }
            if let delta = choice["delta"]?.objectValue {
                if let text = delta["content"]?.stringValue {
                    continuation.yield(.textDelta(text))
                }
                if let toolCalls = delta["tool_calls"]?.arrayValue {
                    for call in toolCalls {
                        guard let callObject = call.objectValue,
                              let index = callObject["index"]?.doubleValue else { continue }
                        let key = Int(index)
                        var buffer = toolBuffers[key] ?? (id: "", name: "", arguments: "")
                        if let callID = callObject["id"]?.stringValue { buffer.id = callID }
                        if let function = callObject["function"]?.objectValue {
                            if let name = function["name"]?.stringValue { buffer.name = name }
                            if let arguments = function["arguments"]?.stringValue { buffer.arguments += arguments }
                        }
                        toolBuffers[key] = buffer
                    }
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
        try flushToolCalls()
        continuation.yield(.done(stopReason ?? (sawToolCalls ? .toolUse : .endTurn)))
    }

    func makeRequest(_ request: ModelRequest) throws -> URLRequest {
        var urlRequest = try BrainHTTP.post(baseURL, path: "v1/chat/completions", provider: id)
        if let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var messages: [JSONValue] = []
        if !request.system.isEmpty {
            messages.append(.object(["role": .string("system"), "content": .string(request.system)]))
        }
        for message in request.messages {
            messages.append(contentsOf: Self.chatMessages(for: message))
        }

        var body: [String: JSONValue] = [
            "model": .string(models.model(for: request.tier)),
            "stream": .bool(true),
            "messages": .array(messages),
            "stream_options": .object(["include_usage": .bool(true)]),
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
        urlRequest.httpBody = try JSONValue.object(body).data()
        return urlRequest
    }

    static func chatMessages(for message: ModelMessage) -> [JSONValue] {
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
                            "type": .string("image_url"),
                            "image_url": .object(["url": .string("data:\(mimeType);base64,\(data.base64EncodedString())")]),
                        ])
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
                            "arguments": .string(String(decoding: (try? call.arguments.data()) ?? Data(), as: UTF8.self)),
                        ]),
                    ])
                })
            }
            return [.object(object)]
        case .toolResult(let callID, let content, _):
            let text = content.compactMap { part -> String? in
                if case .text(let t) = part { return t }
                return nil
            }.joined(separator: "\n")
            return [.object([
                "role": .string("tool"),
                "tool_call_id": .string(callID),
                "content": .string(text),
            ])]
        }
    }
}
