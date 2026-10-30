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
    @Published var hasPostcondition = false
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
                    .accessibilityLabel("Current control")
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
                    Label("Do it for me", systemImage: "cursorarrow.motionlines")
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
                .buttonStyle(.pressable)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More step options")
            }
            .controlSize(.small)
        }
    }

    private var stopButton: some View {
        WindowControlButton(systemImage: "xmark", label: "Stop guide", action: onStop)
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
                            .background(PerryTheme.Colors.veil(0.06), in: Circle())
                            .overlay(Circle().strokeBorder(PerryTheme.Colors.subtleSeparator, lineWidth: 1))
                    }
                    .buttonStyle(.pressable)
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
