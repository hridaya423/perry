import Foundation

public struct BrainModelDefaults: Sendable, Equatable {
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
    public static var anthropic = BrainModelDefaults(fast: "claude-haiku-5-5", deep: "claude-sonnet-5-5")
    public static var gemini = BrainModelDefaults(fast: "gemini-2.5-flash", deep: "gemini-2.5-pro")
    public static var openRouter = BrainModelDefaults(fast: "openai/gpt-5-mini", deep: "openai/gpt-5")
    /// Codex account models measured in docs/evidence/phase-1/talk-brain-decision.md:
    /// terra at effort=none answers a vision turn in ~1.5 s; the server default
    /// (gpt-6-luna) reasons for tens of seconds before its first token.
    public static var codex = BrainModelDefaults(fast: "gpt-5.6-terra", deep: "gpt-6-luna")
}
