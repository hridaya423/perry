import AppKit
import SwiftUI
import PerryCore

@MainActor
final class HistoryWindow: NSPanel {
    override var canBecomeKey: Bool { true }

    init(store: TranscriptStore, activityLog: ActivityLog) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Perry history"
        isFloatingPanel = true
        level = .floating
        contentView = NSHostingView(rootView: HistoryView(store: store, activityLog: activityLog))
    }

    func show() {
        if let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }
}

struct HistoryView: View {
    let store: TranscriptStore
    let activityLog: ActivityLog
    @State private var entries: [TranscriptEntry] = []
    @State private var query = ""
    @State private var selectedIDs = Set<UUID>()
    @State private var message: String?
    @State private var isLoading = true
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("History")
                    .font(.title3.weight(.semibold))
                Spacer()
                TextField("Search requests, apps, steps", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 230)
            }

            if isLoading {
                ProgressView("Loading history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading Perry history")
            } else if filteredEntries.isEmpty {
                ContentUnavailableView(
                    query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No sessions yet" : "No matching sessions",
                    systemImage: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "clock" : "magnifyingglass",
                    description: Text(
                        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Completed, stopped, and failed sessions appear here."
                            : "Try another request, app, or step."
                    )
                )
            } else {
                List(selection: $selectedIDs) {
                    ForEach(groupedEntries) { group in
                        Section(group.day.formatted(date: .complete, time: .omitted)) {
                            ForEach(group.entries) { entry in
                                HistoryRow(entry: entry)
                                    .tag(entry.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                if let message {
                    Text(message)
                        .font(PerryTheme.Typography.note)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Export Markdown") { export(.markdown) }
                    .disabled(selectedIDs.isEmpty)
                Button("Export CSV") { export(.csv) }
                    .disabled(selectedIDs.isEmpty)
                Button("Delete selected…", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .disabled(selectedIDs.isEmpty)
            }
        }
        .padding(18)
        .task {
            entries = await store.snapshot()
            isLoading = false
        }
        .onChange(of: query) { _, _ in refreshSearch() }
        .confirmationDialog(
            "Delete \(selectedIDs.count) session record\(selectedIDs.count == 1 ? "" : "s")?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete selected sessions", role: .destructive) {
                deleteSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the selected sessions from history and deletes their stored transcripts from this Mac. This cannot be undone.")
        }
    }

    private func deleteSelected() {
        let doomed = selectedIDs
        Task { @MainActor in
            if await store.delete(doomed) {
                selectedIDs.subtract(doomed)
                entries.removeAll { doomed.contains($0.id) }
                message = "Deleted \(doomed.count) session record\(doomed.count == 1 ? "" : "s")."
            } else {
                message = "Delete failed: \(await store.lastPersistenceError?.localizedDescription ?? "the store could not be updated")"
            }
        }
    }

    private var filteredEntries: [TranscriptEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            [entry.request, entry.appBundleID ?? "", entry.summary, entry.steps.joined(separator: " ")]
                .joined(separator: " ")
                .lowercased()
                .contains(needle)
        }
    }

    private var groupedEntries: [HistoryDay] {
        Dictionary(grouping: filteredEntries) { Calendar.current.startOfDay(for: $0.finishedAt) }
            .map { HistoryDay(day: $0.key, entries: $0.value) }
            .sorted { $0.day > $1.day }
    }

    private func refreshSearch() {
        Task {
            let matches = await store.search(query)
            let activityMatches = await activityLog.search(query)
            if matches.isEmpty, !activityMatches.isEmpty {
                let allEntries = await store.snapshot()
                let matchingDays = Set(activityMatches.map { Calendar.current.startOfDay(for: $0.timestamp) })
                entries = allEntries.filter { matchingDays.contains(Calendar.current.startOfDay(for: $0.finishedAt)) }
                message = "Showing sessions with matching activity."
            } else {
                entries = matches
                message = nil
            }
        }
    }

    private func export(_ format: TranscriptExportFormat) {
        Task { @MainActor in
            do {
                let data = try await store.export(selectedIDs, format: format)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = format == .markdown ? "perry-history.md" : "perry-history.csv"
                panel.allowedContentTypes = format == .markdown ? [.plainText] : [.commaSeparatedText]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                message = "Exported \(selectedIDs.count) session\(selectedIDs.count == 1 ? "" : "s")."
            } catch {
                message = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: TranscriptEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.dashed")
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.request)
                    .font(.body.weight(.medium))
                Text(entry.summary)
                    .font(PerryTheme.Typography.note)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("\(entry.outcome.rawValue) · \(entry.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(PerryTheme.Typography.monoSmall)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let verified = entry.verified {
                Label(verified ? "verified" : "check needed", systemImage: verified ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(PerryTheme.Typography.panelMetadata)
                    .foregroundStyle(verified ? PerryTheme.Colors.success : PerryTheme.Colors.warning)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch entry.outcome {
        case .completed: return "checkmark.circle.fill"
        case .stopped: return "stop.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch entry.outcome {
        case .completed: return PerryTheme.Colors.success
        case .stopped: return PerryTheme.Colors.warning
        case .failed: return PerryTheme.Colors.danger
        }
    }

    private var appIcon: NSImage? {
        guard let bundleID = entry.appBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

private struct HistoryDay: Identifiable {
    let day: Date
    let entries: [TranscriptEntry]

    var id: Date { day }
}
