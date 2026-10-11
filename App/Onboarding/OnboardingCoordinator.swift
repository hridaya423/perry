import AppKit
import PerryCapture
import PerryOverlay

/// Runs first-run onboarding: owns the director and the practice window, and
/// connects the director's effects to permissions, Home, Talk, and the brain.
@MainActor
final class OnboardingCoordinator {
    private let overlayState: PerryCursorState
    private let makeSpeech: () -> any TalkSpeechOutput
    private let home: () -> HomeController
    private let talkSession: () -> TalkSession
    private let preferOnDeviceBrain: () -> Void
    private lazy var speech = makeSpeech()
    private lazy var practiceWindow = PracticeWindow()
    private(set) var director: OnboardingDirector?

    init(
        overlayState: PerryCursorState,
        makeSpeech: @escaping () -> any TalkSpeechOutput,
        home: @escaping () -> HomeController,
        talkSession: @escaping () -> TalkSession,
        preferOnDeviceBrain: @escaping () -> Void
    ) {
        self.overlayState = overlayState
        self.makeSpeech = makeSpeech
        self.home = home
        self.talkSession = talkSession
        self.preferOnDeviceBrain = preferOnDeviceBrain
    }

    func runIfNeeded() {
        if !PerryPreferences.onboardingCompleted {
            run(force: false)
        }
    }

    func run(force: Bool) {
        if director != nil && !force { return }
        start(effects: OnboardingDirector.Effects(), resume: !force)
    }

    func noteTalkTurnCompleted() {
        director?.noteTalkTurnCompleted()
    }

    /// A finished Guide run completes the practice beat's guide sub-step.
    func noteSessionTransition(from previous: SessionState, to next: SessionState) {
        guard let director,
              director.beat == .practice,
              director.practiceStep == .guide,
              case .guiding = previous,
              case .reporting(let report) = next, report.outcome == .completed else { return }
        director.notePracticeStepCompleted()
    }

    private func start(effects overrides: OnboardingDirector.Effects, resume: Bool = true) {
        director?.stop()
        var effects = overrides
        effects.speak = { [weak self] line in
            self?.overlayState.taskBubbleText = line
            self?.speech.speak(line)
        }
        effects.requestScreenAccess = {
            _ = PerryPermissionProbe.requestAccessibility()
            _ = PerryPermissionProbe.requestScreenRecording()
        }
        effects.openScreenAccessSettings = {
            _ = PerryPermissionProbe.requestAccessibility()
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ) {
                NSWorkspace.shared.open(url)
            }
        }
        effects.openScreenRecordingSettings = {
            _ = PerryPermissionProbe.requestScreenRecording()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        effects.beginPractice = { [weak self] in self?.practiceWindow.show() }
        effects.endPractice = { [weak self] in self?.practiceWindow.close() }
        effects.preferOnDeviceBrain = { [weak self] in self?.preferOnDeviceBrain() }
        effects.finish = { [weak self] in self?.finish() }
        let director = OnboardingDirector(effects: effects, defaults: .standard)
        self.director = director
        let home = home()
        home.homeModel.onboarding = director
        home.homeModel.sidebarSelection = nil
        home.openHome()
        talkSession().onTurnCompleted = { [weak director] in
            director?.noteTalkTurnCompleted()
        }
        practiceWindow.onEvent = { [weak director] event in
            switch (event, director?.practiceStep) {
            case (.renamedAndUndone, .renameUndo), (.dictated, .dictate):
                director?.notePracticeStepCompleted()
            default: break
            }
        }
        practiceWindow.onClose = { [weak director] in
            director?.notePracticeWindowClosed()
        }
        if PerryPermissionProbe.checkMicrophone() == .denied {
            director.noteMicrophoneDenied()
        }
        director.start(resume: resume)
    }

    private func finish() {
        practiceWindow.close()
        overlayState.taskBubbleText = nil
        talkSession().onTurnCompleted = nil
        PerryPreferences.onboardingCompleted = true
        director = nil
        home().homeModel.onboarding = nil
    }

#if DEBUG
    func runDenied() {
        var effects = OnboardingDirector.Effects()
        effects.permissionProbe = {
            PerryPermissionSnapshot(
                accessibility: false,
                screenRecording: .denied,
                microphone: .denied
            )
        }
        start(effects: effects)
    }
#endif
}
