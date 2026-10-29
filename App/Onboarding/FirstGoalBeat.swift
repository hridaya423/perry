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

    static func request(saved goal: String, route: FirstGoal) -> String {
        route == .make ? goal : "I want to learn \(goal)."
    }

    var needsScreen: Bool { self != .ask }

    var mode: HomeModel.ComposerMode {
        switch self {
        case .guide: .guide
        case .ask: .ask
        case .make: .task
        }
    }
}

struct FirstGoalBeat: View {
    @ObservedObject var director: OnboardingDirector
    @ObservedObject var model: HomeModel
    @State var goal: String
    let installedApps: [String]
    @StateObject private var listener = InterviewListener()
    @AppStorage(PerryPreferences.$talkGesture.key) private var talkRaw = Gesture.defaultTalk.rawValue
    @State private var heard = ""
    @State private var typing = false
    @State private var closing = false
    @FocusState private var focused: Bool

    private var talk: Gesture { Gesture(rawValue: talkRaw) ?? .defaultTalk }
    private var saved: String { goal.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var typed: String { heard.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var title: String { saved.isEmpty ? "What do you want to learn first?" : "Shall we start with \(saved)?" }

    var body: some View {
        if closing {
            OnboardingBeatLayout(title: "I’m up here whenever you need me.", message: "\(talk.spoken) any time to talk to me.") {
                EmptyView()
            } detail: {
                EmptyView()
            } actions: {
                EmptyView()
            }
            .task {
                listener.stop()
                await say("I’m up here whenever you need me. \(talk.said) any time to talk to me.")
                director.skip()
            }
        } else {
            OnboardingBeatLayout(title: title, message: "\(talk.spoken) any time to talk to me.") {
                EmptyView()
            } detail: {
                if typing {
                    TextField("Figma auto layout, Spanish, SQL", text: $heard)
                        .textFieldStyle(.plain)
                        .font(PerryTheme.Scale.input)
                        .multilineTextAlignment(.leading)
                        .focused($focused)
                        .focusEffectDisabled()
                        .onSubmit { start(words: typed) }
                        .padding(.horizontal, 16)
                        .frame(width: 360, height: 44)
                        .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.panel, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: PerryTheme.Radius.panel, style: .continuous).strokeBorder(PerryTheme.Colors.subtleSeparator) }
                        .task { focused = true }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: listener.listening ? "waveform" : "mic.fill")
                            .symbolEffect(.variableColor.iterative, isActive: listener.listening)
                            .foregroundStyle(listener.listening ? PerryTheme.Colors.accent : PerryTheme.Colors.icon)
                        Text(typed.isEmpty ? (listener.listening ? "Listening…" : " ") : typed)
                            .font(PerryTheme.Scale.input)
                            .foregroundStyle(typed.isEmpty ? PerryTheme.Colors.textTertiary : PerryTheme.Colors.text)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 360)
                    .frame(minHeight: 44)
                }
            } actions: {
                OnboardingFooter {
                    if !typing {
                        Button("Type") {
                            listener.stop()
                            heard = ""
                            typing = true
                        }
                    }
                } primary: {
                    if !listener.listening, typing || !saved.isEmpty {
                        Button { typing ? start(words: typed) : start(words: nil) } label: { OnboardingPrimaryLabel(title: "Start") }
                            .buttonStyle(InkButtonStyle())
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                            .disabled(typing && typed.isEmpty)
                    }
                } trailing: {
                    Button("Not now") { closing = true }
                }
            }
            .task(id: saved) {
                guard !typing else { return }
                heard = ""
                await say(title)
                guard !Task.isCancelled else { return }
                listener.start(onPartial: { heard = $0 }, onDone: hear)
            }
            .onDisappear { listener.stop() }
        }
    }

    private func say(_ line: String) async {
        await model.deps.controller?.voice.speakAndWait(line)
    }

    private func hear(_ text: String) {
        heard = text
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        if saved.isEmpty { return start(words: words) }
        switch InterviewModel.heardYes(words) {
        case true?: start(words: nil)
        case false? where words.split(separator: " ").count <= 2: goal = ""
        default: start(words: words)
        }
    }

    private func start(words: String?) {
        let text: String
        let route: FirstGoal
        if let words, !words.isEmpty {
            route = FirstGoal.route(words, installedApps: installedApps)
            text = words
        } else {
            guard !saved.isEmpty else { return }
            route = FirstGoal.route(saved, installedApps: installedApps)
            text = FirstGoal.request(saved: saved, route: route)
        }
        listener.stop()
        Task {
            if route.needsScreen, !PerryPermissionProbe.checkScreenRecording().isUsable {
                if await PermissionGuideCoordinator.guide(.screenRecording) == .needsRelaunch {
                    try? model.deps.controller?.memoryFiles?.setProfileField("Learning goal", words ?? saved)
                    GrantMonitor.relaunchSelf()
                    return
                }
            }
            model.composerMode = route.mode
            model.onStartConversation?(text)
            director.beginFirstTask()
        }
    }
}
