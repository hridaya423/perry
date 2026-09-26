import AppKit
import Foundation
import PerryCapture

/// First-run beat script (megaplan §4.1 / Phase 4): the cursor fades in and
/// Perry *does* the tutorial with you — hold ⌃⌥, grant permissions while
/// Guide points at the toggles, pick a brain, practice in a sandbox, tuck
/// into the notch. Every beat is skippable and keyboard-doable; denied mic
/// swaps to the keyboard variant so nothing dead-ends. All side effects are
/// injected so the script is unit-testable end to end.
@MainActor
final class OnboardingDirector {
    enum Beat: String, CaseIterable, Sendable {
        case greet
        case firstTalk
        case screenAccess
        case brainChoice
        case practice
        case finale
    }

    enum PracticeStep: String, CaseIterable, Sendable {
        case pointAsk
        case guide
        case renameUndo
        case dictate
    }

    struct Effects {
        var permissionProbe: () async -> PerryPermissionSnapshot = {
            await PerryPermissionSnapshot.probe()
        }
        var speak: (String) -> Void = { _ in }
        var openScreenAccessSettings: () -> Void = {}
        var beginPractice: () -> Void = {}
        var finish: () -> Void = {}
        var now: () -> Date = { Date() }
    }

    /// Posted so the overlay/UI layer can render the active beat without
    /// the director owning a window.
    var onBeatChanged: ((Beat, PracticeStep?) -> Void)?

    private(set) var beat: Beat?
    private(set) var practiceStep: PracticeStep?
    private(set) var micDenied = false
    private(set) var startedAt: Date?

    private let effects: Effects
    private var permissionTimer: Timer?

    init(effects: Effects = Effects()) {
        self.effects = effects
    }

    func start() {
        startedAt = effects.now()
        enter(.greet)
    }

    /// Any beat may be skipped — "Skip" key, Esc, or the composer path.
    func skip() {
        guard let current = beat else { return }
        switch current {
        case .practice:
            advancePracticeStep()
        default:
            advance()
        }
    }

    // MARK: Events from the app

    /// A Talk turn finished (voice or typed). On greet it opens the "ask
    /// about your screen" beat; on firstTalk it unlocks permissions; during
    /// practice it completes the pointAsk sub-step.
    func noteTalkTurnCompleted() {
        switch beat {
        case .greet:
            enter(.firstTalk)
        case .firstTalk:
            enter(.screenAccess)
        case .practice where practiceStep == .pointAsk:
            advancePracticeStep()
        default:
            break
        }
    }

    /// Mic permission was denied — the talk beat degrades to the keyboard
    /// variant instead of stalling.
    func noteMicrophoneDenied() {
        micDenied = true
        if beat == .firstTalk {
            effects.speak(Self.scriptNoMicTalk)
        }
    }

    /// A practice sub-beat finished inside the PracticeWindow.
    func notePracticeStepCompleted() {
        guard beat == .practice else { return }
        advancePracticeStep()
    }

    private func advancePracticeStep() {
        guard let step = practiceStep else { advance(); return }
        if let next = PracticeStep.allCases.drop(while: { $0 != step }).dropFirst().first {
            practiceStep = next
            effects.speak(Self.practiceScript(for: next))
            onBeatChanged?(.practice, next)
        } else {
            advance()
        }
    }

    /// Brain choice beat resolved (ChatGPT sign-in started, on-device, or
    /// BYOK) — always allowed to proceed.
    func noteBrainChoiceMade() {
        guard beat == .brainChoice else { return }
        advance()
    }

    // MARK: Transitions

    private func advance() {
        guard let current = beat else { return }
        let order = Beat.allCases
        guard let idx = order.firstIndex(of: current), idx + 1 < order.count else {
            beat = nil
            effects.finish()
            return
        }
        enter(order[idx + 1])
    }

    private func advance(to target: Beat) {
        enter(target)
    }

    private func enter(_ next: Beat) {
        beat = next
        practiceStep = next == .practice ? .pointAsk : nil
        switch next {
        case .greet:
            effects.speak(Self.scriptGreet)
        case .firstTalk:
            effects.speak(micDenied ? Self.scriptNoMicTalk : Self.scriptTalk)
        case .screenAccess:
            effects.speak(Self.scriptPermissions)
            effects.openScreenAccessSettings()
            startPermissionPolling()
        case .brainChoice:
            effects.speak(Self.scriptBrain)
        case .practice:
            effects.beginPractice()
            effects.speak(Self.practiceScript(for: .pointAsk))
        case .finale:
            effects.speak(Self.scriptFinale)
            // Let the tuck-away line land, then mark onboarding complete.
            Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.advance() }
            }
        }
        onBeatChanged?(next, practiceStep)
    }

    // MARK: Permission polling (§4.1.3 — grants detected live, no "Retry")

    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in
            Task { @MainActor in await self?.pollPermissions() }
        }
    }

    private func pollPermissions() async {
        let snapshot = await effects.permissionProbe()
        guard beat == .screenAccess else { return }
        if snapshot.requiredPermissionsGranted {
            permissionTimer?.invalidate()
            advance()
        }
    }

    func stop() {
        permissionTimer?.invalidate()
        beat = nil
    }

    // MARK: Script (kept here so beats, copy, and tests share one source)

    static let scriptGreet =
        "Hi, I'm Perry. Hold Control and Option and say hi."
    static let scriptTalk =
        "Now ask about something on your screen — point at it and say “what's this?”"
    static let scriptNoMicTalk =
        "No mic? No problem — double-tap Control and type what you'd ask."
    static let scriptPermissions =
        "To see your screen I need two permissions. I'll point at the switches."
    static let scriptBrain =
        "Want me to use your ChatGPT account? One click, no keys. Or skip — I'll use this Mac's on-device model."
    static let scriptFinale =
        "I live up here. Hover the notch any time."

    static func practiceScript(for step: PracticeStep) -> String {
        switch step {
        case .pointAsk:
            return "In this practice window, point at anything and ask “what's this?”"
        case .guide:
            return "Say “show me how to rename a file” and I'll walk you through it."
        case .renameUndo:
            return "Say “rename these three files” — watch me do it, then say “undo that.”"
        case .dictate:
            return "Hold the talk key in the text box and dictate a sentence."
        }
    }
}
