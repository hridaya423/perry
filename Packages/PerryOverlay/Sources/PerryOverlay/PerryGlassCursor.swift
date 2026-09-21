import SwiftUI

/// The two pointer candidates compared in the Phase-2 debug gallery.
/// Faceted is the preferred shape: an arrow silhouette in glass stays legible
/// on light, dark, and busy content and reads as "pointer" at a glance.
public enum PerryGlassCursorVariant: String, CaseIterable, Equatable, Sendable {
    case faceted
    case lens
}

/// Perry's pointer: a translucent glass shape that rides at the cursor offset
/// instead of a mascot. State is shown through tint, a ring treatment, and
/// small motion — never pointer theft or screen-space grab. Decorative only;
/// every state also has a text label on the status surfaces.
public struct PerryGlassCursorView: View {
    var animation: PerryBuddyAnimationState = .idle
    var size: CGFloat = 52
    var variant: PerryGlassCursorVariant = .faceted

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(animation: PerryBuddyAnimationState = .idle, size: CGFloat = 52, variant: PerryGlassCursorVariant = .faceted) {
        self.animation = animation
        self.size = size
        self.variant = variant
    }

    public var body: some View {
        if animates && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                content(t: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            content(t: 0)
        }
    }

    /// Static states (idle, speak tint, failure) never spin the timeline —
    /// an idle cursor must not cost a 30 fps ticker per mounted instance.
    private var animates: Bool {
        switch animation {
        case .waiting, .review, .running, .runningRight, .runningLeft, .jumping:
            return true
        case .idle, .waving, .failed:
            return false
        }
    }

    @ViewBuilder
    private func content(t: TimeInterval) -> some View {
        ZStack {
            silhouette
                .fill(.ultraThinMaterial)
            silhouette
                .stroke(PerryOverlayTheme.Colors.ink.opacity(0.85), lineWidth: size * 0.028)
            if variant == .faceted {
                FacetLinesShape()
                    .stroke(Color.white.opacity(0.55), lineWidth: size * 0.014)
                    .clipShape(FacetedPointerShape())
            }
            stateOverlay(t)
        }
        .frame(width: size, height: size)
        .scaleEffect(x: facesLeft ? -1 : 1)
        .rotationEffect(.radians(tilt(t)))
        .offset(y: bob(t))
        .accessibilityHidden(true)
    }

    private var silhouette: AnyShape {
        switch variant {
        case .faceted: return AnyShape(FacetedPointerShape())
        case .lens: return AnyShape(LensPointerShape())
        }
    }

    private var facesLeft: Bool {
        animation == .runningLeft
    }

    private var tint: Color {
        switch animation {
        case .failed: return PerryOverlayTheme.Colors.selection
        default: return PerryOverlayTheme.Colors.accent
        }
    }

    @ViewBuilder
    private func stateOverlay(_ t: TimeInterval) -> some View {
        switch animation {
        case .waiting:
            silhouette.stroke(tint.opacity(0.35 + 0.45 * max(0, sin(t * 3.4))), lineWidth: size * 0.03)
        case .review:
            Circle()
                .stroke(style: StrokeStyle(lineWidth: size * 0.02, dash: [size * 0.07, size * 0.05]))
                .foregroundStyle(tint.opacity(0.7))
                .padding(size * 0.13)
                .rotationEffect(.degrees(t * 120))
        case .running, .runningRight, .runningLeft, .waving:
            silhouette.stroke(tint, lineWidth: size * 0.022)
        case .jumping:
            silhouette.stroke(tint, lineWidth: size * 0.03)
        case .failed:
            silhouette.stroke(tint, lineWidth: size * 0.03)
        case .idle:
            EmptyView()
        }
    }

    private func tilt(_ t: TimeInterval) -> Double {
        switch animation {
        case .running, .runningRight, .runningLeft: return sin(t * 14) * 0.06
        default: return 0
        }
    }

    private func bob(_ t: TimeInterval) -> CGFloat {
        switch animation {
        case .idle: return sin(t * 2.2) * size * 0.012
        case .jumping: return -abs(sin(t * 6)) * size * 0.06
        default: return 0
        }
    }
}

/// Classic arrow cursor silhouette, tip at top-left, in a unit box scaled to
/// the view's shortest side.
struct FacetedPointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + x * s, y: rect.midY + y * s)
        }
        return Path { p in
            p.move(to: pt(-0.24, -0.36))
            p.addLine(to: pt(-0.24, 0.30))
            p.addLine(to: pt(-0.09, 0.17))
            p.addLine(to: pt(0.03, 0.40))
            p.addLine(to: pt(0.15, 0.34))
            p.addLine(to: pt(0.03, 0.11))
            p.addLine(to: pt(0.24, 0.11))
            p.closeSubpath()
        }
    }
}

/// Cut lines that make the arrow read as faceted glass rather than flat fill.
struct FacetLinesShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + x * s, y: rect.midY + y * s)
        }
        return Path { p in
            p.move(to: pt(-0.24, -0.08))
            p.addLine(to: pt(0.08, 0.11))
            p.move(to: pt(-0.24, 0.12))
            p.addLine(to: pt(-0.04, 0.23))
            p.move(to: pt(-0.01, 0.18))
            p.addLine(to: pt(0.09, 0.36))
        }
    }
}

/// Loupe-style pointer: a glass lens with a short tail toward bottom-right.
struct LensPointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX - 0.08 * s, y: rect.midY - 0.10 * s)
        let r = 0.27 * s
        var p = Path()
        p.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        let a = CGPoint(x: center.x + r * 0.30, y: center.y + r * 0.95)
        let b = CGPoint(x: center.x + r * 0.95, y: center.y + r * 0.30)
        let tip = CGPoint(x: center.x + r + 0.15 * s, y: center.y + r + 0.15 * s)
        p.move(to: a)
        p.addLine(to: tip)
        p.addLine(to: b)
        p.closeSubpath()
        return p
    }
}
