import Foundation
import PerryCore

/// System-1 grounding chooser (Phase 9 experiment): ranks candidate elements
/// for an intent. Implemented by the cua-s1 sidecar over loopback; only used
/// if the benchmark says it beats the frontier model within 3 points.
public protocol ElementChooser: Sendable {
    /// Candidate ids, best first. May be empty; callers fall back to the
    /// frontier-model chooser.
    func choose(intent: String, candidates: [ObservedElement]) async throws -> [String]
}

/// POST JSONValue → JSONValue against a fixed base URL.
public protocol ChooserTransport: Sendable {
    func post(path: String, body: JSONValue) async throws -> JSONValue
}

public enum ChooserError: Error, Sendable, Equatable, LocalizedError {
    case http(Int)
    case malformed
    public var errorDescription: String? {
        switch self {
        case .http(let code): return "chooser returned HTTP \(code)"
        case .malformed: return "chooser returned a malformed response"
        }
    }
}

/// URLSession POST transport pinned to a safe endpoint (loopback plaintext
/// or https) via `NetworkEndpointPolicy`.
public struct HTTPChooserTransport: ChooserTransport {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) throws {
        try NetworkEndpointPolicy.requireSafe(baseURL)
        self.baseURL = baseURL
        self.session = session
    }

    public func post(path: String, body: JSONValue) async throws -> JSONValue {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try body.data()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChooserError.malformed }
        guard (200..<300).contains(http.statusCode) else { throw ChooserError.http(http.statusCode) }
        return try JSONValue(parsing: data)
    }
}

/// cua-s1 sidecar client: `POST /choose` with `{intent, candidates}`,
/// expecting `{ranking: [id, ...]}`.
public struct CuaS1Chooser: ElementChooser {
    private let transport: any ChooserTransport

    public init(transport: any ChooserTransport) {
        self.transport = transport
    }

    public init(baseURL: URL = URL(string: "http://127.0.0.1:8424")!, session: URLSession = .shared) throws {
        self.transport = try HTTPChooserTransport(baseURL: baseURL, session: session)
    }

    public func choose(intent: String, candidates: [ObservedElement]) async throws -> [String] {
        let body: JSONValue = .object([
            "intent": .string(intent),
            "candidates": .array(candidates.map { element in
                .object([
                    "id": .string(element.id),
                    "role": .string(element.role),
                    "label": .string(element.label),
                    "window": .number(Double(element.windowID)),
                    "frame": .object([
                        "x": .number(Double(element.frame.origin.x)),
                        "y": .number(Double(element.frame.origin.y)),
                        "w": .number(Double(element.frame.size.width)),
                        "h": .number(Double(element.frame.size.height)),
                    ]),
                ])
            }),
        ])
        let result = try await transport.post(path: "choose", body: body)
        return result["ranking"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}
