import Foundation
import PerryCore

public struct ModelCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let vision = Self(rawValue: 1 << 0)
    public static let tools = Self(rawValue: 1 << 1)
    public static let streaming = Self(rawValue: 1 << 2)
    public static let realtimeAudio = Self(rawValue: 1 << 3)
    public static let local = Self(rawValue: 1 << 4)
    public static let longContext = Self(rawValue: 1 << 5)
}

public enum ModelTier: String, Sendable, Codable {
    case fast, deep
}

public struct ProviderID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

extension ProviderID {
    public static let codex: ProviderID = "codex"
    public static let openAI: ProviderID = "openai"
    public static let anthropic: ProviderID = "anthropic"
    public static let gemini: ProviderID = "gemini"
    public static let openRouter: ProviderID = "openrouter"
    public static let local: ProviderID = "local"
    public static let apple: ProviderID = "apple"

    public var displayName: String {
        switch self {
        case .codex: "ChatGPT"
        case .local: "Your local model"
        case .apple: "Apple Intelligence"
        default: ProviderPreset.preset(id: rawValue)?.name ?? rawValue
        }
    }
}

public enum ModelContentPart: Sendable, Equatable {
    case text(String)
    case image(data: Data, mimeType: String)
}

public enum ModelMessage: Sendable, Equatable {
    case user([ModelContentPart])
    case assistant(text: String, toolCalls: [ToolCall])
    case toolResult(callID: String, content: [ModelContentPart], isError: Bool)
}

public struct ToolSpec: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    /// Minimum trust tier, claimed by the spec author. The model cannot lower it per-call.
    public let tier: TrustTier
    public let surfaces: Set<ToolSurface>
    /// True when the tool cannot change anything (feeds MCP readOnlyHint).
    public let readOnly: Bool
    public let requiredCapabilities: ModelCapabilities
    public init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        tier: TrustTier = .green,
        surfaces: Set<ToolSurface> = [.talk, .guide, .agent],
        readOnly: Bool = false,
        requiredCapabilities: ModelCapabilities = [.tools]
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.tier = tier
        self.surfaces = surfaces
        self.readOnly = readOnly
        self.requiredCapabilities = requiredCapabilities.union(.tools)
    }
}

public struct ToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: JSONValue
    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ModelRequest: Sendable {
    public var system: String
    public var messages: [ModelMessage]
    public var tools: [ToolSpec]
    public var tier: ModelTier
    public var maxOutputTokens: Int
    /// Providers that keep server-side conversation state reuse it across
    /// requests sharing a key. Nil means every request stands alone.
    public var conversationKey: String?

    public init(
        system: String = "",
        messages: [ModelMessage],
        tools: [ToolSpec] = [],
        tier: ModelTier = .fast,
        maxOutputTokens: Int = 4096,
        conversationKey: String? = nil
    ) {
        self.system = system
        self.messages = messages
        self.tools = tools
        self.tier = tier
        self.maxOutputTokens = maxOutputTokens
        self.conversationKey = conversationKey
    }
}

public enum ModelStopReason: Sendable, Equatable {
    case endTurn, toolUse, maxTokens, cancelled, other(String)
}

public enum ModelEvent: Sendable, Equatable {
    case textDelta(String)
    case toolCall(ToolCall)
    case usage(inputTokens: Int, outputTokens: Int)
    case done(ModelStopReason)
}

public struct ModelProviderError: Error, Equatable, LocalizedError {
    public enum Kind: Equatable {
        case notConfigured, unauthenticated, rateLimited(resetAt: Date?), http(Int), network, malformed, unavailable, cancelled
    }
    public let kind: Kind
    public let provider: ProviderID
    public let message: String

    public init(kind: Kind, provider: ProviderID, message: String) {
        self.kind = kind
        self.provider = provider
        self.message = message
    }

    public var errorDescription: String? { message }
}

public protocol ModelProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var capabilities: ModelCapabilities { get }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error>
    func warm() async
    func contextWindow(for tier: ModelTier) async throws -> Int?
}

public typealias ToolExecutionHandler = @Sendable (ToolCall) async throws -> ToolResult

public protocol ToolExecutingModelProvider: ModelProvider {
    func stream(_ request: ModelRequest, executeTool: @escaping ToolExecutionHandler) -> AsyncThrowingStream<ModelEvent, Error>
}

extension ModelProvider {
    public func contextWindow(for tier: ModelTier) async throws -> Int? { nil }
}

enum ModelContextError: LocalizedError {
    case invalidCapacity
    case requestTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidCapacity: "The selected model reported an invalid context size. Check its server settings."
        case .requestTooLarge: "Perry’s context estimate exceeds this model’s limit. Shorten the request or choose a model with more context. Your conversation is still saved."
        }
    }
}

extension ModelRequest {
    public func reservingOutput(in contextWindow: Int?) throws -> ModelRequest {
        guard let contextWindow else { return self }
        guard contextWindow > 0 else { throw ModelContextError.invalidCapacity }
        var request = self
        request.maxOutputTokens = min(maxOutputTokens, max(1, contextWindow / 4))
        let input = try textTokenEstimate()
        guard input <= contextWindow - request.maxOutputTokens else { throw ModelContextError.requestTooLarge }
        return request
    }

    func remainingInputBudget(in capacity: Int?) throws -> Int? {
        guard let capacity else { return nil }
        let request = try reservingOutput(in: capacity)
        let input = try request.textTokenEstimate()
        return capacity - request.maxOutputTokens - input
    }

    private func textTokenEstimate() throws -> Int {
        var size = system.utf8.count + 512
        for tool in tools {
            size += tool.name.utf8.count + tool.description.utf8.count + (try tool.inputSchema.data()).count + 64
        }
        for message in messages {
            size += 32
            let parts: [ModelContentPart]
            switch message {
            case .user(let content): parts = content
            case .assistant(let text, let calls):
                parts = [.text(text)]
                for call in calls {
                    size += call.id.utf8.count + call.name.utf8.count + (try call.arguments.data()).count + 32
                }
            case .toolResult(let id, let content, _):
                size += id.utf8.count
                parts = content
            }
            for part in parts {
                switch part {
                case .text(let text): size += text.utf8.count
                case .image: break
                }
            }
        }
        return size
    }
}
