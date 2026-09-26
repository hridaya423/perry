@testable import PerryBrain
import XCTest

final class SSEParserTests: XCTestCase {
    func testSingleLineData() {
        var parser = SSEParser()
        XCTAssertNil(parser.feed(line: "data: hello"))
        let event = parser.feed(line: "")
        XCTAssertEqual(event?.data, "hello")
        XCTAssertNil(event?.event)
    }

    func testMultiLineDataJoinedWithNewline() {
        var parser = SSEParser()
        parser.feed(line: "data: first")
        parser.feed(line: "data: second")
        XCTAssertEqual(parser.feed(line: "")?.data, "first\nsecond")
    }

    func testEventName() {
        var parser = SSEParser()
        parser.feed(line: "event: message_stop")
        parser.feed(line: "data: {}")
        let event = parser.feed(line: "")
        XCTAssertEqual(event?.event, "message_stop")
    }

    func testCommentsIgnored() {
        var parser = SSEParser()
        parser.feed(line: ": ping")
        parser.feed(line: "data: x")
        XCTAssertEqual(parser.feed(line: "")?.data, "x")
    }

    func testBlankLineWithNoDataYieldsNothing() {
        var parser = SSEParser()
        XCTAssertNil(parser.feed(line: ""))
        XCTAssertNil(parser.feed(line: ""))
    }

    func testEOFFlush() {
        var parser = SSEParser()
        parser.feed(line: "data: tail")
        XCTAssertEqual(parser.finish()?.data, "tail")
        XCTAssertNil(parser.finish())
    }
}
