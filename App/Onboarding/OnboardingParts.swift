import AppKit
import SwiftUI
import PerryOverlay

struct OnboardingBeatLayout<Art: View, Detail: View, Actions: View>: View {
    let title: String?
    var message: String?
    var artHeight: CGFloat = 84
    @ViewBuilder var art: Art
    @ViewBuilder var detail: Detail
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            art
                .frame(maxWidth: .infinity)
                .frame(height: artHeight)
            if let title {
                Text(title)
                    .font(PerryTheme.Scale.display)
                    .tracking(-0.4)
                    .foregroundStyle(PerryTheme.Colors.text)
                    .padding(.top, artHeight > 0 ? 14 : 0)
            }
            if let message {
                Text(message)
                    .font(PerryTheme.Scale.input)
                    .lineSpacing(3)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .frame(maxWidth: 400)
                    .padding(.top, title == nil ? 16 : 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            detail
                .frame(maxWidth: 420)
                .padding(.top, 12)
            Spacer(minLength: 8)
            actions
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OnboardingPrimaryLabel: View {
    let title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 14, weight: .semibold)) }
            Text(title)
            Image(systemName: "return")
                .font(.system(size: 11, weight: .semibold))
                .opacity(0.45)
                .accessibilityHidden(true)
        }
        .lineLimit(1)
        .fixedSize()
        .frame(minWidth: 132)
    }
}

struct OnboardingFooter<Leading: View, Primary: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var primary: Primary
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) { leading }
                .frame(width: 128, alignment: .trailing)
            primary
            HStack(spacing: 2) { trailing }
                .frame(width: 128, alignment: .leading)
        }
        .buttonStyle(OnboardingLinkStyle())
        .frame(height: 46)
        .padding(.bottom, 8)
    }
}

struct OnboardingLinkStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(hovering ? PerryTheme.Colors.text : PerryTheme.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct OnboardingProgress: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? PerryTheme.Colors.accent : PerryTheme.Colors.text.opacity(index < current ? 0.5 : 0.16))
                    .frame(width: index == current ? 18 : 6, height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

struct OnboardingRow<Leading: View, Trailing: View>: View {
    let title: String
    let detail: String
    var selected = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(PerryTheme.Colors.text)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(PerryTheme.Colors.surface.opacity(selected ? 1 : 0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? PerryTheme.Colors.accent.opacity(0.7) : PerryTheme.Colors.subtleSeparator, lineWidth: 1)
        }
    }
}

struct RowButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? PerryTheme.Colors.onPrimaryAction : PerryTheme.Colors.text)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(prominent ? PerryTheme.Colors.primaryAction : Color.white.opacity(0.08), in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct GrantedMark: View {
    var body: some View {
        Label("Allowed", systemImage: "checkmark")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(PerryTheme.Colors.accent)
            .labelStyle(.titleAndIcon)
    }
}

struct InkLine: View {
    let points: [CGPoint]
    var width: CGFloat = 2.4
    var seed: UInt64 = 1
    var progress: CGFloat = 1
    var color: Color = PerryTheme.Colors.text
    var smooth = true

    var body: some View {
        let samples = InkStroke.sampled(through: smooth ? Self.smoothed(points) : points, step: 1.5, jitter: 0, seed: seed)
        InkStrokeShape(samples: samples, widths: HelloInk.smoothed(InkStroke.widths(count: samples.count, baseWidth: width, seed: seed), radius: 6), progress: progress)
            .fill(color)
    }

    static func smoothed(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 8 else { return points }
        return points.indices.map { i in
            guard i > 0, i < points.count - 1 else { return points[i] }
            let window = points[max(i - 3, 0)...min(i + 3, points.count - 1)]
            return CGPoint(x: window.map(\.x).reduce(0, +) / CGFloat(window.count),
                           y: window.map(\.y).reduce(0, +) / CGFloat(window.count))
        }
    }
}

struct InkDrawOn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var delay: Double = 0
    @State private var progress: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.inkProgress, reduceMotion ? 1 : progress)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(PerryTheme.Motion.draw.delay(delay)) { progress = 1 }
            }
    }
}

extension EnvironmentValues {
    @Entry var inkProgress: CGFloat = 1
}

struct PermissionSketch: View {
    @Environment(\.inkProgress) private var progress
    let lit: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            InkLine(points: InkStroke.rectangle(in: CGRect(x: 30, y: 14, width: 210, height: 112)), width: 2.2, seed: 3, progress: progress)
            InkLine(points: [CGPoint(x: 31, y: 34), CGPoint(x: 140, y: 33.5), CGPoint(x: 239, y: 34)], width: 1.6, seed: 4, progress: progress, color: PerryTheme.Colors.text.opacity(0.5))
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .strokeBorder(PerryTheme.Colors.text.opacity(0.55), lineWidth: 1.4)
                    .frame(width: 7, height: 7)
                    .position(x: 44 + CGFloat(index) * 11, y: 24)
                    .opacity(Double(progress))
            }
            InkLine(points: [CGPoint(x: 48, y: 54), CGPoint(x: 130, y: 53)], width: 3, seed: 5, progress: progress, color: PerryTheme.Colors.text.opacity(0.35))
            InkLine(points: [CGPoint(x: 48, y: 68), CGPoint(x: 168, y: 67.5)], width: 3, seed: 6, progress: progress, color: PerryTheme.Colors.text.opacity(0.35))
            InkLine(points: [CGPoint(x: 48, y: 82), CGPoint(x: 110, y: 82.5)], width: 3, seed: 7, progress: progress, color: PerryTheme.Colors.text.opacity(0.35))
            Capsule()
                .strokeBorder(PerryTheme.Colors.text.opacity(0.8), lineWidth: 1.6)
                .frame(width: 46, height: 18)
                .position(x: 207, y: 106)
                .opacity(Double(progress))
            InkLine(points: InkStroke.ellipse(in: CGRect(x: 176, y: 90, width: 64, height: 34), seed: 9), width: 2.6, seed: 9,
                    progress: max(0, progress * 1.6 - 0.6), color: lit ? PerryTheme.Colors.accent : PerryTheme.Colors.accent.opacity(0.85))
            PerryCharacterView(pose: pointingPose, size: 40)
                .position(x: 236 - PerryBodyShape.tip.x * 40, y: 116 - PerryBodyShape.tip.y * 40)
        }
        .frame(width: 290, height: 140)
        .scaleEffect(0.86)
    }

    private var pointingPose: PerryCharacterPose {
        var pose = PerryCharacterPose()
        pose.face = lit ? .happy : .focused
        pose.gaze = CGVector(dx: -0.7, dy: -0.4)
        return pose
    }
}

struct SketchbookGrain: View {
    var body: some View {
        Canvas { context, size in
            var rng = SplitMix(seed: 7)
            let count = Int(size.width * size.height / 60)
            for _ in 0..<count {
                let x = CGFloat(rng.unit()) * size.width
                let y = CGFloat(rng.unit()) * size.height
                let alpha = 0.03 + 0.05 * rng.unit()
                context.fill(Path(CGRect(x: x, y: y, width: 0.8, height: 0.8)), with: .color(.white.opacity(alpha)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 }
    mutating func unit() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
