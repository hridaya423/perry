import AppKit
import AVFoundation
import PerryBrain
import PerryCore
import PerryGuide
import PerryOverlay
import SwiftUI

struct VoiceSettingsPage: View {
    let controller: AppController
    @AppStorage(PerryPreferences.$speechOutputEnabled.key) private var speechOutputEnabled = true
    @AppStorage(PerryPreferences.$speechRate.key) private var speechRate = 1.0
    @AppStorage(PerryPreferences.$speechVoiceIdentifier.key) private var speechVoiceIdentifier = ""
    @AppStorage(PerryPreferences.$speechEngine.key) private var engineRaw = ""
    @AppStorage(PerryPreferences.$voiceResponseCaptionOpacity.key) private var captionOpacity = PerryBundleConfig.defaultVoiceResponseCaptionOpacity
    @StateObject private var keyCapture = VoiceKeyCapture()
    @State private var cloudVoices: [VoiceService: [CloudVoiceOption]] = [:]
    @State private var pastedKey = ""
    @ObservedObject private var installer = KokoroInstaller.shared
    @State private var refresh = 0
    @State private var error: String?

    private var engine: SpeechEngineChoice { SpeechEngineChoice(rawValue: engineRaw) ?? .system }
    private var sample: String { SetupFactsProbe.sample(name: controller.memoryFiles?.profileField("Name") ?? SetupFactsProbe.firstName) }

    var body: some View {
        SettingsScroll {
            SettingsCard(title: "Spoken replies") {
                Toggle("Speak replies", isOn: $speechOutputEnabled)
                    .settingsRowPadding()
                    .onChange(of: speechOutputEnabled) { _, _ in save() }
                SettingsDivider()
                SettingsPicker(title: "Voice", detail: engineDetail, selection: Binding(get: { engine.rawValue }, set: { engineRaw = $0 })) {
                    Text("Natural voice on this Mac").tag(SpeechEngineChoice.kokoro.rawValue)
                    Text("Apple voice").tag(SpeechEngineChoice.system.rawValue)
                    Divider()
                    ForEach(VoiceService.allCases) { service in
                        Text(service.name).tag(SpeechEngineChoice.cloud(service).rawValue)
                    }
                }
                engineRows
                SettingsDivider()
                SettingsRow(title: "Speed") {
                    InkSlider(value: $speechRate, range: 0.5...1.5, step: 0.1, label: "Speech speed")
                        .frame(width: 180)
                        .onChange(of: speechRate) { _, _ in save() }
                    Text("\(speechRate, specifier: "%.1f")×")
                        .font(PerryTheme.Typography.value)
                        .frame(width: PerryTheme.Sizing.speechRateValueWidth, alignment: .trailing)
                }
            }
            PronunciationsCard(controller: controller)
            SettingsCard(title: "Captions") {
                SettingsRow(title: "Caption opacity") {
                    InkSlider(value: $captionOpacity, range: 0.55...1.0, step: 0.05, label: "Caption opacity")
                        .frame(width: 180)
                    Text("\(captionOpacity * 100, specifier: "%.0f")%")
                        .font(PerryTheme.Typography.value)
                        .frame(width: PerryTheme.Sizing.captionOpacityValueWidth, alignment: .trailing)
                }
            }
            SettingsAdvanced(title: "Realtime voice") {
                RealtimeVoiceSection(onError: { error = $0 })
            }
        }
        .settingsErrorDialog($error)
        .onAppear {
            keyCapture.onSaved = { service in
                engineRaw = SpeechEngineChoice.cloud(service).rawValue
                Task { await loadVoices(service) }
                controller.voice.preview(sample, engine: .cloud(service))
            }
        }
        .onDisappear { keyCapture.stop() }
        .onChange(of: installer.downloading) { _, downloading in
            guard !downloading else { return }
            if let failure = installer.failure { error = failure } else { controller.voice.preview(sample, engine: .kokoro) }
            refresh += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in refresh += 1 }
        .task(id: engineRaw) {
            if case .cloud(let service) = engine, service.hasKey, cloudVoices[service] == nil { await loadVoices(service) }
        }
    }

    private var engineDetail: String {
        switch engine {
        case .kokoro: "Private and free. Runs on this Mac."
        case .system: "Private and free. Premium voices sound best."
        case .cloud(let service): "\(service.name) speaks your replies. Uses your own key."
        }
    }

    @ViewBuilder
    private var engineRows: some View {
        switch engine {
        case .kokoro:
            if KokoroVoice.isInstalled {
                ForEach(KokoroVoice.voices) { option in
                    SettingsDivider()
                    VoiceOptionRow(name: option.name, detail: option.detail,
                                   isSelected: (UserDefaults.standard.string(forKey: KokoroVoice.voicePreferenceKey) ?? KokoroVoice.defaultVoice) == option.id,
                                   select: {
                                       UserDefaults.standard.set(option.id, forKey: KokoroVoice.voicePreferenceKey)
                                       refresh += 1
                                   },
                                   preview: { controller.voice.preview(sample, engine: .kokoro, voiceID: option.id) })
                }
                .id(refresh)
            } else {
                SettingsDivider()
                SettingsRow(title: "Download the natural voice", detail: "About 380 MB. It never leaves this Mac.") {
                    if installer.downloading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Download") { installer.start() }
                    }
                }
            }
        case .system:
            let voices = VoiceController.recommendedSpeechVoices(limit: 6)
            if voices.isEmpty {
                SettingsDivider()
                SettingsRow(title: "No natural Apple voice yet",
                            detail: "In Spoken Content, open Manage Voices and download Ava (Premium). Perry switches when it arrives.") {
                    Button("Open…", action: openVoiceManager)
                }
            } else {
                ForEach(voices, id: \.identifier) { voice in
                    SettingsDivider()
                    VoiceOptionRow(name: voice.name, detail: voice.quality == .premium ? "Premium" : "Enhanced",
                                   isSelected: voice.identifier == (speechVoiceIdentifier.isEmpty ? VoiceController.speakingVoice?.identifier : speechVoiceIdentifier),
                                   select: {
                                       speechVoiceIdentifier = voice.identifier
                                       save()
                                   },
                                   preview: { controller.voice.previewSpeechVoice(voice) })
                }
                .id(refresh)
                SettingsDivider()
                SettingsRow(title: "More voices", detail: "Premium voices are free in System Settings.") {
                    Button("Open…", action: openVoiceManager)
                }
            }
        case .cloud(let service):
            if service.hasKey {
                ForEach(cloudVoices[service] ?? [], id: \.id) { option in
                    SettingsDivider()
                    VoiceOptionRow(name: option.name, detail: option.detail,
                                   isSelected: (UserDefaults.standard.string(forKey: service.voicePreferenceKey) ?? service.defaultVoice.id) == option.id,
                                   select: {
                                       UserDefaults.standard.set(option.id, forKey: service.voicePreferenceKey)
                                       refresh += 1
                                   },
                                   preview: { controller.voice.preview(sample, engine: .cloud(service), voiceID: option.id) })
                }
                .id(refresh)
                SettingsDivider()
                SettingsRow(title: "\(service.name) key", detail: "Saved in your Keychain.") {
                    Button("Remove") {
                        try? KeychainStore().deleteChecked(account: service.keyAccount)
                        cloudVoices[service] = nil
                        refresh += 1
                    }
                }
            } else {
                SettingsDivider()
                SettingsRow(title: "Get your \(service.name) key", detail: keyDetail(service)) {
                    Button("Get key") { keyCapture.getKey(for: service) }
                }
                SettingsDivider()
                HStack(spacing: 8) {
                    SecureField("Or paste a key", text: $pastedKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submitKey)
                    Button("Save", action: submitKey)
                        .disabled(pastedKey.isEmpty)
                }
                .settingsRowPadding()
            }
        }
    }

    private func keyDetail(_ service: VoiceService) -> String {
        switch keyCapture.state {
        case .waiting(let waiting) where waiting == service: "Sign in, press Create key, then Copy. Perry picks it up."
        case .checking: "Checking the key…"
        case .failed(let message): message
        default: "Perry opens the page and picks up the key when you copy it."
        }
    }

    private func submitKey() {
        keyCapture.submit(pastedKey)
        pastedKey = ""
    }

    private func loadVoices(_ service: VoiceService) async {
        guard let key = service.storedKey() else { return }
        do {
            cloudVoices[service] = try await service.verify(key: key)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func openVoiceManager() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") else { return }
        NSWorkspace.shared.open(url)
    }

    private func save() {
        controller.voice.updateSpeechPreferences(
            SpeechPreferences(
                outputEnabled: speechOutputEnabled,
                rateMultiplier: speechRate,
                voiceIdentifier: speechVoiceIdentifier.isEmpty ? nil : speechVoiceIdentifier
            )
        )
    }
}

private struct VoiceOptionRow: View {
    let name: String
    let detail: String?
    let isSelected: Bool
    let select: () -> Void
    let preview: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: preview) {
                Image(systemName: "play.fill")
                    .font(PerryTheme.Icon.utility).imageScale(.small)
                    .frame(width: 24, height: 24)
                    .background(PerryTheme.Colors.chip, in: Circle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Preview \(name)")
            Button(action: select) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(PerryTheme.Scale.body)
                        .foregroundStyle(PerryTheme.Colors.text)
                    if let detail {
                        Text(detail)
                            .font(PerryTheme.Scale.body)
                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if isSelected { StatusMark(.ok) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(name)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .settingsRowPadding()
    }
}

private struct PronunciationsCard: View {
    let controller: AppController
    @State private var entries: [Pronunciation] = []
    @State private var written = ""
    @State private var spoken = ""

    private var store: PronunciationStore { PronunciationStore(directory: controller.storageDirectory) }

    var body: some View {
        SettingsCard(title: "Pronunciations", footer: "Perry says these names your way and hears them better too.") {
            ForEach(entries) { entry in
                HStack(spacing: 10) {
                    Button { controller.voice.speak(entry.written) } label: {
                        Image(systemName: "play.fill")
                            .font(PerryTheme.Icon.utility).imageScale(.small)
                            .frame(width: 24, height: 24)
                            .background(PerryTheme.Colors.chip, in: Circle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("Say \(entry.written)")
                    Text(entry.written).font(PerryTheme.Scale.body)
                    Text("says “\(entry.spoken)”").font(PerryTheme.Scale.body).foregroundStyle(PerryTheme.Colors.textSecondary)
                    Spacer()
                    Button {
                        try? store.remove(written: entry.written)
                        entries = store.entries()
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.pressable)
                    .foregroundStyle(PerryTheme.Colors.icon)
                    .accessibilityLabel("Remove \(entry.written)")
                }
                .settingsRowPadding()
                SettingsDivider()
            }
            HStack(spacing: 8) {
                TextField("Name", text: $written).textFieldStyle(.roundedBorder)
                TextField("Say it like", text: $spoken).textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(written.isEmpty || spoken.isEmpty)
            }
            .settingsRowPadding()
        }
        .onAppear { entries = store.entries() }
    }

    private func add() {
        try? store.set(Pronunciation(written: written, spoken: spoken))
        entries = store.entries()
        controller.voice.speak(written)
        written = ""
        spoken = ""
    }
}
