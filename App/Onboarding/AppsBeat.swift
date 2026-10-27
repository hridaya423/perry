import AppKit
import SwiftUI

enum AppsBeatPlan {
    struct Tile: Equatable, Identifiable {
        let id: String
        let title: String
        let detail: String
        let bundleID: String?
    }

    private static let known: [(keywords: [String], tile: Tile)] = [
        (["notion"], Tile(id: "notion", title: "Notion", detail: "Read your pages and databases.", bundleID: "notion.id")),
        (["slack"], Tile(id: "slack", title: "Slack", detail: "Read your channels and messages.", bundleID: "com.tinyspeck.slackmacgap")),
        (["linear"], Tile(id: "linear", title: "Linear", detail: "Read your issues and projects.", bundleID: "com.linear")),
        (["github"], Tile(id: "github", title: "GitHub", detail: "Read your notifications.", bundleID: "com.github.GitHubClient")),
        (["google drive", "google docs"], Tile(id: "google-drive", title: "Google Drive", detail: "Read files you open with Perry.", bundleID: "com.google.drivefs")),
        (["outlook", "teams", "microsoft"], Tile(id: "microsoft", title: "Microsoft 365", detail: "Read your mail, calendar and files.", bundleID: "com.microsoft.Outlook")),
        (["google calendar"], Tile(id: "google-calendar", title: "Google Calendar", detail: "Read your events.", bundleID: nil)),
    ]

    private static let calendar = Tile(id: "apple-calendar", title: "Calendar", detail: "Read the events on this Mac.", bundleID: "com.apple.iCal")

    static func tiles(apps: String, mentions: String, available: (String) -> Bool) -> [Tile] {
        let named = apps.lowercased()
        var tiles = known
            .compactMap { entry -> (Range<String.Index>, Tile)? in
                guard let range = entry.keywords.compactMap({ named.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
                return (range, entry.tile)
            }
            .sorted { $0.0.lowerBound < $1.0.lowerBound }
            .map(\.1)
        let everything = (named + " " + mentions).lowercased()
        if !tiles.contains(where: { $0.id == "google-calendar" }),
           ["calendar", "meeting", "schedule"].contains(where: everything.contains) {
            tiles.append(calendar)
        }
        return Array(tiles.filter { available($0.id) }.prefix(3))
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
            title: "Connect your apps",
            message: tiles.isEmpty ? "Connect apps any time in Settings > Apps." : "Read-only to start. I ask before I change anything."
        ) {
            EmptyView()
        } detail: {
            if !tiles.isEmpty {
                VStack(spacing: 0) {
                    ForEach(tiles) { tile in
                        if tile.id != tiles.first?.id { SettingsDivider() }
                        row(tile)
                    }
                }
                .padding(.vertical, 2)
                .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: PerryTheme.Radius.card, style: .continuous)
                        .strokeBorder(PerryTheme.Colors.subtleSeparator, lineWidth: 1)
                }
            }
        } actions: {
            OnboardingFooter {
                EmptyView()
            } primary: {
                Button { director.skip() } label: { OnboardingPrimaryLabel(title: connected.isEmpty && !tiles.isEmpty ? "Skip" : "Continue") }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } trailing: {
                EmptyView()
            }
        }
    }

    private func row(_ tile: AppsBeatPlan.Tile) -> some View {
        HStack(spacing: 12) {
            BrandMark(id: tile.id, name: tile.title, bundleID: tile.bundleID)
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
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func trailing(_ tile: AppsBeatPlan.Tile) -> some View {
        if connected.contains(tile.id) {
            GrantedMark(title: "Connected")
        } else {
            Button("Connect") { connect(tile) }
                .buttonStyle(RowButtonStyle())
        }
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
            case .failure: finish(tile, "Couldn’t connect to \(tile.title). Try again.")
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
