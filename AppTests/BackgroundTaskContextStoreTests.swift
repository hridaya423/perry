import XCTest
import PerryGuide
import PerryRuntimes
@testable import Perry

final class BackgroundTaskContextStoreTests: XCTestCase {
    func testPersistsVersionedEnvelopeAndReloads() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = TaskID()
        let metadata = BackgroundTaskMetadata(
            targetAppBundleID: "com.apple.finder",
            workspacePath: "/tmp/work",
            runtimeRoutingSummary: "Selected cli.opencode."
        )
        let store = BackgroundTaskContextStore(storageDirectory: directory)

        try await store.save(metadata, for: id)

        let data = try Data(contentsOf: directory.appendingPathComponent("background-task-context.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let reloaded = BackgroundTaskContextStore(storageDirectory: directory)
        let saved = await reloaded.metadata(for: id)
        XCTAssertEqual(saved, metadata)
    }

    func testMigratesLegacyDictionaryWithoutLosingValues() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = TaskID()
        let metadata = BackgroundTaskMetadata(targetWindowTitle: "Downloads")
        let fileURL = directory.appendingPathComponent("background-task-context.json")
        try JSONEncoder().encode([id: metadata]).write(to: fileURL)

        let store = BackgroundTaskContextStore(storageDirectory: directory)

        let saved = await store.metadata(for: id)
        XCTAssertEqual(saved, metadata)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
    }

    func testCorruptFileIsQuarantinedBeforeNewStateIsWritten() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("background-task-context.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: fileURL)

        let store = BackgroundTaskContextStore(storageDirectory: directory)
        try await store.save(BackgroundTaskMetadata(), for: TaskID())

        let quarantined = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("background-task-context.quarantined-") }
        let quarantinedURL = try XCTUnwrap(quarantined)
        XCTAssertEqual(try Data(contentsOf: quarantinedURL), corrupt)
    }

    func testUnsupportedVersionIsQuarantined() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("background-task-context.json")
        try Data(#"{"schemaVersion":99,"values":{}}"#.utf8).write(to: fileURL)

        let store = BackgroundTaskContextStore(storageDirectory: directory)

        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("background-task-context.quarantined-") })
    }

    func testRestoresValidBackupAfterPrimaryFileIsCorrupted() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = TaskID()
        let metadata = BackgroundTaskMetadata(targetWindowTitle: "Downloads")
        let fileURL = directory.appendingPathComponent("background-task-context.json")
        let backupURL = fileURL.appendingPathExtension("backup")
        let source = BackgroundTaskContextStore(storageDirectory: directory)
        try await source.save(metadata, for: id)
        try FileManager.default.copyItem(at: fileURL, to: backupURL)
        let damagedData = Data("damaged-primary".utf8)
        try damagedData.write(to: fileURL)

        let recovered = BackgroundTaskContextStore(storageDirectory: directory)

        let recoveredMetadata = await recovered.metadata(for: id)
        let recovery = await recovered.recoveryDisposition()
        XCTAssertEqual(recoveredMetadata, metadata)
        XCTAssertEqual(recovery, .restoredBackup)
        XCTAssertEqual(try Data(contentsOf: fileURL), try Data(contentsOf: backupURL))
        let quarantinedURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix("background-task-context.quarantined-") }
        )
        XCTAssertEqual(try Data(contentsOf: quarantinedURL), damagedData)
    }

    func testQuarantinesInvalidPrimaryAndBackupWithoutOverwritingEither() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("background-task-context.json")
        let backupURL = fileURL.appendingPathExtension("backup")
        let primaryData = Data("damaged-primary".utf8)
        let backupData = Data("damaged-backup".utf8)
        try primaryData.write(to: fileURL)
        try backupData.write(to: backupURL)

        let store = BackgroundTaskContextStore(storageDirectory: directory)

        let snapshot = await store.snapshot()
        let recovery = await store.recoveryDisposition()
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(recovery, .quarantinedUnrecoverableFile)
        let quarantined = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("quarantined-") }
        XCTAssertEqual(quarantined.count, 2)
        let preserved = try Set(quarantined.map { try Data(contentsOf: $0) })
        XCTAssertEqual(preserved, Set([primaryData, backupData]))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
