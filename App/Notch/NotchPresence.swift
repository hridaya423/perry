import AppKit
import Combine
import PerryOverlay
import SwiftUI

@MainActor
final class NotchPresence {
    enum Surface: Equatable {
        case resting
        case peeking
        case open
    }

    private weak var home: HomeController?
    private(set) var surface: Surface = .resting
    private var accepting = true
    private var resumeMonitoring = false
    private var intent = HomeHoverIntent()
    private var monitors: [Any] = []
    private var deadlineTimer: Timer?
    private var insideZone = false
    private var cachedZones: [CGRect]?
    private var cachedEnabled: Bool?
    private var screenObserver: (any NSObjectProtocol)?
    private var defaultsObserver: (any NSObjectProtocol)?
    private var dotPanels: [NSPanel] = []
    let eyes = NotchEyesModel()
    var moodObservation: AnyCancellable?

    var onPreviewConversation: (() -> Void)?
    var previewFrame: (() -> CGRect?)?
    var onEndPreview: (() -> Bool)?
    var onFocusPeek: (() -> Void)?
    var onDismissConversation: (() -> Bool)?

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(home: HomeController) {
        self.home = home
    }

    var isEnabled: Bool {
        if let cachedEnabled { return cachedEnabled }
        let enabled = PerryPreferences.notchStatusEnabled
        cachedEnabled = enabled
        return enabled
    }

    // MARK: - Lifecycle

    func start() {
        guard monitors.isEmpty else { return }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cachedZones = nil }
        }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cachedEnabled = nil }
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.pointerMoved()
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.pointerMoved()
            return event
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.mouseDown()
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.engaged()
            self?.mouseDown()
            return event
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.keyDown(event)
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if ShortcutRecorder.recording { return event }
            if event.keyCode == 53, event.window?.performKeyEquivalent(with: event) == true {
                return nil
            }
            if event.keyCode != 53 { self?.engaged() }
            self?.keyDown(event)
            return event
        } as Any)
        showRestingDotIfNeeded()
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
        for observer in [screenObserver, defaultsObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        screenObserver = nil
        defaultsObserver = nil
        cachedEnabled = nil
        cachedZones = nil
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        eyes.stop()
        dotPanels.forEach { $0.orderOut(nil) }
        insideZone = false
        intent = HomeHoverIntent()
    }

    func suspend() {
        accepting = false
        resumeMonitoring = !monitors.isEmpty
        stop()
    }

    func resume() {
        accepting = true
        if resumeMonitoring { start() }
        resumeMonitoring = false
    }

    private func currentZones() -> [CGRect]? {
        guard accepting, isEnabled else { return nil }
        if let cachedZones { return cachedZones }
        let zones = NSScreen.screens.map { NotchGeometry(screen: $0).zone }
        cachedZones = zones
        return zones
    }

    // MARK: - Pointer and keys

    private func pointerMoved() {
        guard let zones = currentZones() else {
            if insideZone { insideZone = false; apply(intent.exited(at: now)) }
            return
        }
        let point = NSEvent.mouseLocation
        let overPeek = surface == .peeking && previewFrame?()?.contains(point) == true
        let inside = zones.contains { $0.contains(point) } || overPeek
        if overPeek { onFocusPeek?() }
        if inside && !insideZone {
            insideZone = true
            eyes.hover(true)
            PerfMark.mark("notch.hover_enter")
            apply(intent.entered(at: now))
        } else if !inside && insideZone {
            insideZone = false
            eyes.hover(false)
            apply(intent.exited(at: now))
        }
    }

    private func mouseDown() {
        let point = NSEvent.mouseLocation
        guard currentZones() != nil,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              NotchGeometry(screen: screen).clickRect.contains(point) else { return }
        if surface == .open { return }
        openConversation()
    }

    private func openConversation() {
        guard accepting else { return }
        if surface == .peeking { surface = .open }
        apply(intent.escape())
        home?.onOpenConversation?()
    }

    private func engaged() {
        guard surface == .peeking else { return }
        surface = .open
        apply(intent.escape())
    }

    private func endPreview() {
        guard surface == .peeking else { return }
        surface = .open
        _ = onEndPreview?()
    }

    private func keyDown(_ event: NSEvent) {
        if event.keyCode == 53 {
            if onDismissConversation?() == true { return }
            if surface != .resting {
                home?.closeHome()
            } else {
                apply(intent.escape())
            }
            return
        }
        if event.keyCode == 49 {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) && flags.contains(.control)
                && !flags.contains(.option) && !flags.contains(.shift) {
                if surface != .resting { home?.closeHome() } else { home?.openHome() }
            }
        }
    }

    private func apply(_ action: HomeHoverIntent.Action) {
        switch action {
        case .showPeek: showPeek()
        case .hidePeek: endPreview()
        case .none: break
        }
        rescheduleDeadline()
    }

    private func rescheduleDeadline() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard let deadline = intent.pendingDeadline else { return }
        let delay = max(0, deadline - now)
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.apply(self.intent.deadlineReached(at: self.now))
            }
        }
        timer.tolerance = 0
        deadlineTimer = timer
    }

    // MARK: - Panels

    private func showRestingDotIfNeeded() {
        guard isEnabled, dotPanels.isEmpty else { return }
        dotPanels = NSScreen.screens.map(makeEyesPanel(on:))
        dotPanels.forEach { $0.orderFrontRegardless() }
        eyes.start()
    }

    private func makeEyesPanel(on screen: NSScreen) -> NSPanel {
        let geometry = NotchGeometry(screen: screen)
        let notch = geometry.housing
        let height = notch?.height ?? max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        let pad = NotchEyesView.padding
        let width = (notch?.width ?? 150) + 4 + NotchEyesView.wing * 2 + NotchShape.closed.topRadius * 2 + pad * 2
        let frame = CGRect(x: geometry.centerX - width / 2, y: screen.frame.maxY - height - pad, width: width, height: height + pad)
        let panel = PerryPanel(frame: frame)
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: NotchEyesView(model: eyes, notch: notch, height: height))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    private func showPeek() {
        guard accepting, surface == .resting, PerryPreferences.notchHoverPeek else { return }
        surface = .peeking
        onPreviewConversation?()
    }

    func setConversationVisible(_ visible: Bool) {
        if visible {
            if surface != .peeking {
                surface = .open
                apply(intent.escape())
            }
            for panel in dotPanels where panel.isVisible {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.08
                    panel.animator().alphaValue = 0
                } completionHandler: {
                    MainActor.assumeIsolated {
                        guard self.surface != .resting else { return }
                        panel.orderOut(nil)
                        panel.alphaValue = 1
                    }
                }
            }
        } else {
            surface = .resting
            if isEnabled {
                showRestingDotIfNeeded()
                dotPanels.forEach {
                    $0.alphaValue = 1
                    $0.orderFrontRegardless()
                }
            }
        }
    }

    func screenLayoutChanged() {
        guard accepting, !monitors.isEmpty else { return }
        apply(intent.escape())
        insideZone = false
        dotPanels.forEach { $0.orderOut(nil) }
        dotPanels = []
        if surface == .resting {
            showRestingDotIfNeeded()
        }
    }
}
