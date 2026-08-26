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

    func testOrangeApprovesOnChoiceAlone() {
        let policy = IntentCardPolicy()
        XCTAssertTrue(policy.resolve(card(.orange), choice: .approve, typedConfirmation: nil, sourceIsVoice: false))
    }

    func testStopAlwaysDenies() {
        let policy = IntentCardPolicy()
        XCTAssertFalse(policy.resolve(card(.orange), choice: .stop, typedConfirmation: nil, sourceIsVoice: false))
        XCTAssertFalse(policy.resolve(card(.red), choice: .stop, typedConfirmation: "confirm", sourceIsVoice: false))
        XCTAssertFalse(policy.resolve(card(.red), choice: nil, typedConfirmation: "confirm", sourceIsVoice: false))
    }

    func testRedRequiresTypedConfirmationEvenFromClick() {
        let policy = IntentCardPolicy()
        XCTAssertFalse(policy.resolve(card(.red), choice: .approve, typedConfirmation: nil, sourceIsVoice: false))
        XCTAssertTrue(policy.resolve(card(.red), choice: .approve, typedConfirmation: "move them", sourceIsVoice: false))
        XCTAssertTrue(policy.resolve(card(.red), choice: .approve, typedConfirmation: "   ", sourceIsVoice: false) == false)
    }

    func testRedRejectsVoiceOnlyApproval() {
        let policy = IntentCardPolicy()
        XCTAssertFalse(policy.resolve(card(.red), choice: .approve, typedConfirmation: "yes", sourceIsVoice: true))
    }

    func testSpokenLineMatchesTier() {
        XCTAssertTrue(card(.orange).spokenLine.contains("Approve or stop"))
        XCTAssertTrue(card(.red).spokenLine.contains("Confirm on screen"))
    }
}
