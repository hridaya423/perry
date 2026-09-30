import Foundation

public struct LocalModel: Equatable, Sendable {
    public enum Server: String, Sendable {
        case ollama
        case lmStudio
    }
    public let server: Server
    public let baseURL: URL
    public let name: String
    public let revision: String?
    public var id: ProviderID { ProviderID(rawValue: "local.\(server.rawValue).\(name)") }

    public init(server: Server, baseURL: URL, name: String, revision: String? = nil) {
        self.server = server
        self.baseURL = baseURL
        self.name = name
        self.revision = revision
    }
}

public struct LocalServerDiscovery: Sendable {
    public typealias Fetcher = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let fetch: Fetcher
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 0.3, fetch: Fetcher? = nil) {
        self.timeout = timeout
        self.fetch = fetch ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return (data, http)
        }
    }

    public func discover() async -> [LocalModel] {
        async let ollama = probeOllama()
        async let lmStudio = probeLMStudio()
        return await ollama + lmStudio
    }

    public func loadedContextWindow(for model: LocalModel) async throws -> Int? {
        let path = model.server == .ollama ? "api/ps" : "api/v1/models"
        var request = URLRequest(url: model.baseURL.appendingPathComponent(path))
        request.timeoutInterval = timeout
        let (data, response) = try await fetch(request)
        guard (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        let payload = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let models = payload["models"]?.arrayValue else { throw URLError(.cannotParseResponse) }
        var capacities: [Int] = []
        for entry in models {
            switch model.server {
            case .ollama:
                guard entry["name"]?.stringValue == model.name || entry["model"]?.stringValue == model.name else { continue }
                if let capacity = Self.contextLength(entry["context_length"]) { capacities.append(capacity) }
            case .lmStudio:
                guard entry["type"]?.stringValue == "llm" else { continue }
                for instance in entry["loaded_instances"]?.arrayValue ?? [] {
                    guard entry["key"]?.stringValue == model.name || instance["id"]?.stringValue == model.name else { continue }
                    if let capacity = Self.contextLength(instance["config"]?["context_length"]) { capacities.append(capacity) }
                }
            }
        }
        return capacities.min()
    }

    private static func contextLength(_ value: JSONValue?) -> Int? {
        guard let count = value?.doubleValue, count.isFinite, count > 0,
              count.rounded(.down) == count, count < Double(Int.max) else { return nil }
        return Int(count)
    }

    func probeOllama(baseURL: URL = URL(string: "http://127.0.0.1:11434")!) async -> [LocalModel] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = timeout
        guard let (data, response) = try? await fetch(request),
              (200..<300).contains(response.statusCode),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = payload["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { model in
            guard let name = model["name"] as? String else { return nil }
            return LocalModel(server: .ollama, baseURL: baseURL, name: name, revision: model["digest"] as? String)
        }
    }

    func probeLMStudio(baseURL: URL = URL(string: "http://127.0.0.1:1234")!) async -> [LocalModel] {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        request.timeoutInterval = timeout
        guard let (data, response) = try? await fetch(request),
              (200..<300).contains(response.statusCode),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = payload["data"] as? [[String: Any]] else { return [] }
        return models.compactMap { model in
            guard let name = model["id"] as? String else { return nil }
            return LocalModel(server: .lmStudio, baseURL: baseURL, name: name)
        }
    }
}
