import AppKit
import SwiftUI
import PerryCore
import PerryOverlay

enum AgentActivityPhase: Equatable {
    case idle
    case starting
    case working
    case paused
    case confirming
    case verifying
    case reporting
    case failed
}

struct AgentActivityStep: Equatable, Identifiable {
    let id: String
    let summary: String
    let tier: TrustTier
    let reversible: Bool
    let timestamp: Date
    var verification: String?
}

@MainActor
final class AgentActivityStripState: ObservableObject {
    @Published var phase: AgentActivityPhase = .idle
    @Published var title = "Perry is ready"
    @Published var detail = ""
    @Published var progress: Double?
    @Published var tier: TrustTier?
    @Published var verification: String?
    @Published var steps: [AgentActivityStep] = []
    @Published var startedAt: Date?
    @Published var isExpanded = false
    @Published var canRetry = false
    /// The user took over mid-task — resume means replan, not restart the
    /// stale plan that expected to do the step itself.
    @Published var handedToHuman = false

    var steeringIsAvailable: Bool {
        phase == .working || phase == .paused
    }

    var takeOverIsAvailable: Bool {
        phase == .working
    }

    var stopIsAvailable: Bool {
        phase != .idle && phase != .reporting && phase != .failed
    }

    var retryIsAvailable: Bool {
        phase == .failed && canRetry
    }

    func apply(sessionState: SessionState) {
        let expanded = isExpanded
        reset()
        isExpanded = expanded
        switch sessionState {
        case .idle:
            return
        case .invoking:
            phase = .starting
            title = "Starting safely"
            detail = "Preparing your request"
        case .guiding:
            phase = .working
            title = "Perry is guiding"
            detail = "Waiting for the next step"
        case .asking(let ask):
            phase = .working
            title = "Answering a question"
            detail = ask.question
        case .talking(let talk):
            phase = .working
            title = talk.isListening ? "Listening" : "Answering"
            detail = talk.transcript.isEmpty ? "Point and speak" : talk.transcript
        case .executing(let execution):
            startedAt = execution.startedAt
            progress = execution.progress
            tier = execution.currentTier
            steps = execution.stepEvidence.map { evidence in
                let verification = execution.verificationEvidence.first(where: { $0.stepID == evidence.id })
                return AgentActivityStep(
                    id: evidence.id,
                    summary: evidence.summary,
                    tier: evidence.tier,
                    reversible: evidence.reversible,
                    timestamp: evidence.startedAt,
                    verification: Self.verificationLabel(for: verification) ?? evidence.verificationNote
                )
            }
            if let verification = execution.verificationEvidence.last {
                self.verification = Self.verificationLabel(for: verification)
            }
            if let finalizationOutcome = execution.finalizationOutcome {
                switch finalizationOutcome {
                case .completed:
                    phase = .reporting
                    title = "Task finished"
                    detail = "Saving your report"
                case .blocked:
                    phase = .reporting
                    title = "Task stopped"
                    detail = "Saving your report"
                case .failed:
                    phase = .failed
                    title = "Task failed"
                    detail = "Saving your report"
                }
            } else {
                switch execution.lifecycle {
                case .starting:
                    phase = .starting
                    title = "Starting safely"
                    detail = "You have 5 seconds to stop"
                case .running:
                    phase = .working
                    title = "Perry is working"
                    if let step = execution.stepEvidence.last {
                        title = "Step \(step.index + 1) of \(max(execution.totalSteps, step.index + 1))"
                        detail = step.summary
                    } else {
                        detail = "Sandboxed and supervised"
                    }
                case .paused:
                    phase = .paused
                    title = "Task paused"
                    detail = "Resume or stop when ready"
                case .awaitingApproval(let approval):
                    phase = .confirming
                    title = "Approval needed"
                    detail = approval.actionSummary
                case .verifying:
                    phase = .verifying
                    title = "Task finished"
                    detail = "Preparing your report"
                case .stopping:
                    phase = .reporting
                    title = "Task stopped"
                    detail = "Stopping safely…"
                case .finalizing(.verifying):
                    phase = .verifying
                    title = "Task finished"
                    detail = "Preparing your report"
                case .finalizing(.stopping):
                    phase = .reporting
                    title = "Task stopped"
                    detail = "Stopping safely…"
                }
            }
        case .reporting(let report):
            phase = .reporting
            title = report.outcome == .completed ? "Task complete" : "Task stopped"
            detail = report.summary
        case .failed(let failure):
            phase = .failed
            title = "Task failed"
            detail = failure.message
            canRetry = failure.goal != nil
        }
    }

    func reset() {
        phase = .idle
        title = "Perry is ready"
        detail = ""
        progress = nil
        tier = nil
        verification = nil
        steps = []
        startedAt = nil
        isExpanded = false
        canRetry = false
        handedToHuman = false
    }

    private static func verificationLabel(for evidence: ExecutionVerificationEvidence?) -> String? {
        guard let evidence else { return nil }
        if evidence.verified {
            return evidence.evidence.map { "Verified: \($0)" } ?? "Verified"
        }
        return evidence.warning.map { "Needs checking: \($0)" } ?? "Needs checking"
    }
}

struct AgentActivityStripView: View {
    @ObservedObject var state: AgentActivityStripState
    let onPause: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void
    let onRetry: () -> Void
    let onSteer: (String) -> Void
    let onTakeOver: () -> Void
    let onToggleExpanded: () -> Void

    @State private var steering = ""
    @FocusState private var steeringFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.header) {
            header

            if state.isExpanded {
                Divider()
                expandedDetails
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                if state.steeringIsAvailable {
                    steeringControls
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .padding(.horizontal, PerryTheme.Spacing.section)
        .padding(.vertical, PerryTheme.Spacing.header)
        .frame(width: state.isExpanded ? 370 : 300)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PerryTheme.Radius.panel, style: .continuous).strokeBorder(colorForTier.opacity(0.65), lineWidth: 1))
        .shadow(color: PerryTheme.Elevation.shadow, radius: 14, y: 6)
        .tint(PerryTheme.Colors.accent)
        .foregroundStyle(PerryTheme.Colors.text)
        .animation(reduceMotion ? nil : PerryTheme.Motion.panelStateChange, value: state.isExpanded)
        .onAppear {
            if state.isExpanded {
                focusSteering()
            }
        }
        .onChange(of: state.isExpanded) { _, expanded in
            if expanded {
                focusSteering()
            } else {
                steeringFocused = false
            }
        }
    }

    private var header: some View {
        HStack(spacing: PerryTheme.Spacing.header) {
            Button { onToggleExpanded() } label: {
                HStack(alignment: .top, spacing: PerryTheme.Spacing.header) {
                    PerryGlassCursorView(animation: state.phase == .failed ? .failed : state.phase == .paused ? .idle : .running, size: 30, variant: .lens)
                    VStack(alignment: .leading, spacing: PerryTheme.Spacing.tight) {
                        HStack(alignment: .firstTextBaseline, spacing: PerryTheme.Spacing.control) {
                            Text(state.title)
                                .font(PerryTheme.Typography.panelTitle)
                                .lineLimit(1)
                            if let tier = state.tier {
                                Text(tier.rawValue.capitalized)
                                    .font(PerryTheme.Typography.monoSmall.weight(.semibold))
                                    .foregroundStyle(color(for: tier))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(color(for: tier).opacity(0.15), in: Capsule())
                                    .accessibilityLabel("Trust tier")
                                    .accessibilityValue(tier.rawValue)
                            }
                            if let startedAt = state.startedAt {
                                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                                    Text(Self.elapsedText(since: startedAt, now: context.date))
                                        .font(PerryTheme.Typography.monoSmall)
                                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                                }
                            }
                        }
                        if !state.detail.isEmpty {
                            Text(state.detail)
                                .font(PerryTheme.Typography.monoSmall)
                                .foregroundStyle(PerryTheme.Colors.textSecondary)
                                .lineLimit(1)
                        }
                        if let progress = state.progress {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .frame(width: 150)
                                .tint(PerryTheme.Colors.accent)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(state.isExpanded ? "Collapse task details" : "Expand task details")
            .accessibilityValue(headerAccessibilityValue)
            .accessibilityHint(state.isExpanded ? "Hide task status and controls" : "Show task status and controls")
            Spacer(minLength: PerryTheme.Spacing.tight)
            controls
        }
    }

    private var expandedDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PerryTheme.Spacing.control) {
                statusDetails
                if state.steps.isEmpty {
                    Text("Waiting for the first step.")
                        .font(PerryTheme.Typography.note)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Task steps")
                        .accessibilityValue("Waiting for the first step")
                } else {
                    stepsDetails
                }
                if let verification = state.verification {
                    Text("Read-back: \(verification)")
                        .font(PerryTheme.Typography.panelMetadata)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Task verification")
                        .accessibilityValue(verification)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, PerryTheme.Spacing.tight)
        }
        .frame(maxHeight: 180)
        .scrollIndicators(.automatic)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Expanded task details")
    }

    private var statusDetails: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.tight) {
            HStack(alignment: .firstTextBaseline, spacing: PerryTheme.Spacing.control) {
                Text("Status")
                    .font(PerryTheme.Typography.panelMetadata)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: PerryTheme.Spacing.control)
                Text(state.phase.displayLabel)
                    .font(PerryTheme.Typography.monoSmall)
                    .foregroundStyle(statusColor)
            }
            Text(state.title)
                .font(PerryTheme.Typography.panelSubtitle)
                .fixedSize(horizontal: false, vertical: true)
            if !state.detail.isEmpty {
                Text(state.detail)
                    .font(PerryTheme.Typography.note)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let outcomeLabel {
                HStack(alignment: .firstTextBaseline, spacing: PerryTheme.Spacing.control) {
                    Image(systemName: outcomeSymbol)
                        .accessibilityHidden(true)
                    Text("Outcome: \(outcomeLabel)")
                }
                .font(PerryTheme.Typography.panelMetadata)
                .foregroundStyle(outcomeColor)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Task outcome")
                .accessibilityValue(outcomeLabel)
            }
        }
    }

    private var stepsDetails: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.control) {
            Text("Steps")
                .font(PerryTheme.Typography.panelMetadata)
                .foregroundStyle(PerryTheme.Colors.textSecondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(state.steps.indices, id: \.self) { index in
                let step = state.steps[index]
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: PerryTheme.Spacing.control) {
                        Circle()
                            .fill(color(for: step.tier))
                            .frame(width: PerryTheme.Sizing.statusDot, height: PerryTheme.Sizing.statusDot)
                            .padding(.top, PerryTheme.Spacing.control / 2)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: PerryTheme.Spacing.tight) {
                            Text(step.summary)
                                .font(PerryTheme.Typography.note.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(step.reversible ? "Reversible" : "One-way") · Trust tier \(step.tier.rawValue)")
                                .font(PerryTheme.Typography.monoSmall)
                                .foregroundStyle(PerryTheme.Colors.textSecondary)
                            if let verification = step.verification {
                                Text("Outcome: \(verification)")
                                    .font(PerryTheme.Typography.monoSmall.weight(.medium))
                                    .foregroundStyle(verification.hasPrefix("Verified") ? PerryTheme.Colors.success : PerryTheme.Colors.warning)
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel("Task step \(index + 1) of \(state.steps.count)")
                    .accessibilityValue(stepAccessibilityValue(step))
                }
                .accessibilityElement(children: .contain)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var steeringControls: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.control) {
            Text("Steering")
                .font(PerryTheme.Typography.panelMetadata)
                .foregroundStyle(PerryTheme.Colors.textSecondary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: PerryTheme.Spacing.control) {
                TextField("Steer before the next step", text: $steering)
                    .textFieldStyle(.roundedBorder)
                    .font(PerryTheme.Typography.monoSmall)
                    .focused($steeringFocused)
                    .accessibilityLabel("Steering instruction")
                    .accessibilityHint("Type an instruction for Perry before the next task step")
                    .accessibilityValue(trimmedSteering.isEmpty ? "No instruction entered" : trimmedSteering)
                    .onSubmit { sendSteering() }
                Button("Send direction") { sendSteering() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(steeringIsEmpty)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Send steering instruction")
                    .accessibilityHint("Send this instruction before Perry's next task step")
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: PerryTheme.Spacing.inline) {
            if state.phase == .working || state.phase == .starting {
                Button { onPause() } label: {
                    Image(systemName: "pause.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pause task")
                .help("Pause before the next step")
            } else if state.phase == .paused {
                Button { onResume() } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(state.handedToHuman ? "Continue with Perry" : "Resume task")
                .help(state.handedToHuman ? "Replan the remaining work from the current screen" : "Resume the task")
            }
            if state.takeOverIsAvailable {
                Button { onTakeOver() } label: {
                    Image(systemName: "person.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("I'll do this step")
                .help("Pause so you can do the step yourself — Perry replans the rest")
            }
            if state.retryIsAvailable {
                Button { onRetry() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry task")
                .help("Retry the last task")
            }
            if state.stopIsAvailable {
                Button(role: .destructive) { onStop() } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop task")
                .help("Stop the task")
            }
        }
    }

    private func sendSteering() {
        let request = trimmedSteering
        guard !request.isEmpty, state.steeringIsAvailable else { return }
        onSteer(request)
        steering = ""
    }

    private func focusSteering() {
        DispatchQueue.main.async {
            guard state.isExpanded else { return }
            steeringFocused = true
        }
    }

    private var steeringIsEmpty: Bool {
        trimmedSteering.isEmpty
    }

    private var trimmedSteering: String {
        steering.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var headerAccessibilityValue: String {
        guard let progress = state.progress else { return state.title }
        return "\(state.title), \(Int(progress * 100)) percent complete"
    }

    private func stepAccessibilityValue(_ step: AgentActivityStep) -> String {
        var parts = [
            step.summary,
            step.reversible ? "Reversible" : "One-way",
            "Trust tier \(step.tier.rawValue)"
        ]
        if let verification = step.verification {
            parts.append("Outcome: \(verification)")
        }
        return parts.joined(separator: ". ")
    }

    private var colorForTier: Color {
        color(for: state.tier)
    }

    private func color(for tier: TrustTier?) -> Color {
        switch tier {
        case .yellow: return PerryTheme.Colors.caution
        case .orange: return PerryTheme.Colors.warning
        case .red: return PerryTheme.Colors.danger
        default: return PerryTheme.Colors.accent
        }
    }

    private var statusColor: Color {
        switch state.phase {
        case .failed:
            return PerryTheme.Colors.danger
        case .paused, .confirming:
            return PerryTheme.Colors.warning
        case .verifying:
            return PerryTheme.Colors.success
        case .reporting:
            return outcomeLabel == "Stopped" ? PerryTheme.Colors.warning : PerryTheme.Colors.success
        default:
            return PerryTheme.Colors.accent
        }
    }

    private var outcomeLabel: String? {
        switch state.phase {
        case .failed:
            return "Failed"
        case .reporting:
            switch state.title.lowercased() {
            case "task complete", "task finished":
                return "Complete"
            case "task stopped":
                return "Stopped"
            default:
                return "Reporting"
            }
        default:
            return nil
        }
    }

    private var outcomeSymbol: String {
        switch outcomeLabel {
        case "Complete": return "checkmark.circle.fill"
        case "Stopped": return "stop.circle.fill"
        case "Failed": return "xmark.octagon.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var outcomeColor: Color {
        switch outcomeLabel {
        case "Complete": return PerryTheme.Colors.success
        case "Stopped": return PerryTheme.Colors.warning
        case "Failed": return PerryTheme.Colors.danger
        default: return PerryTheme.Colors.textSecondary
        }
    }

    private static func elapsedText(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private extension AgentActivityPhase {
    var displayLabel: String {
        switch self {
        case .idle: return "Ready"
        case .starting: return "Starting"
        case .working: return "In progress"
        case .paused: return "Paused"
        case .confirming: return "Awaiting approval"
        case .verifying: return "Verifying"
        case .reporting: return "Reporting"
        case .failed: return "Failed"
        }
    }
}

@MainActor
final class AgentActivityStripWindow: NSPanel {
    private let state: AgentActivityStripState
    private let onStop: () -> Void
    private var previousFrontmostApplication: NSRunningApplication?

    private var perryProcessIdentifier: pid_t {
        ProcessInfo.processInfo.processIdentifier
    }

    override var canBecomeKey: Bool { state.isExpanded }

    init(
        state: AgentActivityStripState,
        onPause: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onSteer: @escaping (String) -> Void,
        onTakeOver: @escaping () -> Void = {}
    ) {
        self.state = state
        self.onStop = onStop
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        contentView = NSHostingView(rootView: AgentActivityStripView(state: state, onPause: onPause, onResume: onResume, onStop: onStop, onRetry: onRetry, onSteer: onSteer, onTakeOver: onTakeOver, onToggleExpanded: { [weak self] in self?.setExpanded(!(self?.state.isExpanded ?? false)) }))
    }

    func show(on screen: NSScreen?) {
        guard let screen else { orderFrontRegardless(); return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 20, y: visible.maxY - frame.height - 20))
        orderFrontRegardless()
    }

#if DEBUG
    func debugInvokeStop() {
        onStop()
    }
#endif

    func setExpanded(_ expanded: Bool, animate: Bool = true) {
        let newWidth: CGFloat = expanded ? 370 : 300
        let newHeight: CGFloat = expanded ? 330 : 72
        let frameNeedsUpdate = frame.width != newWidth || frame.height != newHeight
        let styleNeedsUpdate = expanded == styleMask.contains(.nonactivatingPanel)
        guard state.isExpanded != expanded || frameNeedsUpdate || styleNeedsUpdate else { return }

        let wasExpanded = state.isExpanded
        if expanded && !wasExpanded {
            let frontmostApplication = NSWorkspace.shared.frontmostApplication
            previousFrontmostApplication = frontmostApplication?.processIdentifier == perryProcessIdentifier ? nil : frontmostApplication
        }
        state.isExpanded = expanded
        let oldFrame = frame
        let newFrame = NSRect(
            x: oldFrame.maxX - newWidth,
            y: oldFrame.maxY - newHeight,
            width: newWidth,
            height: newHeight
        )
        setFrame(newFrame, display: true, animate: animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if expanded {
            styleMask.remove(.nonactivatingPanel)
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
        } else {
            let shouldRestorePreviousApplication = NSApp.isActive
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == perryProcessIdentifier
            resignKey()
            styleMask.insert(.nonactivatingPanel)
            orderFrontRegardless()
            if shouldRestorePreviousApplication,
               let previousFrontmostApplication,
               previousFrontmostApplication.processIdentifier != perryProcessIdentifier {
                previousFrontmostApplication.activate(options: [.activateAllWindows])
            }
            self.previousFrontmostApplication = nil
        }
    }
}
