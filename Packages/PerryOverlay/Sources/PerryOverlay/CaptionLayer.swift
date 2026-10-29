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

/// Positions a bubble beside `anchor`, flipping it to the other side when
/// the default side would leave `screenFrame` and clamping inside it.
func anchoredBubblePosition(
    anchor: CGPoint,
    bubbleSize: CGSize,
    screenFrame: CGRect,
    horizontalOffset: CGFloat,
    verticalOffset: CGFloat
) -> CGPoint {
    let halfWidth = bubbleSize.width / 2
    let halfHeight = bubbleSize.height / 2
    let minMargin: CGFloat = 8

    var x = anchor.x + horizontalOffset + halfWidth
    let maxX = screenFrame.width - halfWidth - minMargin
    let minX = halfWidth + minMargin

    if x > maxX {
        x = anchor.x - horizontalOffset - halfWidth
    }
    x = min(max(x, minX), maxX)

    var y = anchor.y + verticalOffset + halfHeight
    let maxY = screenFrame.height - halfHeight - minMargin
    let minY = halfHeight + minMargin
    y = min(max(y, minY), maxY)

    return CGPoint(x: x, y: y)
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
        .frame(maxWidth: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .position(x: position.x, y: position.y)
        .transition(.opacity)
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

/// A caption bubble anchored next to a point — a pointer, a ghost cursor,
/// or a rect edge — flipped inside the screen when the default side clips.
struct PerryAnchoredCaption: View {
    let caption: String
    let anchor: CGPoint
    let screenFrame: CGRect

    var body: some View {
        PerryCaptionBubble(
            caption: caption,
            position: anchoredBubblePosition(
                anchor: anchor,
                bubbleSize: estimatedCaptionBubbleSize(for: caption),
                screenFrame: screenFrame,
                horizontalOffset: 12,
                verticalOffset: 20
            )
        )
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
            let bubblePosition = anchoredBubblePosition(
                anchor: anchor,
                bubbleSize: bubbleSize,
                screenFrame: screenFrame,
                horizontalOffset: 12,
                verticalOffset: 20
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
                .frame(maxWidth: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: AgentTaskBubbleSizePreferenceKey.self, value: geo.size)
                    }
                )
                .position(x: bubblePosition.x, y: bubblePosition.y)
                .opacity(opacity)
                .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.16), value: bubbleText)
                .onPreferenceChange(AgentTaskBubbleSizePreferenceKey.self) { newSize in
                    bubbleSize = newSize
                }
        }
    }
}
