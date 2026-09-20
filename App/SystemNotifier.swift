import Foundation
import UserNotifications
import PerryGuide

protocol AppNotificationClient: Notifying {
    func configure(
        onApprove: @escaping @MainActor @Sendable (TaskID, String, UUID) -> Void,
        onDeny: @escaping @MainActor @Sendable (TaskID, UUID) -> Void,
        onOpen: @escaping @MainActor @Sendable () -> Void
    )

    func requestAuthorization() async -> Bool
}

final class SystemNotifier: NSObject, AppNotificationClient, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private static let center = UNUserNotificationCenter.current()
    private static let approvalCategory = "perry.background.approval"
    private static let approveAction = "perry.background.approve"
    private static let denyAction = "perry.background.deny"
    private let lock = NSLock()
    private var approvalHandler: (@MainActor @Sendable (TaskID, String, UUID) -> Void)?
    private var denialHandler: (@MainActor @Sendable (TaskID, UUID) -> Void)?
    private var openHandler: (@MainActor @Sendable () -> Void)?

    override init() {
        super.init()
        Self.center.delegate = self
        Self.center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.approvalCategory,
                actions: [
                    UNNotificationAction(identifier: Self.approveAction, title: "Approve"),
                    UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive]),
                ],
                intentIdentifiers: []
            ),
        ])
    }

    func configure(
        onApprove: @escaping @MainActor @Sendable (TaskID, String, UUID) -> Void,
        onDeny: @escaping @MainActor @Sendable (TaskID, UUID) -> Void,
        onOpen: @escaping @MainActor @Sendable () -> Void
    ) {
        lock.lock()
        approvalHandler = onApprove
        denialHandler = onDeny
        openHandler = onOpen
        lock.unlock()
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await Self.center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    func deliver(_ notification: TaskNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        if let taskID = notification.taskID {
            content.userInfo["taskID"] = taskID.rawValue
        }
        if let actionID = notification.actionID {
            content.userInfo["actionID"] = actionID
        }
        if let revision = notification.taskRevision {
            content.userInfo["taskRevision"] = revision.uuidString
        }
        if notification.kind == .needsConfirmation {
            content.categoryIdentifier = Self.approvalCategory
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        do {
            try await Self.center.add(request)
        } catch {
            return
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let taskID = (response.notification.request.content.userInfo["taskID"] as? String).map { TaskID($0) }
        let actionID = response.notification.request.content.userInfo["actionID"] as? String
        let revision = (response.notification.request.content.userInfo["taskRevision"] as? String).flatMap(UUID.init(uuidString:))
        lock.lock()
        let approvalHandler = approvalHandler
        let denialHandler = denialHandler
        let openHandler = openHandler
        lock.unlock()
        Task { @MainActor in
            switch response.actionIdentifier {
            case Self.approveAction:
                if let taskID, let actionID, let revision {
                    approvalHandler?(taskID, actionID, revision)
                } else {
                    openHandler?()
                }
            case Self.denyAction:
                if let taskID, let revision {
                    denialHandler?(taskID, revision)
                } else {
                    openHandler?()
                }
            default:
                openHandler?()
            }
            completionHandler()
        }
    }
}
