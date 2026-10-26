import Foundation
import PerryBrain
import PerryOverlay

@propertyWrapper
struct Preference<Value> {
    let key: String
    let fallback: Value
    private let decode: (Any) -> Value?
    private let encode: (Value) -> Any
    init(wrappedValue: Value, _ key: String) {
        self.key = key
        self.fallback = wrappedValue
        decode = { $0 as? Value }
        encode = { $0 }
    }
    init(wrappedValue: Value, _ key: String) where Value: RawRepresentable {
        self.key = key
        self.fallback = wrappedValue
        decode = { ($0 as? Value.RawValue).flatMap(Value.init(rawValue:)) }
        encode = { $0.rawValue }
    }
    var wrappedValue: Value {
        get { UserDefaults.standard.object(forKey: key).flatMap(decode) ?? fallback }
        nonmutating set {
            if let optional = newValue as? AnyOptionalPreference, optional.isNil {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set(encode(newValue), forKey: key)
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
    @Preference("perry.onboarding.dismissed") static var onboardingDismissed = false
    @Preference("perry.onboarding.openAtLogin") static var openAtLogin = true
    @Preference("perry.voice.pauseHintUses") static var pauseHintUses = 0
    @Preference("perry.notchStatus.enabled") static var notchStatusEnabled = true
    @Preference("perry.notch.hoverPeek") static var notchHoverPeek = true
    @Preference("perry.sounds.enabled") static var soundsEnabled = true
    @Preference("perry.home.frame") static var homeFrame: String? = nil
    @Preference("perry.lastSeenVersion") static var lastSeenVersion: String? = nil

    @Preference("perry.routine.offered") static var routineOffered = false

    // MARK: Invocation

    @Preference("perry.wakeWord.enabled") static var wakeWordEnabled = false
    @Preference("perry.gesture.type") static var typeGesture = Gesture.defaultType
    @Preference("perry.gesture.dictate") static var storedDictateGesture: String? = nil
    @Preference("perry.gesture.wake") static var storedWakeGesture: String? = nil
    @Preference("perry.ptt.shortcut") static var legacyPttShortcut: String? = nil
    @Preference("perry.wakeShortcut") static var legacyWakeShortcut: String? = nil

    static var dictateGesture: Gesture {
        get {
            migrated($storedDictateGesture, from: $legacyPttShortcut, fallback: .defaultDictate, legacy: [
                "functionHold": .hold([.function]),
                "optionCommandSpace": .chord([.option, .command], keyCode: 49),
                "capsLockDoubleTap": .doubleTap([.capsLock]),
                "controlOptionCommandHold": .hold([.control, .option, .command]),
            ])
        }
        set { storedDictateGesture = newValue.rawValue }
    }

    static var wakeGesture: Gesture {
        get {
            migrated($storedWakeGesture, from: $legacyWakeShortcut, fallback: .defaultWake, legacy: [
                "optionCommandP": .chord([.option, .command], keyCode: 35),
                "optionCommandO": .chord([.option, .command], keyCode: 31),
                "controlCommandP": .chord([.control, .command], keyCode: 35),
                "controlCommandO": .chord([.control, .command], keyCode: 31),
            ])
        }
        set { storedWakeGesture = newValue.rawValue }
    }

    private static func migrated(
        _ stored: Preference<String?>,
        from old: Preference<String?>,
        fallback: Gesture,
        legacy table: [String: Gesture]
    ) -> Gesture {
        if let saved = stored.wrappedValue.flatMap(Gesture.init(rawValue:)) { return saved }
        guard let value = old.wrappedValue, let gesture = table[value] else { return fallback }
        stored.wrappedValue = gesture.rawValue
        old.wrappedValue = nil
        return gesture
    }

    // MARK: Brain & providers

    @Preference("perry.brain.modelChoice") static var modelChoice = "chatGPT"
    @Preference("perry.brain.profiles") static var modelProfiles: Data? = nil
    @Preference("perry.brain.activeProfile") static var activeModelProfile: String? = nil
    @Preference("perry.brain.acpAgent") static var acpAgent: Data? = nil
    @Preference("perry.byok.vision.endpoint") static var byokVisionEndpoint: String? = nil
    @Preference("perry.byok.vision.model") static var byokVisionModel: String? = nil
    @Preference("perry.cua.driver.path") static var cuaDriverPath = ""
    @Preference("perry.local.memoryBudget") static var localMemoryBudget = "nothing"
    @Preference("perry.local.cloudFallback") static var localCloudFallback = "ask"

    // MARK: Voice & dictation

    @Preference("perry.speech.outputEnabled") static var speechOutputEnabled = true
    @Preference("perry.speech.rate") static var speechRate = 1.0
    @Preference("perry.speech.voiceIdentifier") static var speechVoiceIdentifier: String? = nil
    @Preference("perry.speech.engine") static var speechEngine = ""
    @Preference("perry.setup.priority") static var setupPriority = SetupPriority.recommended
    @Preference("perry.privacy.hidePersonalDetails") static var hidePersonalDetails = false
    @Preference("perry.dictation.language") static var dictationLanguage = "automatic"
    @Preference("perry.dictation.inputDeviceID") static var dictationInputDeviceID: Int? = nil
    @Preference("perry.gesture.talk") static var talkGesture = Gesture.defaultTalk
    @Preference("perry.realtimeVoice.provider") static var realtimeVoiceProvider: String? = nil
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
