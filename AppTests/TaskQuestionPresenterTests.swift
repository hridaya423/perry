import XCTest
@testable import Perry

@MainActor
final class TaskQuestionPresenterTests: XCTestCase {
    private func waitForPresentation(_ presenter: TaskQuestionPresenter, in presentation: NotchPresentation) async {
        for _ in 0..<200 where !presentation.contains(presenter.requestID) {
            await Task.yield()
        }
    }

    func testChoosingAnOfferedChoiceResolvesAndRemovesTheEntry() async throws {
        let presentation = NotchPresentation()
        let presenter = TaskQuestionPresenter(prompt: "Which report?", choices: ["Monthly", "Annual"], presentation: presentation)
        let asking = Task { try await presenter.ask() }
        await waitForPresentation(presenter, in: presentation)
        XCTAssertEqual(presentation.current?.id, presenter.requestID)
        XCTAssertEqual(presentation.current?.priority, .approval)
        presenter.answer("Annual")
        try await asking.value
        XCTAssertFalse(presentation.contains(presenter.requestID))
    }

    func testCancelThrowsAndRemovesTheEntry() async {
        let presentation = NotchPresentation()
        let presenter = TaskQuestionPresenter(prompt: "Continue?", choices: ["OK"], presentation: presentation)
        let asking = Task { try await presenter.ask() }
        await waitForPresentation(presenter, in: presentation)
        presenter.cancel()
        do {
            try await asking.value
            XCTFail("Cancel must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(presentation.contains(presenter.requestID))
    }

    func testCancellingTheTaskWhileVisibleRemovesTheEntry() async {
        let presentation = NotchPresentation()
        let presenter = TaskQuestionPresenter(prompt: "Continue?", choices: ["OK"], presentation: presentation)
        let asking = Task { try await presenter.ask() }
        await waitForPresentation(presenter, in: presentation)
        asking.cancel()
        do {
            try await asking.value
            XCTFail("Task cancellation must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(presentation.contains(presenter.requestID))
    }

    func testCancellingBeforePresentationPresentsNothing() async {
        let presentation = NotchPresentation()
        let presenter = TaskQuestionPresenter(prompt: "Continue?", choices: ["OK"], presentation: presentation)
        let asking = Task { try await presenter.ask() }
        asking.cancel()
        do {
            try await asking.value
            XCTFail("Task cancellation must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(presentation.entries.isEmpty)
    }

    func testRepeatedAnswerAndCancelResolveOnlyOnce() async throws {
        let presentation = NotchPresentation()
        let presenter = TaskQuestionPresenter(prompt: "Which report?", choices: ["Monthly", "Annual"], presentation: presentation)
        let asking = Task { try await presenter.ask() }
        await waitForPresentation(presenter, in: presentation)
        presenter.answer("Monthly")
        presenter.answer("Annual")
        presenter.cancel()
        try await asking.value
        XCTAssertFalse(presentation.contains(presenter.requestID))
    }

    func testCancelWinsOverALaterAnswer() async {
        let presentation = NotchPresentation()
        let presenter = TaskQuestionPresenter(prompt: "Which report?", choices: ["Monthly", "Annual"], presentation: presentation)
        let asking = Task { try await presenter.ask() }
        await waitForPresentation(presenter, in: presentation)
        presenter.cancel()
        presenter.answer("Monthly")
        do {
            try await asking.value
            XCTFail("Cancellation before the answer must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(presentation.contains(presenter.requestID))
    }

    func testOnlyThreeChoicesAreOfferedAndUnofferedChoicesCannotResolve() async throws {
        let presentation = NotchPresentation()
        let presenter = TaskQuestionPresenter(prompt: "Pick one", choices: ["One", "Two", "Three", "Four"], presentation: presentation)
        let asking = Task { try await presenter.ask() }
        await waitForPresentation(presenter, in: presentation)
        presenter.answer("Four")
        XCTAssertTrue(presentation.contains(presenter.requestID))
        presenter.answer("Three")
        try await asking.value
        XCTAssertFalse(presentation.contains(presenter.requestID))
    }

    func testAskingAgainAfterResolutionThrowsWithoutPresenting() async throws {
        let presentation = NotchPresentation()
        let presenter = TaskQuestionPresenter(prompt: "Continue?", choices: ["OK"], presentation: presentation)
        let asking = Task { try await presenter.ask() }
        await waitForPresentation(presenter, in: presentation)
        presenter.answer("OK")
        try await asking.value
        do {
            try await presenter.ask()
            XCTFail("A resolved presenter must not ask again")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(presentation.entries.isEmpty)
    }
}
