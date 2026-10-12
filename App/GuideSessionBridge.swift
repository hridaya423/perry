import AppKit
import PerryGuide
import PerryOverlay

/// What a guide or ask session reaches for beyond its own state — the
/// overlay, cursor state, spatial selection, voice, the environment probe,
/// and the foreground runner. Implemented by AppController; the member list
/// is a session's documented surface area into the app.
@MainActor
protocol GuideBridgeHost: AnyObject {
    var overlayManager: OverlayWindowManager { get }
    var overlayState: PerryCursorState { get }
    var spatial: SpatialSelectionController { get }
    var voice: VoiceController { get }
    var probe: EnvironmentProbe { get }
    var foreground: ForegroundTaskController { get }
    var sessionPanelFrame: CGRect? { get }
    var intentCardFrame: CGRect? { get }
    var sessionStatus: String { get set }
    func clearSessionSurfaces()
}

/// GuideSessionCoordinator and TalkSession see the app only through
/// GuideSessionOutput/GuideSessionContext; this bridge forwards those calls
/// to the extracted owners, so neither session needs the whole controller.
@MainActor
final class GuideSessionBridge: GuideSessionOutput, GuideSessionContext {
    private weak var host: (any GuideBridgeHost)?

    private var guideOverlay: GuideOverlayPresenter? {
        host.map { GuideOverlayPresenter(overlayState: $0.overlayState) }
    }

    init(host: any GuideBridgeHost) {
        self.host = host
    }

    func guideShowOverlay() {
        guard let host else { return }
        if !host.overlayManager.isShowingOverlay() {
            host.overlayManager.showOverlay(onScreens: NSScreen.screens, state: host.overlayState)
        }
    }

    func guideStopSpatialInput() {
        host?.spatial.stopMonitoring()
    }

    func guideSetStatus(_ status: String) {
        host?.sessionStatus = status
    }

    func guideSpeak(_ text: String, identity: GuideSpeechIdentity) {
        host?.voice.deliverVoiceReply(text, guideSpeechIdentity: identity)
    }

    func guideIsSpeaking() -> Bool {
        host?.voice.isSpeaking ?? false
    }

    func guidePlay(_ cue: SoundPlayer.Cue) {
        SoundPlayer.play(cue)
    }

    func guideSetBuddyState(_ state: PerryBuddyState) {
        host?.overlayState.buddyState = state
    }

    func guideInteractiveFrames() -> [CGRect] {
        [host?.sessionPanelFrame, host?.intentCardFrame].compactMap { $0 }
    }

    func guidePresent(_ presentation: GuidePresentation) {
        guideOverlay?.present(presentation)
    }

    func guideShowFullPath(_ viewPlan: EverythingViewPlan) {
        guideOverlay?.showFullPath(viewPlan)
    }

    func guideClearPresentation() {
        host?.clearSessionSurfaces()
    }

    func guideClearHighlight() {
        guideOverlay?.clearHighlight()
    }

    func guideClearFullPath() {
        guideOverlay?.clearFullPath()
    }

    func guideRequestTakeOver(_ handoff: GuideHandoff) {
        host?.foreground.start(
            goal: "Continue the guided task: \(handoff.goal). Check the current window and finish the remaining work without repeating completed changes.",
            threadID: handoff.threadID, targetHint: handoff.target
        )
    }

    func guideTargetHint() -> CuaTargetHint {
        host?.probe.currentTargetHint() ?? CuaTargetHint()
    }

    func guideAppBundleID(for targetHint: CuaTargetHint) -> String? {
        targetHint.processID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
            ?? host?.spatial.selection?.window?.appBundleID
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func guideSpatialRegionDescription() -> String? {
        host?.spatial.selection?.description
    }
}

extension AppController: GuideBridgeHost {
    var sessionPanelFrame: CGRect? { sessionPanel.frame }
    var intentCardFrame: CGRect? { intentCards.frame }

}

extension AppController {
    func guideConversationID() -> UUID {
        if case .thread(let id) = homeController.homeModel.sidebarSelection,
           !agentCoordinator.runningThreads.contains(id) { return id }
        let id = UUID()
        homeController.homeModel.sidebarSelection = .thread(id)
        return id
    }

    func startGuiding(goal: String) {
        let threadID = guideConversationID()
        guideCoordinator.startGuiding(
            goal: goal, threadID: threadID,
            targetHint: homeController.homeModel.conversationTargets[threadID]
        )
    }
}

extension AppController {
    func ask(question: String) {
        guard !maintenance.isUnderMaintenance else { return }
        talkSession.submitComposer(question: question)
    }

    func advanceGuide() {
        guideCoordinator.advanceGuide()
    }

    func showEverything(goal: String, targetHint: CuaTargetHint? = nil) async {
        let threadID = guideConversationID()
        if let targetHint { homeController.homeModel.conversationTargets[threadID] = targetHint }
        await guideCoordinator.showEverything(
            goal: goal, threadID: threadID,
            targetHint: homeController.homeModel.conversationTargets[threadID]
        )
    }
}
