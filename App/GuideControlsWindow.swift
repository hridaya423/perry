import AppKit
import Combine
import PerryOverlay
import SwiftUI

final class GuideControlsState: ObservableObject {
    @Published var stepPosition: Int = 1
    @Published var targetLabel: String?
    @Published var markerCaptions: [String] = []
    @Published var pendingPrompt: String?
    @Published var pendingChoices: [String] = []
    /// Steps that carry a postcondition verify themselves on the user's
    /// click — the manual Done is hidden so it can't confirm what the
    /// observation can already prove (§3.4).
    @Published var hasPostcondition = false
    /// Whether a previous presented step exists to return to (§3.4 Back).
    @Published var canGoBack = false

    var mapIsPresented: Bool { !markerCaptions.isEmpty }
    var inputIsPending: Bool { pendingPrompt != nil }

    func reset() {
        stepPosition = 1
        targetLabel = nil
        markerCaptions = []
        pendingPrompt = nil
        pendingChoices = []
        hasPostcondition = false
        canGoBack = false
    }
}

struct GuideControlsView: View {
    @ObservedObject var state: GuideControlsState
    let onDone: () -> Void
    let onBack: () -> Void
    let onSkip: () -> Void
    let onRepoint: () -> Void
    let onSelectMarker: (Int) -> Void
    let onChooseInput: (Int) -> Void
    let onTakeOver: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.control) {
            if state.inputIsPending {
                inputContent
            } else if state.mapIsPresented {
                mapContent
            } else {
                stepContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(PerryTheme.Colors.accent)
        .foregroundStyle(PerryTheme.Colors.text)
    }

    private var stepContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                PerryCharacterView(pose: PerryCharacterPose(), size: 20)
                    .accessibilityHidden(true)
                Text("Step \(state.stepPosition)")
                    .font(PerryTheme.Scale.chip)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .accessibilityLabel("Guide step position")
                    .accessibilityValue("Step \(state.stepPosition)")
                Spacer()
                stopButton
            }
            if let targetLabel = state.targetLabel, !targetLabel.isEmpty {
                Text(targetLabel)
                    .font(PerryTheme.Scale.title)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Current target")
                    .accessibilityValue(targetLabel)
            }
            HStack(spacing: 8) {
                if !state.hasPostcondition {
                    Button("Done", action: onDone)
                        .buttonStyle(InkButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .accessibilityHint("Tell Perry you finished this step")
                }
                Button(action: onTakeOver) {
                    Label("Let Perry do it", systemImage: "cursorarrow.motionlines")
                }
                .buttonStyle(InkButtonStyle(.secondary))
                .accessibilityHint("Hand the rest of this task to Perry")
                Spacer(minLength: 12)
                Menu {
                    Button("Back", action: onBack)
                        .disabled(!state.canGoBack)
                    Button("Find it again", action: onRepoint)
                    Button("Skip this step", action: onSkip)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(PerryTheme.Icon.utility)
                        .foregroundStyle(PerryTheme.Colors.icon)
                        .frame(width: PerryTheme.Icon.hit, height: PerryTheme.Icon.hit)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More step options")
            }
            .controlSize(.small)
        }
    }

    private var stopButton: some View {
        WindowControlButton(systemImage: "xmark", label: "Stop guide (Esc)", action: onStop)
            .keyboardShortcut(.cancelAction)
    }

    private var mapContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pick a step to start from")
                    .font(PerryTheme.Scale.title)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                stopButton
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 8)], spacing: 8) {
                ForEach(state.markerCaptions.indices, id: \.self) { index in
                    Button { onSelectMarker(index) } label: {
                        Text("\(index + 1)")
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.06), in: Circle())
                            .overlay(Circle().strokeBorder(PerryTheme.Colors.subtleSeparator, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Start at step \(index + 1)")
                    .accessibilityHint(state.markerCaptions[index])
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var inputContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.pendingPrompt ?? "")
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                stopButton
            }
            VStack(spacing: 8) {
                ForEach(state.pendingChoices.indices, id: \.self) { index in
                    Button(state.pendingChoices[index]) { onChooseInput(index) }
                        .buttonStyle(InkChoiceStyle(isDefault: index == 0))
                        .keyboardShortcut(index == 0 ? .defaultAction : nil)
                        .accessibilityHint("Answer the guide’s question with this choice")
                }
            }
        }
    }
}

@MainActor
final class GuideControlsWindow {
    let controlsState: GuideControlsState
    private let id = UUID()
    private let content: GuideControlsView
    private let presentation: NotchPresentation

    var isVisible: Bool { presentation.contains(id) }
    var frame: NSRect { isVisible ? presentation.frame : .zero }

    init(
        state: GuideControlsState,
        onDone: @escaping () -> Void,
        onBack: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        onRepoint: @escaping () -> Void,
        onSelectMarker: @escaping (Int) -> Void,
        onChooseInput: @escaping (Int) -> Void,
        onTakeOver: @escaping () -> Void,
        onStop: @escaping () -> Void,
        presentation: NotchPresentation? = nil
    ) {
        controlsState = state
        self.presentation = presentation ?? .shared
        content = GuideControlsView(state: state, onDone: onDone, onBack: onBack, onSkip: onSkip,
                                    onRepoint: onRepoint, onSelectMarker: onSelectMarker,
                                    onChooseInput: onChooseInput, onTakeOver: onTakeOver, onStop: onStop)
    }

    func show() {
        presentation.present(id: id, priority: .guide, content: content)
    }

    func orderOut(_ sender: Any?) { presentation.remove(id) }
}
