import AppKit
import Combine
import PerryBrain
import PerryCapture

@MainActor
final class OnboardingCoordinator {
    private let home: () -> HomeController
    private let showNotch: () -> Void
    private var beatObservation: AnyCancellable?
    private(set) var director: OnboardingDirector?

    init(home: @escaping () -> HomeController, showNotch: @escaping () -> Void) {
        self.home = home
        self.showNotch = showNotch
    }

    static func opensAtLaunch(completed: Bool, dismissed: Bool) -> Bool {
        !completed && !dismissed
    }

    nonisolated static var isParked: Bool {
        !PerryPreferences.onboardingCompleted && PerryPreferences.onboardingDismissed
    }

    func runIfNeeded() {
        if Self.opensAtLaunch(completed: PerryPreferences.onboardingCompleted, dismissed: PerryPreferences.onboardingDismissed) {
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

    private func start(effects overrides: OnboardingDirector.Effects, resume: Bool = true) {
        director?.stop()
        var effects = overrides
        effects.mark = { PerfMark.mark($0) }
        effects.grant = { pane in
            if pane == .microphone {
                if PerryPermissionProbe.checkMicrophone() == .denied {
                    pane.open()
                } else {
                    _ = await PerryPermissionProbe.requestMicrophone()
                }
            } else {
                await PermissionGuideCoordinator.guide(pane)
            }
        }
        effects.saveName = { [weak self] name in
            try? self?.home().homeModel.deps.controller?.memoryFiles?.setProfileField("Name", name)
        }
        effects.dismiss = { [weak self] in self?.tearDown() }
        effects.finish = { [weak self] keepNotchOpen in self?.finish(keepNotchOpen: keepNotchOpen) }
        let director = OnboardingDirector(effects: effects, defaults: .standard)
        self.director = director
        let home = home()
        home.homeModel.onboarding = director
        home.homeModel.sidebarSelection = nil
        beatObservation = director.$beat
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak director] beat in
                guard let self, let director, self.director === director, let beat else { return }
                self.showNotch()
            }
        director.start(resume: resume)
    }

    private func finish(keepNotchOpen: Bool) {
        let firstCompletion = !PerryPreferences.onboardingCompleted
        PerryPreferences.onboardingCompleted = true
#if !DEBUG
        if firstCompletion, PerryPreferences.openAtLogin { try? LoginItem.setEnabled(true) }
#else
        _ = firstCompletion
#endif
        tearDown(collapse: !keepNotchOpen)
    }

    private func tearDown(collapse: Bool = true) {
        beatObservation = nil
        director = nil
        let home = home()
        home.homeModel.onboarding = nil
        if collapse { home.homeModel.deps.controller?.collapseNotch() }
    }

#if DEBUG
    func runDenied() {
        var effects = OnboardingDirector.Effects()
        effects.permissionProbe = {
            PerryPermissionSnapshot(accessibility: false, screenRecording: .denied, microphone: .denied)
        }
        start(effects: effects)
    }
#endif
}
