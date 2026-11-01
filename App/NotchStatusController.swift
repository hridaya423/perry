import AppKit
import PerryOverlay

@MainActor
final class NotchStatusController {
    private var window: PerryPanel?
    private var fadeGeneration = 0
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

    func update(isRecording: Bool, backgroundCount: Int, awaitingApproval: Int = 0) {
        self.isRecording = isRecording
        self.backgroundCount = max(0, backgroundCount)
        self.awaitingApproval = max(0, awaitingApproval)
        present()
    }

    func setListeningForWake(_ listening: Bool) {
        listeningForWake = listening
        present()
    }

    func setConversationVisible(_ visible: Bool) {
        conversationVisible = visible
        present()
    }

    func hide() {
        guard let window, window.isVisible else { return }
        fadeGeneration += 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard self?.fadeGeneration == generation else { return }
                window?.orderOut(nil)
            }
        })
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

    nonisolated static func shouldPresent(isRecording: Bool, backgroundCount: Int, awaitingApproval: Int, listeningForWake: Bool = false) -> Bool {
        listeningForWake || isRecording || backgroundCount > 0 || awaitingApproval > 0
    }

    private func present() {
        guard !conversationVisible else {
            hide()
            return
        }
        guard Self.shouldPresent(
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
        let recording = isRecording
        let tasks = backgroundCount
        let reviews = awaitingApproval
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

        stack.edgeInsets = NSEdgeInsets(top: screen.safeAreaInsets.top + 7, left: 16, bottom: 9, right: 16)
        let size = CGSize(width: max(220, stack.fittingSize.width), height: stack.fittingSize.height)
        let frame = NotchGeometry.panelFrame(size: size, screenFrame: screen.frame, centerX: NotchGeometry(screen: screen).centerX)
        panel.contentView?.layer?.cornerRadius = 14
        panel.contentView?.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        window = panel
        fadeGeneration += 1
        let wasVisible = panel.isVisible
        if !wasVisible {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if wasVisible, panel.frame != frame { panel.animator().setFrame(frame, display: true) }
            panel.animator().alphaValue = 1
        }
    }

    private static func makePanel(controller: NotchStatusController) -> PerryPanel {
        let panel = PerryPanel()

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
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        controller.wakeIcon.contentTintColor = NSColor(PerryTheme.Colors.accent)
        controller.separator2.textColor = .secondaryLabelColor
        controller.gear.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        controller.gear.contentTintColor = .labelColor
        controller.reviewIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
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
