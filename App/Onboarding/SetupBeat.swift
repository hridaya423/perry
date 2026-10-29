import AVFoundation
import PerryBrain
import PerryOverlay
import SwiftUI

@MainActor
enum SetupFactsProbe {
    private static var machine: SetupFacts?

    static func current(brain: BrainController, cloudBrainReady: Bool, localModelFits: Bool, priority: SetupPriority) -> SetupFacts {
        var facts = machine ?? SetupFacts(
            memoryGB: Int(ProcessInfo.processInfo.physicalMemory >> 30),
            macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            speechAnalyzerSupportsLocale: Locale.current.language.languageCode?.identifier == "en",
            premiumSystemVoice: VoiceController.naturalVoices().first { $0.quality == .premium }?.name,
            kokoroInstalled: KokoroVoice.isInstalled,
            voiceKeys: Set(VoiceService.allCases.filter(\.hasKey)),
            localBrainCapable: brain.localTaskCapable
        )
        machine = facts
        facts.cloudBrainReady = cloudBrainReady
        facts.localModelFits = localModelFits
        facts.priority = priority
        return facts
    }

    static func forget() {
        machine = nil
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
    @ObservedObject var local: LocalBrain
    let name: String
    let catalog: RuntimeCatalog?

    @AppStorage(PerryPreferences.$setupPriority.key) private var priority = SetupPriority.recommended
    @AppStorage(PerryPreferences.$hidePersonalDetails.key) private var hidePersonalDetails = false
    @State private var brainOverride: SetupRecommendation.Brain?
    @State private var voiceOverride: SpeechEngineChoice?
    @State private var hideOverride: Bool?
    @ObservedObject private var installer = KokoroInstaller.shared
    @State private var voiceError: String?
    @State private var refresh = 0
    @State private var chooserTab = SetupRecommendation.Brain.cloud
    @State private var profile = MachineProfile.current()
    @State private var offers: [ModelOffer] = []
    @State private var freeGB = 0.0
    @StateObject private var keyCapture = VoiceKeyCapture()

    private var cloudRow: CloudBrainList.Row {
        let rows = CloudBrainList.rows(claudeCodeInstalled: brain.claudeCodeAvailable, agents: CloudBrainList.installedAgents(saved: brain.acpAgent))
        return CloudBrainList.preselected(saved: brain.hasSavedChoice ? brain.modelChoice : nil, savedAgent: brain.acpAgent, rows: rows,
                                          states: brain.setupStates, hasProfile: brain.activeProfile != nil) ?? .chatGPT
    }

    private var cloudReady: Bool { BrainBeat.isReady(cloudRow, states: brain.setupStates, hasProfile: brain.activeProfile != nil) }

    private var advice: SetupRecommendation {
        _ = refresh
        return SetupAdvisor.recommend(SetupFactsProbe.current(brain: brain, cloudBrainReady: cloudReady,
                                                              localModelFits: ModelFit.recommended(offers) != nil, priority: priority))
    }

    private var savedBrain: SetupRecommendation.Brain? {
        guard brain.hasSavedChoice else { return nil }
        return brain.modelChoice == .local ? .local : .cloud
    }

    private var brainPick: SetupRecommendation.Brain { brainOverride ?? savedBrain ?? advice.brain }
    private var brainsKnown: Bool { brain.setupStates[.chatGPT] != .unchecked }
    private var needsChatGPT: Bool { brainsKnown && brainPick == .cloud && !cloudReady && cloudRow == .chatGPT }
    private var hides: Bool { hideOverride ?? advice.hidesPersonalDetails }
    private var localOffer: ModelOffer? { local.chosen(from: offers) }

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
        OnboardingBeatLayout(title: director.choosingBrain ? "Choose a brain" : "Your setup") {
            PerryCharacterView(pose: pose, size: 36)
        } detail: {
            Group {
                if director.choosingBrain { chooser } else { setup }
            }
            .multilineTextAlignment(.leading)
        } actions: {
            OnboardingFooter {
                EmptyView()
            } primary: {
                if director.choosingBrain {
                    Button { director.choosingBrain = false } label: { OnboardingPrimaryLabel(title: "Done") }
                        .buttonStyle(InkButtonStyle())
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(action: accept) { OnboardingPrimaryLabel(title: primaryTitle) }
                        .buttonStyle(InkButtonStyle())
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(brain.isSigningIn)
                }
            } trailing: {
                if brain.isSigningIn {
                    Button("Cancel") { brain.cancelSignIn() }
                } else if !director.choosingBrain {
                    Button("Skip") { director.skip() }
                }
            }
        }
        .task {
            if let catalog { await brain.refreshSetupStates(using: catalog) }
            await brain.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            SetupFactsProbe.forget()
            refresh += 1
            if case .system = advice.voice, voiceOverride == nil { voice.preview(SetupFactsProbe.sample(name: name), engine: .system) }
        }
        .onChange(of: installer.downloading) { _, downloading in
            if !downloading { installFinished() }
        }
        .onAppear {
            if case .installKokoro = advice.voice, voiceOverride == nil { installKokoro() }
            freeGB = Double(local.freeDiskBytes) / 1e9
            offers = local.offers(profile: profile)
            SetupFactsProbe.forget()
            keyCapture.onSaved = { service in
                voiceOverride = .cloud(service)
                SetupFactsProbe.forget()
                refresh += 1
                voice.preview(SetupFactsProbe.sample(name: name), engine: .cloud(service))
            }
        }
        .onDisappear { keyCapture.stop() }
    }

    private var setup: some View {
        VStack(spacing: 10) {
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
            VStack(spacing: 0) {
                brainRow
                SettingsDivider()
                voiceRow
                SettingsDivider()
                hearingRow
                if brainPick == .cloud {
                    SettingsDivider()
                    privacyRow
                }
            }
            .setupCard()
            if let message = brain.signInError ?? voiceError ?? (brainPick == .cloud ? advice.brainNote : nil) {
                Text(message)
                    .font(PerryTheme.Scale.secondary)
                    .foregroundStyle(brain.signInError ?? voiceError == nil ? PerryTheme.Colors.textSecondary : PerryTheme.Colors.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var chooser: some View {
        VStack(spacing: 10) {
            Picker("Where the brain runs", selection: $chooserTab) {
                Text("Cloud").tag(SetupRecommendation.Brain.cloud)
                Text("On this Mac").tag(SetupRecommendation.Brain.local)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            VStack(spacing: 0) {
                if chooserTab == .cloud {
                    CloudBrainList(brain: brain, selection: brainPick == .cloud ? cloudRow : nil) { row in
                        if case .agent(let agent) = row { brain.setAcpAgent(agent) } else { brain.modelChoice = row.choice }
                        brainOverride = .cloud
                    }
                } else {
                    LocalModelList(offers: offers, selected: brainPick == .local ? localOffer?.rung.id : nil) { offer in
                        local.choose(offer)
                        brain.modelChoice = .local
                        brainOverride = .local
                    }
                }
            }
            .setupCard()
            if chooserTab == .local {
                Text(LocalModelList.machineLine(profile, freeGB: freeGB))
                    .font(PerryTheme.Scale.meta)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
            }
        }
        .frame(width: 420)
    }

    private var brainRow: some View {
        SetupRow(systemImage: "sparkles", tint: TileTint.lilac, brand: brainBrand, title: "Brain", detail: brainDetail) {
            if needsChatGPT {
                Button("Connect") {
                    brain.signInWithChatGPT { connected in if connected { brain.modelChoice = .chatGPT } }
                }
            }
            Button("Change") {
                keepPick()
                chooserTab = brainPick
                director.choosingBrain = true
            }
        }
    }

    private var brainBrand: String? {
        guard brainPick == .cloud else { return nil }
        switch cloudRow {
        case .claudeCode: return "claude"
        case .chatGPT: return "chatgpt"
        case .agent, .apiKey: return nil
        }
    }

    private var brainDetail: String {
        if brainPick == .local { return localDetail }
        guard brainsKnown else { return "Looking for your brains…" }
        return cloudReady ? "\(cloudRow.title). Ready." : "\(cloudRow.title). Not connected yet."
    }

    private var localDetail: String {
        switch local.phase {
        case .ready: return "On this Mac. Ready."
        case .downloading(let received, let total): return "Downloading, \(total > 0 ? received * 100 / total : 0)%."
        case .failed(let message): return message
        case .notSetUp:
            guard let localOffer else { return "On this Mac. Nothing leaves it." }
            return "\(localOffer.size.title), on this Mac. \(LocalModelList.gigabytes(localOffer.rung.downloadGB)) download."
        }
    }

    private var primaryTitle: String {
        if brain.isSigningIn { return "Waiting for sign-in…" }
        return needsChatGPT ? "Connect ChatGPT" : "Looks good"
    }

    private var voiceRow: some View {
        SetupRow(systemImage: "waveform", tint: TileTint.pink, title: "Voice", detail: voiceDetail) {
            if installer.downloading {
                ProgressView().controlSize(.small)
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
        case .kokoro:
            return installer.downloading ? "Downloading. Replies show as text until then." : "Natural voice on this Mac. Private."
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
        voiceOverride = .kokoro
        installer.start()
    }

    private func installFinished() {
        if let failure = installer.failure {
            voiceError = failure
            return
        }
        SetupFactsProbe.forget()
        refresh += 1
        voice.preview(SetupFactsProbe.sample(name: name), engine: .kokoro)
    }

    private func openVoiceManager() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") else { return }
        NSWorkspace.shared.open(url)
    }

    private func keepPick() {
        if brainPick == .local {
            brain.modelChoice = .local
        } else if case .agent(let agent) = cloudRow {
            brain.setAcpAgent(agent)
        } else {
            brain.modelChoice = cloudRow.choice
        }
    }

    private func accept() {
        if brainPick == .local || cloudReady { keepPick() }
        if brainPick == .local, local.phase == .notSetUp, local.hasEngine, let localOffer {
            local.choose(localOffer)
            Task { await local.setUp(localOffer.rung) }
        }
        if let voicePick { PerryPreferences.speechEngine = voicePick.rawValue }
        hidePersonalDetails = brainPick == .cloud && hides
        if needsChatGPT {
            brain.signInWithChatGPT { connected in
                if connected { brain.modelChoice = .chatGPT }
                director.skip()
            }
            return
        }
        director.skip()
    }
}

extension View {
    func setupCard() -> some View {
        background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PerryTheme.Radius.card, style: .continuous).strokeBorder(PerryTheme.Colors.subtleSeparator, lineWidth: 1)
            }
    }
}

private struct SetupRow<Trailing: View>: View {
    let systemImage: String
    let tint: Color
    var brand: String?
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let brand {
                BrandMark(id: brand, size: 28)
            } else {
                SymbolTile(systemImage: systemImage, tint: tint, size: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(PerryTheme.Scale.rowTitle).foregroundStyle(PerryTheme.Colors.text)
                Text(detail)
                    .font(PerryTheme.Scale.secondary)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { trailing }
                .buttonStyle(InkButtonStyle(.secondary))
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
