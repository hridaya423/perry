@testable import PerryBrain
import XCTest

final class SentenceChunkerTests: XCTestCase {
    func testSimpleSentence() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Hello world. How are"), ["Hello world."])
        XCTAssertEqual(c.finish(), "How are")
    }

    func testDecimalIsNotABoundary() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Pi is 3."), [])
        XCTAssertEqual(c.feed("14159. More"), ["Pi is 3.14159."])
        XCTAssertEqual(c.finish(), "More")
    }

    func testNewlineIsABoundary() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("First line\nSecond"), ["First line"])
        XCTAssertEqual(c.finish(), "Second")
    }

    func testMultipleSentencesOneFeed() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("One. Two. Three"), ["One.", "Two."])
        XCTAssertEqual(c.finish(), "Three")
    }

    func testSplitAcrossFeeds() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Hel"), [])
        XCTAssertEqual(c.feed("lo."), [])
        XCTAssertEqual(c.feed(" Bye"), ["Hello."])
        XCTAssertEqual(c.finish(), "Bye")
    }

    func testQuestionAndExclamation() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Really? Yes! Done"), ["Really?", "Yes!"])
        XCTAssertEqual(c.finish(), "Done")
    }

    func testCJKTerminators() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("你好。 再见"), ["你好。"])
        XCTAssertEqual(c.finish(), "再见")
    }

    func testEmptyFinish() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Done. "), ["Done."])
        XCTAssertNil(c.finish())
    }
}
