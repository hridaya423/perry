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
    public init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        tier: TrustTier = .green,
        surfaces: Set<ToolSurface> = [.talk, .guide, .agent]
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.tier = tier
        self.surfaces = surfaces
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

    public init(
        system: String = "",
        messages: [ModelMessage],
        tools: [ToolSpec] = [],
        tier: ModelTier = .fast,
        maxOutputTokens: Int = 4096
    ) {
        self.system = system
        self.messages = messages
        self.tools = tools
        self.tier = tier
        self.maxOutputTokens = maxOutputTokens
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

    public var errorDescription: String? { "\(provider.rawValue): \(message)" }
}

public protocol ModelProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var capabilities: ModelCapabilities { get }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error>
    func warm() async
}
