import AppKit
import SwiftUI
import PerryGuide

/// Floating intent card anchored near the cursor. Orange: click Approve/Stop.
/// Red: also requires typing the word "confirm" (PRD §4 — voice never suffices).
final class IntentCardWindow: NSPanel {
    private let card: IntentCard
    private let completion: (Bool) -> Void
    private static var active: IntentCardWindow?

    init(card: IntentCard, completion: @escaping (Bool) -> Void) {
        self.card = card
        self.completion = completion
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 132),
            styleMask: [.titled, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .modalPanel
        hidesOnDeactivate = false
        contentView = NSHostingView(rootView: IntentCardView(card: card) { [weak self] approved in
            self?.finish(approved)
        })
    }

    func showNearCursor() {
        Self.active?.close()
        Self.active = self
        let mouse = NSEvent.mouseLocation
        setFrameOrigin(NSPoint(x: mouse.x + 24, y: mouse.y - frame.height - 24))
        orderFrontRegardless()
    }

    private func finish(_ approved: Bool) {
        close()
        if Self.active === self { Self.active = nil }
        completion(approved)
    }
}

struct IntentCardView: View {
    let card: IntentCard
    let onAnswer: (Bool) -> Void

    @State private var typedConfirmation: String = ""
    private let requiredPhrase = "confirm"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(colorForTier)
                    .frame(width: 10, height: 10)
                Text(card.title)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if card.tier >= .red {
                Text("This one needs real attention. Type \"confirm\"; I won't take a voice yes for this.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("confirm", text: $typedConfirmation)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            HStack {
                Button("Stop") { onAnswer(false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Approve") {
                    if card.tier >= .red && typedConfirmation.trimmingCharacters(in: .whitespaces).lowercased() != requiredPhrase {
                        NSSound.beep()
                        return
                    }
                    onAnswer(true)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var colorForTier: Color {
        switch card.tier {
        case .orange: return .orange
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        }
    }
}
