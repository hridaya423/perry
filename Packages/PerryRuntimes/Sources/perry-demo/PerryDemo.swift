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
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-demo-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ""))")
        try! FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        print("Perry demo — scripted Finder task")
        print("workspace: \(workDirectory.path)")

        let runtime = ScriptedFinderRuntime(baseURL: workDirectory)
        let activityLog = ActivityLog()
        let supervisor = DoSupervisor(activityLog: activityLog, confirmer: DemoConfirmer())

        let started = Date()
        let outcome = await supervisor.run(
            goal: "create three notes and rename them",
            runtime: runtime,
            context: ScreenContext(frontAppBundleID: "com.apple.finder", frontWindowTitle: "Desktop"),
            targetWindow: WindowContext(appBundleID: "com.apple.finder", title: "Desktop")
        )
        let elapsed = Date().timeIntervalSince(started)

        switch outcome {
        case .completed(let stepsRun):
            print("outcome: completed \(stepsRun) steps in \(String(format: "%.2f", elapsed))s")
        case .blocked(let reason):
            print("outcome: blocked — \(reason)")
        case .failed(let stepSummary, let reason):
            print("outcome: failed at \"\(stepSummary)\" — \(reason)")
        }

        let entries = await activityLog.snapshot()
        print("activity log:")
        for entry in entries {
            let bundle = entry.targetAppBundleID ?? "—"
            print("  [\(entry.tier.rawValue)] \(entry.outcome.rawValue) · \(entry.actionSummary) · \(bundle)")
        }
    }
}
