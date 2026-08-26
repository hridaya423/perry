import SwiftUI

/// Perry the platypus, drawn in code: flat geometric shapes, charcoal ink
/// outlines, one mint accent. Reads as a character at 32 pt, stays crisp at
/// any scale, and animates by pose parameters rather than frame swaps.
public struct PerrySpriteView: View {
    var animation: PerryBuddyAnimationState = .idle
    var size: CGFloat = 64

    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(animation: PerryBuddyAnimationState = .idle, size: CGFloat = 64) {
        self.animation = animation
        self.size = size
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, canvasSize in
                let s = min(canvasSize.width, canvasSize.height)
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                context.translateBy(x: center.x, y: center.y)

                let breathe = animation == .idle ? sin(t * 2.2) * s * 0.012 : 0
                let bounce = animation == .jumping ? abs(sin(t * 6)) * s * 0.10 : 0
                let runTilt = isRunning ? sin(t * 14) * 0.08 : 0
                let listenPulse = pulseAmount(t)

                context.translateBy(x: 0, y: -bounce + breathe)
                context.rotate(by: .radians(runTilt))

                drawTail(context, size: s)
                drawBody(context, size: s)
                drawBill(context, size: s)
                drawEye(context, size: s)
                drawFeet(context, size: s, t: t)
                if animation == .waving {
                    drawWavePaw(context, size: s, angle: sin(t * 9) * 0.5 - 0.3)
                }
                if listenPulse > 0 {
                    drawListenRings(context, size: s, amount: listenPulse)
                }
            }
            .frame(width: size, height: size)
            .scaleEffect(x: facesLeft ? -1 : 1)
        }
        .accessibilityLabel("Perry")
        .accessibilityHidden(true)
    }

    private var isRunning: Bool {
        switch animation {
        case .running, .runningRight, .runningLeft: return true
        default: return false
        }
    }

    /// Pets face their travel direction; the container flips the sprite
    /// horizontally for runningLeft instead of rotating it.
    private var facesLeft: Bool {
        animation == .runningLeft
    }

    private func pulseAmount(_ t: TimeInterval) -> CGFloat {
        guard case .waiting = animation else { return 0 }
        return max(0, sin(t * 3.4))
    }

    // MARK: parts (unit space: body spans roughly [-0.35, +0.35] of size)

    private let ink = Color(white: 0.16)
    private let accent = Color(red: 0.204, green: 0.827, blue: 0.600) // #34D399

    private func drawBody(_ context: GraphicsContext, size s: CGFloat) {
        let bodyRect = CGRect(x: -0.32 * s, y: -0.26 * s, width: 0.64 * s, height: 0.52 * s)
        let fill = Path(ellipseIn: bodyRect)
        context.fill(fill, with: .color(accent.opacity(0.92)))
        context.stroke(fill, with: .color(ink), lineWidth: 0.05 * s)
    }

    private func drawBill(_ context: GraphicsContext, size s: CGFloat) {
        let bill = Path { p in
            p.move(to: CGPoint(x: 0.24 * s, y: -0.10 * s))
            p.addQuadCurve(
                to: CGPoint(x: 0.46 * s, y: -0.02 * s),
                control: CGPoint(x: 0.40 * s, y: -0.16 * s)
            )
            p.addQuadCurve(
                to: CGPoint(x: 0.24 * s, y: 0.04 * s),
                control: CGPoint(x: 0.38 * s, y: 0.06 * s)
            )
            p.closeSubpath()
        }
        context.fill(bill, with: .color(ink))
    }

    private func drawEye(_ context: GraphicsContext, size s: CGFloat) {
        let eyeCenter = CGPoint(x: 0.10 * s, y: -0.10 * s)
        let eye = Path(ellipseIn: CGRect(x: eyeCenter.x - 0.045 * s, y: eyeCenter.y - 0.045 * s, width: 0.09 * s, height: 0.09 * s))
        context.fill(eye, with: .color(ink))
        let glint = Path(ellipseIn: CGRect(x: eyeCenter.x + 0.004 * s, y: eyeCenter.y - 0.032 * s, width: 0.022 * s, height: 0.022 * s))
        context.fill(glint, with: .color(.white))
    }

    private func drawTail(_ context: GraphicsContext, size s: CGFloat) {
        let tail = Path { p in
            p.move(to: CGPoint(x: -0.26 * s, y: 0.02 * s))
            p.addQuadCurve(
                to: CGPoint(x: -0.44 * s, y: 0.14 * s),
                control: CGPoint(x: -0.42 * s, y: -0.06 * s)
            )
            p.addQuadCurve(
                to: CGPoint(x: -0.22 * s, y: 0.16 * s),
                control: CGPoint(x: -0.34 * s, y: 0.20 * s)
            )
            p.closeSubpath()
        }
        context.fill(tail, with: .color(accent.opacity(0.75)))
        context.stroke(tail, with: .color(ink), lineWidth: 0.035 * s)
    }

    private func drawFeet(_ context: GraphicsContext, size s: CGFloat, t: TimeInterval) {
        let swing: CGFloat = isRunning ? sin(t * 14) * 0.03 * s : 0
        for (xOffset, yOffset) in [(-0.10, 0.24), (0.12, 0.25)] {
            let foot = Path(ellipseIn: CGRect(
                x: (CGFloat(xOffset) * s) - 0.07 * s + swing,
                y: (CGFloat(yOffset) * s) - 0.035 * s,
                width: 0.14 * s,
                height: 0.07 * s
            ))
            context.fill(foot, with: .color(ink.opacity(0.85)))
        }
    }

    private func drawWavePaw(_ context: GraphicsContext, size s: CGFloat, angle: CGFloat) {
        var context = context
        context.translateBy(x: -0.18 * s, y: 0.06 * s)
        context.rotate(by: .radians(Double(angle)))
        let paw = Path(ellipseIn: CGRect(x: -0.06 * s, y: -0.02 * s, width: 0.12 * s, height: 0.12 * s))
        context.fill(paw, with: .color(ink.opacity(0.85)))
    }

    private func drawListenRings(_ context: GraphicsContext, size s: CGFloat, amount: CGFloat) {
        for (radius, opacity) in [(0.34, 0.5), (0.42, 0.28)] {
            let ring = Path(ellipseIn: CGRect(
                x: -radius * s, y: -radius * s,
                width: radius * 2 * s, height: radius * 2 * s
            ))
            context.stroke(ring, with: .color(accent.opacity(Double(opacity * amount))), lineWidth: 0.03 * s)
        }
    }
}
