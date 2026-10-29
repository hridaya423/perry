import AppKit
import PerryGuide
import PerryOverlay

/// GuideSessionCoordinator and TalkSession see the app only through
/// GuideSessionOutput/GuideSessionContext; this bridge forwards those calls
/// to the extracted owners, so neither session needs the whole controller.
@MainActor
final class GuideSessionBridge: GuideSessionOutput, GuideSessionContext {
    private weak var host: AppController?

    private var guideOverlay: GuideOverlayPresenter? {
        host.map { GuideOverlayPresenter(overlayState: $0.overlayState) }
    }

    init(host: AppController) {
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
        PerfMark.mark("guide.step.shown")
        #if DEBUG
        GuideDrillRecorder.presented(presentation)
        #endif
    }

    func guideShowFullPath(_ viewPlan: EverythingViewPlan) {
        guideOverlay?.showFullPath(viewPlan)
    }

    func guideClearPresentation() {
        host?.clearSessionSurfaces()
        #if DEBUG
        GuideDrillRecorder.finished()
        #endif
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

extension AppController {
    var sessionPanelFrame: CGRect? { sessionPanel.frame }
    var intentCardFrame: CGRect? { intentCards.frame }

}

#if DEBUG
/// Phase-3 lab seam: when `PERRY_GUIDE_DRILL_STATE` points at a file, each
/// presented step's target rect (AX top-left space, same as CGEvent clicks)
/// and the session end are recorded there so scripts/lab/guide-drill.sh can
/// click the marked element and time click→next-mark without voice or a
/// model round-trip.
enum GuideDrillRecorder {
    static let enabled = !Set(ProcessInfo.processInfo.arguments).isDisjoint(with: ["--perry-guide-drill", "--perry-guide-live"])
    private static let statePath = ProcessInfo.processInfo.environment["PERRY_GUIDE_DRILL_STATE"]
        ?? NSTemporaryDirectory() + "perry-guide-drill-state.json"
    private static var sequence = 0

    static func presented(_ presentation: GuidePresentation) {
        guard enabled else { return }
        sequence += 1
        let target = presentation.target
        write([
            "seq": sequence,
            "instruction": presentation.step.instruction,
            "done": false,
            "hasTarget": target != nil,
            "targetLabel": target?.label ?? "",
            "targetRole": target?.role.rawValue ?? "",
            "x": target?.frame.x ?? 0,
            "y": target?.frame.y ?? 0,
            "w": target?.frame.width ?? 0,
            "h": target?.frame.height ?? 0,
            "targetID": target?.stableID ?? "",
            "postcondition": presentation.step.postcondition.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) } ?? ""
        ])
    }

    /// Drill-only: statuses describe planner/worker failures that would
    /// otherwise leave the run at done-with-zero-steps.
    static func status(_ status: String) {
        guard enabled else { return }
        sequence += 1
        write(["seq": sequence, "status": status])
    }

    static func finished() {
        guard enabled else { return }
        sequence += 1
        write(["seq": sequence, "instruction": "", "done": true])
    }

    /// Atomic "latest presentation" snapshot the drill polls, plus a JSONL
    /// history append so a run can reconstruct every presented step.
    private static func write(_ record: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        let stateURL = URL(fileURLWithPath: statePath)
        try? data.write(to: stateURL, options: .atomic)
        if let handle = FileHandle(forWritingAtPath: statePath + ".log")
            ?? (FileManager.default.createFile(atPath: statePath + ".log", contents: nil) ? FileHandle(forWritingAtPath: statePath + ".log") : nil) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.write(Data([0x0a]))
            try? handle.close()
        }
    }
}
#endif

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
