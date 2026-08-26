import SwiftUI

public extension Color {
    /// Failable initializer for dynamic hex values (model output, external
    /// cursor state). Returns nil on parse failure so callers can fall back
    /// to their intended color rather than silently getting black.
    init?(optionalHex hex: String) {
        let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard sanitized.count == 6 || sanitized.count == 3,
              sanitized.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        let normalized = sanitized.count == 3
            ? sanitized.map { String(repeating: $0, count: 2) }.joined()
            : sanitized
        var rgbValue: UInt64 = 0
        guard Scanner(string: normalized).scanHexInt64(&rgbValue) else { return nil }

        self.init(
            red: Double((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: Double((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgbValue & 0x0000FF) / 255.0
        )
    }

    init?(optionalHex hex: String?) {
        guard let hex else { return nil }
        self.init(optionalHex: hex)
    }
}

public enum PerryBuddyAnimationState: Equatable {
    case idle
    case waiting
    case runningRight
    case runningLeft
    case running
    case waving
    case jumping
    case failed
    case review
}

public enum PerryVoicePhase: Equatable {
    case idle
    case listening
    case processing
    case responding
}

public final class PerryCursorState: ObservableObject {
    @Published public var animation: PerryBuddyAnimationState = .idle
    @Published public var taskBubbleText: String?
    @Published public var voiceState: PerryVoicePhase = .idle
    @Published public var currentAudioPowerLevel: CGFloat = 0
    @Published public var detectedElementScreenLocation: CGPoint?
    @Published public var detectedElementDisplayFrame: CGRect?
    @Published public var detectedElementBubbleText: String?
    @Published public var detectedElementReturnsImmediately: Bool = false
    @Published public var agentTaskBubbleText: String?
    @Published public var externalPrimaryCaptionText: String?
    @Published public var externalPrimaryCaptionAccentHex: String?
    @Published public var externalSecondaryCursors: [PerryExternalCursor] = []
    @Published public var visualGuidanceOverlays: [PerryGuidanceOverlay] = []
    @Published public var circleSelectLivePoints: [CGPoint] = []
    @Published public var circleSelectSnappedRect: CGRect?
    @Published public var circleSelectSnapLabel: String?
    @Published public var activeControlGlowRect: CGRect?
    @Published public var activeControlGlowLabel: String?

    public init() {}

    public func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
        detectedElementReturnsImmediately = false
    }
}

public struct PerryExternalCursor: Identifiable, Equatable {
    public let id: UUID
    public var screenLocation: CGPoint
    public var caption: String?
    public var accentHex: String?

    public init(id: UUID = UUID(), screenLocation: CGPoint, caption: String?, accentHex: String?) {
        self.id = id
        self.screenLocation = screenLocation
        self.caption = caption
        self.accentHex = accentHex
    }
}

public enum PerryWindowLevels {
    private static let interactiveCeiling = CGWindowLevelForKey(.draggingWindow)

    public static let statusSurface = NSWindow.Level(rawValue: Int(interactiveCeiling) - 1)
    public static let cursorOverlay = statusSurface
    public static let mainPanel = NSWindow.Level(rawValue: Int(interactiveCeiling) - 3)
    public static let panelDialog = NSWindow.Level(rawValue: Int(interactiveCeiling) - 2)

    public static func applyCursorOverlayLevel(to window: NSWindow?) {
        window?.level = cursorOverlay
    }

    public static func applyMainPanelLevel(to window: NSWindow?) {
        window?.level = mainPanel
    }

    public static func applyPanelDialogLevel(to window: NSWindow?) {
        window?.level = panelDialog
    }
}

public enum PerryAccentTheme: String, CaseIterable {
    case mint
    case amber
    case sky

    public var accentColor: Color {
        switch self {
        case .mint: return Color(red: 0.20, green: 0.86, blue: 0.60)
        case .amber: return Color(red: 1.00, green: 0.72, blue: 0.25)
        case .sky: return Color(red: 0.30, green: 0.68, blue: 1.00)
        }
    }

    public var cursorColor: Color { accentColor }

    public static let userDefaultsKey = "perry.accentTheme"
    public static let mintRawValue = PerryAccentTheme.mint.rawValue

    public static func from(optionalHex hex: String?) -> PerryAccentTheme {
        guard let hex else { return .mint }
        return PerryAccentTheme(rawValue: hex.lowercased()) ?? .mint
    }
}

public enum PerryBundleConfig {
    public static let userVoiceResponseCaptionFontDefaultsKey = "perry.captionFont.default"
    public static let userVoiceResponseCaptionOpacityDefaultsKey = "perry.captionOpacity.default"
    public static var defaultVoiceResponseCaptionOpacity: Double { 0.9 }
}
