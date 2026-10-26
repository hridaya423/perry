import Foundation
import PerryGuide

enum RealtimeProviderID: String, CaseIterable, Sendable {
    case openAI
    case grok
    case custom
}

struct RealtimeProvider: Equatable, Sendable {
    enum Billing: Equatable, Sendable {
        case perToken
        case perMinute
    }

    static let legacyKeychainAccount = "realtime.voice"

    let id: RealtimeProviderID
    let name: String
    let endpoint: URL?
    let model: String
    let modelFamily: String
    let voices: [String]
    let transcriptionModel: String
    let billing: Billing
    let costNote: String

    var keychainAccount: String { "\(Self.legacyKeychainAccount).\(id.rawValue)" }

    init(_ id: RealtimeProviderID) {
        self.id = id
        switch id {
        case .openAI:
            name = "OpenAI Realtime"
            endpoint = URL(string: "wss://api.openai.com/v1/realtime")
            model = RealtimeVoiceConfiguration.openAIModel
            modelFamily = "gpt-realtime"
            voices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
            transcriptionModel = "gpt-4o-transcribe"
            billing = .perToken
            costNote = "Charged for the audio you send and hear. Nothing while idle."
        case .grok:
            name = "Grok Voice"
            endpoint = URL(string: "wss://api.x.ai/v1/realtime")
            model = "grok-voice-latest"
            modelFamily = "grok-voice"
            voices = ["eve", "ara", "rex", "sal", "leo"]
            transcriptionModel = "grok-transcribe"
            billing = .perMinute
            costNote = "Charged by the minute while connected. Perry connects when you talk and hangs up after."
        case .custom:
            name = "Custom endpoint"
            endpoint = nil
            model = ""
            modelFamily = ""
            voices = []
            transcriptionModel = "gpt-4o-transcribe"
            billing = .perToken
            costNote = "Billed by your provider under its own terms."
        }
    }

    static var current: RealtimeProvider? {
        if let raw = PerryPreferences.realtimeVoiceProvider, let id = RealtimeProviderID(rawValue: raw) {
            return RealtimeProvider(id)
        }
        guard let host = storedEndpoint?.host else { return nil }
        if host.contains("api.openai.com") { return RealtimeProvider(.openAI) }
        if host.contains("api.x.ai") { return RealtimeProvider(.grok) }
        return RealtimeProvider(.custom)
    }

    private static var storedEndpoint: URL? {
        guard let raw = PerryPreferences.realtimeVoiceEndpoint,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["wss", "ws"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    func configuration() -> RealtimeVoiceConfiguration? {
        guard let endpoint = endpoint ?? Self.storedEndpoint else { return nil }
        let stored = PerryPreferences.realtimeVoiceModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model: String
        if id == .custom {
            model = stored
        } else {
            let fits = stored.hasPrefix(modelFamily) && !RealtimeVoiceConfiguration.retiredOpenAIModels.contains(stored)
            model = fits ? stored : self.model
        }
        guard !model.isEmpty else { return nil }
        let storedVoice = PerryPreferences.realtimeVoiceVoice
        let storedProtocol = RealtimeVoiceProtocolMode(rawValue: PerryPreferences.realtimeVoiceProtocol) ?? .automatic
        return RealtimeVoiceConfiguration(
            endpoint: endpoint,
            model: model,
            voice: voices.isEmpty || voices.contains(storedVoice) ? storedVoice : voices[0],
            responseSpeed: PerryPreferences.realtimeVoiceSpeed,
            instructions: PerryPreferences.realtimeVoiceInstructions,
            protocolMode: id == .grok ? .grok : storedProtocol,
            transcriptionModel: transcriptionModel,
            provider: id
        )
    }

    func apiKey(keychain: KeychainStore = KeychainStore()) throws -> String? {
        if let key = try keychain.readChecked(account: keychainAccount), !key.isEmpty { return key }
        guard PerryPreferences.realtimeVoiceProvider == nil,
              let legacy = try keychain.readChecked(account: Self.legacyKeychainAccount),
              !legacy.isEmpty else { return nil }
        try keychain.save(legacy, account: keychainAccount)
        try keychain.deleteChecked(account: Self.legacyKeychainAccount)
        PerryPreferences.realtimeVoiceProvider = id.rawValue
        return legacy
    }
}
