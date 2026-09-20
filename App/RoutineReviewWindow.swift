import AppKit
import Combine
import PerryGuide
import SwiftUI

/// Floating Watch & Learn surface. While recording it shows the bounded
/// event count and Stop; after the demonstration ends it morphs into the
/// review — the inferred steps, a name field, and Save/Discard. Nothing is
/// saved until the user reviews it.
final class RoutineReviewState: ObservableObject {
    enum Phase { case recording, review }

    @Published var phase: Phase = .recording
    @Published var eventCount = 0
    @Published var name = ""
    @Published var steps: [RoutineStep] = []

    func beginRecording() {
        phase = .recording
        eventCount = 0
        name = ""
        steps = []
    }

    func presentReview(steps: [RoutineStep]) {
        phase = .review
        self.steps = steps
    }
}

struct RoutineReviewView: View {
    @ObservedObject var state: RoutineReviewState
    let onStopRecording: () -> Void
    let onDiscard: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.control) {
            switch state.phase {
            case .recording: recordingContent
            case .review: reviewContent
            }
        }
        .padding(.horizontal, PerryTheme.Spacing.section)
        .padding(.vertical, PerryTheme.Spacing.header)
        .frame(width: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.panel, style: .continuous))
        .shadow(color: PerryTheme.Elevation.shadow, radius: 14, y: 6)
    }

    private var recordingContent: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.control) {
            Text("Recording — show me the workflow")
                .font(.headline)
            Text("\(state.eventCount) steps captured")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { onDiscard() }
                Spacer(minLength: 0)
                Button("Stop & review") { onStopRecording() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.control) {
            Text("Review what I learned")
                .font(.headline)
            TextField("Name this routine", text: $state.name)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(state.steps.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step.summary)")
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 220)
            Text("On replay I find each control fresh — nothing is replayed by coordinates.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Discard") { onDiscard() }
                Spacer(minLength: 0)
                Button("Save routine") { onSave() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

final class RoutineReviewWindow: NSPanel {
    private var anchorScreen: NSScreen?
    private var sizeObserver: AnyCancellable?

    init(
        state: RoutineReviewState,
        onStopRecording: @escaping () -> Void,
        onDiscard: @escaping () -> Void,
        onSave: @escaping () -> Void
    ) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        title = "Perry routine review"
        identifier = NSUserInterfaceItemIdentifier("PerryRoutineReview")
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        contentView = NSHostingView(
            rootView: RoutineReviewView(
                state: state,
                onStopRecording: onStopRecording,
                onDiscard: onDiscard,
                onSave: onSave
            )
        )
        sizeObserver = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.sizeToFit() }
        }
    }

    func show(on screen: NSScreen?) {
        anchorScreen = screen ?? NSScreen.main
        sizeToFit()
        orderFrontRegardless()
    }

    private func sizeToFit() {
        guard let hostingView = contentView as? NSHostingView<RoutineReviewView> else { return }
        let fitting = hostingView.fittingSize
        let newSize = NSSize(width: max(340, fitting.width), height: max(80, fitting.height))
        guard newSize != frame.size else { return }
        let visible = (anchorScreen ?? NSScreen.main)?.visibleFrame ?? .zero
        var newFrame = frame
        newFrame.size = newSize
        newFrame.origin.x = visible.maxX - newSize.width - 20
        newFrame.origin.y = visible.maxY - newSize.height - 20
        setFrame(newFrame, display: true, animate: false)
    }
}
