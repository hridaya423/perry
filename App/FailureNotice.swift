import AppKit

enum FailureRecovery: Equatable {
    case settings(SettingsPage)
    case privacy(PrivacyPane)
    case thread(UUID)

    var title: String {
        switch self {
        case .settings(let page): "Open \(page.title) settings"
        case .privacy(let pane):
            switch pane {
            case .accessibility: "Open Accessibility"
            case .screenRecording: "Open Screen Recording"
            case .inputMonitoring: "Open Input Monitoring"
            case .microphone: "Open Microphone"
            }
        case .thread: "Read the full answer"
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
        let split = message.range(of: ". ")
        NotchDialog(
            title: split.map { String(message[..<$0.lowerBound]) + "." } ?? message,
            message: split.map { String(message[$0.upperBound...]) },
            cancelTitle: "Dismiss", actions: actions,
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
        case .settings(let page):
            openSettings(page)
        case .privacy(let pane):
            pane.open()
        case .thread(let id):
            homeController.homeModel.sidebarSelection = .thread(id)
            showPanel(activate: true)
        }
    }
}
