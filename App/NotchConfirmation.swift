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

    init(title: String, detail: String, destructiveTitle: String, cancelTitle: String, presentation: NotchPresentation? = nil) {
        self.title = title
        self.detail = detail
        self.destructiveTitle = destructiveTitle
        self.cancelTitle = cancelTitle
        self.presentation = presentation ?? .shared
    }

    func confirm() async -> Bool {
        await presentation.ask(id: requestID, priority: .approval, cancelled: false) { answer in
            NotchDialogView(
                title: title,
                message: detail,
                cancelTitle: cancelTitle,
                actions: [NotchDialog.Action(destructiveTitle, role: .destructive) { answer(true) }],
                onCancel: { answer(false) }
            )
        }
    }

    func cancel() {
        presentation.cancelAsk(requestID)
    }
}
