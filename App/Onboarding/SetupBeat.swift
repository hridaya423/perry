import AVFoundation
import PerryBrain
import PerryOverlay
import SwiftUI

@MainActor
enum SetupFactsProbe {
    static func current(brain: BrainController, cloudBrainReady: Bool, priority: SetupPriority) -> SetupFacts {
        SetupFacts(
            memoryGB: Int(ProcessInfo.processInfo.physicalMemory >> 30),
            macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            speechAnalyzerSupportsLocale: Locale.current.language.languageCode?.identifier == "en",
            premiumSystemVoice: VoiceController.naturalVoices().first { $0.quality == .premium }?.name,
            kokoroInstalled: KokoroVoice.isInstalled,
            voiceKeys: Set(VoiceService.allCases.filter(\.hasKey)),
            cloudBrainReady: cloudBrainReady,
            localBrainCapable: brain.localTaskCapable,
            priority: priority
        )
    }

    static var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    }

    static func sample(name: String) -> String {
        name.isEmpty ? "Hi, this is how I sound." : "Hi \(name), this is how I sound."
    }
}

struct SetupBeat: View {
    @ObservedObject var director: OnboardingDirector
    @ObservedObject var brain: BrainController
    let voice: VoiceController
    let name: String
    let catalog: RuntimeCatalog?
    let openSettings: () -> Void

    @AppStorage(PerryPreferences.$setupPriority.key) private var priority = SetupPriority.recommended
    @AppStorage(PerryPreferences.$hidePersonalDetails.key) private var hidePersonalDetails = false
    @State private var brainOverride: SetupRecommendation.Brain?
    @State private var voiceOverride: SpeechEngineChoice?
    @State private var hideOverride: Bool?
    @State private var installing: String?
    @State private var voiceError: String?
    @State private var refresh = 0
    @StateObject private var keyCapture = VoiceKeyCapture()

    private var cloudRow: CloudBrainList.Row {
        let rows = CloudBrainList.rows(claudeCodeInstalled: brain.claudeCodeAvailable, agents: CloudBrainList.installedAgents(saved: brain.acpAgent))
        return CloudBrainList.preselected(saved: brain.hasSavedChoice ? brain.modelChoice : nil, savedAgent: brain.acpAgent, rows: rows,
                                          states: brain.setupStates, hasProfile: brain.activeProfile != nil) ?? .chatGPT
    }

    private var cloudReady: Bool { BrainBeat.isReady(cloudRow, states: brain.setupStates, hasProfile: brain.activeProfile != nil) }

    private var advice: SetupRecommendation {
        _ = refresh
        return SetupAdvisor.recommend(SetupFactsProbe.current(brain: brain, cloudBrainReady: cloudReady, priority: priority))
    }

    private var brainPick: SetupRecommendation.Brain { brainOverride ?? advice.brain }
    private var hides: Bool { hideOverride ?? advice.hidesPersonalDetails }

    private var voicePick: SpeechEngineChoice? {
        if let voiceOverride { return voiceOverride }
        switch advice.voice {
        case .cloud(let service): return .cloud(service)
        case .kokoro: return .kokoro
        case .system: return .system
        case .installKokoro, .guidedPremium, .getKey: return nil
        }
    }

    var body: some View {
        OnboardingBeatLayout(title: "Your setup") {
            PerryCharacterView(pose: pose, size: 36)
        } detail: {
            ViewThatFits(in: .vertical) {
                setup(compact: false)
                setup(compact: true)
            }
            .multilineTextAlignment(.leading)
        } actions: {
            OnboardingFooter {
                EmptyView()
            } primary: {
                Button(action: accept) { OnboardingPrimaryLabel(title: brain.isSigningIn ? "Waiting for sign-in…" : "Looks good") }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(brain.isSigningIn || installing != nil)
            } trailing: {
                if brain.isSigningIn {
                    Button("Cancel") { brain.cancelSignIn() }
                } else {
                    Button("Skip") { director.skip() }
                }
            }
        }
        .task {
            if let catalog { await brain.refreshSetupStates(using: catalog) }
            await brain.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            refresh += 1
            if case .system = advice.voice, voiceOverride == nil { voice.preview(SetupFactsProbe.sample(name: name), engine: .system) }
        }
        .onAppear {
            keyCapture.onSaved = { service in
                voiceOverride = .cloud(service)
                refresh += 1
                voice.preview(SetupFactsProbe.sample(name: name), engine: .cloud(service))
            }
        }
        .onDisappear { keyCapture.stop() }
    }

    private func setup(compact: Bool) -> some View {
        VStack(spacing: compact ? 6 : 10) {
            if !compact {
                Picker("Priority", selection: $priority) {
                    Text("Recommended").tag(SetupPriority.recommended)
                    Text("Best quality").tag(SetupPriority.quality)
                    Text("Most private").tag(SetupPriority.privacy)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 340)
                .onChange(of: priority) { _, _ in
                    brainOverride = nil
                    voiceOverride = nil
                    hideOverride = nil
                }
            }
            VStack(spacing: 0) {
                brainRow.environment(\.setupCompact, compact)
                SettingsDivider()
                voiceRow.environment(\.setupCompact, compact)
                if !compact {
                    SettingsDivider()
                    hearingRow
                }
                if brainPick == .cloud {
                    SettingsDivider()
                    privacyRow.environment(\.setupCompact, compact)
                }
            }
            .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PerryTheme.Radius.card, style: .continuous).strokeBorder(PerryTheme.Colors.subtleSeparator, lineWidth: 1)
            }
            if let message = brain.signInError ?? voiceError ?? (brainPick == .cloud ? advice.brainNote : nil) {
                Text(message)
                    .font(PerryTheme.Scale.secondary)
                    .foregroundStyle(brain.signInError ?? voiceError == nil ? PerryTheme.Colors.textSecondary : PerryTheme.Colors.caution)
                    .lineLimit(compact ? 1 : 3)
                    .fixedSize(horizontal: false, vertical: !compact)
            }
        }
    }

    private var brainRow: some View {
        SetupRow(systemImage: "sparkles", tint: TileTint.lilac, title: "Brain",
                 detail: brainPick == .local ? "On this Mac. Nothing leaves it." : "\(cloudRow.title) in the cloud.") {
            if brainPick == .cloud, !cloudReady, cloudRow == .chatGPT {
                Button("Connect") {
                    brain.signInWithChatGPT { connected in if connected { brain.modelChoice = .chatGPT } }
                }
            }
            Menu {
                Button("Cloud") { brainOverride = .cloud }
                Button("On this Mac") { brainOverride = .local }
                    .disabled(!brain.onDeviceRouteAvailable)
                Divider()
                Button("More brains…", action: openSettings)
            } label: { Image(systemName: "chevron.up.chevron.down") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change the brain")
        }
    }

    private var voiceRow: some View {
        SetupRow(systemImage: "waveform", tint: TileTint.pink, title: "Voice", detail: voiceDetail) {
            if let installing {
                ProgressView().controlSize(.small)
                Text(installing).font(PerryTheme.Scale.meta).foregroundStyle(PerryTheme.Colors.textSecondary)
            } else if let pick = voicePick {
                Button { voice.preview(SetupFactsProbe.sample(name: name), engine: pick) } label: { Image(systemName: "play.fill") }
                    .help("Play a sample")
                    .accessibilityLabel("Play a sample")
            } else if case .installKokoro = advice.voice {
                Button("Download") { installKokoro() }
            } else if case .guidedPremium = advice.voice {
                Button("Get Ava") { openVoiceManager() }
            } else if case .getKey(let service) = advice.voice {
                Button("Get key") { keyCapture.getKey(for: service) }
            }
            Menu {
                Button("On-device voice, 380\u{00A0}MB") {
                    if KokoroVoice.isInstalled { voiceOverride = .kokoro } else { installKokoro() }
                }
                Button("Apple Premium voice") {
                    if VoiceController.naturalVoices().contains(where: { $0.quality == .premium }) { voiceOverride = .system } else { openVoiceManager() }
                }
                Divider()
                ForEach(VoiceService.allCases) { service in
                    Button(service.hasKey ? service.name : "\(service.name): get a key") {
                        if service.hasKey { voiceOverride = .cloud(service) } else { keyCapture.getKey(for: service) }
                    }
                }
            } label: { Image(systemName: "chevron.up.chevron.down") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change the voice")
        }
    }

    private var voiceDetail: String {
        switch keyCapture.state {
        case .waiting: return "Sign in, press Create key, then Copy."
        case .checking(let service): return "Checking the \(service.name) key…"
        case .failed(let message): return message
        case .idle, .saved: break
        }
        switch voicePick {
        case .cloud(let service): return "\(service.name). Sounds human."
        case .kokoro: return "Natural voice on this Mac. Private."
        case .system: return VoiceController.speakingVoice.map { "\($0.name), Apple voice. Private." } ?? "Apple voice. Private."
        case nil:
            if case .installKokoro = advice.voice { return "Natural voice on this Mac, 380 MB." }
            if case .getKey(let service) = advice.voice { return "\(service.name). Free key, about a minute." }
            return "Apple Premium voice, free download."
        }
    }

    private var hearingRow: some View {
        SetupRow(systemImage: "mic.fill", tint: TileTint.teal, title: "Hearing",
                 detail: advice.hearing == .speechAnalyzer ? "On this Mac. Fast and private." : "On this Mac. Works offline.") {
            EmptyView()
        }
    }

    private var privacyRow: some View {
        SetupRow(systemImage: "lock.fill", tint: TileTint.blue, title: "Hide personal details",
                 detail: "Placeholders replace names and emails.") {
            Toggle("Hide personal details", isOn: Binding(get: { hides }, set: { hideOverride = $0 }))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(PerryTheme.Colors.accent)
                .controlSize(.small)
        }
    }

    private var pose: PerryCharacterPose {
        var pose = PerryCharacterPose()
        pose.face = .happy
        pose.gaze = CGVector(dx: 0, dy: 0.6)
        return pose
    }

    private func installKokoro() {
        voiceError = nil
        installing = "Downloading…"
        Task {
            do {
                try await KokoroVoice.install { _ in }
                installing = nil
                voiceOverride = .kokoro
                refresh += 1
                voice.preview(SetupFactsProbe.sample(name: name), engine: .kokoro)
            } catch {
                installing = nil
                voiceError = error.localizedDescription
            }
        }
    }

    private func openVoiceManager() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") else { return }
        NSWorkspace.shared.open(url)
    }

    private func accept() {
        if brainPick == .local {
            brain.modelChoice = .local
        } else if cloudReady {
            if case .agent(let agent) = cloudRow { brain.setAcpAgent(agent) } else { brain.modelChoice = cloudRow.choice }
        }
        if let voicePick { PerryPreferences.speechEngine = voicePick.rawValue }
        hidePersonalDetails = brainPick == .cloud && hides
        if brainPick == .cloud, !cloudReady, cloudRow == .chatGPT {
            brain.signInWithChatGPT { connected in
                if connected { brain.modelChoice = .chatGPT }
                director.skip()
            }
            return
        }
        director.skip()
    }
}

extension EnvironmentValues {
    @Entry var setupCompact = false
}

private struct SetupRow<Trailing: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing
    @Environment(\.setupCompact) private var compact

    var body: some View {
        HStack(alignment: .center, spacing: compact ? 10 : 12) {
            SymbolTile(systemImage: systemImage, tint: tint, size: compact ? 24 : 28)
            if compact {
                Text(title).font(PerryTheme.Scale.rowTitle).foregroundStyle(PerryTheme.Colors.text)
                    .lineLimit(1)
                    .fixedSize()
                Text(detail)
                    .font(PerryTheme.Scale.secondary)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(PerryTheme.Scale.rowTitle).foregroundStyle(PerryTheme.Colors.text)
                    Text(detail)
                        .font(PerryTheme.Scale.secondary)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { trailing }
                .buttonStyle(InkButtonStyle(.secondary))
                .controlSize(.small)
        }
        .padding(.horizontal, compact ? 12 : 14)
        .padding(.vertical, compact ? 5 : 8)
    }
}
