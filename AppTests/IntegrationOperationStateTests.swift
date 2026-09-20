import XCTest
@testable import Perry

final class IntegrationOperationStateTests: XCTestCase {
    func testIdleHasNoMessageOrAnnouncement() {
        let state = IntegrationOperationState.idle

        XCTAssertNil(state.message)
        XCTAssertNil(state.accessibilityLabel)
        XCTAssertFalse(state.isWorking)
    }

    func testWorkingStateClassifiesProgress() {
        let state = IntegrationOperationState.working("Testing provider access…")

        XCTAssertEqual(state.message, "Testing provider access…")
        XCTAssertEqual(state.accessibilityLabel, "In progress: Testing provider access…")
        XCTAssertTrue(state.isWorking)
    }

    func testCompletionStatesClassifyTheirOutcome() {
        let success = IntegrationOperationState.succeeded("Connected on this Mac.")
        let failure = IntegrationOperationState.failed("Authorization expired.")

        XCTAssertEqual(success.accessibilityLabel, "Succeeded: Connected on this Mac.")
        XCTAssertEqual(failure.accessibilityLabel, "Failed: Authorization expired.")
        XCTAssertFalse(success.isWorking)
        XCTAssertFalse(failure.isWorking)
    }
}
