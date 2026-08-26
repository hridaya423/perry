import Foundation
import UserNotifications
import PerryGuide

/// Delivers Do-mode completion/stop notifications via UserNotifications.
final class SystemNotifier: Notifying, @unchecked Sendable {
    private static let center = UNUserNotificationCenter.current()

    init() {
        Self.center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func deliver(_ notification: TaskNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await Self.center.add(request)
    }
}
