import AppKit
import AVFoundation
import SwiftUI
import PerryCore
import PerryGuide
import PerryOverlay
import PerryRuntimes

enum SettingsTab: String, CaseIterable {
    case general
    case voice
    case runtimes
    case integrations
    case memory
    case appearance
    case safety

    static let userDefaultsKey = "perry.settings.tab"
}

struct SettingsView: View {
    @AppStorage(SettingsTab.userDefaultsKey) private var selectedTab = SettingsTab.general.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("perry.wakeWord.enabled") private var wakeWordEnabled = false
    @AppStorage("perry.wakeShortcut") private var wakeShortcutRaw = WakeShortcut.optionCommandP.rawValue
    @AppStorage("perry.ptt.shortcut") private var pttShortcutRaw = PushToTalkShortcut.optionCommandSpace.rawValue
    @AppStorage(VoiceController.speechOutputEnabledKey) private var speechOutputEnabled = true
    @AppStorage(VoiceController.speechRateKey) private var speechRate = 1.0
    @AppStorage(VoiceController.speechVoiceKey) private var speechVoiceIdentifier = ""
    @AppStorage(VoiceController.dictationLanguageKey) private var dictationLanguageRaw = "automatic"
    @AppStorage(VoiceController.dictationInputDeviceKey) private var dictationInputDeviceRaw = 0
    @AppStorage(RuntimeCatalog.byokVisionProviderKey) private var byokVisionProviderRaw = RuntimeProviderSetupChoice.openAI.rawValue
    @AppStorage(RuntimeCatalog.byokVisionEndpointKey) private var byokVisionEndpoint = ""
    @AppStorage(RuntimeCatalog.byokVisionModelKey) private var byokVisionModel = ""
    @AppStorage(CuaDriverConfiguration.driverPathKey) private var cuaDriverPath = ""
    @AppStorage(VoiceController.realtimeVoiceEndpointKey) private var realtimeVoiceEndpoint = ""
    @AppStorage(VoiceController.realtimeVoiceModelKey) private var realtimeVoiceModel = ""
    @AppStorage(VoiceController.realtimeVoiceVoiceKey) private var realtimeVoiceVoice = "marin"
    @AppStorage(VoiceController.realtimeVoiceSpeedKey) private var realtimeVoiceSpeed = 1.0
    @AppStorage(VoiceController.realtimeVoiceInstructionsKey) private var realtimeVoiceInstructions = "You are Perry, a concise and helpful desktop voice assistant. Speak naturally and keep replies short unless the user asks for detail."
    @AppStorage(VoiceController.realtimeVoiceProtocolKey) private var realtimeVoiceProtocolRaw = RealtimeVoiceProtocolMode.automatic.rawValue
    @AppStorage(PerryBundleConfig.userVoiceResponseCaptionOpacityDefaultsKey) private var captionOpacity = PerryBundleConfig.defaultVoiceResponseCaptionOpacity
    @State private var memoryEnabled = false
    @State private var memoryCategoryToggles: [MemoryRecord.Category: Bool] = MemoryRecord.Category.allCases.reduce(into: [:]) { result, category in
        result[category] = true
    }
    @StateObject private var runtimeSettings = RuntimeSettingsState {
        async let setup = AppController.shared.runtimes.currentSetup()
        async let driverStatus = AppController.shared.probe.cuaHealth().summary
        return await RuntimeSettingsState.Status(setup: setup, cuaStatus: driverStatus)
    }
    @State private var dictionaryEntries: [String: String] = [:]
    @State private var inputDevices: [DictationInputDevice] = []
    @State private var inputDeviceStatus = ""
    @State private var skills: [AppSkill] = []
    @State private var skillEnabled: [String: Bool] = [:]
    @State private var newSpokenWord = ""
    @State private var newReplacement = ""
    @State private var byokVisionKey = ""
    @State private var byokVisionKeyIsSaved = false
    @State private var copiedRuntimeCommand: String?
    @State private var realtimeVoiceKey = ""
    @State private var settingsError: String?
    @State private var showRemoveVisionCredentialConfirmation = false
    @State private var showReportProblem = false

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab.tag(SettingsTab.general.rawValue)
            voiceAndInputTab.tag(SettingsTab.voice.rawValue)
            runtimesTab.tag(SettingsTab.runtimes.rawValue)
            integrationsTab.tag(SettingsTab.integrations.rawValue)
            memoryTab.tag(SettingsTab.memory.rawValue)
            appearanceTab.tag(SettingsTab.appearance.rawValue)
            safetyTab.tag(SettingsTab.safety.rawValue)
        }
        .frame(
            minWidth: PerryTheme.Sizing.settingsMinimumWidth,
            idealWidth: PerryTheme.Sizing.settingsWidth,
            minHeight: PerryTheme.Sizing.settingsMinimumHeight,
            idealHeight: PerryTheme.Sizing.settingsHeight
        )
        .tint(PerryTheme.Colors.accent)
        .foregroundStyle(PerryTheme.Colors.text)
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
        .alert("Perry could not save that setting", isPresented: Binding(
            get: { settingsError != nil },
            set: { if !$0 { settingsError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(settingsError ?? "Unknown settings error")
        }
    }

    private var generalTab: some View {
        Form {
            Section("Invocation") {
                Toggle("Say \"hey Perry\" to wake", isOn: $wakeWordEnabled)
                    .onChange(of: wakeWordEnabled) { _, value in
                        AppController.shared.voice.updateWakeWordEnabled(value)
                    }
                Text("Off by default. When on, Perry listens on device for the phrase and keeps no ambient transcript.")
                    .settingNote()
                Picker("Wake shortcut", selection: $wakeShortcutRaw) {
                    ForEach(WakeShortcut.allCases) { shortcut in
                        Text(shortcut.title).tag(shortcut.rawValue)
                    }
                }
                .onChange(of: wakeShortcutRaw) { _, value in
                    guard let shortcut = WakeShortcut(rawValue: value) else { return }
                    do {
                        try AppController.shared.updateWakeShortcut(shortcut)
                    } catch {
                        wakeShortcutRaw = UserDefaults.standard.string(forKey: "perry.wakeShortcut")
                            ?? WakeShortcut.optionCommandP.rawValue
                        settingsError = error.localizedDescription
                    }
                }
                Picker("Push to talk", selection: $pttShortcutRaw) {
                    ForEach(PushToTalkShortcut.allCases) { shortcut in
                        Text(shortcut.title).tag(shortcut.rawValue)
                    }
                }
                .onChange(of: pttShortcutRaw) { _, value in
                    guard let shortcut = PushToTalkShortcut(rawValue: value) else { return }
                    AppController.shared.voice.updatePushToTalkShortcut(shortcut)
                }
                Text("Hold the push-to-talk shortcut from any app. Caps Lock double-tap is available for hands-free use.")
                    .settingNote()
                Text("If voice input is unavailable, Perry leaves the panel ready for typing.")
                    .settingNote()
            }
        }
        .formStyle(.grouped)
        .tabItem { Label("General", systemImage: "switch.2") }
    }

    private var voiceAndInputTab: some View {
        Form {
            Section("Voice out") {
                Toggle("Speak replies", isOn: $speechOutputEnabled)
                    .onChange(of: speechOutputEnabled) { _, _ in saveSpeechPreferences() }
                Picker("Voice", selection: $speechVoiceIdentifier) {
                    Text("Best available").tag("")
                    ForEach(VoiceController.availableSpeechVoices(), id: \.identifier) { voice in
                        Text("\(voice.name) · \(voice.language)").tag(voice.identifier)
                    }
                }
                .onChange(of: speechVoiceIdentifier) { _, _ in saveSpeechPreferences() }
                HStack(spacing: PerryTheme.Spacing.inline) {
                    Text("Speed")
                    Slider(value: $speechRate, in: 0.5...1.5, step: 0.1, label: { Text("Speech speed") })
                        .labelsHidden()
                        .onChange(of: speechRate) { _, _ in saveSpeechPreferences() }
                    Text("\(speechRate, specifier: "%.1f")×")
                        .font(PerryTheme.Typography.value)
                        .frame(width: PerryTheme.Sizing.speechRateValueWidth, alignment: .trailing)
                }
                Button("Preview voice") {
                    let voice = AVSpeechSynthesisVoice(identifier: speechVoiceIdentifier) ?? VoiceController.speakingVoice
                    if let voice { AppController.shared.voice.previewSpeechVoice(voice) }
                }
                Text("Perry uses the system voice installed on this Mac. Voice previews never leave the device.")
                    .settingNote()
            }
            dictationSettings
            Section("Enhanced realtime voice (optional, BYOK)") {
                DisclosureGroup("Configure realtime voice") {
                    TextField("WebSocket endpoint", text: $realtimeVoiceEndpoint)
                        .textFieldStyle(.roundedBorder)
                    TextField("Realtime voice model", text: $realtimeVoiceModel)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: PerryTheme.Spacing.inline) {
                        TextField("Voice name", text: $realtimeVoiceVoice)
                            .textFieldStyle(.roundedBorder)
                        Picker("Protocol", selection: $realtimeVoiceProtocolRaw) {
                            ForEach(RealtimeVoiceProtocolMode.allCases, id: \.rawValue) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                        .frame(width: PerryTheme.Sizing.protocolPickerWidth)
                    }
                    HStack(spacing: PerryTheme.Spacing.inline) {
                        Text("Response speed")
                        Slider(value: $realtimeVoiceSpeed, in: 0.25...1.5, step: 0.05, label: { Text("Response speed") })
                            .labelsHidden()
                        Text("\(realtimeVoiceSpeed, specifier: "%.2f")×")
                            .font(PerryTheme.Typography.value)
                            .frame(width: PerryTheme.Sizing.realtimeRateValueWidth, alignment: .trailing)
                    }
                    TextField("Voice instructions", text: $realtimeVoiceInstructions, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                    SecureField("Realtime voice API key", text: $realtimeVoiceKey)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: PerryTheme.Spacing.inline) {
                        Button("Use OpenAI Realtime defaults") {
                            realtimeVoiceEndpoint = "wss://api.openai.com/v1/realtime"
                            if realtimeVoiceModel.isEmpty { realtimeVoiceModel = "gpt-realtime" }
                            realtimeVoiceProtocolRaw = RealtimeVoiceProtocolMode.automatic.rawValue
                        }
                        Button("Save realtime voice API key") {
                            saveSecret(realtimeVoiceKey, account: VoiceController.realtimeVoiceKeychainAccount) {
                                realtimeVoiceKey = ""
                            }
                        }
                    }
                }
                Text("On-device dictation is the everyday path — endpoint mechanics stay behind this disclosure. When configured, audio and responses stream through your realtime provider under its data policies; Perry keeps one duplex session open and cancels playback when you barge in.")
                    .settingNote()
            }
        }
        .formStyle(.grouped)
        .tabItem { Label("Voice & Input", systemImage: "waveform.and.mic") }
        .onAppear {
            reloadVoiceDictionary()
            inputDevices = DictationController.availableInputDevices()
        }
    }

    private var dictationSettings: some View {
        Section("Dictation") {
                Picker("Language", selection: $dictationLanguageRaw) {
                    Text("Automatic (detect each utterance)").tag("automatic")
                    ForEach(DictationController.supportedLanguageIdentifiers(), id: \.self) { identifier in
                        Text(DictationController.languageName(for: identifier)).tag(identifier)
                    }
                }
                .onChange(of: dictationLanguageRaw) { _, _ in updateDictationPreferences() }
                Picker("Microphone", selection: $dictationInputDeviceRaw) {
                    Text("Automatic").tag(0)
                    ForEach(inputDevices) { device in
                        Text(device.isBuiltIn ? "\(device.name) · Built-in" : device.name)
                            .tag(Int(device.id))
                    }
                }
                .onChange(of: dictationInputDeviceRaw) { _, _ in updateDictationPreferences() }
                Button("Test microphone") {
                    let deviceID = dictationInputDeviceRaw == 0 ? nil : UInt32(dictationInputDeviceRaw)
                    inputDeviceStatus = DictationController.inputDeviceIsAvailable(deviceID)
                        ? "Microphone is available."
                        : "That microphone is unavailable; Perry will use the built-in fallback."
                }
                if !inputDeviceStatus.isEmpty {
                    Text(inputDeviceStatus)
                        .settingNote()
                }
                Text("Custom words are sent as local speech context and applied to the final transcript.")
                    .settingNote()
                ForEach(dictionaryEntries.keys.sorted(), id: \.self) { spoken in
                    HStack(spacing: PerryTheme.Spacing.inline) {
                        Text(spoken)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                            .accessibilityHidden(true)
                        Text(dictionaryEntries[spoken] ?? "")
                        Spacer()
                        Button("Remove replacement") {
                            do {
                                try AppController.shared.voice.removeVoiceDictionaryEntry(spoken: spoken)
                                reloadVoiceDictionary()
                                updateDictationPreferences()
                            } catch {
                                settingsError = error.localizedDescription
                            }
                        }
                        .accessibilityLabel("Remove replacement for \(spoken)")
                        .buttonStyle(.borderless)
                    }
                }
                HStack(spacing: PerryTheme.Spacing.inline) {
                    TextField("Spoken phrase", text: $newSpokenWord)
                    TextField("Replacement phrase", text: $newReplacement)
                    Button("Add replacement") {
                        let spoken = newSpokenWord.trimmingCharacters(in: .whitespacesAndNewlines)
                        let replacement = newReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !spoken.isEmpty, !replacement.isEmpty else { return }
                        do {
                            try AppController.shared.voice.saveVoiceDictionaryEntry(spoken: spoken, replacement: replacement)
                            reloadVoiceDictionary()
                            newSpokenWord = ""
                            newReplacement = ""
                            updateDictationPreferences()
                        } catch {
                            settingsError = error.localizedDescription
                        }
                    }
                    .disabled(newSpokenWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
        }
    }

    private var memoryTab: some View {
        Form {
            Section("Memory") {
                Toggle("Remember context between sessions", isOn: $memoryEnabled)
                    .onChange(of: memoryEnabled) { _, value in
                        Task { await AppController.shared.setMemoryEnabled(value) }
                    }
                Text("Stored locally, inspectable, and never synced. Turn it off for goldfish mode.")
                    .settingNote()
                ForEach(MemoryRecord.Category.allCases, id: \.self) { category in
                    Toggle(Self.memoryCategoryTitle(category), isOn: Binding(
                        get: { memoryCategoryToggles[category] ?? true },
                        set: { value in
                            memoryCategoryToggles[category] = value
                            Task { await AppController.shared.setMemoryCategoryEnabled(category, enabled: value) }
                        }
                    ))
                }
                Button("Erase all Perry data…", role: .destructive) {
                    NotificationCenter.default.post(name: .perryWipeDataRequested, object: nil)
                }
                Text("Removes tasks, history, memory, approvals, preferences, provider credentials, OAuth state, temporary media, caches, and Cua artifacts after confirmation.")
                    .settingNote()
            }
            Section("Activity") {
                Button("Export activity log") {
                    AppController.shared.exportActivityLog()
                }
                Button("Export redacted diagnostics") {
                    AppController.shared.exportDiagnostics()
                }
                Button("Report a problem…") {
                    showReportProblem = true
                }
                Text("The diagnostics bundle contains environment, permission, runtime, and count data; it excludes requests, paths, transcripts, and memory text.")
                    .settingNote()
            }
        }
        .formStyle(.grouped)
        .tabItem { Label("Memory & Privacy", systemImage: "brain") }
        .onAppear {
            refreshMemory()
        }
        .confirmationDialog(
            "Report a problem",
            isPresented: $showReportProblem,
            titleVisibility: .visible
        ) {
            Button("Export diagnostics first") {
                AppController.shared.exportDiagnostics()
            }
            if let url = perryIssuesURL {
                Button("Open GitHub issues") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Perry never uploads anything automatically. Export the redacted diagnostics file, then attach it to a new issue in Perry's GitHub repository so the problem can be reproduced.")
        }
    }

    /// Issues page from the release build's `PERRY_ISSUES_URL` build var;
    /// unset in dev builds, so the dialog just explains the export flow.
    private var perryIssuesURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PerryIssuesURL") as? String,
              !raw.isEmpty,
              !raw.hasPrefix("$(") else { return nil }
        return URL(string: raw)
    }

    private var runtimesTab: some View {
        Form {
            Section("Agent runtime") {
                Text(runtimeSettings.status.setup.summary)
                    .font(PerryTheme.Typography.settingsStatus)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Agent runtime status")
                    .accessibilityValue(runtimeSettings.status.setup.summary)
                ForEach(runtimeSettings.status.setup.records) { runtime in
                    VStack(alignment: .leading, spacing: PerryTheme.Spacing.control) {
                        HStack(spacing: PerryTheme.Spacing.inline) {
                            Image(systemName: runtime.isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                                .foregroundStyle(runtime.isReady ? PerryTheme.Colors.accent : PerryTheme.Colors.textSecondary)
                                .accessibilityHidden(true)
                            Text(runtime.name)
                                .font(PerryTheme.Typography.value)
                            Spacer()
                            if let command = runtime.signInCommand {
                                Button(copiedRuntimeCommand == command.shellText ? "Sign-in command copied" : "Copy sign-in command") {
                                    copyRuntimeCommand(command)
                                }
                            }
                            if let command = runtime.signOutCommand {
                                Button(copiedRuntimeCommand == command.shellText ? "Sign-out command copied" : "Copy sign-out command") {
                                    copyRuntimeCommand(command)
                                }
                            }
                        }
                        Text(runtime.status)
                            .settingNote()
                    }
                    .accessibilityElement(children: .contain)
                }
                HStack(spacing: PerryTheme.Spacing.inline) {
                    Button("Refresh runtime status") {
                        refreshRuntimeStatus()
                    }
                    Button("Open Terminal") {
                        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: NSWorkspace.OpenConfiguration())
                    }
                }
                Text("Perry copies the verified runtime's exact executable path and official authentication command. Run it in Terminal, then refresh the status here.")
                    .settingNote()
            }
            Section("Computer use") {
                Text(runtimeSettings.status.cuaStatus)
                    .font(PerryTheme.Typography.settingsStatus)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Computer-use driver status")
                    .accessibilityValue(runtimeSettings.status.cuaStatus)
                TextField("Cua Driver path (optional)", text: $cuaDriverPath)
                    .textFieldStyle(.roundedBorder)
                Button("Save Cua Driver settings") {
                    AppController.shared.reloadCuaDriverConfiguration()
                    refreshRuntimeStatus()
                }
                Text("Perry requires Cua Driver for window screenshots, accessibility grounding, and GUI actions. Grounded tasks stop when Cua is unavailable or unhealthy.")
                    .settingNote()
            }
            Section("Direct AI provider") {
                Picker("Provider", selection: $byokVisionProviderRaw) {
                    ForEach(RuntimeProviderSetupChoice.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .onChange(of: byokVisionProviderRaw) { _, _ in
                    applySelectedVisionProvider()
                }
                if selectedVisionProvider == .custom {
                    TextField("HTTPS endpoint", text: $byokVisionEndpoint)
                        .textFieldStyle(.roundedBorder)
                } else {
                    LabeledContent("Endpoint") {
                        Text(selectedVisionProvider.endpoint.absoluteString)
                            .font(PerryTheme.Typography.monoSmall)
                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                TextField("Model ID", text: $byokVisionModel)
                    .textFieldStyle(.roundedBorder)
                SecureField("API key", text: $byokVisionKey)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: PerryTheme.Spacing.inline) {
                    Button("Save credential") {
                        saveSecret(byokVisionKey, account: RuntimeCatalog.byokVisionKeychainAccount) {
                            byokVisionKey = ""
                            byokVisionKeyIsSaved = true
                            refreshRuntimeStatus()
                        }
                    }
                    .disabled(!canSaveVisionCredential)
                    if byokVisionKeyIsSaved {
                        Button("Remove credential…", role: .destructive) {
                            showRemoveVisionCredentialConfirmation = true
                        }
                    }
                }
                .confirmationDialog(
                    "Remove the \(selectedVisionProvider.displayName) credential?",
                    isPresented: $showRemoveVisionCredentialConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Remove credential", role: .destructive) {
                        removeVisionCredential()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Perry removes this API key from Keychain. You’ll need to enter it again before using this provider.")
                }
                Text(visionCredentialStatus)
                    .settingNote()
                Text("Direct providers can plan screenshot-grounded tasks but cannot execute actions themselves. Perry sends a screenshot only after you start a grounded task. Choose Custom only for an OpenAI-compatible HTTPS endpoint.")
                    .settingNote()
            }
            Section("Local skills") {
                if skills.isEmpty {
                    Text("No app skills are installed yet.")
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                } else {
                    ForEach(skills) { skill in
                        Toggle(isOn: Binding(
                            get: { skillEnabled[skill.id] ?? true },
                            set: { value in
                                skillEnabled[skill.id] = value
                                AppSkillLibrary(storageDirectory: AppController.supportDirectory).setEnabled(value, for: skill.bundleID)
                            }
                        )) {
                            VStack(alignment: .leading, spacing: PerryTheme.Spacing.tight) {
                                Text(skill.displayName)
                                Text("\(skill.bundleID) · \(skill.source.rawValue)")
                                    .font(PerryTheme.Typography.monoSmall)
                                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                            }
                        }
                        .accessibilityLabel("\(skill.displayName), \(skill.source.rawValue) skill")
                    }
                }
                Text("Skills are local Markdown notes injected only for the matching foreground app. Disable any skill you do not want Perry to use.")
                    .settingNote()
                Button("Open local skills folder") {
                    guard let directory = AppController.supportDirectory?.appendingPathComponent("AppSkills", isDirectory: true) else { return }
                    do {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        guard NSWorkspace.shared.open(directory) else {
                            throw SettingsError.couldNotOpenSkillsFolder
                        }
                    } catch {
                        settingsError = error.localizedDescription
                    }
                }
            }
        }
        .formStyle(.grouped)
        .tabItem { Label("Runtimes", systemImage: "cpu") }
        .onAppear {
            prepareVisionProviderSettings()
            refreshRuntimeStatus()
            refreshSkills()
        }
        .onDisappear { runtimeSettings.cancel() }
    }

    private var integrationsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PerryTheme.Spacing.section) {
                Text("Connect services with device-owned OAuth. Register dev.perry.perry:/oauth/callback with each provider; Perry keeps access tokens and client secrets in Keychain, refreshes expiring grants, and keeps remote writes disabled until you enable them per service and approve each action.")
                    .settingNote()
                ForEach(RemoteIntegrationDefinition.catalog) { definition in
                    IntegrationRow(definition: definition)
                    if definition.id != RemoteIntegrationDefinition.catalog.last?.id {
                        Divider()
                    }
                }
            }
            .padding(PerryTheme.Spacing.cardInset)
        }
        .tabItem { Label("Integrations", systemImage: "point.3.connected.trianglepath.dotted") }
    }

    private var appearanceTab: some View {
        Form {
            Section("Overlay") {
                HStack(spacing: PerryTheme.Spacing.inline) {
                    Text("Caption opacity")
                    Slider(value: $captionOpacity, in: 0.35...1.0, step: 0.05, label: { Text("Caption opacity") })
                        .labelsHidden()
                    Text("\(captionOpacity * 100, specifier: "%.0f")%")
                        .font(PerryTheme.Typography.value)
                        .frame(width: PerryTheme.Sizing.captionOpacityValueWidth, alignment: .trailing)
                }
                Text("Reduced-motion behavior follows the macOS accessibility setting.")
                    .settingNote()
            }
        }
        .formStyle(.grouped)
        .tabItem { Label("Appearance", systemImage: "paintbrush") }
    }

    private var safetyTab: some View {
        Form {
            Section("Always blocked") {
                ForEach(Self.blockedApps, id: \.bundleID) { app in
                    VStack(alignment: .leading, spacing: PerryTheme.Spacing.label) {
                        Text(app.name)
                        Text(app.bundleID)
                            .font(PerryTheme.Typography.monoSmall)
                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("Banking, password-manager, sign-in, payment, and checkout windows are refused before screen capture or action.")
                    .settingNote()
            }
        }
        .formStyle(.grouped)
        .tabItem { Label("Safety & Advanced", systemImage: "hand.raised") }
    }

    private func refreshRuntimeStatus() {
        runtimeSettings.refresh()
    }

    private func copyRuntimeCommand(_ command: RuntimeAuthenticationCommand) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(command.shellText, forType: .string) else {
            settingsError = SettingsError.couldNotCopyRuntimeCommand.localizedDescription
            return
        }
        copiedRuntimeCommand = command.shellText
    }

    private func refreshMemory() {
        Task {
            let config = await AppController.shared.currentMemoryConfiguration()
            await MainActor.run {
                memoryEnabled = config.enabled
                memoryCategoryToggles = config.categoryToggles
            }
        }
    }

    private func refreshSkills() {
        let library = AppSkillLibrary(storageDirectory: AppController.supportDirectory)
        let available = library.allSkills()
        skills = available
        skillEnabled = available.reduce(into: [:]) { result, skill in
            result[skill.id] = library.isEnabled(skill.bundleID)
        }
    }

    private var selectedVisionProvider: RuntimeProviderSetupChoice {
        RuntimeProviderSetupChoice(rawValue: byokVisionProviderRaw) ?? .openAI
    }

    private var canSaveVisionCredential: Bool {
        !byokVisionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !byokVisionModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedVisionProvider.accepts(endpoint: byokVisionEndpoint)
    }

    private var visionCredentialStatus: String {
        byokVisionKeyIsSaved
            ? "Credential saved in Keychain. Perry verifies it when the next planning request starts."
            : "No credential is saved for direct planning."
    }

    private func prepareVisionProviderSettings() {
        if let inferred = RuntimeProviderSetupChoice.infer(from: byokVisionEndpoint) {
            byokVisionProviderRaw = inferred.rawValue
        }
        applySelectedVisionProvider()
        do {
            byokVisionKeyIsSaved = try !(KeychainStore().readChecked(account: RuntimeCatalog.byokVisionKeychainAccount) ?? "").isEmpty
        } catch {
            byokVisionKeyIsSaved = false
            settingsError = error.localizedDescription
        }
    }

    private func applySelectedVisionProvider() {
        guard selectedVisionProvider != .custom else { return }
        byokVisionEndpoint = selectedVisionProvider.endpoint.absoluteString
    }

    private func removeVisionCredential() {
        do {
            try KeychainStore().deleteChecked(account: RuntimeCatalog.byokVisionKeychainAccount)
            byokVisionKey = ""
            byokVisionKeyIsSaved = false
            refreshRuntimeStatus()
        } catch {
            settingsError = error.localizedDescription
        }
    }

    private static func memoryCategoryTitle(_ category: MemoryRecord.Category) -> String {
        switch category {
        case .appWorkflow: return "App workflows"
        case .preference: return "Preferences"
        case .pastSession: return "Past sessions"
        }
    }

    private static let blockedApps = TrustGuard.defaultBlockedBundleIDs.sorted().map { bundleID in
        let names = [
            "com.agilebits.onepassword-osx": "1Password",
            "com.agilebits.onepassword7": "1Password 7",
            "com.apple.KeychainAccess": "Keychain Access",
            "com.bitwarden.desktop": "Bitwarden",
            "com.dashlane.dashlanephonehome": "Dashlane",
            "com.keepersecurity.KeeperDesktop": "Keeper",
            "com.lastpass.LastPass": "LastPass",
        ]
        return (bundleID: bundleID, name: names[bundleID] ?? bundleID)
    }

    private func saveSecret(_ value: String, account: String, onSuccess: () -> Void) {
        let secret = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return }
        do {
            try KeychainStore().save(secret, account: account)
            onSuccess()
        } catch {
            settingsError = error.localizedDescription
        }
    }

    private func saveSpeechPreferences() {
        AppController.shared.voice.updateSpeechPreferences(
            SpeechPreferences(
                outputEnabled: speechOutputEnabled,
                rateMultiplier: speechRate,
                voiceIdentifier: speechVoiceIdentifier.isEmpty ? nil : speechVoiceIdentifier
            )
        )
    }

    private func updateDictationPreferences() {
        let language: DictationLanguageMode = dictationLanguageRaw == "automatic"
            ? .automatic
            : .fixed(identifier: dictationLanguageRaw)
        let entries: [String: String]
        do {
            entries = try AppController.shared.voice.voiceDictionaryEntries()
        } catch {
            settingsError = error.localizedDescription
            return
        }
        AppController.shared.voice.updateDictationPreferences(
            DictationPreferences(
                language: language,
                customWords: Array(entries.keys) + Array(entries.values),
                inputDeviceID: dictationInputDeviceRaw == 0 ? nil : UInt32(dictationInputDeviceRaw)
            )
        )
    }

    private func reloadVoiceDictionary() {
        do {
            dictionaryEntries = try AppController.shared.voice.voiceDictionaryEntries()
        } catch {
            dictionaryEntries = [:]
            settingsError = error.localizedDescription
        }
    }
}

private enum SettingsError: LocalizedError {
    case couldNotOpenSkillsFolder
    case couldNotCopyRuntimeCommand

    var errorDescription: String? {
        switch self {
        case .couldNotOpenSkillsFolder:
            return "Perry could not open the local skills folder."
        case .couldNotCopyRuntimeCommand:
            return "Perry could not copy the authentication command. Open Terminal and run the runtime's official sign-in command manually."
        }
    }
}

enum RuntimeProviderSetupChoice: String, CaseIterable, Identifiable {
    case openAI
    case anthropic
    case gemini
    case openRouter
    case custom

    var id: String { rawValue }

    var displayName: String {
        directProvider?.displayName ?? "Custom OpenAI-compatible"
    }

    var endpoint: URL {
        directProvider?.defaultBaseURL ?? URL(string: "https://provider.example")!
    }

    func accepts(endpoint rawValue: String) -> Bool {
        guard let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.host != nil else { return false }
        do {
            try NetworkEndpointPolicy.requireSafe(url)
            return true
        } catch {
            return false
        }
    }

    static func infer(from rawValue: String) -> RuntimeProviderSetupChoice? {
        guard let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.host != nil else { return nil }
        return allCases.first { $0.directProvider?.defaultBaseURL.host == url.host } ?? .custom
    }

    private var directProvider: DirectAIProvider? {
        switch self {
        case .openAI: return .openAI
        case .anthropic: return .anthropic
        case .gemini: return .gemini
        case .openRouter: return .openRouter
        case .custom: return nil
        }
    }
}

private extension View {
    func settingNote() -> some View {
        font(PerryTheme.Typography.note)
            .foregroundStyle(PerryTheme.Colors.textSecondary)
    }
}

extension Notification.Name {
    static let perryWipeDataRequested = Notification.Name("perry.wipeDataRequested")
}
