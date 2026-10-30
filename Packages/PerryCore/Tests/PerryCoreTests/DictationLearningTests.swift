import XCTest
@testable import PerryCore

final class PersonalDictionaryLearnerTests: XCTestCase {
    private let t0 = Date()

    func testSingleSubstitutionLearned() {
        let learned = PersonalDictionaryLearner.learn(
            inserted: "meet wright at noon",
            observed: "meet right at noon",
            insertedAt: t0, observedAt: t0.addingTimeInterval(5)
        )
        XCTAssertEqual(learned, ["wright": "right"])
    }

    func testMultipleSubstitutionsLearned() {
        let learned = PersonalDictionaryLearner.learn(
            inserted: "their going to there house",
            observed: "they're going to their house",
            insertedAt: t0, observedAt: t0.addingTimeInterval(10)
        )
        XCTAssertEqual(learned["their"], "they're")
        XCTAssertEqual(learned["there"], "their")
    }

    func testAfterWindowLearnsNothing() {
        XCTAssertTrue(PersonalDictionaryLearner.learn(
            inserted: "meet wright", observed: "meet right",
            insertedAt: t0, observedAt: t0.addingTimeInterval(21)
        ).isEmpty)
    }

    func testUnequalCountsLearnNothing() {
        XCTAssertTrue(PersonalDictionaryLearner.learn(
            inserted: "meet wright at noon",
            observed: "meet right there at noon",
            insertedAt: t0, observedAt: t0.addingTimeInterval(5)
        ).isEmpty)
    }

    func testCasingPreserved() {
        let learned = PersonalDictionaryLearner.learn(
            inserted: "call michele",
            observed: "call Michèle",
            insertedAt: t0, observedAt: t0.addingTimeInterval(5)
        )
        XCTAssertEqual(learned["michele"], "Michèle")
    }
}
