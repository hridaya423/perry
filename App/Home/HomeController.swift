import AppKit
import Combine
import SwiftUI
import PerryBrain

/// Notch Home (Phase 5 §4.7): a resting strip in the notch, a hover peek,
/// and the full Home window. Event-driven only — pointer position arrives
/// through NSEvent monitors, and dwell/tuck run on a single deadline timer
/// owned by `HomeHoverIntent`. The strip stays invisible on notched Macs
/// (dead space beside the camera) and renders as a slim dot below the menu
/// bar on Macs without a notch.
@MainActor
final class HomeController {
    static let homeFrameKey = "perry.home.frame"

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: NotchStatusController.enabledKey) as? Bool ?? true }
    }

    private var intent = HomeHoverIntent()
    private var monitors: [Any] = []
    private var deadlineTimer: Timer?
    private var insideZone = false
    private var peekPanel: NSPanel?
    private let peekView = HomePeekView()
    private var dotPanel: NSPanel?
    /// Internal (not private) so tests can assert the window is key-capable
    /// and resizable — the properties the deleted panels were tested for.
    var homeWindow: NSWindow?
    private let homeModel = HomeModel()

    private var peekContent = HomePeekContent()
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var threadStore: ThreadStore?
    /// `(threadID, prompt) -> answer`. Runs the agent loop when the owner
    /// wires it; the turn is persisted by `onSend` below.
    var answerProvider: ((UUID, String) async throws -> String)?

    /// Owner binds the coordinator's running set → composer's working row.
    func bindWorkingThreads(_ publisher: some Publisher<Set<UUID>, Never>) -> AnyCancellable {
        publisher
            .receive(on: DispatchQueue.main)
            .assign(to: \.workingThreads, on: homeModel)
    }

    // MARK: - Lifecycle

    func start() {
        guard monitors.isEmpty else { return }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in self?.pointerMoved() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.pointerMoved()
            return event
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in self?.mouseDown() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.mouseDown()
            return event
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.keyDown(event) }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        hidePeek()
        dotPanel?.orderOut(nil)
        homeWindow?.close()
        insideZone = false
        intent = HomeHoverIntent()
    }

    // MARK: - Content

    /// Status pill contents feed the peek's agent/unread rows.
    func updateStatus(isRecording: Bool, agentLines: [String], unreadCount: Int) {
        var lines = agentLines
        if isRecording { lines.insert("Recording a demonstration", at: 0) }
        peekContent.agentLines = lines
        peekContent.unreadCount = unreadCount
        peekView.update(peekContent)
    }

    func updatePinnedPerrys(_ names: [String]) {
        peekContent.pinnedPerryNames = names
        homeModel.perryNames = names
        peekView.update(peekContent)
    }

    func noteAnswer(_ text: String) {
        peekContent.lastAnswer = text
        peekView.update(peekContent)
    }

    // MARK: - Zone geometry

    /// The hover strip: on a notched screen, the dead space beside/under the
    /// camera (auxiliary areas bracket the notch); otherwise a small zone
    /// around the resting dot below the menu bar.
    nonisolated static func zoneRect(for screen: NSScreen) -> CGRect {
        let top = screen.frame.maxY
        if screen.safeAreaInsets.top > 0 {
            let left = screen.auxiliaryTopLeftArea?.maxX ?? screen.frame.midX - 100
            let right = screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX + 100
            let center = (left + right) / 2
            let width = max(220, right - left + 40)
            return CGRect(x: center - width / 2,
                          y: top - screen.safeAreaInsets.top - 8,
                          width: width,
                          height: screen.safeAreaInsets.top + 8)
        }
        // Pill fallback: slim dot just below the menu bar, top-center.
        return CGRect(x: screen.frame.midX - 20, y: top - 24 - 14, width: 40, height: 14)
    }

    private func currentZone() -> CGRect? {
        guard isEnabled else { return nil }
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
        guard let screen else { return nil }
        var zone = Self.zoneRect(for: screen)
        // While the peek is open the zone grows to include it, so sliding
        // the pointer down into the peek keeps it open.
        if let peek = peekPanel, peek.isVisible {
            zone = zone.union(peek.frame)
        }
        return zone
    }

    private func pointerMoved() {
        guard isEnabled, let zone = currentZone() else {
            if insideZone { insideZone = false; apply(intent.exited(at: now)) }
            return
        }
        let inside = zone.contains(NSEvent.mouseLocation)
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
        guard isEnabled, let zone = currentZone() else { return }
        if zone.contains(NSEvent.mouseLocation) {
            openHome()
        }
    }

    private func keyDown(_ event: NSEvent) {
        if event.keyCode == 53 {
            if homeWindow?.isVisible == true {
                closeHome()
            } else {
                apply(intent.escape())
            }
            return
        }
        // ⌃⌘Space toggles full Home (§4.7).
        if event.keyCode == 49 {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) && flags.contains(.control)
                && !flags.contains(.option) && !flags.contains(.shift) {
                if homeWindow?.isVisible == true { closeHome() } else { openHome() }
            }
        }
    }

    private func apply(_ action: HomeHoverIntent.Action) {
        switch action {
        case .showPeek: showPeek()
        case .hidePeek: hidePeek()
        case .none: break
        }
        rescheduleDeadline()
    }

    private func rescheduleDeadline() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard let deadline = intent.pendingDeadline else { return }
        let delay = max(0, deadline - now)
        deadlineTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.apply(self.intent.deadlineReached(at: self.now))
            }
        }
    }

    // MARK: - Panels

    private func showRestingDotIfNeeded() {
        guard isEnabled else { return }
        let notched = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
        guard !notched else { return }
        guard dotPanel == nil, let screen = NSScreen.main else { return }
        let zone = Self.zoneRect(for: screen)
        let dot = NSPanel(
            contentRect: CGRect(x: zone.midX - 3, y: zone.midY - 3, width: 6, height: 6),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        dot.level = .statusBar
        dot.isOpaque = false
        dot.backgroundColor = .clear
        dot.hasShadow = false
        dot.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.6).cgColor
        view.layer?.cornerRadius = 3
        dot.contentView = view
        dot.orderFrontRegardless()
        dotPanel = dot
    }

    private func showPeek() {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
        guard let screen else { return }
        let zone = Self.zoneRect(for: screen)
        let panel = peekPanel ?? Self.makePeekPanel(content: peekView)
        peekView.onOpenHome = { [weak self] in self?.openHome() }
        let size = peekView.fittingSize
        panel.setFrame(
            CGRect(x: zone.midX - size.width / 2,
                   y: zone.minY - 4 - size.height,
                   width: size.width, height: size.height),
            display: true
        )
        panel.contentView?.layer?.cornerRadius = 12
        peekPanel = panel
        panel.orderFrontRegardless()
        PerfMark.mark("home.peek_shown")
    }

    private func hidePeek() {
        peekPanel?.orderOut(nil)
    }

    private static func makePeekPanel(content: NSView) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let capsule = NSVisualEffectView()
        capsule.material = .popover
        capsule.state = .active
        capsule.blendingMode = .behindWindow
        capsule.wantsLayer = true
        capsule.layer?.masksToBounds = true
        capsule.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: capsule.topAnchor),
            content.bottomAnchor.constraint(equalTo: capsule.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: capsule.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: capsule.trailingAnchor)
        ])
        panel.contentView = capsule
        return panel
    }

    /// Services the embedded pages need — set once by AppController.
    func configure(deps: HomeModel.Deps) {
        homeModel.deps = deps
    }

    // MARK: - Full Home

    func openHome(selection: HomeModel.Selection? = nil) {
        if let selection {
            homeModel.sidebarSelection = selection
        }
        let window = homeWindow ?? makeHomeWindow()
        homeWindow = window
        Task { await refreshThreads() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        apply(intent.setHomeOpen(true))
        PerfMark.mark("home.opened")
    }

    func closeHome() {
        homeWindow?.close()
    }

    private func makeHomeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Perry Home"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HomeView(model: homeModel))
        if let saved = UserDefaults.standard.string(forKey: Self.homeFrameKey) {
            window.setFrame(from: saved)
        } else {
            window.center()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let window = self.homeWindow else { return }
                UserDefaults.standard.set(window.frameDescriptor, forKey: Self.homeFrameKey)
                _ = self.intent.setHomeOpen(false)
            }
        }
        homeModel.onSend = { [weak self] threadID, text in
            guard let self else { return }
            Task {
                var answer = ""
                if let provider = self.answerProvider {
                    answer = (try? await provider(threadID, text)) ?? ""
                }
                _ = await self.threadStore?.appendTurn(to: threadID, question: text, answer: answer)
                await self.refreshThreads()
            }
        }
        homeModel.onDraftChanged = { [weak self] id, draft in
            guard let self else { return }
            Task { await self.threadStore?.setDraft(draft, for: id) }
        }
        return window
    }

    @MainActor
    private func refreshThreads() async {
        homeModel.threads = await threadStore?.list() ?? []
    }
}
