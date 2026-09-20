import XCTest
@testable import PerryCore

final class TranscriptStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-transcript-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        super.tearDown()
    }

    func testAppendSurvivesReloadAndSearch() async throws {
        let started = Date(timeIntervalSince1970: 1_724_700_000)
        let finished = started.addingTimeInterval(8)
        let entry = TranscriptEntry(
            sessionID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            request: "rename a file",
            appBundleID: "com.apple.finder",
            summary: "Renamed one file and verified it.",
            outcome: .completed,
            startedAt: started,
            finishedAt: finished,
            steps: ["rename notes.txt"],
            verified: true
        )

        let store = TranscriptStore(directory: directory)
        await store.append(entry)

        let reloaded = TranscriptStore(directory: directory)
        let matches = await reloaded.search("finder")

        XCTAssertEqual(matches, [entry])
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Transcripts").path)
            .filter { $0.hasSuffix(".md") }
        XCTAssertEqual(files.count, 1)
        let markdown = try String(contentsOf: directory.appendingPathComponent("Transcripts").appendingPathComponent(files[0]), encoding: .utf8)
        XCTAssertTrue(markdown.contains("rename a file"))
        XCTAssertTrue(markdown.contains("verified"))
    }

    func testAppendWritesVersionedIndexEnvelope() async throws {
        let entry = TranscriptEntry(
            request: "persist the envelope",
            appBundleID: nil,
            summary: "Persisted.",
            outcome: .completed,
            startedAt: Date(timeIntervalSince1970: 1_724_700_000),
            finishedAt: Date(timeIntervalSince1970: 1_724_700_001),
            steps: [],
            verified: nil
        )
        let store = TranscriptStore(directory: directory)
        let appended = await store.append(entry)
        XCTAssertTrue(appended)

        let indexURL = directory.appendingPathComponent("Transcripts/index.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual((object["entries"] as? [[String: Any]])?.count, 1)
    }

    func testCorruptIndexIsQuarantinedAndReported() async throws {
        let transcriptsDirectory = directory.appendingPathComponent("Transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptsDirectory, withIntermediateDirectories: true)
        let indexURL = transcriptsDirectory.appendingPathComponent("index.json")
        let corruptData = Data("{ not valid json".utf8)
        try corruptData.write(to: indexURL)

        let store = TranscriptStore(directory: directory)
        let initialEntries = await store.snapshot()
        XCTAssertTrue(initialEntries.isEmpty)
        let issue = await store.lastPersistenceError

        guard case .recoveredCorruptFile(let path, let quarantinePath, _) = issue else {
            return XCTFail("expected corrupt transcript index recovery, got \(String(describing: issue))")
        }
        XCTAssertEqual(path, indexURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: quarantinePath)), corruptData)

        let entry = TranscriptEntry(
            request: "recovered transcript",
            appBundleID: nil,
            summary: "Recovered.",
            outcome: .completed,
            startedAt: Date(timeIntervalSince1970: 1_724_700_000),
            finishedAt: Date(timeIntervalSince1970: 1_724_700_001),
            steps: [],
            verified: nil
        )
        let appended = await store.append(entry)
        XCTAssertTrue(appended)
        let reloaded = TranscriptStore(directory: directory)
        let reloadedEntries = await reloaded.snapshot()
        XCTAssertEqual(reloadedEntries, [entry])
    }

    func testUnsupportedIndexVersionIsQuarantinedAndCanBeReplaced() async throws {
        let transcriptsDirectory = directory.appendingPathComponent("Transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptsDirectory, withIntermediateDirectories: true)
        let indexURL = transcriptsDirectory.appendingPathComponent("index.json")
        let unsupportedData = Data(#"{"version":99,"entries":[]}"#.utf8)
        try unsupportedData.write(to: indexURL)

        let store = TranscriptStore(directory: directory)
        let initialEntries = await store.snapshot()
        XCTAssertTrue(initialEntries.isEmpty)

        let issue = await store.lastPersistenceError
        guard case .recoveredCorruptFile(let path, let quarantinePath, let reason) = issue else {
            return XCTFail("expected unsupported transcript version recovery, got \(String(describing: issue))")
        }
        XCTAssertEqual(path, indexURL.path)
        XCTAssertTrue(reason.contains("unsupported transcript persistence version 99"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: quarantinePath)), unsupportedData)

        let entry = TranscriptEntry(
            request: "replace unsupported data",
            appBundleID: nil,
            summary: "Replaced.",
            outcome: .completed,
            startedAt: Date(timeIntervalSince1970: 1_724_700_000),
            finishedAt: Date(timeIntervalSince1970: 1_724_700_001),
            steps: [],
            verified: nil
        )
        let appended = await store.append(entry)
        XCTAssertTrue(appended)
        let entries = await store.snapshot()
        XCTAssertEqual(entries, [entry])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: quarantinePath)), unsupportedData)
    }

    func testInterruptedIndexIsQuarantinedWithoutOverwritingRecovery() async throws {
        let originalEntry = TranscriptEntry(
            request: "original transcript",
            appBundleID: nil,
            summary: "Original.",
            outcome: .completed,
            startedAt: Date(timeIntervalSince1970: 1_724_700_000),
            finishedAt: Date(timeIntervalSince1970: 1_724_700_001),
            steps: [],
            verified: nil
        )
        let store = TranscriptStore(directory: directory)
        let appended = await store.append(originalEntry)
        XCTAssertTrue(appended)

        let indexURL = directory.appendingPathComponent("Transcripts/index.json")
        let persistedData = try Data(contentsOf: indexURL)
        let interruptedData = Data(persistedData.prefix(max(1, persistedData.count / 2)))
        try interruptedData.write(to: indexURL)

        let reloaded = TranscriptStore(directory: directory)
        let initialEntries = await reloaded.snapshot()
        XCTAssertTrue(initialEntries.isEmpty)
        let issue = await reloaded.lastPersistenceError
        guard case .recoveredCorruptFile(let path, let quarantinePath, _) = issue else {
            return XCTFail("expected interrupted transcript recovery, got \(String(describing: issue))")
        }
        XCTAssertEqual(path, indexURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: quarantinePath)), interruptedData)

        let recoveredEntry = TranscriptEntry(
            request: "recovered transcript",
            appBundleID: nil,
            summary: "Recovered.",
            outcome: .completed,
            startedAt: Date(timeIntervalSince1970: 1_724_700_002),
            finishedAt: Date(timeIntervalSince1970: 1_724_700_003),
            steps: [],
            verified: nil
        )
        let recovered = await reloaded.append(recoveredEntry)
        XCTAssertTrue(recovered)
        let entries = await reloaded.snapshot()
        XCTAssertEqual(entries, [recoveredEntry])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: quarantinePath)), interruptedData)
    }

    func testCorruptPrimaryRestoresTheLastValidTranscriptBackup() async throws {
        let first = TranscriptEntry(
            request: "first transcript",
            appBundleID: nil,
            summary: "First.",
            outcome: .completed,
            startedAt: Date(timeIntervalSince1970: 1_724_700_000),
            finishedAt: Date(timeIntervalSince1970: 1_724_700_001),
            steps: [],
            verified: nil
        )
        let second = TranscriptEntry(
            request: "second transcript",
            appBundleID: nil,
            summary: "Second.",
            outcome: .completed,
            startedAt: Date(timeIntervalSince1970: 1_724_700_002),
            finishedAt: Date(timeIntervalSince1970: 1_724_700_003),
            steps: [],
            verified: nil
        )
        let store = TranscriptStore(directory: directory)
        let appendedFirst = await store.append(first)
        let appendedSecond = await store.append(second)
        XCTAssertTrue(appendedFirst)
        XCTAssertTrue(appendedSecond)
        let indexURL = directory.appendingPathComponent("Transcripts/index.json")
        let backupURL = indexURL.appendingPathExtension("backup")
        let backupData = try Data(contentsOf: backupURL)
        let corruptData = Data("truncated-transcript".utf8)
        try corruptData.write(to: indexURL)

        let recovered = TranscriptStore(directory: directory)

        let entries = await recovered.snapshot()
        XCTAssertEqual(entries, [first])
        XCTAssertEqual(try Data(contentsOf: indexURL), backupData)
        guard case .recoveredCorruptFile(_, let quarantinePath, _) = await recovered.lastPersistenceError else {
            return XCTFail("expected primary corruption to remain visible")
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: quarantinePath)), corruptData)
    }

    func testFailedQuarantineBlocksOverwriteOfCorruptIndex() async throws {
        let transcriptsDirectory = directory.appendingPathComponent("Transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptsDirectory, withIntermediateDirectories: true)
        let indexURL = transcriptsDirectory.appendingPathComponent("index.json")
        let corruptData = Data("{ not valid json".utf8)
        try corruptData.write(to: indexURL)

        let store = TranscriptStore(directory: directory, fileManager: RejectingMoveFileManager())
        let initialEntries = await store.snapshot()
        XCTAssertTrue(initialEntries.isEmpty)
        guard case .quarantineFailed(let path, _) = await store.lastPersistenceError else {
            return XCTFail("expected quarantine failure")
        }
        XCTAssertEqual(path, indexURL.path)

        let entry = TranscriptEntry(
            request: "must not overwrite",
            appBundleID: nil,
            summary: "Blocked.",
            outcome: .completed,
            startedAt: Date(timeIntervalSince1970: 1_724_700_000),
            finishedAt: Date(timeIntervalSince1970: 1_724_700_001),
            steps: [],
            verified: nil
        )
        let appended = await store.append(entry)
        XCTAssertFalse(appended)
        let entries = await store.snapshot()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: indexURL), corruptData)
    }

    func testWriteFailureIsReportedAndDoesNotCommitEntry() async throws {
        let transcriptsPath = directory.appendingPathComponent("Transcripts")
        try Data("not a directory".utf8).write(to: transcriptsPath)

        let store = TranscriptStore(directory: directory)
        let entry = TranscriptEntry(
            request: "not persisted",
            appBundleID: nil,
            summary: "Not persisted.",
            outcome: .completed,
            startedAt: Date(timeIntervalSince1970: 1_724_700_000),
            finishedAt: Date(timeIntervalSince1970: 1_724_700_001),
            steps: [],
            verified: nil
        )

        let appended = await store.append(entry)
        XCTAssertFalse(appended)
        let entries = await store.snapshot()
        XCTAssertTrue(entries.isEmpty)
        let issue = await store.lastPersistenceError

        guard case .createDirectoryFailed(let path, _) = issue else {
            return XCTFail("expected transcript write failure, got \(String(describing: issue))")
        }
        XCTAssertEqual(path, transcriptsPath.path)
    }

    func testDeleteRemovesEntryFromIndexAndDayFile() async throws {
        let day = Date(timeIntervalSince1970: 1_724_700_000)
        let doomed = TranscriptEntry(
            request: "delete this transcript",
            appBundleID: nil,
            summary: "Doomed.",
            outcome: .failed,
            startedAt: day,
            finishedAt: day.addingTimeInterval(1),
            steps: ["secret step"],
            verified: nil
        )
        let survivor = TranscriptEntry(
            request: "keep this transcript",
            appBundleID: nil,
            summary: "Survives.",
            outcome: .completed,
            startedAt: day,
            finishedAt: day.addingTimeInterval(2),
            steps: [],
            verified: true
        )
        let store = TranscriptStore(directory: directory)
        await store.append(doomed)
        await store.append(survivor)

        let deleted = await store.delete([doomed.id])
        XCTAssertTrue(deleted)
        let remaining = await store.snapshot()
        XCTAssertEqual(remaining, [survivor])

        let transcriptsDirectory = directory.appendingPathComponent("Transcripts")
        let files = try FileManager.default.contentsOfDirectory(atPath: transcriptsDirectory.path)
            .filter { $0.hasSuffix(".md") }
        XCTAssertEqual(files.count, 1)
        let markdown = try String(
            contentsOf: transcriptsDirectory.appendingPathComponent(files[0]), encoding: .utf8
        )
        XCTAssertFalse(markdown.contains("delete this transcript"))
        XCTAssertFalse(markdown.contains("secret step"))
        XCTAssertFalse(markdown.contains(doomed.id.uuidString))
        XCTAssertTrue(markdown.contains("keep this transcript"))

        let reloaded = TranscriptStore(directory: directory)
        let reloadedEntries = await reloaded.snapshot()
        XCTAssertEqual(reloadedEntries, [survivor])
    }

    func testDeleteRemovesDayFileWhenNoEntriesRemain() async throws {
        let entry = TranscriptEntry(
            request: "only transcript",
            appBundleID: nil,
            summary: "Alone.",
            outcome: .completed,
            startedAt: Date(timeIntervalSince1970: 1_724_700_000),
            finishedAt: Date(timeIntervalSince1970: 1_724_700_001),
            steps: [],
            verified: nil
        )
        let store = TranscriptStore(directory: directory)
        await store.append(entry)

        let deleted = await store.delete([entry.id])
        XCTAssertTrue(deleted)
        let empty = await store.snapshot()
        XCTAssertTrue(empty.isEmpty)

        let transcriptsDirectory = directory.appendingPathComponent("Transcripts")
        let markdownFiles = try FileManager.default.contentsOfDirectory(atPath: transcriptsDirectory.path)
            .filter { $0.hasSuffix(".md") }
        XCTAssertTrue(markdownFiles.isEmpty)
    }

    func testDeleteKeepsEntriesAndDayFilesFromOtherDays() async throws {
        let firstDay = Date(timeIntervalSince1970: 1_724_700_000)
        let secondDay = Date(timeIntervalSince1970: 1_724_800_000)
        let doomed = TranscriptEntry(
            request: "first day transcript",
            appBundleID: nil,
            summary: "Day one.",
            outcome: .stopped,
            startedAt: firstDay,
            finishedAt: firstDay.addingTimeInterval(1),
            steps: [],
            verified: nil
        )
        let survivor = TranscriptEntry(
            request: "second day transcript",
            appBundleID: nil,
            summary: "Day two.",
            outcome: .completed,
            startedAt: secondDay,
            finishedAt: secondDay.addingTimeInterval(1),
            steps: [],
            verified: nil
        )
        let store = TranscriptStore(directory: directory)
        await store.append(doomed)
        await store.append(survivor)

        let deleted = await store.delete([doomed.id])
        XCTAssertTrue(deleted)
        let remaining = await store.snapshot()
        XCTAssertEqual(remaining, [survivor])

        let transcriptsDirectory = directory.appendingPathComponent("Transcripts")
        let markdown = try FileManager.default.contentsOfDirectory(atPath: transcriptsDirectory.path)
            .filter { $0.hasSuffix(".md") }
            .map { try String(contentsOf: transcriptsDirectory.appendingPathComponent($0), encoding: .utf8) }
        XCTAssertEqual(markdown.count, 1)
        XCTAssertTrue(markdown[0].contains("second day transcript"))
    }

    func testDeleteUnknownIDsIsANoOp() async throws {
        let entry = TranscriptEntry(
            request: "still here",
            appBundleID: nil,
            summary: "Untouched.",
            outcome: .completed,
            startedAt: Date(timeIntervalSince1970: 1_724_700_000),
            finishedAt: Date(timeIntervalSince1970: 1_724_700_001),
            steps: [],
            verified: nil
        )
        let store = TranscriptStore(directory: directory)
        await store.append(entry)

        let deleted = await store.delete([UUID()])
        XCTAssertTrue(deleted)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot, [entry])
    }

    func testDeleteFailureKeepsEntriesVisibleForRetry() async throws {
        let entry = TranscriptEntry(
            request: "cannot delete yet",
            appBundleID: nil,
            summary: "Persisted.",
            outcome: .completed,
            startedAt: Date(timeIntervalSince1970: 1_724_700_000),
            finishedAt: Date(timeIntervalSince1970: 1_724_700_001),
            steps: [],
            verified: nil
        )
        let store = TranscriptStore(directory: directory)
        await store.append(entry)

        let transcriptsDirectory = directory.appendingPathComponent("Transcripts")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: transcriptsDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: transcriptsDirectory.path)
        }

        let deleted = await store.delete([entry.id])
        XCTAssertFalse(deleted)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot, [entry])
        let issue = await store.lastPersistenceError
        XCTAssertNotNil(issue)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: transcriptsDirectory.path)
        let retried = await store.delete([entry.id])
        XCTAssertTrue(retried)
        let retriedSnapshot = await store.snapshot()
        XCTAssertTrue(retriedSnapshot.isEmpty)
    }

    func testExportProducesMarkdownAndCSV() async throws {
        let entry = TranscriptEntry(
            request: "do the thing",
            appBundleID: nil,
            summary: "Finished.",
            outcome: .completed,
            startedAt: Date(timeIntervalSince1970: 1_724_700_000),
            finishedAt: Date(timeIntervalSince1970: 1_724_700_001),
            steps: [],
            verified: nil
        )
        let store = TranscriptStore(directory: directory)
        await store.append(entry)

        let markdown = try await store.export([entry.id], format: .markdown)
        let csv = try await store.export([entry.id], format: .csv)

        XCTAssertTrue(String(decoding: markdown, as: UTF8.self).contains("do the thing"))
        XCTAssertTrue(String(decoding: csv, as: UTF8.self).contains("session_id,request"))
        XCTAssertTrue(String(decoding: csv, as: UTF8.self).contains("do the thing"))
    }
}

private final class RejectingMoveFileManager: FileManager {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw NSError(domain: "TranscriptStoreTests", code: 1)
    }
}
