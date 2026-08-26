import XCTest
@testable import PerryGuide
import PerryCore
import PerryRuntimes

final class MemoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-memory-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        super.tearDown()
    }

    func testOnByDefaultAndPersistsAcrossInstances() async {
        let store = MemoryStore(storageDirectory: directory)
        let config = await store.currentConfiguration()
        XCTAssertTrue(config.enabled)

        await store.remember(MemoryRecord(category: .preference, appBundleID: "com.apple.finder", summary: "sorts by name"))
        let reloaded = MemoryStore(storageDirectory: directory)
        let recalled = await reloaded.recall(category: .preference, appBundleID: "com.apple.finder")
        XCTAssertEqual(recalled.map(\.summary), ["sorts by name"])
    }

    func testCategoryToggleBlocksWriteAndRecall() async {
        var toggles: [MemoryRecord.Category: Bool] = [:]
        toggles[.appWorkflow] = false
        let store = MemoryStore(storageDirectory: nil, configuration: MemoryConfiguration(enabled: true, categoryToggles: toggles))

        let accepted = await store.remember(MemoryRecord(category: .appWorkflow, summary: "export preset flow"))
        XCTAssertFalse(accepted)
        let recalled = await store.recall(category: .appWorkflow, appBundleID: nil)
        XCTAssertTrue(recalled.isEmpty)

        _ = await store.remember(MemoryRecord(category: .pastSession, summary: "renamed files yesterday"))
        let count = await store.snapshot().count
        XCTAssertEqual(count, 1)
    }

    func testGoldfishModeRecallsNothing() async {
        let store = MemoryStore(storageDirectory: nil, configuration: .goldfish)
        _ = await store.remember(MemoryRecord(category: .pastSession, summary: "anything"))
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
        let recalled = await store.recall(category: nil, appBundleID: nil)
        XCTAssertTrue(recalled.isEmpty)
    }

    func testWipeClearsEverythingIncludingDisk() async {
        let store = MemoryStore(storageDirectory: directory)
        _ = await store.remember(MemoryRecord(category: .preference, summary: "dark mode always"))
        await store.wipe()

        let reloaded = MemoryStore(storageDirectory: directory)
        let afterWipe = await reloaded.snapshot()
        XCTAssertTrue(afterWipe.isEmpty)
    }
}

final class BackgroundTaskRunnerTests: XCTestCase {
    private final class NotificationBox: Notifying, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [TaskNotification] = []

        func deliver(_ notification: TaskNotification) async {
            lock.lock()
            items.append(notification)
            lock.unlock()
        }

        var all: [TaskNotification] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    private var workDirectory: URL!

    override func setUp() {
        super.setUp()
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-runner-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        super.tearDown()
    }

    func testCompletionDeliversNotification() async {
        let box = NotificationBox()
        let runner = BackgroundTaskRunner(notifier: box)
        let runtime = ScriptedFinderRuntime(baseURL: workDirectory)

        let outcome = await runner.run(goal: "demo rename", runtime: runtime)

        guard case .completed = outcome else { return XCTFail("expected completion") }
        XCTAssertEqual(box.all.first?.kind, .completed)
    }

    func testBlockedRunDeliversStoppedNotification() async {
        let box = NotificationBox()
        let runner = BackgroundTaskRunner(notifier: box)
        let runtime = ScriptedFinderRuntime(baseURL: workDirectory)

        _ = await runner.run(
            goal: "peek",
            runtime: runtime,
            targetWindow: WindowContext(appBundleID: "com.lastpass.LastPass", title: "Vault")
        )

        XCTAssertEqual(box.all.first?.kind, .stopped)
    }

    func testConfirmationNeededStopsSafelyInBackground() async throws {
        // Orange steps in background runs stop safely; the intent card owns
        // real approval when the user returns.
        let box = NotificationBox()
        let runner = BackgroundTaskRunner(notifier: box)
        let plan = Plan(goal: "cleanup", runtimeID: "test", steps: [
            Step(kind: .moveToTrash, summary: "trash exports"),
        ])

        let supervisor = DoSupervisor(activityLog: ActivityLog(), confirmer: NeverConfirmer())
        let outcome = await supervisor.run(plan: plan)

        if case .blocked = outcome {} else {
            XCTFail("expected blocked, got \(outcome)")
        }
    }
}

private struct NeverConfirmer: Confirmer {
    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool { false }
}
