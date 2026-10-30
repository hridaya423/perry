import XCTest
@testable import PerryGuide
import PerryCore

final class IntentCardTests: XCTestCase {
    private func card(_ tier: TrustTier) -> IntentCard {
        IntentCard(
            title: "About to move 34 files to Trash",
            tier: tier,
            targetSummary: "Finder · Desktop"
        )
    }

    func testSpokenLineMatchesTier() {
        XCTAssertTrue(card(.orange).spokenLine.contains("Approve or deny"))
        XCTAssertTrue(card(.red).spokenLine.contains("Confirm on screen"))
    }
}
