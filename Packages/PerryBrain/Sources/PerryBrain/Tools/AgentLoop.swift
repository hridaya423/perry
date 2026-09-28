import Foundation
import PerryCore

public enum AgentFinish: Sendable, Equatable {
    case completed, interrupted, paused, budgetToolCalls, budgetTime, providerError(String)
}

public enum AgentLoopEvent: Sendable, Equatable {
    case textDelta(String)
    case toolCallStarted(ToolCall)
    case toolCallFinished(ToolResult)
    case note(String)
    case finished(AgentFinish)
}

/// Provider-agnostic agent turn loop: stream → tool calls → host → results →
/// repeat, with steer/pause/interrupt and budgets (60 calls, 20 min).
public actor AgentLoop {
    public struct Budgets: Sendable {
        public var maxToolCalls: Int
        public var wallClock: TimeInterval
        public init(maxToolCalls: Int = 60, wallClock: TimeInterval = 1200) {
            self.maxToolCalls = maxToolCalls
            self.wallClock = wallClock
        }
    }

    private let provider: any ModelProvider
    private let host: PerryToolHost
    private let budgets: Budgets

    private var steerQueue: [String] = []
    private var pauseRequested = false
    private var loopTask: Task<Void, Never>?

    public init(provider: any ModelProvider, host: PerryToolHost, budgets: Budgets = .init()) {
        self.provider = provider
        self.host = host
        self.budgets = budgets
    }

    public func steer(_ text: String) { steerQueue.append(text) }
    /// Yields at the next tool boundary and holds there until `resume()`
    /// or `interrupt()` — the run's message history is preserved.
    public func pause() { pauseRequested = true }
    public func resume() { pauseRequested = false }
    public func interrupt() {
        pauseRequested = false
        steerQueue.removeAll()
        loopTask?.cancel()
    }

    public nonisolated func run(
        system: String,
        messages: [ModelMessage],
        context: ToolContext,
        tier: ModelTier = .deep
    ) -> AsyncStream<AgentLoopEvent> {
        AsyncStream { continuation in
            let task = Task { await self.loop(system: system, messages: messages, context: context, tier: tier, sink: continuation) }
            Task { await self.attach(task) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func attach(_ task: Task<Void, Never>) { loopTask = task }

    private func loop(
        system: String,
        messages: [ModelMessage],
        context: ToolContext,
        tier: ModelTier,
        sink: AsyncStream<AgentLoopEvent>.Continuation
    ) async {
        var messages = messages
        let deadline = Date().addingTimeInterval(budgets.wallClock)
        var toolCallCount = 0
        let tools = host.specs(for: context.surface)

        func finish(_ reason: AgentFinish) {
            sink.yield(.finished(reason))
            sink.finish()
        }

        while true {
            if Task.isCancelled { finish(.interrupted); return }
            let steers = drainSteers()
            for steer in steers {
                messages.append(.user([.text(steer)]))
                sink.yield(.note("steer: \(steer)"))
            }
            if pauseRequested {
                sink.yield(.note("paused after \(toolCallCount) tool calls"))
                await suspendUntilResumed()
                if Task.isCancelled { finish(.interrupted); return }
                sink.yield(.note("resumed"))
            }
            if Date() > deadline { finish(.budgetTime); return }

            var text = ""
            var calls: [ToolCall] = []
            do {
                let stream = provider.stream(ModelRequest(
                    system: system, messages: messages, tools: tools, tier: tier
                ))
                for try await event in stream {
                    if Task.isCancelled { finish(.interrupted); return }
                    switch event {
                    case .textDelta(let delta): text += delta; sink.yield(.textDelta(delta))
                    case .toolCall(let call): calls.append(call)
                    case .usage, .done: break
                    }
                }
            } catch {
                finish(.providerError(error.localizedDescription))
                return
            }

            if calls.isEmpty { finish(.completed); return }
            messages.append(.assistant(text: text, toolCalls: calls))

            for call in calls {
                if Task.isCancelled { finish(.interrupted); return }
                if pauseRequested {
                    sink.yield(.note("paused after \(toolCallCount) tool calls"))
                    await suspendUntilResumed()
                    if Task.isCancelled { finish(.interrupted); return }
                    sink.yield(.note("resumed"))
                }
                toolCallCount += 1
                if toolCallCount > budgets.maxToolCalls { finish(.budgetToolCalls); return }
                sink.yield(.toolCallStarted(call))
                let result = await host.handle(call, context: context)
                sink.yield(.toolCallFinished(result))
                messages.append(.toolResult(callID: result.callID, content: result.content, isError: result.isError))
            }
        }
    }

    /// Holds at a tool boundary until resumed or interrupted. Steers queued
    /// while paused are delivered to the model on the next loop iteration.
    private func suspendUntilResumed() async {
        while pauseRequested, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func drainSteers() -> [String] {
        let steers = steerQueue
        steerQueue.removeAll()
        return steers
    }
}
