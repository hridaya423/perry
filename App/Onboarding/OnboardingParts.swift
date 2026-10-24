import AppKit
import SwiftUI
import PerryOverlay

enum OnboardingStyle {
    static let artHeight: CGFloat = 120
    static let title = Font.system(size: 26, weight: .semibold)
    static let body = Font.system(size: 14)
    static let carbon = Color(red: 0.094, green: 0.098, blue: 0.106)
    static let hairline = Color.white.opacity(0.09)
    static let enter = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.5)
    static let draw = Animation.timingCurve(0.65, 0, 0.35, 1, duration: 0.9)
}

struct OnboardingBeatLayout<Art: View, Detail: View, Actions: View>: View {
    let title: String?
    var message: String?
    var artHeight = OnboardingStyle.artHeight
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
                    .font(OnboardingStyle.title)
                    .tracking(-0.4)
                    .foregroundStyle(PerryTheme.Colors.text)
                    .padding(.top, 14)
            }
            if let message {
                Text(message)
                    .font(OnboardingStyle.body)
                    .lineSpacing(3)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .frame(maxWidth: 400)
                    .padding(.top, title == nil ? 16 : 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            detail
                .frame(maxWidth: 420)
                .padding(.top, 16)
            Spacer(minLength: 12)
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
        .background(OnboardingStyle.carbon.opacity(selected ? 1 : 0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? PerryTheme.Colors.accent.opacity(0.7) : OnboardingStyle.hairline, lineWidth: 1)
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
                withAnimation(OnboardingStyle.draw.delay(delay)) { progress = 1 }
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

final class ModifierWatcher: ObservableObject {
    @Published private(set) var held: Set<String> = []
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        update(NSEvent.modifierFlags)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(event.modifierFlags)
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func update(_ flags: NSEvent.ModifierFlags) {
        var keys: Set<String> = []
        if flags.contains(.control) { keys.insert("⌃") }
        if flags.contains(.option) { keys.insert("⌥") }
        if flags.contains(.command) { keys.insert("⌘") }
        held = keys
    }
}

struct LargeKeycap: View {
    let symbol: String
    var lit = false

    var body: some View {
        Text(symbol)
            .font(.system(size: 17, weight: .medium, design: .rounded))
            .foregroundStyle(lit ? PerryTheme.Colors.onAccent : PerryTheme.Colors.text)
            .frame(width: 38, height: 38)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(lit ? PerryTheme.Colors.accent : PerryTheme.Colors.surface)
                    .shadow(color: .black.opacity(0.7), radius: 0, y: lit ? 0 : 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(lit ? .clear : PerryTheme.Colors.subtleSeparator, lineWidth: 1)
            }
            .offset(y: lit ? 1.5 : 0)
            .animation(.easeOut(duration: 0.1), value: lit)
    }
}

struct LargeShortcut: View {
    let keys: [String]
    var lit: Set<String> = []
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    LargeKeycap(symbol: key, lit: lit.contains(key))
                }
            }
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(PerryTheme.Colors.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(keys.joined()), \(label)")
    }
}

struct ChoiceSketch: View {
    @Environment(\.inkProgress) private var progress
    let local: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            InkLine(points: InkStroke.rectangle(in: CGRect(x: 26, y: 30, width: 70, height: 48)), width: 2, seed: 41, progress: progress, color: tint(local))
            InkLine(points: [CGPoint(x: 18, y: 84), CGPoint(x: 104, y: 84), CGPoint(x: 114, y: 92), CGPoint(x: 8, y: 92), CGPoint(x: 18, y: 84)], width: 2, seed: 42, progress: progress, color: tint(local))
            InkLine(points: Self.cloud, width: 2.2, seed: 43, progress: progress, color: tint(!local), smooth: false)
            PerryCharacterView(pose: pose, size: 46)
                .position(x: 152, y: 66)
        }
        .frame(width: 300, height: 110)
        .animation(.easeOut(duration: 0.2), value: local)
    }

    static let cloud: [CGPoint] = {
        let bumps: [(CGPoint, CGFloat, Double, Double)] = [
            (CGPoint(x: 213, y: 68), 11, .pi * 0.6, .pi * 1.6),
            (CGPoint(x: 237, y: 57), 17, .pi * 1.1, .pi * 1.92),
            (CGPoint(x: 262, y: 66), 13, .pi * 1.3, .pi * 2.4)
        ]
        var points = [CGPoint(x: 203, y: 80)]
        for (center, radius, from, to) in bumps {
            for step in 0...6 {
                let angle = from + (to - from) * Double(step) / 6
                points.append(CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
            }
        }
        points.append(CGPoint(x: 278, y: 80))
        points.append(CGPoint(x: 203, y: 80.5))
        return points
    }()

    private func tint(_ on: Bool) -> Color {
        on ? PerryTheme.Colors.accent : PerryTheme.Colors.text.opacity(0.35)
    }

    private var pose: PerryCharacterPose {
        var pose = PerryCharacterPose()
        pose.gaze = CGVector(dx: local ? -0.9 : 0.9, dy: -0.1)
        return pose
    }
}

struct PracticeWindowSketch: View {
    @Environment(\.inkProgress) private var progress
    let step: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            InkLine(points: InkStroke.rectangle(in: CGRect(x: 40, y: 6, width: 220, height: 108)), width: 2, seed: 51, progress: progress)
            InkLine(points: [CGPoint(x: 41, y: 24), CGPoint(x: 259, y: 24)], width: 1.4, seed: 52, progress: progress, color: PerryTheme.Colors.text.opacity(0.45))
            InkLine(points: [CGPoint(x: 150, y: 25), CGPoint(x: 150.5, y: 113)], width: 1.4, seed: 53, progress: progress, color: PerryTheme.Colors.text.opacity(0.45))
            ForEach(0..<3, id: \.self) { row in
                let y = 42 + CGFloat(row) * 22
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(PerryTheme.Colors.text.opacity(0.6), lineWidth: 1.3)
                    .frame(width: 9, height: 12)
                    .position(x: 60, y: y)
                InkLine(points: [CGPoint(x: 72, y: y), CGPoint(x: 72 + CGFloat(54 - row * 10), y: y + 0.5)], width: 2.6, seed: UInt64(54 + row), progress: progress,
                        color: PerryTheme.Colors.text.opacity(step == 2 ? 0.75 : 0.35))
            }
            InkLine(points: [CGPoint(x: 164, y: 42), CGPoint(x: 236, y: 42.5)], width: 2.6, seed: 58, progress: progress, color: PerryTheme.Colors.text.opacity(step == 3 ? 0.75 : 0.3))
            InkLine(points: [CGPoint(x: 164, y: 56), CGPoint(x: 214, y: 56)], width: 2.6, seed: 59, progress: progress, color: PerryTheme.Colors.text.opacity(step == 3 ? 0.75 : 0.3))
            InkLine(points: InkStroke.ellipse(in: ring, seed: 60), width: 2.4, seed: 60, progress: max(0, progress * 1.6 - 0.6), color: PerryTheme.Colors.accent)
                .id(step)
            PerryCharacterView(pose: PerryCharacterPose(), size: 36)
                .position(x: ring.maxX - 6 - PerryBodyShape.tip.x * 36, y: ring.maxY - 4 - PerryBodyShape.tip.y * 36)
                .animation(OnboardingStyle.enter, value: step)
        }
        .frame(width: 300, height: 120)
    }

    private var ring: CGRect {
        switch step {
        case 0: CGRect(x: 48, y: 30, width: 92, height: 24)
        case 1: CGRect(x: 48, y: 52, width: 92, height: 24)
        case 2: CGRect(x: 46, y: 30, width: 100, height: 70)
        default: CGRect(x: 156, y: 32, width: 92, height: 34)
        }
    }
}

struct StepGrid: View {
    let current: Int
    let started: Bool
    static let labels = ["Point and ask", "Follow a guide", "Rename, then undo", "Dictate a note"]

    var body: some View {
        Grid(horizontalSpacing: 28, verticalSpacing: 10) {
            GridRow { cell(0); cell(1) }
            GridRow { cell(2); cell(3) }
        }
        .accessibilityElement(children: .combine)
    }

    private func cell(_ index: Int) -> some View {
        let done = index < current
        let active = started && index == current
        return HStack(spacing: 8) {
            ZStack {
                Circle()
                    .strokeBorder(done ? PerryTheme.Colors.accent : PerryTheme.Colors.text.opacity(active ? 0.9 : 0.3), lineWidth: 1.4)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(PerryTheme.Colors.accent)
                } else {
                    Text("\(index + 1)").font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(PerryTheme.Colors.text.opacity(active ? 1 : 0.5))
                }
            }
            .frame(width: 20, height: 20)
            Text(Self.labels[index])
                .font(.system(size: 13, weight: active ? .medium : .regular))
                .foregroundStyle(active || done ? PerryTheme.Colors.text : PerryTheme.Colors.textSecondary)
        }
        .frame(width: 170, alignment: .leading)
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

struct FinaleCard: View {
    struct Item: Hashable {
        let text: String
        let on: Bool
    }

    let name: String?
    let items: [Item]
    let since: Date
    var leaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name.map { "\($0)’s Perry" } ?? "Your Perry")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(PerryTheme.Colors.text)
                    Text("Since \(since.formatted(.dateTime.month(.wide).day().year()))")
                        .font(.system(size: 12))
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                }
                Spacer()
                PerryCharacterView(pose: mascotPose, size: 40)
                    .frame(width: 40, height: 40)
                    .offset(y: leaving ? -300 : 0)
                    .opacity(leaving ? 0 : 1)
            }
            Rectangle().fill(OnboardingStyle.hairline).frame(height: 1).padding(.vertical, 12)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.on ? "checkmark" : "gearshape")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(item.on ? PerryTheme.Colors.accent : PerryTheme.Colors.textSecondary)
                            .frame(width: 14)
                        Text(item.text)
                            .font(.system(size: 13))
                            .foregroundStyle(item.on ? PerryTheme.Colors.text : PerryTheme.Colors.textSecondary)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 330)
        .background(OnboardingStyle.carbon, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(OnboardingStyle.hairline) }
        .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
        .multilineTextAlignment(.leading)
    }

    private var mascotPose: PerryCharacterPose {
        var pose = PerryCharacterPose()
        pose.face = .happy
        pose.gaze = leaving ? CGVector(dx: 0, dy: -1) : CGVector(dx: -0.4, dy: 0.2)
        pose.stretch = leaving ? 1.3 : 1
        return pose
    }
}
