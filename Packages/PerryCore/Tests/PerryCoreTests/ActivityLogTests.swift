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
        let reloaded = ActivityLog(storageDirectory: tempDirectory)
        let snapshot = await reloaded.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.actionSummary, "renamed 3 files in Finder")
        XCTAssertEqual(snapshot.first?.tier, .yellow)
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

    func testInMemoryLogDoesNotTouchDisk() async throws {
        let log = ActivityLog()
        await log.record(
            ActivityEntry(
                actionSummary: "read window",
                targetAppBundleID: nil,
                tier: .green,
                outcome: .allowed,
                reversible: true
            )
        )
        let snapshot = await log.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        let contents = try? FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        XCTAssertTrue(contents?.isEmpty ?? true)
    }
}
