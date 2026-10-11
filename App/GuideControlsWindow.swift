import AppKit
import Combine
import SwiftUI

/// Floating guide-controls surface shown while Perry is pointing at a target.
/// Step mode: position, current target, and Done/Skip/Re-point/Stop — the
/// control alternative to clicking the highlighted element. Map mode: numbered
/// buttons matching the visible-path markers, so marker picking is never a
/// click-only gesture. Stop is also reachable via Escape.
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

    var mapIsPresented: Bool { !markerCaptions.isEmpty }
    var inputIsPending: Bool { pendingPrompt != nil }

    func reset() {
        stepPosition = 1
        targetLabel = nil
        markerCaptions = []
        pendingPrompt = nil
        pendingChoices = []
        hasPostcondition = false
    }
}

struct GuideControlsView: View {
    @ObservedObject var state: GuideControlsState
    let onDone: () -> Void
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
        .padding(.horizontal, PerryTheme.Spacing.section)
        .padding(.vertical, PerryTheme.Spacing.header)
        .frame(width: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.panel, style: .continuous))
        .shadow(color: PerryTheme.Elevation.shadow, radius: 14, y: 6)
        .tint(PerryTheme.Colors.accent)
        .foregroundStyle(PerryTheme.Colors.text)
    }

    private var stepContent: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.control) {
            HStack(spacing: PerryTheme.Spacing.control) {
                Text("Step \(state.stepPosition)")
                    .font(PerryTheme.Typography.panelMetadata.weight(.semibold))
                    .accessibilityLabel("Guide step position")
                    .accessibilityValue("Step \(state.stepPosition)")
                if let targetLabel = state.targetLabel, !targetLabel.isEmpty {
                    Text("· \(targetLabel)")
                        .font(PerryTheme.Typography.panelMetadata)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .lineLimit(1)
                        .accessibilityLabel("Current target")
                        .accessibilityValue(targetLabel)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: PerryTheme.Spacing.control) {
                if !state.hasPostcondition {
                    Button("Done") { onDone() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityHint("Tell Perry you finished this step")
                }
                Button("Skip") { onSkip() }
                    .accessibilityHint("Skip this step")
                Button("Re-point") { onRepoint() }
                    .accessibilityHint("Find the target again")
                Button("Do it") { onTakeOver() }
                    .accessibilityHint("Hand the rest of this task to Perry")
                Spacer(minLength: 0)
                Button(role: .destructive) { onStop() } label: {
                    Text("Stop")
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityHint("Stop the guide")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var mapContent: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.control) {
            Text("Pick a step to start from")
                .font(PerryTheme.Typography.panelMetadata.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: PerryTheme.Spacing.control)], spacing: PerryTheme.Spacing.control) {
                ForEach(state.markerCaptions.indices, id: \.self) { index in
                    Button { onSelectMarker(index) } label: {
                        Text("\(index + 1)")
                            .font(PerryTheme.Typography.panelMetadata.weight(.semibold))
                            .frame(width: 28, height: 28)
                            .background(PerryTheme.Colors.canvas, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Start at step \(index + 1)")
                    .accessibilityHint(state.markerCaptions[index])
                }
            }
            .accessibilityElement(children: .contain)
            HStack {
                Spacer(minLength: 0)
                Button(role: .destructive) { onStop() } label: {
                    Text("Stop")
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
                .accessibilityHint("Stop the guide")
            }
        }
    }

    private var inputContent: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.control) {
            Text(state.pendingPrompt ?? "")
                .font(PerryTheme.Typography.panelMetadata.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            ForEach(state.pendingChoices.indices, id: \.self) { index in
                Button(state.pendingChoices[index]) { onChooseInput(index) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint("Answer the guide’s question with this choice")
            }
            HStack {
                Spacer(minLength: 0)
                Button(role: .destructive) { onStop() } label: {
                    Text("Stop")
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
                .accessibilityHint("Stop the guide")
            }
        }
    }
}

final class GuideControlsWindow: NSPanel {
    let controlsState: GuideControlsState
    private var sizeObserver: AnyCancellable?
    private var anchorScreen: NSScreen?

    init(
        state: GuideControlsState,
        onDone: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        onRepoint: @escaping () -> Void,
        onSelectMarker: @escaping (Int) -> Void,
        onChooseInput: @escaping (Int) -> Void,
        onTakeOver: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.controlsState = state
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        title = "Perry guide controls"
        identifier = NSUserInterfaceItemIdentifier("PerryGuideControls")
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        let hostingView = NSHostingView(
            rootView: GuideControlsView(
                state: state,
                onDone: onDone,
                onSkip: onSkip,
                onRepoint: onRepoint,
                onSelectMarker: onSelectMarker,
                onChooseInput: onChooseInput,
                onTakeOver: onTakeOver,
                onStop: onStop
            )
        )
        contentView = hostingView
        sizeObserver = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.sizeToFit() }
        }
    }

    /// Anchored top-right like the activity strip; content grows downward so
    /// the panel never leaves the screen or jumps between steps.
    func show(on screen: NSScreen?) {
        anchorScreen = screen ?? NSScreen.main
        sizeToFit()
        orderFrontRegardless()
    }

    private func sizeToFit() {
        guard let hostingView = contentView as? NSHostingView<GuideControlsView> else { return }
        let fitting = hostingView.fittingSize
        let newSize = NSSize(width: max(320, fitting.width), height: max(56, fitting.height))
        guard newSize != frame.size else { return }
        let visible = (anchorScreen ?? NSScreen.main)?.visibleFrame ?? .zero
        var newFrame = frame
        newFrame.size = newSize
        newFrame.origin.x = visible.maxX - newSize.width - 20
        newFrame.origin.y = visible.maxY - newSize.height - 20
        setFrame(newFrame, display: true, animate: false)
    }
}
