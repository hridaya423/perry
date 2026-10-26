import XCTest
@testable import PerryGuide
import PerryCore
import PerryRuntimes

private struct TestMemoryEnvelope: Codable {
    let version: Int
    let configuration: MemoryConfiguration
    let records: [MemoryRecord]
}

private struct TestLegacyMemoryFile: Encodable {
    let configuration: MemoryConfiguration
    let records: [MemoryRecord]
}

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

    func testOffByDefaultRequiresExplicitOptIn() async {
        let store = MemoryStore(storageDirectory: directory)
        let config = await store.currentConfiguration()
        XCTAssertFalse(config.enabled)

        let accepted = await store.remember(MemoryRecord(category: .preference, summary: "sorts by name"))
        let records = await store.snapshot()

        XCTAssertFalse(accepted)
        XCTAssertTrue(records.isEmpty)
    }

    func testOptInPersistsAcrossInstances() async {
        let store = MemoryStore(
            storageDirectory: directory,
            configuration: MemoryConfiguration(enabled: true)
        )

        await store.remember(MemoryRecord(category: .preference, appBundleID: "com.apple.finder", summary: "sorts by name"))
        let reloaded = MemoryStore(storageDirectory: directory)
        let recalled = await reloaded.recall(category: .preference, appBundleID: "com.apple.finder")
        XCTAssertEqual(recalled.map(\.summary), ["sorts by name"])
    }

    func testForgettingOneRecordKeepsTheRestAcrossInstances() async {
        let store = MemoryStore(storageDirectory: directory, configuration: MemoryConfiguration(enabled: true))
        let keep = MemoryRecord(category: .preference, summary: "sorts by name")
        let drop = MemoryRecord(category: .appWorkflow, summary: "exports as PDF")
        await store.remember(keep)
        await store.remember(drop)
        let forgotten = await store.forget(drop.id)
        XCTAssertTrue(forgotten)
        let reloaded = MemoryStore(storageDirectory: directory)
        let records = await reloaded.snapshot()
        XCTAssertEqual(records.map(\.id), [keep.id])
    }

    func testPersistsVersionedEnvelope() async throws {
        let record = MemoryRecord(
            id: UUID(uuidString: "B8E9DD5C-4F72-4EA5-B2A4-EA2B2B50F9BF")!,
            category: .preference,
            summary: "sorts by name",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let store = MemoryStore(storageDirectory: directory, configuration: MemoryConfiguration(enabled: true))
        let accepted = await store.remember(record)
        XCTAssertTrue(accepted)

        let data = try Data(contentsOf: directory.appendingPathComponent("memory.json"))
        let envelope = try JSONDecoder().decode(TestMemoryEnvelope.self, from: data)
        XCTAssertEqual(envelope.version, 1)
        XCTAssertEqual(envelope.records, [record])
    }

    func testUnsupportedVersionIsQuarantinedAndReported() async throws {
        let fileURL = directory.appendingPathComponent("memory.json")
        let unsupportedData = try JSONEncoder().encode(
            TestMemoryEnvelope(
                version: 2,
                configuration: MemoryConfiguration(enabled: true),
                records: []
            )
        )
        try unsupportedData.write(to: fileURL)

        let store = MemoryStore(storageDirectory: directory, configuration: MemoryConfiguration(enabled: true))
        let initialRecords = await store.snapshot()
        XCTAssertTrue(initialRecords.isEmpty)

        let issue = await store.lastPersistenceError
        guard case .recoveredCorruptFile(let path, let quarantinePath, let reason) = issue else {
            return XCTFail("expected unsupported memory version recovery, got \(String(describing: issue))")
        }
        XCTAssertEqual(path, fileURL.path)
        XCTAssertTrue(reason.contains("unsupported memory persistence version 2"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: quarantinePath)), unsupportedData)

        let accepted = await store.remember(MemoryRecord(category: .preference, summary: "after recovery"))
        XCTAssertTrue(accepted)
        let recoveredData = try Data(contentsOf: fileURL)
        let recoveredEnvelope = try JSONDecoder().decode(TestMemoryEnvelope.self, from: recoveredData)
        XCTAssertEqual(recoveredEnvelope.version, 1)
    }

    func testLegacyRawFileLoadsAndMigratesOnNextWrite() async throws {
        let fileURL = directory.appendingPathComponent("memory.json")
        let legacyRecord = MemoryRecord(
            id: UUID(uuidString: "10D7F3B8-43C6-46A8-AD8A-11B4D1C57D4C")!,
            category: .pastSession,
            summary: "renamed the notes",
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let legacyData = try JSONEncoder().encode(
            TestLegacyMemoryFile(configuration: MemoryConfiguration(enabled: true), records: [legacyRecord])
        )
        try legacyData.write(to: fileURL)

        let store = MemoryStore(storageDirectory: directory, configuration: MemoryConfiguration(enabled: true))
        let loadedRecords = await store.snapshot()
        XCTAssertEqual(loadedRecords, [legacyRecord])

        let accepted = await store.remember(MemoryRecord(category: .preference, summary: "prefers concise replies"))
        XCTAssertTrue(accepted)
        let migratedData = try Data(contentsOf: fileURL)
        let migratedEnvelope = try JSONDecoder().decode(TestMemoryEnvelope.self, from: migratedData)
        XCTAssertEqual(migratedEnvelope.version, 1)
        XCTAssertEqual(migratedEnvelope.records.map(\.summary), [legacyRecord.summary, "prefers concise replies"])
    }

    func testCorruptFileIsQuarantinedAndReported() async throws {
        let fileURL = directory.appendingPathComponent("memory.json")
        let corruptData = Data("{ not valid json".utf8)
        try corruptData.write(to: fileURL)

        let store = MemoryStore(storageDirectory: directory, configuration: MemoryConfiguration(enabled: true))
        let initialRecords = await store.snapshot()
        XCTAssertTrue(initialRecords.isEmpty)
        let issue = await store.lastPersistenceError

        guard case .recoveredCorruptFile(let path, let quarantinePath, _) = issue else {
            return XCTFail("expected corrupt memory recovery, got \(String(describing: issue))")
        }
        XCTAssertEqual(path, fileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: quarantinePath)), corruptData)

        let remembered = await store.remember(MemoryRecord(category: .preference, summary: "recovered memory"))
        XCTAssertTrue(remembered)
        let reloaded = MemoryStore(storageDirectory: directory)
        let reloadedRecords = await reloaded.snapshot()
        XCTAssertEqual(reloadedRecords.map(\.summary), ["recovered memory"])
    }

    func testCorruptPrimaryRestoresTheLastValidMemoryBackup() async throws {
        let first = MemoryRecord(
            category: .preference,
            summary: "first memory",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let second = MemoryRecord(
            category: .pastSession,
            summary: "second memory",
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let store = MemoryStore(storageDirectory: directory, configuration: MemoryConfiguration(enabled: true))
        let rememberedFirst = await store.remember(first)
        let rememberedSecond = await store.remember(second)
        XCTAssertTrue(rememberedFirst)
        XCTAssertTrue(rememberedSecond)
        let fileURL = directory.appendingPathComponent("memory.json")
        let backupURL = fileURL.appendingPathExtension("backup")
        let backupData = try Data(contentsOf: backupURL)
        let corruptData = Data("truncated-memory".utf8)
        try corruptData.write(to: fileURL)

        let recovered = MemoryStore(storageDirectory: directory)

        let records = await recovered.snapshot()
        XCTAssertEqual(records, [first])
        XCTAssertEqual(try Data(contentsOf: fileURL), backupData)
        guard case .recoveredCorruptFile(_, let quarantinePath, _) = await recovered.lastPersistenceError else {
            return XCTFail("expected primary corruption to remain visible")
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: quarantinePath)), corruptData)
    }

    func testWriteFailureIsReportedAndDoesNotCommitRecord() async throws {
        let blockedDirectory = directory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blockedDirectory)

        let store = MemoryStore(storageDirectory: blockedDirectory, configuration: MemoryConfiguration(enabled: true))
        let remembered = await store.remember(MemoryRecord(category: .preference, summary: "not persisted"))
        XCTAssertFalse(remembered)
        let records = await store.snapshot()
        XCTAssertTrue(records.isEmpty)
        let issue = await store.lastPersistenceError

        guard case .createDirectoryFailed(let path, _) = issue else {
            return XCTFail("expected memory write failure, got \(String(describing: issue))")
        }
        XCTAssertEqual(path, blockedDirectory.path)
    }

    func testFirstWriteCreatesStorageDirectoryBeforePersisting() async {
        let freshDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-memory-fresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: freshDirectory) }

        let store = MemoryStore(storageDirectory: freshDirectory, configuration: MemoryConfiguration(enabled: true))
        _ = await store.remember(MemoryRecord(category: .preference, summary: "prefers concise replies"))

        let reloaded = MemoryStore(storageDirectory: freshDirectory)
        let recalled = await reloaded.recall(category: .preference, appBundleID: nil)
        XCTAssertEqual(recalled.map(\.summary), ["prefers concise replies"])
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

    func testDisablingCategoryStopsExistingRecordsFromBeingRecalled() async {
        let store = MemoryStore(storageDirectory: nil, configuration: MemoryConfiguration(enabled: true))
        _ = await store.remember(MemoryRecord(category: .preference, summary: "prefers compact windows"))

        var configuration = await store.currentConfiguration()
        configuration.categoryToggles[.preference] = false
        await store.setConfiguration(configuration)

        let recalled = await store.recall(category: .preference, appBundleID: nil)
        let context = await store.promptContext(appBundleID: nil)
        XCTAssertTrue(recalled.isEmpty)
        XCTAssertNil(context)
    }

    func testGoldfishModeRecallsNothing() async {
        let store = MemoryStore(storageDirectory: nil, configuration: .goldfish)
        _ = await store.remember(MemoryRecord(category: .pastSession, summary: "anything"))
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
        let recalled = await store.recall(category: nil, appBundleID: nil)
        XCTAssertTrue(recalled.isEmpty)
    }

    func testPromptContextIsLocalAndOrdered() async {
        let store = MemoryStore(storageDirectory: nil, configuration: MemoryConfiguration(enabled: true))
        _ = await store.remember(MemoryRecord(category: .preference, appBundleID: "com.apple.finder", summary: "sort by name"))
        _ = await store.remember(MemoryRecord(category: .pastSession, summary: "renamed the notes"))

        let context = await store.promptContext(appBundleID: "com.apple.finder")

        XCTAssertEqual(context, "- [preference · com.apple.finder] sort by name\n- [pastSession] renamed the notes")
    }

    func testWipeClearsEverythingIncludingDisk() async {
        let store = MemoryStore(storageDirectory: directory, configuration: MemoryConfiguration(enabled: true))
        _ = await store.remember(MemoryRecord(category: .preference, summary: "dark mode always"))
        await store.wipe()

        let reloaded = MemoryStore(storageDirectory: directory)
        let afterWipe = await reloaded.snapshot()
        XCTAssertTrue(afterWipe.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("PROFILE.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("VOLATILE.md").path))
    }

    func testMemoryWritesInspectableProfileAndVolatileMarkdown() async throws {
        let store = MemoryStore(storageDirectory: directory, configuration: MemoryConfiguration(enabled: true))
        _ = await store.remember(MemoryRecord(category: .preference, summary: "prefers compact replies"))
        _ = await store.remember(MemoryRecord(category: .appWorkflow, appBundleID: "com.apple.finder", summary: "uses the Finder tags toolbar"))

        let profile = try String(contentsOf: directory.appendingPathComponent("PROFILE.md"), encoding: .utf8)
        let volatile = try String(contentsOf: directory.appendingPathComponent("VOLATILE.md"), encoding: .utf8)
        XCTAssertTrue(profile.contains("prefers compact replies"))
        XCTAssertTrue(volatile.contains("uses the Finder tags toolbar"))
    }
}
