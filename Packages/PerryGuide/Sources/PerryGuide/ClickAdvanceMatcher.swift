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

    /// The smallest actionable element under the point, skipping the intended
    /// target — used to say "that's the Effects tab" on a wrong click.
    public func elementUnder(
        clickPoint: CGPointShim, elements: [AXElement], excluding stableID: String?
    ) -> AXElement? {
        let point = CGPoint(x: clickPoint.x, y: clickPoint.y)
        return elements
            .filter { $0.stableID != stableID && $0.isActionable }
            .filter { e in
                CGRect(x: e.frame.x, y: e.frame.y, width: e.frame.width, height: e.frame.height)
                    .contains(point)
            }
            .min { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }
    }
}
