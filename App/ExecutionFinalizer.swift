import Foundation
import PerryCore
import PerryGuide
import PerryRuntimes

enum ExecutionFinalizationIssue: Equatable {
    case transcriptPersistence
    case memoryPersistence
}

struct ExecutionCompletion: Equatable {
    let transcript: TranscriptEntry
    let memory: MemoryRecord
    let notification: TaskNotification

    var summary: String { transcript.summary }
    var outcome: TranscriptEntry.Outcome { transcript.outcome }
}

struct ExecutionFinalizationResult: Equatable {
    let completion: ExecutionCompletion
    let issues: [ExecutionFinalizationIssue]

    var historySaved: Bool { !issues.contains(.transcriptPersistence) }
}

struct ExecutionFinalizer: Sendable {
    let transcriptStore: TranscriptStore
    let memoryStore: MemoryStore
    let notifier: any Notifying
    let beforeTranscriptAppend: (@Sendable () async -> Void)?

    init(
        transcriptStore: TranscriptStore,
        memoryStore: MemoryStore,
        notifier: any Notifying,
        beforeTranscriptAppend: (@Sendable () async -> Void)? = nil
    ) {
        self.transcriptStore = transcriptStore
        self.memoryStore = memoryStore
        self.notifier = notifier
        self.beforeTranscriptAppend = beforeTranscriptAppend
    }

    func finalize(
        execution: ExecutionSessionState,
        outcome: DoOutcome,
        finishedAt: Date = Date()
    ) async -> ExecutionFinalizationResult {
        let completion = Self.completion(execution: execution, outcome: outcome, finishedAt: finishedAt)
        if let beforeTranscriptAppend {
            await beforeTranscriptAppend()
        }
        guard await transcriptStore.append(completion.transcript) else {
            return ExecutionFinalizationResult(completion: completion, issues: [.transcriptPersistence])
        }

        var issues: [ExecutionFinalizationIssue] = []
        let memoryConfiguration = await memoryStore.currentConfiguration()
        if memoryConfiguration.enabled,
           memoryConfiguration.categoryToggles[.pastSession] == true,
           !(await memoryStore.remember(completion.memory)) {
            issues.append(.memoryPersistence)
        }
        await notifier.deliver(completion.notification)
        return ExecutionFinalizationResult(completion: completion, issues: issues)
    }

    static func completion(
        execution: ExecutionSessionState,
        outcome: DoOutcome,
        finishedAt: Date
    ) -> ExecutionCompletion {
        let transcriptOutcome: TranscriptEntry.Outcome
        let summary: String
        switch outcome {
        case .completed(let steps):
            transcriptOutcome = .completed
            summary = execution.warnings.isEmpty
                ? "Finished \(steps) step\(steps == 1 ? "" : "s")."
                : "Finished, but Perry could not independently verify: \(execution.warnings.joined(separator: "; "))."
        case .blocked(let reason):
            transcriptOutcome = .stopped
            summary = recoverySummary(headline: "Stopped: \(reason).", execution: execution, pendingMayHaveApplied: false)
        case .failed(let step, let reason):
            transcriptOutcome = .failed
            summary = recoverySummary(headline: "Stopped at \(step): \(reason).", execution: execution, pendingMayHaveApplied: true)
        }

        let verified: Bool?
        if !execution.warnings.isEmpty || execution.verificationResults.contains(false) {
            verified = false
        } else if !execution.steps.isEmpty,
                  execution.verificationResults.count == execution.steps.count {
            verified = true
        } else {
            verified = nil
        }
        let transcript = TranscriptEntry(
            id: execution.taskID,
            sessionID: execution.taskID,
            request: execution.goal,
            appBundleID: execution.appBundleID,
            summary: summary,
            outcome: transcriptOutcome,
            startedAt: execution.startedAt,
            finishedAt: finishedAt,
            steps: execution.steps,
            verified: verified
        )
        let memory = MemoryRecord(
            category: .pastSession,
            appBundleID: execution.appBundleID,
            summary: summary,
            createdAt: finishedAt
        )
        let notificationKind: TaskNotification.Kind = transcriptOutcome == .completed ? .completed : .stopped
        let notification = TaskNotification(
            kind: notificationKind,
            title: "Perry task (\(transcriptOutcome.rawValue))",
            body: summary
        )
        return ExecutionCompletion(
            transcript: transcript,
            memory: memory,
            notification: notification
        )
    }

    /// Recovery-oriented failure copy: what happened, what changed, what did
    /// not change, and the one safe next action.
    private static func recoverySummary(headline: String, execution: ExecutionSessionState, pendingMayHaveApplied: Bool) -> String {
        let finished = execution.steps.count
        guard finished > 0 else {
            return "\(headline) No actions ran, so nothing was changed. Safe next step: adjust the goal and try again."
        }
        let verifiedCount = execution.verificationResults.filter { $0 }.count
        var sentence = "\(headline) \(finished) of \(max(execution.totalSteps, finished)) actions finished"
        sentence += verifiedCount == finished
            ? " and were verified"
            : " (\(verifiedCount) verified)"
        sentence += pendingMayHaveApplied
            ? "; the stopped action's effect is uncertain, and everything after it was left untouched."
            : "; everything after that point was left untouched."
        return "\(sentence) Safe next step: review what changed, then retry the goal."
    }
}
