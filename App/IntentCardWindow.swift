import AppKit
import SwiftUI
import PerryCore
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
    private let card: IntentCard
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
        self.card = card
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
        presentation.present(id: approvalID, priority: .approval, title: card.title, content: content, onDismiss: { [weak self] in self?.cancel() })
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

extension TrustTier {
    var riskLabel: String {
        switch self {
        case .green: "Reads only"
        case .yellow: "Small change"
        case .orange: "Bigger change"
        case .red: "High stakes"
        }
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
                        .font(PerryTheme.Scale.section)
                        .foregroundStyle(colorForTier)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Risk: \(tierLabel)")
                Text(card.title)
                    .font(PerryTheme.Scale.title)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !card.targetSummary.isEmpty || card.reversible != nil {
            VStack(alignment: .leading, spacing: 4) {
                if !card.targetSummary.isEmpty {
                    labeledRow("Affects", value: card.targetSummary)
                }
                if let reversible = card.reversible {
                    labeledRow(
                        "Undo",
                        value: reversible ? "Yes" : "No. This can’t be undone.",
                        valueColor: reversible ? PerryTheme.Colors.textSecondary : PerryTheme.Colors.danger
                    )
                }
            }
            .accessibilityElement(children: .contain)
            }

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
                            .buttonStyle(.pressable)
                            .font(PerryTheme.Scale.secondary)
                            .foregroundStyle(PerryTheme.Colors.accent)
                    }
                }
            }

            if card.tier >= .red {
                Text("Type “\(card.redPhrase)” to confirm. Voice can’t approve this.")
                    .font(PerryTheme.Typography.settingsStatus)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                Text(card.redPhrase)
                    .font(PerryTheme.Typography.mono)
                    .foregroundStyle(PerryTheme.Colors.danger)
                TextField("Type the phrase", text: $typedConfirmation)
                    .textFieldStyle(.roundedBorder)
                    .font(PerryTheme.Typography.settingsStatus)
                    .focused($confirmationFocused)
                    .accessibilityLabel("Confirmation phrase")
                    .accessibilityHint("Type the phrase shown to approve this action")
            }

            HStack(spacing: 8) {
                if allowsStepThrough {
                    HStack(spacing: 14) {
                        Button("Edit goal") { onAnswer(.edit) }
                            .keyboardShortcut("e", modifiers: .command)
                            .accessibilityHint("Send the goal back so you can change it")
                        Button("Preview again") { onAnswer(.replay) }
                            .keyboardShortcut("r", modifiers: .command)
                            .accessibilityHint("Look at the screen again and show the preview")
                    }
                    .buttonStyle(.pressable)
                    .font(PerryTheme.Scale.body)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                }
                Spacer()
                Button("Deny") { onAnswer(.cancel) }
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
                    .accessibilityHint("Run the plan one step at a time, and confirm each step")
                }
                if let alwaysAllowLabel, let onAlwaysAllow, card.tier < .red {
                    Button(alwaysAllowLabel) {
                        onAlwaysAllow()
                        onAnswer(.run)
                    }
                    .accessibilityHint("Approve this and every later request like it in this conversation")
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
        .frame(maxWidth: .infinity)
        .foregroundStyle(PerryTheme.Colors.text)
        .onAppear {
            if card.tier >= .red {
                confirmationFocused = true
            }
        }
    }

    private func detailText(_ detail: String) -> some View {
        Text(detail)
            .font(PerryTheme.Scale.body)
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

    private var tierLabel: String { card.tier.riskLabel }

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
