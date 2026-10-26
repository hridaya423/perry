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
    case safety

    var tabTitle: String {
        switch self {
        case .general: "General"
        case .voice: "Voice"
        case .runtimes: "Models"
        case .integrations: "Apps"
        case .memory: "Memory"
        case .safety: "Safety"
        }
    }
}

struct SettingsView: View {
    let controller: AppController
    @AppStorage(PerryPreferences.$settingsTab.key) private var selectedTab = SettingsTab.general.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabNamespace
    @AppStorage(PerryPreferences.$wakeWordEnabled.key) private var wakeWordEnabled = false
    @AppStorage(PerryPreferences.$wakeShortcut.key) private var wakeShortcut = WakeShortcut.optionCommandP
    @AppStorage(PerryPreferences.$pttShortcut.key) private var pttShortcut = PushToTalkShortcut.functionHold
    @State private var pttSystemConflict = false
    @State private var opensAtLogin = LoginItem.isEnabled
    @AppStorage(PerryPreferences.$speechOutputEnabled.key) private var speechOutputEnabled = true
    @AppStorage(PerryPreferences.$speechRate.key) private var speechRate = 1.0
    @AppStorage(PerryPreferences.$speechVoiceIdentifier.key) private var speechVoiceIdentifier = ""
    @AppStorage(PerryPreferences.$dictationLanguage.key) private var dictationLanguageRaw = "automatic"
    @AppStorage(PerryPreferences.$dictationInputDeviceID.key) private var dictationInputDeviceRaw = 0
    @AppStorage(PerryPreferences.$cuaDriverPath.key) private var cuaDriverPath = ""
    @AppStorage(PerryPreferences.$realtimeVoiceEndpoint.key) private var realtimeVoiceEndpoint = ""
    @AppStorage(PerryPreferences.$realtimeVoiceModel.key) private var realtimeVoiceModel = ""
    @AppStorage(PerryPreferences.$realtimeVoiceVoice.key) private var realtimeVoiceVoice = "marin"
    @AppStorage(PerryPreferences.$realtimeVoiceSpeed.key) private var realtimeVoiceSpeed = 1.0
    @AppStorage(PerryPreferences.$realtimeVoiceInstructions.key) private var realtimeVoiceInstructions = PerryPreferences.$realtimeVoiceInstructions.fallback
    @AppStorage(PerryPreferences.$realtimeVoiceProtocol.key) private var realtimeVoiceProtocolRaw = RealtimeVoiceProtocolMode.automatic.rawValue
    @AppStorage(PerryPreferences.$voiceResponseCaptionOpacity.key) private var captionOpacity = PerryBundleConfig.defaultVoiceResponseCaptionOpacity
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
    @State private var copiedRuntimeCommand: String?
    @State private var realtimeVoiceKey = ""
    @State private var settingsError: String?
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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(SettingsTab.allCases, id: \.rawValue) { tab in
                        Button {
                            withAnimation(reduceMotion ? nil : PerryTheme.Motion.glide) { selectedTab = tab.rawValue }
                        } label: {
                            Text(tab.tabTitle)
                                .font(.callout.weight(.semibold))
                                .hidden()
                                .overlay {
                                    Text(tab.tabTitle)
                                        .font(.callout.weight(selectedTab == tab.rawValue ? .semibold : .regular))
                                        .foregroundStyle(selectedTab == tab.rawValue ? PerryTheme.Colors.text : PerryTheme.Colors.textSecondary)
                                }
                                .padding(.vertical, 4)
                                .overlay(alignment: .bottom) {
                                    if selectedTab == tab.rawValue {
                                        Capsule()
                                            .fill(PerryTheme.Colors.text)
                                            .frame(height: 2)
                                            .matchedGeometryEffect(id: "settingsTab", in: tabNamespace)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedTab == tab.rawValue ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            Divider()
            switch SettingsTab(rawValue: selectedTab) ?? .general {
            case .general: generalTab
            case .voice: voiceAndInputTab
            case .runtimes: runtimesTab
            case .integrations: integrationsTab
            case .memory: memoryTab
            case .safety: safetyTab
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollContentBackground(.hidden)
        .background(PerryTheme.Colors.canvas)
        .tint(PerryTheme.Colors.accent)
        .buttonStyle(InkButtonStyle(.secondary))
        .toggleStyle(InkSwitchStyle())
        .foregroundStyle(PerryTheme.Colors.text)
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
        .notchDialog(
            "Perry could not save that setting",
            item: $settingsError,
            message: settingsError ?? "Unknown settings error",
            cancelTitle: "OK"
        ) { _ in [] }
    }

    private var generalTab: some View {
        Form {
            Section("Startup") {
                Toggle("Open Perry when you log in", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, value in
                        guard value != LoginItem.isEnabled else { return }
                        do {
                            try LoginItem.setEnabled(value)
                        } catch {
                            opensAtLogin = LoginItem.isEnabled
                            settingsError = error.localizedDescription
                        }
                    }
                if LoginItem.needsApproval {
                    Text("Approve Perry in System Settings → General → Login Items.")
                        .settingNote()
                }
            }
            Section("Invocation") {
                Toggle(isOn: $wakeWordEnabled) {
                    Text("Say “hey Perry” to wake")
                    Text("Listens on this Mac for the phrase and keeps no transcript.").settingNote()
                }
                    .onChange(of: wakeWordEnabled) { _, value in
                        controller.voice.updateWakeWordEnabled(value)
                    }
                Picker("Wake shortcut", selection: $wakeShortcut) {
                    ForEach(WakeShortcut.allCases) { shortcut in
                        Text(shortcut.title).tag(shortcut)
                    }
                }
                .onChange(of: wakeShortcut) { _, shortcut in
                    do {
                        try controller.updateWakeShortcut(shortcut)
                    } catch {
                        wakeShortcut = PerryPreferences.wakeShortcut
                        settingsError = error.localizedDescription
                    }
                }
                Picker(selection: $pttShortcut) {
                    ForEach(PushToTalkShortcut.allCases) { shortcut in
                        Text(shortcut.title).tag(shortcut)
                    }
                } label: {
                    Text("Dictation")
                    Text("Hold it in any app to type by voice. Double-tap Caps Lock for hands-free.").settingNote()
                }
                .onChange(of: pttShortcut) { _, shortcut in
                    controller.voice.updatePushToTalkShortcut(shortcut)
                    refreshPttConflict()
                }
                if pttSystemConflict {
                    Text("macOS already uses this shortcut, so it may not reach Perry. Pick another, or change it in System Settings › Keyboard › Keyboard Shortcuts.")
                        .settingNote()
                }
            }
            permissionsSection
        }
        .formStyle(.grouped)
        .task { await refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            opensAtLogin = LoginItem.isEnabled
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
                why: "Lets Perry hear the dictation key while other apps are focused.",
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
        refreshPttConflict()
    }

    private func refreshPttConflict() {
        guard let chord = pttShortcut.symbolicChord else {
            pttSystemConflict = false
            return
        }
        pttSystemConflict = SymbolicHotkeys.conflicts(
            keyCode: chord.keyCode,
            modifiers: chord.modifiers,
            in: SymbolicHotkeys.load()
        )
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
                ForEach(VoiceController.recommendedSpeechVoices(), id: \.identifier) { voice in
                    VoiceChoiceRow(
                        voice: voice,
                        isSelected: voice.identifier == (speechVoiceIdentifier.isEmpty ? VoiceController.speakingVoice?.identifier : speechVoiceIdentifier),
                        select: { speechVoiceIdentifier = voice.identifier },
                        preview: { controller.voice.previewSpeechVoice(voice) }
                    )
                }
                Picker("All voices", selection: $speechVoiceIdentifier) {
                    Text("Best available").tag("")
                    ForEach(VoiceController.availableSpeechVoices(), id: \.identifier) { voice in
                        Text("\(voice.name) · \(voice.language)").tag(voice.identifier)
                    }
                }
                .onChange(of: speechVoiceIdentifier) { _, _ in saveSpeechPreferences() }
                HStack(spacing: PerryTheme.Spacing.inline) {
                    Text("Speed")
                    InkSlider(value: $speechRate, range: 0.5...1.5, step: 0.1, label: "Speech speed")
                        .onChange(of: speechRate) { _, _ in saveSpeechPreferences() }
                    Text("\(speechRate, specifier: "%.1f")×")
                        .font(PerryTheme.Typography.value)
                        .frame(width: PerryTheme.Sizing.speechRateValueWidth, alignment: .trailing)
                }
                if (AVSpeechSynthesisVoice(identifier: speechVoiceIdentifier) ?? VoiceController.speakingVoice)?.quality == .default {
                    actionRow("This voice sounds robotic", detail: "Enhanced and Premium voices sound far more natural. They’re free.", action: "Get one…") {
                        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") else { return }
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Section("Captions") {
                HStack(spacing: PerryTheme.Spacing.inline) {
                    Text("Caption opacity")
                    InkSlider(value: $captionOpacity, range: 0.55...1.0, step: 0.05, label: "Caption opacity")
                    Text("\(captionOpacity * 100, specifier: "%.0f")%")
                        .font(PerryTheme.Typography.value)
                        .frame(width: PerryTheme.Sizing.captionOpacityValueWidth, alignment: .trailing)
                }
            }
            dictationSettings
            Section("Realtime voice (bring your own key)") {
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
                        InkSlider(value: $realtimeVoiceSpeed, range: 0.25...1.5, step: 0.05, label: "Response speed")
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
                    Text("Automatic").tag("automatic")
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
                Text("Teach dictation your words. When you say the first phrase, Perry types the second.")
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
                    TextField("Spoken phrase", text: $newSpokenWord, prompt: Text("When I say"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    TextField("Replacement phrase", text: $newReplacement, prompt: Text("Type"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
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
                Toggle(isOn: $memoryEnabled) {
                    Text("Remember context between conversations")
                    Text("Stored on this Mac, never synced. You can read or erase it any time.").settingNote()
                }
                    .onChange(of: memoryEnabled) { _, value in
                        Task { await controller.setMemoryEnabled(value) }
                    }
                ForEach(MemoryRecord.Category.allCases, id: \.self) { category in
                    Toggle(Self.memoryCategoryTitle(category), isOn: Binding(
                        get: { memoryCategoryToggles[category] ?? true },
                        set: { value in
                            memoryCategoryToggles[category] = value
                            Task { await controller.setMemoryCategoryEnabled(category, enabled: value) }
                        }
                    ))
                    .disabled(!memoryEnabled)
                }
            }
            Section("Activity") {
                actionRow("Activity log", action: "Export…") { controller.exportActivityLog() }
                actionRow("Diagnostics", detail: "Setup and permission details only, never your requests, files, transcripts or memories.", action: "Export…") {
                    controller.exportDiagnostics()
                }
                actionRow("Something wrong?", action: "Report a problem…") { showReportProblem = true }
            }
            Section {
                actionRow("Erase all Perry data", detail: "Tasks, history, memory, approvals, preferences, credentials and temporary files. Perry asks you to confirm first.", action: "Erase…", role: .destructive) {
                    NotificationCenter.default.post(name: .perryWipeDataRequested, object: nil)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshMemory()
        }
        .notchDialog(
            "Report a problem",
            isPresented: $showReportProblem,
            message: "Perry never uploads anything automatically. Export the redacted diagnostics file, then attach it to a new issue in Perry’s GitHub repository."
        ) {
            var actions = [NotchDialog.Action("Export diagnostics first") {
                controller.exportDiagnostics()
            }]
            if let url = perryIssuesURL {
                actions.append(NotchDialog.Action("Open GitHub issues") {
                    NSWorkspace.shared.open(url)
                })
            }
            return actions
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
            Section("Agents") {
                if !runtimeSettings.status.setup.records.contains(where: { $0.status == runtimeSettings.status.setup.summary }) {
                    Text(runtimeSettings.status.setup.summary)
                        .font(PerryTheme.Typography.settingsStatus)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Agent status")
                        .accessibilityValue(runtimeSettings.status.setup.summary)
                }
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
                        if runtime.authenticatesInApp, runtime.authentication != .authenticated {
                            Text("Sign in with ChatGPT from Conversation model above.")
                                .settingNote()
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
                HStack(spacing: PerryTheme.Spacing.inline) {
                    Button("Check again") {
                        refreshRuntimeStatus()
                    }
                    if hasCopyableRuntimeCommands {
                        Button("Open Terminal") {
                            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                }
                if hasCopyableRuntimeCommands {
                    Text("Run the copied command in Terminal, then choose Check again.")
                        .settingNote()
                }
            }
            Section("Computer use") {
                Text(runtimeSettings.status.cuaStatus)
                    .font(PerryTheme.Typography.settingsStatus)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Computer-use driver status")
                    .accessibilityValue(runtimeSettings.status.cuaStatus)
                DisclosureGroup("Custom driver path") {
                    TextField("Cua Driver path (optional)", text: $cuaDriverPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Save Cua Driver settings") {
                        controller.reloadCuaDriverConfiguration()
                        refreshRuntimeStatus()
                    }
                }
                Text("The screen helper (Cua Driver) lets Perry see the screen and act in other apps.")
                    .settingNote()
            }
            Section("Local skills") {
                if skills.isEmpty {
                    Text("No app skills are installed yet.")
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                } else {
                    DisclosureGroup("App skills") {
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
                }
                Text("Skills are notes Perry reads when you use the matching app.")
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
            refreshRuntimeStatus()
            refreshSkills()
        }
        .onDisappear { runtimeSettings.cancel() }
    }

    private var integrationsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PerryTheme.Spacing.section) {
                Text("Give Perry access to the apps you work in. Connections stay in this Mac’s Keychain. Each service starts read-only, and every change Perry makes still asks you first.")
                    .settingNote()
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(RemoteIntegrationDefinition.catalog) { definition in
                        IntegrationRow(definition: definition, connections: controller.integrationConnections)
                        if definition.id != RemoteIntegrationDefinition.catalog.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(16)
                .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 12))
                CustomConnectorsSection(connectors: controller.customConnectors)
            }
            .frame(maxWidth: 704)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }

    private var safetyTab: some View {
        Form {
            Section {
                ForEach(Self.blockedApps, id: \.bundleID) { app in
                    HStack(spacing: 10) {
                        Group {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                            } else {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                        }
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                        Text(app.name)
                        Spacer()
                        Text("Never")
                            .font(PerryTheme.Typography.note)
                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                    }
                    .help(app.bundleID)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Always blocked")
            } footer: {
                Text("Perry never looks at or acts in these apps. Banking, sign-in, payment and checkout windows are refused the same way, in any app.")
                    .settingNote()
            }
        }
        .formStyle(.grouped)
    }

    private func refreshRuntimeStatus() {
        runtimeSettings.refresh()
    }

    /// Terminal instructions only make sense while some runtime still offers
    /// a shell sign-in/out command to copy.
    private var hasCopyableRuntimeCommands: Bool {
        runtimeSettings.status.setup.records.contains {
            $0.signInCommand != nil || $0.signOutCommand != nil
        }
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

    private func actionRow(_ title: String, detail: String? = nil, action: String, role: ButtonRole? = nil, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).settingNote()
                }
            }
            Spacer(minLength: 8)
            Button(action, role: role, action: perform)
        }
    }

    private static func memoryCategoryTitle(_ category: MemoryRecord.Category) -> String {
        switch category {
        case .appWorkflow: return "App workflows"
        case .preference: return "Preferences"
        case .pastSession: return "Past conversations"
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

extension View {
    func settingNote() -> some View {
        font(PerryTheme.Typography.note)
            .foregroundStyle(PerryTheme.Colors.textSecondary)
    }
}

extension Notification.Name {
    static let perryWipeDataRequested = Notification.Name("perry.wipeDataRequested")
}

extension AppController {
    func openSettings(tab: SettingsTab) {
        PerryPreferences.settingsTab = tab.rawValue
        showSettings()
    }

    func currentMemoryConfiguration() async -> MemoryConfiguration {
        await memoryStore.currentConfiguration()
    }

    func setMemoryEnabled(_ enabled: Bool) async {
        guard !maintenance.isErasureInProgress else { return }
        let current = await memoryStore.currentConfiguration()
        await memoryStore.setConfiguration(
            MemoryConfiguration(enabled: enabled, categoryToggles: current.categoryToggles)
        )
    }

    func setMemoryCategoryEnabled(_ category: MemoryRecord.Category, enabled: Bool) async {
        guard !maintenance.isErasureInProgress else { return }
        let current = await memoryStore.currentConfiguration()
        var toggles = current.categoryToggles
        toggles[category] = enabled
        await memoryStore.setConfiguration(
            MemoryConfiguration(enabled: current.enabled, categoryToggles: toggles)
        )
    }
}

private struct VoiceChoiceRow: View {
    let voice: AVSpeechSynthesisVoice
    let isSelected: Bool
    let select: () -> Void
    let preview: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: preview) {
                Image(systemName: "play.fill")
                    .font(.caption2.weight(.bold))
                    .frame(width: 24, height: 24)
                    .background(PerryTheme.Colors.subtleSeparator.opacity(0.7), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview \(voice.name)")
            Button(action: select) {
                HStack(spacing: 8) {
                    Text(voice.name)
                        .foregroundStyle(PerryTheme.Colors.text)
                    if let region {
                        Text(region)
                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                    }
                    if let quality {
                        Text(quality)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(PerryTheme.Colors.accent)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(PerryTheme.Colors.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(voice.name)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private var region: String? {
        Locale(identifier: voice.language).region.flatMap { Locale.current.localizedString(forRegionCode: $0.identifier) }
    }

    private var quality: String? {
        switch voice.quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: nil
        }
    }
}
