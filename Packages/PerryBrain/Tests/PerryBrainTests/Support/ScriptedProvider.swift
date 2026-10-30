import Foundation
@testable import PerryBrain

final class ScriptedProvider: ModelProvider, @unchecked Sendable {
    let id: ProviderID = "scripted"
    let displayName = "Scripted"
    let capabilities: ModelCapabilities
    let capacity: Int?

    private let lock = NSLock()
    private var queue: [[ModelEvent]]
    private(set) var requests: [ModelRequest] = []

    init(responses: [[ModelEvent]], capabilities: ModelCapabilities = [.tools, .streaming], capacity: Int? = nil) {
        self.queue = responses
        self.capabilities = capabilities
        self.capacity = capacity
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        let events = lock.withLock { () -> [ModelEvent] in
            requests.append(request)
            return queue.isEmpty ? [] : queue.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func warm() async {}
    func contextWindow(for tier: ModelTier) async throws -> Int? { capacity }
}

final class RecordingExecutor: ToolExecutor, @unchecked Sendable {
    let spec: ToolSpec
    private let lock = NSLock()
    private(set) var calls: [ToolCall] = []
    var body: @Sendable (ToolCall) async throws -> ToolResult = { .text($0.id, "ok") }

    init(spec: ToolSpec) { self.spec = spec }

    var callCount: Int { lock.withLock { calls.count } }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        lock.withLock { calls.append(call) }
        return try await body(call)
    }
}

func toolSchema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
    .object([
        "type": .string("object"),
        "properties": .object(properties),
        "required": .array(required.map { .string($0) }),
    ])
}
