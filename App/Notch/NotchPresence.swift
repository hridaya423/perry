import AppKit
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
    private var blinkTimer: Timer?

    var onPreviewConversation: (() -> Void)?
    var previewFrame: (() -> CGRect?)?
    var onEndPreview: (() -> Bool)?
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
            MainActor.assumeIsolated { self?.pointerMoved() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.pointerMoved()
            return event
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.mouseDown()
            return event
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.keyDown(event) }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, event.window?.performKeyEquivalent(with: event) == true {
                return nil
            }
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
        blinkTimer?.invalidate()
        blinkTimer = nil
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

    // MARK: - Zone geometry

    nonisolated static let notchEar: CGFloat = 26

    nonisolated static func zoneRect(for screen: NSScreen) -> CGRect {
        let top = screen.frame.maxY
        if screen.safeAreaInsets.top > 0 {
            let left = screen.auxiliaryTopLeftArea?.maxX ?? screen.frame.midX - 100
            let right = screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX + 100
            let center = (left + right) / 2
            let width = max(220, right - left + notchEar * 2 + 12)
            return CGRect(x: center - width / 2,
                          y: top - screen.safeAreaInsets.top - 8,
                          width: width,
                          height: screen.safeAreaInsets.top + 8)
        }
        let menuBar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return CGRect(x: screen.frame.midX - 60, y: top - menuBar, width: 120, height: menuBar)
    }

    static func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
    }

    nonisolated static func clickRect(for screen: NSScreen) -> CGRect {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea?.maxX,
              let right = screen.auxiliaryTopRightArea?.minX else { return zoneRect(for: screen) }
        return CGRect(x: left - notchEar, y: screen.frame.maxY - screen.safeAreaInsets.top,
                      width: right - left + notchEar * 2, height: screen.safeAreaInsets.top)
    }

    nonisolated static func notchPanelFrame(size: CGSize, screenFrame: CGRect, centerX: CGFloat) -> CGRect {
        let width = min(size.width, screenFrame.width)
        let height = min(size.height, screenFrame.height)
        let x = min(max(centerX - width / 2, screenFrame.minX), screenFrame.maxX - width)
        return CGRect(x: x, y: screenFrame.maxY - height, width: width, height: height)
    }

    private func currentZones() -> [CGRect]? {
        guard accepting, isEnabled else { return nil }
        if let cachedZones { return cachedZones }
        let zones = NSScreen.screens.map(Self.zoneRect(for:))
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
        let inside = zones.contains { $0.contains(point) } || (surface == .peeking && previewFrame?()?.contains(point) == true)
        if inside && !insideZone {
            insideZone = true
            PerfMark.mark("home.hover_start")
            apply(intent.entered(at: now))
        } else if !inside && insideZone {
            insideZone = false
            apply(intent.exited(at: now))
        }
    }

    private func mouseDown() {
        let point = NSEvent.mouseLocation
        guard currentZones() != nil,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              Self.clickRect(for: screen).contains(point) else { return }
        if surface == .open { return }
        openConversation()
    }

    private func openConversation() {
        guard accepting else { return }
        if surface == .peeking { surface = .open }
        apply(intent.escape())
        home?.onOpenConversation?()
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
        dotPanels = NSScreen.screens.map { Self.makeNotchEyes(on: $0) ?? Self.makeRestingTab(on: $0) }
        dotPanels.forEach { $0.orderFrontRegardless() }
        if blinkTimer == nil {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 7, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.blinkNotchEyes() }
            }
        }
    }

    private static func makeNotchEyes(on screen: NSScreen) -> NSPanel? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let ear = notchEar
        let height = screen.safeAreaInsets.top
        let frame = CGRect(x: left.maxX - ear, y: screen.frame.maxY - height, width: right.minX - left.maxX + ear * 2, height: height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        PerryWindowChrome.applyChrome(to: panel)
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(PerryTheme.Colors.crown).cgColor
        view.layer?.cornerRadius = 9
        view.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.setAccessibilityElement(false)
        var tint = NSColor.white.cgColor
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            tint = NSColor(PerryTheme.Colors.accent).cgColor
        }
        let eyeSize = CGSize(width: 3.5, height: 9)
        let eyesWidth = eyeSize.width * 2 + 4
        let originX = frame.width - ear + (ear - eyesWidth) / 2 - 2
        for index in 0..<2 {
            let eye = CALayer()
            eye.backgroundColor = tint
            eye.cornerRadius = eyeSize.width / 2
            eye.bounds = CGRect(origin: .zero, size: eyeSize)
            eye.position = CGPoint(x: originX + eyeSize.width / 2 + CGFloat(index) * (eyeSize.width + 4), y: height / 2)
            view.layer?.addSublayer(eye)
        }
        panel.contentView = view
        panel.appearance = NSAppearance(named: .darkAqua)
        return panel
    }

    private func blinkNotchEyes() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        for eye in dotPanels.filter(\.isVisible).flatMap({ $0.contentView?.layer?.sublayers ?? [] }) {
            let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
            blink.values = [1, 0.12, 1]
            blink.duration = 0.18
            eye.add(blink, forKey: "blink")
        }
    }

    private static func makeRestingTab(on screen: NSScreen) -> NSPanel {
        let size = CGSize(width: 64, height: 7)
        let tab = NSPanel(
            contentRect: CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        tab.level = .statusBar
        tab.isOpaque = false
        tab.backgroundColor = .clear
        tab.hasShadow = false
        tab.ignoresMouseEvents = true
        PerryWindowChrome.applyChrome(to: tab)
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(PerryTheme.Colors.crown).cgColor
        view.layer?.cornerRadius = size.height / 2
        view.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        tab.contentView = view
        return tab
    }

    private func showPeek() {
        guard accepting, surface == .resting else { return }
        surface = .peeking
        onPreviewConversation?()
    }

    func setConversationVisible(_ visible: Bool) {
        if visible {
            if surface != .peeking {
                surface = .open
                apply(intent.escape())
            }
            dotPanels.forEach { $0.orderOut(nil) }
        } else {
            surface = .resting
            if isEnabled {
                showRestingDotIfNeeded()
                dotPanels.forEach { $0.orderFrontRegardless() }
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
