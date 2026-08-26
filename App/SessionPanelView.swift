import SwiftUI
import PerryGuide
import PerryOverlay

/// The wake panel: type a request or hit the mic and talk.
/// Ink-on-glass: one material surface, charcoal ink, single mint accent,
/// the buddy himself answering the "who am I talking to" question.
struct SessionPanelView: View {
    weak var controller: AppController?

    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    private static let accent = Color(red: 0.204, green: 0.827, blue: 0.600)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PerrySpriteView(animation: .idle, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Perry")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("here. what are we doing?")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    controller?.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            TextField("show me… or do it for me", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($fieldFocused)
                .onSubmit { submit() }

            HStack(spacing: 8) {
                Button {
                    controller?.beginDictation()
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Self.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Talk instead")

                Spacer()

                Button("Everything") { submit(kind: .everything) }
                Button("Teach me") { submit(kind: .guide) }
                Button("Do it") { submit(kind: .do_) }
                    .buttonStyle(.borderedProminent)
                    .tint(Self.accent)
            }
            .controlSize(.small)
            .font(.system(size: 11, weight: .medium))
        }
        .padding(16)
        .frame(width: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        .tint(Self.accent)
        .onAppear { fieldFocused = true }
    }

    private enum RequestKind { case guide, everything, do_ }

    private func submit(kind: RequestKind? = nil) {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        text = ""
        SoundPlayer.play(.send)

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
