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

    var frame: CGRect? { isVisible ? panel?.frame : nil }
    var isVisible: Bool { panel?.isVisible == true && !hiding }
    var isKey: Bool { panel?.isKeyWindow == true }
    var screen: NSScreen?
    private var hiding = false

    private static let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func show(frame: NSRect, activate: Bool) {
        let panel = ensurePanel()
        let wasVisible = isVisible
        if hiding {
            hiding = false
            panel.contentView?.layer?.mask = nil
            panel.contentView?.layer?.removeAnimation(forKey: "collapseFade")
        }
        place(frame)
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
        if !wasVisible { morph(panel, growing: true) }
        PerfMark.mark("panel.visible")
    }

    private func morph(_ panel: NSPanel, growing: Bool, completion: (() -> Void)? = nil) {
        guard !reduceMotion, let content = panel.contentView, let screen = panel.screen else {
            completion?()
            return
        }
        content.wantsLayer = true
        guard let layer = content.layer else {
            completion?()
            return
        }
        let bounds = content.bounds
        let notchWidth = screen.frame.width - (screen.auxiliaryTopLeftArea?.width ?? 0) - (screen.auxiliaryTopRightArea?.width ?? 0)
        let notchHeight = max(screen.safeAreaInsets.top, 24)
        let width = min(max(notchWidth, 160), bounds.width)
        let notch = CGRect(x: bounds.midX - width / 2, y: layer.isGeometryFlipped || content.isFlipped ? 0 : bounds.maxY - notchHeight, width: width, height: notchHeight)
        let notchPath = CGPath(roundedRect: notch, cornerWidth: 10, cornerHeight: 10, transform: nil)
        let fullPath = CGPath(roundedRect: bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.path = growing ? CGPath(rect: bounds, transform: nil) : notchPath
        layer.mask = mask
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = growing ? notchPath : fullPath
        animation.toValue = growing ? fullPath : notchPath
        animation.duration = growing ? 0.34 : 0.22
        animation.timingFunction = growing ? Self.curve : CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak layer, weak mask] in
            if growing, layer?.mask === mask { layer?.mask = nil }
            completion?()
            layer?.removeAnimation(forKey: "collapseFade")
        }
        mask.add(animation, forKey: growing ? "grow" : "collapse")
        if !growing {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = animation.duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            layer.add(fade, forKey: "collapseFade")
        }
        CATransaction.commit()
    }

    func place(_ frame: NSRect) {
        guard let panel, panel.frame != frame else { return }
        let sameScreen = panel.screen.map { $0.frame.intersects(frame) } ?? false
        guard isVisible, sameScreen, !reduceMotion else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = Self.curve
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// Pays the one-time render cost so a first invocation only orders an
    /// already-rendered window on screen.
    func warm() {
        ensurePanel().displayIfNeeded()
    }

    func hide() {
        guard let panel, isVisible else { return }
        hiding = true
        morph(panel, growing: false) { [weak self, weak panel] in
            guard let self, self.hiding, let panel else { return }
            self.hiding = false
            panel.orderOut(nil)
            panel.contentView?.layer?.mask = nil
        }
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
        homeController.setConversationVisible(true)
        notchStatus.setConversationVisible(true)
        if !sessionPanel.isVisible { sessionPanel.screen = HomeController.screenUnderPointer() }
        sessionPanel.show(frame: notchPanelFrame(), activate: activate)
        overlayState.panelScreenFrame = sessionPanel.frame
    }

    /// Size follows what the notch is showing: a focused stage (onboarding,
    /// an approval, a guide step) stays narrow; the workspace opens wide.
    private func notchPanelFrame() -> NSRect {
        guard let screen = sessionPanel.screen.flatMap({ NSScreen.screens.contains($0) ? $0 : nil }) ?? HomeController.screenUnderPointer() else { return .zero }
        let presentation = NotchPresentation.shared
        let model = homeController.homeModel
        let focused = (model.onboarding != nil && model.sidebarSelection != .settings)
            || (presentation.current != nil && presentation.showsInteraction)
        let interaction = presentation.showsInteraction ? presentation.current : nil
        let contentHeight = interaction?.contentHeight.map { max(220, $0 + 136) } ?? (focused ? 460 : 520)
        let size = NSSize(
            width: min(focused ? 592 : 892, screen.frame.width - 32),
            height: min(contentHeight + max(24, screen.safeAreaInsets.top), screen.frame.height - 64)
        )
        let frame = HomeController.notchPanelFrame(
            size: size,
            screenFrame: screen.frame,
            centerX: HomeController.zoneRect(for: screen).midX
        )
        presentation.frame = frame
        return frame
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
            self.sessionPanel.place(self.notchPanelFrame())
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
        if sessionPanel.isVisible { sessionPanel.place(notchPanelFrame()) }
        overlayState.panelScreenFrame = sessionPanel.frame
        homeController.screenLayoutChanged()
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
        homeController.setConversationVisible(false)
        notchStatus.setConversationVisible(false)
    }

    func showBackgroundTasks() {
        runtimes.refreshChoices()
        homeController.openHome(selection: .tasks)
    }
}
