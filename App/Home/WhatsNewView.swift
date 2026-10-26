import AppKit
import PerryOverlay
import SwiftUI

struct WhatsNewView: View {
    let onDone: () -> Void

    private let changes: [(symbol: String, title: String, detail: String)] = [
        ("rectangle.topthird.inset.filled", "Perry lives in your notch", "Click it for conversations, tasks, routines and files."),
        ("cursorarrow.rays", "Works next to your cursor", "I listen, point and work beside you in any app."),
        ("puzzlepiece.extension", "Connect more apps", "Add your own connectors in Settings > Apps."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                PerryCharacter(mood: .resting, size: 32)
                    .accessibilityHidden(true)
                Text("What’s new in Perry")
                    .font(PerryTheme.Scale.heading)
            }

            VStack(alignment: .leading, spacing: 16) {
                ForEach(changes, id: \.title) { change in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: change.symbol)
                            .font(PerryTheme.Scale.body.weight(.medium))
                            .foregroundStyle(PerryTheme.Colors.accent)
                            .frame(width: 30, height: 30)
                            .background(PerryTheme.Colors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.title)
                                .font(PerryTheme.Scale.body.weight(.semibold))
                            Text(change.detail)
                                .font(PerryTheme.Scale.body)
                                .foregroundStyle(PerryTheme.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            HStack(spacing: 16) {
                Button("Done", action: onDone)
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                Button("Release notes") {
                    guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md") else { return }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.plain)
                .font(PerryTheme.Scale.body)
                .foregroundStyle(PerryTheme.Colors.textSecondary)
            }
        }
        .padding(28)
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
