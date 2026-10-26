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
                BrainChoiceBeat(director: director, brain: brain, openSettings: openSettings)
            }
        case .access:
            AccessBeat(director: director)
        case .shortcuts:
            PendingBeat(director: director, title: "Shortcuts")
        case .interview:
            PendingBeat(director: director, title: "About you")
        case .apps:
            PendingBeat(director: director, title: "Your apps")
        case .firstGoal:
            PendingBeat(director: director, title: "First goal")
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
            VStack(spacing: 6) {
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
        OnboardingRow(title: title, detail: detail, selected: granted) {
            Image(systemName: icon)
                .font(PerryTheme.Icon.row)
                .foregroundStyle(granted ? PerryTheme.Colors.accent : PerryTheme.Colors.text)
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

private struct BrainChoiceBeat: View {
    @ObservedObject var director: OnboardingDirector
    @ObservedObject var brain: BrainController
    let openSettings: () -> Void

    private var choice: BrainController.ModelChoice { brain.modelChoice }
    private var signedIn: Bool { if case .signedIn = brain.account { return true }; return false }
    private var ready: Bool {
        switch choice {
        case .local: brain.onDeviceRouteAvailable
        case .chatGPT: signedIn
        case .claudeCode: brain.claudeCodeAvailable
        case .acp: brain.acpAgentAvailable
        case .direct: true
        }
    }

    var body: some View {
        OnboardingBeatLayout(
            title: "Choose how I think.",
            message: "Start on this Mac or connect ChatGPT. Switch any time in Settings."
        ) {
            ChoiceSketch(local: choice == .local)
                .scaleEffect(0.76)
                .modifier(InkDrawOn())
        } detail: {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    option(.local, title: "On this Mac", detail: brain.onDeviceRouteAvailable ? "Private and offline" : "Not on this Mac", icon: "laptopcomputer")
                        .disabled(!brain.onDeviceRouteAvailable)
                    option(.chatGPT, title: "ChatGPT", detail: signedIn ? "Signed in" : "Uses your account", icon: "cloud")
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
                        Button { director.skip() } label: { OnboardingPrimaryLabel(title: "Continue") }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button {
                            brain.signInWithChatGPT { connected in if connected { director.skip() } }
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
        return Button { brain.modelChoice = value } label: {
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
            .background(PerryTheme.Colors.surface.opacity(selected ? 1 : 0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? PerryTheme.Colors.accent.opacity(0.7) : PerryTheme.Colors.subtleSeparator, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PendingBeat: View {
    @ObservedObject var director: OnboardingDirector
    let title: String

    var body: some View {
        OnboardingBeatLayout(title: title) {
            EmptyView()
        } detail: {
            EmptyView()
        } actions: {
            Button { director.skip() } label: { OnboardingPrimaryLabel(title: "Continue") }
                .buttonStyle(InkButtonStyle())
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.bottom, 8)
        }
    }
}
