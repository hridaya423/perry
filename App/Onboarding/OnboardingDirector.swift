import AppKit
import Foundation
import PerryCapture

@MainActor
final class OnboardingDirector: ObservableObject {
    enum Beat: String, CaseIterable, Sendable {
        case greet, brainChoice, firstTalk, screenAccess, practice, finale
    }

    enum PracticeStep: String, CaseIterable, Sendable {
        case pointAsk, guide, renameUndo, dictate
    }

    struct Effects {
        var permissionProbe: () async -> PerryPermissionSnapshot = { await PerryPermissionSnapshot.probe() }
        var speak: (String) -> Void = { _ in }
        var requestScreenAccess: () -> Void = {}
        var openScreenAccessSettings: () -> Void = {}
        var openScreenRecordingSettings: () -> Void = {}
        var beginPractice: () -> Void = {}
        var endPractice: () -> Void = {}
        var finish: () -> Void = {}
        var now: () -> Date = { Date() }
    }

    @Published private(set) var beat: Beat?
    @Published private(set) var practiceStep: PracticeStep?
    @Published private(set) var practiceStarted = false
    @Published private(set) var permissions: PerryPermissionSnapshot?
    @Published private(set) var micDenied = false
    private(set) var startedAt: Date?

    private let effects: Effects
    private let defaults: UserDefaults?
    private let checkpointKey = "perry.onboarding.beat"
    private let practiceKey = "perry.onboarding.practice"
    private var permissionTimer: Timer?
    private var isRefreshingPermissions = false

    init(effects: Effects = Effects(), defaults: UserDefaults? = nil) {
        self.effects = effects
        self.defaults = defaults
    }

    func start(resume: Bool = true) {
        startedAt = effects.now()
        let saved = resume ? defaults?.string(forKey: checkpointKey).flatMap(Beat.init(rawValue:)) : nil
        let savedPractice = resume ? defaults?.string(forKey: practiceKey).flatMap(PracticeStep.init(rawValue:)) : nil
        enter(saved ?? .greet)
        if beat == .practice, let savedPractice {
            practiceStep = savedPractice
            defaults?.set(savedPractice.rawValue, forKey: practiceKey)
        }
    }

    func skip() {
        advance()
    }

    func noteTalkTurnCompleted() {
        if beat == .firstTalk {
            advance()
        } else if beat == .practice, practiceStep == .pointAsk {
            notePracticeStepCompleted()
        }
    }

    func noteMicrophoneDenied() {
        micDenied = true
        if beat == .firstTalk { effects.speak(Self.scriptNoMicTalk) }
    }

    func noteBrainChoiceMade() {
        guard beat == .brainChoice else { return }
        advance()
    }

    func startPractice() {
        guard beat == .practice, !practiceStarted else { return }
        practiceStarted = true
        effects.beginPractice()
        if let practiceStep { effects.speak(Self.practiceScript(for: practiceStep)) }
    }

    func notePracticeWindowClosed() {
        guard beat == .practice else { return }
        practiceStarted = false
    }

    func notePracticeStepCompleted() {
        guard beat == .practice, practiceStarted, let step = practiceStep else { return }
        if let next = PracticeStep.allCases.drop(while: { $0 != step }).dropFirst().first {
            practiceStep = next
            defaults?.set(next.rawValue, forKey: practiceKey)
            effects.speak(Self.practiceScript(for: next))
        } else {
            advance()
        }
    }

    func openAccessibilitySettings() {
        guard beat == .screenAccess else { return }
        effects.openScreenAccessSettings()
    }

    func openScreenRecordingSettings() {
        guard beat == .screenAccess else { return }
        effects.openScreenRecordingSettings()
    }

    func refreshPermissions() async {
        guard beat == .screenAccess, !isRefreshingPermissions else { return }
        isRefreshingPermissions = true
        defer { isRefreshingPermissions = false }
        let snapshot = await effects.permissionProbe()
        guard beat == .screenAccess else { return }
        permissions = snapshot
        if snapshot.requiredPermissionsGranted { advance() }
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        beat = nil
    }

    private func advance() {
        guard let current = beat else { return }
        if current == .practice { effects.endPractice() }
        let order = Beat.allCases
        guard let index = order.firstIndex(of: current), index + 1 < order.count else {
            stop()
            defaults?.removeObject(forKey: checkpointKey)
            defaults?.removeObject(forKey: practiceKey)
            effects.finish()
            return
        }
        enter(order[index + 1])
    }

    private func enter(_ next: Beat) {
        permissionTimer?.invalidate()
        permissionTimer = nil
        beat = next
        practiceStep = next == .practice ? .pointAsk : nil
        practiceStarted = false
        defaults?.set(next.rawValue, forKey: checkpointKey)
        switch next {
        case .greet: effects.speak(Self.scriptGreet)
        case .brainChoice: effects.speak(Self.scriptBrain)
        case .firstTalk: effects.speak(micDenied ? Self.scriptNoMicTalk : Self.scriptTalk)
        case .screenAccess:
            effects.speak(Self.scriptPermissions)
            effects.requestScreenAccess()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refreshPermissions() }
            }
        case .practice: defaults?.set(PracticeStep.pointAsk.rawValue, forKey: practiceKey)
        case .finale: effects.speak(Self.scriptFinale)
        }
    }

    static let scriptGreet = "Hi, I’m Perry. Let’s connect your account, then try a conversation."
    static let scriptTalk = "Tell me something you’re working on, or ask a question. You can type below."
    static let scriptNoMicTalk = "You can type your first question below. A microphone isn’t required."
    static let scriptPermissions = "Screen permissions let me understand what you point at and help in other apps. You can enable them in System Settings or do this later."
    static let scriptBrain = "Connect your ChatGPT account to get started. You can also configure your own model in Settings."
    static let scriptFinale = "Home keeps your conversations together. Hold Control and Option to talk, or double-tap Control to type."

    static func practiceScript(for step: PracticeStep) -> String {
        switch step {
        case .pointAsk: "In the practice window, point at something and ask what it is."
        case .guide: "Ask Perry to show you how to rename a file."
        case .renameUndo: "Ask Perry to rename the three practice files, then undo the change."
        case .dictate: "Focus the practice text box, hold the talk key, and dictate a sentence."
        }
    }
}
