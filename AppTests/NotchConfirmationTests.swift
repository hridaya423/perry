import XCTest
@testable import Perry

@MainActor
final class NotchConfirmationTests: XCTestCase {
    private func waitForPresentation(_ confirmation: NotchConfirmation, in presentation: NotchPresentation) async {
        for _ in 0..<200 where !presentation.contains(confirmation.requestID) {
            await Task.yield()
        }
    }

    private func makeConfirmation(in presentation: NotchPresentation) -> NotchConfirmation {
        NotchConfirmation(
            title: "Erase all Perry data?",
            detail: "This cannot be undone.",
            destructiveTitle: "Erase all Perry data",
            cancelTitle: "Cancel",
            presentation: presentation
        )
    }

    func testExplicitDestructiveResolveReturnsTrueAndRemovesTheEntry() async {
        let presentation = NotchPresentation()
        let confirmation = makeConfirmation(in: presentation)
        let asking = Task { await confirmation.confirm() }
        await waitForPresentation(confirmation, in: presentation)
        XCTAssertEqual(presentation.current?.id, confirmation.requestID)
        XCTAssertEqual(presentation.current?.priority, .approval)
        confirmation.resolve(true)
        let result = await asking.value
        XCTAssertTrue(result)
        XCTAssertFalse(presentation.contains(confirmation.requestID))
    }

    func testCancelReturnsFalseAndRemovesTheEntry() async {
        let presentation = NotchPresentation()
        let confirmation = makeConfirmation(in: presentation)
        let asking = Task { await confirmation.confirm() }
        await waitForPresentation(confirmation, in: presentation)
        confirmation.cancel()
        let result = await asking.value
        XCTAssertFalse(result)
        XCTAssertFalse(presentation.contains(confirmation.requestID))
    }

    func testResolveFalseIsNeverAnApproval() async {
        let presentation = NotchPresentation()
        let confirmation = makeConfirmation(in: presentation)
        let asking = Task { await confirmation.confirm() }
        await waitForPresentation(confirmation, in: presentation)
        confirmation.resolve(false)
        let result = await asking.value
        XCTAssertFalse(result)
        XCTAssertFalse(presentation.contains(confirmation.requestID))
    }

    func testCancellingTheTaskWhileVisibleReturnsFalse() async {
        let presentation = NotchPresentation()
        let confirmation = makeConfirmation(in: presentation)
        let asking = Task { await confirmation.confirm() }
        await waitForPresentation(confirmation, in: presentation)
        asking.cancel()
        let result = await asking.value
        XCTAssertFalse(result)
        XCTAssertFalse(presentation.contains(confirmation.requestID))
    }

    func testCancellingBeforePresentationReturnsFalseAndPresentsNothing() async {
        let presentation = NotchPresentation()
        let confirmation = makeConfirmation(in: presentation)
        let asking = Task { await confirmation.confirm() }
        asking.cancel()
        let result = await asking.value
        XCTAssertFalse(result)
        XCTAssertTrue(presentation.entries.isEmpty)
    }

    func testRepeatedResolveAndCancelResolveOnlyOnce() async {
        let presentation = NotchPresentation()
        let confirmation = makeConfirmation(in: presentation)
        let asking = Task { await confirmation.confirm() }
        await waitForPresentation(confirmation, in: presentation)
        confirmation.resolve(true)
        confirmation.resolve(false)
        confirmation.cancel()
        let result = await asking.value
        XCTAssertTrue(result)
        XCTAssertFalse(presentation.contains(confirmation.requestID))
    }

    func testCancelWinsOverALaterResolve() async {
        let presentation = NotchPresentation()
        let confirmation = makeConfirmation(in: presentation)
        let asking = Task { await confirmation.confirm() }
        await waitForPresentation(confirmation, in: presentation)
        confirmation.cancel()
        confirmation.resolve(true)
        let result = await asking.value
        XCTAssertFalse(result)
        XCTAssertFalse(presentation.contains(confirmation.requestID))
    }

    func testRemovingTheEntryExternallyDoesNotApprove() async {
        let presentation = NotchPresentation()
        let confirmation = makeConfirmation(in: presentation)
        let asking = Task { await confirmation.confirm() }
        await waitForPresentation(confirmation, in: presentation)
        presentation.remove(confirmation.requestID)
        XCTAssertFalse(presentation.contains(confirmation.requestID))
        confirmation.resolve(true)
        let result = await asking.value
        XCTAssertTrue(result)
    }

    func testConfirmingAgainWhilePendingReturnsFalseAndKeepsTheEntry() async {
        let presentation = NotchPresentation()
        let confirmation = makeConfirmation(in: presentation)
        let asking = Task { await confirmation.confirm() }
        await waitForPresentation(confirmation, in: presentation)
        let reentry = await confirmation.confirm()
        XCTAssertFalse(reentry)
        confirmation.resolve(true)
        let result = await asking.value
        XCTAssertTrue(result)
        XCTAssertFalse(presentation.contains(confirmation.requestID))
    }

    func testConfirmingAgainAfterResolutionReturnsFalseWithoutPresenting() async {
        let presentation = NotchPresentation()
        let confirmation = makeConfirmation(in: presentation)
        let asking = Task { await confirmation.confirm() }
        await waitForPresentation(confirmation, in: presentation)
        confirmation.resolve(true)
        _ = await asking.value
        let again = await confirmation.confirm()
        XCTAssertFalse(again)
        XCTAssertTrue(presentation.entries.isEmpty)
    }
}
