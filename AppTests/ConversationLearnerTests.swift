@testable import Perry
import PerryBrain
import PerryGuide
import XCTest

@MainActor
final class ConversationLearnerTests: XCTestCase {
    func testTitleCleaning() {
        XCTAssertEqual(ConversationLearner.cleanTitle("\"Figma starter plan.\""), "Figma starter plan")
        XCTAssertEqual(ConversationLearner.cleanTitle("Title: Quarterly sales report\nextra"), "Quarterly sales report")
        XCTAssertNil(ConversationLearner.cleanTitle("This is far too long to be a sensible sidebar title for anyone"))
        XCTAssertNil(ConversationLearner.cleanTitle(""))
    }

    func testFirstTurnGetsATitleAndNewFactsAreRemembered() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let threads = ThreadStore(directory: directory.appendingPathComponent("Threads"))
        let memory = MemoryStore(storageDirectory: directory, configuration: MemoryConfiguration(enabled: true))
        let question = "I want to learn figma. My manager Sam wants a mockup by Friday."
        let thread = try await threads.appendTurn(to: UUID(), question: question, answer: "Start with frames.")
        var remembered: [MemoryRecord] = []
        let titled = expectation(description: "titled")
        let learned = expectation(description: "learned")
        let learner = ConversationLearner(
            complete: { prompt in
                prompt.contains("title") && !prompt.contains("facts")
                    ? "Learning Figma"
                    : #"{"facts": [{"text": "Manager is Sam", "kind": "person", "subject": "manager"}, {"text": "Mockup due Friday", "kind": "event", "subject": "mockup", "days": 5}]}"#
            },
            threads: threads, memory: memory,
            remembered: { _, records in remembered = records; learned.fulfill() },
            titled: { titled.fulfill() }
        )
        learner.turnCompleted(threadID: thread.id, question: question, answer: "Start with frames.")
        await fulfillment(of: [titled, learned], timeout: 5)
        let title = await threads.thread(id: thread.id)?.title
        XCTAssertEqual(title, "Learning Figma")
        XCTAssertEqual(remembered.map(\.summary), ["Manager is Sam", "Mockup due Friday"])
        XCTAssertNil(remembered[0].expiresAt)
        XCTAssertNotNil(remembered[1].expiresAt)
    }

    func testPausedMemoryLearnsNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let threads = ThreadStore(directory: directory.appendingPathComponent("Threads"))
        let memory = MemoryStore(storageDirectory: directory, configuration: MemoryConfiguration(enabled: false))
        var asked = 0
        let learner = ConversationLearner(
            complete: { _ in asked += 1; return #"{"facts": [{"text": "Likes tea", "kind": "preference", "subject": "drink"}]}"# },
            threads: threads, memory: memory, remembered: { _, _ in XCTFail("memory is paused") }, titled: {}
        )
        learner.turnCompleted(threadID: UUID(), question: "hi", answer: "hello")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(asked, 0)
    }
}
