import Foundation
import PerryCore

public enum AgentFinish: Sendable, Equatable {
    case completed, interrupted, paused, budgetToolCalls, budgetTime, providerError(String), failed(String)
}

public enum AgentLoopEvent: Sendable, Equatable {
    case textDelta(String)
    case draw(DrawCommand)
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
    private var toolCallCount = 0
    private var answerTail: Character?
    private var toolCallsAtLastText = 0

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

    private func request(system: String, messages: [ModelMessage], context: ToolContext, tier: ModelTier) -> ModelRequest {
        let tools = host.specs(for: context.surface).filter { provider.capabilities.isSuperset(of: $0.requiredCapabilities) }
        return ModelRequest(system: system, messages: messages, tools: tools, tier: tier, conversationKey: context.threadID)
    }

    public func prepareConversation(
        thread: PerryThread, question: String, runID: UUID, store: ThreadStore,
        system: String, context: ToolContext, tier: ModelTier, currentParts: [ModelContentPart]
    ) async throws -> PreparedConversation {
        let base = request(system: system, messages: [.user(currentParts)], context: context, tier: tier)
        return try await ConversationContext().prepareDeferringSummary(
            thread: thread, question: question, runID: runID, store: store, provider: provider, baseRequest: base
        )
    }

    private func loop(
        system: String,
        messages: [ModelMessage],
        context: ToolContext,
        tier: ModelTier,
        sink: AsyncStream<AgentLoopEvent>.Continuation
    ) async {
        var messages = messages
        let deadline = Date().addingTimeInterval(budgets.wallClock)
        toolCallCount = 0
        answerTail = nil
        toolCallsAtLastText = 0
        let base = request(system: system, messages: messages, context: context, tier: tier)
        let tools = base.tools
        let system = base.system
        let allowedTools = Set(tools.map(\.name))
        /// Fabrication detection runs against every tool on the surface, not
        /// just the ones this provider may call — a no-tools model can still
        /// write `files.list(…)` claims into its answer.
        let surfaceToolNames = Set(host.specs(for: context.surface).map(\.name))

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
            var stopReason: ModelStopReason?
            if !provider.capabilities.contains(.vision), messages.contains(where: { message in
                switch message {
                case .user(let parts), .toolResult(_, let parts, _):
                    return parts.contains { if case .image = $0 { return true }; return false }
                case .assistant: return false
                }
            }) {
                finish(.failed("This conversation contains an image the selected model cannot read. Choose an image-capable model in Settings."))
                return
            }
            do {
                let capacity = try await provider.contextWindow(for: tier)
                try Task.checkCancellation()
                let request = try ModelRequest(system: system, messages: Self.trimmingStaleObservations(messages), tools: tools, tier: tier, conversationKey: context.threadID).reservingOutput(in: capacity)
                let stream = provider.stream(request) { call in
                    try await self.executeTool(call, context: context, allowedTools: allowedTools, deadline: deadline, sink: sink)
                }
                for try await event in stream {
                    if Task.isCancelled { finish(.interrupted); return }
                    switch event {
                    case .textDelta(let delta):
                        text += delta
                        sink.yield(.textDelta(separated(delta)))
                    case .toolCall(let call):
                        if !provider.executesTools { calls.append(call) }
                    case .done(.cancelled): finish(.interrupted); return
                    case .done(.maxTokens): finish(.failed("The answer reached the model’s output limit.")); return
                    case .done(let reason): stopReason = reason
                    case .usage: break
                    }
                }
            } catch let stopped as ToolExecutionStopped {
                finish(stopped.reason)
                return
            } catch is CancellationError {
                finish(.interrupted)
                return
            } catch let error as ModelProviderError {
                finish(.providerError(Self.describe(error)))
                return
            } catch {
                finish(.providerError(error.localizedDescription))
                return
            }

            if Task.isCancelled { finish(.interrupted); return }
            guard stopReason == (calls.isEmpty ? .endTurn : .toolUse) else {
                finish(.failed("The model stopped before completing its response. Review any earlier changes before retrying."))
                return
            }
            if calls.isEmpty {
                if toolCallCount == 0 {
                    if Self.looksFabricatedToolTranscript(text, toolNames: surfaceToolNames) {
                        finish(.failed("The answer describes actions Perry did not run, so nothing happened. Try again, or choose a different model in Settings."))
                        return
                    }
                    if context.unattended, Self.looksLikeUserQuestion(text) {
                        finish(.failed("This Perry asked for confirmation during a scheduled run, and nobody was there to answer. Rewrite its job so it can act on its own, or choose a model that can use tools in Settings."))
                        return
                    }
                }
                finish(.completed)
                return
            }
            messages.append(.assistant(text: text, toolCalls: calls))

            for call in calls {
                do {
                    let result = try await executeTool(call, context: context, allowedTools: allowedTools, deadline: deadline, sink: sink)
                    messages.append(.toolResult(callID: result.callID, content: result.content, isError: result.isError))
                } catch let stopped as ToolExecutionStopped {
                    finish(stopped.reason)
                    return
                } catch {
                    finish(.interrupted)
                    return
                }
            }
        }
    }

    static func trimmingStaleObservations(_ messages: [ModelMessage], keeping kept: Int = 2) -> [ModelMessage] {
        let observed = messages.indices.filter { index in
            guard case .toolResult(_, let content, _) = messages[index] else { return false }
            return content.contains { if case .image = $0 { true } else { false } }
        }
        var trimmed = messages
        for index in observed.dropLast(kept) {
            guard case .toolResult(let callID, let content, let isError) = messages[index] else { continue }
            let text = content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
            let head = text.count > 400 ? "\(text.prefix(400))…" : text
            trimmed[index] = .toolResult(callID: callID, content: [.text("\(head)\n[Older screen removed to save space. Its element ids are stale.]")], isError: isError)
        }
        return trimmed
    }

    /// Some models write a fake transcript into the answer — `files.list("…")`
    /// or `[Observation: …]` — instead of emitting a real tool call. Others
    /// narrate a completed action in prose ("Action completed", "file X
    /// created") with no call at all. When no call ran in the whole turn,
    /// those claims are fabricated.
    static func looksFabricatedToolTranscript(_ text: String, toolNames: Set<String>) -> Bool {
        if text.range(of: #"(?m)^\s*\[(Observation|Action)\s*:"#, options: .regularExpression) != nil {
            return true
        }
        // [Files.list] / [UI.action] — a line that is only a bracketed dotted label.
        if text.range(of: #"(?im)^\s*\[\s*[A-Za-z]+\.[A-Za-z]+\s*\]\s*$"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"(?i)\baction (was |is )?(not )?(completed|done|approved|denied|declined)\b"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"(?i)\bapproval (was |is )?(not )?(given|granted|denied|declined)\b|\b(not|wasn'?t) approved\b"#, options: .regularExpression) != nil {
            return true
        }
        let claimPattern = #"(?i)\b(created|wrote|written|saved|deleted|renamed|moved|copied|sent)\b[^.\n]{0,40}\b(file|folder|document|note|message|email|task)\b|\b(files?|folders?|documents?|notes?)\s+(\S+\s+)?(was\s+|were\s+|are\s+|has been\s+|have been\s+|now\s+)?(created|written|saved|deleted|renamed|moved|copied|sent)\b|\b(each|every|all|both|these|those|\d+)\s+files?\s+(now\s+)?(contain|hold|include)s?\b"#
        if text.range(of: claimPattern, options: .regularExpression) != nil {
            return true
        }
        for name in toolNames where name.contains(".") {
            let lineStart = "(?im)^\\s*(?:[-*•]\\s*)?" + NSRegularExpression.escapedPattern(for: name) + "\\b"
            if text.range(of: lineStart, options: .regularExpression) != nil { return true }
            let callSyntax = "(?i)" + NSRegularExpression.escapedPattern(for: name) + "\\s*\\("
            if text.range(of: callSyntax, options: .regularExpression) != nil { return true }
        }
        return false
    }

    /// A trailing question to the user ("Do you want to proceed?", "Which
    /// folder should I use?") can never be answered on an unattended turn.
    static func looksLikeUserQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { return true }
        return trimmed.range(
            of: #"(?i)\b(do you want (me )?to|please confirm|shall i|would you like me to|let me know if|awaiting (your )?(approval|confirmation|input|response)|waiting for (your )?(approval|confirmation|input|response|reply))\b"#,
            options: .regularExpression
        ) != nil
    }

    private struct ToolExecutionStopped: Error {
        let reason: AgentFinish
    }

    private func executeTool(
        _ call: ToolCall,
        context: ToolContext,
        allowedTools: Set<String>,
        deadline: Date,
        sink: AsyncStream<AgentLoopEvent>.Continuation
    ) async throws -> ToolResult {
        try Task.checkCancellation()
        guard allowedTools.contains(call.name) else {
            throw ToolExecutionStopped(reason: .failed("The model requested an action unavailable in this conversation. That action was not run. Review earlier results, then choose a model with the required capabilities in Settings."))
        }
        if pauseRequested {
            sink.yield(.note("paused after \(toolCallCount) tool calls"))
            await suspendUntilResumed()
            try Task.checkCancellation()
            sink.yield(.note("resumed"))
        }
        if Date() > deadline { throw ToolExecutionStopped(reason: .budgetTime) }
        guard toolCallCount < budgets.maxToolCalls else { throw ToolExecutionStopped(reason: .budgetToolCalls) }
        toolCallCount += 1
        sink.yield(.toolCallStarted(call))
        let result = await host.handle(call, context: context)
        sink.yield(.toolCallFinished(result))
        try Task.checkCancellation()
        return result
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

    /// User-facing failure text — a rate limit names its reset time so the
    /// voice line and status card both carry it, not a bare "429".
    private func separated(_ delta: String) -> String {
        guard let first = delta.first, let last = delta.last else { return delta }
        let afterTool = toolCallCount > toolCallsAtLastText && answerTail.map { !$0.isNewline } == true && !first.isNewline
        toolCallsAtLastText = toolCallCount
        answerTail = last
        return afterTool ? "\n\n" + delta : delta
    }

    public static func describe(_ error: ModelProviderError) -> String {
        let name = error.provider.displayName
        switch error.kind {
        case .rateLimited(let resetAt):
            let reset = resetAt.map { " until \(Self.timeFormatter.string(from: $0))" } ?? ""
            return "\(name) is out of requests\(reset). Try again later, or choose another brain in Settings > Brain."
        case .unauthenticated where error.provider == .codex:
            return "\(name) isn’t signed in. Connect it in Settings > Brain."
        case .unauthenticated:
            return "\(name) didn’t accept your key. Check it in Settings > Brain."
        case .network:
            return "I can’t reach \(name). Check your internet connection."
        case .http(let status) where status >= 500:
            return "\(name) had a server problem (error \(status)). Try again in a moment."
        case .http(let status):
            return "\(name) turned this request down (error \(status)). Try again, or choose another brain in Settings > Brain."
        default:
            return error.localizedDescription
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}
