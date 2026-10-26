import SwiftUI

enum AppsBeatPlan {
    enum Action: Equatable {
        case connect, later, comingSoon, useOwnApp
    }

    struct Tile: Equatable, Identifiable {
        let id: String
        let title: String
        let detail: String
        var action: Action
    }

    private static let known: [(keywords: [String], id: String, title: String, detail: String)] = [
        (["notion"], "notion", "Notion", "Read your pages and databases."),
        (["slack"], "slack", "Slack", "Read your channels and messages."),
        (["linear"], "linear", "Linear", "Read your issues and projects."),
        (["github"], "github", "GitHub", "Read your notifications."),
        (["gmail"], "google-gmail", "Gmail", "Read your mail."),
        (["google drive", "google docs"], "google-drive", "Google Drive", "Read files you open with Perry."),
        (["outlook", "teams", "microsoft"], "microsoft", "Microsoft 365", "Read your mail and files."),
        (["google calendar"], "google-calendar", "Google Calendar", "Read your events."),
    ]

    private static let calendar = (id: "apple-calendar", title: "Calendar", detail: "Read the events on this Mac.")

    static func tiles(apps: String, mentions: String, available: (String) -> Bool) -> [Tile] {
        let named = apps.lowercased()
        var tiles = known
            .compactMap { entry -> (Range<String.Index>, Tile)? in
                guard let range = entry.keywords.compactMap({ named.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
                return (range, Tile(id: entry.id, title: entry.title, detail: entry.detail, action: .later))
            }
            .sorted { $0.0.lowerBound < $1.0.lowerBound }
            .map(\.1)
        let everything = (named + " " + mentions).lowercased()
        if !tiles.contains(where: { $0.id == "google-calendar" }),
           ["calendar", "meeting", "schedule"].contains(where: everything.contains) {
            tiles.append(Tile(id: calendar.id, title: calendar.title, detail: calendar.detail, action: .later))
        }
        var suggested = false
        for index in tiles.indices {
            if tiles[index].id == "google-gmail" {
                tiles[index].action = .useOwnApp
            } else if !available(tiles[index].id) {
                tiles[index].action = .comingSoon
            } else if !suggested {
                tiles[index].action = .connect
                suggested = true
            }
        }
        return Array(tiles.prefix(4))
    }
}

struct AppsBeat: View {
    @ObservedObject var director: OnboardingDirector
    let controller: AppController
    let tiles: [AppsBeatPlan.Tile]
    @State private var states: [String: String] = [:]
    @State private var connected: Set<String> = []

    var body: some View {
        OnboardingBeatLayout(
            title: "Want me to reach into your apps?",
            message: tiles.isEmpty ? "Connect apps any time in Settings › Apps." : "Read-only to start. I ask before I change anything.",
            artHeight: tiles.isEmpty ? 40 : 0
        ) {
            Color.clear
        } detail: {
            if !tiles.isEmpty {
                VStack(spacing: 0) {
                    ForEach(tiles) { tile in
                        if tile.id != tiles.first?.id { SettingsDivider() }
                        row(tile)
                    }
                }
                .padding(.vertical, 2)
                .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(PerryTheme.Colors.subtleSeparator, lineWidth: 1)
                }
            }
        } actions: {
            OnboardingFooter {
                EmptyView()
            } primary: {
                Button { director.skip() } label: { OnboardingPrimaryLabel(title: "Continue") }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } trailing: {
                if connected.isEmpty && !tiles.isEmpty {
                    Button("Skip") { director.skip() }
                }
            }
        }
    }

    private func row(_ tile: AppsBeatPlan.Tile) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tile.title)
                    .font(PerryTheme.Scale.rowTitle)
                Text(states[tile.id] ?? tile.detail)
                    .font(PerryTheme.Scale.secondary)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing(tile)
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func trailing(_ tile: AppsBeatPlan.Tile) -> some View {
        if connected.contains(tile.id) {
            GrantedMark()
        } else {
            switch tile.action {
            case .connect:
                Button("Connect") { connect(tile) }
                    .buttonStyle(RowButtonStyle(prominent: true))
            case .later:
                note("Later in Settings › Apps")
            case .comingSoon:
                note("Coming soon")
            case .useOwnApp:
                Button("Use my own app") { controller.openSettings(.apps) }
                    .buttonStyle(RowButtonStyle(prominent: false))
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(PerryTheme.Scale.meta)
            .foregroundStyle(PerryTheme.Colors.textTertiary)
    }

    private func connect(_ tile: AppsBeatPlan.Tile) {
        states[tile.id] = "Opening sign-in…"
        if tile.id == "apple-calendar" {
            Task {
                let granted = (try? await SystemCalendar().connect()) == true
                finish(tile, granted ? nil : "Turn on Calendar for Perry in System Settings.")
            }
            return
        }
        guard let definition = RemoteIntegrationDefinition.catalog.first(where: { $0.id == tile.id }) else { return }
        controller.integrationConnections.connect(definition) { result in
            switch result {
            case .success: finish(tile, nil)
            case .failure(let error): finish(tile, error.localizedDescription)
            }
        }
    }

    private func finish(_ tile: AppsBeatPlan.Tile, _ failure: String?) {
        if let failure {
            states[tile.id] = failure
        } else {
            states[tile.id] = nil
            connected.insert(tile.id)
        }
    }
}
