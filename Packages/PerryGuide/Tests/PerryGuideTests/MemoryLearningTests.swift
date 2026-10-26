import XCTest
@testable import PerryGuide

final class MemoryLearningTests: XCTestCase {
    private func store() -> MemoryStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return MemoryStore(storageDirectory: directory, configuration: MemoryConfiguration(enabled: true))
    }

    func testNewerFactReplacesTheSameSubject() async {
        let memory = store()
        _ = await memory.remember(MemoryRecord(category: .aboutYou, summary: "Manager is Sam", subject: "manager"))
        _ = await memory.remember(MemoryRecord(category: .aboutYou, summary: "Manager is Priya", subject: "manager"))
        _ = await memory.remember(MemoryRecord(category: .aboutYou, summary: "Works at Acme", subject: "employer"))
        let summaries = await memory.snapshot().map(\.summary)
        XCTAssertEqual(summaries, ["Manager is Priya", "Works at Acme"])
    }

    func testExpiredFactsLeaveThePrompt() async {
        let memory = store()
        _ = await memory.remember(MemoryRecord(category: .aboutYou, summary: "Launch was last week", expiresAt: Date().addingTimeInterval(-60)))
        _ = await memory.remember(MemoryRecord(category: .aboutYou, summary: "Prefers short answers"))
        let context = await memory.promptContext(appBundleID: nil)
        XCTAssertEqual(context, "- [aboutYou] Prefers short answers")
    }

    func testRelevantFactsComeFirst() {
        let records = [
            MemoryRecord(category: .pastSession, summary: "Booked a dentist appointment", createdAt: Date()),
            MemoryRecord(category: .pastSession, summary: "Wrote the quarterly sales report in Numbers", createdAt: Date().addingTimeInterval(-100)),
        ]
        let ranked = MemoryStore.ranked(records, query: "update the sales spreadsheet")
        XCTAssertEqual(ranked.first?.summary, "Wrote the quarterly sales report in Numbers")
    }
}
