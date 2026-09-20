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

public struct DirectProviderRuntime: TaskPlanner {
    public let id: String
    public let capabilities = RuntimeCapabilities(guiGrounding: true, fileIO: false, browser: false, remoteIntegrations: true, latencyClass: .medium)

    private let configuration: DirectProviderConfiguration
    private let client: DirectProviderClient

    public init(
        configuration: DirectProviderConfiguration,
        apiKeyProvider: @escaping @Sendable () -> String?,
        transport: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil
    ) {
        self.configuration = configuration
        id = configuration.provider.runtimeID
        client = DirectProviderClient(
            configuration: configuration,
            apiKeyProvider: apiKeyProvider,
            transport: transport
        )
    }

    public func plan(_ request: PlanningRequest) async throws -> ExecutionPlan {
        guard case .screen(let context) = request.context else {
            throw PlanningError.contextRequired
        }
        let text = try await client.complete(
            prompt: TypedPlanningPrompt.make(goal: request.goal, context: context),
            screenshot: context.screenshotJPEGData.map { ($0, context.screenshotMIMEType) }
        )
        return try TypedPlanParser.plan(
            text,
            request: request,
            bindings: .init(request: request, context: context)
        )
    }
}
