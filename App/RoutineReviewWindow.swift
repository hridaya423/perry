import AppKit
import Combine
import PerryGuide
import PerryOverlay
import SwiftUI

/// Floating Watch & Learn surface. While recording it shows the bounded
/// step count and Done; after the demonstration ends it morphs into the
/// review — the inferred steps, a name field, and Save/Discard. Nothing is
/// saved until the user reviews it.
final class RoutineReviewState: ObservableObject {
    enum Phase { case recording, review, fillParameters }

    @Published var phase: Phase = .recording
    @Published var eventCount = 0
    @Published var name = ""
    @Published var steps: [RoutineStep] = []
    @Published var parameterizedSteps: Set<Int> = []
    @Published var parameterPrompts: [(name: String, prompt: String)] = []
    @Published var parameterValues: [String: String] = [:]

    func beginRecording() {
        phase = .recording
        eventCount = 0
        name = ""
        steps = []
        parameterizedSteps = []
        parameterPrompts = []
        parameterValues = [:]
    }

    func presentReview(steps: [RoutineStep]) {
        phase = .review
        self.steps = steps
        parameterizedSteps = Set(steps.indices.filter {
            if case .typeText(.literal) = steps[$0].action { return true }
            return false
        }.prefix(LearnedRoutine.maximumParameters))
    }

    func toggleParameter(_ index: Int) {
        if parameterizedSteps.contains(index) {
            parameterizedSteps.remove(index)
        } else {
            parameterizedSteps.insert(index)
        }
    }

    func beginFillParameters(routineName: String, parameters: [(name: String, prompt: String)]) {
        phase = .fillParameters
        name = routineName
        parameterPrompts = parameters
        parameterValues = [:]
    }
}

struct RoutineReviewView: View {
    @ObservedObject var state: RoutineReviewState
    let onStopRecording: () -> Void
    let onDiscard: () -> Void
    let onSave: () -> Void
    let onSaveAndTry: () -> Void
    let onRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state.phase {
            case .recording: recordingContent
            case .review: reviewContent
            case .fillParameters: fillParametersContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(PerryTheme.Colors.accent)
        .foregroundStyle(PerryTheme.Colors.text)
    }

    private var recordingContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text("\(state.eventCount) \(state.eventCount == 1 ? "step" : "steps")")
                    .font(.headline)
                    .monospacedDigit()
                    .accessibilityLabel("Recording, \(state.eventCount) \(state.eventCount == 1 ? "step" : "steps")")
                Spacer(minLength: 0)
                Button("Done") { onStopRecording() }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            Text("Press Esc twice to cancel. Nothing is saved.")
                .font(PerryTheme.Typography.note)
                .foregroundStyle(PerryTheme.Colors.textSecondary)
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Check what I learned.")
                .font(.headline)
            TextField("Name this routine", text: $state.name)
                .textFieldStyle(.roundedBorder)
            ViewThatFits(in: .vertical) {
                stepList.fixedSize(horizontal: false, vertical: true)
                ScrollView { stepList }
            }
            .frame(maxHeight: 104)
            .fixedSize(horizontal: false, vertical: true)
            Text("Check each step before you save. I ask for typed text each time it runs unless you turn that off for a step.")
                .font(PerryTheme.Typography.note)
                .foregroundStyle(PerryTheme.Colors.textSecondary)
            HStack {
                Button("Discard") { onDiscard() }
                    .buttonStyle(InkButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Button("Save & try it") { onSaveAndTry() }
                    .buttonStyle(InkButtonStyle(.secondary))
                    .disabled(state.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Save routine") { onSave() }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(state.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .font(PerryTheme.Typography.panelClose)
                        .monospacedDigit()
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .frame(width: 20, height: 20)
                        .background(Color.white.opacity(0.08), in: Circle())
                    VStack(alignment: .leading, spacing: 6) {
                        Text(step.summary)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if step.requiresHuman {
                            Text("You do this one")
                                .font(PerryTheme.Typography.note)
                                .foregroundStyle(PerryTheme.Colors.textSecondary)
                        } else if case .typeText = step.action {
                            Toggle(isOn: Binding(
                                get: { state.parameterizedSteps.contains(index) },
                                set: { _ in state.toggleParameter(index) }
                            )) {
                                Text("Ask me for this text each time")
                                    .font(PerryTheme.Typography.note)
                                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                            }
                            .toggleStyle(InkSwitchStyle())
                        }
                    }
                }
            }
        }
    }

    private var fillParametersContent: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.control) {
            Text("Run “\(state.name)”")
                .font(.headline)
            ForEach(Array(state.parameterPrompts.enumerated()), id: \.offset) { index, parameter in
                TextField(
                    parameter.prompt,
                    text: Binding(
                        get: { state.parameterValues[parameter.name] ?? "" },
                        set: { state.parameterValues[parameter.name] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("Cancel") { onDiscard() }
                    .buttonStyle(InkButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Button("Run") { onRun() }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

@MainActor
final class RoutineReviewWindow {
    private let id = UUID()
    private let content: RoutineReviewView
    private let presentation: NotchPresentation

    init(
        state: RoutineReviewState,
        onStopRecording: @escaping () -> Void,
        onDiscard: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onSaveAndTry: @escaping () -> Void,
        onRun: @escaping () -> Void,
        presentation: NotchPresentation? = nil
    ) {
        self.presentation = presentation ?? .shared
        content = RoutineReviewView(state: state, onStopRecording: onStopRecording,
                                    onDiscard: onDiscard, onSave: onSave, onSaveAndTry: onSaveAndTry, onRun: onRun)
    }

    func show() {
        presentation.present(id: id, priority: .routine, content: content)
    }

    func close() { presentation.remove(id) }
}
