import Foundation
import PerryBrain
import PerryCore
import PerryGuide
import PerryRuntimes

struct GuideFinalizationRequest {
    let id: UUID
    let goal: String
    let startedAt: Date
    let steps: [String]
    let outcome: TranscriptEntry.Outcome
    let summary: String
    let appBundleID: String?

    var transcriptEntry: TranscriptEntry {
        TranscriptEntry(
            id: id,
            sessionID: id,
            request: goal,
            appBundleID: appBundleID,
            summary: summary,
            outcome: outcome,
            startedAt: startedAt,
            finishedAt: Date(),
            steps: steps,
            verified: nil
        )
    }

    var workflowMemory: MemoryRecord? {
        guard outcome == .completed, !steps.isEmpty else { return nil }
        return MemoryRecord(
            category: .appWorkflow,
            appBundleID: appBundleID,
            summary: "\(goal): \(steps.joined(separator: " → "))"
        )
    }

    var agentFinish: AgentFinish {
        switch outcome {
        case .completed: .completed
        case .stopped: .interrupted
        case .failed: .failed(summary)
        }
    }
}

extension GuideFinalizationRequest {
    init(guide: GuideSessionState, outcome: TranscriptEntry.Outcome, summary: String) {
        self.init(
            id: guide.id, goal: guide.goal, startedAt: guide.startedAt, steps: guide.steps,
            outcome: outcome, summary: summary, appBundleID: guide.appBundleID
        )
    }
}

@MainActor
final class GuideWorkerSession {
    enum Slot {
        case action, repoint, finish, presentation
    }

    let id: UUID
    let targetStore = ScreenGuideTargetStore()
    let finishStream: AsyncStream<Void>
    let finishContinuation: AsyncStream<Void>.Continuation
    private(set) var engine: GuideEngine?
    var scopeTask: Task<Void, Never>?
    var finalizationTask: Task<Void, Never>?
    var conversationOutcome: (answer: String, finish: AgentFinish)?
    var savedOutcome: AgentFinish?
    var takeoverRequested = false
    var workerBodyActive = false
    var isFinished = false
    var pendingFinalization: GuideFinalizationRequest?
    private(set) var finalizationSuppressed = false
    private var admissionOpen = true
    private var tasks: [Slot: (token: UUID, task: Task<Void, Never>)] = [:]

    init(id: UUID) {
        let finish = AsyncStream<Void>.makeStream()
        self.id = id
        finishStream = finish.stream
        finishContinuation = finish.continuation
    }

    func bind(engine: GuideEngine) {
        self.engine = engine
    }

    func suppressFinalization() {
        finalizationSuppressed = true
        pendingFinalization = nil
    }

    func requestFinalization(_ request: GuideFinalizationRequest) {
        guard pendingFinalization == nil, finalizationTask == nil else { return }
        pendingFinalization = request
    }

    func takePendingFinalization() -> GuideFinalizationRequest? {
        guard finalizationTask == nil else { return nil }
        defer { pendingFinalization = nil }
        return finalizationSuppressed ? nil : pendingFinalization
    }

    func start(_ slot: Slot, _ body: @escaping @MainActor () async -> Void) {
        guard admissionOpen else { return }
        tasks[slot]?.task.cancel()
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            if !Task.isCancelled { await body() }
            if self?.tasks[slot]?.token == token { self?.tasks[slot] = nil }
        }
        tasks[slot] = (token, task)
    }

    @discardableResult
    func startAction(_ body: @escaping @MainActor () async -> Void) -> Bool {
        guard admissionOpen, tasks[.action] == nil else { return false }
        start(.action, body)
        return true
    }

    func closeAndCancel() {
        admissionOpen = false
        tasks.values.forEach { $0.task.cancel() }
    }

    func drain() async {
        for entry in Array(tasks.values) { await entry.task.value }
    }

    func abort() {
        closeAndCancel()
        finishContinuation.finish()
        scopeTask?.cancel()
    }
}
