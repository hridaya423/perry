import AppKit
import Foundation
import PerryBrain

/// Phase 7: runs agent turns through `AgentLoop` against the app's tool host.
/// One loop per thread; steer/pause/stop target the loop. Approvals go through
/// the intent card with per-thread "Always allow" consent; red-tier calls
/// always require the card's typed confirmation. When a turn finishes, the
/// goal + accumulated answer land in the thread store.
@MainActor
final class AgentCoordinator: ObservableObject {
    @Published private(set) var runningThreads: Set<UUID> = []

    private let brain: BrainController
    private let host: PerryToolHost
    private let threads: ThreadStore
    private let consent: AgentConsentStore
    private var loops: [UUID: AgentLoop] = [:]

    init(
        brain: BrainController,
        host: PerryToolHost,
        threads: ThreadStore,
        consent: AgentConsentStore = .shared
    ) {
        self.brain = brain
        self.host = host
        self.threads = threads
        self.consent = consent
    }

    /// Starts an agent turn for `goal` on `threadID` and streams its events.
    /// The finished turn (goal + final text + actuation labels) is appended to
    /// the thread automatically.
    func run(threadID: UUID, goal: String, perryID: String? = nil) -> AsyncStream<AgentLoopEvent> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                await self?.execute(threadID: threadID, goal: goal, perryID: perryID, sink: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func steer(_ text: String, threadID: UUID) {
        let loop = loops[threadID]
        Task { await loop?.steer(text) }
    }

    func pause(threadID: UUID) {
        let loop = loops[threadID]
        Task { await loop?.pause() }
    }

    func stop(threadID: UUID) {
        let loop = loops[threadID]
        Task { await loop?.interrupt() }
    }

    private func execute(
        threadID: UUID,
        goal: String,
        perryID: String?,
        sink: AsyncStream<AgentLoopEvent>.Continuation
    ) async {
        guard !Task.isCancelled else { sink.finish(); return }
        let provider: any ModelProvider
        do {
            provider = try await brain.route(RouteRequirement(capabilities: [.tools, .vision], tier: .deep)).provider
        } catch {
            sink.yield(.finished(.providerError(error.localizedDescription)))
            sink.finish()
            return
        }

        let scope = perryID ?? threadID.uuidString
        let context = ToolContext(
            surface: .agent,
            threadID: threadID.uuidString,
            approve: { call, spec in
                await ToolApprovalPresenter.present(call: call, spec: spec, consentScope: scope)
            }
        )
        let loop = AgentLoop(provider: provider, host: host)
        loops[threadID] = loop
        runningThreads.insert(threadID)
        defer {
            loops[threadID] = nil
            runningThreads.remove(threadID)
        }

        var text = ""
        var actuationLabels: [String] = []
        for await event in loop.run(system: Self.systemPrompt, messages: [.user([.text(goal)])], context: context) {
            sink.yield(event)
            switch event {
            case .textDelta(let delta):
                text += delta
            case .toolCallFinished(let result):
                if !result.isError, let label = Self.actuationLabel(result.content) {
                    actuationLabels.append(label)
                }
            case .finished:
                await threads.appendTurn(
                    to: threadID,
                    question: goal,
                    answer: text,
                    elementLabels: Array(actuationLabels.prefix(20))
                )
            case .toolCallStarted, .note:
                break
            }
        }
    }

    /// A tool result's first text line — e.g. "clicked Save" — for the thread's
    /// element-label trail. Non-text content is skipped.
    private static func actuationLabel(_ content: [ModelContentPart]) -> String? {
        content.compactMap { part -> String? in
            if case .text(let text) = part { return text.components(separatedBy: .newlines).first }
            return nil
        }.first
    }

    private static let systemPrompt = """
        You are Perry, acting on the user's Mac. Work in observe-act-verify \
        cycles: call screen.observe to see the current UI, act with ui.* tools, \
        then observe again to confirm. Refer to elements by their compact id or \
        label from the latest observation. Keep replies short — one or two \
        sentences of narration between actions. If a step needs something you \
        cannot see or reach, say so plainly and stop.
        """
}
