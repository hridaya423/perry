import AppKit
import PerryOverlay
import SwiftUI

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

    let expansion = NotchExpansion()
    var frame: CGRect? { isVisible ? visibleFrame : nil }
    var isVisible: Bool { panel?.isVisible == true && expansion.contentShown }
    var isKey: Bool { panel?.isKeyWindow == true }
    var screen: NSScreen?
    var keyboardInitiated = false
    private var visibleFrame: CGRect?
    private var instant: Bool { keyboardInitiated || NSApp.currentEvent?.type == .keyDown }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func show(window: NSRect, visible: NSRect, activate: Bool) {
        let panel = ensurePanel()
        place(window: window, visible: visible)
        panel.contentView?.layoutSubtreeIfNeeded()
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
        expand()
        if expansion.peeking { PerfMark.mark("notch.peek_visible") } else { PerfMark.mark("panel.visible") }
    }

    private func expand() {
        guard !(expansion.open && expansion.contentShown) else { return }
        if instant {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                expansion.open = true
                expansion.contentShown = true
            }
            return
        }
        withAnimation(reduceMotion ? NotchMotion.reduced : NotchMotion.open) { expansion.open = true }
        withAnimation(reduceMotion ? NotchMotion.reduced : NotchMotion.contentIn) { expansion.contentShown = true }
    }

    func place(window: NSRect, visible: NSRect) {
        visibleFrame = visible
        guard let panel, panel.frame != window else { return }
        panel.setFrame(window, display: true)
    }

    func focusWithoutActivating() {
        guard let panel, isVisible, !panel.isKeyWindow else { return }
        panel.makeKey()
    }

    /// Pays the one-time render cost so a first invocation only orders an
    /// already-rendered window on screen.
    func warm() {
        ensurePanel().displayIfNeeded()
    }

    func hide(completion: @escaping () -> Void = {}) {
        guard let panel, isVisible else { return completion() }
        if instant {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                expansion.contentShown = false
                expansion.open = false
            }
            panel.orderOut(nil)
            completion()
        } else {
            let expansion = expansion
            withAnimation(reduceMotion ? NotchMotion.reduced : NotchMotion.contentOut) {
                expansion.contentShown = false
            } completion: { [reduceMotion] in
                guard !expansion.contentShown else { return }
                withAnimation(reduceMotion ? NotchMotion.reduced : NotchMotion.close) {
                    expansion.open = false
                } completion: { [weak panel] in
                    DispatchQueue.main.async {
                        guard !expansion.open else { return }
                        panel?.orderOut(nil)
                        completion()
                    }
                }
            }
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
        p.identifier = CompactConversationPanel.identifier
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
    func presentPrompt(prefill: String, mode: HomeModel.ComposerMode = .ask) {
        let model = homeController.homeModel
        model.sidebarSelection = nil
        model.updateNewDraft(prefill)
        model.composerMode = mode
        conversationVoice.cancel()
        showPanel()
    }

    func showPanel() {
        showPanel(activate: true)
    }

    func showPeek() {
        showPanel(activate: false, peek: true)
    }

    func showPanel(activate: Bool, peek: Bool = false) {
        sessionPanel.expansion.peeking = peek
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
        let size = NotchLayout.size(NotchLayout.mode(presentation, expansion: sessionPanel.expansion), cameraInset: max(24, screen.safeAreaInsets.top), screen: screen.frame.size)
        presentation.frame = NotchLayout.visibleFrame(size, in: window)
        return (window, presentation.frame)
    }

    static let voiceEntryID = UUID()

    func presentConversationVoice(_ state: VoiceConversationController.State) {
        let presentation = NotchPresentation.shared
        switch state {
        case .idle:
            presentation.remove(Self.voiceEntryID)
            if voiceOpenedNotch, presentation.current == nil { hidePanel() }
            voiceOpenedNotch = false
        case .requestingPermission:
            break
        case .listening, .thinking, .speaking, .failed:
            guard homeController.homeModel.onboarding == nil, !presentation.contains(Self.voiceEntryID) else { break }
            voiceOpenedNotch = !sessionPanel.isVisible
            presentation.present(
                id: Self.voiceEntryID,
                priority: .voice,
                content: NotchListeningView(voice: conversationVoice),
                onDismiss: { [weak self] in self?.conversationVoice.cancel() }
            )
            if !sessionPanel.isVisible { showPanel(activate: false) }
            sessionPanel.focusWithoutActivating()
        }
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        switch state {
        case .requestingPermission:
            break
        case .listening:
            overlayState.buddyState = .listening
            overlayState.voiceState = .listening
            overlayState.taskBubbleText = nil
        case .thinking:
            SoundPlayer.play(.send)
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

    func endPeek() {
        hideSurfaces()
    }

    private func hideSurfaces() {
        overlayState.panelScreenFrame = nil
        sessionPanel.hide { [weak self] in
            self?.notchPresence.setConversationVisible(false)
            self?.notchStatus.setConversationVisible(false)
        }
    }

    func showBackgroundTasks() {
        homeController.openHome(selection: .tasks)
    }
}
