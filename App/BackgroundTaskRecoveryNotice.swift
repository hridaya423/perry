import PerryGuide

enum BackgroundTaskRecoveryNotice: Equatable {
    case restoredBackup
    case unverifiedAction
    case legacyPlan

    init?(record: TaskRecord, isRunning: Bool) {
        if record.recoveryDisposition == .restoredBackup {
            self = .restoredBackup
        } else if record.checkpoint.hasUncertainSideEffect, !isRunning {
            self = .unverifiedAction
        } else if case .legacy = record.plan, !record.state.isTerminal {
            self = .legacyPlan
        } else {
            return nil
        }
    }

    var title: String {
        self == .legacyPlan ? "This task can’t resume" : "Check the last step"
    }

    var message: String {
        switch self {
        case .restoredBackup:
            return "I can’t tell which steps finished. Check the app, then start a new task."
        case .unverifiedAction:
            return "I couldn’t confirm the last step, and repeating it could change your work twice. Check the app, then start a new task."
        case .legacyPlan:
            return "An older version of Perry saved this task. Replan it to run it."
        }
    }
}
