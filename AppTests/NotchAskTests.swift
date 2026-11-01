import SwiftUI
import XCTest
@testable import Perry

private final class AnswerBox<Answer> {
    var answer: ((Answer) -> Void)?
}

@MainActor
final class NotchAskTests: XCTestCase {
    private func waitForEntry(in presentation: NotchPresentation) async -> UUID? {
        for _ in 0..<200 where presentation.current == nil {
            await Task.yield()
        }
        return presentation.current?.id
    }

    func testAnsweringResolvesOnceAndRemovesTheEntry() async throws {
        let presentation = NotchPresentation()
        let box = AnswerBox<String>()
        let asking = Task {
            await presentation.ask(priority: .approval, cancelled: "none") { answer in
                box.answer = answer
                return Text("Pick")
            }
        }
        let entryID = await waitForEntry(in: presentation)
        let id = try XCTUnwrap(entryID)
        XCTAssertEqual(presentation.current?.priority, .approval)
        box.answer?("first")
        box.answer?("second")
        let result = await asking.value
        XCTAssertEqual(result, "first")
        XCTAssertFalse(presentation.contains(id))
    }

    func testCancelAskResolvesWithTheCancelledValue() async throws {
        let presentation = NotchPresentation()
        let id = UUID()
        let asking = Task {
            await presentation.ask(id: id, priority: .approval, cancelled: false) { _ in Text("Confirm") }
        }
        _ = await waitForEntry(in: presentation)
        presentation.cancelAsk(id)
        let result = await asking.value
        XCTAssertFalse(result)
        XCTAssertFalse(presentation.contains(id))
    }

    func testAnswerAfterCancelAskIsIgnored() async throws {
        let presentation = NotchPresentation()
        let id = UUID()
        let box = AnswerBox<Bool>()
        let asking = Task {
            await presentation.ask(id: id, priority: .approval, cancelled: false) { answer in
                box.answer = answer
                return Text("Confirm")
            }
        }
        _ = await waitForEntry(in: presentation)
        presentation.cancelAsk(id)
        box.answer?(true)
        let result = await asking.value
        XCTAssertFalse(result)
    }

    func testCancellingTheTaskWhileVisibleRemovesTheEntry() async throws {
        let presentation = NotchPresentation()
        let asking = Task {
            await presentation.ask(priority: .approval, cancelled: false) { _ in Text("Confirm") }
        }
        let entryID = await waitForEntry(in: presentation)
        let id = try XCTUnwrap(entryID)
        asking.cancel()
        let result = await asking.value
        XCTAssertFalse(result)
        XCTAssertFalse(presentation.contains(id))
    }

    func testCancellingBeforePresentationPresentsNothing() async {
        let presentation = NotchPresentation()
        let asking = Task {
            await presentation.ask(priority: .approval, cancelled: false) { _ in Text("Confirm") }
        }
        asking.cancel()
        let result = await asking.value
        XCTAssertFalse(result)
        XCTAssertTrue(presentation.entries.isEmpty)
    }

    func testDismissingTheEntryResolvesWithTheCancelledValue() async throws {
        let presentation = NotchPresentation()
        let asking = Task {
            await presentation.ask(priority: .approval, cancelled: false) { _ in Text("Confirm") }
        }
        let entryID = await waitForEntry(in: presentation)
        let id = try XCTUnwrap(entryID)
        presentation.dismissCurrent()
        let result = await asking.value
        XCTAssertFalse(result)
        XCTAssertFalse(presentation.contains(id))
    }

    func testConfirmationCancelResolvesFalseAndRemovesTheEntry() async {
        let presentation = NotchPresentation()
        let confirmation = NotchConfirmation(title: "Erase?", detail: "Cannot be undone.", confirmTitle: "Erase", cancelTitle: "Cancel", presentation: presentation)
        let asking = Task { await confirmation.confirm() }
        for _ in 0..<200 where !presentation.contains(confirmation.requestID) { await Task.yield() }
        XCTAssertEqual(presentation.current?.priority, .approval)
        confirmation.cancel()
        let result = await asking.value
        XCTAssertFalse(result)
        XCTAssertFalse(presentation.contains(confirmation.requestID))
    }

    func testChoiceQuestionThrowsWhenCancelled() async {
        let presentation = NotchPresentation()
        let asking = Task { try await presentation.askChoice(prompt: "Which report?", choices: ["Monthly", "Annual"]) }
        _ = await waitForEntry(in: presentation)
        asking.cancel()
        do {
            try await asking.value
            XCTFail("Cancelling a question must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(presentation.entries.isEmpty)
    }
}
