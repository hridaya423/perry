import SwiftUI
import PerryBrain
import PerryCapture
import PerryOverlay

struct HomeOnboardingView: View {
    @ObservedObject var director: OnboardingDirector
    @ObservedObject var model: HomeModel
    let brain: BrainController?
    let openSettings: () -> Void

    var body: some View {
        switch director.beat {
        case .hello:
            HelloBeat(
                director: director,
                name: OnboardingDirector.suggestedName(saved: model.deps.controller?.memoryFiles?.profileField("Name"), fullName: NSFullUserName())
            )
        case .brain:
            if let brain {
                BrainBeat(director: director, brain: brain, catalog: model.deps.controller?.runtimes, openSettings: openSettings)
            }
        case .access:
            AccessBeat(director: director)
        case .shortcuts:
            if let controller = model.deps.controller {
                ShortcutsBeat(director: director, controller: controller, check: controller.shortcutCheck)
            }
        case .interview:
            if let controller = model.deps.controller {
                InterviewBeat(
                    director: director,
                    model: InterviewModel(
                        name: controller.memoryFiles?.profileField("Name") ?? OnboardingDirector.suggestedName(saved: nil, fullName: NSFullUserName()),
                        effects: .init(
                            complete: controller.brain.hasSavedChoice ? { try await controller.brain.completeText($0) } : nil,
                            save: { facts in Task { await controller.saveInterview(facts) } }
                        )
                    ),
                    cloudLine: InterviewModel.cloudLine(choice: controller.brain.modelChoice, hasSavedChoice: controller.brain.hasSavedChoice),
                    appChips: InterviewModel.appChips()
                )
            }
        case .apps:
            if let controller = model.deps.controller {
                AppsBeat(director: director, controller: controller, tiles: AppsBeatPlan.tiles(
                    apps: controller.memoryFiles?.profileField("Apps") ?? "",
                    mentions: [controller.memoryFiles?.profileField("Work"), controller.memoryFiles?.profileField("Learning goal")].compactMap { $0 }.joined(separator: " "),
                    available: { id in
                        id == "apple-calendar" || RemoteIntegrationDefinition.catalog.first { $0.id == id }.map(controller.integrationConnections.hasBundledClient) == true
                    }
                ))
            }
        case .firstGoal:
            FirstGoalBeat(
                director: director,
                model: model,
                goal: FirstGoal.savedGoal(in: model.deps.controller?.memoryFiles) ?? "",
                installedApps: FirstGoal.installedApps()
            )
        case nil:
            EmptyView()
        }
    }
}

private struct HelloBeat: View {
    @ObservedObject var director: OnboardingDirector
    @State var name: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HelloGreetingView()
                .frame(maxWidth: 340, minHeight: 104, maxHeight: 128)
                .padding(.top, 4)
            Text("Hi, I’m Perry. I live in your notch.\nWhat should I call you?")
                .font(PerryTheme.Scale.input)
                .lineSpacing(3)
                .foregroundStyle(PerryTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(LateEntrance(delay: HelloInk.lift.upperBound))
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(PerryTheme.Colors.surface)
                    .strokeBorder(focused ? PerryTheme.Colors.accent.opacity(0.5) : PerryTheme.Colors.subtleSeparator)
                TextField("Your name", text: $name)
                    .textFieldStyle(.plain)
                    .font(PerryTheme.Scale.input)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .focusEffectDisabled()
                    .onSubmit { director.acceptName(name) }
                    .padding(.horizontal, 18)
            }
            .frame(width: 220, height: 40)
            .padding(.top, 16)
            .modifier(LateEntrance(delay: HelloInk.lift.upperBound + 0.04))
            Spacer(minLength: 12)
            Button { director.acceptName(name) } label: { OnboardingPrimaryLabel(title: "Continue") }
                .buttonStyle(InkButtonStyle())
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .modifier(LateEntrance(delay: HelloInk.lift.upperBound + 0.08))
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: .seconds(HelloInk.lift.upperBound))
            focused = true
            await Task.yield()
            NSApp.sendAction(#selector(NSResponder.moveToEndOfDocument(_:)), to: nil, from: nil)
        }
    }
}

private struct LateEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                withAnimation(PerryTheme.Motion.enter.delay(delay)) { shown = true }
            }
    }
}

private struct AccessBeat: View {
    @ObservedObject var director: OnboardingDirector

    var body: some View {
        OnboardingBeatLayout(title: "I need to see what you see.") {
            PermissionSketch(lit: director.accessGranted)
                .scaleEffect(0.6)
                .modifier(InkDrawOn())
        } detail: {
            VStack(spacing: 8) {
                row(.accessibility, title: "Accessibility", detail: "Reads buttons, menus and fields", icon: "hand.point.up.left",
                    granted: director.permissions?.accessibility == true)
                row(.microphone, title: "Microphone", detail: "Hears you only while you hold the shortcut", icon: "mic",
                    granted: director.permissions?.microphone.isUsable == true)
            }
        } actions: {
            OnboardingFooter {
                EmptyView()
            } primary: {
                if director.accessGranted {
                    Button { director.skip() } label: { OnboardingPrimaryLabel(title: "Continue") }
                        .buttonStyle(InkButtonStyle())
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Not now, I’ll type") { director.skip() }
                }
            } trailing: {
                EmptyView()
            }
        }
        .task(id: director.beat) { await director.refreshPermissions() }
    }

    private func row(_ pane: PrivacyPane, title: String, detail: String, icon: String, granted: Bool) -> some View {
        OnboardingRow(title: title, detail: detail) {
            Image(systemName: icon)
                .font(PerryTheme.Icon.row)
                .foregroundStyle(PerryTheme.Colors.text)
        } trailing: {
            if granted {
                GrantedMark()
            } else {
                Button("Allow") { Task { await director.grant(pane) } }
                    .buttonStyle(RowButtonStyle(prominent: true))
            }
        }
    }
}

struct BrainBeat: View {
    enum Route: Equatable {
        case cloud, local
    }

    static func initialRoute(saved: BrainController.ModelChoice?, cloudReady: Bool, localReady: Bool) -> Route {
        if saved == .local, localReady { return .local }
        return cloudReady || !localReady ? .cloud : .local
    }

    static func isReady(_ row: CloudBrainList.Row, states: [BrainController.ModelChoice: SetupState], hasProfile: Bool) -> Bool {
        if row == .apiKey { return hasProfile }
        if case .ready = states[row.choice] { return true }
        return false
    }

    @ObservedObject var director: OnboardingDirector
    @ObservedObject var brain: BrainController
    let catalog: RuntimeCatalog?
    let openSettings: () -> Void
    @State private var route: Route?

    private var cloudRow: CloudBrainList.Row {
        let rows = CloudBrainList.rows(claudeCodeInstalled: brain.claudeCodeAvailable, agents: CloudBrainList.installedAgents(saved: brain.acpAgent))
        return CloudBrainList.preselected(
            saved: brain.hasSavedChoice ? brain.modelChoice : nil,
            savedAgent: brain.acpAgent,
            rows: rows,
            states: brain.setupStates,
            hasProfile: brain.activeProfile != nil
        ) ?? .chatGPT
    }

    private var cloudReady: Bool { Self.isReady(cloudRow, states: brain.setupStates, hasProfile: brain.activeProfile != nil) }
    private var localReady: Bool { brain.onDeviceRouteAvailable }
    private var selected: Route {
        route ?? Self.initialRoute(saved: brain.hasSavedChoice ? brain.modelChoice : nil, cloudReady: cloudReady, localReady: localReady)
    }

    var body: some View {
        OnboardingBeatLayout(title: "How should I think?", artHeight: 52) {
            PerryCharacterView(pose: perryPose, size: 40)
        } detail: {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    card(.cloud, title: "Cloud", sketch: .cloud, detail: cloudDetail, status: cloudReady ? readyDetail : nil)
                    card(.local, title: "On this Mac", sketch: .laptop, detail: "Private and offline. Nothing leaves this Mac.",
                         status: localReady ? nil : "Set up later in Settings")
                        .disabled(!localReady)
                }
                .fixedSize(horizontal: false, vertical: true)
                if let error = brain.signInError {
                    Text(error)
                        .font(PerryTheme.Scale.secondary)
                        .foregroundStyle(PerryTheme.Colors.caution)
                }
            }
        } actions: {
            OnboardingFooter {
                EmptyView()
            } primary: {
                primary
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.large)
            } trailing: {
                if brain.isSigningIn {
                    Button("Cancel") { brain.cancelSignIn() }
                } else if selected == .cloud && !cloudReady {
                    Button("Skip") { director.skip() }
                }
            }
        }
        .task {
            if let catalog { await brain.refreshSetupStates(using: catalog) }
            await brain.refresh()
        }
    }

    private var cloudDetail: String {
        switch cloudRow {
        case .chatGPT: "Sharper answers. Uses your ChatGPT account."
        case .apiKey: "Sharper answers. Uses your API key."
        default: "Sharper answers. Uses \(cloudRow.title)."
        }
    }

    private var readyDetail: String? {
        if case .ready(let detail) = brain.setupStates[cloudRow.choice] { return detail }
        return brain.activeProfile?.displayName
    }

    @ViewBuilder
    private var primary: some View {
        if brain.isSigningIn {
            Button {} label: { OnboardingPrimaryLabel(title: "Waiting for sign-in…") }
                .disabled(true)
        } else if selected == .local {
            Button {
                brain.modelChoice = .local
                director.skip()
            } label: { OnboardingPrimaryLabel(title: "Continue") }
                .keyboardShortcut(.defaultAction)
        } else if cloudReady {
            Button {
                if case .agent(let agent) = cloudRow { brain.setAcpAgent(agent) } else { brain.modelChoice = cloudRow.choice }
                director.skip()
            } label: { OnboardingPrimaryLabel(title: "Continue") }
                .keyboardShortcut(.defaultAction)
        } else if cloudRow == .chatGPT {
            Button {
                brain.signInWithChatGPT { connected in
                    guard connected else { return }
                    brain.modelChoice = .chatGPT
                    director.skip()
                }
            } label: { OnboardingPrimaryLabel(title: "Connect ChatGPT") }
                .keyboardShortcut(.defaultAction)
        } else {
            Button(action: openSettings) { OnboardingPrimaryLabel(title: "Open Settings") }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var perryPose: PerryCharacterPose {
        var pose = PerryCharacterPose()
        pose.face = .happy
        pose.gaze = CGVector(dx: selected == .local ? 0.9 : -0.9, dy: 0.3)
        return pose
    }

    private func card(_ value: Route, title: String, sketch: ChoiceSketch.Kind, detail: String, status: String?) -> some View {
        let isSelected = selected == value
        return Button { route = value } label: {
            VStack(alignment: .leading, spacing: 4) {
                ChoiceSketch(kind: sketch, lit: isSelected)
                    .modifier(InkDrawOn())
                    .padding(.bottom, 6)
                Text(title)
                    .font(PerryTheme.Scale.rowTitle)
                    .foregroundStyle(PerryTheme.Colors.text)
                Text(detail)
                    .font(PerryTheme.Scale.secondary)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let status {
                    Text(status)
                        .font(PerryTheme.Scale.meta)
                        .foregroundStyle(PerryTheme.Colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            .padding(14)
            .frame(width: 204, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(PerryTheme.Colors.surface.opacity(isSelected ? 1 : 0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? PerryTheme.Colors.accent.opacity(0.7) : PerryTheme.Colors.subtleSeparator, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ShortcutsBeat: View {
    @ObservedObject var director: OnboardingDirector
    let controller: AppController
    @ObservedObject var check: ShortcutCheck
    @AppStorage(PerryPreferences.$talkGesture.key) private var talkRaw = Gesture.defaultTalk.rawValue
    @AppStorage(PerryPreferences.$openAtLogin.key) private var openAtLogin = true

    private var talk: Gesture { Gesture(rawValue: talkRaw) ?? .defaultTalk }

    var body: some View {
        OnboardingBeatLayout(title: "\(talk.spoken) and say hi.", message: "Click the key to change it.", artHeight: 40) {
            Color.clear
        } detail: {
            ShortcutRecorders(controller: controller, roles: [.talk], presetLimit: 0)
                .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(PerryTheme.Colors.subtleSeparator, lineWidth: 1)
                }
                .multilineTextAlignment(.leading)
                .buttonStyle(InkButtonStyle(.secondary))
                .controlSize(.small)
                .font(PerryTheme.Scale.body)
        } actions: {
            OnboardingFooter {
                Toggle("Open at login", isOn: $openAtLogin)
                    .toggleStyle(.checkbox)
                    .font(PerryTheme.Scale.secondary)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .help("Open Perry when you log in to this Mac")
            } primary: {
                Button { director.skip() } label: { OnboardingPrimaryLabel(title: "Continue") }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(check.result == .needsInputMonitoring)
            } trailing: {
                if check.result == .needsInputMonitoring {
                    Button("Skip") { director.skip() }
                }
            }
        }
    }
}
