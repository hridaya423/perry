import Foundation
import PerryCore

protocol WireDecoder {
    var isComplete: Bool { get }
    mutating func consume(_ event: SSEEvent) throws -> [ModelEvent]
    mutating func finish() throws -> [ModelEvent]
}

protocol WireFormat: Sendable {
    var requiresKey: Bool { get }
    var fixedCapabilities: ModelCapabilities? { get }
    var modelsPath: String { get }
    var streamQuery: [URLQueryItem] { get }
    func path(model: String) -> String
    func authorize(_ request: inout URLRequest, key: String)
    func body(for request: ModelRequest, model: String) -> [String: JSONValue]
    func makeDecoder(provider: ProviderID) -> any WireDecoder
}

extension WireFormat {
    var streamQuery: [URLQueryItem] { [] }
    var fixedCapabilities: ModelCapabilities? { [.vision, .tools, .streaming] }
    var requiresKey: Bool { true }
    var modelsPath: String { "v1/models" }

    func authorize(_ request: inout URLRequest, key: String) {
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
}

let incompleteStreamMessage = "The response ended before the model confirmed completion."

public struct HTTPModelProvider: ModelProvider {
    public let id: ProviderID
    public let displayName: String
    public let capabilities: ModelCapabilities

    private let wire: any WireFormat
    private let baseURL: URL
    private let apiKeyProvider: @Sendable () -> String?
    private let models: BrainModelDefaults
    private let transport: any HTTPLineStreaming
    private let readContextWindow: @Sendable (ModelTier) async throws -> Int?

    public init(
        wire: ProviderPreset.Wire,
        id: ProviderID,
        displayName: String,
        baseURL: URL,
        apiKeyProvider: @escaping @Sendable () -> String? = { nil },
        models: BrainModelDefaults,
        capabilities: ModelCapabilities = [.tools, .streaming],
        transport: any HTTPLineStreaming = URLSessionLineStreaming(),
        contextWindow: @escaping @Sendable (ModelTier) async throws -> Int? = { _ in nil }
    ) {
        let format = wire.format
        self.wire = format
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiKeyProvider = apiKeyProvider
        self.models = models
        var resolved = format.fixedCapabilities ?? capabilities
        if baseURL.isLoopback { resolved.insert(.local) }
        self.capabilities = resolved
        self.transport = transport
        self.readContextWindow = contextWindow
    }

    public func warm() async {
        await transport.preconnect(to: baseURL)
    }

    public func contextWindow(for tier: ModelTier) async throws -> Int? {
        try await readContextWindow(tier)
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        let provider = self
        return BrainHTTP.eventStream { try await provider.run(request, into: $0) }
    }

    private func run(_ request: ModelRequest, into continuation: AsyncThrowingStream<ModelEvent, Error>.Continuation) async throws {
        let (response, rawLines) = try await transport.lines(for: makeRequest(request))
        let lines = try await BrainHTTP.requireSuccess(response, lines: rawLines, provider: id)

        var parser = SSEParser()
        var decoder = wire.makeDecoder(provider: id)
        for try await line in lines {
            try Task.checkCancellation()
            guard let event = parser.feed(line: line) else { continue }
            for modelEvent in try decoder.consume(event) { continuation.yield(modelEvent) }
            if decoder.isComplete { break }
        }
        if !decoder.isComplete, let event = parser.finish() {
            for modelEvent in try decoder.consume(event) { continuation.yield(modelEvent) }
        }
        for modelEvent in try decoder.finish() { continuation.yield(modelEvent) }
    }

    func makeRequest(_ request: ModelRequest) throws -> URLRequest {
        let model = models.model(for: request.tier)
        var urlRequest = try BrainHTTP.post(baseURL, path: wire.path(model: model), query: wire.streamQuery)
        let key = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key, !key.isEmpty {
            wire.authorize(&urlRequest, key: key)
        } else if wire.requiresKey {
            throw ModelProviderError(kind: .unauthenticated, provider: id, message: "API key is missing")
        }
        urlRequest.httpBody = try JSONValue.object(wire.body(for: request, model: model)).data()
        return urlRequest
    }
}

extension URL {
    var isLoopback: Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }
}

extension [ModelContentPart] {
    var joinedText: String {
        compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
    }

    var containsImage: Bool {
        contains { part in
            if case .image = part { return true }
            return false
        }
    }
}

extension Data {
    func dataURL(mimeType: String) -> String {
        "data:\(mimeType);base64,\(base64EncodedString())"
    }
}

extension ToolCall {
    var argumentsJSON: String {
        String(decoding: (try? arguments.data()) ?? Data(), as: UTF8.self)
    }
}
