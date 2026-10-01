import Foundation

public struct ModelCapabilityProbe: Sendable {
    public enum Check: Equatable, Sendable {
        case passed
        case failed(String)
        case notRun
    }

    public struct Result: Equatable, Sendable {
        public let text: Check
        public let vision: Check
        public let tools: Check

        public var capabilities: ModelCapabilities {
            var result: ModelCapabilities = []
            if text == .passed { result.insert(.streaming) }
            if vision == .passed { result.insert(.vision) }
            if tools == .passed { result.insert(.tools) }
            return result
        }
    }

    private let provider: any ModelProvider
    private let timeout: Duration

    public init(provider: any ModelProvider, timeout: Duration = .seconds(60)) {
        self.provider = provider
        self.timeout = timeout
    }

    public func run(image: Data, expectedImageText: String) async throws -> Result {
        let text = try await check {
            let events = try await collect(ModelRequest(messages: [.user([.text("Reply with exactly PERRY_READY and nothing else.")])], maxOutputTokens: 512))
            return answer(events) == "PERRY_READY"
        }
        guard text == .passed else { return Result(text: text, vision: .notRun, tools: .notRun) }
        let vision = try await check {
            let events = try await collect(ModelRequest(messages: [.user([
                .text("Read the digits in this image. Reply with only those digits."),
                .image(data: image, mimeType: "image/png")
            ])], maxOutputTokens: 512))
            return answer(events) == expectedImageText
        }
        let tools = try await check {
            let spec = ToolSpec(
                name: "perry_capability_check", description: "A harmless test that returns a value. It has no external effects.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["value": .object(["type": .string("string"), "enum": .array([.string("test")])])]),
                    "required": .array([.string("value")]), "additionalProperties": .bool(false)
                ]), readOnly: true
            )
            let prompt = ModelMessage.user([.text("Call perry_capability_check with value test. After its result arrives, reply with only the returned text.")])
            let events = try await collect(ModelRequest(messages: [prompt], tools: [spec], maxOutputTokens: 2048))
            let calls = events.compactMap { event -> ToolCall? in
                if case .toolCall(let call) = event { return call }
                return nil
            }
            guard calls.count == 1, let call = calls.first,
                  call.name == spec.name, call.arguments == .object(["value": .string("test")]) else { return false }
            let returned = UUID().uuidString
            let followUp = try await collect(ModelRequest(messages: [
                prompt, .assistant(text: answer(events), toolCalls: calls),
                .toolResult(callID: call.id, content: [.text(returned)], isError: false)
            ], tools: [spec], maxOutputTokens: 2048))
            return answer(followUp) == returned && !followUp.contains { if case .toolCall = $0 { return true }; return false }
        }
        return Result(text: text, vision: vision, tools: tools)
    }

    private func check(_ operation: @escaping @Sendable () async throws -> Bool) async throws -> Check {
        do {
            let passed = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask(operation: operation)
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ModelProviderError(kind: .unavailable, provider: provider.id, message: "The capability check timed out. Try again after the model finishes loading.")
                }
                defer { group.cancelAll() }
                return try await group.next() ?? false
            }
            try Task.checkCancellation()
            return passed ? .passed : .failed("The model did not complete this capability check correctly.")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return .failed(error.localizedDescription)
        }
    }

    private func collect(_ request: ModelRequest) async throws -> [ModelEvent] {
        var events: [ModelEvent] = []
        for try await event in provider.stream(request) {
            try Task.checkCancellation()
            events.append(event)
        }
        try Task.checkCancellation()
        return events
    }

    private func answer(_ events: [ModelEvent]) -> String {
        events.compactMap { event -> String? in
            if case .textDelta(let text) = event { return text }
            return nil
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
