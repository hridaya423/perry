import AppKit
import SwiftUI
import PerryGuide

/// Floating intent card anchored near the cursor. Orange: click the action
/// button or Stop. Red: also requires typing the exact displayed target
/// (PRD §4 — voice never suffices).
final class IntentCardWindow: NSPanel {
    let approvalID: UUID
    private let card: IntentCard
    private let completion: (Bool) -> Void
    private static var active: IntentCardWindow?
    private var finished = false
    private var previousFrontmostApplication: NSRunningApplication?

    override var canBecomeKey: Bool { true }

    init(approvalID: UUID = UUID(), card: IntentCard, completion: @escaping (Bool) -> Void) {
        self.approvalID = approvalID
        self.card = card
        self.completion = completion
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 388, height: 320),
            styleMask: [.titled, .utilityWindow, .resizable],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .modalPanel
        hidesOnDeactivate = false
        let hostingView = NSHostingView(rootView: IntentCardView(card: card) { [weak self] approved in
            self?.finish(approved)
        })
        contentView = hostingView
        let fitting = hostingView.fittingSize
        setContentSize(NSSize(width: max(388, fitting.width), height: max(280, fitting.height)))
        // After hosting installs its own ideal-size constraints.
        minSize = NSSize(width: 388, height: 280)
    }

    func showNearCursor() {
        Self.active?.cancel()
        Self.active = self
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousFrontmostApplication = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let x = min(mouse.x + 24, visible.maxX - frame.width - 12)
        let y = max(visible.minY + 12, mouse.y - frame.height - 24)
        setFrameOrigin(NSPoint(x: max(visible.minX + 12, x), y: y))
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    func cancel() {
        finish(false)
    }

    private func finish(_ approved: Bool) {
        guard !finished else { return }
        finished = true
        close()
        if Self.active === self { Self.active = nil }
        completion(approved)
        if let previousFrontmostApplication,
           previousFrontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousFrontmostApplication.activate(options: [.activateAllWindows])
        }
        previousFrontmostApplication = nil
    }
}

struct IntentCardView: View {
    let card: IntentCard
    let onAnswer: (Bool) -> Void

    @State private var typedConfirmation: String = ""
    @FocusState private var confirmationFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(colorForTier)
                    .frame(width: 10, height: 10)
                Text(card.title)
                    .font(PerryTheme.Typography.panelBody.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                labeledRow("Target", value: card.targetSummary)
                if let reversible = card.reversible {
                    labeledRow(
                        "Reversible",
                        value: reversible ? "Yes" : "No — this cannot be undone",
                        valueColor: reversible ? PerryTheme.Colors.textSecondary : PerryTheme.Colors.danger
                    )
                }
            }
            .accessibilityElement(children: .contain)

            if let detail = card.detail, !detail.isEmpty {
                Text(detail)
                    .font(PerryTheme.Typography.note.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if card.tier >= .red {
                Text("This one needs real attention. Type \"\(card.redPhrase)\" exactly; I won't take a voice yes for this.")
                    .font(PerryTheme.Typography.note)
                    .foregroundStyle(.secondary)
                TextField(card.redPhrase, text: $typedConfirmation)
                    .textFieldStyle(.roundedBorder)
                    .font(PerryTheme.Typography.settingsStatus)
                    .focused($confirmationFocused)
                    .accessibilityLabel("Confirmation phrase")
                    .accessibilityHint("Type the displayed target exactly to allow this action")
            }

            HStack {
                Button("Stop") { onAnswer(false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(approveButtonTitle) {
                    guard isTypedConfirmationValid else {
                        NSSound.beep()
                        return
                    }
                    onAnswer(true)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isTypedConfirmationValid)
            }
        }
        .padding(14)
        .frame(minWidth: 340, maxWidth: .infinity)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            if card.tier >= .red {
                confirmationFocused = true
            }
        }
    }

    private func labeledRow(_ label: String, value: String, valueColor: Color = PerryTheme.Colors.textSecondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(PerryTheme.Typography.note.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(PerryTheme.Typography.note)
                .foregroundStyle(valueColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var approveButtonTitle: String {
        guard let label = card.approveLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else { return "Approve" }
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    private var colorForTier: Color {
        switch card.tier {
        case .orange: return PerryTheme.Colors.warning
        case .red: return PerryTheme.Colors.danger
        case .yellow: return PerryTheme.Colors.caution
        case .green: return PerryTheme.Colors.success
        }
    }

    private var isTypedConfirmationValid: Bool {
        guard card.tier >= .red else { return true }
        return typedConfirmation.trimmingCharacters(in: .whitespacesAndNewlines) == card.redPhrase
    }
}
