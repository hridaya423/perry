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
        case .greet:
            GreetBeat(director: director)
        case .firstTalk:
            if let controller = model.deps.controller {
                FirstTalkBeat(director: director, model: model, voice: controller.conversationVoice, brain: brain, openSettings: openSettings)
            }
        case .screenAccess:
            ScreenAccessBeat(director: director)
        case .brainChoice:
            if let brain {
                BrainChoiceBeat(director: director, brain: brain, openSettings: openSettings)
            }
        case .practice:
            PracticeBeat(director: director)
        case .finale:
            FinaleBeat(director: director, brain: brain)
        case nil:
            EmptyView()
        }
    }
}

private struct GreetBeat: View {
    @ObservedObject var director: OnboardingDirector

    var body: some View {
        VStack(spacing: 0) {
            HelloGreetingView()
                .frame(width: 420, height: 210)
                .padding(.top, 16)
            Text("I’m Perry. I live up in your notch and help with whatever is on your screen.")
                .font(.system(size: 16))
                .lineSpacing(3)
                .foregroundStyle(PerryTheme.Colors.text.opacity(0.78))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .padding(.top, 2)
                .modifier(LateEntrance(delay: HelloInk.lift.upperBound))
            Spacer(minLength: 12)
            Button { director.skip() } label: { OnboardingPrimaryLabel(title: "Let’s begin") }
                .buttonStyle(InkButtonStyle())
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .modifier(LateEntrance(delay: HelloInk.lift.upperBound + 0.08))
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                withAnimation(OnboardingStyle.enter.delay(delay)) { shown = true }
            }
    }
}

private struct FirstTalkBeat: View {
    @ObservedObject var director: OnboardingDirector
    @ObservedObject var model: HomeModel
    @ObservedObject var voice: VoiceConversationController
    let brain: BrainController?
    let openSettings: () -> Void
    @State private var typing = false
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private var threadID: UUID? {
        if case .thread(let id) = model.sidebarSelection { return id }
        return nil
    }

    private var thread: PerryThread? { threadID.flatMap { id in model.threads.first { $0.id == id } } }
    private var pendingQuestion: String? { threadID.flatMap { model.pendingQuestions[$0]?.text } }
    private var question: String? {
        pendingQuestion ?? thread?.turns.last?.question ?? (voice.transcript.isEmpty ? nil : voice.transcript)
    }
    private var answer: String? {
        let text = threadID.flatMap { model.streamingAnswers[$0] } ?? (pendingQuestion == nil ? thread?.turns.last?.answer : nil)
        return text?.isEmpty == false ? text : nil
    }
    private var failure: String? { threadID.flatMap { model.threadErrors[$0] } ?? voice.error }
    private var answeredTurns: Int { pendingQuestion == nil ? (thread?.turns.count ?? 0) : 0 }
    private var working: Bool { pendingQuestion != nil || voice.state == .thinking || model.isCreatingConversation }

    private var mood: PerryMood {
        if director.firstAnswerReceived { return .celebrating }
        switch voice.state {
        case .listening: return .listening
        case .thinking, .requestingPermission: return .thinking
        case .speaking: return .speaking
        case .failed: return .needsYou
        case .idle: return working ? .thinking : (answer == nil ? .resting : .speaking)
        }
    }

    private var title: String? {
        if director.firstAnswerReceived { return nil }
        if failure != nil { return "That didn’t go through." }
        switch voice.state {
        case .requestingPermission: return "Getting the mic ready…"
        case .listening: return "I’m listening."
        case .thinking: return "Let me think…"
        case .speaking: return "Here’s what I found."
        default: return working ? "Let me think…" : "Ask me something."
        }
    }

    private var message: String? {
        if director.firstAnswerReceived {
            return "That’s the idea. Ask me anything, any time."
        }
        if let failure { return failure }
        if question != nil || answer != nil { return nil }
        if director.micDenied { return "Your microphone is off for Perry, so let’s type. Try “What can you help me with?”" }
        switch voice.state {
        case .listening: return "Talk normally. I’ll answer when you pause."
        default: return "Say it out loud or type it. Try “What can you help me with?”"
        }
    }

    var body: some View {
        OnboardingBeatLayout(title: title, message: message, artHeight: director.firstAnswerReceived ? 210 : OnboardingStyle.artHeight) {
            if question != nil || answer != nil {
                exchange
            } else {
                PerryCharacter(mood: mood, size: 76)
                    .frame(width: 96, height: 96)
            }
        } detail: {
            EmptyView()
        } actions: {
            actions
        }
        .onAppear { typing = director.micDenied }
        .onChange(of: director.micDenied) { _, denied in if denied { typing = true } }
        .onChange(of: answeredTurns) { _, count in if count > 0 { director.noteTalkTurnCompleted() } }
    }

    private var exchange: some View {
        HStack(alignment: .top, spacing: 12) {
            PerryCharacter(mood: mood, size: 44)
                .frame(width: 48, height: 48)
            card
        }
        .frame(maxWidth: 470, maxHeight: .infinity, alignment: .bottom)
        .padding(.top, 10)
    }

    private var card: some View {
        ViewThatFits(in: .vertical) {
            cardText
            ScrollView { cardText }.scrollIndicators(.never)
        }
        .background(OnboardingStyle.carbon, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(OnboardingStyle.hairline) }
    }

    private var cardText: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let question {
                Text(question)
                    .font(.system(size: 13))
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
            }
            if let answer {
                Text(answer)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(PerryTheme.Colors.text)
                    .textSelection(.enabled)
            } else if working {
                PerryCharacter(mood: .thinking, size: 30)
                    .frame(width: 36, height: 36)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    @ViewBuilder
    private var actions: some View {
        if director.firstAnswerReceived {
            Button { director.skip() } label: { OnboardingPrimaryLabel(title: "Continue") }
                .buttonStyle(InkButtonStyle())
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.bottom, 8)
        } else {
            OnboardingFooter {
                if typing {
                    if !director.micDenied { Button("Use my voice") { typing = false } }
                } else {
                    Button("Type instead") { voice.cancel(); typing = true }
                }
            } primary: {
                if typing {
                    composer
                } else {
                    Button(action: talk) { OnboardingPrimaryLabel(title: talkTitle, systemImage: talkIcon) }
                        .buttonStyle(InkButtonStyle())
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(working && voice.state == .idle)
                }
            } trailing: {
                Button("Skip") { director.skip() }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask Perry…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($composerFocused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(PerryTheme.Colors.onPrimaryAction)
                    .frame(width: 30, height: 30)
                    .background(PerryTheme.Colors.primaryAction.opacity(canSend ? 1 : 0.3), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(width: 260, height: 46)
        .background(OnboardingStyle.carbon, in: Capsule())
        .overlay { Capsule().strokeBorder(composerFocused ? PerryTheme.Colors.accent.opacity(0.6) : OnboardingStyle.hairline) }
        .onAppear { composerFocused = true }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !working
    }

    private func send() {
        guard canSend else { return }
        model.onStartConversation?(draft)
        draft = ""
    }

    private var talkTitle: String {
        switch voice.state {
        case .listening: "I’m done"
        case .requestingPermission, .thinking, .speaking: "Stop"
        case .failed: "Try again"
        case .idle: answer == nil ? "Talk to Perry" : "Ask another"
        }
    }

    private var talkIcon: String {
        switch voice.state {
        case .listening: "arrow.up"
        case .requestingPermission, .thinking, .speaking: "stop.fill"
        case .idle, .failed: "mic.fill"
        }
    }

    private func talk() {
        switch voice.state {
        case .idle, .failed: voice.start()
        case .listening: voice.finishListening()
        default: voice.cancel()
        }
    }
}

private struct ScreenAccessBeat: View {
    @ObservedObject var director: OnboardingDirector
    @State private var asked: Set<String> = []

    private var accessibility: Bool { director.permissions?.accessibility == true }
    private var recording: Bool { director.permissions?.screenRecording == .granted }

    var body: some View {
        OnboardingBeatLayout(
            title: "Let me see what you mean.",
            message: "Two permissions let me point at things for you."
        ) {
            PermissionSketch(lit: accessibility && recording)
                .modifier(InkDrawOn())
        } detail: {
            VStack(spacing: 6) {
                permissionRow(
                    key: "accessibility", title: "Accessibility", detail: "Read buttons, menus and fields",
                    icon: "hand.point.up.left", granted: accessibility, prominent: true
                ) { director.openAccessibilitySettings() }
                permissionRow(
                    key: "recording", title: "Screen Recording", detail: "See the window you point at",
                    icon: "macwindow", granted: recording, prominent: accessibility
                ) { director.openScreenRecordingSettings() }
                Text("Opens System Settings. You can turn either off any time.")
                    .font(.caption)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .padding(.top, 4)
            }
        } actions: {
            OnboardingFooter {
                EmptyView()
            } primary: {
                if accessibility && recording {
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

    private func permissionRow(key: String, title: String, detail: String, icon: String, granted: Bool, prominent: Bool, open: @escaping () -> Void) -> some View {
        OnboardingRow(title: title, detail: asked.contains(key) && !granted ? "Turn on Perry in System Settings, then come back" : detail, selected: granted) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(granted ? PerryTheme.Colors.accent : PerryTheme.Colors.text)
        } trailing: {
            if granted {
                GrantedMark()
            } else {
                Button(asked.contains(key) ? "Open again" : "Allow") {
                    asked.insert(key)
                    open()
                }
                .buttonStyle(RowButtonStyle(prominent: prominent))
                .keyboardShortcut(key == "accessibility" || accessibility ? .defaultAction : nil)
            }
        }
    }
}

private struct BrainChoiceBeat: View {
    @ObservedObject var director: OnboardingDirector
    @ObservedObject var brain: BrainController
    let openSettings: () -> Void

    private var choice: BrainController.ModelChoice { BrainController.ModelChoice(rawValue: brain.modelChoice) ?? .chatGPT }
    private var signedIn: Bool { if case .signedIn = brain.account { return true }; return false }
    private var ready: Bool {
        switch choice {
        case .local: brain.onDeviceRouteAvailable
        case .chatGPT: signedIn
        case .direct: true
        }
    }

    var body: some View {
        OnboardingBeatLayout(
            title: "Choose how I think.",
            message: "Start on this Mac or connect ChatGPT. Switch any time in Settings."
        ) {
            ChoiceSketch(local: choice == .local)
                .modifier(InkDrawOn())
        } detail: {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    option(.local, title: "On this Mac", detail: brain.onDeviceRouteAvailable ? "Private and offline" : "Not on this Mac", icon: "laptopcomputer")
                        .disabled(!brain.onDeviceRouteAvailable)
                    option(.chatGPT, title: "ChatGPT", detail: signedIn ? "Signed in and ready" : "Your ChatGPT account", icon: "cloud")
                }
                if let error = brain.signInError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                }
            }
        } actions: {
            OnboardingFooter {
                if !brain.isSigningIn { Button("Other models", action: openSettings) }
            } primary: {
                Group {
                    if brain.isSigningIn {
                        Button {} label: { OnboardingPrimaryLabel(title: "Waiting for sign-in…") }
                            .disabled(true)
                    } else if ready {
                        Button { director.noteBrainChoiceMade() } label: { OnboardingPrimaryLabel(title: "Continue") }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button {
                            brain.signInWithChatGPT { connected in if connected { director.noteBrainChoiceMade() } }
                        } label: { OnboardingPrimaryLabel(title: "Connect ChatGPT") }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .buttonStyle(InkButtonStyle())
                .controlSize(.large)
            } trailing: {
                if brain.isSigningIn {
                    Button("Cancel") { brain.cancelSignIn() }
                } else {
                    Button("Later") { director.skip() }
                }
            }
        }
        .task { await brain.refresh() }
    }

    private func option(_ value: BrainController.ModelChoice, title: String, detail: String, icon: String) -> some View {
        let selected = choice == value
        return Button { brain.modelChoice = value.rawValue } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? PerryTheme.Colors.accent : PerryTheme.Colors.text)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(PerryTheme.Colors.text)
                    Text(detail).font(.system(size: 12)).foregroundStyle(PerryTheme.Colors.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Circle()
                    .strokeBorder(selected ? PerryTheme.Colors.accent : PerryTheme.Colors.text.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 16, height: 16)
                    .overlay { if selected { Circle().fill(PerryTheme.Colors.accent).frame(width: 8, height: 8) } }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .frame(width: 214, height: 56)
            .background(OnboardingStyle.carbon.opacity(selected ? 1 : 0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? PerryTheme.Colors.accent.opacity(0.7) : OnboardingStyle.hairline, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PracticeBeat: View {
    @ObservedObject var director: OnboardingDirector

    private var stepIndex: Int {
        director.practiceStep.flatMap { OnboardingDirector.PracticeStep.allCases.firstIndex(of: $0) } ?? 0
    }

    var body: some View {
        OnboardingBeatLayout(
            title: director.practiceStarted ? "Step \(stepIndex + 1) of 4" : "Try it on something safe.",
            message: director.practiceStarted
                ? director.practiceStep.map(OnboardingDirector.practiceHint(for:))
                : "A practice window with sample files and notes. Point, ask, rename, undo. Nothing of yours is touched."
        ) {
            PracticeWindowSketch(step: director.practiceStarted ? stepIndex : 0)
                .modifier(InkDrawOn())
        } detail: {
            StepGrid(current: stepIndex, started: director.practiceStarted)
        } actions: {
            OnboardingFooter {
                if director.practiceStarted { Button("Skip this step") { director.notePracticeStepCompleted() } }
            } primary: {
                if director.practiceStarted {
                    Button { director.showPracticeWindow() } label: { OnboardingPrimaryLabel(title: "Show practice window") }
                        .buttonStyle(InkButtonStyle())
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button { director.startPractice() } label: { OnboardingPrimaryLabel(title: "Open practice window") }
                        .buttonStyle(InkButtonStyle())
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            } trailing: {
                Button("Skip practice") { director.skip() }
            }
        }
    }
}

private struct FinaleBeat: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var director: OnboardingDirector
    let brain: BrainController?
    @StateObject private var keys = ModifierWatcher()
    @State private var permissions: PerryPermissionSnapshot?
    @State private var shown = false
    @State private var leaving = false

    private var firstName: String? {
        NSFullUserName().split(separator: " ").first.map(String.init)
    }

    private var items: [FinaleCard.Item] {
        let local = brain?.modelChoice == BrainController.ModelChoice.local.rawValue
        let seesScreen = permissions?.requiredPermissionsGranted == true
        return [
            .init(text: local ? "Answers on this Mac" : "Answers with ChatGPT", on: true),
            .init(text: seesScreen ? "Sees the window you point at" : "Typing works now. Screen access waits in Settings.", on: seesScreen),
            .init(text: "Opens at login. Change it in Settings.", on: true)
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            FinaleCard(name: firstName, items: items, since: .now, leaving: leaving)
                .rotationEffect(.degrees(shown || reduceMotion ? -1.5 : -6))
                .offset(y: shown || reduceMotion ? 0 : 24)
                .opacity(shown || reduceMotion ? 1 : 0)
                .padding(.top, 4)
            Text("I live in your notch now.")
                .font(OnboardingStyle.title)
                .tracking(-0.4)
                .padding(.top, 22)
            HStack(spacing: 36) {
                LargeShortcut(keys: ["⌃", "⌥"], lit: keys.held, label: "Hold to talk")
                LargeShortcut(keys: ["⌃", "⌃"], label: "Double-tap to type")
            }
            .padding(.top, 16)
            Spacer(minLength: 8)
            OnboardingFooter {
                EmptyView()
            } primary: {
                Button(action: finish) { OnboardingPrimaryLabel(title: "Start using Perry") }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } trailing: {
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            keys.start()
            withAnimation(.spring(duration: 0.7, bounce: 0.25).delay(0.1)) { shown = true }
        }
        .onDisappear { keys.stop() }
        .task { permissions = await PerryPermissionSnapshot.probe() }
    }

    private func finish() {
        guard !leaving else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.5, 0, 0.75, 0, duration: 0.36)) { leaving = true }
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 380))
            if director.beat == .finale { director.skip() }
        }
    }
}
