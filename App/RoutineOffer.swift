import SwiftUI

@MainActor
final class RoutineOffer {
    private let isOnboarding: () -> Bool
    private let wasOffered: () -> Bool
    private let markOffered: () -> Void
    private let present: () -> Void

    init(
        isOnboarding: @escaping () -> Bool,
        wasOffered: @escaping () -> Bool = { PerryPreferences.routineOffered },
        markOffered: @escaping () -> Void = { PerryPreferences.routineOffered = true },
        present: @escaping () -> Void
    ) {
        self.isOnboarding = isOnboarding
        self.wasOffered = wasOffered
        self.markOffered = markOffered
        self.present = present
    }

    func taskFinished(usedGUI: Bool) {
        guard usedGUI, !isOnboarding(), !wasOffered() else { return }
        markOffered()
        present()
    }
}

struct RoutineOfferView: View {
    let onShowMe: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Show me one thing you do often.")
                .font(.headline)
            Text("Do it once while I watch. I’ll write down the steps. You check them before I save anything.")
                .font(.callout)
                .foregroundStyle(PerryTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Not now") { onNotNow() }
                    .buttonStyle(InkButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Button("Show me") { onShowMe() }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            Text("Works best for steps inside one app window. I can’t see passwords.")
                .font(PerryTheme.Typography.note)
                .foregroundStyle(PerryTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(PerryTheme.Colors.accent)
        .foregroundStyle(PerryTheme.Colors.text)
    }
}
