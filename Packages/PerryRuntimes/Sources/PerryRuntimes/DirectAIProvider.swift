import Foundation
import PerryCore

public enum DirectAIProvider: String, CaseIterable, Codable, Sendable {
    case openAI
    case anthropic
    case gemini
    case openRouter

    public var runtimeID: String {
        "direct.\(rawValue.lowercased())"
    }

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Gemini"
        case .openRouter: return "OpenRouter"
        }
    }

    public var defaultBaseURL: URL {
        switch self {
        case .openAI: return URL(string: "https://api.openai.com")!
        case .anthropic: return URL(string: "https://api.anthropic.com")!
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com")!
        case .openRouter: return URL(string: "https://openrouter.ai/api")!
        }
    }

    public init?(officialHost host: String) {
        guard let provider = Self.allCases.first(where: { candidate in
            guard let officialHost = candidate.defaultBaseURL.host else { return false }
            return officialHost.caseInsensitiveCompare(host) == .orderedSame
        }) else { return nil }
        self = provider
    }
}

public struct DirectProviderConfiguration: Equatable, Sendable {
    public let provider: DirectAIProvider
    public let model: String
    public let baseURL: URL

    public init(provider: DirectAIProvider, model: String, baseURL: URL? = nil) {
        self.provider = provider
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL ?? provider.defaultBaseURL
    }
}
