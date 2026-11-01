import Foundation
import SwiftUI

@MainActor
final class NotchConfirmation {
    let requestID = UUID()
    private let title: String
    private let detail: String
    private let confirmTitle: String
    private let cancelTitle: String
    private let destructive: Bool
    private let presentation: NotchPresentation

    init(title: String, detail: String, confirmTitle: String, cancelTitle: String, destructive: Bool = true, presentation: NotchPresentation? = nil) {
        self.title = title
        self.detail = detail
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
        self.destructive = destructive
        self.presentation = presentation ?? .shared
    }

    func confirm() async -> Bool {
        await presentation.ask(id: requestID, priority: .approval, cancelled: false) { answer in
            NotchDialogView(
                title: title,
                message: detail,
                cancelTitle: cancelTitle,
                actions: [NotchDialog.Action(confirmTitle, role: destructive ? .destructive : nil) { answer(true) }],
                onCancel: { answer(false) },
                confirmsOnReturn: !destructive
            )
        }
    }

    func cancel() {
        presentation.cancelAsk(requestID)
    }
}
