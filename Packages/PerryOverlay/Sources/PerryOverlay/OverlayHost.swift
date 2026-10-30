import AppKit
import SwiftUI

enum PerryOverlaySpace {
    static func besideCursor(_ local: CGPoint) -> CGPoint {
        CGPoint(x: local.x + 20, y: local.y + 24)
    }

    static func characterCenter(pointingAt local: CGPoint, size: CGFloat) -> CGPoint {
        CGPoint(x: local.x - PerryBodyShape.tip.x * size, y: local.y - PerryBodyShape.tip.y * size)
    }

    static func localPoint(_ screenPoint: CGPoint, in screenFrame: CGRect) -> CGPoint {
        CGPoint(
            x: screenPoint.x - screenFrame.origin.x,
            y: (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        )
    }

    static func localRect(_ rect: CGRect, in screenFrame: CGRect) -> CGRect {
        let topLeft = localPoint(CGPoint(x: rect.minX, y: rect.maxY), in: screenFrame)
        return CGRect(x: topLeft.x, y: topLeft.y, width: rect.width, height: rect.height)
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

        self.isOpaque = false
        self.backgroundColor = .clear
        PerryWindowChrome.applyChrome(to: self)
        self.level = PerryWindowChrome.cursorOverlay
        self.ignoresMouseEvents = true
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        self.hidesOnDeactivate = false

        self.setFrame(screen.frame, display: true)

        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

private final class OverlayHost {
    let window: OverlayWindow
    let hostingView: NSHostingView<PerryOverlaySurface>
    let boundState: PerryCursorState

    init(screen: NSScreen, state: PerryCursorState) {
        let window = OverlayWindow(screen: screen)
        let rootView = PerryOverlaySurface(screenFrame: screen.frame, cursorState: state)
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

    public func warmRenderPipeline(state: PerryCursorState) {
        for screen in NSScreen.screens {
            _ = host(for: screen, state: state)
        }
    }

    private func host(for screen: NSScreen, state: PerryCursorState) -> OverlayHost {
        let key = ObjectIdentifier(screen)
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
            self?.onSample?("overlay.first_frame_ms", "ms", (CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        emitStallSample()
    }

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
