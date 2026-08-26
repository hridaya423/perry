import Foundation
import PerryCore
import PerryRuntimes

/// PRD §4 Do mode: buddy docks to menu bar with live status, notification on
/// completion or stop. Protocol keeps delivery testable; production binds to
/// UserNotifications.
public struct TaskNotification: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case completed
        case stopped
        case needsConfirmation
    }

    public let kind: Kind
    public let title: String
    public let body: String

    public init(kind: TaskNotification.Kind, title: String, body: String) {
        self.kind = kind
        self.title = title
        self.body = body
    }
}

public protocol Notifying: Sendable {
    func deliver(_ notification: TaskNotification) async
}

/// Wraps a DoSupervisor run with background semantics: notifications on every
/// terminal outcome. The buddy docking is UI; this carries the state machine.
public actor BackgroundTaskRunner {
    public private(set) var lastOutcome: DoOutcome?
    private let notifier: any Notifying

    public init(notifier: any Notifying) {
        self.notifier = notifier
    }

    @discardableResult
    public func run(
        goal: String,
        runtime: any AgentRuntime,
        context: ScreenContext = .empty,
        targetWindow: WindowContext? = nil
    ) async -> DoOutcome {
        let supervisor = DoSupervisor(activityLog: ActivityLog(), confirmer: PromptingConfirmer(notifier: notifier))
        let outcome = await supervisor.run(goal: goal, runtime: runtime, context: context, targetWindow: targetWindow)
        lastOutcome = outcome

        switch outcome {
        case .completed(let steps):
            await notifier.deliver(TaskNotification(kind: .completed, title: "Task finished", body: "\(goal) — \(steps) steps done."))
        case .blocked(let reason):
            await notifier.deliver(TaskNotification(kind: .stopped, title: "Task stopped", body: reason))
        case .failed(let step, let reason):
            await notifier.deliver(TaskNotification(kind: .stopped, title: "Task failed", body: "\(step): \(reason)"))
        }
        return outcome
    }
}

private struct PromptingConfirmer: Confirmer {
    let notifier: any Notifying

    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool {
        await notifier.deliver(
            TaskNotification(
                kind: .needsConfirmation,
                title: "Approval needed",
                body: request.actionSummary
            )
        )
        // Background runs never auto-approve; the intent card in the UI owns
        // the real decision. Returning false stops the task safely.
        return false
    }
}
