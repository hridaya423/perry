import Foundation
import CoreGraphics

public struct ClickAdvanceMatcher: Sendable {
    public let tolerance: Double

    public init(tolerance: Double = 8) {
        self.tolerance = tolerance
    }

    public enum Outcome: Equatable, Sendable {
        case hit(stableID: String)
        case miss
    }

    public func outcome(
        clickPoint: CGPointShim,
        target: GuideStep.Target?,
        elements: [AXElement]
    ) -> Outcome {
        guard case .axElement(let stableID)? = target,
              let element = elements.first(where: { $0.stableID == stableID }) else {
            return .miss
        }
        let frame = element.frame
        let padded = CGRect(
            x: frame.x - tolerance,
            y: frame.y - tolerance,
            width: frame.width + tolerance * 2,
            height: frame.height + tolerance * 2
        )
        let minHitSide: Double = 24
        let hitRect: CGRect
        if padded.width < minHitSide || padded.height < minHitSide {
            let centerX = frame.x + frame.width / 2
            let centerY = frame.y + frame.height / 2
            hitRect = CGRect(
                x: centerX - minHitSide / 2,
                y: centerY - minHitSide / 2,
                width: minHitSide,
                height: minHitSide
            )
        } else {
            hitRect = padded
        }
        return hitRect.contains(CGPoint(x: clickPoint.x, y: clickPoint.y))
            ? .hit(stableID: stableID)
            : .miss
    }
}
