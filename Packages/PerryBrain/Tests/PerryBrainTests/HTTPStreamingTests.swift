import Foundation
import XCTest
@testable import PerryBrain

final class HTTPStreamingTests: XCTestCase {
    func testServerErrorExtractsNestedMessageWithoutDroppingPlainText() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://fixture.invalid")!, statusCode: 400, httpVersion: nil, headerFields: nil))
        let nested = try JSONSerialization.data(withJSONObject: ["error": ["message": "The model does not support images."]])
        let wrapped = try JSONSerialization.data(withJSONObject: ["error": ["message": String(decoding: nested, as: UTF8.self)]])
        XCTAssertEqual(BrainHTTP.error(for: response, body: wrapped, provider: "test").message, "HTTP 400: The model does not support images.")
        XCTAssertEqual(BrainHTTP.error(for: response, body: Data("Model is loading".utf8), provider: "test").message, "HTTP 400: Model is loading")
    }

    func testURLSessionPreservesEventSeparatorsAndUnicode() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionLineStreaming(session: session)
        let (_, lines) = try await transport.lines(for: URLRequest(url: URL(string: "https://fixture.invalid/events")!))
        var received: [String] = []
        for try await line in lines { received.append(line) }
        XCTAssertEqual(received, ["data: café", "", "data: second", "", "data: third", "", "data: tail"])
        var parser = SSEParser()
        var events = received.compactMap { parser.feed(line: $0)?.data }
        if let final = parser.finish() { events.append(final.data) }
        XCTAssertEqual(events, ["café", "second", "third", "tail"])
    }
}

private final class StreamingFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for byte in "data: café\r\n\r\ndata: second\n\ndata: third\r\rdata: tail".utf8 {
            client?.urlProtocol(self, didLoad: Data([byte]))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
