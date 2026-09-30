import SwiftUI

/// The two pointer candidates compared in the Phase-2 debug gallery.
/// Faceted is the preferred shape: an arrow silhouette in glass stays legible
/// on light, dark, and busy content and reads as "pointer" at a glance.
public enum PerryGlassCursorVariant: String, CaseIterable, Equatable, Sendable {
    case faceted
    case lens
}

/// The §5 morph grammar: one glass shape that transitions between pointer,
/// listening ring, thinking orbit, pen, caption bubble, ghost, settle tick,
/// and amber hold. Opt-in — when `morph` is nil the legacy `animation` state
/// drives the overlay exactly as before.
public enum PerryCursorMorph: String, Equatable, Sendable, CaseIterable {
    case pointer
    case listening
    case thinking
    case pen
    case caption
    case ghost
    case settle
    case blocked

    /// Legacy mapping so existing animation-driven call sites can adopt
    /// morphs incrementally.
    public init(animation: PerryBuddyAnimationState) {
        switch animation {
        case .idle: self = .pointer
        case .waiting: self = .listening
        case .review: self = .thinking
        case .running, .runningRight, .runningLeft: self = .ghost
        case .waving: self = .pointer
        case .jumping: self = .settle
        case .failed: self = .blocked
        }
    }
}

/// Perry's pointer: a translucent glass shape that rides at the cursor offset
/// instead of a mascot. State is shown through tint, a ring treatment, and
/// small motion — never pointer theft or screen-space grab. Decorative only;
/// every state also has a text label on the status surfaces.
public struct PerryGlassCursorView: View {
    var animation: PerryBuddyAnimationState = .idle
    var size: CGFloat = 52
    var variant: PerryGlassCursorVariant = .faceted
    /// §5 morph state; nil keeps the legacy animation-driven overlay.
    var morph: PerryCursorMorph?
    /// Mic RMS 0–1 driving the listening ring radius.
    var micLevel: CGFloat = 0
    /// The pointer breathes (4 s edge light) only while a session is live;
    /// fully static when idle per §5.
    var sessionActive = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        animation: PerryBuddyAnimationState = .idle,
        size: CGFloat = 52,
        variant: PerryGlassCursorVariant = .faceted,
        morph: PerryCursorMorph? = nil,
        micLevel: CGFloat = 0,
        sessionActive: Bool = false
    ) {
        self.animation = animation
        self.size = size
        self.variant = variant
        self.morph = morph
        self.micLevel = micLevel
        self.sessionActive = sessionActive
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
        if let morph {
            switch morph {
            case .thinking: return true
            case .pointer: return sessionActive
            case .listening, .pen, .caption, .ghost, .settle, .blocked: return false
            }
        }
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
            if let morph {
                morphContent(morph, t: t)
            } else {
                legacyContent(t: t)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(x: facesLeft ? -1 : 1)
        .rotationEffect(.radians(tilt(t)))
        .offset(y: bob(t))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func legacyContent(t: TimeInterval) -> some View {
        silhouette
            .fill(.ultraThinMaterial)
        silhouette
            .stroke(accent.opacity(0.85), lineWidth: size * 0.028)
        if variant == .faceted {
            FacetLinesShape()
                .stroke(Color.white.opacity(0.55), lineWidth: size * 0.014)
                .clipShape(FacetedPointerShape())
        }
        stateOverlay(t)
    }

    private var accent: Color { PerryOverlayTheme.Colors.accent }

    /// §5 morph rendering: same silhouette grammar, state carried by edge
    /// light, ring, orbit, or an alternate silhouette — never a spinner.
    @ViewBuilder
    private func morphContent(_ morph: PerryCursorMorph, t: TimeInterval) -> some View {
        switch morph {
        case .pointer:
            silhouette.fill(.ultraThinMaterial)
            silhouette.stroke(PerryOverlayTheme.Colors.ink.opacity(0.85), lineWidth: size * 0.028)
            if variant == .faceted {
                FacetLinesShape()
                    .stroke(Color.white.opacity(0.55), lineWidth: size * 0.014)
                    .clipShape(FacetedPointerShape())
            }
            if sessionActive {
                // 4 s breathing edge light; static when idle.
                silhouette.stroke(
                    accent.opacity(0.30 + 0.35 * (0.5 + 0.5 * sin(t * .pi / 2))),
                    lineWidth: size * 0.02
                )
            }
        case .listening:
            silhouette.fill(.ultraThinMaterial)
            silhouette.stroke(PerryOverlayTheme.Colors.ink.opacity(0.85), lineWidth: size * 0.028)
            // Ring radius follows mic RMS (fed at 30 Hz from the audio tap).
            let level = min(max(micLevel, 0), 1)
            Circle()
                .stroke(accent.opacity(0.55), lineWidth: size * 0.022)
                .padding(-size * (0.06 + 0.14 * level))
        case .thinking:
            silhouette.fill(.ultraThinMaterial)
            silhouette.stroke(PerryOverlayTheme.Colors.ink.opacity(0.85), lineWidth: size * 0.028)
            // One orbit per 1.2 s — a traveling edge light, no spinner.
            let angle = t * (.pi * 2 / 1.2)
            let radius = size * 0.46
            Circle()
                .fill(accent)
                .frame(width: size * 0.10, height: size * 0.10)
                .offset(x: cos(angle) * radius, y: sin(angle) * radius)
        case .pen:
            PenNibShape().fill(.ultraThinMaterial)
            PenNibShape().stroke(PerryOverlayTheme.Colors.ink.opacity(0.85), lineWidth: size * 0.028)
            PenNibShape().stroke(accent.opacity(0.7), lineWidth: size * 0.018)
        case .caption:
            CaptionBubbleShape().fill(.ultraThinMaterial)
            CaptionBubbleShape().stroke(PerryOverlayTheme.Colors.ink.opacity(0.8), lineWidth: size * 0.024)
            CaptionBubbleShape().stroke(accent.opacity(0.6), lineWidth: size * 0.014)
        case .ghost:
            // Agent/rehearsal pointer: dashed outline only, never filled —
            // reads as "Perry's, not yours" and never covers the target.
            silhouette.stroke(
                accent.opacity(0.9),
                style: StrokeStyle(lineWidth: size * 0.028, dash: [size * 0.08, size * 0.05])
            )
        case .settle:
            silhouette.fill(.ultraThinMaterial)
            silhouette.stroke(PerryOverlayTheme.Colors.ink.opacity(0.85), lineWidth: size * 0.028)
            SettleTickShape()
                .stroke(accent, style: StrokeStyle(lineWidth: size * 0.05, lineCap: .round, lineJoin: .round))
                .padding(size * 0.28)
        case .blocked:
            // Amber hold: static, readable at a glance, no motion.
            silhouette.fill(.ultraThinMaterial)
            silhouette.stroke(PerryOverlayTheme.Colors.ink.opacity(0.85), lineWidth: size * 0.028)
            silhouette.stroke(PerryOverlayTheme.Colors.amber.opacity(0.9), lineWidth: size * 0.04)
        }
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

/// Pen morph (§5): a nib, tip down-left where the ink comes out.
struct PenNibShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + x * s, y: rect.midY + y * s)
        }
        return Path { p in
            p.move(to: pt(-0.30, 0.34))          // tip
            p.addQuadCurve(to: pt(-0.10, -0.28), control: pt(-0.34, -0.10))
            p.addQuadCurve(to: pt(0.30, -0.10), control: pt(0.12, -0.42))
            p.addQuadCurve(to: pt(-0.30, 0.34), control: pt(0.14, 0.24))
            p.closeSubpath()
            // slit down to the tip
            p.move(to: pt(-0.30, 0.34))
            p.addLine(to: pt(-0.02, -0.06))
        }
    }
}

/// Caption morph (§5): a rounded bubble with a tail anchoring down-left
/// toward the element the caption describes.
struct CaptionBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let w = s * 0.62
        let h = s * 0.42
        let bubble = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2 - s * 0.06, width: w, height: h)
        return Path { p in
            p.addRoundedRect(in: bubble, cornerSize: CGSize(width: h * 0.5, height: h * 0.5))
            p.move(to: CGPoint(x: bubble.minX + w * 0.22, y: bubble.maxY - 1))
            p.addLine(to: CGPoint(x: bubble.minX + w * 0.10, y: bubble.maxY + s * 0.16))
            p.addLine(to: CGPoint(x: bubble.minX + w * 0.40, y: bubble.maxY - 1))
            p.closeSubpath()
        }
    }
}

/// Settle morph (§5): a small tick inside the pointer on done.
struct SettleTickShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.midY + rect.height * 0.02))
            p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.maxY - rect.height * 0.22))
            p.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.minY + rect.height * 0.16))
        }
    }
}
