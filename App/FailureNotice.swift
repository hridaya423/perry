import AppKit

enum FailureRecovery: Equatable {
    case settings(SettingsTab)
    case privacy(String)

    var title: String {
        switch self {
        case .settings(let tab): "Open \(tab.tabTitle) settings"
        case .privacy: "Open Privacy settings"
        }
    }
}

extension AppController {
    private static let failureNoticeID = UUID()

    func presentFailure(_ message: String, recovery: FailureRecovery?) {
        clearFailure()
        let panelWasVisible = sessionPanel.isVisible
        var recovered = false
        let actions = recovery.map { recovery in
            [NotchDialog.Action(recovery.title) { [weak self] in
                recovered = true
                self?.recover(with: recovery)
            }]
        } ?? []
        NotchDialog(
            title: message, cancelTitle: "Dismiss", actions: actions,
            id: Self.failureNoticeID, priority: .activity,
            onClearSource: { [weak self] in
                if !recovered && !panelWasVisible { self?.hidePanel() }
            }
        ).present()
    }

    func clearFailure() {
        NotchPresentation.shared.remove(Self.failureNoticeID)
    }

    private func recover(with recovery: FailureRecovery) {
        switch recovery {
        case .settings(let tab):
            openSettings(tab: tab)
        case .privacy(let anchor):
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
