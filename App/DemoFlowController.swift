import Foundation

/// What the live demo needs from the app: the sessions it cancels and
/// replays through, the probe/runtimes preflight, and the surfaces it
/// reports on. Implemented by AppController.
@MainActor
protocol DemoFlowHost: AnyObject {
    var voice: VoiceController { get }
    var spatial: SpatialSelectionController { get }
    var guideCoordinator: GuideSessionCoordinator { get }
    var foreground: ForegroundTaskController { get }
    var talkSession: TalkSession { get }
    var probe: EnvironmentProbe { get }
    var runtimes: RuntimeCatalog { get }
    var sessionState: SessionState { get }
    func wakeForDemo()
    func dismissIntentCard()
    var sessionStatus: String { get set }
    func runOnboardingForDemo()
    func showDemoReport()
}

/// The scripted live demo's app-facing half: preflights the machine,
/// cancels anything pending, and hands DemoDirector the hooks it drives.
/// The director owns the script; this owns what the script touches.
@MainActor
final class DemoFlowController {
    private weak var host: (any DemoFlowHost)?
    let director: DemoDirector

    init(host: any DemoFlowHost) {
        self.host = host
        director = DemoDirector(hooks: DemoDirector.Hooks(
            preflight: { [weak host] in
                guard let host else {
                    return DemoPreflightResult(ready: false, failureMessage: "Perry could not run the live demo.")
                }
                return await Self.preflight(host: host)
            },
            wake: { [weak host] in host?.wakeForDemo() },
            speak: { [weak host] text in host?.voice.speak(text) },
            waitForSpatialSelection: { [weak host] in await host?.spatial.waitForSelection() },
            cancelPendingInputs: { [weak host] in host.map(Self.cancelPendingInputs) },
            describeSpatialSelection: { [weak host] selection in await host?.spatial.describe(selection) ?? false },
            runGuide: { [weak host] goal in await host?.guideCoordinator.runGuideForDemo(goal: goal) ?? false },
            runDo: { [weak host] goal in await host?.foreground.runForDemo(goal: goal) },
            report: { [weak host] _ in host?.showDemoReport() }
        ))
    }

    var verifiedSummary: String? { director.lastVerifiedResult }

    /// The flagship (⌘D / labs) run refuses to interrupt a live session;
    /// the menu path starts unconditionally through `director`.
    func run(completion: ((Bool) -> Void)? = nil) {
        guard let host else {
            completion?(false)
            return
        }
        guard case .idle = host.sessionState else {
            host.voice.speak("Finish the current session before starting the live demo.")
            completion?(false)
            return
        }
        director.run(completion: completion)
    }

    private static func preflight(host: any DemoFlowHost) async -> DemoPreflightResult {
        let permissions = await host.probe.permissionSnapshot()
        guard permissions.requiredPermissionsGranted else {
            host.runOnboardingForDemo()
            return DemoPreflightResult(
                ready: false,
                failureMessage: "I can’t run the live demo until Accessibility and Screen Recording are granted in System Settings."
            )
        }
        let cuaHealth = await host.probe.cuaHealth()
        guard cuaHealth.ready else {
            return DemoPreflightResult(ready: false, failureMessage: cuaHealth.summary)
        }
        do {
            let inventory = try await host.runtimes.inspect()
            if !inventory.hasReadyCLI {
                host.sessionStatus = "Using Perry's private local planner for the supported demo task."
            }
            return .ready
        } catch is CancellationError {
            return DemoPreflightResult(ready: false, failureMessage: "Runtime inspection was canceled.")
        } catch {
            return DemoPreflightResult(ready: false, failureMessage: "Perry could not inspect the available runtimes. Refresh runtime setup and try again.")
        }
    }

    private static func cancelPendingInputs(host: any DemoFlowHost) {
        host.talkSession.cancelAsk()
        if case .invoking(let invocation) = host.sessionState {
            host.foreground.cancelInvocationIfCurrent(invocation.id)
        }
        host.spatial.releaseWaiter()
        host.guideCoordinator.cancelPendingDemoInputs()
        host.dismissIntentCard()
        Task { await host.foreground.cancelActiveSupervisor() }
    }
}

extension AppController: DemoFlowHost {
    func wakeForDemo() { wake() }
    func dismissIntentCard() { intentCards.dismiss() }
    func runOnboardingForDemo() { runOnboarding(force: true) }
    func showDemoReport() { showHistory() }
}

extension AppController {
    /// Verified result text from the last completed live demo — onboarding
    /// ends on this evidence rather than a generic "you're set".
    var demoVerifiedSummary: String? { demoFlow.verifiedSummary }

    func runFlagshipDemo(completion: ((Bool) -> Void)? = nil) {
        demoFlow.run(completion: completion)
    }
}
