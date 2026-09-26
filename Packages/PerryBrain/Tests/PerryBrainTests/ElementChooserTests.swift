import XCTest
@testable import PerryBrain

private final class StubChooserTransport: ChooserTransport {
    let response: JSONValue
    private(set) var lastPath: String?
    private(set) var lastBody: JSONValue?

    init(response: JSONValue) { self.response = response }

    func post(path: String, body: JSONValue) async throws -> JSONValue {
        lastPath = path
        lastBody = body
        return response
    }
}

final class ElementChooserTests: XCTestCase {
    private let candidates = [
        ObservedElement(id: "e1", role: "AXButton", label: "Export",
                        frame: CGRect(x: 10, y: 20, width: 60, height: 24), windowID: 7),
        ObservedElement(id: "e2", role: "AXSlider", label: "Opacity",
                        frame: CGRect(x: 10, y: 60, width: 120, height: 20), windowID: 7),
    ]

    func testPostsCandidatesAndReturnsRanking() async throws {
        let transport = StubChooserTransport(
            response: .object(["ranking": .array([.string("e2"), .string("e1")])])
        )
        let chooser = CuaS1Chooser(transport: transport)
        let ranking = try await chooser.choose(intent: "change opacity", candidates: candidates)
        XCTAssertEqual(ranking, ["e2", "e1"])

        XCTAssertEqual(transport.lastPath, "choose")
        XCTAssertEqual(transport.lastBody?["intent"]?.stringValue, "change opacity")
        let sent = transport.lastBody?["candidates"]?.arrayValue
        XCTAssertEqual(sent?.count, 2)
        XCTAssertEqual(sent?.first?["role"]?.stringValue, "AXButton")
        XCTAssertEqual(sent?.first?["frame"]?["w"]?.doubleValue, 60)
    }

    func testEmptyRankingOnMalformedResult() async throws {
        let chooser = CuaS1Chooser(transport: StubChooserTransport(response: .object([:])))
        let ranking = try await chooser.choose(intent: "x", candidates: candidates)
        XCTAssertEqual(ranking, [])
    }

    func testLoopbackOnlyForPlaintext() {
        XCTAssertThrowsError(try HTTPChooserTransport(baseURL: URL(string: "http://example.com")!))
        XCTAssertNoThrow(try HTTPChooserTransport(baseURL: URL(string: "http://127.0.0.1:8424")!))
        XCTAssertNoThrow(try HTTPChooserTransport(baseURL: URL(string: "https://example.com")!))
    }
}
