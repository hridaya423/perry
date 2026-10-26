import AppKit
import SwiftUI

struct SystemCalendarRow: View {
    let calendar: SystemCalendar
    @State private var state: CalendarAccessState
    @State private var failure: String?
    @State private var asking = false

    init(calendar: SystemCalendar = SystemCalendar()) {
        self.calendar = calendar
        _state = State(initialValue: calendar.state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calendar")
                        .font(PerryTheme.Typography.panelBody.weight(.semibold))
                    Text("Events from your calendars on this Mac, Google and iCloud included")
                        .font(PerryTheme.Typography.note)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                }
                Spacer(minLength: 8)
                switch state {
                case .granted:
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(PerryTheme.Typography.note)
                        .foregroundStyle(PerryTheme.Colors.success)
                case .notAsked:
                    Button("Connect", action: connect)
                        .buttonStyle(InkButtonStyle())
                        .controlSize(.small)
                        .disabled(asking)
                        .accessibilityLabel("Connect Calendar")
                case .denied:
                    Button("Open Privacy Settings", action: openPrivacySettings)
                        .buttonStyle(InkButtonStyle(.secondary))
                        .controlSize(.small)
                        .accessibilityLabel("Open Calendar privacy settings")
                }
            }
            if state == .denied {
                Text("Calendar access is off for Perry. Turn it on under Privacy & Security > Calendars.")
                    .font(PerryTheme.Typography.note)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
            }
            if let failure {
                Text(failure)
                    .font(PerryTheme.Typography.note)
                    .foregroundStyle(PerryTheme.Colors.danger)
            }
        }
    }

    private func connect() {
        asking = true
        failure = nil
        Task { @MainActor in
            do {
                _ = try await calendar.connect()
            } catch {
                failure = error.localizedDescription
            }
            state = calendar.state
            asking = false
        }
    }

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }
}
