import Foundation
import SwiftUI

extension NotchPresentation {
    func askChoice(prompt: String, choices: [String]) async throws {
        let offered = Array(choices.prefix(3))
        let chosen = await ask(priority: .approval, cancelled: false) { answer in
            TaskQuestionView(prompt: prompt, choices: offered, onChoose: { _ in answer(true) }, onCancel: { answer(false) })
        }
        if !chosen { throw CancellationError() }
    }
}

struct TaskQuestionView: View {
    let prompt: String
    let choices: [String]
    let onChoose: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                    Button(choice) { onChoose(choice) }
                        .buttonStyle(InkChoiceStyle(isDefault: index == 0))
                        .keyboardShortcut(index == 0 ? .defaultAction : nil)
                }
            }
            HStack {
                Spacer()
                Button("Stop task", role: .cancel, action: onCancel)
                    .buttonStyle(.pressable)
                    .font(.callout)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(PerryTheme.Colors.text)
        .tint(PerryTheme.Colors.accent)
    }
}
