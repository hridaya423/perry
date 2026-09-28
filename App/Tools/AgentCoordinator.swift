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
    private let consent: ToolConsentStore
    private var loops: [UUID: AgentLoop] = [:]

    init(
        brain: BrainController,
        host: PerryToolHost,
        threads: ThreadStore,
        consent: ToolConsentStore
    ) {
        self.brain = brain
        self.host = host
        self.threads = threads
        self.consent = consent
    }

    /// Starts an agent turn for `goal` on `threadID` and streams its events.
    /// The finished turn (goal + final text + actuation labels) is appended to
    /// the thread automatically unless `persistTurn` is false — for callers
    /// that persist the turn themselves.
    func run(
        threadID: UUID,
        goal: String,
        perryID: String? = nil,
        persistTurn: Bool = true
    ) -> AsyncStream<AgentLoopEvent> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                await self?.execute(
                    threadID: threadID, goal: goal, perryID: perryID,
                    persistTurn: persistTurn, sink: continuation
                )
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

    func resume(threadID: UUID) {
        let loop = loops[threadID]
        Task { await loop?.resume() }
    }

    func stop(threadID: UUID) {
        let loop = loops[threadID]
        Task { await loop?.interrupt() }
    }

    private func execute(
        threadID: UUID,
        goal: String,
        perryID: String?,
        persistTurn: Bool,
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

        // Consent scope is the Perry the thread belongs to, not the thread —
        // "Always for this Perry" survives across the Perry's whole thread.
        // A caller-supplied perryID is stamped onto the thread so later turns
        // keep it; a stored binding wins over a caller's guess.
        var scope = perryID ?? threadID.uuidString
        if let stored = await threads.thread(id: threadID) {
            if let bound = stored.perryID {
                scope = bound
            } else if let perryID {
                var stamped = stored
                stamped.perryID = perryID
                _ = await threads.upsert(stamped)
            }
        }
        let context = ToolContext(
            surface: .agent,
            threadID: threadID.uuidString,
            approve: { call, spec in
                await ToolApprovalPresenter.present(
                    call: call, spec: spec, consentScope: scope, consentStore: self.consent
                )
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
        let system = AgentPrompt.system(workspacePath: Self.workspacePath)
        for await event in loop.run(system: system, messages: [.user([.text(goal)])], context: context) {
            sink.yield(event)
            switch event {
            case .textDelta(let delta):
                text += delta
            case .toolCallFinished(let result):
                if !result.isError, let label = Self.actuationLabel(result.content) {
                    actuationLabels.append(label)
                }
            case .finished:
                if persistTurn {
                    await threads.appendTurn(
                        to: threadID,
                        question: goal,
                        answer: text,
                        elementLabels: Array(actuationLabels.prefix(20))
                    )
                }
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

    /// Matches the root `LocalWorkspaceFiles` was given in AppController —
    /// AgentPrompt tells the model where files.* lives.
    static var workspacePath: String? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("Perry/workspace", isDirectory: true).path
    }
}
