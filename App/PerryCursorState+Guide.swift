import AppKit
import PerryGuide
import PerryOverlay

extension AXCoordinateConverter {
    @MainActor
    static func appKitPoint(of point: CGPointShim) -> CGPoint {
        appKitPoint(axX: point.x, axY: point.y, primaryScreenMaxY: primaryScreenMaxY, elementHeight: 0)
    }

    @MainActor
    static func appKitRect(of frame: AXElementFrame) -> CGRect {
        appKitRect(axX: frame.x, axY: frame.y, width: frame.width, height: frame.height, primaryScreenMaxY: primaryScreenMaxY)
    }

    @MainActor
    private static var primaryScreenMaxY: Double {
        Double(NSScreen.screens.first?.frame.maxY ?? 0)
    }
}

@MainActor
extension PerryCursorState {
    func presentGuide(_ presentation: GuidePresentation) {
        guard let target = presentation.target else {
            clearGuideHighlight()
            return
        }
        let frame = AXCoordinateConverter.appKitRect(of: target.frame)
        detectedElementScreenLocation = CGPoint(x: frame.midX, y: frame.midY)
        detectedElementDisplayFrame = frame
        activeControlGlowRect = frame.insetBy(dx: -6, dy: -6)
        activeControlGlowLabel = target.label ?? presentation.step.instruction
    }

    func showGuideFullPath(_ viewPlan: EverythingViewPlan) {
        visualGuidanceOverlays.append(contentsOf: viewPlan.markers.map { marker in
            PerryGuidanceOverlay.pointMark(
                center: AXCoordinateConverter.appKitPoint(of: marker.position),
                accentHex: "#9CCBB6",
                caption: "\(marker.number). \(marker.caption)",
                duration: 20
            )
        })
    }

    func clearGuideHighlight() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        activeControlGlowRect = nil
        activeControlGlowLabel = nil
    }

    func clearGuideFullPath() {
        visualGuidanceOverlays = []
    }

    func clearGuideOverlays() {
        voiceState = .idle
        taskBubbleText = nil
        agentTaskBubbleText = nil
        clearGuideHighlight()
        circleSelectSnappedRect = nil
        circleSelectSnapLabel = nil
        clearGuideFullPath()
    }
}
