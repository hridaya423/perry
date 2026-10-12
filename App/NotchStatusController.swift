import AppKit
import PerryOverlay

/// A glanceable pill that drops below the camera notch with live status —
/// only while a demonstration is recording or background tasks are active.
/// Hidden whenever there's nothing to say, and skipped entirely on Macs
/// without a notch. Status only: it never intercepts input.
///
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

    func hide() {
        window?.orderOut(nil)
    }

    nonisolated static func shouldPresent(isEnabled: Bool, isRecording: Bool, backgroundCount: Int, hasNotchedScreen: Bool) -> Bool {
        isEnabled && (isRecording || backgroundCount > 0) && hasNotchedScreen
    }

    private func present() {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
        guard Self.shouldPresent(
            isEnabled: isEnabled,
            isRecording: isRecording,
            backgroundCount: backgroundCount,
            hasNotchedScreen: screen != nil
        ), let screen else {
            hide()
            return
        }
        let panel = window ?? Self.makePanel(controller: self)
        guard let stack else {
            hide()
            return
        }
        dot.isHidden = !isRecording
        recordingLabel.isHidden = !isRecording
        separator.isHidden = !(isRecording && (backgroundCount > 0 || awaitingApproval > 0))
        gear.isHidden = backgroundCount == 0
        countLabel.isHidden = backgroundCount == 0
        countLabel.stringValue = backgroundCount == 1 ? "1 task" : "\(backgroundCount) tasks"
        separator2.isHidden = !(awaitingApproval > 0 && (isRecording || backgroundCount > 0))
        reviewIcon.isHidden = awaitingApproval == 0
        reviewLabel.isHidden = awaitingApproval == 0
        reviewLabel.stringValue = awaitingApproval == 1 ? "1 needs review" : "\(awaitingApproval) need review"
        var parts: [String] = []
        if isRecording { parts.append("Recording a demonstration") }
        if backgroundCount > 0 { parts.append("\(backgroundCount) background \(backgroundCount == 1 ? "task" : "tasks")") }
        if awaitingApproval > 0 { parts.append("\(awaitingApproval) awaiting approval") }
        panel.contentView?.setAccessibilityLabel(parts.joined(separator: ", "))

        let size = stack.fittingSize
        let drop = screen.safeAreaInsets.top + 4
        panel.setFrame(
            NSRect(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - drop - size.height,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        panel.contentView?.layer?.cornerRadius = size.height / 2
        window = panel
        panel.orderFrontRegardless()
    }

    private static func makePanel(controller: NotchStatusController) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        PerryWindowChrome.applyChrome(to: panel)

        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        controller.dot.wantsLayer = true
        controller.dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        controller.dot.layer?.cornerRadius = 3.5
        controller.dot.translatesAutoresizingMaskIntoConstraints = false
        controller.dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        controller.dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        for label in [controller.recordingLabel, controller.separator, controller.countLabel, controller.separator2, controller.reviewLabel] {
            label.font = font
            label.textColor = .labelColor
        }
        controller.separator.textColor = .secondaryLabelColor
        controller.separator2.textColor = .secondaryLabelColor
        controller.gear.image = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        controller.gear.contentTintColor = .labelColor
        controller.reviewIcon.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        controller.reviewIcon.contentTintColor = .labelColor

        let stack = NSStackView(views: [
            controller.dot, controller.recordingLabel, controller.separator, controller.gear, controller.countLabel,
            controller.separator2, controller.reviewIcon, controller.reviewLabel
        ])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.stack = stack

        let capsule = NSVisualEffectView()
        capsule.material = .hudWindow
        capsule.state = .active
        capsule.blendingMode = .behindWindow
        capsule.wantsLayer = true
        capsule.layer?.masksToBounds = true
        capsule.setAccessibilityElement(true)
        capsule.setAccessibilityRole(.group)
        capsule.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: capsule.topAnchor),
            stack.bottomAnchor.constraint(equalTo: capsule.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: capsule.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: capsule.trailingAnchor)
        ])
        panel.contentView = capsule
        return panel
    }
}
