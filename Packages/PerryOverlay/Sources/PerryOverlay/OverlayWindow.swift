import AppKit
import Combine
import SwiftUI

/// Where the agent dock parks itself on the active screen. Eight anchor
/// points: four corners, four mid-edges. Default is top-right because
/// that's where most users put their menubar/notification stack — the
/// dock blends with that visual line without competing for the bottom
/// Dock area. `nonisolated` so the type can be referenced from any
/// actor context (the dock manager calls `originForWindow` from
/// `@MainActor`; PerryCursorState bindings cross actors freely).
nonisolated enum AgentParkingPosition: String, CaseIterable, Identifiable {
    case topLeft = "topLeft"
    case topCenter = "topCenter"
    case topRight = "topRight"
    case middleLeft = "middleLeft"
    case middleRight = "middleRight"
    case bottomLeft = "bottomLeft"
    case bottomCenter = "bottomCenter"
    case bottomRight = "bottomRight"

    static let `default`: AgentParkingPosition = .topRight
    static let userDefaultsKey = "perry.agentParkingPosition"
    private static let calibrationDefaultsPrefix = "perry.agentParkingCalibration"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topCenter: return "Top"
        case .topRight: return "Top Right"
        case .middleLeft: return "Left"
        case .middleRight: return "Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomCenter: return "Bottom"
        case .bottomRight: return "Bottom Right"
        }
    }

    /// Computes the origin (bottom-left in AppKit coords) for a window
    /// of `size` parked on `screen` at this anchor. Uses `visibleFrame`
    /// so the dock respects the menu bar and system Dock.
    func originForWindow(size: NSSize, on screen: NSScreen, edgeInset: CGFloat = 16) -> CGPoint {
        let frame = screen.frame
        let visible = screen.visibleFrame

        let xLeft = visible.minX + edgeInset
        let xRight = visible.maxX - size.width - edgeInset
        let xCenter = visible.midX - size.width / 2

        let yTop = visible.maxY - size.height - max(edgeInset, frame.maxY - visible.maxY + 8)
        let yBottom = visible.minY + edgeInset
        let yMiddle = visible.midY - size.height / 2

        let baseOrigin: CGPoint
        switch self {
        case .topLeft:      baseOrigin = CGPoint(x: xLeft, y: yTop)
        case .topCenter:    baseOrigin = CGPoint(x: xCenter, y: yTop)
        case .topRight:     baseOrigin = CGPoint(x: xRight, y: yTop)
        case .middleLeft:   baseOrigin = CGPoint(x: xLeft, y: yMiddle)
        case .middleRight:  baseOrigin = CGPoint(x: xRight, y: yMiddle)
        case .bottomLeft:   baseOrigin = CGPoint(x: xLeft, y: yBottom)
        case .bottomCenter: baseOrigin = CGPoint(x: xCenter, y: yBottom)
        case .bottomRight:  baseOrigin = CGPoint(x: xRight, y: yBottom)
        }

        let calibrationOffset = Self.calibrationOffset(for: self)
        return CGPoint(
            x: baseOrigin.x + calibrationOffset.width,
            y: baseOrigin.y + calibrationOffset.height
        )
    }

    var normalizedAnchor: CGPoint {
        switch self {
        case .topLeft:      return CGPoint(x: 0.0, y: 0.0)
        case .topCenter:    return CGPoint(x: 0.5, y: 0.0)
        case .topRight:     return CGPoint(x: 1.0, y: 0.0)
        case .middleLeft:   return CGPoint(x: 0.0, y: 0.5)
        case .middleRight:  return CGPoint(x: 1.0, y: 0.5)
        case .bottomLeft:   return CGPoint(x: 0.0, y: 1.0)
        case .bottomCenter: return CGPoint(x: 0.5, y: 1.0)
        case .bottomRight:  return CGPoint(x: 1.0, y: 1.0)
        }
    }

    static func calibrationOffset(for position: AgentParkingPosition) -> CGSize {
        let defaults = UserDefaults.standard
        return CGSize(
            width: defaults.double(forKey: calibrationKey(for: position, axis: "x")),
            height: defaults.double(forKey: calibrationKey(for: position, axis: "y"))
        )
    }

    static func setCalibrationOffset(_ offset: CGSize, for position: AgentParkingPosition) {
        let clampedOffset = CGSize(
            width: min(max(offset.width, -220), 220),
            height: min(max(offset.height, -180), 180)
        )
        let defaults = UserDefaults.standard
        defaults.set(clampedOffset.width, forKey: calibrationKey(for: position, axis: "x"))
        defaults.set(clampedOffset.height, forKey: calibrationKey(for: position, axis: "y"))
    }

    private static func calibrationKey(for position: AgentParkingPosition, axis: String) -> String {
        "\(calibrationDefaultsPrefix).\(position.rawValue).\(axis)"
    }
}

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and click-through. A content-view `hitTest`
        // returning nil does NOT pass clicks to the app behind, so the window
        // itself must ignore events to stay transparent.
        self.isOpaque = false
        self.backgroundColor = .clear
        // Perry's overlay must never appear in screenshots or screen shares.
        self.sharingType = .none
        PerryWindowLevels.applyCursorOverlayLevel(to: self)
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        self.hidesOnDeactivate = false

        self.setFrame(screen.frame, display: true)

        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

private struct PerryCalibrationBoxView: View {
    let color: Color
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(
                color,
                style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round)
            )
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(0.08))
            )
            .shadow(color: color.opacity(reduceMotion ? 0.32 : 0.76), radius: reduceMotion ? 4 : 10)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(color.opacity(0.32), lineWidth: 7)
                    .blur(radius: 1.5)
            )
            .scaleEffect(reduceMotion ? 1 : (pulse ? 1.04 : 0.98))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(PerryOverlayTheme.Motion.ambientPulse.repeatCount(4, autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

struct AgentTaskBubbleSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct PerryBuddyView: View {
    let screenFrame: CGRect
    let supervisorState: PerryCursorState
    @ObservedObject var cursorState: PerryCursorState
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @AppStorage(PerryBundleConfig.userVoiceResponseCaptionOpacityDefaultsKey) private var voiceResponseCaptionOpacity = PerryBundleConfig.defaultVoiceResponseCaptionOpacity

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, supervisorState: PerryCursorState) {
        self.screenFrame = screenFrame
        self.supervisorState = supervisorState
        self.cursorState = supervisorState

        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    /// Event-driven cursor follow (§5): mouse-moved/dragged monitors write
    /// the position in the same turn the event arrives — no polling timer,
    /// so an idle Perry keeps zero timers ticking. The global monitor covers
    /// events aimed at other apps; the local monitor covers our own.
    @State private var cursorMoveMonitors: [Any] = []
    /// Global monitors deliver nothing without Input Monitoring — they install
    /// fine and just never fire, which used to freeze the buddy silently. A
    /// 0.5 s watchdog compares `NSEvent.mouseLocation` (permission-free) with
    /// the monitor event count; movement without events means starvation, and
    /// follow switches to a permission-free poll until monitors wake.
    @State private var cursorWatchdog: Timer?
    @State private var cursorPollTimer: Timer?
    @State private var lastProbePoint: CGPoint = .zero
    @State private var monitorEventCount = 0
    @State private var stationaryPolls = 0
    @State private var agentTaskBubbleSize: CGSize = .zero
    @State private var cursorOpacity: Double = 0.0

    private var isCalibrationCursorBoxActive: Bool {
        visualGuidanceOverlaysOnThisScreen.contains { overlay in
            guard let caption = overlay.style.caption else { return false }
            let normalized = caption
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
            return normalized.contains("calibration")
                || normalized.contains("calibrate")
                || normalized.contains("anchor")
        }
    }


    private var captionBubbleBackgroundColor: Color { PerryOverlayTheme.Colors.captionSurface }
    private var captionBubbleTextColor: Color { PerryOverlayTheme.Colors.captionText }
    private var captionBubbleShadowColor: Color { PerryOverlayTheme.Colors.shadow }
    private var normalizedVoiceResponseCaptionOpacity: Double {
        min(max(voiceResponseCaptionOpacity, 0.55), 1.0)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)

            if let externalPrimaryCaption = cursorState.externalPrimaryCaptionText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !externalPrimaryCaption.isEmpty,
               followerIsVisibleOnThisScreen {
                externalCaption(
                    externalPrimaryCaption,
                    at: cursorPosition,
                    color: externalPrimaryCaptionColor
                )
            }

            if let activeControlGlowRect = cursorState.activeControlGlowRect,
               activeControlGlowRect.intersects(screenFrame) {
                activeControlGlow(activeControlGlowRect)
            }

            ForEach(externalSecondaryCursorsOnThisScreen) { cursor in
                externalSecondaryCursor(cursor)
            }

            ForEach(visualGuidanceOverlaysOnThisScreen) { overlay in
                visualGuidanceOverlay(overlay)
            }

            if !circleSelectPointsOnThisScreen.isEmpty {
                circleSelectLiveTrail(
                    circleSelectPointsOnThisScreen,
                    dimmed: cursorState.circleSelectSnappedRect != nil
                )
            }

            if let snappedRect = cursorState.circleSelectSnappedRect,
               snappedRect.intersects(screenFrame) {
                circleSelectSnappedHighlight(
                    snappedRect,
                    label: cursorState.circleSelectSnapLabel
                )
            }

            if shouldShowAgentTaskBubble,
               let agentTaskBubbleText = taskBubbleText,
               !agentTaskBubbleText.isEmpty {
                let bubblePosition = anchoredBubblePosition(
                    for: cursorPosition,
                    bubbleSize: agentTaskBubbleSize,
                    horizontalOffset: 12,
                    verticalOffset: 20
                )

                Text(agentTaskBubbleText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(captionBubbleTextColor)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(captionBubbleBackgroundColor)
                            .shadow(color: captionBubbleShadowColor, radius: 8, x: 0, y: 2)
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
                    .opacity(cursorOpacity)
                    .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.16), value: taskBubbleText)
                    .onPreferenceChange(AgentTaskBubbleSizePreferenceKey.self) { newSize in
                        agentTaskBubbleSize = newSize
                    }
            }

            ZStack {
                if isCalibrationCursorBoxActive {
                    PerryCalibrationBoxView(
                        color: PerryOverlayTheme.Colors.accent,
                        reduceMotion: accessibilityReduceMotion
                    )
                } else {
                    PerryGlassCursorView(
                        size: 52,
                        morph: cursorMorph,
                        micLevel: cursorState.currentAudioPowerLevel,
                        sessionActive: cursorState.voiceState != .idle || cursorState.buddyState != .idle
                    )
                }
            }
                .frame(
                    width: isCalibrationCursorBoxActive ? 38 : 48,
                    height: isCalibrationCursorBoxActive ? 38 : 52
                )
                .opacity(followerIsVisibleOnThisScreen && (cursorState.voiceState == .idle || cursorState.voiceState == .responding) ? cursorOpacity : 0)
                .position(followerPosition)
                .animation(PerryOverlayTheme.Motion.travel, value: followerPosition)
                .animation(PerryOverlayTheme.Motion.feedback, value: cursorState.voiceState)

            PerryWaveformView(
                audioPowerLevel: cursorState.currentAudioPowerLevel,
                cursorColor: PerryOverlayTheme.Colors.accent,
                isActive: followerIsVisibleOnThisScreen && cursorState.voiceState == .listening
            )
                .opacity(followerIsVisibleOnThisScreen && cursorState.voiceState == .listening ? cursorOpacity : 0)
                .position(followerPosition)
                .animation(PerryOverlayTheme.Motion.feedback, value: cursorState.voiceState)

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            // Host windows persist and are pre-rendered at warm time while
            // invisible — real activation is driven by `overlayVisible`.
            guard cursorState.overlayVisible else { return }
            beginVisibleSession()
        }
        .onDisappear {
            stopTrackingCursor()
        }
        .onChange(of: cursorState.overlayVisible) { _, visible in
            if visible {
                beginVisibleSession()
            } else {
                stopTrackingCursor()
            }
        }
    }

    /// The overlay just became visible: snap the follower to the live
    /// pointer, start tracking, and reveal. A published element target is
    /// picked up automatically through `followerPosition`.
    private func beginVisibleSession() {
        let mouseLocation = NSEvent.mouseLocation
        isCursorOnThisScreen = screenFrame.contains(mouseLocation)
        let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
        cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

        startTrackingCursor()
        cursorOpacity = 1.0
    }

    /// §5 morph grammar for the main cursor: voice state wins (listening ring,
    /// thinking orbit), then semantic buddy state (amber hold, settle tick),
    /// else the resting pointer that breathes only while a session is active.
    private var cursorMorph: PerryCursorMorph {
        switch cursorState.voiceState {
        case .listening: return .listening
        case .processing: return .thinking
        case .idle, .responding: break
        }
        switch cursorState.buddyState {
        case .blocked, .awaitingApproval: return .blocked
        case .success: return .settle
        case .acting: return .ghost
        default: return .pointer
        }
    }

    /// Where the companion sits: parked at the detected element while one
    /// is published on this screen, otherwise riding the pointer offset.
    private var followerPosition: CGPoint {
        if let screenLocation = cursorState.detectedElementScreenLocation,
           (cursorState.detectedElementDisplayFrame?.intersects(screenFrame) == true
            || screenFrame.contains(screenLocation)) {
            let local = convertScreenPointToSwiftUICoordinates(screenLocation)
            return CGPoint(
                x: max(20, min(local.x + 8, screenFrame.width - 20)),
                y: max(20, min(local.y + 12, screenFrame.height - 20))
            )
        }
        return cursorPosition
    }

    private var followerIsVisibleOnThisScreen: Bool {
        if let screenLocation = cursorState.detectedElementScreenLocation {
            return cursorState.detectedElementDisplayFrame?.intersects(screenFrame) == true
                || screenFrame.contains(screenLocation)
        }
        return isCursorOnThisScreen
    }

    private var shouldShowAgentTaskBubble: Bool {
        followerIsVisibleOnThisScreen
            && cursorState.voiceState != .listening
            && cursorState.voiceState != .processing
    }

    private var taskBubbleText: String? {
        let text = cursorState.agentTaskBubbleText ?? cursorState.taskBubbleText
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private var externalPrimaryCaptionColor: Color {
        colorFromHex(cursorState.externalPrimaryCaptionAccentHex) ?? PerryOverlayTheme.Colors.accent
    }

    private var externalSecondaryCursorsOnThisScreen: [PerryExternalCursor] {
        cursorState.externalSecondaryCursors.filter { cursor in
            screenFrame.contains(cursor.screenLocation)
        }
    }

    private var circleSelectPointsOnThisScreen: [CGPoint] {
        let points = cursorState.circleSelectLivePoints
        guard !points.isEmpty else { return [] }
        return points.compactMap { point in
            guard screenFrame.insetBy(dx: -40, dy: -40).contains(point) else { return nil }
            return convertScreenPointToSwiftUICoordinates(point)
        }
    }

    @ViewBuilder
    private func circleSelectLiveTrail(_ localPoints: [CGPoint], dimmed: Bool) -> some View {
        PerryFadingTrailView(
            points: localPoints,
            color: PerryOverlayTheme.Colors.selection,
            reduceMotion: accessibilityReduceMotion,
            overallOpacity: dimmed ? 0.35 : 1.0
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func circleSelectSnappedHighlight(_ screenRect: CGRect, label: String?) -> some View {
        let localRect = convertScreenRectToSwiftUICoordinates(screenRect)
        let trailColor = PerryOverlayTheme.Colors.selection
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(trailColor.opacity(0.10))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(trailColor.opacity(0.92), lineWidth: 2.4)
                .shadow(color: trailColor.opacity(0.55), radius: 8, x: 0, y: 0)

            if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(PerryOverlayTheme.Colors.labelForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(PerryOverlayTheme.Colors.labelBackground)
                    )
                    .position(x: localRect.midX, y: max(14, localRect.minY - 14))
            }
        }
        .frame(width: max(1, localRect.width), height: max(1, localRect.height))
        .position(x: localRect.midX, y: localRect.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.16), value: screenRect)
    }

    private var visualGuidanceOverlaysOnThisScreen: [PerryGuidanceOverlay] {
        cursorState.visualGuidanceOverlays.filter { overlay in
            overlay.screenBounds.intersects(screenFrame)
        }
    }

    @ViewBuilder
    private func activeControlGlow(_ screenRect: CGRect) -> some View {
        let localRect = convertScreenRectToSwiftUICoordinates(screenRect)
        ZStack {
            PerryControlGlowView(
                color: PerryOverlayTheme.Colors.accent,
                reduceMotion: accessibilityReduceMotion
            )
            .frame(width: max(1, localRect.width), height: max(1, localRect.height))
            .position(x: localRect.midX, y: localRect.midY)

            if let label = cursorState.activeControlGlowLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
               !label.isEmpty {
                externalCaption(label, at: CGPoint(x: localRect.midX, y: localRect.minY), color: PerryOverlayTheme.Colors.accent)
            }
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func visualGuidanceOverlay(_ overlay: PerryGuidanceOverlay) -> some View {
        let color = colorFromHex(overlay.style.accentHex) ?? PerryOverlayTheme.Colors.accent
        ZStack {
            switch overlay.kind {
            case .scribble:
                visualGuidanceScribble(overlay, color: color)
            case .rectangle:
                visualGuidanceRectangle(overlay, color: color)
            case .ellipse:
                visualGuidanceEllipse(overlay, color: color)
            }

            if let caption = overlay.style.caption?.trimmingCharacters(in: .whitespacesAndNewlines),
               !caption.isEmpty {
                guidanceCaption(caption, for: overlay, color: color)
            }
        }
        .transition(accessibilityReduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
        .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.18), value: overlay.id)
        .allowsHitTesting(false)
    }

    /// Caption next to a guidance mark (§5): CaptionPlacer picks a slot that
    /// doesn't cover the marked element and stays inside the visible frame
    /// (clear of menu bar / Dock / notch).
    @ViewBuilder
    private func guidanceCaption(_ caption: String, for overlay: PerryGuidanceOverlay, color: Color) -> some View {
        let bubbleSize = estimatedExternalCaptionBubbleSize(for: caption, providerBadge: nil)
        let targetBL = overlay.screenBounds
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? screenFrame.maxY
        // AppKit bottom-left → CG top-left for the solver.
        let anchorCG = CGRect(
            x: targetBL.minX, y: primaryMaxY - targetBL.maxY,
            width: targetBL.width, height: targetBL.height
        )
        let visibleBL = NSScreen.screens
            .first(where: { $0.frame == screenFrame })?.visibleFrame ?? screenFrame
        let screenCG = CGRect(
            x: visibleBL.minX, y: primaryMaxY - visibleBL.maxY,
            width: visibleBL.width, height: visibleBL.height
        )
        let placed = targetBL.isNull
            ? CGRect(
                x: captionAnchor(for: overlay).x - bubbleSize.width / 2,
                y: captionAnchor(for: overlay).y - bubbleSize.height / 2,
                width: bubbleSize.width, height: bubbleSize.height
            )
            : CaptionPlacer.place(
                size: bubbleSize, anchor: anchorCG, in: screenCG
            )
        let centerBL = targetBL.isNull
            ? captionAnchor(for: overlay)
            : CGPoint(x: placed.midX, y: primaryMaxY - placed.midY)
        let local = targetBL.isNull
            ? centerBL
            : convertScreenPointToSwiftUICoordinates(centerBL)

        captionBubble(caption, at: local, color: color)
    }

    @ViewBuilder
    private func visualGuidanceScribble(_ overlay: PerryGuidanceOverlay, color: Color) -> some View {
        let localPoints = overlay.points.map { convertScreenPointToSwiftUICoordinates($0.cgPoint) }
        PerryGuidanceScribbleView(
            points: localPoints,
            color: color,
            lineWidth: CGFloat(overlay.style.lineWidth),
            drawingDuration: min(1.2, max(0.35, overlay.duration * 0.20)),
            reduceMotion: accessibilityReduceMotion
        )
    }

    @ViewBuilder
    private func visualGuidanceRectangle(_ overlay: PerryGuidanceOverlay, color: Color) -> some View {
        guidanceLoop(overlay, color: color, ellipse: false)
    }

    @ViewBuilder
    private func visualGuidanceEllipse(_ overlay: PerryGuidanceOverlay, color: Color) -> some View {
        guidanceLoop(overlay, color: color, ellipse: true)
    }

    @ViewBuilder
    private func guidanceLoop(_ overlay: PerryGuidanceOverlay, color: Color, ellipse: Bool) -> some View {
        if let rect = overlay.rect?.normalized.cgRect {
            let localRect = convertScreenRectToSwiftUICoordinates(rect)
            PerryGuidanceRectangleView(
                color: color,
                lineWidth: CGFloat(overlay.style.lineWidth),
                fillOpacity: overlay.style.fillOpacity,
                drawingDuration: min(0.95, max(0.38, overlay.duration * 0.22)),
                reduceMotion: accessibilityReduceMotion,
                ellipse: ellipse
            )
            .frame(width: localRect.width, height: localRect.height)
            .position(x: localRect.midX, y: localRect.midY)
            .allowsHitTesting(false)
        }
    }

    private func captionAnchor(for overlay: PerryGuidanceOverlay) -> CGPoint {
        let bounds = overlay.screenBounds
        guard !bounds.isNull else { return cursorPosition }
        return convertScreenPointToSwiftUICoordinates(CGPoint(x: bounds.midX, y: bounds.maxY))
    }

    private func convertScreenRectToSwiftUICoordinates(_ rect: CGRect) -> CGRect {
        let topLeft = convertScreenPointToSwiftUICoordinates(CGPoint(x: rect.minX, y: rect.maxY))
        return CGRect(x: topLeft.x, y: topLeft.y, width: rect.width, height: rect.height)
    }

    @ViewBuilder
    private func externalSecondaryCursor(_ cursor: PerryExternalCursor) -> some View {
        let local = convertScreenPointToSwiftUICoordinates(cursor.screenLocation)
        let position = CGPoint(x: local.x + 35, y: local.y + 25)
        let color = colorFromHex(cursor.accentHex) ?? PerryOverlayTheme.Colors.accent
        ZStack {
            // §5 ghost morph: another agent's pointer is a dashed outline,
            // never filled — reads as Perry's, not the user's.
            PerryGlassCursorView(size: 30, morph: .ghost)
                .shadow(color: color.opacity(0.90), radius: 10, x: 0, y: 0)
                .position(position)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))

            if let caption = cursor.caption?.trimmingCharacters(in: .whitespacesAndNewlines),
               !caption.isEmpty {
                externalCaption(caption, at: position, color: color)
            }
        }
        .animation(PerryOverlayTheme.Motion.travelFast, value: cursor.screenLocation)
    }

    @ViewBuilder
    private func externalCaption(_ caption: String, at position: CGPoint, color: Color) -> some View {
        let bubblePosition = anchoredBubblePosition(
            for: position,
            bubbleSize: estimatedExternalCaptionBubbleSize(for: caption, providerBadge: nil),
            horizontalOffset: 12,
            verticalOffset: 20
        )
        captionBubble(caption, at: bubblePosition, color: color)
    }

    @ViewBuilder
    private func captionBubble(_ caption: String, at position: CGPoint, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(captionBubbleTextColor)
                .lineLimit(5)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(captionBubbleBackgroundColor.opacity(normalizedVoiceResponseCaptionOpacity))
                .shadow(color: captionBubbleShadowColor.opacity(normalizedVoiceResponseCaptionOpacity), radius: 8, x: 0, y: 2)
        )
        .frame(maxWidth: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .position(x: position.x, y: position.y)
        .transition(.opacity)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func estimatedExternalCaptionBubbleSize(for caption: String, providerBadge: String? = nil) -> CGSize {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CGSize(width: 72, height: 28) }

        let averageGlyphWidth: CGFloat = 6.6
        let horizontalPadding: CGFloat = 18
        let maxWidth: CGFloat = 340
        let minWidth: CGFloat = 72
        let rawWidth = CGFloat(trimmed.count) * averageGlyphWidth + horizontalPadding
        let width = min(max(rawWidth, minWidth), maxWidth)
        let lineCount = max(1, Int(ceil(rawWidth / maxWidth)))
        let badgeHeight: CGFloat = providerBadge == nil ? 0 : 12
        let height = CGFloat(min(lineCount, 5)) * 15 + 10 + badgeHeight
        return CGSize(width: width, height: height)
    }

    private func colorFromHex(_ rawHex: String?) -> Color? {
        guard let hex = rawHex?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty else { return nil }
        return Color(optionalHex: hex)
    }

    private func anchoredBubblePosition(
        for cursorPosition: CGPoint,
        bubbleSize: CGSize,
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat
    ) -> CGPoint {
        let halfWidth = bubbleSize.width / 2
        let halfHeight = bubbleSize.height / 2
        let minMargin: CGFloat = 8

        var x = cursorPosition.x + horizontalOffset + halfWidth
        let maxX = screenFrame.width - halfWidth - minMargin
        let minX = halfWidth + minMargin

        if x > maxX {
            x = cursorPosition.x - horizontalOffset - halfWidth
        }
        x = min(max(x, minX), maxX)

        var y = cursorPosition.y + verticalOffset + halfHeight
        let maxY = screenFrame.height - halfHeight - minMargin
        let minY = halfHeight + minMargin
        y = min(max(y, minY), maxY)

        return CGPoint(x: x, y: y)
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        stopTrackingCursor()
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
            // Global-monitor callbacks arrive on a background thread; the
            // state write still lands inside the frame the event produced.
            DispatchQueue.main.async {
                monitorEventCount += 1
                updateCursorTracking()
            }
        }) {
            cursorMoveMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            monitorEventCount += 1
            updateCursorTracking()
            return event
        }) {
            cursorMoveMonitors.append(local)
        }
        monitorEventCount = 0
        lastProbePoint = NSEvent.mouseLocation
        cursorWatchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            cursorWatchdogTick()
        }
    }

    private func stopTrackingCursor() {
        for monitor in cursorMoveMonitors { NSEvent.removeMonitor(monitor) }
        cursorMoveMonitors = []
        cursorWatchdog?.invalidate()
        cursorWatchdog = nil
        cursorPollTimer?.invalidate()
        cursorPollTimer = nil
    }

    private func cursorWatchdogTick() {
        let location = NSEvent.mouseLocation
        guard location != lastProbePoint else { return }
        lastProbePoint = location
        if monitorEventCount > 0 {
            cursorWatchdog?.invalidate()
            cursorWatchdog = nil
            if OverlayPerfProbe.shared.cursorTrackingDegraded {
                OverlayPerfProbe.shared.markCursorTrackingDegraded(false)
                cursorPollTimer?.invalidate()
                cursorPollTimer = nil
            }
            return
        }
        OverlayPerfProbe.shared.markCursorTrackingDegraded(true)
        guard cursorPollTimer == nil else { return }
        stationaryPolls = 0
        cursorPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            let point = NSEvent.mouseLocation
            if point != lastProbePoint {
                lastProbePoint = point
                stationaryPolls = 0
                updateCursorTracking()
            } else {
                stationaryPolls += 1
                if stationaryPolls > 45 {
                    cursorPollTimer?.invalidate()
                    cursorPollTimer = nil
                }
            }
        }
    }

    private func updateCursorTracking() {
        OverlayPerfProbe.shared.tick()
        let mouseLocation = NSEvent.mouseLocation
        isCursorOnThisScreen = screenFrame.contains(mouseLocation)
        let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
        cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

}

private struct PerryControlGlowView: View {
    let color: Color
    let reduceMotion: Bool

    @State private var pulse = false

    var body: some View {
        GeometryReader { geometry in
            let radius = min(max(min(geometry.size.width, geometry.size.height) * 0.05, 10), 30)
            ZStack {
                ForEach(0..<5, id: \.self) { index in
                    let inset = CGFloat(index) * 5
                    RoundedRectangle(cornerRadius: max(2, radius - inset * 0.35), style: .continuous)
                        .inset(by: inset)
                        .strokeBorder(
                            color.opacity(glowOpacity(for: index)),
                            lineWidth: CGFloat(5 - index)
                        )
                }

                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(color.opacity(0.78), lineWidth: 1.4)
            }
            .blur(radius: reduceMotion ? 0.2 : (pulse ? 0.45 : 0.9))
            .opacity(reduceMotion ? 0.82 : (pulse ? 0.92 : 0.68))
            .compositingGroup()
            .onAppear {
                pulse = true
            }
            .animation(
                reduceMotion ? nil : PerryOverlayTheme.Motion.ambientPulse.repeatCount(4, autoreverses: true),
                value: pulse
            )
        }
    }

    private func glowOpacity(for index: Int) -> Double {
        let opacities = [0.55, 0.32, 0.20, 0.13, 0.08]
        return opacities[min(max(index, 0), opacities.count - 1)]
    }
}

private struct PerryGuidanceScribbleView: View {
    let points: [CGPoint]
    let color: Color
    let lineWidth: CGFloat
    let drawingDuration: TimeInterval
    let reduceMotion: Bool

    @State private var drawProgress: CGFloat = 0

    var body: some View {
        let clampedProgress = min(max(drawProgress, 0), 1)
        // Hand-inked mark (§5): Catmull-Rom resample + seeded wobble +
        // tapered variable-width outline, drawn on over drawingDuration.
        let samples = InkStroke.sampled(through: points)
        let widths = InkStroke.widths(count: samples.count, baseWidth: lineWidth)

        ZStack(alignment: .topLeading) {
            InkStrokeShape(samples: samples, widths: widths, progress: clampedProgress)
                .fill(color)
                .shadow(
                    color: color.opacity(reduceMotion ? 0.30 : 0.68),
                    radius: reduceMotion ? 2 : 7,
                    x: 0,
                    y: 0
                )

            if !reduceMotion,
               let cursorPoint = InkStroke.point(on: samples, progress: clampedProgress),
               clampedProgress < 0.995 {
                PerryGlassCursorView(size: 24, morph: .pen)
                    .shadow(color: color.opacity(0.65), radius: 6, x: 0, y: 0)
                    .position(cursorPoint)
            }
        }
        .onAppear {
            drawProgress = reduceMotion ? 1 : 0
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: drawingDuration)) {
                drawProgress = 1
            }
        }
    }
}

/// Freehand circle-select stroke: smooth path with a comet-style fading tail
/// (oldest segments nearly invisible, head bright and slightly thicker).
private struct PerryFadingTrailView: View {
    let points: [CGPoint]
    let color: Color
    let reduceMotion: Bool
    var overallOpacity: Double = 1.0

    /// How many point-steps make up each fade band. Smaller = smoother fade.
    private let pointsPerBand = 3
    private let minOpacity: Double = 0.08
    private let maxOpacity: Double = 0.95
    private let minLineWidth: CGFloat = 2.2
    private let maxLineWidth: CGFloat = 5.0

    var body: some View {
        let displayPoints = points.count >= 2 ? points : []
        ZStack(alignment: .topLeading) {
            if displayPoints.count >= 2 {
                ForEach(Array(bandRanges(for: displayPoints.count).enumerated()), id: \.offset) { _, range in
                    let progress = bandProgress(range: range, total: displayPoints.count)
                    let opacity = (minOpacity + (maxOpacity - minOpacity) * progress) * overallOpacity
                    let width = minLineWidth + (maxLineWidth - minLineWidth) * CGFloat(progress)
                    let slice = Array(displayPoints[range])
                    PerrySmoothScribblePath(points: slice)
                        .stroke(
                            color.opacity(opacity),
                            style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
                        )
                        .shadow(
                            color: color.opacity(reduceMotion ? opacity * 0.15 : opacity * 0.55),
                            radius: reduceMotion ? 1.5 : (2.5 + 4.5 * progress),
                            x: 0,
                            y: 0
                        )
                }
            }

            if let last = displayPoints.last, overallOpacity > 0.5 {
                Circle()
                    .fill(color.opacity(0.95 * overallOpacity))
                    .frame(width: 8, height: 8)
                    .shadow(color: color.opacity(0.75 * overallOpacity), radius: 5, x: 0, y: 0)
                    .position(last)
            }
        }
        .opacity(overallOpacity)
    }

    /// Overlapping index ranges so band strokes join without gaps.
    private func bandRanges(for count: Int) -> [Range<Int>] {
        guard count >= 2 else { return [] }
        var ranges: [Range<Int>] = []
        var start = 0
        while start < count - 1 {
            let end = min(count, start + pointsPerBand + 1)
            ranges.append(start..<end)
            if end >= count { break }
            // Overlap one point so adjacent bands share a join vertex.
            start = end - 1
        }
        return ranges
    }

    /// 0 at the oldest end of the stroke, 1 at the newest (head).
    private func bandProgress(range: Range<Int>, total: Int) -> Double {
        guard total > 1 else { return 1 }
        let mid = Double(range.lowerBound + range.upperBound - 1) / 2.0
        return min(max(mid / Double(total - 1), 0), 1)
    }
}

private struct PerrySmoothScribblePath: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)

        guard points.count > 2 else {
            if let last = points.last {
                path.addLine(to: last)
            }
            return path
        }

        for index in 1..<points.count {
            let current = points[index]
            if index < points.count - 1 {
                let next = points[index + 1]
                let midpoint = CGPoint(
                    x: (current.x + next.x) / 2,
                    y: (current.y + next.y) / 2
                )
                path.addQuadCurve(to: midpoint, control: current)
            } else {
                path.addQuadCurve(to: current, control: current)
            }
        }

        return path
    }

    static func point(on points: [CGPoint], progress: CGFloat) -> CGPoint? {
        guard let first = points.first else { return nil }
        guard points.count > 1 else { return first }

        let segments = zip(points, points.dropFirst()).map { pair in
            let start = pair.0
            let end = pair.1
            let dx = end.x - start.x
            let dy = end.y - start.y
            return (start: start, end: end, length: (dx * dx + dy * dy).squareRoot())
        }
        let totalLength = segments.reduce(CGFloat(0)) { $0 + $1.length }
        guard totalLength > 0 else { return first }

        var remaining = min(max(progress, 0), 1) * totalLength
        for segment in segments {
            guard segment.length > 0 else { continue }
            if remaining <= segment.length {
                let t = remaining / segment.length
                return CGPoint(
                    x: segment.start.x + (segment.end.x - segment.start.x) * t,
                    y: segment.start.y + (segment.end.y - segment.start.y) * t
                )
            }
            remaining -= segment.length
        }

        return points.last
    }
}

private struct PerryGuidanceRectangleView: View {
    let color: Color
    let lineWidth: CGFloat
    let fillOpacity: Double
    let drawingDuration: TimeInterval
    let reduceMotion: Bool
    var ellipse: Bool = false

    @State private var drawProgress: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let clampedProgress = min(max(drawProgress, 0), 1)

            let inkRect = CGRect(origin: .zero, size: size)
                .insetBy(dx: lineWidth, dy: lineWidth)
            let samples = ellipse ? InkStroke.ellipse(in: inkRect) : InkStroke.rectangle(in: inkRect)
            let widths = InkStroke.widths(count: samples.count, baseWidth: lineWidth)

            ZStack(alignment: .topLeading) {
                (ellipse ? AnyShape(Ellipse()) : AnyShape(Rectangle()))
                    .fill(color.opacity(fillOpacity * Double(clampedProgress)))

                // Inked perimeter (§5): hand-drawn loop, not a crisp rect.
                InkStrokeShape(samples: samples, widths: widths, progress: clampedProgress)
                    .fill(color)
                    .shadow(
                        color: color.opacity(reduceMotion ? 0.30 : 0.70),
                        radius: reduceMotion ? 2 : 9,
                        x: 0,
                        y: 0
                    )

                if !reduceMotion && clampedProgress < 0.995,
                   let tip = InkStroke.point(on: samples, progress: clampedProgress) {
                    PerryGlassCursorView(size: 24, morph: .pen)
                        .shadow(color: color.opacity(0.65), radius: 6, x: 0, y: 0)
                        .position(tip)
                }
            }
            .onAppear {
                drawProgress = reduceMotion ? 1 : 0
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: drawingDuration)) {
                    drawProgress = 1
                }
            }
            .onChange(of: geometry.size) { _, _ in
                if reduceMotion {
                    drawProgress = 1
                }
            }
        }
    }
}

private struct PerryWaveformView: View {
    let audioPowerLevel: CGFloat
    let cursorColor: Color
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    @ViewBuilder
    var body: some View {
        if isActive && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timelineContext in
                bars(timelineDate: timelineContext.date)
            }
        } else {
            bars(timelineDate: .distantPast)
        }
    }

    private func bars(timelineDate: Date) -> some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { barIndex in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(cursorColor)
                    .frame(
                        width: 2,
                        height: barHeight(
                            for: barIndex,
                            timelineDate: timelineDate
                        )
                    )
            }
        }
        .shadow(color: cursorColor.opacity(0.6), radius: 6, x: 0, y: 0)
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

/// One persistent window + hosting view per screen. Windows are created
/// once and toggled with orderFront/orderOut — never rebuilt per
/// invocation — so the render cost is paid once at warm, not per Do.
private final class OverlayHost {
    let window: OverlayWindow
    let hostingView: NSHostingView<PerryBuddyView>
    /// The state object this host's view is bound to. A different object
    /// means the content view must be rebuilt.
    let boundState: PerryCursorState

    init(screen: NSScreen, state: PerryCursorState) {
        let window = OverlayWindow(screen: screen)
        let rootView = PerryBuddyView(screenFrame: screen.frame, supervisorState: state)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: screen.frame.size)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        self.window = window
        self.hostingView = hostingView
        self.boundState = state
    }
}

public class OverlayWindowManager {
    private var hosts: [ObjectIdentifier: OverlayHost] = [:]
    private var supervisorState: PerryCursorState?
    private var displayConfigurationObserver: NSObjectProtocol?

    /// Optional sample sink — wired by the app to its env-gated performance
    /// log. Arguments: metric id, unit, value.
    public var onSample: ((_ metricID: String, _ unit: String, _ value: Double) -> Void)? {
        didSet { OverlayPerfProbe.shared.isEnabled = onSample != nil }
    }

    public init() {
        displayConfigurationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshOverlayWindowsForCurrentScreens()
            }
        }
    }

    deinit {
        if let displayConfigurationObserver {
            NotificationCenter.default.removeObserver(displayConfigurationObserver)
        }
    }

    /// Pays the one-time window + SwiftUI render cost at launch: every
    /// screen's host is created and rendered once at alpha 0, so the first
    /// invocation is a pure orderFront of an already-drawn surface.
    public func warmRenderPipeline(state: PerryCursorState) {
        for screen in NSScreen.screens {
            _ = host(for: screen, state: state)
        }
    }

    /// Creates (or reuses) the host for `screen` and guarantees it has been
    /// rendered once while invisible.
    private func host(for screen: NSScreen, state: PerryCursorState) -> OverlayHost {
        let key = ObjectIdentifier(screen)
        // Reuse only when the bound state and the captured frame still
        // match — the root view's coordinate math is derived from
        // screenFrame at init, so a resized screen gets a fresh host.
        if let existing = hosts[key],
           existing.boundState === state,
           existing.window.frame == screen.frame {
            return existing
        }
        hosts[key]?.window.orderOut(nil)
        let host = OverlayHost(screen: screen, state: state)
        host.window.alphaValue = 0
        host.window.orderFrontRegardless()
        host.window.displayIfNeeded()
        host.window.orderOut(nil)
        host.window.alphaValue = 1
        hosts[key] = host
        return host
    }

    public func showOverlay(onScreens screens: [NSScreen], state: PerryCursorState) {
        let start = CFAbsoluteTimeGetCurrent()
        supervisorState = state
        state.overlayVisible = true

        let wanted = Set(screens.map { ObjectIdentifier($0) })
        for (key, host) in hosts where !wanted.contains(key) {
            host.window.orderOut(nil)
        }
        for screen in screens {
            host(for: screen, state: state).window.orderFrontRegardless()
        }

        OverlayPerfProbe.shared.reset()
        DispatchQueue.main.async { [weak self] in
            // First presentation opportunity after ordering the windows.
            self?.onSample?("overlay.first_frame_ms", "ms", (CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        emitStallSample()
    }

    public func hideOverlay() {
        let start = CFAbsoluteTimeGetCurrent()
        supervisorState?.overlayVisible = false
        for host in hosts.values {
            host.window.orderOut(nil)
        }
        supervisorState = nil
        emitFrameIntervalSamples()
        emit("overlay.cleanup_ms", value: (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    /// Fades out overlay windows over `duration` seconds, then orders them
    /// out. Hosts stay alive for the next invocation.
    public func fadeOutAndHideOverlay(duration: TimeInterval = 0.24) {
        let start = CFAbsoluteTimeGetCurrent()
        supervisorState?.overlayVisible = false
        let windowsToFade = hosts.values.map(\.window)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: { [weak self] in
            for window in windowsToFade {
                window.orderOut(nil)
                window.alphaValue = 1
            }
            self?.emitFrameIntervalSamples()
            self?.emit("overlay.fade_cleanup_ms", value: (CFAbsoluteTimeGetCurrent() - start) * 1000)
            self?.emitStallSample()
        })
    }

    private func emit(_ metricID: String, value: Double) {
        onSample?(metricID, "ms", value)
    }

    private func emitFrameIntervalSamples() {
        let intervals = OverlayPerfProbe.shared.drain()
        guard !intervals.isEmpty else { return }
        emit("overlay.frame_interval_ms", value: intervals.reduce(0, +) / Double(intervals.count))
        if let worst = intervals.max() {
            emit("overlay.frame_interval_max_ms", value: worst)
        }
    }

    /// Round-trip through a background queue onto main: the hop latency is a
    /// cheap proxy for main-thread stalls while the overlay is up.
    private func emitStallSample() {
        guard onSample != nil else { return }
        let queued = CFAbsoluteTimeGetCurrent()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            DispatchQueue.main.async {
                self?.emit("overlay.main_thread_stall_ms", value: (CFAbsoluteTimeGetCurrent() - queued) * 1000)
            }
        }
    }

    public func isShowingOverlay() -> Bool {
        return hosts.values.contains { $0.window.isVisible }
    }

    private func refreshOverlayWindowsForCurrentScreens() {
        // Drop hosts for detached displays; a changed frame is refit on
        // the next host(for:) call inside showOverlay.
        let live = Set(NSScreen.screens.map { ObjectIdentifier($0) })
        for (key, host) in hosts where !live.contains(key) {
            host.window.orderOut(nil)
            host.window.contentView = nil
            hosts[key] = nil
        }
        guard let state = supervisorState else { return }
        showOverlay(onScreens: NSScreen.screens, state: state)
    }
}
