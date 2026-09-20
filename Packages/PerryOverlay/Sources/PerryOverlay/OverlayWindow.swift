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

struct SizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct AgentTaskBubbleSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.

enum BuddyNavigationMode {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
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
    @State private var welcomeTypingTimer: Timer?
    /// High-priority background timer that drives cursor tracking. Held
    /// as a strong reference so the source isn't deallocated mid-tick.
    /// We sample on a `userInteractive` queue (not @MainActor) so the
    /// buddy stays smooth even when the main thread is busy with SwiftUI
    /// animation work or LLM streaming. Hops to main only when the cursor
    /// has actually moved.
    @State private var cursorTrackingTimer: DispatchSourceTimer?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var agentTaskBubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0

    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    @State private var navigationAnimationTimer: Timer?

    @State private var buddyFlightScale: CGFloat = 1.0

    @State private var navigationBubbleScale: CGFloat = 1.0

    @State private var isReturningToCursor: Bool = false

    @State private var petAnimationState: PerryBuddyAnimationState = .idle

    @State private var lastDirectionSampleX: CGFloat = 0
    @State private var lastRunningRowFlipAt: Date = .distantPast

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

    private var cursorFollowAnimation: Animation? {
        buddyNavigationMode == .followingCursor ? .linear(duration: 1.0 / 120.0) : nil
    }

    private let fullWelcomeMessage = "hey! i'm Perry"
    private var captionBubbleBackgroundColor: Color { PerryOverlayTheme.Colors.captionSurface }
    private var captionBubbleTextColor: Color { PerryOverlayTheme.Colors.captionText }
    private var captionBubbleShadowColor: Color { PerryOverlayTheme.Colors.shadow }
    private var normalizedVoiceResponseCaptionOpacity: Double {
        min(max(voiceResponseCaptionOpacity, 0.55), 1.0)
    }

    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!"
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)

            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(captionBubbleTextColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(captionBubbleBackgroundColor)
                            .shadow(color: captionBubbleShadowColor, radius: 6, x: 0, y: 2)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(cursorFollowAnimation, value: cursorPosition)
                    .animation(PerryOverlayTheme.Motion.entrance, value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(captionBubbleTextColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(captionBubbleBackgroundColor)
                            .shadow(
                                color: captionBubbleShadowColor.opacity(0.8 + (1.0 - navigationBubbleScale) * 0.2),
                                radius: 6 + (1.0 - navigationBubbleScale) * 10,
                                x: 0, y: 2
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (navigationBubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(cursorFollowAnimation, value: cursorPosition)
                    .animation(PerryOverlayTheme.Motion.travel, value: navigationBubbleScale)
                    .animation(PerryOverlayTheme.Motion.entrance, value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            if let externalPrimaryCaption = cursorState.externalPrimaryCaptionText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !externalPrimaryCaption.isEmpty,
               buddyIsVisibleOnThisScreen {
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
                    .animation(cursorFollowAnimation, value: cursorPosition)
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
                    PerryGlassCursorView(animation: petAnimationState, size: 52)
                }
            }
                .frame(
                    width: isCalibrationCursorBoxActive ? 38 : 48,
                    height: isCalibrationCursorBoxActive ? 38 : 52
                )
                .scaleEffect(buddyFlightScale)
                .opacity(buddyIsVisibleOnThisScreen && (cursorState.voiceState == .idle || cursorState.voiceState == .responding) ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? PerryOverlayTheme.Motion.travel
                        : nil,
                    value: cursorPosition
                )
                .animation(PerryOverlayTheme.Motion.feedback, value: cursorState.voiceState)
                .onChange(of: cursorPosition) { _, newPos in
                    updatePetAnimationStateForCursorMotion(toX: newPos.x)
                }
                .onChange(of: buddyNavigationMode) { _, _ in
                    updatePetAnimationStateForCursorMotion(toX: cursorPosition.x)
                }
                .onChange(of: cursorState.voiceState) { _, _ in
                    updatePetAnimationStateForCursorMotion(toX: cursorPosition.x)
                }
                .onChange(of: cursorState.animation) { _, animation in
                    setPetAnimationState(animation)
                }

            PerryWaveformView(
                audioPowerLevel: cursorState.currentAudioPowerLevel,
                cursorColor: PerryOverlayTheme.Colors.accent,
                isActive: buddyIsVisibleOnThisScreen && cursorState.voiceState == .listening
            )
                .opacity(buddyIsVisibleOnThisScreen && cursorState.voiceState == .listening ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(cursorFollowAnimation, value: cursorPosition)
                .animation(PerryOverlayTheme.Motion.feedback, value: cursorState.voiceState)

            PerrySpinnerView(
                cursorColor: PerryOverlayTheme.Colors.accent,
                isActive: buddyIsVisibleOnThisScreen && cursorState.voiceState == .processing
            )
                .opacity(buddyIsVisibleOnThisScreen && cursorState.voiceState == .processing ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(cursorFollowAnimation, value: cursorPosition)
                .animation(PerryOverlayTheme.Motion.feedback, value: cursorState.voiceState)

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

            startTrackingCursor()
            DispatchQueue.main.async {
                startNavigatingToCurrentDetectedLocationIfNeeded()
            }

            self.cursorOpacity = 1.0
        }
        .onDisappear {
            welcomeTypingTimer?.invalidate()
            cursorTrackingTimer?.cancel()
            cursorTrackingTimer = nil
            navigationAnimationTimer?.invalidate()
        }
        .onChange(of: cursorState.detectedElementScreenLocation) { _, newLocation in
            guard newLocation != nil else {
                resetNavigationStateAndResumeFollowing()
                return
            }
            startNavigatingToCurrentDetectedLocationIfNeeded()
        }
    }

    private func startNavigatingToCurrentDetectedLocationIfNeeded() {
        guard let screenLocation = cursorState.detectedElementScreenLocation,
              let displayFrame = cursorState.detectedElementDisplayFrame else {
            return
        }

        guard displayFrame.intersects(screenFrame) || screenFrame.contains(screenLocation) else {
            return
        }

        startNavigatingToElement(screenLocation: screenLocation)
    }

    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            if cursorState.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    private var shouldShowAgentTaskBubble: Bool {
        buddyIsVisibleOnThisScreen
            && buddyNavigationMode == .followingCursor
            && !showWelcome
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
            }

            if let caption = overlay.style.caption?.trimmingCharacters(in: .whitespacesAndNewlines),
               !caption.isEmpty {
                externalCaption(caption, at: captionAnchor(for: overlay), color: color)
            }
        }
        .transition(accessibilityReduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
        .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.18), value: overlay.id)
        .allowsHitTesting(false)
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
        if let rect = overlay.rect?.normalized.cgRect {
            let localRect = convertScreenRectToSwiftUICoordinates(rect)
            PerryGuidanceRectangleView(
                color: color,
                lineWidth: CGFloat(overlay.style.lineWidth),
                fillOpacity: overlay.style.fillOpacity,
                drawingDuration: min(0.95, max(0.38, overlay.duration * 0.22)),
                reduceMotion: accessibilityReduceMotion
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
            PerryGlassCursorView(size: 30)
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
        .position(x: bubblePosition.x, y: bubblePosition.y)
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
        cursorTrackingTimer?.cancel()

        let queue = DispatchQueue(label: "dev.perry.perry.cursor.tracker", qos: .userInteractive)
        let dispatchTimer = DispatchSource.makeTimerSource(queue: queue)
        dispatchTimer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(3))
        var lastSampledPoint: CGPoint = .zero
        var updateQueuedOnMain = false

        dispatchTimer.setEventHandler {
            let mouseLocation = NSEvent.mouseLocation
            guard mouseLocation != lastSampledPoint else { return }
            lastSampledPoint = mouseLocation

            guard !updateQueuedOnMain else { return }
            updateQueuedOnMain = true

            DispatchQueue.main.async {
                updateCursorTracking()
                queue.async {
                    updateQueuedOnMain = false
                }
            }
        }
        dispatchTimer.resume()
        cursorTrackingTimer = dispatchTimer
    }

    private func updateCursorTracking() {
        OverlayPerfProbe.shared.tick()
        guard buddyIsVisibleOnThisScreen else { return }
        let mouseLocation = NSEvent.mouseLocation
        isCursorOnThisScreen = screenFrame.contains(mouseLocation)

        if buddyNavigationMode == .navigatingToTarget && isReturningToCursor {
            let currentMouseInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
            let distanceFromNavigationStart = hypot(
                currentMouseInSwiftUI.x - cursorPositionWhenNavigationStarted.x,
                currentMouseInSwiftUI.y - cursorPositionWhenNavigationStarted.y
            )
            if distanceFromNavigationStart > 100 {
                cancelNavigationAndResumeFollowing()
            }
            return
        }

        if buddyNavigationMode != .followingCursor {
            return
        }

        let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let buddyX = swiftUIPosition.x + 35
        let buddyY = swiftUIPosition.y + 25
        cursorPosition = CGPoint(x: buddyX, y: buddyY)

        updatePetAnimationStateForCursorMotion(toX: buddyX)
    }

    private func updatePetAnimationStateForCursorMotion(toX newX: CGFloat) {
        if cursorState.animation != .idle {
            setPetAnimationState(cursorState.animation)
            lastDirectionSampleX = newX
            return
        }

        if cursorState.voiceState == .processing {
            setPetAnimationState(.review)
            lastDirectionSampleX = newX
            return
        }
        if buddyNavigationMode == .pointingAtTarget {
            setPetAnimationState(.waving)
            lastDirectionSampleX = newX
            return
        }

        let dx = newX - lastDirectionSampleX
        let now = Date()
        let deadZone: CGFloat = 1.5
        let minDwell: TimeInterval = 0.08
        let isFlying = buddyNavigationMode == .navigatingToTarget

        if abs(dx) < deadZone {
            if isFlying {
                if petAnimationState != .running {
                    setPetAnimationState(.running)
                }
            } else if now.timeIntervalSince(lastRunningRowFlipAt) > 0.6 {
                setPetAnimationState(.idle)
            }
        } else {
            let desired: PerryBuddyAnimationState = dx > 0 ? .runningRight : .runningLeft
            if desired != petAnimationState,
               now.timeIntervalSince(lastRunningRowFlipAt) > minDwell {
                setPetAnimationState(desired)
                lastRunningRowFlipAt = now
            }
        }
        lastDirectionSampleX = newX
    }

    private func setPetAnimationState(_ next: PerryBuddyAnimationState) {
        if petAnimationState != next {
            petAnimationState = next
        }
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        guard !showWelcome || welcomeText.isEmpty else { return }

        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x + 8,
            y: targetInSwiftUI.y + 12
        )

        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        animateBezierFlightArc(to: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    private func animateBezierFlightArc(
        to destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()
        if accessibilityReduceMotion {
            cursorPosition = destination
            buddyFlightScale = 1
            onComplete()
            return
        }

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        let flightDurationSeconds: Double
        if cursorState.detectedElementReturnsImmediately {
            flightDurationSeconds = min(max(distance / 1800.0, 0.32), 0.58)
        } else {
            flightDurationSeconds = min(max(distance / 800.0, 0.6), 1.4)
        }
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        var currentFrame = 0

        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        let animationTimer = Timer(timeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            let linearProgress = Double(currentFrame) / Double(totalFrames)

            let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * t * controlPoint.x
                        + t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * t * controlPoint.y
                        + t * t * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)

            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.3
        }
        navigationAnimationTimer = animationTimer
        RunLoop.main.add(animationTimer, forMode: .common)
    }

    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget

        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        if cursorState.detectedElementReturnsImmediately {
            navigationBubbleOpacity = 0.0
            navigationBubbleScale = 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.startFlyingBackToCursor()
            }
            return
        }

        let pointerPhrase = cursorState.detectedElementBubbleText
            ?? navigationPointerPhrases.randomElement()
            ?? "right here!"

        streamNavigationBubbleCharacter(phrase: pointerPhrase, characterIndex: 0) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.buddyNavigationMode == .pointingAtTarget else { return }
                    self.startFlyingBackToCursor()
                }
            }
        }
    }

    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget else { return }
        if accessibilityReduceMotion {
            navigationBubbleText = phrase
            onComplete()
            return
        }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    private func startFlyingBackToCursor() {
        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorWithTrackingOffset = CGPoint(x: cursorInSwiftUI.x + 35, y: cursorInSwiftUI.y + 25)

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: cursorWithTrackingOffset) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        buddyFlightScale = 1.0
        finishNavigationAndResumeFollowing()
    }

    private func finishNavigationAndResumeFollowing() {
        resetNavigationStateAndResumeFollowing()
        supervisorState.clearDetectedElementLocation()
    }

    private func resetNavigationStateAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        updateCursorTracking()
    }

    // MARK: - Welcome Animation

    private func startWelcomeAnimation() {
        withAnimation(PerryOverlayTheme.Motion.entrance) {
            self.bubbleOpacity = 1.0
        }

        var currentIndex = 0
        let typingTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < fullWelcomeMessage.count else {
                timer.invalidate()
                welcomeTypingTimer = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    showWelcome = false
                }
                return
            }

            let index = fullWelcomeMessage.index(fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            welcomeText.append(fullWelcomeMessage[index])
            currentIndex += 1
        }
        welcomeTypingTimer = typingTimer
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

        ZStack(alignment: .topLeading) {
            PerrySmoothScribblePath(points: points)
                .trim(from: 0, to: clampedProgress)
                .stroke(
                    color,
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .shadow(
                    color: color.opacity(reduceMotion ? 0.30 : 0.68),
                    radius: reduceMotion ? 2 : 7,
                    x: 0,
                    y: 0
                )

            if !reduceMotion,
               let cursorPoint = PerrySmoothScribblePath.point(on: points, progress: clampedProgress),
               clampedProgress < 0.995 {
                PerryGlassCursorView(size: 24, variant: .faceted)
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

    @State private var drawProgress: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let clampedProgress = min(max(drawProgress, 0), 1)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(color.opacity(fillOpacity * Double(clampedProgress)))

                PerryTopLeftRectangleOutline()
                    .trim(from: 0, to: clampedProgress)
                    .stroke(
                        color,
                        style: StrokeStyle(
                            lineWidth: lineWidth,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: [lineWidth * 2.4, lineWidth * 1.7]
                        )
                    )
                    .shadow(
                        color: color.opacity(reduceMotion ? 0.30 : 0.70),
                        radius: reduceMotion ? 2 : 9,
                        x: 0,
                        y: 0
                    )

                if !reduceMotion && clampedProgress < 0.995 {
                    PerryGlassCursorView(size: 24, variant: .faceted)
                        .shadow(color: color.opacity(0.65), radius: 6, x: 0, y: 0)
                        .position(
                            x: max(0, min(size.width, size.width * clampedProgress)),
                            y: max(0, min(size.height, size.height * clampedProgress))
                        )
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

private struct PerryTopLeftRectangleOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return path
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

private struct PerrySpinnerView: View {
    let cursorColor: Color
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        cursorColor.opacity(0.0),
                        cursorColor
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning && isActive ? 360 : 0))
            .shadow(color: cursorColor.opacity(0.6), radius: 6, x: 0, y: 0)
            .onAppear {
                updateSpinning()
            }
            .onChange(of: isActive) { _, _ in
                updateSpinning()
            }
            .onChange(of: reduceMotion) { _, _ in
                updateSpinning()
            }
    }

    private func updateSpinning() {
        if isActive && !reduceMotion {
            isSpinning = false
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                isSpinning = true
            }
        } else {
            withAnimation(nil) {
                isSpinning = false
            }
        }
    }
}

public class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
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

    public func showOverlay(onScreens screens: [NSScreen], state: PerryCursorState) {
        let start = CFAbsoluteTimeGetCurrent()
        hideOverlay(clearSupervisorState: false)
        self.supervisorState = state

        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = PerryBuddyView(
                screenFrame: screen.frame,
                supervisorState: state
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = NSRect(origin: .zero, size: screen.frame.size)
            hostingView.autoresizingMask = [.width, .height]
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }

        OverlayPerfProbe.shared.reset()
        DispatchQueue.main.async { [weak self] in
            // First presentation opportunity after ordering the windows.
            self?.onSample?("overlay.first_frame_ms", "ms", (CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        emitStallSample()
    }

    public func hideOverlay() {
        hideOverlay(clearSupervisorState: true)
    }

    private func hideOverlay(clearSupervisorState clear: Bool) {
        let start = CFAbsoluteTimeGetCurrent()
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
        if clear {
            supervisorState = nil
        }
        emitFrameIntervalSamples()
        emit("overlay.cleanup_ms", value: (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    public func fadeOutAndHideOverlay(duration: TimeInterval = 0.24) {
        let start = CFAbsoluteTimeGetCurrent()
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: { [weak self] in
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
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
        return !overlayWindows.isEmpty
    }

    private func refreshOverlayWindowsForCurrentScreens() {
        guard !overlayWindows.isEmpty, let state = supervisorState else { return }
        showOverlay(onScreens: NSScreen.screens, state: state)
    }
}
