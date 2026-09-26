import Foundation

public struct BrainModelDefaults: Sendable {
    public var fast: String
    public var deep: String

    public init(fast: String, deep: String) {
        self.fast = fast
        self.deep = deep
    }

    public func model(for tier: ModelTier) -> String {
        switch tier {
        case .fast: return fast
        case .deep: return deep
        }
    }
}

public enum BrainModelCatalog {
    public static var openAI = BrainModelDefaults(fast: "gpt-5-mini", deep: "gpt-5")
    public static var anthropic = BrainModelDefaults(fast: "claude-haiku-4-5", deep: "claude-sonnet-4-5")
    public static var gemini = BrainModelDefaults(fast: "gemini-2.5-flash", deep: "gemini-2.5-pro")
    public static var openRouter = BrainModelDefaults(fast: "openai/gpt-5-mini", deep: "openai/gpt-5")
}
