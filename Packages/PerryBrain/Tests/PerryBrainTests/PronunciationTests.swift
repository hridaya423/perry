import XCTest
@testable import PerryBrain

final class PronunciationTests: XCTestCase {
    func testRespellingReplacesWholeWordsOnly() {
        let entries = [Pronunciation(written: "Hridya", spoken: "Hrid-yah"), Pronunciation(written: "Siobhan", spoken: "Shi-vawn")]
        XCTAssertEqual(PronunciationStore.respell("Hi Hridya, Siobhan's notes are ready. Hridyas?", with: entries),
                       "Hi Hrid-yah, Shi-vawn's notes are ready. Hridyas?")
    }

    func testStoreReplacesEntriesCaseInsensitively() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PronunciationStore(directory: directory)
        try store.set(Pronunciation(written: "Hridya", spoken: "Hrid-ya"))
        try store.set(Pronunciation(written: "hridya", spoken: "Hrid-yah", source: .learned))
        XCTAssertEqual(store.entries().map(\.spoken), ["Hrid-yah"])
        try store.remove(written: "HRIDYA")
        XCTAssertTrue(store.entries().isEmpty)
    }
}
