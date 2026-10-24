import XCTest
@testable import PerryCore

final class ActivityLogTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-activity-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        super.tearDown()
    }

    func testRecordPersistsAcrossInstances() async throws {
        let log = ActivityLog(storageDirectory: tempDirectory)
        await log.record(
            ActivityEntry(
                actionSummary: "renamed 3 files in Finder",
                targetAppBundleID: "com.apple.finder",
                tier: .yellow,
                outcome: .allowed,
                reversible: true
            )
        )
        let fileURL = tempDirectory.appendingPathComponent("activity-log.json")
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertEqual(persisted["version"] as? Int, 1)
        XCTAssertEqual((persisted["entries"] as? [[String: Any]])?.count, 1)

        let reloaded = ActivityLog(storageDirectory: tempDirectory)
        let snapshot = await reloaded.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.actionSummary, "renamed 3 files in Finder")
        XCTAssertEqual(snapshot.first?.tier, .yellow)
    }

    func testCorruptFileIsQuarantinedAndReported() async throws {
        let fileURL = tempDirectory.appendingPathComponent("activity-log.json")
        let corruptData = Data("{ not valid json".utf8)
        try corruptData.write(to: fileURL)

        let log = ActivityLog(storageDirectory: tempDirectory)
        let initialEntries = await log.snapshot()
        XCTAssertTrue(initialEntries.isEmpty)
        let issue = await log.lastPersistenceError

        guard case .recoveredCorruptFile(let path, let quarantinePath, _) = issue else {
            return XCTFail("expected corrupt activity log recovery, got \(String(describing: issue))")
        }
        XCTAssertEqual(path, fileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: quarantinePath)), corruptData)

        let recorded = await log.record(ActivityEntry(actionSummary: "recovered record", targetAppBundleID: nil, tier: .green, outcome: .allowed, reversible: true))
        XCTAssertTrue(recorded)
        let reloaded = ActivityLog(storageDirectory: tempDirectory)
        let reloadedEntries = await reloaded.snapshot()
        XCTAssertEqual(reloadedEntries.map(\.actionSummary), ["recovered record"])
    }

    func testUnsupportedVersionIsQuarantinedAndCanBeReplaced() async throws {
        let fileURL = tempDirectory.appendingPathComponent("activity-log.json")
        let unsupportedData = Data(#"{"version":99,"entries":[]}"#.utf8)
        try unsupportedData.write(to: fileURL)

        let log = ActivityLog(storageDirectory: tempDirectory)
        let initialEntries = await log.snapshot()
        XCTAssertTrue(initialEntries.isEmpty)
        let issue = await log.lastPersistenceError

        guard case .recoveredCorruptFile(let path, let quarantinePath, let reason) = issue else {
            return XCTFail("expected unsupported activity log recovery, got \(String(describing: issue))")
        }
        XCTAssertEqual(path, fileURL.path)
        XCTAssertTrue(reason.contains("unsupported activity log persistence version 99"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: quarantinePath)), unsupportedData)

        let recorded = await log.record(
            ActivityEntry(
                actionSummary: "replaced unsupported state",
                targetAppBundleID: nil,
                tier: .green,
                outcome: .allowed,
                reversible: true
            )
        )
        XCTAssertTrue(recorded)
        let replacement = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertEqual(replacement["version"] as? Int, 1)

        let reloaded = ActivityLog(storageDirectory: tempDirectory)
        let reloadedEntries = await reloaded.snapshot()
        XCTAssertEqual(reloadedEntries.map(\.actionSummary), ["replaced unsupported state"])
    }

    func testLegacyArrayLoadsAndMigratesOnNextWrite() async throws {
        let fileURL = tempDirectory.appendingPathComponent("activity-log.json")
        let legacyEntry = ActivityEntry(
            actionSummary: "legacy entry",
            targetAppBundleID: nil,
            tier: .green,
            outcome: .allowed,
            reversible: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([legacyEntry]).write(to: fileURL)

        let log = ActivityLog(storageDirectory: tempDirectory)
        let loaded = await log.snapshot()
        XCTAssertEqual(loaded.map(\.actionSummary), [legacyEntry.actionSummary])
        XCTAssertEqual(loaded.map(\.tier), [legacyEntry.tier])
        let recorded = await log.record(
            ActivityEntry(
                actionSummary: "new entry",
                targetAppBundleID: nil,
                tier: .green,
                outcome: .allowed,
                reversible: true
            )
        )
        XCTAssertTrue(recorded)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual((object["entries"] as? [[String: Any]])?.count, 2)
    }

    func testInterruptedEnvelopeIsQuarantinedWithoutOverwritingRecovery() async throws {
        let originalEntry = ActivityEntry(
            actionSummary: "original activity",
            targetAppBundleID: nil,
            tier: .green,
            outcome: .allowed,
            reversible: true
        )
        let log = ActivityLog(storageDirectory: tempDirectory)
        let recordedOriginal = await log.record(originalEntry)
        XCTAssertTrue(recordedOriginal)

        let fileURL = tempDirectory.appendingPathComponent("activity-log.json")
        let persistedData = try Data(contentsOf: fileURL)
        let interruptedData = Data(persistedData.prefix(max(1, persistedData.count / 2)))
        try interruptedData.write(to: fileURL)

        let reloaded = ActivityLog(storageDirectory: tempDirectory)
        let initialEntries = await reloaded.snapshot()
        XCTAssertTrue(initialEntries.isEmpty)
        let issue = await reloaded.lastPersistenceError

        guard case .recoveredCorruptFile(let path, let quarantinePath, _) = issue else {
            return XCTFail("expected interrupted activity recovery, got \(String(describing: issue))")
        }
        XCTAssertEqual(path, fileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: quarantinePath)), interruptedData)

        let recoveredEntry = ActivityEntry(
            actionSummary: "recovered activity",
            targetAppBundleID: nil,
            tier: .green,
            outcome: .allowed,
            reversible: true
        )
        let recordedRecovery = await reloaded.record(recoveredEntry)
        XCTAssertTrue(recordedRecovery)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: quarantinePath)), interruptedData)
    }

    func testCorruptPrimaryRestoresTheLastValidActivityBackup() async throws {
        let first = ActivityEntry(
            actionSummary: "first activity",
            targetAppBundleID: nil,
            tier: .green,
            outcome: .allowed,
            reversible: true
        )
        let second = ActivityEntry(
            actionSummary: "second activity",
            targetAppBundleID: nil,
            tier: .green,
            outcome: .allowed,
            reversible: true
        )
        let log = ActivityLog(storageDirectory: tempDirectory)
        let recordedFirst = await log.record(first)
        let recordedSecond = await log.record(second)
        XCTAssertTrue(recordedFirst)
        XCTAssertTrue(recordedSecond)
        let fileURL = tempDirectory.appendingPathComponent("activity-log.json")
        let backupURL = fileURL.appendingPathExtension("backup")
        let backupData = try Data(contentsOf: backupURL)
        let corruptData = Data("truncated-activity".utf8)
        try corruptData.write(to: fileURL)

        let recovered = ActivityLog(storageDirectory: tempDirectory)

        let entries = await recovered.snapshot()
        XCTAssertEqual(entries.map(\.actionSummary), [first.actionSummary])
        XCTAssertEqual(try Data(contentsOf: fileURL), backupData)
        guard case .recoveredCorruptFile(_, let quarantinePath, _) = await recovered.lastPersistenceError else {
            return XCTFail("expected primary corruption to remain visible")
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: quarantinePath)), corruptData)
    }

    func testCorruptPrimaryRestoresLegacyActivityBackup() async throws {
        let entry = ActivityEntry(
            actionSummary: "legacy backup",
            targetAppBundleID: nil,
            tier: .green,
            outcome: .allowed,
            reversible: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyData = try encoder.encode([entry])
        let fileURL = tempDirectory.appendingPathComponent("activity-log.json")
        let backupURL = fileURL.appendingPathExtension("backup")
        try Data("corrupt primary".utf8).write(to: fileURL)
        try legacyData.write(to: backupURL)

        let recovered = ActivityLog(storageDirectory: tempDirectory)
        let snapshot = await recovered.snapshot()

        XCTAssertEqual(snapshot.map(\.actionSummary), ["legacy backup"])
        XCTAssertEqual(try Data(contentsOf: fileURL), legacyData)
    }

    func testFailedQuarantineBlocksOverwriteOfCorruptFile() async throws {
        let fileURL = tempDirectory.appendingPathComponent("activity-log.json")
        let corruptData = Data("not valid activity log".utf8)
        try corruptData.write(to: fileURL)

        let log = ActivityLog(storageDirectory: tempDirectory, fileManager: RejectingMoveFileManager())
        let initialEntries = await log.snapshot()
        XCTAssertTrue(initialEntries.isEmpty)
        guard case .quarantineFailed(let path, _) = await log.lastPersistenceError else {
            return XCTFail("expected activity log quarantine failure")
        }
        XCTAssertEqual(path, fileURL.path)

        let recorded = await log.record(
            ActivityEntry(
                actionSummary: "must not overwrite",
                targetAppBundleID: nil,
                tier: .green,
                outcome: .allowed,
                reversible: true
            )
        )
        XCTAssertFalse(recorded)
        let entries = await log.snapshot()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fileURL), corruptData)
    }

    func testWriteFailureIsReportedAndDoesNotCommitRecord() async throws {
        let blockedDirectory = tempDirectory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blockedDirectory)

        let log = ActivityLog(storageDirectory: blockedDirectory)
        let recorded = await log.record(ActivityEntry(actionSummary: "not persisted", targetAppBundleID: nil, tier: .green, outcome: .allowed, reversible: true))
        XCTAssertFalse(recorded)
        let entries = await log.snapshot()
        XCTAssertTrue(entries.isEmpty)
        let issue = await log.lastPersistenceError

        guard case .createDirectoryFailed(let path, _) = issue else {
            return XCTFail("expected activity log write failure, got \(String(describing: issue))")
        }
        XCTAssertEqual(path, blockedDirectory.path)
    }

    func testFirstRecordCreatesStorageDirectoryBeforePersisting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-activity-fresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = ActivityLog(storageDirectory: directory)
        await log.record(ActivityEntry(actionSummary: "first record", targetAppBundleID: nil, tier: .green, outcome: .allowed, reversible: true))

        let reloaded = ActivityLog(storageDirectory: directory)
        let snapshot = await reloaded.snapshot()
        XCTAssertEqual(snapshot.map(\.actionSummary), ["first record"])
    }

    func testExportProducesReadableJSON() async throws {
        let log = ActivityLog(storageDirectory: tempDirectory)
        await log.record(
            ActivityEntry(
                actionSummary: "moved files to Trash",
                targetAppBundleID: "com.apple.finder",
                tier: .orange,
                outcome: .confirmed,
                reversible: false
            )
        )
        let data = try await log.exportData()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(json.count, 1)
        XCTAssertEqual(json[0]["actionSummary"] as? String, "moved files to Trash")
        XCTAssertEqual(json[0]["outcome"] as? String, "confirmed")
    }

    func testWipeClearsEntriesAndFile() async throws {
        let log = ActivityLog(storageDirectory: tempDirectory)
        await log.record(
            ActivityEntry(
                actionSummary: "typed text",
                targetAppBundleID: "com.apple.TextEdit",
                tier: .yellow,
                outcome: .allowed,
                reversible: true
            )
        )
        await log.wipe()
        let snapshot = await log.snapshot()
        XCTAssertTrue(snapshot.isEmpty)

        let reloaded = ActivityLog(storageDirectory: tempDirectory)
        let afterWipe = await reloaded.snapshot()
        XCTAssertTrue(afterWipe.isEmpty)
    }
}

private final class RejectingMoveFileManager: FileManager {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw NSError(domain: "ActivityLogTests", code: 1)
    }
}
