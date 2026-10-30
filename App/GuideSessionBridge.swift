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
        guard let host, !host.subsystems.overlayManager.isShowingOverlay() else { return }
        host.subsystems.overlayManager.showOverlay(onScreens: NSScreen.screens, state: host.subsystems.overlayState)
    }

    func guideStopSpatialInput() {
        host?.subsystems.spatial.stopMonitoring()
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
        host?.subsystems.voice.deliverVoiceReply(text)
    }

    func guideIsSpeaking() -> Bool {
        host?.subsystems.voice.isSpeaking ?? false
    }

    func guidePlay(_ cue: SoundPlayer.Cue) {
        SoundPlayer.play(cue)
    }

    func guideSetBuddyState(_ state: PerryBuddyState) {
        host?.subsystems.overlayState.buddyState = state
    }

    func guideInteractiveFrames() -> [CGRect] {
        [host?.sessionPanel.frame, host?.intentCards.frame].compactMap { $0 }
    }

    func guidePresent(_ presentation: GuidePresentation) {
        host?.subsystems.overlayState.presentGuide(presentation)
        PerfMark.mark("guide.step.shown")
        #if DEBUG
        GuideDrillRecorder.presented(presentation)
        #endif
    }

    func guideShowFullPath(_ viewPlan: EverythingViewPlan) {
        host?.subsystems.overlayState.showGuideFullPath(viewPlan)
    }

    func guideClearPresentation() {
        host?.clearSessionSurfaces()
        #if DEBUG
        GuideDrillRecorder.finished()
        #endif
    }

    func guideClearFullPath() {
        host?.subsystems.overlayState.clearGuideFullPath()
    }

    func guideRequestTakeOver(_ handoff: GuideHandoff) {
        host?.subsystems.foreground.start(
            goal: "Continue the guided task: \(handoff.goal). Check the current window and finish the remaining work without repeating completed changes.",
            threadID: handoff.threadID, targetHint: handoff.target
        )
    }

    func guideTargetHint() -> CuaTargetHint {
        host?.subsystems.probe.currentTargetHint() ?? CuaTargetHint()
    }

    func guideAppBundleID(for targetHint: CuaTargetHint) -> String? {
        targetHint.processID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
            ?? host?.subsystems.spatial.selection?.window?.appBundleID
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func guideSpatialRegionDescription() -> String? {
        host?.subsystems.spatial.selection?.description
    }
}

extension AppController {
    func guideConversationID() -> UUID {
        if case .thread(let id) = subsystems.homeController.homeModel.sidebarSelection,
           !subsystems.agentCoordinator.runningThreads.contains(id) { return id }
        let id = UUID()
        subsystems.homeController.homeModel.sidebarSelection = .thread(id)
        return id
    }

    func startGuiding(goal: String) {
        let threadID = guideConversationID()
        subsystems.guideCoordinator.startGuiding(
            goal: goal, threadID: threadID,
            targetHint: subsystems.homeController.homeModel.conversationTargets[threadID]
        )
    }

    func ask(question: String) {
        guard !maintenance.isUnderMaintenance else { return }
        subsystems.talkSession.submitComposer(question: question)
    }

    func showEverything(goal: String, targetHint: CuaTargetHint? = nil) async {
        let threadID = guideConversationID()
        if let targetHint { subsystems.homeController.homeModel.conversationTargets[threadID] = targetHint }
        await subsystems.guideCoordinator.showEverything(
            goal: goal, threadID: threadID,
            targetHint: subsystems.homeController.homeModel.conversationTargets[threadID]
        )
    }
}
