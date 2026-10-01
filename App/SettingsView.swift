import AppKit
import AVFoundation
import SwiftUI
import PerryCore
import PerryGuide
import PerryOverlay
import PerryRuntimes
import PerryCapture

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
    let controller: AppController
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
    @StateObject private var runtimeSettings: RuntimeSettingsState
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
    @State private var permissions: PerryPermissionSnapshot?

    init(controller: AppController) {
        self.controller = controller
        _runtimeSettings = StateObject(wrappedValue: RuntimeSettingsState {
            async let setup = controller.runtimes.currentSetup()
            async let driverStatus = controller.probe.cuaHealth().summary
            return await RuntimeSettingsState.Status(setup: setup, cuaStatus: driverStatus)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.title2.weight(.semibold))
                Spacer()
                Picker("Settings section", selection: $selectedTab) {
                    Text("General").tag(SettingsTab.general.rawValue)
                    Text("Voice & Input").tag(SettingsTab.voice.rawValue)
                    Text("Models & Advanced").tag(SettingsTab.runtimes.rawValue)
                    Text("Connected Apps").tag(SettingsTab.integrations.rawValue)
                    Text("Memory").tag(SettingsTab.memory.rawValue)
                    Text("Appearance").tag(SettingsTab.appearance.rawValue)
                    Text("Safety").tag(SettingsTab.safety.rawValue)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .padding(20)
            Divider()
            switch SettingsTab(rawValue: selectedTab) ?? .general {
            case .general: generalTab
            case .voice: voiceAndInputTab
            case .runtimes: runtimesTab
            case .integrations: integrationsTab
            case .memory: memoryTab
            case .appearance: appearanceTab
            case .safety: safetyTab
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        controller.voice.updateWakeWordEnabled(value)
                    }
                Text("Perry listens on device for the phrase and keeps no ambient transcript.")
                    .settingNote()
                Picker("Wake shortcut", selection: $wakeShortcutRaw) {
                    ForEach(WakeShortcut.allCases) { shortcut in
                        Text(shortcut.title).tag(shortcut.rawValue)
                    }
                }
                .onChange(of: wakeShortcutRaw) { _, value in
                    guard let shortcut = WakeShortcut(rawValue: value) else { return }
                    do {
                        try controller.updateWakeShortcut(shortcut)
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
                    controller.voice.updatePushToTalkShortcut(shortcut)
                }
                Text("Hold the push-to-talk shortcut from any app. Caps Lock double-tap is available for hands-free use.")
                    .settingNote()
                Text("If voice input is unavailable, Perry leaves the panel ready for typing.")
                    .settingNote()
            }
            permissionsSection
        }
        .formStyle(.grouped)
        .task { await refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshPermissions() }
        }
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            permissionRow(
                name: "Accessibility",
                why: "Lets Perry read and act on whatever you point at.",
                granted: permissions?.accessibility
            ) {
                _ = PerryPermissionProbe.requestAccessibility()
                openPrivacyPane("Privacy_Accessibility")
            }
            permissionRow(
                name: "Screen Recording",
                why: "Lets Perry see window contents so answers stay grounded.",
                granted: permissions?.screenRecording.isUsable
            ) {
                _ = PerryPermissionProbe.requestScreenRecording()
                openPrivacyPane("Privacy_ScreenCapture")
            }
            permissionRow(
                name: "Microphone",
                why: "Lets Perry hear you for talk and dictation.",
                granted: permissions?.microphone.isUsable
            ) {
                Task {
                    _ = await PerryPermissionProbe.requestMicrophone()
                    openPrivacyPane("Privacy_Microphone")
                }
            }
            permissionRow(
                name: "Input Monitoring",
                why: "Lets Perry hear the push-to-talk key while other apps are focused.",
                granted: permissions?.inputMonitoring
            ) {
                _ = PerryPermissionProbe.requestInputMonitoring()
                openPrivacyPane("Privacy_ListenEvent")
            }
            Text("Enabling Screen Recording may ask you to quit and reopen Perry.")
                .settingNote()
        }
    }

    private func permissionRow(name: String, why: String, granted: Bool?, action: @escaping () -> Void) -> some View {
        HStack(spacing: PerryTheme.Spacing.inline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(why)
                    .settingNote()
            }
            Spacer()
            switch granted {
            case .some(true):
                Label("On", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(PerryTheme.Colors.success)
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("\(name) permission granted")
            case .some(false):
                Button("Enable…", action: action)
                    .accessibilityLabel("Enable \(name) permission")
            case nil:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking \(name) permission")
            }
        }
    }

    private func refreshPermissions() async {
        permissions = await PerryPermissionSnapshot.probe()
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
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
                    if let voice { controller.voice.previewSpeechVoice(voice) }
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
                Text("When configured, audio and responses stream through your realtime provider under its data policies.")
                    .settingNote()
            }
        }
        .formStyle(.grouped)
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
                                try controller.voice.removeVoiceDictionaryEntry(spoken: spoken)
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
                            try controller.voice.saveVoiceDictionaryEntry(spoken: spoken, replacement: replacement)
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
                        Task { await controller.setMemoryEnabled(value) }
                    }
                Text("Stored locally, inspectable, and never synced. Turn it off for goldfish mode.")
                    .settingNote()
                ForEach(MemoryRecord.Category.allCases, id: \.self) { category in
                    Toggle(Self.memoryCategoryTitle(category), isOn: Binding(
                        get: { memoryCategoryToggles[category] ?? true },
                        set: { value in
                            memoryCategoryToggles[category] = value
                            Task { await controller.setMemoryCategoryEnabled(category, enabled: value) }
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
                    controller.exportActivityLog()
                }
                Button("Export redacted diagnostics") {
                    controller.exportDiagnostics()
                }
                Button("Report a problem…") {
                    showReportProblem = true
                }
                Text("The diagnostics bundle contains environment, permission, runtime, and count data; it excludes requests, paths, transcripts, and memory text.")
                    .settingNote()
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshMemory()
        }
        .confirmationDialog(
            "Report a problem",
            isPresented: $showReportProblem,
            titleVisibility: .visible
        ) {
            Button("Export diagnostics first") {
                controller.exportDiagnostics()
            }
            if let url = perryIssuesURL {
                Button("Open GitHub issues") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Perry never uploads anything automatically. Export the redacted diagnostics file, then attach it to a new issue in Perry’s GitHub repository.")
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
            Section("Conversation model") {
                BrainModelSettingsView(brain: controller.brain)
            }
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
                Text("Perry copies the verified runtime’s exact executable path and official authentication command. Run it in Terminal, then refresh the status here.")
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
                    controller.reloadCuaDriverConfiguration()
                    refreshRuntimeStatus()
                }
                Text("Perry requires Cua Driver for window screenshots, accessibility grounding, and GUI actions.")
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
                    TextField("HTTPS base URL", text: $byokVisionEndpoint)
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
                Text("Skills are local Markdown notes injected only for the matching foreground app.")
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
                    IntegrationRow(definition: definition, controller: controller)
                    if definition.id != RemoteIntegrationDefinition.catalog.last?.id {
                        Divider()
                    }
                }
            }
            .padding(PerryTheme.Spacing.cardInset)
        }
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
            let config = await controller.currentMemoryConfiguration()
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
        controller.voice.updateSpeechPreferences(
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
            entries = try controller.voice.voiceDictionaryEntries()
        } catch {
            settingsError = error.localizedDescription
            return
        }
        controller.voice.updateDictationPreferences(
            DictationPreferences(
                language: language,
                customWords: Array(entries.keys) + Array(entries.values),
                inputDeviceID: dictationInputDeviceRaw == 0 ? nil : UInt32(dictationInputDeviceRaw)
            )
        )
    }

    private func reloadVoiceDictionary() {
        do {
            dictionaryEntries = try controller.voice.voiceDictionaryEntries()
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
            return "Perry could not copy the authentication command. Open Terminal and run the runtime’s official sign-in command manually."
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
