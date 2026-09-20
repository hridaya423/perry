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
        self == .legacyPlan ? "Saved task can’t resume" : "Check the last action"
    }

    var message: String {
        switch self {
        case .restoredBackup:
            return "Perry restored an older task record and can’t tell which actions finished. This task can’t resume. Check the target app before starting a new task."
        case .unverifiedAction:
            return "Perry couldn’t verify the last action. This task can’t resume because repeating it could change your work twice. Check the target app before starting a new task."
        case .legacyPlan:
            return "This task was saved by an older Perry version and can’t resume. Replan it to run with the current engine."
        }
    }
}
