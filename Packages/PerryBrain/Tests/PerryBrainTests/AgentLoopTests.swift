import XCTest
import PerryCore
@testable import PerryBrain

final class AgentLoopTests: XCTestCase {
    private let context = ToolContext(surface: .agent)

    private func makeLoop(_ responses: [[ModelEvent]], budgets: AgentLoop.Budgets = .init())
        -> (AgentLoop, ScriptedProvider, PerryToolHost, RecordingExecutor) {
        let provider = ScriptedProvider(responses: responses)
        let executor = RecordingExecutor(spec: ToolSpec(
            name: "ui.click", description: "click", inputSchema: toolSchema([:])
        ))
        let host = PerryToolHost(executors: [executor])
        return (AgentLoop(provider: provider, host: host, budgets: budgets), provider, host, executor)
    }

    private func collect(_ stream: AsyncStream<AgentLoopEvent>) async -> [AgentLoopEvent] {
        var events: [AgentLoopEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func finishReason(_ events: [AgentLoopEvent]) -> AgentFinish? {
        events.compactMap { if case .finished(let f) = $0 { return f }; return nil }.last
    }

    func testTextOnlyTurn() async {
        let (loop, provider, _, _) = makeLoop([[.textDelta("Hello"), .textDelta(" there"), .done(.endTurn)]])
        let events = await collect(loop.run(system: "s", messages: [], context: context))
        XCTAssertEqual(finishReason(events), .completed)
        XCTAssertEqual(provider.requests.count, 1)
    }

    func testToolCallRoundTrip() async {
        let call = ToolCall(id: "t1", name: "ui.click", arguments: .object([:]))
        let (loop, provider, _, executor) = makeLoop([
            [.textDelta("Clicking."), .toolCall(call), .done(.toolUse)],
            [.textDelta("Done."), .done(.endTurn)],
        ])
        let events = await collect(loop.run(system: "s", messages: [.user([.text("go")])], context: context))
        XCTAssertEqual(finishReason(events), .completed)
        XCTAssertEqual(executor.callCount, 1)
        XCTAssertEqual(provider.requests.count, 2)
        // Second request must carry the assistant turn + tool result.
        let second = provider.requests[1].messages
        XCTAssertTrue(second.contains(.assistant(text: "Clicking.", toolCalls: [call])))
        XCTAssertTrue(second.contains(.toolResult(callID: "t1", content: [.text("ok")], isError: false)))
    }

    func testSteerInjectedAtBoundary() async {
        let call = ToolCall(id: "t1", name: "ui.click", arguments: .object([:]))
        let provider = ScriptedProvider(responses: [
            [.toolCall(call), .done(.toolUse)],
            [.textDelta("ok"), .done(.endTurn)],
        ])
        let executor = RecordingExecutor(spec: ToolSpec(name: "ui.click", description: "c", inputSchema: toolSchema([:])))
        executor.body = { call in
            try? await Task.sleep(nanoseconds: 80_000_000)
            return .text(call.id, "ok")
        }
        let host = PerryToolHost(executors: [executor])
        let loop = AgentLoop(provider: provider, host: host)
        let stream = loop.run(system: "s", messages: [], context: context)
        let task = Task { await collect(stream) }
        // The tool is still running; the steer is drained before the next provider round.
        try? await Task.sleep(nanoseconds: 20_000_000)
        await loop.steer("also add pricing")
        let events = await task.value
        XCTAssertEqual(finishReason(events), .completed)
        XCTAssertTrue(provider.requests[1].messages.contains(.user([.text("also add pricing")])))
    }

    func testInterrupt() async {
        let provider = ScriptedProvider(responses: [])
        let host = PerryToolHost(executors: [])
        let loop = AgentLoop(provider: provider, host: host)
        // Provider emits a slow trickle so interrupt lands mid-stream.
        let slow = AsyncThrowingStream<ModelEvent, Error> { continuation in
            Task {
                continuation.yield(.textDelta("one"))
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                continuation.finish()
            }
        }
        _ = slow
        let stream = loop.run(system: "s", messages: [], context: context)
        let task = Task { await collect(stream) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await loop.interrupt()
        let events = await task.value
        // Empty scripted queue finishes instantly; interrupt must not hang.
        XCTAssertEqual(finishReason(events), .completed)
    }

    func testInterruptDuringToolCalls() async {
        let call = ToolCall(id: "t1", name: "ui.click", arguments: .object([:]))
        // Provider keeps issuing the same call forever; interrupt must stop the loop.
        var queue: [[ModelEvent]] = []
        for _ in 0..<100 { queue.append([.toolCall(call), .done(.toolUse)]) }
        let provider = ScriptedProvider(responses: queue)
        let executor = RecordingExecutor(spec: ToolSpec(name: "ui.click", description: "c", inputSchema: toolSchema([:])))
        executor.body = { call in
            try? await Task.sleep(nanoseconds: 5_000_000)
            return .text(call.id, "ok")
        }
        let host = PerryToolHost(executors: [executor])
        let loop = AgentLoop(provider: provider, host: host, budgets: .init(maxToolCalls: 90))
        let task = Task { await collect(loop.run(system: "s", messages: [], context: context)) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await loop.interrupt()
        let events = await task.value
        XCTAssertEqual(finishReason(events), .interrupted)
    }

    func testToolCallBudget() async {
        let call = ToolCall(id: "t1", name: "ui.click", arguments: .object([:]))
        var queue: [[ModelEvent]] = []
        for _ in 0..<10 { queue.append([.toolCall(call), .done(.toolUse)]) }
        let (loop, _, _, _) = makeLoop(queue, budgets: .init(maxToolCalls: 2))
        let events = await collect(loop.run(system: "s", messages: [], context: context))
        XCTAssertEqual(finishReason(events), .budgetToolCalls)
    }

    func testPauseHoldsAtBoundaryUntilResumed() async {
        let call = ToolCall(id: "t1", name: "ui.click", arguments: .object([:]))
        let provider = ScriptedProvider(responses: [
            [.toolCall(call), .toolCall(call), .done(.toolUse)],
        ])
        let executor = RecordingExecutor(spec: ToolSpec(name: "ui.click", description: "c", inputSchema: toolSchema([:])))
        executor.body = { call in
            try? await Task.sleep(nanoseconds: 10_000_000)
            return .text(call.id, "ok")
        }
        let host = PerryToolHost(executors: [executor])
        let loop = AgentLoop(provider: provider, host: host)
        let task = Task { await collect(loop.run(system: "s", messages: [], context: context)) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await loop.pause()
        // Suspended, not finished: give the loop a moment, then resume —
        // the run must complete the second call rather than end paused.
        try? await Task.sleep(nanoseconds: 50_000_000)
        await loop.resume()
        let events = await task.value
        XCTAssertEqual(finishReason(events), .completed)
        XCTAssertTrue(events.contains { if case .note(let s) = $0 { return s.hasPrefix("paused after") } ; return false })
        XCTAssertEqual(executor.callCount, 2)
    }

    func testInterruptWhilePausedFinishesInterrupted() async {
        let call = ToolCall(id: "t1", name: "ui.click", arguments: .object([:]))
        let provider = ScriptedProvider(responses: [
            [.toolCall(call), .toolCall(call), .done(.toolUse)],
        ])
        let executor = RecordingExecutor(spec: ToolSpec(name: "ui.click", description: "c", inputSchema: toolSchema([:])))
        executor.body = { call in
            try? await Task.sleep(nanoseconds: 10_000_000)
            return .text(call.id, "ok")
        }
        let host = PerryToolHost(executors: [executor])
        let loop = AgentLoop(provider: provider, host: host)
        let task = Task { await collect(loop.run(system: "s", messages: [], context: context)) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await loop.pause()
        try? await Task.sleep(nanoseconds: 50_000_000)
        await loop.interrupt()
        let events = await task.value
        XCTAssertEqual(finishReason(events), .interrupted)
    }

    func testProviderErrorFinishesCleanly() async {
        final class Failing: ModelProvider, @unchecked Sendable {
            let id: ProviderID = "failing"; let displayName = "F"; let capabilities: ModelCapabilities = []
            func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
                AsyncThrowingStream { $0.finish(throwing: ModelProviderError(kind: .network, provider: "failing", message: "offline")) }
            }
            func warm() async {}
        }
        let loop = AgentLoop(provider: Failing(), host: PerryToolHost(executors: []))
        let events = await collect(loop.run(system: "s", messages: [], context: context))
        guard case .providerError = finishReason(events) else {
            return XCTFail("expected providerError, got \(String(describing: finishReason(events)))")
        }
    }
}
