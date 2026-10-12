import AppKit
import Foundation
import PerryCapture

@MainActor
final class OnboardingDirector: ObservableObject {
    enum Beat: String, CaseIterable, Sendable {
        case greet, firstTalk, screenAccess, brainChoice, practice, finale
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
        /// The first-answer beat runs before model setup: when an on-device
        /// route exists and the user never chose one, make it the default so
        /// no account is needed. Never overrides a saved choice.
        var preferOnDeviceBrain: () -> Void = {}
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
    private var permissionTimer: Timer?
    private var isRefreshingPermissions = false

    init(effects: Effects = Effects(), defaults: UserDefaults? = nil) {
        self.effects = effects
        self.defaults = defaults
    }

    func start(resume: Bool = true) {
        startedAt = effects.now()
        let saved = resume ? defaults?.string(forKey: PerryPreferences.$onboardingBeat.key).flatMap(Beat.init(rawValue:)) : nil
        let savedPractice = resume ? defaults?.string(forKey: PerryPreferences.$onboardingPractice.key).flatMap(PracticeStep.init(rawValue:)) : nil
        enter(saved ?? .greet)
        if beat == .practice, let savedPractice {
            practiceStep = savedPractice
            defaults?.set(savedPractice.rawValue, forKey: PerryPreferences.$onboardingPractice.key)
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
            defaults?.set(next.rawValue, forKey: PerryPreferences.$onboardingPractice.key)
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
            defaults?.removeObject(forKey: PerryPreferences.$onboardingBeat.key)
            defaults?.removeObject(forKey: PerryPreferences.$onboardingPractice.key)
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
        defaults?.set(next.rawValue, forKey: PerryPreferences.$onboardingBeat.key)
        switch next {
        case .greet: effects.speak(Self.scriptGreet)
        case .brainChoice: effects.speak(Self.scriptBrain)
        case .firstTalk:
            effects.preferOnDeviceBrain()
            effects.speak(micDenied ? Self.scriptNoMicTalk : Self.scriptTalk)
        case .screenAccess:
            effects.speak(Self.scriptPermissions)
            effects.requestScreenAccess()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refreshPermissions() }
            }
        case .practice: defaults?.set(PracticeStep.pointAsk.rawValue, forKey: PerryPreferences.$onboardingPractice.key)
        case .finale: effects.speak(Self.scriptFinale)
        }
    }

    static let scriptGreet = "Hi, I’m Perry. Let’s try a conversation first — models and permissions can wait."
    static let scriptTalk = "Tell me something you’re working on, or ask a question. You can type below."
    static let scriptNoMicTalk = "You can type your first question below. A microphone isn’t required."
    static let scriptPermissions = "Screen permissions let me understand what you point at and help in other apps. You can enable them in System Settings or do this later."
    static let scriptBrain = "Pick how I answer: ChatGPT, a model on this Mac, or another provider in Settings."
    static let scriptFinale = "Home keeps your conversations together. Hold ⌃⌥ to talk while you point, or double-tap ⌃ to type."

    static func practiceScript(for step: PracticeStep) -> String {
        switch step {
        case .pointAsk: "In the practice window, point at something and ask what it is."
        case .guide: "Ask Perry to show you how to rename a file."
        case .renameUndo: "Ask Perry to rename the three practice files, then undo the change."
        case .dictate: "Focus the practice text box, hold your dictation shortcut, and dictate a sentence."
        }
    }
}
