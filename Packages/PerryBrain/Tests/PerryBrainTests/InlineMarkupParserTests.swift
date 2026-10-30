@testable import PerryBrain
import XCTest

final class InlineMarkupParserTests: XCTestCase {
    private func parser(_ ids: Set<String> = ["export", "field-1", "a", "b"]) -> InlineMarkupParser {
        InlineMarkupParser(validElementIDs: ids)
    }

    func testPassthrough() {
        var p = parser()
        let (text, commands) = p.feed("Hello there, no tags.")
        XCTAssertEqual(text, "Hello there, no tags.")
        XCTAssertTrue(commands.isEmpty)
    }

    func testValidRingEmitsLabelAndCommand() {
        var p = parser()
        let (text, commands) = p.feed("Click ⟦ring export \"Export\"⟧ to save")
        XCTAssertEqual(text, "Click Export to save")
        XCTAssertEqual(commands, [DrawCommand(verb: .ring, elementID: "export", label: "Export")])
    }

    func testTagSplitAcrossThreeChunks() {
        var p = parser()
        let first = p.feed("Click ⟦ri")
        let second = p.feed("ng export \"Ex")
        let third = p.feed("port\"⟧ to save")
        XCTAssertEqual(first.text + second.text + third.text, "Click Export to save")
        XCTAssertEqual(first.commands + second.commands + third.commands,
                       [DrawCommand(verb: .ring, elementID: "export", label: "Export")])
    }

    func testInvalidIDKeepsTextDropsCommand() {
        var p = parser()
        let (text, commands) = p.feed("See ⟦point unknown \"here\"⟧ ok")
        XCTAssertEqual(text, "See here ok")
        XCTAssertTrue(commands.isEmpty)
    }

    func testUnknownVerb() {
        var p = parser()
        let (text, commands) = p.feed("Do ⟦dance export \"this\"⟧ now")
        XCTAssertEqual(text, "Do this now")
        XCTAssertTrue(commands.isEmpty)
    }

    func testClear() {
        var p = parser()
        let (text, commands) = p.feed("⟦clear⟧done")
        XCTAssertEqual(text, "done")
        XCTAssertEqual(commands, [DrawCommand(verb: .clear)])
    }

    func testTwoTagsInOneChunk() {
        var p = parser()
        let (text, commands) = p.feed("⟦point a⟧ then ⟦underline b \"B\"⟧")
        XCTAssertEqual(text, " then B")
        XCTAssertEqual(commands, [
            DrawCommand(verb: .point, elementID: "a"),
            DrawCommand(verb: .underline, elementID: "b", label: "B"),
        ])
    }

    func testUnterminatedFlushAt200Chars() {
        var p = parser()
        let inner = String(repeating: "x", count: 201)
        let (text, commands) = p.feed("⟦" + inner)
        XCTAssertEqual(text, "⟦" + inner)
        XCTAssertTrue(commands.isEmpty)
        let next = p.feed("more ⟦point a⟧")
        XCTAssertEqual(next.text, "more ")
        XCTAssertEqual(next.commands, [DrawCommand(verb: .point, elementID: "a")])
    }

    func testUnterminatedFlushAtFinish() {
        var p = parser()
        let fed = p.feed("text ⟦ring export \"lab")
        XCTAssertEqual(fed.text, "text ")
        XCTAssertTrue(fed.commands.isEmpty)
        let done = p.finish()
        XCTAssertEqual(done.text, "⟦ring export \"lab")
        XCTAssertTrue(done.commands.isEmpty)
    }
}
