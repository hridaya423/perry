import Foundation

public enum SetupPriority: String, CaseIterable, Sendable {
    case recommended, quality, privacy
}

public struct SetupFacts: Equatable, Sendable {
    public var memoryGB: Int
    public var macOSMajor: Int
    public var speechAnalyzerSupportsLocale: Bool
    public var premiumSystemVoice: String?
    public var kokoroInstalled: Bool
    public var voiceKeys: Set<VoiceService>
    public var cloudBrainReady: Bool
    public var localBrainCapable: Bool
    public var priority: SetupPriority

    public init(memoryGB: Int, macOSMajor: Int, speechAnalyzerSupportsLocale: Bool = true, premiumSystemVoice: String? = nil,
                kokoroInstalled: Bool = false, voiceKeys: Set<VoiceService> = [], cloudBrainReady: Bool = false,
                localBrainCapable: Bool = false, priority: SetupPriority = .recommended) {
        self.memoryGB = memoryGB
        self.macOSMajor = macOSMajor
        self.speechAnalyzerSupportsLocale = speechAnalyzerSupportsLocale
        self.premiumSystemVoice = premiumSystemVoice
        self.kokoroInstalled = kokoroInstalled
        self.voiceKeys = voiceKeys
        self.cloudBrainReady = cloudBrainReady
        self.localBrainCapable = localBrainCapable
        self.priority = priority
    }
}

public enum VoiceService: String, CaseIterable, Sendable {
    case elevenLabs, openAI, cartesia
}

public struct SetupRecommendation: Equatable, Sendable {
    public enum Brain: Equatable, Sendable { case cloud, local }
    public enum Voice: Equatable, Sendable {
        case cloud(VoiceService)
        case system(String)
        case kokoro
        case installKokoro
        case guidedPremium
        case getKey(VoiceService)
    }
    public enum Hearing: Equatable, Sendable { case speechAnalyzer, onDevice }

    public var brain: Brain
    public var voice: Voice
    public var hearing: Hearing
    public var hidesPersonalDetails: Bool
    public var brainNote: String?
}

public enum SetupAdvisor {
    public static let kokoroMinimumMemoryGB = 16

    public static func recommend(_ facts: SetupFacts) -> SetupRecommendation {
        let brain = brain(for: facts)
        let privateCloud = brain == .cloud && facts.priority == .privacy
        return SetupRecommendation(
            brain: brain,
            voice: voice(for: facts),
            hearing: facts.macOSMajor >= 26 && facts.speechAnalyzerSupportsLocale ? .speechAnalyzer : .onDevice,
            hidesPersonalDetails: brain == .cloud && facts.priority != .quality,
            brainNote: privateCloud && !facts.localBrainCapable
                ? "This Mac can chat privately but can’t use your apps well, so the brain stays in the cloud with personal details hidden."
                : nil
        )
    }

    private static func brain(for facts: SetupFacts) -> SetupRecommendation.Brain {
        guard facts.localBrainCapable else { return .cloud }
        return facts.priority == .privacy || !facts.cloudBrainReady ? .local : .cloud
    }

    private static func voice(for facts: SetupFacts) -> SetupRecommendation.Voice {
        if facts.priority != .privacy, let service = VoiceService.allCases.first(where: facts.voiceKeys.contains) {
            return .cloud(service)
        }
        if facts.priority == .quality { return .getKey(.elevenLabs) }
        if facts.kokoroInstalled { return .kokoro }
        if let premium = facts.premiumSystemVoice { return .system(premium) }
        return facts.memoryGB >= kokoroMinimumMemoryGB ? .installKokoro : .guidedPremium
    }
}
