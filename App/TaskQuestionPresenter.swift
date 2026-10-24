import Foundation
import SwiftUI

@MainActor
final class TaskQuestionPresenter {
    let requestID = UUID()
    private let prompt: String
    private let choices: [String]
    private let presentation: NotchPresentation
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    init(prompt: String, choices: [String], presentation: NotchPresentation? = nil) {
        self.prompt = prompt
        self.choices = Array(choices.prefix(3))
        self.presentation = presentation ?? .shared
    }

    func ask() async throws {
        guard !finished else { throw CancellationError() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                presentation.present(id: requestID, priority: .approval, content: TaskQuestionView(
                    prompt: prompt,
                    choices: choices,
                    onChoose: { [weak self] choice in self?.answer(choice) },
                    onCancel: { [weak self] in self?.cancel() }
                ), onDismiss: { [weak self] in self?.cancel() })
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func answer(_ choice: String) {
        guard choices.contains(choice) else { return }
        finish(.success(()))
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        presentation.remove(requestID)
        continuation?.resume(with: result)
        continuation = nil
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
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 340, maxWidth: 500, alignment: .leading)
        .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.panel, style: .continuous))
        .foregroundStyle(PerryTheme.Colors.text)
        .tint(PerryTheme.Colors.accent)
    }
}
