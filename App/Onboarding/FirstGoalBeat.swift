import PerryBrain
import PerryCapture
import SwiftUI

enum FirstGoal: Equatable {
    case guide(app: String)
    case ask
    case make

    static let makeVerbs = ["write ", "make ", "build ", "create ", "draft ", "design ", "plan "]

    static func route(_ goal: String, installedApps: [String]) -> FirstGoal {
        let named = installedApps
            .filter { goal.range(of: "\\b\(NSRegularExpression.escapedPattern(for: $0))\\b", options: [.regularExpression, .caseInsensitive]) != nil }
            .max { $0.count < $1.count }
        if let named { return .guide(app: named) }
        let lowered = goal.lowercased()
        return makeVerbs.contains { lowered.hasPrefix($0) } ? .make : .ask
    }

    static func installedApps() -> [String] {
        ["/Applications", "/System/Applications"].flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { $0.hasSuffix(".app") }
                .map { String($0.dropLast(4)) }
        }
    }

    static func savedGoal(in files: MemoryFiles?) -> String? {
        files?.profileField("Learning goal")
    }

    static func askPrompt(for goal: String) -> String {
        "I want to learn \(goal). Give me a three-line starter plan, then ask me one question."
    }

    var needsScreen: Bool { self != .ask }

    var mode: HomeModel.ComposerMode {
        switch self {
        case .guide: .guide
        case .ask: .ask
        case .make: .task
        }
    }

    func promise(_ goal: String) -> String {
        switch self {
        case .guide(let app): "I’ll open \(app) and show you, one step at a time."
        case .ask: "I’ll give you a short plan and one question to start."
        case .make: "I’ll get it started. I ask before I change anything."
        }
    }
}

struct FirstGoalBeat: View {
    @ObservedObject var director: OnboardingDirector
    @ObservedObject var model: HomeModel
    @State var goal: String
    let installedApps: [String]
    @State private var closing = false
    @State private var asking = false
    @FocusState private var focused: Bool

    private var trimmed: String { goal.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var route: FirstGoal { FirstGoal.route(trimmed, installedApps: installedApps) }
    private var needsScreenAccess: Bool { route.needsScreen && !PerryPermissionProbe.checkScreenRecording().isUsable }

    var body: some View {
        if closing {
            OnboardingBeatLayout(title: "I’m up here whenever you need me.", artHeight: 96) {
                Color.clear
            } detail: {
                EmptyView()
            } actions: {
                EmptyView()
            }
            .task {
                try? await Task.sleep(for: .seconds(2.5))
                director.skip()
            }
        } else {
            OnboardingBeatLayout(
                title: trimmed.isEmpty || asking ? "What do you want to learn first?" : "Let’s start with \(trimmed).",
                message: trimmed.isEmpty || asking ? nil : [route.promise(trimmed), needsScreenAccess ? "To show you, I need to see your screen." : nil].compactMap { $0 }.joined(separator: " "),
                artHeight: 64
            ) {
                Color.clear
            } detail: {
                if trimmed.isEmpty || asking {
                    TextField("Figma auto layout, Spanish, a pitch deck…", text: $goal)
                        .textFieldStyle(.plain)
                        .font(PerryTheme.Scale.input)
                        .multilineTextAlignment(.center)
                        .focused($focused)
                        .onSubmit { asking = false }
                        .padding(.horizontal, 16)
                        .frame(width: 360, height: 44)
                        .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 22))
                        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(PerryTheme.Colors.subtleSeparator) }
                        .task { focused = true }
                } else {
                    Button("Something else") { asking = true }
                        .buttonStyle(OnboardingLinkStyle())
                }
            } actions: {
                OnboardingFooter {
                    EmptyView()
                } primary: {
                    Button(action: start) { OnboardingPrimaryLabel(title: needsScreenAccess ? "Allow and start" : "Start") }
                        .buttonStyle(InkButtonStyle())
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmed.isEmpty)
                } trailing: {
                    Button("Not now") { closing = true }
                }
            }
        }
    }

    private func start() {
        guard !trimmed.isEmpty else { return }
        if asking {
            asking = false
            return
        }
        let route = route
        let goal = trimmed
        Task {
            if needsScreenAccess {
                if await PermissionGuideCoordinator.guide(.screenRecording) == .needsRelaunch {
                    try? model.deps.controller?.memoryFiles?.setProfileField("Learning goal", goal)
                    GrantMonitor.relaunchSelf()
                    return
                }
            }
            model.composerMode = route.mode
            model.onStartConversation?(route == .ask ? FirstGoal.askPrompt(for: goal) : goal)
            director.beginFirstTask()
        }
    }
}
