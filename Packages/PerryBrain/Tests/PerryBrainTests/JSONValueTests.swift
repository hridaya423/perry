@testable import PerryBrain
import XCTest

final class JSONValueTests: XCTestCase {
    func testRoundTrip() throws {
        let value = JSONValue.object([
            "s": .string("x"),
            "n": .number(1.5),
            "b": .bool(true),
            "z": .null,
            "a": .array([.number(1), .number(2)]),
            "o": .object(["k": .string("v")]),
        ])
        let decoded = try JSONValue(parsing: value.data())
        XCTAssertEqual(value, decoded)
    }

    func testSortedKeys() throws {
        let data = try JSONValue.object(["b": .number(1), "a": .number(2)]).data()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"a":2,"b":1}"#)
    }

    func testNumberVsBool() throws {
        let parsed = try JSONValue(parsing: Data(#"{"t":true,"n":1}"#.utf8))
        XCTAssertEqual(parsed["t"], .bool(true))
        XCTAssertEqual(parsed["n"], .number(1))
        XCTAssertNotEqual(parsed["n"], .bool(true))
    }

    func testFragmentString() throws {
        let parsed = try JSONValue(parsing: Data(#""hi""#.utf8))
        XCTAssertEqual(parsed, .string("hi"))
    }
}
