import Foundation
import PerryGuide

struct BackgroundTaskLaunchLease: Equatable {
    let taskID: TaskID
    let generation: UUID
}

@MainActor
final class BackgroundTaskLaunchGate {
    private var generations: [TaskID: UUID] = [:]

    static func blocker(record: TaskRecord) -> String? {
        if let notice = BackgroundTaskRecoveryNotice(record: record, isRunning: false) {
            return notice.message
        }
        if record.canResumeWorkspaceTask || record.canResumeAgentTask {
            return nil
        }
        return "This task cannot resume because it is cancelled or has no remaining safe action."
    }

    func acquire(for taskID: TaskID) -> BackgroundTaskLaunchLease? {
        guard generations[taskID] == nil else { return nil }
        let lease = BackgroundTaskLaunchLease(taskID: taskID, generation: UUID())
        generations[taskID] = lease.generation
        return lease
    }

    func contains(_ lease: BackgroundTaskLaunchLease) -> Bool {
        generations[lease.taskID] == lease.generation
    }

    func release(_ lease: BackgroundTaskLaunchLease) {
        guard contains(lease) else { return }
        generations[lease.taskID] = nil
    }

    func cancel(_ taskID: TaskID) {
        generations[taskID] = nil
    }

    func cancelAll() {
        generations.removeAll()
    }
}

enum BackgroundTaskResource: Hashable, Sendable {
    case application(String)
    case workspace(String)
    case integration(String)
}
