import EventKit
import PerryCapture
import Speech
import UserNotifications

enum SystemGrant: CaseIterable, Sendable {
    case speech, notifications, calendar
}

struct SystemGrants: Equatable, Sendable {
    var speech: PerryPermissionStatus
    var notifications: PerryPermissionStatus
    var calendar: PerryPermissionStatus

    static let answered = SystemGrants(speech: .granted, notifications: .granted, calendar: .granted)

    var allAnswered: Bool { SystemGrant.allCases.allSatisfy { self[$0] != .notDetermined } }

    subscript(grant: SystemGrant) -> PerryPermissionStatus {
        switch grant {
        case .speech: speech
        case .notifications: notifications
        case .calendar: calendar
        }
    }

    static func probe() async -> SystemGrants {
        let notifications: PerryPermissionStatus = switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
        let speech: PerryPermissionStatus = switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
        let calendar: PerryPermissionStatus = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
        return SystemGrants(speech: speech, notifications: notifications, calendar: calendar)
    }

    static func request(_ grant: SystemGrant) async {
        switch grant {
        case .speech:
            _ = await DictationController.requestPermission()
        case .notifications:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        case .calendar:
            _ = try? await EKEventStore().requestFullAccessToEvents()
        }
    }
}
