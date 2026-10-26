import AppKit
import Combine
import PerryCapture
import PerryOverlay

/// Runs first-run onboarding inside the expanded notch: owns the director and
/// the practice window, and connects the director's effects to permissions,
/// the notch, Talk, and the brain.
@MainActor
final class OnboardingCoordinator {
    private let overlayState: PerryCursorState
    private let home: () -> HomeController
    private let talkSession: () -> TalkSession
    private let preferOnDeviceBrain: () -> Void
    private let showNotch: () -> Void
    private let endTalk: () -> Void
    private lazy var practiceWindow = PracticeWindow()
    private var beatObservation: AnyCancellable?
    private(set) var director: OnboardingDirector?

    init(
        overlayState: PerryCursorState,
        home: @escaping () -> HomeController,
        talkSession: @escaping () -> TalkSession,
        preferOnDeviceBrain: @escaping () -> Void,
        showNotch: @escaping () -> Void,
        endTalk: @escaping () -> Void
    ) {
        self.overlayState = overlayState
        self.home = home
        self.talkSession = talkSession
        self.preferOnDeviceBrain = preferOnDeviceBrain
        self.showNotch = showNotch
        self.endTalk = endTalk
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
        effects.showHint = { [weak self] line in
            self?.overlayState.taskBubbleText = line
        }
        effects.mark = { PerfMark.mark($0) }
        effects.endTalk = { [weak self] in self?.endTalk() }
        effects.openScreenAccessSettings = {
            _ = PerryPermissionProbe.requestAccessibility()
            PrivacyPane.accessibility.open()
        }
        effects.openScreenRecordingSettings = {
            _ = PerryPermissionProbe.requestScreenRecording()
            PrivacyPane.screenRecording.open()
        }
        effects.beginPractice = { [weak self] in
            guard let self else { return }
            self.practiceWindow.show(below: self.overlayState.panelScreenFrame)
        }
        effects.endPractice = { [weak self] in self?.practiceWindow.close() }
        effects.preferOnDeviceBrain = { [weak self] in self?.preferOnDeviceBrain() }
        effects.finish = { [weak self] in self?.finish() }
        let director = OnboardingDirector(effects: effects, defaults: .standard)
        self.director = director
        let home = home()
        home.homeModel.onboarding = director
        home.homeModel.sidebarSelection = nil
        beatObservation = director.$beat
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak director] beat in
                guard let self, let director, self.director === director, beat != nil else { return }
                self.showNotch()
            }
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
        let firstCompletion = !PerryPreferences.onboardingCompleted
        PerryPreferences.onboardingCompleted = true
#if !DEBUG
        if firstCompletion { try? LoginItem.setEnabled(true) }
#else
        _ = firstCompletion
#endif
        beatObservation = nil
        director = nil
        let home = home()
        home.homeModel.onboarding = nil
        home.homeModel.deps.controller?.collapseNotch()
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
