import AppKit
import Combine
import SwiftUI

/// One screen's overlay surface: owns cursor tracking and composes the
/// ink, glow, ghost, caption, and follower layers in draw order.
struct PerryOverlaySurface: View {
    let screenFrame: CGRect
    @ObservedObject var cursorState: PerryCursorState

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, cursorState: PerryCursorState) {
        self.screenFrame = screenFrame
        self.cursorState = cursorState

        let mouseLocation = NSEvent.mouseLocation
        let local = PerryOverlaySpace.localPoint(mouseLocation, in: screenFrame)
        _cursorPosition = State(initialValue: CGPoint(x: local.x + 35, y: local.y + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    /// Event-driven cursor follow (§5): mouse-moved/dragged monitors write
    /// the position in the same turn the event arrives — no polling timer,
    /// so an idle Perry keeps zero timers ticking. The global monitor covers
    /// events aimed at other apps; the local monitor covers our own.
    @State private var cursorMoveMonitors: [Any] = []
    /// Global monitors deliver nothing without Input Monitoring — they install
    /// fine and just never fire, which used to freeze the follower silently. A
    /// 0.5 s watchdog compares `NSEvent.mouseLocation` (permission-free) with
    /// the monitor event count; movement without events means starvation, and
    /// follow switches to a permission-free poll until monitors wake.
    @State private var cursorWatchdog: Timer?
    @State private var cursorPollTimer: Timer?
    @State private var lastProbePoint: CGPoint = .zero
    @State private var monitorEventCount = 0
    @State private var stationaryPolls = 0
    @State private var cursorOpacity: Double = 0.0

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)

            ControlGlowLayer(state: cursorState, screenFrame: screenFrame)

            GhostCursorLayer(state: cursorState, screenFrame: screenFrame)

            InkLayer(state: cursorState, screenFrame: screenFrame, pointerAnchor: cursorPosition)

            TaskBubbleLayer(
                state: cursorState,
                screenFrame: screenFrame,
                anchor: cursorPosition,
                isVisible: followerIsVisibleOnThisScreen,
                opacity: cursorOpacity
            )

            CompanionFollower(
                cursorState: cursorState,
                screenFrame: screenFrame,
                position: followerPosition,
                isVisible: followerIsVisibleOnThisScreen,
                opacity: cursorOpacity
            )
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
        let swiftUIPosition = PerryOverlaySpace.localPoint(mouseLocation, in: screenFrame)
        cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

        startTrackingCursor()
        cursorOpacity = 1.0
    }

    /// Where the companion sits: parked at the detected element while one
    /// is published on this screen, otherwise riding the pointer offset.
    private var followerPosition: CGPoint {
        if let screenLocation = cursorState.detectedElementScreenLocation,
           (cursorState.detectedElementDisplayFrame?.intersects(screenFrame) == true
            || screenFrame.contains(screenLocation)) {
            let local = PerryOverlaySpace.localPoint(screenLocation, in: screenFrame)
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
        let swiftUIPosition = PerryOverlaySpace.localPoint(mouseLocation, in: screenFrame)
        cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)
    }

}

/// The companion's own visuals: a calibration box while a calibration
/// scribble is up, otherwise the living glass pointer and the listening
/// waveform riding the same position.
struct CompanionFollower: View {
    let cursorState: PerryCursorState
    let screenFrame: CGRect
    let position: CGPoint
    let isVisible: Bool
    let opacity: Double
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

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

    private var isCalibrationCursorBoxActive: Bool {
        cursorState.visualGuidanceOverlays.contains { overlay in
            guard overlay.screenBounds.intersects(screenFrame),
                  let caption = overlay.style.caption else { return false }
            let normalized = caption
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
            return normalized.contains("calibration")
                || normalized.contains("calibrate")
                || normalized.contains("anchor")
        }
    }

    var body: some View {
        // Group is layout-transparent: both pieces keep their screen-space
        // .position inside the surface's ZStack, as they did before the split.
        Group {
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
            .opacity(isVisible && (cursorState.voiceState == .idle || cursorState.voiceState == .responding) ? opacity : 0)
            .position(position)
            .animation(PerryOverlayTheme.Motion.travel, value: position)
            .animation(PerryOverlayTheme.Motion.feedback, value: cursorState.voiceState)

            PerryWaveformView(
                audioPowerLevel: cursorState.currentAudioPowerLevel,
                cursorColor: PerryOverlayTheme.Colors.accent,
                isActive: isVisible && cursorState.voiceState == .listening
            )
            .opacity(isVisible && cursorState.voiceState == .listening ? opacity : 0)
            .position(position)
            .animation(PerryOverlayTheme.Motion.feedback, value: cursorState.voiceState)
        }
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
