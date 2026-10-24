import Foundation
import SwiftUI

@MainActor
final class NotchConfirmation {
    let requestID = UUID()
    private let title: String
    private let detail: String
    private let destructiveTitle: String
    private let cancelTitle: String
    private let presentation: NotchPresentation
    private var continuation: CheckedContinuation<Bool, Never>?
    private var finished = false

    init(title: String, detail: String, destructiveTitle: String, cancelTitle: String, presentation: NotchPresentation? = nil) {
        self.title = title
        self.detail = detail
        self.destructiveTitle = destructiveTitle
        self.cancelTitle = cancelTitle
        self.presentation = presentation ?? .shared
    }

    func confirm() async -> Bool {
        guard !finished, continuation == nil else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                guard !Task.isCancelled else {
                    finished = true
                    continuation.resume(returning: false)
                    return
                }
                self.continuation = continuation
                presentation.present(id: requestID, priority: .approval, content: NotchDialogView(
                    title: title,
                    message: detail,
                    cancelTitle: cancelTitle,
                    actions: [NotchDialog.Action(destructiveTitle, role: .destructive) { [weak self] in self?.resolve(true) }],
                    onCancel: { [weak self] in self?.cancel() }
                ))
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func resolve(_ confirmed: Bool) {
        finish(confirmed)
    }

    func cancel() {
        finish(false)
    }

    private func finish(_ confirmed: Bool) {
        guard !finished else { return }
        finished = true
        presentation.remove(requestID)
        continuation?.resume(returning: confirmed)
        continuation = nil
    }
}
