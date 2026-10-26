import XCTest
@testable import PerryBrain

final class SpeechTextTests: XCTestCase {
    func testMarkdownBecomesPlainSentences() {
        let text = "## Next steps\n- Review the **outline**\n- Share `notes.md`\n\n```swift\nlet x = 1\n```"
        XCTAssertEqual(SpeechText.prepare(text), "Next steps. Review the outline. Share notes.md.")
    }

    func testLinksAndPathsAreShortened() {
        XCTAssertEqual(SpeechText.prepare("See [the docs](https://example.com/a) or https://www.github.com/perry."),
                       "See the docs or github dot com")
        XCTAssertEqual(SpeechText.prepare("Saved to /Users/hridya/Documents/Q3 report/plan.pdf now."),
                       "Saved to plan.pdf now.")
    }

    func testShortcutGlyphsAndSymbols() {
        XCTAssertEqual(SpeechText.prepare("Press ⌘⇧4 to capture & share."), "Press Command Shift 4 to capture and share.")
        XCTAssertEqual(SpeechText.prepare("It costs $5k, up 12%."), "It costs 5 thousand dollars, up 12 percent.")
        XCTAssertEqual(SpeechText.prepare("Pages 3–5, e.g. the intro."), "Pages 3 to 5, for example the intro.")
    }

    func testDatesSurviveWithoutSpellingNumbers() {
        XCTAssertEqual(SpeechText.prepare("Due 2026-10-26."), "Due 2026-10-26.")
    }

    func testSpellNumbersForEnginesWithoutNormalization() {
        XCTAssertEqual(SpeechText.prepare("I found 1,250 files in 2026.", spellNumbers: true),
                       "I found one thousand two hundred fifty files in twenty twenty-six.")
        XCTAssertEqual(SpeechText.prepare("Back in 1905.", spellNumbers: true), "Back in nineteen oh five.")
    }

    func testPlainSentencePassesThrough() {
        XCTAssertEqual(SpeechText.prepare("You're all set, Hridya."), "You're all set, Hridya.")
    }
}

final class SpeechTextStreamTests: XCTestCase {
    func testCodeFenceSpanningStreamedChunksIsSilent() {
        var stream = SpeechText.Stream()
        XCTAssertEqual(stream.next("Here is the fix."), "Here is the fix.")
        XCTAssertEqual(stream.next("```swift"), "")
        XCTAssertEqual(stream.next("let total = items.count"), "")
        XCTAssertEqual(stream.next("```"), "")
        XCTAssertEqual(stream.next("Run it again."), "Run it again.")
    }
}
