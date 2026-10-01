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

    func testTextModelReceivesNoToolsAndCannotDispatchAnUnexpectedCall() async {
        let call = ToolCall(id: "unexpected", name: "files.write", arguments: .object([:]))
        let provider = ScriptedProvider(responses: [[.toolCall(call), .done(.toolUse)]], capabilities: [.streaming])
        let executor = RecordingExecutor(spec: ToolSpec(name: call.name, description: "write", inputSchema: toolSchema([:])))
        let loop = AgentLoop(provider: provider, host: PerryToolHost(executors: [executor]))
        let events = await collect(loop.run(system: "Perry", messages: [.user([.text("Hello")])], context: context))
        XCTAssertEqual(provider.requests.first?.tools, [])
        XCTAssertEqual(executor.callCount, 0)
        guard case .failed = finishReason(events) else { return XCTFail("An unavailable tool must fail without effects") }
    }

    func testToolsWithoutVisionKeepTextToolsAndRejectScreenActions() async {
        let read = RecordingExecutor(spec: ToolSpec(name: "files.read", description: "read", inputSchema: toolSchema([:])))
        let screen = RecordingExecutor(spec: ToolSpec(name: "ui.click", description: "click", inputSchema: toolSchema([:]), requiredCapabilities: [.tools, .vision]))
        let provider = ScriptedProvider(responses: [
            [.toolCall(ToolCall(id: "read", name: read.spec.name, arguments: .object([:]))), .done(.toolUse)],
            [.toolCall(ToolCall(id: "screen", name: screen.spec.name, arguments: .object([:]))), .done(.toolUse)]
        ])
        let loop = AgentLoop(provider: provider, host: PerryToolHost(executors: [read, screen]))
        let events = await collect(loop.run(system: "Perry", messages: [], context: context))
        XCTAssertEqual(provider.requests.first?.tools.map(\.name), [read.spec.name])
        XCTAssertEqual(read.callCount, 1)
        XCTAssertEqual(screen.callCount, 0)
        guard case .failed = finishReason(events) else { return XCTFail("Screen access must remain gated") }
    }

    func testImageContextNeverReachesTextOnlyModel() async {
        let provider = ScriptedProvider(responses: [[.textDelta("Answer"), .done(.endTurn)]], capabilities: [.streaming])
        let loop = AgentLoop(provider: provider, host: PerryToolHost(executors: []))
        let events = await collect(loop.run(system: "Perry", messages: [.user([.image(data: Data([1]), mimeType: "image/png")])], context: context))
        XCTAssertTrue(provider.requests.isEmpty)
        guard case .failed = finishReason(events) else { return XCTFail("Images require a capable model") }
    }

    func testNativeProviderCannotBypassCapabilityGate() async {
        let executor = RecordingExecutor(spec: ToolSpec(name: "files.write", description: "write", inputSchema: toolSchema([:])))
        let loop = AgentLoop(provider: UnexpectedNativeCallProvider(), host: PerryToolHost(executors: [executor]))
        let events = await collect(loop.run(system: "Perry", messages: [], context: context))
        XCTAssertEqual(executor.callCount, 0)
        guard case .failed = finishReason(events) else { return XCTFail("Native calls must use the same gate") }
    }

    func testIncompleteStreamsNeverCompleteOrDispatchTools() async {
        let call = ToolCall(id: "unfinished", name: "ui.click", arguments: .object([:]))
        let cases: [[ModelEvent]] = [
            [], [.textDelta("Partial answer")], [.toolCall(call)],
            [.toolCall(call), .done(.other("incomplete"))],
            [.done(.toolUse)], [.toolCall(call), .done(.endTurn)]
        ]
        for response in cases {
            let (loop, _, _, executor) = makeLoop([response])
            let events = await collect(loop.run(system: "Perry", messages: [], context: context))
            guard case .failed = finishReason(events) else {
                XCTFail("Incomplete response reported success: \(response)")
                continue
            }
            XCTAssertEqual(executor.callCount, 0)
        }
    }

    func testContextBudgetIncludesUnicodeToolsAndToolResults() async {
        let call = ToolCall(id: "read", name: "files.read", arguments: .object([:]))
        let executor = RecordingExecutor(spec: ToolSpec(name: "files.read", description: "Read fixture", inputSchema: toolSchema([:])))
        executor.body = { .text($0.id, String(repeating: "🪴", count: 2000)) }
        let provider = ScriptedProvider(responses: [
            [.toolCall(call), .done(.toolUse)], [.textDelta("Must not dispatch"), .done(.endTurn)]
        ], capacity: 4096)
        let loop = AgentLoop(provider: provider, host: PerryToolHost(executors: [executor]))
        let events = await collect(loop.run(system: "Read", messages: [.user([.text("Read the fixture")])], context: context))
        guard case .providerError = finishReason(events) else { return XCTFail("Expected context failure") }
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(provider.requests.first?.maxOutputTokens, 1024)
        XCTAssertEqual(executor.callCount, 1)

        let oversized = RecordingExecutor(spec: ToolSpec(name: "files.read", description: String(repeating: "x", count: 4000), inputSchema: toolSchema([:])))
        let unused = ScriptedProvider(responses: [[.done(.endTurn)]], capacity: 4096)
        let second = AgentLoop(provider: unused, host: PerryToolHost(executors: [oversized]))
        let rejected = await collect(second.run(system: "Read", messages: [], context: context))
        guard case .providerError = finishReason(rejected) else { return XCTFail("Tool schemas must count toward capacity") }
        XCTAssertTrue(unused.requests.isEmpty)
        XCTAssertEqual(oversized.callCount, 0)
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
            [.textDelta("Done"), .done(.endTurn)]
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
            [.textDelta("Done"), .done(.endTurn)]
        ])
        let executor = RecordingExecutor(spec: ToolSpec(name: "ui.click", description: "c", inputSchema: toolSchema([:])))
        let toolsRunning = expectation(description: "tool calls in flight")
        let lock = NSLock()
        var gates: [CheckedContinuation<Void, Never>] = []
        var gateOpen = false
        executor.body = { call in
            toolsRunning.fulfill()
            await withCheckedContinuation { gate in
                lock.withLock {
                    if gateOpen { gate.resume() } else { gates.append(gate) }
                }
            }
            return .text(call.id, "ok")
        }
        let host = PerryToolHost(executors: [executor])
        let loop = AgentLoop(provider: provider, host: host)
        let task = Task { await collect(loop.run(system: "s", messages: [], context: context)) }
        await fulfillment(of: [toolsRunning])
        await loop.pause()
        await loop.interrupt()
        lock.withLock {
            gateOpen = true
            gates.forEach { $0.resume() }
            gates.removeAll()
        }
        let events = await task.value
        XCTAssertEqual(finishReason(events), .interrupted)
    }

    func testFabricatedToolTranscriptFailsInsteadOfCompleting() async {
        let fabricated = """
            files.list("/tmp")
            [Observation: The folder contains 5 files.]
            Result: 5 files found.
            """
        let executor = RecordingExecutor(spec: ToolSpec(name: "files.list", description: "list", inputSchema: toolSchema([:])))
        let provider = ScriptedProvider(responses: [[.textDelta(fabricated), .done(.endTurn)]])
        let loop = AgentLoop(provider: provider, host: PerryToolHost(executors: [executor]))
        let events = await collect(loop.run(system: "s", messages: [], context: context))
        XCTAssertEqual(executor.callCount, 0)
        guard case .failed = finishReason(events) else {
            return XCTFail("A fake tool transcript must not record as completed")
        }
    }

    func testFabricatedCallSyntaxFailsEvenWithoutToolCapability() async {
        // A probed no-tools model still sees tool names in prior context and
        // can write fake calls — detection can't rely on allowedTools.
        let executor = RecordingExecutor(spec: ToolSpec(name: "files.list", description: "list", inputSchema: toolSchema([:])))
        let provider = ScriptedProvider(
            responses: [[.textDelta("files.list(\"/tmp\") — 5 files"), .done(.endTurn)]],
            capabilities: [.streaming]
        )
        let loop = AgentLoop(provider: provider, host: PerryToolHost(executors: [executor]))
        let events = await collect(loop.run(system: "s", messages: [], context: context))
        guard case .failed = finishReason(events) else {
            return XCTFail("A fabricated call must fail even when no tools were offered")
        }
    }

    func testFabricatedActionClaimFailsInsteadOfCompleting() async {
        // qwen-style narration: "**Action completed:** File X created" with
        // zero tool calls — a fabricated mutation claim, not a completion.
        let fabricated = """
            **Action completed:** File drill-proof.txt created in /tmp/workspace with content hello.
            """
        let executor = RecordingExecutor(spec: ToolSpec(name: "files.write", description: "write", inputSchema: toolSchema([:])))
        let provider = ScriptedProvider(responses: [[.textDelta(fabricated), .done(.endTurn)]])
        let loop = AgentLoop(provider: provider, host: PerryToolHost(executors: [executor]))
        let events = await collect(loop.run(system: "s", messages: [], context: context))
        XCTAssertEqual(executor.callCount, 0)
        guard case .failed = finishReason(events) else {
            return XCTFail("A fabricated action claim must not record as completed")
        }
    }

    func testFabricatedDenialClaimFailsInsteadOfCompleting() async {
        // Zero tools ran, so no approval card could ever have been shown —
        // "not approved" fabricates an approval decision that never happened.
        let executor = RecordingExecutor(spec: ToolSpec(name: "files.write", description: "write", inputSchema: toolSchema([:])))
        let provider = ScriptedProvider(responses: [[.textDelta("Action not completed: The file creation action was not approved."), .done(.endTurn)]])
        let loop = AgentLoop(provider: provider, host: PerryToolHost(executors: [executor]))
        let events = await collect(loop.run(system: "s", messages: [], context: context))
        XCTAssertEqual(executor.callCount, 0)
        guard case .failed = finishReason(events) else {
            return XCTFail("A fabricated approval-denial claim must not record as completed")
        }
    }

    func testUnattendedAwaitingApprovalFailsInsteadOfParking() async {
        // "Awaiting your approval" ends the turn waiting on a person who is
        // not there — the same dead end as a literal question.
        let executor = RecordingExecutor(spec: ToolSpec(name: "files.write", description: "write", inputSchema: toolSchema([:])))
        let provider = ScriptedProvider(responses: [[.textDelta("The change is ready and awaiting your approval."), .done(.endTurn)]])
        let loop = AgentLoop(provider: provider, host: PerryToolHost(executors: [executor]))
        let events = await collect(loop.run(system: "s", messages: [], context: ToolContext(surface: .agent, unattended: true)))
        guard case .failed = finishReason(events) else {
            return XCTFail("An approval wait on an unattended turn must fail")
        }
    }

    func testAttendedAwaitingApprovalStillCompletes() async {
        let executor = RecordingExecutor(spec: ToolSpec(name: "files.write", description: "write", inputSchema: toolSchema([:])))
        let provider = ScriptedProvider(responses: [[.textDelta("The change is ready and awaiting your approval."), .done(.endTurn)]])
        let loop = AgentLoop(provider: provider, host: PerryToolHost(executors: [executor]))
        let events = await collect(loop.run(system: "s", messages: [], context: context))
        XCTAssertEqual(finishReason(events), .completed)
    }

    func testUnattendedQuestionTurnFailsInsteadOfParking() async {
        // Scheduled Perrys have no one to answer "Do you want to proceed?" —
        // recording completed would park the job and poison future context.
        let executor = RecordingExecutor(spec: ToolSpec(name: "files.write", description: "write", inputSchema: toolSchema([:])))
        let provider = ScriptedProvider(responses: [[.textDelta("Please confirm the following action: Create drill.txt. Do you want to proceed?"), .done(.endTurn)]])
        let loop = AgentLoop(provider: provider, host: PerryToolHost(executors: [executor]))
        let events = await collect(loop.run(system: "s", messages: [], context: ToolContext(surface: .agent, unattended: true)))
        guard case .failed = finishReason(events) else {
            return XCTFail("An unanswerable question on an unattended turn must fail")
        }
    }

    func testAttendedQuestionTurnStillCompletes() async {
        let executor = RecordingExecutor(spec: ToolSpec(name: "files.write", description: "write", inputSchema: toolSchema([:])))
        let provider = ScriptedProvider(responses: [[.textDelta("Which folder should I use?"), .done(.endTurn)]])
        let loop = AgentLoop(provider: provider, host: PerryToolHost(executors: [executor]))
        let events = await collect(loop.run(system: "s", messages: [], context: context))
        XCTAssertEqual(finishReason(events), .completed)
    }

    func testPlainAnswerWithoutActionClaimsStillCompletes() async {
        let executor = RecordingExecutor(spec: ToolSpec(name: "files.list", description: "list", inputSchema: toolSchema([:])))
        let provider = ScriptedProvider(responses: [[.textDelta("The workspace listing is empty — nothing was found."), .done(.endTurn)]])
        let loop = AgentLoop(provider: provider, host: PerryToolHost(executors: [executor]))
        let events = await collect(loop.run(system: "s", messages: [], context: context))
        XCTAssertEqual(finishReason(events), .completed)
    }

    func testToolNameMentionAfterRealCallsStillCompletes() async {
        let call = ToolCall(id: "t1", name: "ui.click", arguments: .object([:]))
        let (loop, _, _, executor) = makeLoop([
            [.toolCall(call), .done(.toolUse)],
            [.textDelta("ui.click ran fine."), .done(.endTurn)],
        ])
        let events = await collect(loop.run(system: "s", messages: [], context: context))
        XCTAssertEqual(executor.callCount, 1)
        XCTAssertEqual(finishReason(events), .completed)
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

private struct UnexpectedNativeCallProvider: ToolExecutingModelProvider {
    let id: ProviderID = "native-test"
    let displayName = "Native test"
    let capabilities: ModelCapabilities = [.streaming]
    func warm() async {}
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func stream(_ request: ModelRequest, executeTool: @escaping ToolExecutionHandler) -> AsyncThrowingStream<ModelEvent, Error> {
        BrainHTTP.eventStream { continuation in
            _ = try await executeTool(ToolCall(id: "unexpected", name: "files.write", arguments: .object([:])))
            continuation.yield(.done(.endTurn))
        }
    }
}
