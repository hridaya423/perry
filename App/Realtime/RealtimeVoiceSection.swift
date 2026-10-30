import PerryGuide
import SwiftUI

struct RealtimeVoiceSection: View {
    static let off = "off"

    var keychain = KeychainStore()
    let onError: (String) -> Void
    @AppStorage(PerryPreferences.$realtimeVoiceProvider.key) private var providerRaw: String?
    @AppStorage(PerryPreferences.$realtimeVoiceEndpoint.key) private var endpoint = ""
    @AppStorage(PerryPreferences.$realtimeVoiceModel.key) private var model = ""
    @AppStorage(PerryPreferences.$realtimeVoiceVoice.key) private var voice = "marin"
    @AppStorage(PerryPreferences.$realtimeVoiceSpeed.key) private var speed = 1.0
    @AppStorage(PerryPreferences.$realtimeVoiceInstructions.key) private var instructions = PerryPreferences.$realtimeVoiceInstructions.fallback
    @AppStorage(PerryPreferences.$realtimeVoiceProtocol.key) private var protocolRaw = RealtimeVoiceProtocolMode.automatic.rawValue
    @State private var key = ""
    @State private var keySaved = false

    private var provider: RealtimeProvider? { RealtimeProvider.current }

    var body: some View {
        SettingsCard(footer: footer) {
            SettingsPicker(title: "Provider", selection: Binding(
                get: { provider?.id.rawValue ?? Self.off },
                set: { providerRaw = $0 }
            )) {
                Text("Off").tag(Self.off)
                ForEach(RealtimeProviderID.allCases, id: \.rawValue) { id in
                    Text(RealtimeProvider(id).name).tag(id.rawValue)
                }
            }
            if let provider {
                Text(provider.costNote)
                    .settingNote()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                SettingsDivider()
                if provider.id == .custom {
                    field("Endpoint", text: $endpoint, prompt: "wss://…")
                    SettingsDivider()
                    field("Model", text: $model, prompt: "Model name")
                    SettingsDivider()
                    field("Voice", text: $voice, prompt: "Voice")
                } else {
                    SettingsPicker(title: "Voice", selection: Binding(
                        get: { provider.voices.contains(voice) ? voice : provider.voices[0] },
                        set: { voice = $0 }
                    )) {
                        ForEach(provider.voices, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                }
                SettingsDivider()
                HStack(spacing: PerryTheme.Spacing.inline) {
                    SecureField("API key", text: $key, prompt: Text(keySaved ? "Saved. Paste a new key to replace it" : "Paste your key"))
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { save(for: provider) }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .settingsRowPadding()
                SettingsDivider()
                if provider.id == .custom {
                    SettingsPicker(title: "Protocol", selection: $protocolRaw) {
                        ForEach(RealtimeVoiceProtocolMode.allCases, id: \.rawValue) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                } else {
                    field("Model", text: $model, prompt: provider.model)
                }
                SettingsDivider()
                SettingsRow(title: "Response speed") {
                    InkSlider(value: $speed, range: 0.25...1.5, step: 0.05, label: "Response speed")
                        .frame(width: 160)
                    Text("\(speed, specifier: "%.2f")×")
                        .font(PerryTheme.Scale.value)
                        .frame(width: PerryTheme.Sizing.realtimeRateValueWidth, alignment: .trailing)
                }
                SettingsDivider()
                TextField("Voice instructions", text: $instructions, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                    .settingsRowPadding()
            }
        }
        .onAppear(perform: refreshKey)
        .onChange(of: providerRaw) { _, _ in refreshKey() }
    }

    private var footer: String {
        guard let provider else {
            return "Perry speaks with on-device voices. Pick a provider for faster, more natural speech."
        }
        return "Audio and replies stream through \(provider.id == .custom ? "your endpoint" : provider.name) under its data policies."
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        SettingsRow(title: title) {
            TextField(title, text: text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
        }
    }

    private func refreshKey() {
        key = ""
        keySaved = (try? provider?.apiKey(keychain: keychain)).flatMap { $0 } != nil
    }

    private func save(for provider: RealtimeProvider) {
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return }
        do {
            try keychain.save(secret, account: provider.keychainAccount)
            providerRaw = provider.id.rawValue
            key = ""
            keySaved = true
        } catch {
            onError(error.localizedDescription)
        }
    }
}
