import AppKit
import SwiftUI

struct AgentTaskBubbleSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// Resolves a hex accent to a Color; blank or unparseable input falls
/// back to the product accent rather than failing silently.
func perryAccentColor(_ rawHex: String?) -> Color {
    guard let hex = rawHex?.trimmingCharacters(in: .whitespacesAndNewlines),
          !hex.isEmpty,
          let color = Color(optionalHex: hex) else {
        return PerryOverlayTheme.Colors.accent
    }
    return color
}

/// Estimated rendered size of a caption bubble, used to place it without
/// a measurement pass.
func estimatedCaptionBubbleSize(for caption: String) -> CGSize {
    let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return CGSize(width: 72, height: 28) }

    let averageGlyphWidth: CGFloat = 6.6
    let horizontalPadding: CGFloat = 18
    let maxWidth: CGFloat = 340
    let minWidth: CGFloat = 72
    let rawWidth = CGFloat(trimmed.count) * averageGlyphWidth + horizontalPadding
    let width = min(max(rawWidth, minWidth), maxWidth)
    let lineCount = max(1, Int(ceil(rawWidth / maxWidth)))
    let height = CGFloat(min(lineCount, 5)) * 15 + 10
    return CGSize(width: width, height: height)
}

func captionRect(size: CGSize, beside anchor: CGRect, avoiding: [CGRect], preferablyAvoiding: [CGRect] = [], screenFrame: CGRect) -> CGRect {
    let visible = NSScreen.screens.first { $0.frame == screenFrame }?.visibleFrame ?? screenFrame
    return CaptionPlacer.place(
        size: size, anchor: anchor, avoiding: avoiding, preferablyAvoiding: preferablyAvoiding,
        in: PerryOverlaySpace.localRect(visible, in: screenFrame)
    )
}

struct CaptionLayout {
    var stepLabel: CGRect?
    var markCaptions: [UUID: CGRect] = [:]
    var obstacles: [CGRect] = []
}

extension PerryCursorState {
    func localMarkRects(in screenFrame: CGRect) -> [CGRect] {
        (visualGuidanceOverlays.map(\.screenBounds) + [activeControlGlowRect].compactMap { $0 })
            .filter { !$0.isNull && $0.intersects(screenFrame) }
            .map { PerryOverlaySpace.localRect($0, in: screenFrame).insetBy(dx: -6, dy: -6) }
    }

    func captionLayout(in screenFrame: CGRect) -> CaptionLayout {
        let marks = localMarkRects(in: screenFrame)
        var layout = CaptionLayout()
        var placed: [CGRect] = []
        func place(_ caption: String?, beside screenRect: CGRect, controls: [CGRect] = []) -> CGRect? {
            guard let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty,
                  !screenRect.isNull, screenRect.intersects(screenFrame) else { return nil }
            let rect = captionRect(
                size: estimatedCaptionBubbleSize(for: caption),
                beside: PerryOverlaySpace.localRect(screenRect, in: screenFrame),
                avoiding: marks + placed,
                preferablyAvoiding: controls.map { PerryOverlaySpace.localRect($0, in: screenFrame) },
                screenFrame: screenFrame
            )
            placed.append(rect)
            return rect
        }
        if let glow = activeControlGlowRect {
            layout.stepLabel = place(activeControlGlowLabel, beside: glow)
        }
        for overlay in visualGuidanceOverlays {
            layout.markCaptions[overlay.id] = place(overlay.style.caption, beside: overlay.screenBounds, controls: overlay.nearbyControls ?? [])
        }
        layout.obstacles = marks + placed
        return layout
    }
}

/// The shared caption bubble: rounded surface, caption text, opacity
/// driven by the voice-caption-opacity preference.
struct PerryCaptionBubble: View {
    let caption: String
    let position: CGPoint
    @AppStorage(PerryBundleConfig.userVoiceResponseCaptionOpacityDefaultsKey)
    private var voiceResponseCaptionOpacity = PerryBundleConfig.defaultVoiceResponseCaptionOpacity

    private var normalizedOpacity: Double {
        min(max(voiceResponseCaptionOpacity, 0.55), 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(PerryOverlayTheme.Colors.captionText)
                .lineLimit(5)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(PerryOverlayTheme.Colors.captionSurface.opacity(normalizedOpacity))
                .shadow(color: PerryOverlayTheme.Colors.shadow.opacity(normalizedOpacity), radius: 8, x: 0, y: 2)
        )
        .frame(maxWidth: 340)
        .fixedSize(horizontal: false, vertical: true)
        .position(x: position.x, y: position.y)
        .transition(.opacity)
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

/// A caption bubble beside an anchor rect — a control, a ghost cursor —
/// kept off the anchor and the marks it must not cover.
struct PerryAnchoredCaption: View {
    let caption: String
    let anchor: CGRect
    let avoiding: [CGRect]
    let screenFrame: CGRect

    var body: some View {
        let placed = captionRect(
            size: estimatedCaptionBubbleSize(for: caption),
            beside: anchor, avoiding: avoiding, screenFrame: screenFrame
        )
        PerryCaptionBubble(caption: caption, position: CGPoint(x: placed.midX, y: placed.midY))
    }
}

/// The status bubble riding the pointer while a task or agent run is in
/// flight ("Working on …"), hidden while Perry is listening or thinking.
struct TaskBubbleLayer: View {
    @ObservedObject var state: PerryCursorState
    let screenFrame: CGRect
    /// Live pointer position in local coordinates — the bubble anchors to it.
    let anchor: CGPoint
    let isVisible: Bool
    let opacity: Double
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var bubbleSize: CGSize = .zero

    private var bubbleText: String? {
        let text = state.agentTaskBubbleText ?? state.taskBubbleText
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var body: some View {
        if isVisible,
           state.voiceState != .listening,
           state.voiceState != .processing,
           let bubbleText {
            let placed = captionRect(
                size: bubbleSize,
                beside: CGRect(x: anchor.x, y: anchor.y, width: 20, height: 24),
                avoiding: state.captionLayout(in: screenFrame).obstacles,
                screenFrame: screenFrame
            )

            Text(bubbleText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(PerryOverlayTheme.Colors.captionText)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(PerryOverlayTheme.Colors.captionSurface)
                        .shadow(color: PerryOverlayTheme.Colors.shadow, radius: 8, x: 0, y: 2)
                )
                .frame(maxWidth: 300)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: AgentTaskBubbleSizePreferenceKey.self, value: geo.size)
                    }
                )
                .position(x: placed.midX, y: placed.midY)
                .opacity(opacity)
                .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.16), value: bubbleText)
                .onPreferenceChange(AgentTaskBubbleSizePreferenceKey.self) { newSize in
                    bubbleSize = newSize
                }
        }
    }
}
