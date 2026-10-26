import Foundation
import XCTest
import PerryBrain
@testable import Perry

private final class FakeCalendarSource: CalendarEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: CalendarAccessState
    private let grants: Bool
    private var window: (Date, Date)?
    let events: [CalendarEventSummary]

    init(state: CalendarAccessState, grants: Bool = true, events: [CalendarEventSummary] = []) {
        current = state
        self.grants = grants
        self.events = events
    }

    var state: CalendarAccessState { lock.withLock { current } }
    var requestedWindow: (Date, Date)? { lock.withLock { window } }

    func requestAccess() async throws -> Bool {
        lock.withLock { current = grants ? .granted : .denied }
        return grants
    }

    func events(from start: Date, to end: Date) -> [CalendarEventSummary] {
        lock.withLock { window = (start, end) }
        return events
    }
}

@MainActor
final class SystemCalendarTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_972_800)
    private var utc: TimeZone { TimeZone(identifier: "UTC")! }

    func testConnectAsksTheSystemOnceAndReportsTheAnswer() async throws {
        let granted = SystemCalendar(source: FakeCalendarSource(state: .notAsked, grants: true))
        let refused = SystemCalendar(source: FakeCalendarSource(state: .notAsked, grants: false))

        let first = try await granted.connect()
        let second = try await refused.connect()

        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(granted.state, .granted)
        XCTAssertEqual(refused.state, .denied)
    }

    func testConnectDoesNotPromptAgainAfterADenial() async throws {
        let source = FakeCalendarSource(state: .denied, grants: true)
        let calendar = SystemCalendar(source: source)

        let connected = try await calendar.connect()

        XCTAssertFalse(connected)
        XCTAssertEqual(source.state, .denied)
    }

    func testUpcomingListsTitlesTimesAndCalendarsInTheRequestedWindow() throws {
        let start = now.addingTimeInterval(3_600)
        let source = FakeCalendarSource(state: .granted, events: [
            CalendarEventSummary(title: "Standup", start: start, end: start.addingTimeInterval(1_800), isAllDay: false, calendarTitle: "Work", location: "Room 4"),
            CalendarEventSummary(title: "Holiday", start: start.addingTimeInterval(86_400), end: start.addingTimeInterval(172_800), isAllDay: true, calendarTitle: "Home", location: nil),
        ])
        let calendar = SystemCalendar(source: source)

        let text = try calendar.upcoming(days: 3, now: now, timeZone: utc)

        XCTAssertTrue(text.contains("2026-10-26 01:00 to 01:30 · Standup · Work · Room 4"), text)
        XCTAssertTrue(text.contains("2026-10-27 all day · Holiday · Home"), text)
        XCTAssertEqual(source.requestedWindow?.0, now)
        XCTAssertEqual(source.requestedWindow?.1, now.addingTimeInterval(3 * 86_400))
    }

    func testUpcomingClampsTheWindowAndCapsTheList() throws {
        let many = (0..<60).map {
            CalendarEventSummary(title: "E\($0)", start: now.addingTimeInterval(Double($0) * 60), end: now.addingTimeInterval(Double($0) * 60 + 30), isAllDay: false, calendarTitle: "Work", location: nil)
        }
        let source = FakeCalendarSource(state: .granted, events: many)
        let calendar = SystemCalendar(source: source)

        let text = try calendar.upcoming(days: 500, now: now, timeZone: utc)

        XCTAssertEqual(source.requestedWindow?.1, now.addingTimeInterval(14 * 86_400))
        XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count, 25)
        XCTAssertTrue(text.contains("35 more"), text)
    }

    func testUpcomingRefusesWithoutAccess() {
        let calendar = SystemCalendar(source: FakeCalendarSource(state: .notAsked))

        XCTAssertThrowsError(try calendar.upcoming(days: 7, now: now, timeZone: utc)) { error in
            XCTAssertEqual(error as? SystemCalendarError, .accessNotGranted)
        }
    }

    func testBackendOffersCalendarAsAReadOnlyService() async throws {
        let calendar = SystemCalendar(source: FakeCalendarSource(state: .granted))
        let backend = AppIntegrationBackend(
            client: RemoteIntegrationClient(transport: { _ in throw URLError(.cancelled) }),
            oauth: OAuthCoordinator(credentialStore: OAuthCredentialStore(backend: EmptyBackend())),
            permissionStore: RemoteIntegrationPermissionStore(suiteName: "dev.perry.tests.calendar.\(UUID().uuidString)"),
            calendar: calendar
        )

        let services = try await backend.services()
        let service = try XCTUnwrap(services.first { $0.id == "apple-calendar" })

        XCTAssertTrue(service.connected)
        XCTAssertFalse(service.writeEnabled)
        XCTAssertEqual(service.operations, [IntegrationOperation(name: "upcoming", description: "Read upcoming events", isWrite: false)])
    }

    func testBackendSaysHowToConnectWhenCalendarIsOff() async throws {
        let backend = AppIntegrationBackend(
            client: RemoteIntegrationClient(transport: { _ in throw URLError(.cancelled) }),
            oauth: OAuthCoordinator(credentialStore: OAuthCredentialStore(backend: EmptyBackend())),
            permissionStore: RemoteIntegrationPermissionStore(suiteName: "dev.perry.tests.calendar.\(UUID().uuidString)"),
            calendar: SystemCalendar(source: FakeCalendarSource(state: .denied))
        )

        do {
            _ = try await backend.perform(service: "apple-calendar", operation: "upcoming", arguments: .object([:]))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Settings"), error.localizedDescription)
        }
    }
}

private final class EmptyBackend: OAuthCredentialStoreBackend, @unchecked Sendable {
    func readCredential(account: String) throws -> String? { nil }
    func save(_ secret: String, account: String) throws {}
    func deleteCredential(account: String) throws {}
}
