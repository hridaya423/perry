import AppKit
import Combine
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
            title = "Starting"
            detail = "Getting ready"
        case .guiding:
            phase = .working
            title = "Guiding you"
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
                    title = "Done"
                    detail = "Saving to History"
                case .blocked:
                    phase = .reporting
                    title = "Stopped"
                    detail = "Saving to History"
                case .failed:
                    phase = .failed
                    title = "Failed"
                    detail = "Saving to History"
                }
            } else {
                switch execution.lifecycle {
                case .starting:
                    phase = .starting
                    title = "Starting"
                    detail = "You have 5 seconds to stop"
                case .running:
                    phase = .working
                    title = "Working"
                    if let step = execution.stepEvidence.last {
                        title = "Step \(step.index + 1) of \(max(execution.totalSteps, step.index + 1))"
                        detail = step.summary
                    } else {
                        detail = "Starting the first step"
                    }
                case .paused:
                    phase = .paused
                    title = "Paused"
                    detail = "Resume or stop when ready"
                case .awaitingApproval(let approval):
                    phase = .confirming
                    title = "Needs your OK"
                    detail = approval.actionSummary
                case .verifying:
                    phase = .verifying
                    title = "Done"
                    detail = "Checking the result"
                case .stopping:
                    phase = .reporting
                    title = "Stopped"
                    detail = "Stopping…"
                case .finalizing(.verifying):
                    phase = .verifying
                    title = "Done"
                    detail = "Checking the result"
                case .finalizing(.stopping):
                    phase = .reporting
                    title = "Stopped"
                    detail = "Stopping…"
                }
            }
        case .reporting(let report):
            phase = .reporting
            title = report.outcome == .completed ? "Done" : "Stopped"
            detail = report.summary
        case .failed(let failure):
            phase = .failed
            title = "Failed"
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
            return evidence.evidence.map { "Checked: \($0)" } ?? "Checked"
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
    @State private var typedSteeringExpanded = false
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .onChange(of: typedSteeringExpanded) { _, expanded in
            if expanded {
                focusSteering()
            } else {
                steeringFocused = false
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.header) {
            Button { onToggleExpanded() } label: {
                HStack(alignment: .top, spacing: PerryTheme.Spacing.header) {
                    PerryCharacter(mood: state.phase == .failed ? .needsYou : state.phase == .paused ? .resting : .working, size: 24)
                        .padding(.trailing, 4)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: PerryTheme.Spacing.tight) {
                        HStack(alignment: .firstTextBaseline, spacing: PerryTheme.Spacing.control) {
                            Text(state.title)
                                .font(PerryTheme.Scale.rowTitle)
                                .lineLimit(state.isExpanded ? nil : 1)
                            if let tier = state.tier {
                                Text(tier.riskLabel)
                                    .font(PerryTheme.Scale.section)
                                    .foregroundStyle(color(for: tier))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(color(for: tier).opacity(0.15), in: Capsule())
                                    .accessibilityLabel("Risk")
                                    .accessibilityValue(tier.riskLabel)
                            }
                            if let startedAt = state.startedAt {
                                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                                    Text(Self.elapsedText(since: startedAt, now: context.date))
                                        .font(PerryTheme.Scale.meta)
                                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                                }
                            }
                        }
                        if !state.detail.isEmpty {
                            Text(state.detail)
                                .font(PerryTheme.Scale.secondary)
                                .foregroundStyle(PerryTheme.Colors.textSecondary)
                                .lineLimit(state.isExpanded ? nil : 1)
                        }
                        if let progress = state.progress {
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(PerryTheme.Colors.subtleSeparator)
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(PerryTheme.Colors.accent)
                                            .frame(width: proxy.size.width * min(max(progress, 0), 1))
                                    }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 4)
                                .padding(.top, 4)
                                .animation(.smooth(duration: 0.4), value: progress)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            controls
        }
    }

    private var expandedDetails: some View {
        ViewThatFits(in: .vertical) {
            detailsContent.fixedSize(horizontal: false, vertical: true)
            ScrollView { detailsContent }
                .scrollIndicators(.automatic)
        }
        .frame(maxHeight: 180)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Expanded task details")
    }

    private var detailsContent: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.control) {
            if state.steps.isEmpty {
                if state.detail.isEmpty || state.phase == .failed || state.phase == .reporting {
                    Text(emptyStepsLabel)
                        .font(PerryTheme.Scale.secondary)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Task steps")
                        .accessibilityValue(emptyStepsLabel)
                }
            } else {
                stepsDetails
            }
            if let verification = state.verification {
                Text(verification)
                    .font(PerryTheme.Scale.secondary)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Task verification")
                    .accessibilityValue(verification)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, PerryTheme.Spacing.tight)
    }

    private var stepsDetails: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.control) {
            Text("Steps")
                .font(PerryTheme.Scale.secondary)
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
                                .font(PerryTheme.Scale.chip)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(step.reversible ? "Can be undone" : "Can’t be undone")
                                .font(PerryTheme.Scale.secondary)
                                .foregroundStyle(PerryTheme.Colors.textSecondary)
                            if let verification = step.verification {
                                Text(verification)
                                    .font(PerryTheme.Scale.chip)
                                    .foregroundStyle(verification.hasPrefix("Checked") ? PerryTheme.Colors.success : PerryTheme.Colors.warning)
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
            HStack(spacing: 6) {
                Text("Hold")
                Keycap(TalkGesture.keys)
                Text("to steer")
            }
            .font(PerryTheme.Scale.secondary)
            .foregroundStyle(PerryTheme.Colors.textSecondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(TalkGesture.steer)
            DisclosureGroup(isExpanded: $typedSteeringExpanded) {
                HStack(spacing: PerryTheme.Spacing.control) {
                    TextField("Steer before the next step", text: $steering)
                        .textFieldStyle(.roundedBorder)
                        .font(PerryTheme.Scale.secondary)
                        .focused($steeringFocused)
                        .accessibilityLabel("Steering instruction")
                        .accessibilityHint("Type an instruction for Perry before the next task step")
                        .accessibilityValue(trimmedSteering.isEmpty ? "No instruction entered" : trimmedSteering)
                        .onSubmit { sendSteering() }
                    Button("Send") { sendSteering() }
                        .buttonStyle(InkButtonStyle())
                        .controlSize(.small)
                        .disabled(steeringIsEmpty)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel("Send steering instruction")
                        .accessibilityHint("Send this instruction before my next step")
                }
                .padding(.top, PerryTheme.Spacing.tight)
            } label: {
                Text("Type instead")
                    .font(PerryTheme.Scale.secondary)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 6) {
            if state.phase == .working || state.phase == .starting {
                Button { onPause() } label: {
                    Label("Pause", systemImage: "pause")
                }
                .accessibilityLabel("Pause task")
                .help("Pause before the next step")
            } else if state.phase == .paused {
                Button { onResume() } label: {
                    Label("Resume", systemImage: "play")
                }
                .accessibilityLabel(state.handedToHuman ? "Continue" : "Resume task")
                .help(state.handedToHuman ? "Replan the remaining work from the current screen" : "Resume the task")
            }
            if state.takeOverIsAvailable {
                Button { onTakeOver() } label: {
                    Label("Take over", systemImage: "hand.raised")
                }
                .accessibilityLabel("Take over this step")
                .help("Pause so you can do the step yourself. Perry replans the rest.")
            }
            if state.retryIsAvailable {
                Button("Try again") { onRetry() }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.small)
                    .accessibilityLabel("Try again")
                    .help("Run the task again")
            }
            if state.stopIsAvailable {
                Button(role: .destructive) { onStop() } label: {
                    Label("Stop", systemImage: "stop")
                }
                .accessibilityLabel("Stop task")
                .help("Stop the task")
            }
        }
        .buttonStyle(ChipStyle(iconOnly: !state.isExpanded))
        .fixedSize()
    }

    private func sendSteering() {
        let request = trimmedSteering
        guard !request.isEmpty, state.steeringIsAvailable else { return }
        onSteer(request)
        steering = ""
    }

    private func focusSteering() {
        DispatchQueue.main.async {
            guard state.isExpanded, typedSteeringExpanded else { return }
            steeringFocused = true
        }
    }

    private var steeringIsEmpty: Bool {
        trimmedSteering.isEmpty
    }

    private var emptyStepsLabel: String {
        state.phase == .failed || state.phase == .reporting
            ? "I didn’t change anything."
            : "Waiting for the first step."
    }

    private var trimmedSteering: String {
        steering.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var headerAccessibilityValue: String {
        var parts = [state.title, state.phase.displayLabel]
        if !state.detail.isEmpty {
            parts.append(state.detail)
        }
        if let progress = state.progress {
            parts.append("\(Int(progress * 100)) percent complete")
        }
        return parts.joined(separator: ", ")
    }

    private func stepAccessibilityValue(_ step: AgentActivityStep) -> String {
        var parts = [
            step.summary,
            step.reversible ? "Can be undone" : "Can’t be undone"
        ]
        if let verification = step.verification {
            parts.append(verification)
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
        case .confirming: return "Needs your OK"
        case .verifying: return "Checking"
        case .reporting: return "Saving"
        case .failed: return "Failed"
        }
    }
}

@MainActor
final class AgentActivityStripWindow {
    private let id = UUID()
    private let state: AgentActivityStripState
    private let onStop: () -> Void
    private let presentation: NotchPresentation
    private var content: AnyView = AnyView(EmptyView())

    init(
        state: AgentActivityStripState,
        onPause: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onSteer: @escaping (String) -> Void,
        onTakeOver: @escaping () -> Void = {},
        presentation: NotchPresentation? = nil
    ) {
        self.state = state
        self.onStop = onStop
        self.presentation = presentation ?? .shared
        content = AnyView(AgentActivityStripView(state: state, onPause: onPause,
            onResume: onResume, onStop: onStop, onRetry: onRetry, onSteer: onSteer,
            onTakeOver: onTakeOver, onToggleExpanded: { [weak self] in
                guard let self else { return }
                self.setExpanded(!self.state.isExpanded)
            }))
    }

    func show() {
        presentation.present(id: id, priority: .activity, content: content, reveal: state.isExpanded)
    }

    func orderOut(_ sender: Any?) { presentation.remove(id) }

    func setExpanded(_ expanded: Bool, animate: Bool = true) {
        state.isExpanded = expanded
    }

#if DEBUG
    func debugInvokeStop() { onStop() }
#endif
}
