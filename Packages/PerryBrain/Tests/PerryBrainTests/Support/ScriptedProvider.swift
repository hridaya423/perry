import Foundation
@testable import PerryBrain

/// Returns a queued list of events per stream() call; records every request.
final class ScriptedProvider: ModelProvider, @unchecked Sendable {
    let id: ProviderID = "scripted"
    let displayName = "Scripted"
    let capabilities: ModelCapabilities = [.tools, .streaming]

    private let lock = NSLock()
    private var queue: [[ModelEvent]]
    private(set) var requests: [ModelRequest] = []

    init(responses: [[ModelEvent]]) { self.queue = responses }

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
}

/// Executor that counts invocations and returns a canned result.
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
