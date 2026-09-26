import Foundation
import PerryCore

public protocol HTTPLineStreaming: Sendable {
    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>)
}

public struct URLSessionLineStreaming: HTTPLineStreaming {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelProviderError(kind: .network, provider: "http", message: "provider returned a non-HTTP response")
        }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http, stream)
    }
}

public struct SSEEvent: Equatable, Sendable {
    public var event: String?
    public var data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

public struct SSEParser: Sendable {
    private var dataLines: [String] = []
    private var eventName: String?

    public init() {}

    public mutating func feed(line: String) -> SSEEvent? {
        if line.hasPrefix(":") { return nil }
        if line.isEmpty { return dispatch() }
        if let colon = line.firstIndex(of: ":") {
            let field = String(line[..<colon])
            var value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
            switch field {
            case "data": dataLines.append(value)
            case "event": eventName = value
            default: break
            }
        } else {
            dataLines.append(line)
        }
        return nil
    }

    public mutating func finish() -> SSEEvent? {
        dispatch()
    }

    private mutating func dispatch() -> SSEEvent? {
        guard !dataLines.isEmpty else {
            eventName = nil
            return nil
        }
        let event = SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
        dataLines = []
        eventName = nil
        return event
    }
}

enum BrainHTTP {
    /// Runs `body` in a task tied to the stream's lifetime and always finishes the stream.
    static func eventStream(
        _ body: @escaping @Sendable (AsyncThrowingStream<ModelEvent, Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func requireSuccess(
        _ response: HTTPURLResponse,
        lines: AsyncThrowingStream<String, Error>,
        provider: ProviderID
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard (200..<300).contains(response.statusCode) else {
            var body = Data()
            var iterator = lines.makeAsyncIterator()
            while let line = try await iterator.next() {
                body.append(contentsOf: line.utf8)
                body.append(0x0A)
                if body.count > 8 * 1024 { break }
            }
            throw error(for: response, body: body, provider: provider)
        }
        return lines
    }

    static func error(for response: HTTPURLResponse, body: Data, provider: ProviderID) -> ModelProviderError {
        let message = String(decoding: body, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = message.isEmpty ? "HTTP \(response.statusCode)" : "HTTP \(response.statusCode): \(message)"
        switch response.statusCode {
        case 401, 403:
            return ModelProviderError(kind: .unauthenticated, provider: provider, message: detail)
        case 429:
            return ModelProviderError(kind: .rateLimited(resetAt: resetAt(response)), provider: provider, message: detail)
        default:
            return ModelProviderError(kind: .http(response.statusCode), provider: provider, message: detail)
        }
    }

    private static func resetAt(_ response: HTTPURLResponse) -> Date? {
        if let retryAfter = response.value(forHTTPHeaderField: "retry-after"),
           let seconds = TimeInterval(retryAfter.trimmingCharacters(in: .whitespaces)) {
            return Date().addingTimeInterval(seconds)
        }
        if let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset-requests"),
           let seconds = TimeInterval(reset.trimmingCharacters(in: .whitespaces)) {
            return Date().addingTimeInterval(seconds)
        }
        return nil
    }

    static func post(_ baseURL: URL, path: String, provider: ProviderID) throws -> URLRequest {
        try NetworkEndpointPolicy.requireSafe(baseURL)
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        return request
    }
}
