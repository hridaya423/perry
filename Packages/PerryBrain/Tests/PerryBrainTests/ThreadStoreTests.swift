import XCTest
@testable import PerryBrain

final class ThreadStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(limit: Int = 200) -> ThreadStore {
        ThreadStore(directory: directory, historyLimit: limit)
    }

    func testAppendTurnCreatesAndPersists() async {
        let s = store()
        let id = UUID()
        let t = await s.appendTurn(to: id, question: "what's this button?", answer: "The save button.")
        XCTAssertEqual(t.turns.count, 1)
        XCTAssertEqual(t.title, "what's this button?")
        // New instance reads the same disk state.
        let reloaded = ThreadStore(directory: directory)
        let answer = await reloaded.thread(id: id)?.turns.first?.answer
        XCTAssertEqual(answer, "The save button.")
    }

    func testListIsNewestFirst() async {
        let s = store()
        let older = await s.appendTurn(to: UUID(), question: "old", answer: "a",
                                       at: Date(timeIntervalSince1970: 100))
        let newer = await s.appendTurn(to: UUID(), question: "new", answer: "b",
                                       at: Date(timeIntervalSince1970: 200))
        let ids = await s.list().map(\.id)
        XCTAssertEqual(ids, [newer.id, older.id])
    }

    func testTitleOnlyFromFirstTurn() async {
        let s = store()
        let id = UUID()
        _ = await s.appendTurn(to: id, question: "first q", answer: "a")
        _ = await s.appendTurn(to: id, question: "second q", answer: "b")
        let title = await s.thread(id: id)?.title
        XCTAssertEqual(title, "first q")
    }

    func testHistoryLimitDropsOldest() async {
        let s = store(limit: 2)
        let id = UUID()
        for i in 1...4 {
            _ = await s.appendTurn(to: id, question: "q\(i)", answer: "a\(i)")
        }
        let questions = await s.thread(id: id)?.turns.map(\.question)
        XCTAssertEqual(questions, ["q3", "q4"])
    }

    func testDraftPersistsPerThread() async {
        let s = store()
        let id = UUID()
        _ = await s.appendTurn(to: id, question: "q", answer: "a")
        await s.setDraft("half-typed reply", for: id)
        let draft = await s.thread(id: id)?.draft
        XCTAssertEqual(draft, "half-typed reply")
    }

    func testDeleteRemovesFileAndCacheEntry() async {
        let s = store()
        let id = UUID()
        _ = await s.appendTurn(to: id, question: "q", answer: "a")
        await s.delete(id: id)
        let gone = await s.thread(id: id)
        XCTAssertNil(gone)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("\(id.uuidString).json").path))
    }

    func testCorruptFileIsSkipped() async {
        try? "not json".write(
            to: directory.appendingPathComponent("\(UUID().uuidString).json"),
            atomically: true, encoding: .utf8
        )
        let s = store()
        let threads = await s.list()
        XCTAssertTrue(threads.isEmpty)
    }

    func testDerivedTitleTruncatesAndStripsNewlines() {
        let q = "  what does this do?\nsecond line  "
        XCTAssertEqual(ThreadStore.derivedTitle(from: q), "what does this do?")
        let long = String(repeating: "x", count: 100)
        XCTAssertEqual(ThreadStore.derivedTitle(from: long).count, 60)
    }
}
