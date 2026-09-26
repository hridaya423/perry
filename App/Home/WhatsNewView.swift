import AppKit
import SwiftUI

struct WhatsNewView: View {
    let onDone: () -> Void

    private let changes = [
        "Live sessions now move from a real screen circle to click-advanced teaching, sandboxed work, verification, and history.",
        "Push-to-talk, partial transcripts, barge-in, audio-route recovery, and clipboard fallback keep voice usable when hardware changes.",
        "The agent strip exposes every step, trust tier, pause, steer, retry, and read-back result while Perry works."
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(PerryTheme.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Perry got sharper.")
                        .font(.title3.weight(.semibold))
                    Text("A local-first live session you can see and stop.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(changes, id: \.self) { change in
                        Label(change, systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .labelStyle(WhatsNewLabelStyle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Open CHANGELOG.md") {
                    guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md") else { return }
                    NSWorkspace.shared.open(url)
                }
                Spacer()
                Button("Close What’s New", action: onDone)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(minWidth: 396, maxWidth: .infinity, minHeight: 316, maxHeight: .infinity)
    }
}

private struct WhatsNewLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 8) {
            configuration.icon
                .foregroundStyle(PerryTheme.Colors.accent)
            configuration.title
        }
    }
}
