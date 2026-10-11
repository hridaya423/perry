import AppKit
import PerryGuide
import PerryOverlay

/// Draws Guide on the overlay: the current step's target highlight and the
/// numbered full-path markers, and clears them.
@MainActor
struct GuideOverlayPresenter {
    let overlayState: PerryCursorState

    func present(_ presentation: GuidePresentation) {
        guard let target = presentation.target else {
            clearHighlight()
            return
        }
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = AXCoordinateConverter.appKitRect(
            axX: target.frame.x,
            axY: target.frame.y,
            width: target.frame.width,
            height: target.frame.height,
            primaryScreenMaxY: primaryMaxY
        )
        overlayState.detectedElementScreenLocation = CGPoint(x: frame.midX, y: frame.midY)
        overlayState.detectedElementDisplayFrame = frame
        overlayState.detectedElementBubbleText = presentation.step.instruction
        overlayState.activeControlGlowRect = frame.insetBy(dx: -6, dy: -6)
        overlayState.activeControlGlowLabel = target.label ?? presentation.step.instruction
    }

    func showFullPath(_ viewPlan: EverythingViewPlan) {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let overlays = viewPlan.markers.map { marker in
            let point = AXCoordinateConverter.appKitPoint(
                axX: marker.position.x,
                axY: marker.position.y,
                primaryScreenMaxY: primaryMaxY,
                elementHeight: 24
            )
            return PerryGuidanceOverlay.scribble(
                points: [point, point],
                accentHex: "#34D399",
                lineWidth: 6,
                caption: "\(marker.number). \(marker.caption)",
                duration: 20
            )
        }
        overlayState.visualGuidanceOverlays.append(contentsOf: overlays)
    }

    func clearHighlight() {
        overlayState.detectedElementScreenLocation = nil
        overlayState.detectedElementDisplayFrame = nil
        overlayState.detectedElementBubbleText = nil
        overlayState.activeControlGlowRect = nil
        overlayState.activeControlGlowLabel = nil
    }

    func clearFullPath() {
        overlayState.visualGuidanceOverlays = []
    }

    /// Everything Guide or a session left on the overlay.
    func clearAll() {
        overlayState.voiceState = .idle
        overlayState.taskBubbleText = nil
        overlayState.agentTaskBubbleText = nil
        clearHighlight()
        overlayState.circleSelectSnappedRect = nil
        overlayState.circleSelectSnapLabel = nil
        clearFullPath()
    }
}
