import AppKit
import SwiftUI
import PerryCore
import PerryOverlay

struct HistoryView: View {
    let store: TranscriptStore
    let activityLog: ActivityLog
    let undoableEntryIDs: (@MainActor () async -> Set<UUID>)?
    var askPerry: (() -> Void)?
    @State private var entries: [TranscriptEntry] = []
    @State private var query = ""
    @State private var selectedIDs = Set<UUID>()
    @FocusState private var historyFocused: Bool
    @State private var message: String?
    @State private var isLoading = true
    @State private var showDeleteConfirmation = false
    @State private var undoableIDs = Set<UUID>()
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !entries.isEmpty || !query.isEmpty {
                HStack {
                    Spacer()
                    TextField("Search messages, apps, steps", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 230)
                }
            }

            if isLoading {
                ProgressView("Loading history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading Perry history")
            } else if filteredEntries.isEmpty {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    WorkspaceEmptyState(title: "No history yet", message: "Everything Perry does shows up here, including what it couldn’t finish.", actionTitle: askPerry == nil ? nil : "Ask Perry", action: askPerry)
                } else {
                    WorkspaceEmptyState(face: .focused, title: "No matches", message: "Try another message, app, or step.")
                }
            } else {
                List(selection: $selectedIDs) {
                    ForEach(groupedEntries) { group in
                        Section(group.day.formatted(date: .complete, time: .omitted)) {
                            ForEach(group.entries) { entry in
                                HistoryRow(entry: entry, undoable: undoableIDs.contains(entry.id), emphasized: historyFocused && selectedIDs.contains(entry.id))
                                    .tag(entry.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .focused($historyFocused)
                .onChange(of: selectedIDs) { _, selection in
                    if !selection.isEmpty { historyFocused = true }
                }
            }

            if !entries.isEmpty || message != nil {
                HStack {
                    if let message {
                        Text(message)
                            .font(PerryTheme.Scale.secondary)
                            .foregroundStyle(PerryTheme.Colors.textSecondary)
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
        }
        .padding(20)
        .task {
            async let entrySnapshot = store.snapshot()
            async let recoverySnapshot = undoableEntryIDs?() ?? []
            entries = await entrySnapshot
            undoableIDs = await recoverySnapshot
            isLoading = false
        }
        .onChange(of: query) { _, _ in refreshSearch() }
        .notchDialog(
            "Delete \(selectedIDs.count) item\(selectedIDs.count == 1 ? "" : "s")?",
            isPresented: $showDeleteConfirmation,
            message: "I’ll delete \(selectedIDs.count == 1 ? "it" : "them") and \(selectedIDs.count == 1 ? "its transcript" : "their transcripts") from this Mac. This can’t be undone."
        ) {
            let doomed = selectedIDs
            return [NotchDialog.Action("Delete \(doomed.count) item\(doomed.count == 1 ? "" : "s")", role: .destructive) {
                deleteSelected(doomed)
            }]
        }
    }

    private func deleteSelected(_ doomed: Set<UUID>) {
        Task { @MainActor in
            if await store.delete(doomed) {
                selectedIDs.subtract(doomed)
                entries.removeAll { doomed.contains($0.id) }
                message = "Deleted \(doomed.count) item\(doomed.count == 1 ? "" : "s")."
            } else {
                message = "Couldn’t delete. \(await store.lastPersistenceError?.localizedDescription ?? "Try again.")"
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
        searchTask?.cancel()
        let query = query
        searchTask = Task {
            let matches = await store.search(query)
            let activityMatches = await activityLog.search(query)
            guard !Task.isCancelled else { return }
            if matches.isEmpty, !activityMatches.isEmpty {
                let allEntries = await store.snapshot()
                guard !Task.isCancelled else { return }
                let matchingDays = Set(activityMatches.map { Calendar.current.startOfDay(for: $0.timestamp) })
                entries = allEntries.filter { matchingDays.contains(Calendar.current.startOfDay(for: $0.finishedAt)) }
                message = "Showing items with matching activity."
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
                message = "Exported \(selectedIDs.count) item\(selectedIDs.count == 1 ? "" : "s")."
            } catch {
                message = "Couldn’t export. \(error.localizedDescription)"
            }
        }
    }
}

struct HistoryRow: View {
    let entry: TranscriptEntry
    let undoable: Bool
    let emphasized: Bool

    private var selectionText: Color { Color(nsColor: .alternateSelectedControlTextColor) }
    private var secondaryText: Color { emphasized ? selectionText : PerryTheme.Colors.textSecondary }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            lead
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.request)
                    .font(PerryTheme.Scale.body.weight(.medium))
                Text(entry.summary)
                    .font(PerryTheme.Scale.secondary)
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if undoable || entry.verified != nil {
                    HStack(spacing: 8) {
                        if undoable {
                            Label("Undo available", systemImage: "arrow.uturn.backward")
                                .font(PerryTheme.Scale.meta)
                                .foregroundStyle(secondaryText)
                        }
                        if let verified = entry.verified {
                            StatusLabel(verified ? "Checked" : "Needs checking", verified ? .ok : .attention, tint: emphasized ? selectionText : nil)
                                .font(PerryTheme.Scale.meta)
                                .foregroundStyle(emphasized ? selectionText : (verified ? PerryTheme.Colors.success : PerryTheme.Colors.caution))
                        }
                    }
                }
                HStack(spacing: 5) {
                    StatusMark(outcomeKind, tint: emphasized ? selectionText : nil)
                    Text([
                        entry.outcome.rawValue,
                        entry.providerRoute,
                        entry.finishedAt.formatted(date: .abbreviated, time: .shortened)
                    ].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(secondaryText)
                }
                .font(PerryTheme.Scale.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .foregroundStyle(emphasized ? selectionText : PerryTheme.Colors.text)
    }

    @ViewBuilder
    private var lead: some View {
        if let bundleID = entry.appBundleID {
            BrandMark(id: bundleID, name: appName(bundleID), bundleID: bundleID)
        } else {
            PerryCharacterView(pose: PerryCharacterPose(), size: PerryTheme.Icon.slot)
        }
    }

    private var outcomeKind: StatusMark.Kind {
        switch entry.outcome {
        case .completed: .ok
        case .stopped: .attention
        case .failed: .failed
        }
    }

    private func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent ?? bundleID
    }
}

private struct HistoryDay: Identifiable {
    let day: Date
    let entries: [TranscriptEntry]

    var id: Date { day }
}
