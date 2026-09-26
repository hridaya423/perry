import XCTest
@testable import PerryCore

final class DictationCleanupGuardTests: XCTestCase {
    func testIdentical() {
        XCTAssertTrue(DictationCleanupGuard.isAcceptable(raw: "hello world", cleaned: "hello world"))
    }

    func testPunctuationOnly() {
        XCTAssertFalse(DictationCleanupGuard.isAcceptable(
            raw: "hello world this works", cleaned: "Hello, world — this works."
        )) // em dash was added
        XCTAssertTrue(DictationCleanupGuard.isAcceptable(
            raw: "hello world this works", cleaned: "Hello, world. This works."
        ))
    }

    func testFillerRemovalWithinBudget() {
        XCTAssertTrue(DictationCleanupGuard.isAcceptable(
            raw: "um so like the meeting is thursday",
            cleaned: "The meeting is Thursday."
        ))
    }

    func testInventedWordsRejected() {
        XCTAssertFalse(DictationCleanupGuard.isAcceptable(
            raw: "the meeting is thursday",
            cleaned: "The meeting is Thursday and I will bring snacks for everyone"
        ))
    }

    func testBigRewriteRejected() {
        XCTAssertFalse(DictationCleanupGuard.isAcceptable(
            raw: "i saw a dog",
            cleaned: "completely different sentence about cats"
        ))
    }

    func testEllipsisAddedRejected() {
        XCTAssertFalse(DictationCleanupGuard.isAcceptable(raw: "wait what", cleaned: "wait… what"))
        XCTAssertTrue(DictationCleanupGuard.isAcceptable(raw: "wait… what", cleaned: "Wait… what?"))
    }

    func testBudgetScalesWithLength() {
        let raw = (1...30).map { "word\($0)" }.joined(separator: " ")
        var cleaned = raw
        for i in 1...6 { cleaned = cleaned.replacingOccurrences(of: "word\(i * 4)", with: "changed\(i)") }
        XCTAssertTrue(DictationCleanupGuard.isAcceptable(raw: raw, cleaned: cleaned)) // 6 ≤ ceil(30*0.2)=6
        cleaned = cleaned.replacingOccurrences(of: "word7", with: "changed7")
        XCTAssertFalse(DictationCleanupGuard.isAcceptable(raw: raw, cleaned: cleaned)) // 7 > 6
    }

    func testEditDistance() {
        XCTAssertEqual(DictationCleanupGuard.editDistance(["a", "b"], ["a", "b"]), 0)
        XCTAssertEqual(DictationCleanupGuard.editDistance(["a", "b"], ["a", "c"]), 1)
        XCTAssertEqual(DictationCleanupGuard.editDistance([], ["a"]), 1)
        XCTAssertEqual(DictationCleanupGuard.editDistance(["a", "b", "c"], ["a", "c"]), 1)
    }
}

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
