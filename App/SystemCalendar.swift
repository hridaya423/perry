import EventKit
import Foundation

enum CalendarAccessState: Equatable, Sendable {
    case notAsked
    case granted
    case denied
}

struct CalendarEventSummary: Equatable, Sendable {
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarTitle: String
    let location: String?
}

enum SystemCalendarError: Error, Equatable, LocalizedError {
    case accessNotGranted

    var errorDescription: String? {
        "Calendar access is off. Turn it on in Perry Settings > Apps."
    }
}

protocol CalendarEventSource: Sendable {
    var state: CalendarAccessState { get }
    func requestAccess() async throws -> Bool
    func events(from start: Date, to end: Date) -> [CalendarEventSummary]
}

final class EventKitCalendarSource: CalendarEventSource, @unchecked Sendable {
    private let store = EKEventStore()

    var state: CalendarAccessState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    func events(from start: Date, to end: Date) -> [CalendarEventSummary] {
        store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
            .map {
                CalendarEventSummary(
                    title: $0.title ?? "Untitled",
                    start: $0.startDate,
                    end: $0.endDate,
                    isAllDay: $0.isAllDay,
                    calendarTitle: $0.calendar?.title ?? "Calendar",
                    location: $0.location.flatMap { $0.isEmpty ? nil : $0 }
                )
            }
    }
}

struct SystemCalendar: Sendable {
    static let maxDays = 14
    static let maxListed = 25

    private let source: any CalendarEventSource

    init(source: any CalendarEventSource = EventKitCalendarSource()) {
        self.source = source
    }

    var state: CalendarAccessState { source.state }

    func connect() async throws -> Bool {
        switch source.state {
        case .granted: return true
        case .denied: return false
        case .notAsked: return try await source.requestAccess()
        }
    }

    func upcoming(days: Int, now: Date = Date(), timeZone: TimeZone = .current) throws -> String {
        guard source.state == .granted else { throw SystemCalendarError.accessNotGranted }
        let span = min(max(days, 1), Self.maxDays)
        let events = source.events(from: now, to: now.addingTimeInterval(Double(span) * 86_400))
        guard !events.isEmpty else { return "No events in the next \(span) days." }
        let day = Self.formatter("yyyy-MM-dd", timeZone)
        let time = Self.formatter("HH:mm", timeZone)
        var lines = events.prefix(Self.maxListed).map { event in
            let when = event.isAllDay
                ? "\(day.string(from: event.start)) all day"
                : "\(day.string(from: event.start)) \(time.string(from: event.start)) to \(time.string(from: event.end))"
            return "- " + [when, event.title, event.calendarTitle, event.location].compactMap { $0 }.joined(separator: " · ")
        }
        if events.count > Self.maxListed { lines.append("…and \(events.count - Self.maxListed) more.") }
        return "Events in the next \(span) days:\n" + lines.joined(separator: "\n")
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}
