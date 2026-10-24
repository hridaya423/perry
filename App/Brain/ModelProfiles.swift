import Foundation
import PerryBrain

struct ModelProfile: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var presetID: String
    var baseURL: URL
    var model: String
    var fastModel: String?
    var keyAccount: String

    init(id: String = UUID().uuidString, presetID: String, baseURL: URL, model: String, fastModel: String? = nil, keyAccount: String? = nil) {
        self.id = id
        self.presetID = presetID
        self.baseURL = baseURL
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fastModel = fastModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyAccount = keyAccount ?? "brain.profile.\(id)"
    }

    var preset: ProviderPreset { ProviderPreset.preset(id: presetID) ?? .custom }
    var providerID: ProviderID { ProviderID(rawValue: presetID) }
    var displayName: String { presetID == ProviderPreset.custom.id ? (baseURL.host ?? preset.name) : preset.name }

    var models: BrainModelDefaults {
        let fast = fastModel.flatMap { $0.isEmpty ? nil : $0 } ?? model
        return BrainModelDefaults(fast: fast, deep: model)
    }
}

struct ModelProfileStore {
    let defaults: UserDefaults

    func load() -> [ModelProfile] {
        if let data = defaults.data(forKey: PerryPreferences.$modelProfiles.key),
           let profiles = try? JSONDecoder().decode([ModelProfile].self, from: data) {
            return profiles
        }
        guard let legacy = legacyProfile() else { return [] }
        save([legacy])
        if activeID == nil { activeID = legacy.id }
        return [legacy]
    }

    func save(_ profiles: [ModelProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: PerryPreferences.$modelProfiles.key)
    }

    var activeID: String? {
        get { defaults.string(forKey: PerryPreferences.$activeModelProfile.key) }
        nonmutating set { defaults.set(newValue, forKey: PerryPreferences.$activeModelProfile.key) }
    }

    func active() -> ModelProfile? {
        let profiles = load()
        return profiles.first { $0.id == activeID } ?? profiles.first
    }

    private func legacyProfile() -> ModelProfile? {
        guard let rawURL = defaults.string(forKey: PerryPreferences.$byokVisionEndpoint.key),
              let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host,
              let model = defaults.string(forKey: PerryPreferences.$byokVisionModel.key),
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ModelProfile(
            id: "legacy",
            presetID: ProviderPreset.preset(forHost: host)?.id ?? ProviderPreset.custom.id,
            baseURL: url, model: model, keyAccount: RuntimeCatalog.byokVisionKeychainAccount
        )
    }
}
