import Foundation
import PerryOverlay

@propertyWrapper
struct Preference<Value> {
    let key: String
    let fallback: Value
    init(wrappedValue: Value, _ key: String) {
        self.key = key
        self.fallback = wrappedValue
    }
    var wrappedValue: Value {
        get { UserDefaults.standard.object(forKey: key) as? Value ?? fallback }
        nonmutating set {
            if let optional = newValue as? AnyOptionalPreference, optional.isNil {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set(newValue, forKey: key)
            }
        }
    }
    var projectedValue: Preference<Value> { self }
    func reset() { UserDefaults.standard.removeObject(forKey: key) }
}

private protocol AnyOptionalPreference {
    var isNil: Bool { get }
}

extension Optional: AnyOptionalPreference {
    var isNil: Bool { self == nil }
}

/// The only place UserDefaults keys live — every `perry.*` preference read
/// or write in the App target goes through here. scripts/ci.sh enforces it.
enum PerryPreferences {

    // MARK: Shell & onboarding

    @Preference("perry.settings.tab") static var settingsTab = "general"
    @Preference("perry.onboarding.completed") static var onboardingCompleted = false
    @Preference("perry.onboarding.beat") static var onboardingBeat: String? = nil
    @Preference("perry.onboarding.practice") static var onboardingPractice: String? = nil
    @Preference("perry.notchStatus.enabled") static var notchStatusEnabled = true
    @Preference("perry.home.frame") static var homeFrame: String? = nil
    @Preference("perry.lastSeenVersion") static var lastSeenVersion: String? = nil

    // MARK: Invocation

    @Preference("perry.wakeWord.enabled") static var wakeWordEnabled = false
    @Preference("perry.wakeShortcut") static var wakeShortcut = "optionCommandP"
    @Preference("perry.ptt.shortcut") static var pttShortcut = "functionHold"

    // MARK: Brain & providers

    @Preference("perry.brain.modelChoice") static var modelChoice = "chatGPT"
    @Preference("perry.brain.profiles") static var modelProfiles: Data? = nil
    @Preference("perry.brain.activeProfile") static var activeModelProfile: String? = nil
    @Preference("perry.brain.acpAgent") static var acpAgent: Data? = nil
    @Preference("perry.byok.vision.endpoint") static var byokVisionEndpoint: String? = nil
    @Preference("perry.byok.vision.model") static var byokVisionModel: String? = nil
    @Preference("perry.cua.driver.path") static var cuaDriverPath = ""

    // MARK: Voice & dictation

    @Preference("perry.speech.outputEnabled") static var speechOutputEnabled = true
    @Preference("perry.speech.rate") static var speechRate = 1.0
    @Preference("perry.speech.voiceIdentifier") static var speechVoiceIdentifier: String? = nil
    @Preference("perry.dictation.language") static var dictationLanguage = "automatic"
    @Preference("perry.dictation.inputDeviceID") static var dictationInputDeviceID: Int? = nil
    @Preference("perry.realtimeVoice.endpoint") static var realtimeVoiceEndpoint: String? = nil
    @Preference("perry.realtimeVoice.model") static var realtimeVoiceModel: String? = nil
    @Preference("perry.realtimeVoice.voice") static var realtimeVoiceVoice = "marin"
    @Preference("perry.realtimeVoice.speed") static var realtimeVoiceSpeed = 1.0
    @Preference("perry.realtimeVoice.instructions") static var realtimeVoiceInstructions = "You are Perry, a concise and helpful desktop voice assistant. Speak naturally and keep replies short unless the user asks for detail."
    @Preference("perry.realtimeVoice.protocol") static var realtimeVoiceProtocol = "automatic"

    // MARK: Workspace & tasks

    @Preference("perry.workspace.root") static var workspaceRoot: String? = nil
    @Preference("perry.suggestions.enabled") static var suggestionsEnabled = false
    @Preference("perry.suggestions.lastRunDay") static var suggestionsLastRunDay = 0.0
    @Preference("perry.suggestions.ignoredDays") static var suggestionsIgnoredDays = 0
    @Preference("perry.suggestions.pending") static var suggestionsPending: Data? = nil

    // MARK: Connected apps

    static let remoteWritesKeyPrefix = "perry.remote.writes."
    static func remoteWritesKey(for id: String) -> String { remoteWritesKeyPrefix + id }
    static let oauthStateKeyPrefix = "perry.oauth."

    // MARK: Overlay

    @Preference(PerryBundleConfig.userVoiceResponseCaptionOpacityDefaultsKey) static var voiceResponseCaptionOpacity = PerryBundleConfig.defaultVoiceResponseCaptionOpacity

    // MARK: Erasure

    static let allKeysPrefix = "perry."
}
