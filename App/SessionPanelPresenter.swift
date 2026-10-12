import AppKit
import PerryOverlay

/// The floating type/talk panel: built once, shown on invocation, and on
/// hide hands focus back to the app the user came from.
@MainActor
final class SessionPanelPresenter {
    private static let frameAutosaveName = "perry.session.frame"
    private let makeContent: () -> NSView
    private var panel: NSPanel?
    /// The app the user was in before Perry activated — restored on hide so
    /// an invocation never leaves focus kidnapped. Same convention as
    /// IntentCardWindow and AgentActivityStrip.
    private var previousFrontmostApplication: NSRunningApplication?

    init(makeContent: @escaping () -> NSView) {
        self.makeContent = makeContent
    }

    var frame: CGRect? { panel?.frame }

    func show() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ownPID {
            previousFrontmostApplication = frontmost
        }
        NSApp.activate(ignoringOtherApps: true)
        ensurePanel().makeKeyAndOrderFront(nil)
        PerfMark.mark("panel.visible")
    }

    /// Pays the one-time render cost so a first invocation only orders an
    /// already-rendered window on screen.
    func warm() {
        ensurePanel().displayIfNeeded()
    }

    func hide() {
        panel?.orderOut(nil)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if NSApp.isActive,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID,
           let previous = previousFrontmostApplication,
           previous.processIdentifier != ownPID {
            previous.activate(options: [.activateAllWindows])
        }
        previousFrontmostApplication = nil
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: PerryTheme.Sizing.panelWidth,
                height: PerryTheme.Sizing.panelHeight
            ),
            styleMask: [.titled, .utilityWindow, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        p.contentView = makeContent()
        p.identifier = SessionPanelView.windowIdentifier
        p.contentMinSize = NSSize(width: PerryTheme.Sizing.panelWidth, height: PerryTheme.Sizing.panelHeight)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.titlebarAppearsTransparent = true
        p.level = .floating
        PerryWindowChrome.applyChrome(to: p)
        if !p.setFrameUsingName(Self.frameAutosaveName), let screen = NSScreen.main {
            let frame = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: frame.maxX - p.frame.width - 24, y: frame.minY + 80))
        }
        p.setFrameAutosaveName(Self.frameAutosaveName)
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
        probe.pinInvocationTargetIfNeeded()
        homeController.prepareConversation(target: probe.presentationTarget())
        sessionPanel.show()
    }

    /// Pays the one-time render cost for the session surfaces at launch so a
    /// first invocation only orders already-rendered windows on screen.
    func warmSessionSurfaces() {
        sessionPanel.warm()
        overlayManager.warmRenderPipeline(state: overlayState)
    }

    func hidePanel() {
        sessionPanel.hide()
    }

    func showBackgroundTasks() {
        runtimes.refreshChoices()
        homeController.openHome(selection: .tasks)
    }
}
