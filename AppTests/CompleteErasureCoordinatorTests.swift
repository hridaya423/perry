import Foundation
import XCTest
import PerryCore
import PerryGuide
@testable import Perry

final class CompleteErasureCoordinatorTests: XCTestCase {
    @MainActor
    func testBackgroundWorkspaceRemovalDeletesOnlyTheSelectedTask() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerryBackgroundWorkspaceRemoval-\(UUID().uuidString)", isDirectory: true)
        let selectedID = TaskID("selected")
        let siblingID = TaskID("sibling")
        let selected = root.appendingPathComponent(selectedID.rawValue, isDirectory: true)
        let sibling = root.appendingPathComponent(siblingID.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try BackgroundTaskController.removeWorkspace(for: selectedID, root: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    func testFullEraseInventoriesAndRemovesEveryCategory() async {
        let states = Dictionary(
            uniqueKeysWithValues: PerryErasureCategory.allCases.map { category in
                let item = PerryErasureItem(category: category, identifier: "fixture")
                return (category, ErasureState(items: [item]))
            }
        )
        let coordinator = CompleteErasureCoordinator(
            erasers: PerryErasureCategory.allCases.map { category in
                makeEraser(category: category, state: states[category]!)
            }
        )

        let report = await coordinator.erase()

        XCTAssertEqual(
            Set(report.preEraseInventory.items.map(\.category)),
            Set(PerryErasureCategory.allCases)
        )
        XCTAssertTrue(report.postEraseInventory.items.isEmpty)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.status, .complete)
    }

    func testCategoryEraseLeavesOtherCategoriesInventoryIntact() async {
        let memoryItem = PerryErasureItem(category: .memory, identifier: "memory")
        let historyItem = PerryErasureItem(category: .history, identifier: "history")
        let memoryState = ErasureState(items: [memoryItem])
        let historyState = ErasureState(items: [historyItem])
        let coordinator = CompleteErasureCoordinator(
            erasers: [
                makeEraser(category: .memory, state: memoryState),
                makeEraser(category: .history, state: historyState),
            ]
        )

        let report = await coordinator.erase(category: .memory)

        let memoryWasErased = await memoryState.wasErased
        let historyWasErased = await historyState.wasErased
        XCTAssertTrue(memoryWasErased)
        XCTAssertFalse(historyWasErased)
        XCTAssertTrue(report.isSuccessful)
        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(report.status, .partial)
        XCTAssertEqual(report.postEraseInventory[.history], [historyItem])
        XCTAssertTrue(report.summary.contains("other categories"))
    }

    func testResidualItemsPreventSuccessClaim() async {
        let item = PerryErasureItem(category: .preferences, identifier: "preference")
        let state = ErasureState(items: [item], clearsItems: false)
        let coordinator = CompleteErasureCoordinator(
            erasers: [makeEraser(category: .preferences, state: state)]
        )

        let report = await coordinator.erase(category: .preferences)

        XCTAssertFalse(report.isSuccessful)
        XCTAssertFalse(report.success)
        XCTAssertTrue(report.hasResidualItems)
        XCTAssertEqual(report.residualItems, [item])
        XCTAssertEqual(report.postEraseInventory[.preferences], [item])
        XCTAssertEqual(report.status, .partial)
        XCTAssertTrue(report.summary.contains("incomplete"))
    }

    func testEraseContinuesAfterFailureAndReportsResidualItems() async {
        let taskItem = PerryErasureItem(category: .tasks, identifier: "task")
        let historyItem = PerryErasureItem(category: .history, identifier: "history")
        let taskState = ErasureState(items: [taskItem], failure: .erase)
        let historyState = ErasureState(items: [historyItem])
        let coordinator = CompleteErasureCoordinator(
            erasers: [
                makeEraser(category: .tasks, state: taskState),
                makeEraser(category: .history, state: historyState),
            ]
        )

        let report = await coordinator.erase(categories: [.tasks, .history])

        let taskEraseCount = await taskState.eraseCount
        let historyEraseCount = await historyState.eraseCount
        XCTAssertEqual(taskEraseCount, 1)
        XCTAssertEqual(historyEraseCount, 1)
        XCTAssertEqual(report.postEraseInventory[.tasks], [taskItem])
        XCTAssertTrue(report.postEraseInventory[.history].isEmpty)
        XCTAssertEqual(report.failures.map(\.category), [.tasks])
        XCTAssertEqual(report.failures.first?.operation, .erase)
        XCTAssertFalse(report.isSuccessful)
    }

    func testPostEraseInventoryCatchesDataRecreatedDuringErase() async {
        let item = PerryErasureItem(category: .history, identifier: "late-write")
        let state = ErasureState(items: [item], recreatesAfterErase: true)
        let coordinator = CompleteErasureCoordinator(
            erasers: [makeEraser(category: .history, state: state)]
        )

        let report = await coordinator.erase(category: .history)

        XCTAssertEqual(report.residualItems, [item])
        XCTAssertFalse(report.isSuccessful)
        XCTAssertEqual(report.status, .partial)
    }

    @MainActor
    func testLiveErasersInventoryAndErasePersistenceRecoveryFiles() async throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerryErasureErasersTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let fixtures: [(PerryErasureCategory, String)] = [
            (.tasks, "tasks.json"),
            (.tasks, "tasks.json.backup"),
            (.tasks, "tasks.json.corrupt-fixture"),
            (.tasks, "background-task-context.json"),
            (.tasks, "background-task-context.json.backup"),
            (.tasks, "background-task-context.quarantined-fixture.json"),
            (.history, "activity-log.json"),
            (.history, "activity-log.json.backup"),
            (.history, "activity-log.json.corrupt-fixture"),
            (.memory, "memory.json"),
            (.memory, "memory.json.backup"),
            (.memory, "memory.json.corrupt-fixture"),
            (.memory, "PROFILE.md"),
            (.memory, "VOLATILE.md"),
            (.preferences, "voice-dictionary.json"),
            (.preferences, "voice-dictionary.json.backup"),
            (.preferences, "voice-dictionary.json.corrupt-fixture"),
        ]
        let taskCoordinator = TaskCoordinator(storageDirectory: supportDirectory)
        let backgroundTaskContextStore = BackgroundTaskContextStore(storageDirectory: supportDirectory)
        let activityLog = ActivityLog(storageDirectory: supportDirectory)
        let transcriptStore = TranscriptStore(directory: supportDirectory)
        let memoryStore = MemoryStore(storageDirectory: supportDirectory)
        for (_, name) in fixtures {
            try Data(name.utf8).write(to: supportDirectory.appendingPathComponent(name))
        }
        let unrelated = supportDirectory.appendingPathComponent("unrelated.json")
        try Data("keep".utf8).write(to: unrelated)

        let suiteName = "PerryErasureErasersTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let erasers = PerryLiveErasureErasers.make(
            paths: PerryErasurePaths(
                supportDirectory: supportDirectory,
                homeDirectory: supportDirectory.appendingPathComponent("Home"),
                temporaryDirectory: supportDirectory.appendingPathComponent("Temporary"),
                cachesDirectory: supportDirectory.appendingPathComponent("Caches")
            ),
            defaults: defaults,
            taskCoordinator: taskCoordinator,
            backgroundTaskContextStore: backgroundTaskContextStore,
            activityLog: activityLog,
            transcriptStore: transcriptStore,
            memoryStore: memoryStore
        )

        for category in [PerryErasureCategory.tasks, .history, .memory, .preferences] {
            let eraser = try XCTUnwrap(erasers.first { $0.category == category })
            let expected = Set(
                fixtures
                    .filter { $0.0 == category }
                    .map { PerryErasureItem(category: $0.0, identifier: $0.1) }
            )
            let inventory = try await eraser.inventory()
            XCTAssertEqual(Set(inventory), expected)

            try await eraser.erase()

            let remaining = try await eraser.inventory()
            XCTAssertTrue(remaining.isEmpty)
            for (fixtureCategory, name) in fixtures where fixtureCategory == category {
                XCTAssertFalse(FileManager.default.fileExists(atPath: supportDirectory.appendingPathComponent(name).path))
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @MainActor
    func testProductionKeychainInventoryOwnsEveryShippedSecretService() {
        XCTAssertEqual(
            Set(PerryLiveErasureErasers.providerKeychainServices),
            Set(["dev.perry.integrations", "dev.perry.keys"])
        )
    }

    func testKeychainEraserInventoriesAndDeletesSecrets() async throws {
        let service = "dev.perry.tests.erasure.\(UUID().uuidString)"
        let store = KeychainStore(service: service)
        let targets = ["first", "second"].map {
            PerryKeychainEraser.Target(service: service, account: $0)
        }
        for target in targets {
            try store.save("secret", account: target.account)
        }
        addTeardownBlock {
            for target in targets {
                try store.deleteChecked(account: target.account)
            }
        }
        let eraser = PerryKeychainEraser(services: [service])
        let inventory = try await eraser.inventory()

        XCTAssertEqual(
            Set(inventory),
            Set(targets.map { PerryErasureItem(category: .providerKeychain, identifier: $0.identifier) })
        )

        try await eraser.erase()

        let remaining = try await eraser.inventory()
        XCTAssertTrue(remaining.isEmpty)
        for target in targets {
            XCTAssertNil(try store.readChecked(account: target.account))
        }
    }

    func testKeychainErasureIncludesAccountsAddedAfterTheCatalogWasBuilt() async throws {
        let service = "dev.perry.tests.erasure-unlisted.\(UUID().uuidString)"
        let store = KeychainStore(service: service)
        let known = PerryKeychainEraser.Target(service: service, account: "known")
        let addedLater = PerryKeychainEraser.Target(service: service, account: "added-later")
        try store.save("known-secret", account: known.account)
        try store.save("future-secret", account: addedLater.account)
        addTeardownBlock {
            try store.deleteChecked(account: known.account)
            try store.deleteChecked(account: addedLater.account)
        }
        let eraser = PerryKeychainEraser(services: [service])

        let inventory = try await eraser.inventory()

        XCTAssertEqual(
            Set(inventory),
            Set([known, addedLater].map {
                PerryErasureItem(category: .providerKeychain, identifier: $0.identifier)
            })
        )
    }

    func testKeychainDeletionFailureDoesNotSkipLaterSecretsOrClaimSuccess() async throws {
        struct DeleteFailure: Error {}
        let blockedService = "dev.perry.tests.erasure-failure.blocked.\(UUID().uuidString)"
        let removableService = "dev.perry.tests.erasure-failure.removable.\(UUID().uuidString)"
        let blockedStore = KeychainStore(service: blockedService)
        let removableStore = KeychainStore(service: removableService)
        let blocked = PerryKeychainEraser.Target(service: blockedService, account: "blocked")
        let removable = PerryKeychainEraser.Target(service: removableService, account: "removable")
        try blockedStore.save("secret", account: blocked.account)
        try removableStore.save("secret", account: removable.account)
        addTeardownBlock {
            try blockedStore.deleteChecked(account: blocked.account)
            try removableStore.deleteChecked(account: removable.account)
        }
        let eraser = PerryKeychainEraser(
            services: [blockedService, removableService],
            accounts: { service in try KeychainStore(service: service).accounts() },
            delete: { target in
                if target == blocked { throw DeleteFailure() }
                try KeychainStore(service: target.service).deleteChecked(account: target.account)
            }
        )
        let coordinator = CompleteErasureCoordinator(erasers: [eraser])

        let report = await coordinator.erase(category: .providerKeychain)

        XCTAssertFalse(report.isSuccessful)
        XCTAssertEqual(report.residualItems, [
            PerryErasureItem(category: .providerKeychain, identifier: blocked.identifier),
        ])
        XCTAssertEqual(report.failures.map(\.operation), [.erase])
        XCTAssertNil(try removableStore.readChecked(account: removable.account))
    }

    func testKeychainEnumerationFailureDoesNotSkipLaterServicesOrClaimSuccess() async throws {
        struct EnumerationFailure: Error {}
        let blockedService = "dev.perry.tests.erasure-list-failure.blocked.\(UUID().uuidString)"
        let removableService = "dev.perry.tests.erasure-list-failure.removable.\(UUID().uuidString)"
        let removableStore = KeychainStore(service: removableService)
        let removable = PerryKeychainEraser.Target(service: removableService, account: "removable")
        try removableStore.save("secret", account: removable.account)
        addTeardownBlock {
            try removableStore.deleteChecked(account: removable.account)
        }
        let eraser = PerryKeychainEraser(
            services: [blockedService, removableService],
            accounts: { service in
                if service == blockedService { throw EnumerationFailure() }
                return try KeychainStore(service: service).accounts()
            }
        )
        let coordinator = CompleteErasureCoordinator(erasers: [eraser])

        let report = await coordinator.erase(category: .providerKeychain)

        XCTAssertFalse(report.isSuccessful)
        XCTAssertEqual(report.failures.map(\.operation), [.inventory, .erase, .inventory])
        XCTAssertNil(try removableStore.readChecked(account: removable.account))
    }

    @MainActor
    func testCompleteProductionErasureLeavesSeededCleanProfileEmpty() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerryCompleteErasureTests")
            .appendingPathComponent(UUID().uuidString)
        let supportDirectory = root.appendingPathComponent("ApplicationSupport/Perry", isDirectory: true)
        let homeDirectory = root.appendingPathComponent("Home", isDirectory: true)
        let temporaryDirectory = root.appendingPathComponent("Temporary", isDirectory: true)
        let cachesDirectory = root.appendingPathComponent("Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = PerryErasurePaths(
            supportDirectory: supportDirectory,
            homeDirectory: homeDirectory,
            temporaryDirectory: temporaryDirectory,
            cachesDirectory: cachesDirectory
        )
        let taskCoordinator = TaskCoordinator(storageDirectory: supportDirectory)
        let backgroundTaskContextStore = BackgroundTaskContextStore(storageDirectory: supportDirectory)
        let activityLog = ActivityLog(storageDirectory: supportDirectory)
        let transcriptStore = TranscriptStore(directory: supportDirectory)
        let memoryStore = MemoryStore(storageDirectory: supportDirectory)
        let telemetryDirectory = supportDirectory.appendingPathComponent("Telemetry", isDirectory: true)

        let supportFiles = [
            "tasks.json",
            "background-task-context.json",
            "activity-log.json",
            "memory.json",
            "PROFILE.md",
            "VOLATILE.md",
            "approvals.json",
            "voice-dictionary.json",
            "oauth-state.json",
        ]
        for name in supportFiles {
            try Data(name.utf8).write(to: supportDirectory.appendingPathComponent(name))
        }
        for directory in [
            supportDirectory.appendingPathComponent("Transcripts", isDirectory: true),
            supportDirectory.appendingPathComponent("AppSkills", isDirectory: true),
        ] + paths.temporaryMediaDirectories + paths.cacheDirectories + paths.cuaArtifactDirectories + [paths.taskWorkspaceDirectory, telemetryDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("seed".utf8).write(to: directory.appendingPathComponent("seed.txt"))
        }

        let suiteName = "PerryCompleteErasureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: "perry.remote.writes.slack")
        defaults.set("state", forKey: "perry.oauth.slack.state")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let keychainService = "dev.perry.tests.complete-erasure.\(UUID().uuidString)"
        let keychain = KeychainStore(service: keychainService)
        let keychainTarget = PerryKeychainEraser.Target(service: keychainService, account: "seed")
        try keychain.save("secret", account: keychainTarget.account)
        defer { try? keychain.deleteChecked(account: keychainTarget.account) }
        let keychainEraser = PerryKeychainEraser(services: [keychainService])

        let coordinator = CompleteErasureCoordinator(
            erasers: PerryLiveErasureErasers.make(
                paths: paths,
                defaults: defaults,
                taskCoordinator: taskCoordinator,
                backgroundTaskContextStore: backgroundTaskContextStore,
                activityLog: activityLog,
                transcriptStore: transcriptStore,
                memoryStore: memoryStore,
                keychainEraser: keychainEraser
            ),
            ownedDataSweeper: PerryOwnedRootSweeper(
                roots: paths.completeErasureRoots
            )
        )

        let before = await coordinator.inventory()
        XCTAssertEqual(Set(before.items.map(\.category)), Set(PerryErasureCategory.allCases))
        XCTAssertTrue(before.failures.isEmpty)

        let report = await coordinator.erase()

        XCTAssertTrue(report.isComplete)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(report.postEraseInventory.items.isEmpty)
        XCTAssertNil(try keychain.readChecked(account: keychainTarget.account))
        XCTAssertFalse(defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("perry.") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.taskWorkspaceDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: telemetryDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: supportDirectory.appendingPathComponent("CodexRuntime").path))
    }

    @MainActor
    func testCompleteErasureRemovesUnregisteredFilesFromOwnedRoots() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerryClosedWorldErasureTests")
            .appendingPathComponent(UUID().uuidString)
        let supportDirectory = root.appendingPathComponent("ApplicationSupport/Perry", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let unknownFile = supportDirectory.appendingPathComponent("future-feature-private-data.bin")
        try Data("private".utf8).write(to: unknownFile)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = PerryErasurePaths(
            supportDirectory: supportDirectory,
            homeDirectory: root.appendingPathComponent("Home", isDirectory: true),
            temporaryDirectory: root.appendingPathComponent("Temporary", isDirectory: true),
            cachesDirectory: root.appendingPathComponent("Caches", isDirectory: true)
        )
        let coordinator = CompleteErasureCoordinator(
            erasers: PerryErasureCategory.allCases.map { category in
                makeEraser(category: category, state: ErasureState(items: []))
            },
            ownedDataSweeper: PerryOwnedRootSweeper(roots: paths.completeErasureRoots)
        )

        let report = await coordinator.erase()

        XCTAssertTrue(report.isComplete)
        XCTAssertTrue(report.residualOwnedPaths.isEmpty)
        XCTAssertTrue(report.ownedDataFailures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unknownFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: supportDirectory.path))
    }

    @MainActor
    func testCategoryErasureDoesNotRunOwnedRootSweep() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerryScopedErasureTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let retained = root.appendingPathComponent("retained.txt")
        try Data("keep".utf8).write(to: retained)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ErasureState(items: [])
        let coordinator = CompleteErasureCoordinator(
            erasers: [makeEraser(category: .history, state: state)],
            ownedDataSweeper: PerryOwnedRootSweeper(roots: [root])
        )

        let report = await coordinator.erase(category: .history)

        XCTAssertTrue(report.isSuccessful)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
    }

    private func makeEraser(
        category: PerryErasureCategory,
        state: ErasureState
    ) -> PerryClosureEraser {
        PerryClosureEraser(
            category: category,
            inventory: { try await state.inventory() },
            erase: { try await state.erase() }
        )
    }
}

private actor ErasureState {
    enum Failure: Error, Equatable {
        case erase
        case inventory
    }

    private var items: Set<PerryErasureItem>
    private let failure: Failure?
    private let clearsItems: Bool
    private let recreatesAfterErase: Bool
    private var erasedItems: Set<PerryErasureItem> = []
    private(set) var eraseCount = 0

    init(
        items: [PerryErasureItem],
        failure: Failure? = nil,
        clearsItems: Bool = true,
        recreatesAfterErase: Bool = false
    ) {
        self.items = Set(items)
        self.failure = failure
        self.clearsItems = clearsItems
        self.recreatesAfterErase = recreatesAfterErase
    }

    func inventory() throws -> [PerryErasureItem] {
        if failure == .inventory {
            throw Failure.inventory
        }
        if recreatesAfterErase, eraseCount > 0, items.isEmpty {
            items = erasedItems
        }
        return items.sorted { $0.id < $1.id }
    }

    func erase() throws {
        eraseCount += 1
        if failure == .erase {
            throw Failure.erase
        }
        if clearsItems {
            erasedItems = items
            items.removeAll()
        }
    }

    var wasErased: Bool {
        eraseCount > 0
    }
}
