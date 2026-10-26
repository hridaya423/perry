import AppKit
import PerryOverlay

/// The expanded notch: one borderless panel pinned under the camera housing.
/// Built once, shown on invocation, and on hide hands focus back to the app
/// the user came from.
@MainActor
final class SessionPanelPresenter {
    private let makeContent: () -> NSView
    private var panel: NSPanel?
    private var previousFrontmostApplication: NSRunningApplication?

    init(makeContent: @escaping () -> NSView) {
        self.makeContent = makeContent
    }

    var frame: CGRect? { isVisible ? visibleFrame : nil }
    var isVisible: Bool { panel?.isVisible == true }
    var isKey: Bool { panel?.isKeyWindow == true }
    var screen: NSScreen?
    private var visibleFrame: CGRect?

    func show(window: NSRect, visible: NSRect, activate: Bool) {
        let panel = ensurePanel()
        place(window: window, visible: visible)
        if activate {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            if let frontmost = NSWorkspace.shared.frontmostApplication,
               frontmost.processIdentifier != ownPID {
                previousFrontmostApplication = frontmost
            }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        PerfMark.mark("panel.visible")
    }

    func place(window: NSRect, visible: NSRect) {
        visibleFrame = visible
        guard let panel, panel.frame != window else { return }
        panel.setFrame(window, display: true)
    }

    /// Pays the one-time render cost so a first invocation only orders an
    /// already-rendered window on screen.
    func warm() {
        ensurePanel().displayIfNeeded()
    }

    func hide() {
        guard let panel, isVisible else { return }
        panel.orderOut(nil)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if NSApp.isActive,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID,
           let previous = previousFrontmostApplication,
           previous.processIdentifier != ownPID {
            previous.activate()
        }
        previousFrontmostApplication = nil
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = CompactConversationPanel(
            contentRect: NSRect(x: 0, y: 0, width: PerryTheme.Sizing.panelWidth, height: PerryTheme.Sizing.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.contentView = makeContent()
        p.appearance = NSAppearance(named: .darkAqua)
        p.identifier = SessionPanelView.windowIdentifier
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        PerryWindowChrome.applyChrome(to: p)
        panel = p
        return p
    }
}

extension AppController {
    func presentPrompt(prefill: String, asTask: Bool = false) {
        pendingPromptDoMode = asTask
        pendingPromptText = prefill
        showPanel()
    }

    func showPanel() {
        showPanel(activate: true)
    }

    func showPanel(activate: Bool) {
        probe.pinInvocationTargetIfNeeded()
        homeController.prepareConversation(target: probe.presentationTarget())
        notchPresence.setConversationVisible(true)
        notchStatus.setConversationVisible(true)
        if !sessionPanel.isVisible { sessionPanel.screen = NotchPresence.screenUnderPointer() }
        let layout = notchLayout()
        sessionPanel.show(window: layout.window, visible: layout.visible, activate: activate)
        overlayState.panelScreenFrame = sessionPanel.frame
    }

    private func notchLayout() -> (window: NSRect, visible: NSRect) {
        guard let screen = sessionPanel.screen.flatMap({ NSScreen.screens.contains($0) ? $0 : nil }) ?? NotchPresence.screenUnderPointer() else { return (.zero, .zero) }
        let presentation = NotchPresentation.shared
        let window = NotchLayout.windowFrame(screen: screen.frame, centerX: NotchPresence.zoneRect(for: screen).midX)
        let size = NotchLayout.size(NotchLayout.mode(presentation), cameraInset: max(24, screen.safeAreaInsets.top), screen: screen.frame.size)
        presentation.frame = NotchLayout.visibleFrame(size, in: window)
        return (window, presentation.frame)
    }

    func presentConversationVoice(_ state: VoiceConversationController.State) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        switch state {
        case .requestingPermission:
            break
        case .listening:
            overlayState.buddyState = .listening
            overlayState.voiceState = .listening
            overlayState.taskBubbleText = nil
            overlayManager.showOverlay(onScreens: NSScreen.screens, state: overlayState)
            NotchPresentation.shared.dismissCurrent()
            cancelNotchConfirmations()
            hideSurfaces()
        case .thinking:
            overlayState.buddyState = .thinking
            overlayState.voiceState = .processing
            overlayState.taskBubbleText = "Working on your request"
        case .speaking:
            overlayState.buddyState = .idle
            overlayState.voiceState = .responding
            overlayState.taskBubbleText = "Speaking"
        case .idle:
            overlayState.voiceState = .idle
            overlayState.buddyState = conversationVoice.answer.isEmpty ? .idle : .success
            overlayState.taskBubbleText = conversationVoice.answer.isEmpty ? nil : "Answer ready"
        case .failed:
            overlayState.buddyState = .blocked
            overlayState.voiceState = .idle
            overlayState.taskBubbleText = nil
            showPanel(activate: false)
        }
    }

    func refreshNotchLayout() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionPanel.isVisible else { return }
            let layout = self.notchLayout()
            self.sessionPanel.place(window: layout.window, visible: layout.visible)
            self.overlayState.panelScreenFrame = self.sessionPanel.frame
        }
    }

    func collapseNotch() {
        NotchPresentation.shared.dismissCurrent()
        cancelNotchConfirmations()
        hidePanel()
    }

    func showWorkspace() {
        NotchPresentation.shared.dismissCurrent()
        cancelNotchConfirmations()
        NotchPresentation.shared.showsInteraction = false
        showPanel()
    }

    func handleScreenLayoutChanged() {
        guard !isUnderMaintenance else { return }
        if sessionPanel.isVisible {
            let layout = notchLayout()
            sessionPanel.place(window: layout.window, visible: layout.visible)
        }
        overlayState.panelScreenFrame = sessionPanel.frame
        notchPresence.screenLayoutChanged()
        notchStatus.repositionIfVisible()
    }

    /// Pays the one-time render cost for the session surfaces at launch so a
    /// first invocation only orders already-rendered windows on screen.
    func warmSessionSurfaces() {
        sessionPanel.warm()
        overlayManager.warmRenderPipeline(state: overlayState)
    }

    func hidePanel() {
        conversationVoice.cancel()
        hideSurfaces()
    }

    private func hideSurfaces() {
        sessionPanel.hide()
        overlayState.panelScreenFrame = nil
        notchPresence.setConversationVisible(false)
        notchStatus.setConversationVisible(false)
    }

    func showBackgroundTasks() {
        homeController.openHome(selection: .tasks)
    }
}
