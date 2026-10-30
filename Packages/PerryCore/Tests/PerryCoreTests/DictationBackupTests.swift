import XCTest
@testable import PerryCore

final class DictationBackupTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day))!
    }

    func testRecordAndReadBack() throws {
        let store = DictationBackupStore(directory: dir, calendar: calendar)
        try store.record(text: "first", at: date(20))
        try store.record(text: "second", language: "en", at: date(20).addingTimeInterval(60))
        let entries = store.entries()
        XCTAssertEqual(entries.map(\.text), ["first", "second"])
        XCTAssertEqual(entries.last?.language, "en")
    }

    func testEmptyTextNotRecorded() throws {
        let store = DictationBackupStore(directory: dir, calendar: calendar)
        try store.record(text: "   \n ", at: date(20))
        XCTAssertTrue(store.entries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testPruneKeepsSevenDays() throws {
        let store = DictationBackupStore(directory: dir, calendar: calendar)
        try store.record(text: "old", at: date(10))
        try store.record(text: "edge", at: date(19))
        try store.record(text: "new", at: date(26))
        XCTAssertEqual(store.entries().map(\.text), ["edge", "new"])
    }

    func testCorruptLineSkipped() throws {
        let store = DictationBackupStore(directory: dir, calendar: calendar)
        try store.record(text: "good", at: date(20))
        let file = dir.appendingPathComponent("2026-09-20.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        XCTAssertEqual(store.entries().map(\.text), ["good"])
    }
}
