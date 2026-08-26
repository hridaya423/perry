import SwiftUI
import PerryGuide

/// The wake panel: type a request or hit the mic and talk.
struct SessionPanelView: View {
    weak var controller: AppController?

    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(.mint)
                Text("Perry is listening")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Done") { controller?.dismiss() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }

            TextField("Show me… / Do… / anything", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { submit() }

            HStack(spacing: 8) {
                Button {
                    controller?.beginDictation()
                } label: {
                    Image(systemName: "mic.fill")
                }
                Button("Everything") { submit(kind: .everything) }
                Button("Do it for me") { submit(kind: .do_) }
                Button("Teach me") { submit(kind: .guide) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { fieldFocused = true }
    }

    private enum RequestKind { case guide, everything, do_ }

    private func submit(kind: RequestKind? = nil) {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        text = ""

        switch kind {
        case .guide:
            controller?.startGuiding(goal: raw)
        case .everything:
            Task { await controller?.showEverything(goal: raw) }
        case .do_:
            controller?.startDoing(goal: raw)
        case nil:
            dispatchParsed(raw)
        }
    }

    private func dispatchParsed(_ raw: String) {
        switch GuideIntentParser.parse(raw) {
        case .guide(let goal):
            controller?.startGuiding(goal: goal)
        case .showEverything(let goal):
            Task { await controller?.showEverything(goal: goal) }
        case .doTask(let goal):
            controller?.startDoing(goal: goal)
        case .dismiss:
            controller?.dismiss()
        case .notAGuideRequest:
            controller?.startGuiding(goal: raw)
        }
    }
}
