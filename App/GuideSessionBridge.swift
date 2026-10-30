import AppKit
import PerryGuide
import PerryOverlay

@MainActor
final class GuideSessionBridge: GuideSessionOutput, GuideSessionContext {
    private weak var host: AppController?

    init(host: AppController) {
        self.host = host
    }

    func guideShowOverlay() {
        guard let host, !host.overlayManager.isShowingOverlay() else { return }
        host.overlayManager.showOverlay(onScreens: NSScreen.screens, state: host.overlayState)
    }

    func guideStopSpatialInput() {
        host?.spatial.stopMonitoring()
    }

    func guideSetStatus(_ status: String) {
        host?.sessionStatus = status
        #if DEBUG
        GuideDrillRecorder.status(status)
        #endif
    }

    func guideReportFailure(_ message: String, recovery: FailureRecovery?) {
        guideSetStatus(message)
        host?.presentFailure(message, recovery: recovery)
    }

    func guideClearFailure() {
        host?.clearFailure()
    }

    func guideSpeak(_ text: String, identity: GuideSpeechIdentity) {
        host?.voice.deliverVoiceReply(text)
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
        [host?.sessionPanel.frame, host?.intentCards.frame].compactMap { $0 }
    }

    func guidePresent(_ presentation: GuidePresentation) {
        host?.overlayState.presentGuide(presentation)
        PerfMark.mark("guide.step.shown")
        #if DEBUG
        GuideDrillRecorder.presented(presentation)
        #endif
    }

    func guideShowFullPath(_ viewPlan: EverythingViewPlan) {
        host?.overlayState.showGuideFullPath(viewPlan)
    }

    func guideClearPresentation() {
        host?.clearSessionSurfaces()
        #if DEBUG
        GuideDrillRecorder.finished()
        #endif
    }

    func guideClearFullPath() {
        host?.overlayState.clearGuideFullPath()
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

    func ask(question: String) {
        guard !maintenance.isUnderMaintenance else { return }
        talkSession.submitComposer(question: question)
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
