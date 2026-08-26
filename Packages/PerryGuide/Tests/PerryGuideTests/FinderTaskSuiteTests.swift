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
        let plan = FinderTaskSuite.plan(for: scenario)

        let outcome = await runScenario(plan, executor: FinderTaskSuite.FileOpsRuntime(baseURL: workDirectory))
        XCTAssertEqual(outcome, .completed(stepsRun: 3))
        XCTAssertTrue(try scenario.verify(workDirectory))
    }

    func testOrganizeByExtensionScenarioGreen() async throws {
        let scenario = FinderTaskSuite.organizeByExtension
        try scenario.setup(workDirectory)
        let plan = FinderTaskSuite.plan(for: scenario)

        let outcome = await runScenario(plan, executor: FinderTaskSuite.FileOpsRuntime(baseURL: workDirectory))
        XCTAssertEqual(outcome, .completed(stepsRun: 2))
        XCTAssertTrue(try scenario.verify(workDirectory))
    }

    func testCleanupOldExportsRunsOrangeStepsThroughConfirmation() async throws {
        let scenario = FinderTaskSuite.cleanupOldExports
        try scenario.setup(workDirectory)
        let plan = FinderTaskSuite.plan(for: scenario)

        let policy = IntentCardPolicy()
        let confirmer = CardConfirmer(policy: policy, typedConfirmation: nil, voice: false)
        let activityLog = ActivityLog()
        let supervisor = DoSupervisor(activityLog: activityLog, confirmer: confirmer)

        let outcome = await supervisor.run(plan: plan, executor: FinderTaskSuite.FileOpsRuntime(baseURL: workDirectory))
        guard case .completed(let steps) = outcome else {
            return XCTFail("expected completion, got \(outcome)")
        }
        XCTAssertEqual(steps, 3)
        XCTAssertTrue(try scenario.verify(workDirectory))

        let entries = await activityLog.snapshot()
        XCTAssertTrue(entries.contains { $0.outcome == .confirmed && $0.tier == .orange })
    }

    func testCleanupDeniesWithoutTypedConfirmationForRedEquivalent() async throws {
        // Simulates a red-tier variant: same trash steps but the window is on
        // the block list, so the guard denies outright regardless of consent.
        let scenario = FinderTaskSuite.cleanupOldExports
        try scenario.setup(workDirectory)
        let plan = FinderTaskSuite.plan(for: scenario)

        let supervisor = DoSupervisor(activityLog: ActivityLog(), confirmer: AlwaysYesConfirmer())
        let outcome = await supervisor.run(
            plan: plan,
            targetWindow: WindowContext(appBundleID: "com.bitwarden.desktop", title: "Bitwarden"),
            executor: FinderTaskSuite.FileOpsRuntime(baseURL: workDirectory)
        )

        XCTAssertEqual(outcome, .blocked(reason: "target window is on the blocked list"))
        let names = try FileManager.default.contentsOfDirectory(atPath: workDirectory.path)
        XCTAssertEqual(names.count, 3)
    }
}

private func runScenario(_ plan: Plan, executor: FinderTaskSuite.FileOpsRuntime) async -> DoOutcome {
    let supervisor = DoSupervisor(activityLog: ActivityLog(), confirmer: AlwaysYesConfirmer())
    return await supervisor.run(plan: plan, executor: executor)
}

private struct AlwaysYesConfirmer: Confirmer {
    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool { true }
}

private final class CardConfirmer: Confirmer {
    private let policy: IntentCardPolicy
    private let typedConfirmation: String?
    private let voice: Bool

    init(policy: IntentCardPolicy, typedConfirmation: String?, voice: Bool) {
        self.policy = policy
        self.typedConfirmation = typedConfirmation
        self.voice = voice
    }

    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool {
        let card = IntentCard(title: request.actionSummary, tier: request.tier, targetSummary: "")
        return policy.resolve(card, choice: .approve, typedConfirmation: typedConfirmation, sourceIsVoice: voice)
    }
}
