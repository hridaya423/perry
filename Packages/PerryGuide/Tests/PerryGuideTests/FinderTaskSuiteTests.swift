import XCTest
@testable import PerryGuide
import PerryCore
import PerryRuntimes

final class FinderTaskSuiteTests: XCTestCase {
    private var workDirectory: URL!

    override func setUp() {
        super.setUp()
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-finder-suite-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        super.tearDown()
    }

    func testRenameBatchScenarioGreen() async throws {
        let scenario = FinderTaskSuite.renameBatch
        try scenario.setup(workDirectory)
        let plan = try FinderTaskSuite.plan(for: scenario, workspace: workDirectory)

        let outcome = await runScenario(plan)
        XCTAssertEqual(outcome, .completed(stepsRun: 3))
        XCTAssertTrue(try scenario.verify(workDirectory))
    }

    func testOrganizeByExtensionScenarioGreen() async throws {
        let scenario = FinderTaskSuite.organizeByExtension
        try scenario.setup(workDirectory)
        let plan = try FinderTaskSuite.plan(for: scenario, workspace: workDirectory)

        let outcome = await runScenario(plan)
        XCTAssertEqual(outcome, .completed(stepsRun: 2))
        XCTAssertTrue(try scenario.verify(workDirectory))
    }

    func testCleanupOldExportsRunsActionsThroughConfirmation() async throws {
        let scenario = FinderTaskSuite.cleanupOldExports
        try scenario.setup(workDirectory)
        let plan = try FinderTaskSuite.plan(for: scenario, workspace: workDirectory)

        let confirmer = RecordingConfirmer()
        let activityLog = ActivityLog()
        let trash = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: trash) }
        let supervisor = DoSupervisor(
            activityLog: activityLog,
            confirmer: confirmer,
            typedVerifier: WorkspaceFileVerifier(baseURL: workDirectory, trashURL: trash)
        )

        let outcome = await supervisor.run(
            plan: plan,
            typedExecutor: WorkspaceFileRuntime(baseURL: workDirectory, trashURL: trash)
        )
        guard case .completed(let steps) = outcome else {
            return XCTFail("expected completion, got \(outcome)")
        }
        XCTAssertEqual(steps, 3)
        XCTAssertEqual(confirmer.requestCount, 3)
        XCTAssertTrue(try scenario.verify(workDirectory))

        let entries = await activityLog.snapshot()
        XCTAssertTrue(entries.contains { $0.outcome == .confirmed })
    }

    func testCleanupDeniesWithoutConfirmation() async throws {
        let scenario = FinderTaskSuite.cleanupOldExports
        try scenario.setup(workDirectory)
        let plan = try FinderTaskSuite.plan(for: scenario, workspace: workDirectory)

        let trash = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: trash) }
        let supervisor = DoSupervisor(
            activityLog: ActivityLog(),
            confirmer: AlwaysNoConfirmer(),
            typedVerifier: WorkspaceFileVerifier(baseURL: workDirectory, trashURL: trash)
        )
        let outcome = await supervisor.run(
            plan: plan,
            typedExecutor: WorkspaceFileRuntime(baseURL: workDirectory, trashURL: trash)
        )

        guard case .blocked = outcome else {
            return XCTFail("expected a blocked outcome, got \(outcome)")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: workDirectory.path)
        XCTAssertEqual(names.count, 3)
    }

    private func runScenario(_ plan: PerryRuntimes.ExecutionPlan) async -> DoOutcome {
        let supervisor = DoSupervisor(
            activityLog: ActivityLog(),
            confirmer: AlwaysYesConfirmer(),
            typedVerifier: WorkspaceFileVerifier(baseURL: workDirectory)
        )
        return await supervisor.run(
            plan: plan,
            typedExecutor: WorkspaceFileRuntime(baseURL: workDirectory)
        )
    }
}

private struct AlwaysYesConfirmer: Confirmer {
    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool { true }
}

private struct AlwaysNoConfirmer: Confirmer {
    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool { false }
}

private final class RecordingConfirmer: Confirmer, @unchecked Sendable {
    private(set) var requestCount = 0

    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool {
        requestCount += 1
        return true
    }
}
