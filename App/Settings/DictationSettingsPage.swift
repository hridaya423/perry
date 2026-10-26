import PerryCore
import SwiftUI

struct DictationSettingsPage: View {
    let controller: AppController
    @AppStorage(PerryPreferences.$dictationLanguage.key) private var languageRaw = "automatic"
    @AppStorage(PerryPreferences.$dictationInputDeviceID.key) private var inputDeviceRaw = 0
    @State private var inputDevices: [DictationInputDevice] = []
    @State private var inputDeviceStatus = ""
    @State private var entries: [String: String] = [:]
    @State private var newSpoken = ""
    @State private var newReplacement = ""
    @State private var error: String?

    var body: some View {
        SettingsScroll {
            SettingsCard(title: "Input", footer: inputDeviceStatus.isEmpty ? nil : inputDeviceStatus) {
                SettingsPicker(title: "Microphone", selection: $inputDeviceRaw) {
                    Text("Automatic").tag(0)
                    ForEach(inputDevices) { device in
                        Text(device.isBuiltIn ? "\(device.name) · Built-in" : device.name)
                            .tag(Int(device.id))
                    }
                }
                .onChange(of: inputDeviceRaw) { _, _ in update() }
                SettingsDivider()
                SettingsRow(title: "Check the microphone") {
                    Button("Test") {
                        let deviceID = inputDeviceRaw == 0 ? nil : UInt32(inputDeviceRaw)
                        inputDeviceStatus = DictationController.inputDeviceIsAvailable(deviceID)
                            ? "Microphone is available."
                            : "That microphone is unavailable; Perry will use the built-in fallback."
                    }
                }
                SettingsDivider()
                SettingsPicker(title: "Language", selection: $languageRaw) {
                    Text("Automatic").tag("automatic")
                    ForEach(DictationController.supportedLanguageIdentifiers(), id: \.self) { identifier in
                        Text(DictationController.languageName(for: identifier)).tag(identifier)
                    }
                }
                .onChange(of: languageRaw) { _, _ in update() }
            }
            SettingsCard(title: "Your words", footer: "When you say the first phrase, Perry types the second.") {
                ForEach(entries.keys.sorted(), id: \.self) { spoken in
                    HStack(spacing: PerryTheme.Spacing.inline) {
                        Text(spoken)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                            .accessibilityHidden(true)
                        Text(entries[spoken] ?? "")
                        Spacer()
                        Button("Remove") {
                            do {
                                try controller.voice.removeVoiceDictionaryEntry(spoken: spoken)
                                reload()
                                update()
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Remove replacement for \(spoken)")
                    }
                    .font(PerryTheme.Scale.body)
                    .settingsRowPadding()
                    SettingsDivider()
                }
                HStack(spacing: PerryTheme.Spacing.inline) {
                    TextField("Spoken phrase", text: $newSpoken, prompt: Text("When I say"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    TextField("Replacement phrase", text: $newReplacement, prompt: Text("Type"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    Button("Add", action: add)
                        .disabled(trimmed(newSpoken).isEmpty || trimmed(newReplacement).isEmpty)
                }
                .settingsRowPadding()
            }
        }
        .onAppear {
            reload()
            inputDevices = DictationController.availableInputDevices()
        }
        .settingsErrorDialog($error)
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        do {
            try controller.voice.saveVoiceDictionaryEntry(spoken: trimmed(newSpoken), replacement: trimmed(newReplacement))
            reload()
            newSpoken = ""
            newReplacement = ""
            update()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reload() {
        do {
            entries = try controller.voice.voiceDictionaryEntries()
        } catch {
            entries = [:]
            self.error = error.localizedDescription
        }
    }

    private func update() {
        let language: DictationLanguageMode = languageRaw == "automatic" ? .automatic : .fixed(identifier: languageRaw)
        let current: [String: String]
        do {
            current = try controller.voice.voiceDictionaryEntries()
        } catch {
            self.error = error.localizedDescription
            return
        }
        controller.voice.updateDictationPreferences(
            DictationPreferences(
                language: language,
                customWords: Array(current.keys) + Array(current.values),
                inputDeviceID: inputDeviceRaw == 0 ? nil : UInt32(inputDeviceRaw)
            )
        )
    }
}
