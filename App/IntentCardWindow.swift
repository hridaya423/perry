import AppKit
import SwiftUI
import PerryGuide
import PerryOverlay
import PerryRuntimes

@MainActor
final class IntentCardWindow {
    let approvalID: UUID
    private let completion: (PlanDecision) -> Void
    private static var active: IntentCardWindow?
    private var finished = false
    private var content: AnyView = AnyView(EmptyView())
    private let presentation: NotchPresentation
    private var previousFrontmostApplication: NSRunningApplication?

    var frame: NSRect { presentation.frame }

    init(
        approvalID: UUID = UUID(),
        card: IntentCard,
        allowsStepThrough: Bool = false,
        alwaysAllowLabel: String? = nil,
        onAlwaysAllow: (() -> Void)? = nil,
        presentation: NotchPresentation? = nil,
        completion: @escaping (PlanDecision) -> Void
    ) {
        self.approvalID = approvalID
        self.completion = completion
        self.presentation = presentation ?? .shared
        content = AnyView(IntentCardView(
            card: card,
            allowsStepThrough: allowsStepThrough,
            alwaysAllowLabel: alwaysAllowLabel,
            onAlwaysAllow: onAlwaysAllow
        ) { [weak self] decision in self?.finish(decision) })
    }

    func show() {
        guard !finished else { return }
        if Self.active !== self { Self.active?.cancel() }
        Self.active = self
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousFrontmostApplication = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        presentation.present(id: approvalID, priority: .approval, content: content, onDismiss: { [weak self] in self?.cancel() })
    }

    func cancel() { finish(.cancel) }

    private func finish(_ decision: PlanDecision) {
        guard !finished else { return }
        finished = true
        presentation.remove(approvalID)
        if Self.active === self { Self.active = nil }
        completion(decision)
        previousFrontmostApplication?.activate(options: [.activateAllWindows])
        previousFrontmostApplication = nil
    }
}

struct IntentCardView: View {
    let card: IntentCard
    var allowsStepThrough: Bool = false
    /// When set (orange-tier tool approvals), a third choice grants the tool
    /// for the rest of this thread's session, then counts as run.
    var alwaysAllowLabel: String?
    var onAlwaysAllow: (() -> Void)?
    let onAnswer: (PlanDecision) -> Void

    @State private var typedConfirmation: String = ""
    @State private var showsFullDetail = false
    @FocusState private var confirmationFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(colorForTier)
                        .frame(width: 7, height: 7)
                    Text(tierLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Risk: \(tierLabel)")
                Text(card.title)
                    .font(.title3.weight(.semibold))
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
                VStack(alignment: .leading, spacing: 6) {
                    if showsFullDetail {
                        ScrollView {
                            detailText(detail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                    } else {
                        detailText(detail)
                            .lineLimit(4)
                    }
                    if detail.count > 220 || detail.contains("\n") {
                        Button(showsFullDetail ? "Show less" : "Show more") { showsFullDetail.toggle() }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(PerryTheme.Colors.accent)
                    }
                }
            }

            if card.tier >= .red {
                Text("This one needs real attention. Type \"\(card.redPhrase)\" exactly; I won’t take a voice yes for this.")
                    .font(PerryTheme.Typography.settingsStatus)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                Text(card.redPhrase)
                    .font(PerryTheme.Typography.mono)
                    .foregroundStyle(PerryTheme.Colors.danger)
                TextField("Type it here to confirm", text: $typedConfirmation)
                    .textFieldStyle(.roundedBorder)
                    .font(PerryTheme.Typography.settingsStatus)
                    .focused($confirmationFocused)
                    .accessibilityLabel("Confirmation phrase")
                    .accessibilityHint("Type the displayed target exactly to allow this action")
            }

            HStack(spacing: 8) {
                if allowsStepThrough {
                    HStack(spacing: 14) {
                        Button("Edit") { onAnswer(.edit) }
                            .keyboardShortcut("e", modifiers: .command)
                            .accessibilityHint("Send the goal back to revise it")
                        Button("Replay") { onAnswer(.replay) }
                            .keyboardShortcut("r", modifiers: .command)
                            .accessibilityHint("Re-observe the targets and show the preview again")
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                }
                Spacer()
                Button("Don’t allow") { onAnswer(.cancel) }
                    .keyboardShortcut(.cancelAction)
                if allowsStepThrough {
                    Button("Step through") {
                        guard isTypedConfirmationValid else {
                            NSSound.beep()
                            return
                        }
                        onAnswer(.stepThrough)
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isTypedConfirmationValid)
                    .accessibilityHint("Run the plan one action at a time, confirming each step")
                }
                if let alwaysAllowLabel, let onAlwaysAllow, card.tier < .red {
                    Button(alwaysAllowLabel) {
                        onAlwaysAllow()
                        onAnswer(.run)
                    }
                    .accessibilityHint("Approve this and future calls of the same tool for this thread")
                }
                Button(approveButtonTitle) {
                    guard isTypedConfirmationValid else {
                        NSSound.beep()
                        return
                    }
                    onAnswer(.run)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(InkButtonStyle())
                .disabled(!isTypedConfirmationValid)
            }
            .buttonStyle(InkButtonStyle(.secondary))
            .controlSize(.small)
        }
        .padding(18)
        .frame(minWidth: 340, maxWidth: .infinity)
        .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.panel, style: .continuous))
        .foregroundStyle(PerryTheme.Colors.text)
        .onAppear {
            if card.tier >= .red {
                confirmationFocused = true
            }
        }
    }

    private func detailText(_ detail: String) -> some View {
        Text(detail)
            .font(.callout)
            .foregroundStyle(PerryTheme.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func labeledRow(_ label: String, value: String, valueColor: Color = PerryTheme.Colors.textSecondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(PerryTheme.Typography.settingsStatus.weight(.semibold))
                .foregroundStyle(PerryTheme.Colors.textSecondary)
            Text(value)
                .font(PerryTheme.Typography.settingsStatus)
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

    private var tierLabel: String {
        switch card.tier {
        case .green: "Read only"
        case .yellow: "Small change"
        case .orange: "Needs your OK"
        case .red: "High stakes"
        }
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
