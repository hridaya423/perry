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
        finishedAt: Date = Date(),
        headline: String? = nil
    ) async -> ExecutionFinalizationResult {
        let completion = Self.completion(execution: execution, outcome: outcome, finishedAt: finishedAt, headline: headline)
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
        finishedAt: Date,
        headline: String? = nil
    ) -> ExecutionCompletion {
        let transcriptOutcome: TranscriptEntry.Outcome
        let summary: String
        switch outcome {
        case .completed(let steps):
            transcriptOutcome = .completed
            summary = execution.warnings.isEmpty
                ? headline ?? "Done. I ran \(steps) step\(steps == 1 ? "" : "s")."
                : "Done, but I couldn’t confirm it worked: \(execution.warnings.joined(separator: "; "))."
        case .blocked(let reason):
            transcriptOutcome = .stopped
            summary = recoverySummary(headline: "I stopped: \(reason).", execution: execution, pendingMayHaveApplied: false)
        case .failed(let step, let reason):
            transcriptOutcome = .failed
            summary = recoverySummary(headline: headline ?? "I stopped at \(step): \(reason).", execution: execution, pendingMayHaveApplied: true)
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
            verified: verified,
            providerRoute: execution.providerRoute
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
            title: execution.goal,
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
            return "\(headline) I didn’t change anything. Rephrase the task and try again."
        }
        let verifiedCount = execution.verificationResults.filter { $0 }.count
        var sentence = "\(headline) I finished \(finished) of \(max(execution.totalSteps, finished)) steps and checked "
        sentence += verifiedCount == finished ? "each one." : "\(verifiedCount) of them."
        if pendingMayHaveApplied {
            sentence += " I can’t tell whether the last step took effect."
        }
        return "\(sentence) I didn’t touch the rest. Check what changed, then try again."
    }
}
