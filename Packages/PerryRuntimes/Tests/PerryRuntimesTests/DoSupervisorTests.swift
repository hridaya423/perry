import XCTest
@testable import PerryRuntimes
import PerryCore

private actor StubConfirmer: Confirmer {
    private let approved: Bool

    init(approved: Bool) {
        self.approved = approved
    }

    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool {
        approved
    }
}

private struct NoOpExecutor: AgentRuntime {
    let id = "test.noop"
    let capabilities = RuntimeCapabilities()

    func plan(goal: String, context: ScreenContext) async throws -> Plan {
        Plan(goal: goal, runtimeID: id, steps: [])
    }

    func execute(_ step: Step, consent: ConsentHandle?) async throws -> StepResult {
        StepResult(stepID: step.id, success: true, message: "no-op")
    }
}

final class DoSupervisorTests: XCTestCase {
    private var workDirectory: URL!

    override func setUp() {
        super.setUp()
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-supervisor-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        super.tearDown()
    }

    func testScriptedFinderTaskCompletesAndLogs() async {
        let log = ActivityLog()
        let supervisor = DoSupervisor(activityLog: log, confirmer: StubConfirmer(approved: true))
        let runtime = ScriptedFinderRuntime(baseURL: workDirectory)

        let outcome = await supervisor.run(goal: "demo rename", runtime: runtime)

        XCTAssertEqual(outcome, .completed(stepsRun: 7))
        let entries = await log.snapshot()
        XCTAssertTrue(entries.contains { $0.actionSummary.contains("create perry-demo-a.txt") && $0.outcome == .allowed })
        let finalState = await supervisor.sessionState
        XCTAssertEqual(finalState, .idle)
    }

    func testBlockedWindowDeniesBeforeExecution() async {
        let log = ActivityLog()
        let supervisor = DoSupervisor(activityLog: log, confirmer: StubConfirmer(approved: true))
        let runtime = ScriptedFinderRuntime(baseURL: workDirectory)

        let outcome = await supervisor.run(
            goal: "peek at vault",
            runtime: runtime,
            targetWindow: WindowContext(appBundleID: "com.bitwarden.desktop", title: "Bitwarden")
        )

        XCTAssertEqual(outcome, .blocked(reason: "target window is on the blocked list"))
        let contents = try? FileManager.default.contentsOfDirectory(atPath: workDirectory.path)
        XCTAssertTrue(contents?.isEmpty ?? true)
        let entries = await log.snapshot()
        XCTAssertTrue(entries.contains { $0.outcome == .denied })
        let finalState = await supervisor.sessionState
        XCTAssertEqual(finalState, .stopped)
    }

    func testDeniedConfirmationStopsTask() async throws {
        let log = ActivityLog()
        let supervisor = DoSupervisor(activityLog: log, confirmer: StubConfirmer(approved: false))
        let plan = Plan(goal: "risky", runtimeID: "test", steps: [
            Step(kind: .moveToTrash, summary: "delete old exports"),
            Step(kind: .highlight, summary: "should never run"),
        ])

        let outcome = await supervisor.run(plan: plan, targetWindow: WindowContext(appBundleID: "com.apple.finder", title: "Exports"))

        guard case .blocked(let reason) = outcome else {
            return XCTFail("expected blocked, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("user denied"))
        let entries = await log.snapshot()
        XCTAssertTrue(entries.contains { $0.outcome == .denied && $0.tier == .orange })
        let finalState = await supervisor.sessionState
        XCTAssertEqual(finalState, .stopped)
    }

    func testApprovedConfirmationRunsOrangeStep() async {
        let log = ActivityLog()
        let supervisor = DoSupervisor(activityLog: log, confirmer: RecordingConfirmer())
        let plan = Plan(goal: "cleanup", runtimeID: "test", steps: [
            Step(kind: .moveToTrash, summary: "trash one file"),
            Step(kind: .highlight, summary: "point at trash"),
        ])

        let outcome = await supervisor.run(plan: plan, executor: NoOpExecutor())

        XCTAssertEqual(outcome, .completed(stepsRun: 2))
        let snapshot = await log.snapshot()
        XCTAssertTrue(snapshot.contains { $0.outcome == .confirmed && $0.tier == .orange })
    }

    func testFailingStepStopsRemainingWork() async {
        let log = ActivityLog()
        let supervisor = DoSupervisor(activityLog: log, confirmer: StubConfirmer(approved: true))
        let runtime = ScriptedFinderRuntime(baseURL: workDirectory)

        try? Data("occupied".utf8).write(to: workDirectory.appendingPathComponent("perry-demo-a.txt"))

        let outcome = await supervisor.run(goal: "demo rename", runtime: runtime)

        if case .failed(let stepSummary, _) = outcome {
            XCTAssertTrue(stepSummary.contains("perry-demo-a.txt"))
        } else {
            XCTFail("expected failed, got \(outcome)")
        }
        let contents = try? FileManager.default.contentsOfDirectory(atPath: workDirectory.path)
        XCTAssertEqual(contents, ["perry-demo-a.txt"])
    }
}

private struct RecordingConfirmer: Confirmer {
    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool {
        true
    }
}
