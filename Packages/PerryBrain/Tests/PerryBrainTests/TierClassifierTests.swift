@testable import PerryBrain
import XCTest

final class TierClassifierTests: XCTestCase {
    func testShortQuestionIsFast() {
        XCTAssertEqual(TierClassifier.tier(question: "what does this button do", bindingCount: 0, elementCount: 10), .fast)
    }

    func testLongQuestionIsDeep() {
        let question = String(repeating: "word ", count: 40)
        XCTAssertEqual(TierClassifier.tier(question: question, bindingCount: 0, elementCount: 0), .deep)
    }

    func testWhyIsDeep() {
        XCTAssertEqual(TierClassifier.tier(question: "why is this greyed out", bindingCount: 0, elementCount: 0), .deep)
    }

    func testHowDoIIsDeep() {
        XCTAssertEqual(TierClassifier.tier(question: "how do I export", bindingCount: 0, elementCount: 0), .deep)
    }

    func testManyElementsIsDeep() {
        XCTAssertEqual(TierClassifier.tier(question: "click it", bindingCount: 0, elementCount: 401), .deep)
    }

    func testManyBindingsIsDeep() {
        XCTAssertEqual(TierClassifier.tier(question: "click it", bindingCount: 3, elementCount: 0), .deep)
    }

    func testMultilingualDeepSignals() {
        XCTAssertEqual(TierClassifier.tier(question: "pourquoi ça marche pas", bindingCount: 0, elementCount: 0), .deep)
        XCTAssertEqual(TierClassifier.tier(question: "warum ist das so", bindingCount: 0, elementCount: 0), .deep)
    }
}
