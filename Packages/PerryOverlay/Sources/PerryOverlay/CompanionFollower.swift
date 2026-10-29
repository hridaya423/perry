import AppKit
import Combine
import SwiftUI

/// One screen's overlay surface: owns cursor tracking and composes the
/// ink, glow, ghost, caption, and follower layers in draw order.
struct PerryOverlaySurface: View {
    let screenFrame: CGRect
    @ObservedObject var cursorState: PerryCursorState

    @StateObject private var pointer: OverlayPointer

    init(screenFrame: CGRect, cursorState: PerryCursorState) {
        self.screenFrame = screenFrame
        self.cursorState = cursorState
        _pointer = StateObject(wrappedValue: OverlayPointer(screenFrame: screenFrame))
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

            InkLayer(state: cursorState, screenFrame: screenFrame, pointer: pointer)

            PointerRiders(cursorState: cursorState, pointer: pointer, screenFrame: screenFrame, opacity: cursorOpacity)
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
        pointer.snap()
        startTrackingCursor()
        cursorOpacity = 1.0
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
        pointer.follow(NSEvent.mouseLocation)
    }

}

@MainActor
final class OverlayPointer: ObservableObject {
    let screenFrame: CGRect
    @Published private(set) var position: CGPoint
    @Published private(set) var onScreen: Bool

    init(screenFrame: CGRect) {
        self.screenFrame = screenFrame
        let location = NSEvent.mouseLocation
        position = PerryOverlaySpace.besideCursor(PerryOverlaySpace.localPoint(location, in: screenFrame))
        onScreen = screenFrame.contains(location)
    }

    func snap() {
        let location = NSEvent.mouseLocation
        onScreen = screenFrame.contains(location)
        position = PerryOverlaySpace.besideCursor(PerryOverlaySpace.localPoint(location, in: screenFrame))
    }

    func follow(_ location: CGPoint) {
        let inside = screenFrame.contains(location)
        if inside != onScreen { onScreen = inside }
        guard inside else { return }
        let next = PerryOverlaySpace.besideCursor(PerryOverlaySpace.localPoint(location, in: screenFrame))
        guard abs(next.x - position.x) >= 0.5 || abs(next.y - position.y) >= 0.5 else { return }
        position = next
    }
}

private struct PointerRiders: View {
    @ObservedObject var cursorState: PerryCursorState
    @ObservedObject var pointer: OverlayPointer
    let screenFrame: CGRect
    let opacity: Double

    var body: some View {
        TaskBubbleLayer(
            state: cursorState,
            screenFrame: screenFrame,
            anchor: pointer.position,
            isVisible: followerIsVisibleOnThisScreen && !pointerIsOverPanel,
            opacity: opacity
        )
        .animation(PerryOverlayTheme.Motion.feedback, value: pointerIsOverPanel)

        CompanionFollower(
            cursorState: cursorState,
            screenFrame: screenFrame,
            position: followerPosition,
            isVisible: followerIsVisibleOnThisScreen && (isParked || !pointerIsOverPanel),
            opacity: opacity
        )
    }

    private var pointerIsOverPanel: Bool {
        cursorState.panelScreenFrame?.contains(NSEvent.mouseLocation) == true
    }

    private var isParked: Bool {
        cursorState.detectedElementScreenLocation != nil
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
        return pointer.position
    }

    private var followerIsVisibleOnThisScreen: Bool {
        if let screenLocation = cursorState.detectedElementScreenLocation {
            return cursorState.detectedElementDisplayFrame?.intersects(screenFrame) == true
                || screenFrame.contains(screenLocation)
        }
        return pointer.onScreen
    }
}

struct CompanionFollower: View {
    @ObservedObject var cursorState: PerryCursorState
    let screenFrame: CGRect
    let position: CGPoint
    let isVisible: Bool
    let opacity: Double
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

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
        ZStack {
            if isCalibrationCursorBoxActive {
                PerryCalibrationBoxView(
                    color: PerryOverlayTheme.Colors.accent,
                    reduceMotion: accessibilityReduceMotion
                )
                .frame(width: 38, height: 38)
            } else if cursorState.overlayVisible && isVisible {
                PerryCharacter(
                    mood: PerryMood(voice: cursorState.voiceState, buddy: cursorState.buddyState),
                    position: position,
                    micLevel: Double(cursorState.currentAudioPowerLevel),
                    size: 24
                )
            }
        }
        .opacity(isVisible ? opacity : 0)
        .position(position)
        .animation(PerryOverlayTheme.Motion.travel, value: position)
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
