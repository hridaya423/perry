import AppKit
import PerryBrain
import PerryCapture
import PerryCore
import PerryGuide
import PerryOverlay
import PerryRuntimes

@MainActor
struct GuideSpeechIdentity: Equatable {
    let guideID: UUID
    let scopeID: UUID
    let stepID: UUID?
    let text: String
}

struct GuideHandoff {
    let threadID: UUID
    let goal: String
    let target: CuaTargetHint
}

@MainActor
protocol GuideSessionOutput: AnyObject {
    func guideShowOverlay()
    func guideStopSpatialInput()
    func guideSetStatus(_ status: String)
    func guideSpeak(_ text: String, identity: GuideSpeechIdentity)
    func guidePlay(_ cue: SoundPlayer.Cue)
    func guidePresent(_ presentation: GuidePresentation)
    func guideSetBuddyState(_ state: PerryBuddyState)
    func guideInteractiveFrames() -> [CGRect]
    func guideShowFullPath(_ viewPlan: EverythingViewPlan)
    func guideClearPresentation()
    func guideClearFullPath()
    func guideRequestTakeOver(_ handoff: GuideHandoff)
    func guideIsSpeaking() -> Bool
    func guideReportFailure(_ message: String, recovery: FailureRecovery?)
    func guideClearFailure()
}

extension GuideSessionOutput {
    func guideRequestTakeOver(_ handoff: GuideHandoff) {}
    func guideIsSpeaking() -> Bool { false }
    func guideReportFailure(_ message: String, recovery: FailureRecovery?) { guideSetStatus(message) }
    func guideClearFailure() {}
}

@MainActor
protocol GuideSessionContext: AnyObject {
    func guideTargetHint() -> CuaTargetHint
    func guideAppBundleID(for targetHint: CuaTargetHint) -> String?
    func guideSpatialRegionDescription() -> String?
}
