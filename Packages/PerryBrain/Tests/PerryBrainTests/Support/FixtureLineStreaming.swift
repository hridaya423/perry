import Foundation
@testable import PerryBrain
import XCTest

final class FixtureLineStreaming: HTTPLineStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let statusCode: Int
    private let headers: [String: String]
    private let body: String
    private let delayBeforeLines: UInt64

    init(statusCode: Int = 200, headers: [String: String] = [:], body: String, delayMs: UInt64 = 0) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.delayBeforeLines = delayMs
    }

    convenience init(statusCode: Int = 200, headers: [String: String] = [:], fixture name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/sse"),
            "missing fixture \(name)", file: file, line: line
        )
        self.init(
            statusCode: statusCode,
            headers: headers,
            body: try String(contentsOf: url, encoding: .utf8)
        )
    }

    var requests: [URLRequest] {
        lock.withLock { _requests }
    }

    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        lock.withLock { _requests.append(request) }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        let lines = body.components(separatedBy: "\n").dropLast()
        let delay = delayBeforeLines
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay * 1_000_000)
                }
                guard !Task.isCancelled else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                for line in lines {
                    continuation.yield(line)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (response, stream)
    }
}
