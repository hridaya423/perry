import SwiftUI

public enum PerryOverlayTheme {
    public enum Colors {
        public static let accentRGB = 0x9CCBB6
        public static let accent = Color(
            red: Double((accentRGB >> 16) & 0xFF) / 255,
            green: Double((accentRGB >> 8) & 0xFF) / 255,
            blue: Double(accentRGB & 0xFF) / 255
        )
        public static let ink = Color(white: 0.16)
        public static let selection = Color(red: 0.86, green: 0.28, blue: 0.24)
        /// Amber hold — the blocked morph. Distinct from failure red.
        public static let amber = Color(red: 0.96, green: 0.62, blue: 0.04)
        public static let labelForeground = Color.white
        public static let labelBackground = Color.black.opacity(0.72)
        public static let captionSurface = Color.white
        public static let captionText = Color.black
        public static let shadow = Color.black.opacity(0.22)
    }

    /// Motion budgets: feedback ≤150ms, entrances ≤300ms with a strong
    /// ease-out, spatial travel uses the house spring. Reduced motion keeps
    /// opacity/color feedback and removes travel and bounce.
    public enum Motion {
        public static let feedback = Animation.easeOut(duration: 0.14)
        public static let travel = Animation.spring(response: 0.2, dampingFraction: 0.6)
        public static let travelFast = Animation.spring(response: 0.16, dampingFraction: 0.72)
        public static let ambientPulse = Animation.easeInOut(duration: 0.82)
    }
}

public extension Color {
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
}

public enum PerryVoicePhase: Equatable {
    case idle
    case listening
    case processing
    case responding
}

public final class PerryCursorState: ObservableObject {
    @Published public var buddyState: PerryBuddyState = .idle
    @Published public var taskBubbleText: String? {
        didSet { bubbleExpiry?.cancel() }
    }
    private var bubbleExpiry: DispatchWorkItem?
    @Published public var voiceState: PerryVoicePhase = .idle
    @Published public var currentAudioPowerLevel: CGFloat = 0
    @Published public var detectedElementScreenLocation: CGPoint?
    @Published public var detectedElementDisplayFrame: CGRect?
    @Published public var agentTaskBubbleText: String?
    @Published public var externalSecondaryCursors: [PerryExternalCursor] = []
    @Published public var visualGuidanceOverlays: [PerryGuidanceOverlay] = [] {
        didSet { scheduleMarkExpiry() }
    }
    private var expiringMarks: Set<UUID> = []
    @Published public var circleSelectLivePoints: [CGPoint] = []
    @Published public var circleSelectSnappedRect: CGRect?
    @Published public var circleSelectSnapLabel: String?
    @Published public var activeControlGlowRect: CGRect?
    @Published public var activeControlGlowLabel: String?
    @Published public var overlayVisible: Bool = false
    @Published public var panelScreenFrame: CGRect?

    public init() {}

    public func expireTaskBubble(after seconds: TimeInterval) {
        let text = taskBubbleText
        let expiry = DispatchWorkItem { [weak self] in
            guard let self, self.taskBubbleText == text else { return }
            self.taskBubbleText = nil
        }
        bubbleExpiry?.cancel()
        bubbleExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: expiry)
    }

    /// The user clicked at `point` (AppKit screen space): a mark on or just
    /// around it has done its job.
    public func dismissMarks(at point: CGPoint) {
        let hit = visualGuidanceOverlays.filter { $0.screenBounds.insetBy(dx: -24, dy: -48).contains(point) }
        guard !hit.isEmpty else { return }
        let ids = Set(hit.map(\.id))
        visualGuidanceOverlays.removeAll { ids.contains($0.id) }
    }

    private func scheduleMarkExpiry() {
        for overlay in visualGuidanceOverlays where expiringMarks.insert(overlay.id).inserted {
            let id = overlay.id
            let delay = max(0, overlay.createdAt.addingTimeInterval(overlay.duration).timeIntervalSinceNow)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                expiringMarks.remove(id)
                visualGuidanceOverlays.removeAll { $0.id == id }
            }
        }
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

/// The chrome contract every Perry window follows: excluded
/// from screenshots and screen shares (`sharingType = .none`), visible on
/// every space including fullscreen apps, stationary, and out of the
/// ⌘⇥ window cycle. Interactive levels stack just under the system
/// dragging-window ceiling so a drag over Perry chrome never loses it.
public enum PerryWindowChrome {
    private static let interactiveCeiling = CGWindowLevelForKey(.draggingWindow)

    /// The overlay cursor surface — above every app window, one step under
    /// the ceiling so it never captures a drag.
    public static let cursorOverlay = NSWindow.Level(rawValue: Int(interactiveCeiling) - 1)

    /// Applies the share-hiding and space behavior. Every Perry window
    /// calls this; windows that also need a specific level set it after.
    /// `PERRY_ALLOW_SCREEN_CAPTURE=1` opts back into capture for lab and
    /// evidence runs — the product default is always hidden.
    public static func applyChrome(to window: NSWindow) {
        if ProcessInfo.processInfo.environment["PERRY_ALLOW_SCREEN_CAPTURE"] == nil {
            window.sharingType = .none
        }
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

public enum PerryBundleConfig {
    public static let userVoiceResponseCaptionOpacityDefaultsKey = "perry.captionOpacity.default"
    public static var defaultVoiceResponseCaptionOpacity: Double { 0.9 }
}
