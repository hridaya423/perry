import SwiftUI

public enum PerryOverlayTheme {
    public enum Colors {
        public static let accent = Color(red: 0.204, green: 0.827, blue: 0.600)
        public static let ink = Color(white: 0.16)
        public static let selection = Color(red: 0.86, green: 0.28, blue: 0.24)
        /// Amber hold — the §5 blocked morph. Distinct from failure red.
        public static let amber = Color(red: 0.96, green: 0.62, blue: 0.04)
        public static let labelForeground = Color.white
        public static let labelBackground = Color.black.opacity(0.72)
        public static let eyeHighlight = Color.white
        public static let captionSurface = Color.white
        public static let captionText = Color.black
        public static let shadow = Color.black.opacity(0.22)
    }

    /// Motion budgets: feedback ≤150ms, entrances ≤300ms with a strong
    /// ease-out, spatial travel uses the house spring. Reduced motion keeps
    /// opacity/color feedback and removes travel and bounce.
    public enum Motion {
        public static let feedback = Animation.easeOut(duration: 0.14)
        public static let entrance = Animation.easeOut(duration: 0.24)
        public static let travel = Animation.spring(response: 0.2, dampingFraction: 0.6)
        public static let travelFast = Animation.spring(response: 0.16, dampingFraction: 0.72)
        public static let ambientPulse = Animation.easeInOut(duration: 0.82)
    }
}

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

/// Canonical buddy states. Animation is never the only signal: each state has
/// a static label and icon, and surfaces show text status alongside the pose.
public enum PerryBuddyState: String, Equatable, Sendable {
    case idle
    case listening
    case thinking
    case guiding
    case acting
    case awaitingApproval
    case success
    case blocked

    public var pose: PerryBuddyAnimationState {
        switch self {
        case .idle: return .idle
        case .listening, .awaitingApproval: return .waiting
        case .thinking: return .review
        case .guiding: return .waving
        case .acting: return .running
        case .success: return .jumping
        case .blocked: return .failed
        }
    }

    public var label: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .guiding: return "Guiding"
        case .acting: return "Acting"
        case .awaitingApproval: return "Waiting for approval"
        case .success: return "Done"
        case .blocked: return "Blocked"
        }
    }

    public var symbolName: String {
        switch self {
        case .idle: return "face.smiling"
        case .listening: return "ear"
        case .thinking: return "ellipsis.bubble"
        case .guiding: return "hand.point.up.left"
        case .acting: return "figure.run"
        case .awaitingApproval: return "hand.raised"
        case .success: return "checkmark.circle"
        case .blocked: return "exclamationmark.triangle"
        }
    }
}

public enum PerryVoicePhase: Equatable {
    case idle
    case listening
    case processing
    case responding
}

public final class PerryCursorState: ObservableObject {
    /// Semantic buddy state; setting it drives the sprite pose. Transient
    /// poses (e.g. waving while speaking, running during travel) still write
    /// `animation` directly after any `buddyState` write.
    @Published public var buddyState: PerryBuddyState = .idle {
        didSet { animation = buddyState.pose }
    }
    @Published public var animation: PerryBuddyAnimationState = .idle
    @Published public var taskBubbleText: String?
    @Published public var voiceState: PerryVoicePhase = .idle
    @Published public var currentAudioPowerLevel: CGFloat = 0
    @Published public var detectedElementScreenLocation: CGPoint?
    @Published public var detectedElementDisplayFrame: CGRect?
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
    /// Set by OverlayWindowManager: overlay windows are persistent now, so
    /// this flag — not view appear/disappear — drives cursor tracking. A
    /// hidden host must hold zero monitors and timers (idle CPU budget).
    @Published public var overlayVisible: Bool = false

    public init() {}

    public func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
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

/// Lightweight frame-interval probe for the overlay's cursor-tracking tick.
/// Only collects while the overlay reports samples (env-gated downstream);
/// drained at hide so each "visual wave" yields its own interval stats.
public final class OverlayPerfProbe {
    public static let shared = OverlayPerfProbe()
    public var isEnabled = false
    /// Fires once when cursor-follow monitors prove dead (pointer moves but
    /// no events arrive — Input Monitoring denied) and the view switches to
    /// polling `NSEvent.mouseLocation`, which needs no grant.
    public var onCursorTrackingDegraded: (() -> Void)?
    /// True while the view is on the permission-free polling path.
    public private(set) var cursorTrackingDegraded = false
    private var lastTick: CFAbsoluteTime = 0
    private var intervals: [Double] = []
    private let lock = NSLock()

    private init() {}

    public func tick() {
        guard isEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if lastTick > 0 {
            intervals.append((now - lastTick) * 1000)
        }
        lastTick = now
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        lastTick = 0
        intervals.removeAll()
        lock.unlock()
    }

    public func drain() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        let drained = intervals
        intervals.removeAll()
        lastTick = 0
        return drained
    }

    public func markCursorTrackingDegraded(_ degraded: Bool) {
        guard degraded != cursorTrackingDegraded else { return }
        cursorTrackingDegraded = degraded
        if degraded { onCursorTrackingDegraded?() }
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

public enum PerryBundleConfig {
    public static let userVoiceResponseCaptionOpacityDefaultsKey = "perry.captionOpacity.default"
    public static var defaultVoiceResponseCaptionOpacity: Double { 0.9 }
}
