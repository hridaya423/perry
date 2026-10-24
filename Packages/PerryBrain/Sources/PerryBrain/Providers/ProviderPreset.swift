import Foundation
import PerryCore

public struct ProviderPreset: Sendable, Identifiable, Equatable {
    public enum Wire: Sendable, Equatable {
        case openAIResponses, anthropic, gemini, openAIChat
    }

    public let id: String
    public let name: String
    public let wire: Wire
    public let baseURL: URL?
    public let keyRequired: Bool
    public let suggested: BrainModelDefaults?

    public var isLocal: Bool { baseURL.map(Self.isLoopback) ?? false }

    public static let custom = ProviderPreset(id: "custom", name: "Custom OpenAI-compatible", wire: .openAIChat, baseURL: nil, keyRequired: false, suggested: nil)

    public static let all: [ProviderPreset] = [
        cloud("openai", "OpenAI", .openAIResponses, "https://api.openai.com", BrainModelCatalog.openAI),
        cloud("anthropic", "Anthropic", .anthropic, "https://api.anthropic.com", BrainModelCatalog.anthropic),
        cloud("gemini", "Google Gemini", .gemini, "https://generativelanguage.googleapis.com", BrainModelCatalog.gemini),
        cloud("openrouter", "OpenRouter", .openAIChat, "https://openrouter.ai/api", BrainModelCatalog.openRouter),
        cloud("xai", "xAI", .openAIChat, "https://api.x.ai", nil),
        cloud("groq", "Groq", .openAIChat, "https://api.groq.com/openai", nil),
        cloud("cerebras", "Cerebras", .openAIChat, "https://api.cerebras.ai", nil),
        cloud("mistral", "Mistral", .openAIChat, "https://api.mistral.ai", nil),
        cloud("deepseek", "DeepSeek", .openAIChat, "https://api.deepseek.com", nil),
        cloud("together", "Together AI", .openAIChat, "https://api.together.xyz", nil),
        cloud("fireworks", "Fireworks", .openAIChat, "https://api.fireworks.ai/inference", nil),
        local("ollama", "Ollama", "http://127.0.0.1:11434"),
        local("lmstudio", "LM Studio", "http://127.0.0.1:1234"),
        local("llamacpp", "llama.cpp server", "http://127.0.0.1:8080"),
        local("vllm", "vLLM", "http://127.0.0.1:8000"),
        local("jan", "Jan", "http://127.0.0.1:1337"),
        custom,
    ]

    public static func preset(id: String) -> ProviderPreset? {
        all.first { $0.id == id }
    }

    public static func preset(forHost host: String) -> ProviderPreset? {
        all.first { $0.baseURL?.host?.caseInsensitiveCompare(host) == .orderedSame && !$0.isLocal }
    }

    public func makeProvider(
        id: ProviderID, displayName: String, baseURL: URL, key: String?,
        models: BrainModelDefaults, capabilities: ModelCapabilities,
        transport: any HTTPLineStreaming
    ) -> any ModelProvider {
        let keyProvider: @Sendable () -> String? = { key }
        switch wire {
        case .openAIResponses:
            return OpenAIResponsesProvider(id: id, displayName: displayName, baseURL: baseURL, apiKeyProvider: keyProvider, models: models, transport: transport)
        case .anthropic:
            return AnthropicMessagesProvider(id: id, displayName: displayName, baseURL: baseURL, apiKeyProvider: keyProvider, models: models, transport: transport)
        case .gemini:
            return GeminiProvider(id: id, displayName: displayName, baseURL: baseURL, apiKeyProvider: keyProvider, models: models, transport: transport)
        case .openAIChat:
            return OpenAIChatCompatibleProvider(id: id, displayName: displayName, baseURL: baseURL, apiKeyProvider: keyProvider, models: models, capabilities: capabilities, transport: transport)
        }
    }

    public func modelsRequest(baseURL: URL, key: String?) throws -> URLRequest {
        try NetworkEndpointPolicy.requireSafe(baseURL)
        let path = wire == .gemini ? "v1beta/models" : "v1/models"
        let suffix = baseURL.lastPathComponent == "v1" ? String(path.dropFirst(3)) : path
        var request = URLRequest(url: baseURL.appendingPathComponent(suffix), timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            switch wire {
            case .anthropic:
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            case .gemini:
                request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            case .openAIResponses, .openAIChat:
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    public func listModels(baseURL: URL, key: String?, session: URLSession = .shared) async throws -> [String] {
        let (data, response) = try await session.data(for: modelsRequest(baseURL: baseURL, key: key))
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw BrainHTTP.error(for: http, body: data, provider: ProviderID(rawValue: id))
        }
        return Self.modelIDs(from: data)
    }

    public static func modelIDs(from data: Data) -> [String] {
        guard let payload = try? JSONValue(parsing: data) else { return [] }
        let entries = payload["data"]?.arrayValue ?? payload["models"]?.arrayValue ?? []
        let ids = entries.compactMap { entry -> String? in
            if let id = entry["id"]?.stringValue { return id }
            guard let name = entry["name"]?.stringValue else { return nil }
            return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
        }
        return Array(Set(ids)).sorted()
    }

    private static func cloud(_ id: String, _ name: String, _ wire: Wire, _ url: String, _ suggested: BrainModelDefaults?) -> ProviderPreset {
        ProviderPreset(id: id, name: name, wire: wire, baseURL: URL(string: url)!, keyRequired: true, suggested: suggested)
    }

    private static func local(_ id: String, _ name: String, _ url: String) -> ProviderPreset {
        ProviderPreset(id: id, name: name, wire: .openAIChat, baseURL: URL(string: url)!, keyRequired: false, suggested: nil)
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }
}
