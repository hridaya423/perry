import Foundation

public struct LocalModel: Equatable, Sendable {
    public enum Server: String, Sendable {
        case ollama
        case lmStudio
    }
    public let server: Server
    public let baseURL: URL
    public let name: String
    public let supportsVision: Bool

    public init(server: Server, baseURL: URL, name: String, supportsVision: Bool) {
        self.server = server
        self.baseURL = baseURL
        self.name = name
        self.supportsVision = supportsVision
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

    func probeOllama(baseURL: URL = URL(string: "http://127.0.0.1:11434")!) async -> [LocalModel] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = timeout
        guard let (data, response) = try? await fetch(request),
              (200..<300).contains(response.statusCode),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = payload["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { model in
            guard let name = model["name"] as? String else { return nil }
            let families = (model["details"] as? [String: Any])?["families"] as? [String] ?? []
            let vision = families.contains(where: { ["clip", "mllama"].contains($0) })
                || name.lowercased().range(of: "llava|vision|vl|gemma3|qwen2\\.5vl|qwen3-vl|llama3\\.2-vision|minicpm-v", options: .regularExpression) != nil
            return LocalModel(server: .ollama, baseURL: baseURL, name: name, supportsVision: vision)
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
            let vision = name.lowercased().range(of: "llava|vision|vl|gemma3|qwen2\\.5vl|qwen3-vl|llama3\\.2-vision|minicpm-v", options: .regularExpression) != nil
            return LocalModel(server: .lmStudio, baseURL: baseURL, name: name, supportsVision: vision)
        }
    }
}
