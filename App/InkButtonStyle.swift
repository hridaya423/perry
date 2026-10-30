import SwiftUI

struct InkButtonStyle: ButtonStyle {
    enum Tier {
        case primary, secondary, destructive
    }

    var tier = Tier.primary

    init(_ tier: Tier = .primary) {
        self.tier = tier
    }

    func makeBody(configuration: Configuration) -> some View {
        InkButton(configuration: configuration, tier: tier)
    }

    private struct InkButton: View {
        let configuration: ButtonStyleConfiguration
        let tier: Tier
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.controlSize) private var controlSize
        @State private var hovering = false

        var body: some View {
            let hero = controlSize >= .large
            let compact = controlSize <= .small
            configuration.label
                .font(.system(size: hero ? 15 : 13, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, hero ? 24 : compact ? 14 : 16)
                .padding(.vertical, hero ? 11 : compact ? 6 : 8)
                .foregroundStyle(configuration.role == .destructive && tier == .secondary ? PerryTheme.Colors.danger : foreground)
                .background(background, in: Capsule())
                .overlay {
                    if tier == .secondary {
                        Capsule().strokeBorder(PerryTheme.Colors.subtleSeparator, lineWidth: 1)
                    }
                }
                .overlay {
                    Capsule().fill(PerryTheme.Colors.veil(hovering && isEnabled && !configuration.isPressed ? 0.06 : 0))
                }
                .clipShape(Capsule())
                .contentShape(Capsule())
                .padding(2)
                .overlay {
                    if isFocused {
                        Capsule().strokeBorder(PerryTheme.Colors.accent, lineWidth: 2)
                    }
                }
                .padding(-2)
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : tier == .primary ? 1 : 0.45)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .onHover { hovering = $0 }
                .animation(PerryTheme.Motion.snap, value: configuration.isPressed)
                .animation(PerryTheme.Motion.snap, value: hovering)
        }

        private var foreground: Color {
            if !isEnabled && tier == .primary { return PerryTheme.Colors.textTertiary }
            return switch tier {
            case .primary: PerryTheme.Colors.onPrimaryAction
            case .secondary: PerryTheme.Colors.text
            case .destructive: PerryTheme.Colors.onPrimaryAction
            }
        }

        private var background: Color {
            if !isEnabled && tier == .primary { return PerryTheme.Colors.veil(0.08) }
            return switch tier {
            case .primary: PerryTheme.Colors.primaryAction
            case .secondary: PerryTheme.Colors.veil(0.06)
            case .destructive: PerryTheme.Colors.danger
            }
        }
    }
}

struct ControlFeedback<S: InsettableShape>: ViewModifier {
    let shape: S
    var hover = 0.06
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay { shape.fill(PerryTheme.Colors.veil(hovering && isEnabled ? hover : 0)) }
            .overlay { if isFocused { shape.strokeBorder(PerryTheme.Colors.accent, lineWidth: 2) } }
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(PerryTheme.Motion.snap, value: hovering)
    }
}

extension View {
    func controlFeedback<S: InsettableShape>(_ shape: S, hover: Double = 0.06) -> some View {
        modifier(ControlFeedback(shape: shape, hover: hover))
    }
}

struct InkChoiceStyle: ButtonStyle {
    var isDefault = false

    func makeBody(configuration: Configuration) -> some View {
        ChoiceRow(configuration: configuration, isDefault: isDefault)
    }

    private struct ChoiceRow: View {
        let configuration: ButtonStyleConfiguration
        let isDefault: Bool
        @Environment(\.isFocused) private var isFocused
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                configuration.label
                    .font(.body)
                    .foregroundStyle(PerryTheme.Colors.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isDefault {
                    ReturnHint()
                        .foregroundStyle(PerryTheme.Colors.text)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: PerryTheme.Radius.control, style: .continuous)
                    .fill(PerryTheme.Colors.veil(configuration.isPressed ? 0.12 : hovering ? 0.09 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PerryTheme.Radius.control, style: .continuous)
                    .strokeBorder(isFocused ? PerryTheme.Colors.accent : isDefault ? PerryTheme.Colors.accent.opacity(0.5) : PerryTheme.Colors.subtleSeparator, lineWidth: isFocused ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: PerryTheme.Radius.control, style: .continuous))
            .onHover { hovering = $0 }
            .animation(PerryTheme.Motion.snap, value: hovering)
        }
    }
}

struct InkSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    configuration.label
                }
                Spacer(minLength: 0)
                track(configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }

    private func track(_ isOn: Bool) -> some View {
        Capsule()
            .fill(isOn ? PerryTheme.Colors.accent : PerryTheme.Colors.veil(0.14))
            .frame(width: 32, height: 18)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(2)
            }
            .animation(reduceMotion ? nil : PerryTheme.Motion.glide, value: isOn)
    }
}

struct InkSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool

    private var fraction: Double {
        min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let knob = CGFloat(16)
            let travel = max(proxy.size.width - knob, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(PerryTheme.Colors.veil(0.14)).frame(height: 4)
                Capsule().fill(PerryTheme.Colors.accent).frame(width: knob / 2 + travel * fraction, height: 4)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .overlay { if focused { Circle().strokeBorder(PerryTheme.Colors.accent, lineWidth: 2).padding(-3) } }
                    .frame(width: knob, height: knob)
                    .offset(x: travel * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                focused = true
                set(range.lowerBound + Double((drag.location.x - knob / 2) / travel) * (range.upperBound - range.lowerBound))
            })
        }
        .frame(height: 20)
        .opacity(isEnabled ? 1 : 0.45)
        .focusable(isEnabled)
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .downArrow]) { _ in set(value - step); return .handled }
        .onKeyPress(keys: [.rightArrow, .upArrow]) { _ in set(value + step); return .handled }
        .onKeyPress(.home) { set(range.lowerBound); return .handled }
        .onKeyPress(.end) { set(range.upperBound); return .handled }
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: step) { Text(label) }
        }
    }

    private func set(_ raw: Double) {
        let steps = ((raw - range.lowerBound) / step).rounded()
        let snapped = ((range.lowerBound + steps * step) * 1000).rounded() / 1000
        let clamped = min(max(snapped, range.lowerBound), range.upperBound)
        if clamped != value { value = clamped }
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pressable(configuration: configuration)
    }

    private struct Pressable: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .frame(minWidth: PerryTheme.Icon.hit, minHeight: PerryTheme.Icon.hit)
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.6 : 1)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
        }
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}
