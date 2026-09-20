import AppKit
import SwiftUI

/// A glanceable pill that drops below the camera notch with live status —
/// only while a demonstration is recording or background tasks are active.
/// Hidden whenever there's nothing to say, and skipped entirely on Macs
/// without a notch. Status only: it never intercepts input.
@MainActor
final class NotchStatusController {
    static let enabledKey = "perry.notchStatus.enabled"

    private var window: NSPanel?
    private var isRecording = false
    private var backgroundCount = 0

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { hide() } else { present() }
    }

    func update(isRecording: Bool, backgroundCount: Int) {
        self.isRecording = isRecording
        self.backgroundCount = max(0, backgroundCount)
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
        let view = NotchStatusPill(isRecording: isRecording, backgroundCount: backgroundCount)
        let panel = window ?? Self.makePanel()
        let hosting: NSHostingView<NotchStatusPill>
        if let existing = panel.contentView as? NSHostingView<NotchStatusPill> {
            existing.rootView = view
            hosting = existing
        } else {
            hosting = NSHostingView(rootView: view)
            // The frame is set explicitly from fittingSize — the hosting view
            // must not negotiate window size extrema or its sizing loop can
            // re-invalidate constraints every pass (AppKit throws).
            hosting.sizingOptions = []
            panel.contentView = hosting
        }
        let size = hosting.fittingSize
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
        window = panel
        panel.orderFrontRegardless()
    }

    private static func makePanel() -> NSPanel {
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
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        return panel
    }
}

private struct NotchStatusPill: View {
    let isRecording: Bool
    let backgroundCount: Int

    var body: some View {
        HStack(spacing: 6) {
            if isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                Text("Recording")
                    .foregroundStyle(.primary)
            }
            if isRecording && backgroundCount > 0 {
                Text("·").foregroundStyle(.secondary)
            }
            if backgroundCount > 0 {
                Image(systemName: "gearshape.2")
                    .imageScale(.small)
                Text(backgroundCount == 1 ? "1 task" : "\(backgroundCount) tasks")
                    .foregroundStyle(.primary)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var label: String {
        var parts: [String] = []
        if isRecording { parts.append("Recording a demonstration") }
        if backgroundCount > 0 { parts.append("\(backgroundCount) background \(backgroundCount == 1 ? "task" : "tasks")") }
        return parts.joined(separator: ", ")
    }
}
