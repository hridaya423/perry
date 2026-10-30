import Foundation
@testable import PerryBrain
import XCTest

struct TestTimeout: Error {}

func withTimeout<T: Sendable>(
    _ seconds: Double = 15,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let gate = ResumeOnce<T>()
    return try await withCheckedThrowingContinuation { continuation in
        gate.set(continuation)
        let work = Task {
            do { gate.resume(.success(try await operation())) } catch { gate.resume(.failure(error)) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            work.cancel()
            gate.resume(.failure(TestTimeout()))
        }
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    func set(_ c: CheckedContinuation<T, Error>) { lock.withLock { continuation = c } }
    func resume(_ result: Result<T, Error>) {
        let c = lock.withLock { () -> CheckedContinuation<T, Error>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume(with: result)
    }
}

func drain(_ stream: AsyncThrowingStream<ModelEvent, Error>) async throws -> [ModelEvent] {
    var events: [ModelEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

func text(_ events: [ModelEvent]) -> String {
    events.compactMap { if case .textDelta(let t) = $0 { return t }; return nil }.joined()
}

func toolCalls(_ events: [ModelEvent]) -> [ToolCall] {
    events.compactMap { if case .toolCall(let c) = $0 { return c }; return nil }
}

func stopReason(_ events: [ModelEvent]) -> ModelStopReason? {
    events.compactMap { if case .done(let r) = $0 { return r }; return nil }.last
}

let sampleTool = ToolSpec(
    name: "get_weather",
    description: "Look up weather",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object(["city": .object(["type": .string("string")])]),
    ])
)

func sampleRequest(tools: [ToolSpec] = []) -> ModelRequest {
    ModelRequest(system: "system prompt", messages: [.user([.text("hi")])], tools: tools, tier: .fast)
}
