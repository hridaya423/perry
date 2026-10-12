import Foundation
import PerryCore
import PerryRuntimes

struct DemoConfirmer: Confirmer {
    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool {
        print("  confirmation requested [\(request.tier.rawValue)]: \(request.actionSummary)")
        print("  reason: \(request.reason)")
        return true
    }
}

@main
struct PerryDemo {
    static func main() async {
        await runWorkspaceDemo()
    }

    /// Fabricated typed plan → DoSupervisor → workspace file execution:
    /// the same execution pipeline routine replay drives, without a planner.
    private static func runWorkspaceDemo() async {
        let workDirectory = makeWorkspace(named: "workspace")
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        print("Perry demo — typed workspace task")
        print("workspace: \(workDirectory.path)")

        let taskID = TaskID(UUID().uuidString)
        var plan = try? await WorkspaceFilePlanFabricator().workspaceExecutionPlan(
            goal: #"create file "note-1.txt" with "first note""#,
            workspace: workDirectory,
            taskID: taskID
        )
        // A multi-action plan exercises the supervisor's ordered execution.
        let extra = (2...3).compactMap { index -> ExecutableAction? in
            try? ExecutableAction(
                id: ActionID(UUID().uuidString),
                summary: "Create note \(index)",
                approvalRequirement: .action,
                operation: .transform(
                    workspace: workDirectory,
                    command: .createUTF8File(path: "note-\(index).txt", contents: "note \(index)")
                ),
                postcondition: .fileContents("note \(index)")
            )
        }
        if let existing = plan {
            plan = try? ExecutionPlan(
                taskID: taskID,
                goal: "create three notes",
                actions: existing.actions + extra,
                requestedScopes: existing.requestedScopes
            )
        }
        guard let plan else {
            print("could not fabricate the demo plan")
            return
        }

        let activityLog = ActivityLog(storageDirectory: workDirectory)
        let supervisor = DoSupervisor(activityLog: activityLog, confirmer: DemoConfirmer())
        let outcome = await supervisor.run(
            plan: plan,
            context: .empty,
            targetWindow: WindowContext(appBundleID: "com.apple.finder", title: "Desktop"),
            typedExecutor: WorkspaceFileRuntime(baseURL: workDirectory)
        )
        report(outcome)

        let entries = await activityLog.snapshot()
        print("activity log:")
        for entry in entries {
            let bundle = entry.targetAppBundleID ?? "—"
            print("  [\(entry.tier.rawValue)] \(entry.outcome.rawValue) · \(entry.actionSummary) · \(bundle)")
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: workDirectory.path).sorted()) ?? []
        print("final workspace: \(contents.joined(separator: ", "))")
    }

    private static func report(_ outcome: DoOutcome) {
        switch outcome {
        case .completed(let stepsRun):
            print("outcome: completed \(stepsRun) steps")
        case .blocked(let reason):
            print("outcome: blocked — \(reason)")
        case .failed(let stepSummary, let reason):
            print("outcome: failed at \"\(stepSummary)\" — \(reason)")
        }
    }

    private static func makeWorkspace(named name: String) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-demo-\(name)-\(stamp)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
