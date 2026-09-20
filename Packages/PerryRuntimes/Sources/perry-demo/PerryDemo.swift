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
        await runScriptedDemo()
        print()
        await runCLIDemo()
    }

    /// Scripted runtime: plan is deterministic, execution touches disk.
    private static func runScriptedDemo() async {
        let workDirectory = makeWorkspace(named: "scripted")
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        print("Perry demo — scripted Finder task")
        print("workspace: \(workDirectory.path)")

        let runtime = ScriptedFinderRuntime()
        let outcome = await execute(
            goal: "create three notes",
            planner: runtime,
            workDirectory: workDirectory
        )
        report(outcome)
    }

    /// CLI adapter path: planning goes through a real spawned process
    /// (a fake claude-like responder via a staged executable), proving the
    /// typed plan pipeline end to end without network or auth.
    private static func runCLIDemo() async {
        guard let fakeCLI = installFakeCLI() else {
            print("\nPerry demo — CLI adapter path skipped (could not stage fake CLI)")
            return
        }
        defer { try? FileManager.default.removeItem(at: fakeCLI.directory) }

        let workDirectory = makeWorkspace(named: "cli")
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        print("\nPerry demo — CLI adapter task")
        print("workspace: \(workDirectory.path)")
        print("fake CLI at: \(fakeCLI.executable.path)")

        let runtime = CLIRuntime(executableLocator: { fakeCLI.executable }, timeout: 15)
        let outcome = await execute(
            goal: "tidy the perry demo folder",
            planner: runtime,
            workDirectory: workDirectory,
            context: ScreenContext(frontAppBundleID: "com.apple.finder", frontWindowTitle: "Desktop")
        )
        report(outcome)

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: workDirectory.path).sorted()) ?? []
        print("final workspace: \(contents.joined(separator: ", "))")
    }

    private static func execute(
        goal: String,
        planner: any TaskPlanner,
        workDirectory: URL,
        context: ScreenContext = .empty
    ) async -> DoOutcome {
        let activityLog = ActivityLog(storageDirectory: workDirectory)
        let supervisor = DoSupervisor(activityLog: activityLog, confirmer: DemoConfirmer())
        guard let request = try? PlanningRequest(
            goal: goal,
            taskID: TaskID(UUID().uuidString),
            workspace: workDirectory,
            context: .screen(context)
        ), let plan = try? await planner.plan(request) else {
            return .failed(stepSummary: "plan", reason: "runtime could not create a plan")
        }
        let outcome = await supervisor.run(
            plan: plan,
            context: context,
            targetWindow: WindowContext(appBundleID: "com.apple.finder", title: "Desktop"),
            typedExecutor: WorkspaceFileRuntime(baseURL: workDirectory)
        )

        let entries = await activityLog.snapshot()
        print("activity log:")
        for entry in entries {
            let bundle = entry.targetAppBundleID ?? "—"
            print("  [\(entry.tier.rawValue)] \(entry.outcome.rawValue) · \(entry.actionSummary) · \(bundle)")
        }
        return outcome
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

    /// Stages an executable that mimics `claude -p <prompt>` output so the
    /// adapter's plan() parses typed draft actions from a real subprocess.
    private static func installFakeCLI() -> (executable: URL, directory: URL)? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-fake-cli-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let executable = directory.appendingPathComponent("claude")
            let script = """
            #!/bin/sh
            cat > /dev/null
            echo '{"actions":['
            echo '{"summary":"Create first note","operation":{"transform":{"command":{"createUTF8File":{"path":"note-1.txt","contents":"first note"}}}}},'
            echo '{"summary":"Create second note","operation":{"transform":{"command":{"createUTF8File":{"path":"note-2.txt","contents":"second note"}}}}},'
            echo '{"summary":"Create third note","operation":{"transform":{"command":{"createUTF8File":{"path":"note-3.txt","contents":"third note"}}}}}'
            echo ']}'
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            return (executable, directory)
        } catch {
            return nil
        }
    }
}
