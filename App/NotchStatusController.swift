import AppKit
import PerryOverlay

/// Rendered in plain AppKit, not NSHostingView: a hosting view attached to a
/// borderless panel can re-invalidate the window's size extrema every
/// constraint pass until AppKit throws. A fixed NSStackView can't.
@MainActor
final class NotchStatusController {

    private var window: NSPanel?
    private var stack: NSStackView?
    private var isRecording = false
    private var backgroundCount = 0
    private var awaitingApproval = 0
    private var conversationVisible = false
    private var listeningForWake = false

    var onOpenConversation: (() -> Void)?

    private let wakeIcon = NSImageView()
    private let wakeLabel = NSTextField(labelWithString: "Listening for “Hey Perry”")
    private let wakeSeparator = NSTextField(labelWithString: "·")
    private let dot = NSView()
    private let recordingLabel = NSTextField(labelWithString: "Recording")
    private let separator = NSTextField(labelWithString: "·")
    private let gear = NSImageView()
    private let countLabel = NSTextField(labelWithString: "")
    private let separator2 = NSTextField(labelWithString: "·")
    private let reviewIcon = NSImageView()
    private let reviewLabel = NSTextField(labelWithString: "")

    var isEnabled: Bool {
        get { PerryPreferences.notchStatusEnabled }
        set { PerryPreferences.notchStatusEnabled = newValue }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { hide() } else { present() }
    }

    func update(isRecording: Bool, backgroundCount: Int, awaitingApproval: Int = 0) {
        self.isRecording = isRecording
        self.backgroundCount = max(0, backgroundCount)
        self.awaitingApproval = max(0, awaitingApproval)
        present()
    }

    /// Ambient wake is the one state this indicator shows even when the user
    /// turned the notch status off: an open microphone is never invisible.
    func setListeningForWake(_ listening: Bool) {
        listeningForWake = listening
        present()
    }

    func setConversationVisible(_ visible: Bool) {
        conversationVisible = visible
        present()
    }

    func hide() {
        window?.orderOut(nil)
    }

    func repositionIfVisible() {
        guard window?.isVisible == true else { return }
        present()
    }

    @objc private func openConversation() -> Bool {
        guard let onOpenConversation else { return false }
        onOpenConversation()
        return true
    }

    nonisolated static func shouldPresent(isEnabled: Bool, isRecording: Bool, backgroundCount: Int, awaitingApproval: Int, listeningForWake: Bool = false) -> Bool {
        listeningForWake || isEnabled && (isRecording || backgroundCount > 0 || awaitingApproval > 0)
    }

    private func present() {
        guard !conversationVisible else {
            hide()
            return
        }
        guard Self.shouldPresent(
            isEnabled: isEnabled,
            isRecording: isRecording,
            backgroundCount: backgroundCount,
            awaitingApproval: awaitingApproval,
            listeningForWake: listeningForWake
        ), let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else {
            hide()
            return
        }
        let panel = window ?? Self.makePanel(controller: self)
        guard let stack else {
            hide()
            return
        }
        let recording = isEnabled && isRecording
        let tasks = isEnabled ? backgroundCount : 0
        let reviews = isEnabled ? awaitingApproval : 0
        wakeIcon.isHidden = !listeningForWake
        wakeLabel.isHidden = !listeningForWake
        wakeSeparator.isHidden = !(listeningForWake && (recording || tasks > 0 || reviews > 0))
        dot.isHidden = !recording
        recordingLabel.isHidden = !recording
        separator.isHidden = !(recording && (tasks > 0 || reviews > 0))
        gear.isHidden = tasks == 0
        countLabel.isHidden = tasks == 0
        countLabel.stringValue = tasks == 1 ? "1 task" : "\(tasks) tasks"
        separator2.isHidden = !(reviews > 0 && (recording || tasks > 0))
        reviewIcon.isHidden = reviews == 0
        reviewLabel.isHidden = reviews == 0
        reviewLabel.stringValue = reviews == 1 ? "1 needs review" : "\(reviews) need review"
        var parts: [String] = []
        if listeningForWake { parts.append("Listening for Hey Perry") }
        if recording { parts.append("Recording a demonstration") }
        if tasks > 0 { parts.append("\(tasks) background \(tasks == 1 ? "task" : "tasks")") }
        if reviews > 0 { parts.append("\(reviews) awaiting approval") }
        panel.contentView?.setAccessibilityLabel(parts.joined(separator: ", "))

        let midX: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            midX = (left.maxX + right.minX) / 2
        } else {
            midX = screen.frame.midX
        }
        stack.edgeInsets = NSEdgeInsets(top: screen.safeAreaInsets.top + 7, left: 16, bottom: 9, right: 16)
        let size = CGSize(width: max(220, stack.fittingSize.width), height: stack.fittingSize.height)
        panel.setFrame(
            HomeController.notchPanelFrame(size: size, screenFrame: screen.frame, centerX: midX),
            display: true
        )
        panel.contentView?.layer?.cornerRadius = 14
        panel.contentView?.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        window = panel
        panel.orderFrontRegardless()
    }

    private static func makePanel(controller: NotchStatusController) -> NSPanel {
        let panel = NotchStatusPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        PerryWindowChrome.applyChrome(to: panel)

        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        controller.dot.wantsLayer = true
        controller.dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        controller.dot.layer?.cornerRadius = 3.5
        controller.dot.translatesAutoresizingMaskIntoConstraints = false
        controller.dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        controller.dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        for label in [controller.wakeLabel, controller.wakeSeparator, controller.recordingLabel, controller.separator, controller.countLabel, controller.separator2, controller.reviewLabel] {
            label.font = font
            label.textColor = .labelColor
        }
        controller.separator.textColor = .secondaryLabelColor
        controller.wakeSeparator.textColor = .secondaryLabelColor
        controller.wakeIcon.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        controller.wakeIcon.contentTintColor = NSColor(PerryOverlayTheme.Colors.accent)
        controller.separator2.textColor = .secondaryLabelColor
        controller.gear.image = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        controller.gear.contentTintColor = .labelColor
        controller.reviewIcon.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        controller.reviewIcon.contentTintColor = .labelColor

        let stack = NSStackView(views: [
            controller.wakeIcon, controller.wakeLabel, controller.wakeSeparator,
            controller.dot, controller.recordingLabel, controller.separator, controller.gear, controller.countLabel,
            controller.separator2, controller.reviewIcon, controller.reviewLabel
        ])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.stack = stack

        let capsule = NSView()
        capsule.wantsLayer = true
        capsule.layer?.backgroundColor = NSColor.black.cgColor
        capsule.layer?.masksToBounds = true
        capsule.setAccessibilityElement(true)
        capsule.setAccessibilityRole(.button)
        capsule.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Open conversation") { [weak controller] in
                controller?.openConversation() ?? false
            }
        ])
        capsule.addGestureRecognizer(NSClickGestureRecognizer(target: controller, action: #selector(NotchStatusController.openConversation)))
        capsule.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: capsule.topAnchor),
            stack.bottomAnchor.constraint(equalTo: capsule.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: capsule.centerXAnchor)
        ])
        panel.contentView = capsule
        return panel
    }
}

private final class NotchStatusPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
