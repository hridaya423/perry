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

    enum Direction: Sendable {
        case forward, backward
    }

    struct Effects {
        var permissionProbe: () async -> PerryPermissionSnapshot = { await PerryPermissionSnapshot.probe() }
        var showHint: (String?) -> Void = { _ in }
        var endTalk: () -> Void = {}
        var openScreenAccessSettings: () -> Void = {}
        var openScreenRecordingSettings: () -> Void = {}
        var beginPractice: () -> Void = {}
        var endPractice: () -> Void = {}
        /// The first-answer beat runs before model setup: when an on-device
        /// route exists and the user never chose one, make it the default so
        /// no account is needed. Never overrides a saved choice.
        var preferOnDeviceBrain: () -> Void = {}
        var mark: (StaticString) -> Void = { _ in }
        var finish: () -> Void = {}
    }

    @Published private(set) var beat: Beat?
    @Published private(set) var direction = Direction.forward
    @Published private(set) var practiceStep: PracticeStep?
    @Published private(set) var practiceStarted = false
    @Published private(set) var permissions: PerryPermissionSnapshot?
    @Published private(set) var firstAnswerReceived = false
    @Published private(set) var micDenied = false

    private let effects: Effects
    private let defaults: UserDefaults?
    private var permissionTimer: Timer?
    private var isRefreshingPermissions = false

    init(effects: Effects = Effects(), defaults: UserDefaults? = nil) {
        self.effects = effects
        self.defaults = defaults
    }

    var canGoBack: Bool {
        guard let beat else { return false }
        return beat != .greet
    }

    func start(resume: Bool = true) {
        let saved = resume ? defaults?.string(forKey: PerryPreferences.$onboardingBeat.key).flatMap(Beat.init(rawValue:)) : nil
        let savedPractice = resume ? defaults?.string(forKey: PerryPreferences.$onboardingPractice.key).flatMap(PracticeStep.init(rawValue:)) : nil
        effects.mark("onboarding.start")
        enter(saved ?? .greet, direction: .forward)
        if beat == .practice, let savedPractice {
            practiceStep = savedPractice
            defaults?.set(savedPractice.rawValue, forKey: PerryPreferences.$onboardingPractice.key)
        }
    }

    func skip() {
        advance()
    }

    func goBack() {
        guard canGoBack, let beat, let index = Beat.allCases.firstIndex(of: beat) else { return }
        if beat == .practice { effects.endPractice() }
        enter(Beat.allCases[index - 1], direction: .backward)
    }

    func noteTalkTurnCompleted() {
        if beat == .firstTalk {
            if !firstAnswerReceived { effects.mark("onboarding.first_answer") }
            firstAnswerReceived = true
        } else if beat == .practice, practiceStep == .pointAsk {
            notePracticeStepCompleted()
        }
    }

    func noteMicrophoneDenied() {
        micDenied = true
    }

    func noteBrainChoiceMade() {
        guard beat == .brainChoice else { return }
        advance()
    }

    func startPractice() {
        guard beat == .practice, !practiceStarted else { return }
        practiceStarted = true
        effects.beginPractice()
        effects.showHint(practiceStep.map(Self.practiceHint(for:)))
    }

    func showPracticeWindow() {
        guard beat == .practice, practiceStarted else { return }
        effects.beginPractice()
    }

    func notePracticeWindowClosed() {
        guard beat == .practice else { return }
        practiceStarted = false
        effects.showHint(nil)
    }

    func notePracticeStepCompleted() {
        guard beat == .practice, practiceStarted, let step = practiceStep else { return }
        if let next = PracticeStep.allCases.drop(while: { $0 != step }).dropFirst().first {
            practiceStep = next
            defaults?.set(next.rawValue, forKey: PerryPreferences.$onboardingPractice.key)
            effects.showHint(Self.practiceHint(for: next))
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
        let isFirstProbe = permissions == nil
        let snapshot = await effects.permissionProbe()
        guard beat == .screenAccess else { return }
        permissions = snapshot
        if isFirstProbe, direction == .forward, snapshot.requiredPermissionsGranted { advance() }
    }

    func pausePermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    func resumePermissionPolling() {
        guard beat == .screenAccess, permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshPermissions() }
        }
    }

    func stop() {
        if beat == .firstTalk { effects.endTalk() }
        pausePermissionPolling()
        effects.showHint(nil)
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
            effects.mark("onboarding.finish")
            effects.finish()
            return
        }
        enter(order[index + 1], direction: .forward)
    }

    private func enter(_ next: Beat, direction: Direction) {
        if beat == .firstTalk { effects.endTalk() }
        pausePermissionPolling()
        effects.showHint(nil)
        self.direction = direction
        beat = next
        practiceStep = next == .practice ? .pointAsk : nil
        practiceStarted = false
        permissions = nil
        firstAnswerReceived = false
        defaults?.set(next.rawValue, forKey: PerryPreferences.$onboardingBeat.key)
        switch next {
        case .firstTalk:
            effects.preferOnDeviceBrain()
        case .screenAccess:
            resumePermissionPolling()
        case .practice:
            defaults?.set(PracticeStep.pointAsk.rawValue, forKey: PerryPreferences.$onboardingPractice.key)
        case .greet, .brainChoice, .finale:
            break
        }
    }

    static func practiceHint(for step: PracticeStep) -> String {
        switch step {
        case .pointAsk: "Point at something in the practice window, then \(TalkGesture.talk.lowercased()) and ask what it is."
        case .guide: "Ask Perry to show you how to rename a file."
        case .renameUndo: "Rename the three practice files, then undo the change."
        case .dictate: "Click the notes box, \(dictationShortcut.title.prefix(1).lowercased() + dictationShortcut.title.dropFirst()), and say a sentence."
        }
    }

    static var dictationShortcut: PushToTalkShortcut {
        PerryPreferences.pttShortcut
    }
}
