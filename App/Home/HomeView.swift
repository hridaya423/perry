import AppKit
import SwiftUI
import PerryBrain
import PerryCore
import PerryGuide
import PerryRuntimes

struct HomeView: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.sidebarSelection) {
                if !model.perrys.isEmpty {
                    Section("Perrys") {
                        ForEach(model.perrys) { perry in
                            Button { model.onPerrySelected?(perry) } label: {
                                Label(perry.name, systemImage: "sparkle")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section("Conversations") {
                    ForEach(model.filteredThreads) { thread in
                        Label(thread.title.isEmpty ? "Untitled" : thread.title,
                              systemImage: "bubble.left")
                        .tag(HomeModel.Selection.thread(thread.id))
                    }
                    if model.threads.isEmpty {
                        Text("No conversations yet").foregroundStyle(.secondary)
                    }
                }
                Section("Work") {
                    Label("Suggestions", systemImage: "lightbulb")
                        .badge(model.suggestions.isEmpty ? 0 : model.suggestions.count)
                        .tag(HomeModel.Selection.suggestions)
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .tag(HomeModel.Selection.history)
                    Label("Background tasks", systemImage: "tray.full")
                        .tag(HomeModel.Selection.tasks)
                    Label("Routines", systemImage: "repeat")
                        .tag(HomeModel.Selection.routines)
                    Label("Files", systemImage: "doc.on.doc")
                        .tag(HomeModel.Selection.files)
                }
                Section("Settings") {
                    Label("Settings", systemImage: "gear")
                        .tag(HomeModel.Selection.settings)
                    Label("What's New", systemImage: "sparkles")
                        .tag(HomeModel.Selection.whatsNew)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if let onboarding = model.onboarding, showsSetup {
                    HomeOnboardingView(director: onboarding, brain: model.deps.brain) {
                        model.sidebarSelection = .settings
                    }
                    Divider()
                }
                detail
            }
            .navigationTitle(navigationTitle)
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: "Search conversations")
        .toolbar {
            ToolbarItem {
                Button {
                    model.sidebarSelection = nil
                } label: {
                    Label("New conversation", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New conversation")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                UnsavedInputRecoveryButton(model: model)
                if let error = model.storageError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial)
                }
            }
        }
        .tint(PerryTheme.Colors.accent)
        .frame(minWidth: 600, minHeight: 460)
    }

    private var showsSetup: Bool {
        switch model.sidebarSelection {
        case nil, .thread: true
        default: false
        }
    }

    private var navigationTitle: String {
        switch model.sidebarSelection {
        case .thread(let id): model.threads.first { $0.id == id }.flatMap { $0.title.isEmpty ? nil : $0.title } ?? "New conversation"
        case .history: "History"
        case .tasks: "Background tasks"
        case .routines: "Routines"
        case .files: "Files"
        case .suggestions: "Suggestions"
        case .settings: "Settings"
        case .whatsNew: "What’s New"
        case nil: "Perry Home"
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.sidebarSelection {
        case .thread(let id):
            if let thread = model.threads.first(where: { $0.id == id }) {
                HomeConversationView(thread: thread, model: model)
                    .id(thread.id)
            } else {
                placeholder("Pick a thread")
            }
        case .suggestions:
            SuggestionsView(model: model)
        case .history:
            if let store = model.deps.transcriptStore, let log = model.deps.activityLog {
                HistoryView(store: store, activityLog: log, undoableEntryIDs: model.deps.undoableEntryIDs)
            } else {
                placeholder("History unavailable")
            }
        case .tasks:
            if let tasks = model.deps.backgroundTasks, let runtimes = model.deps.runtimes {
                BackgroundTasksView(backgroundTasks: tasks, runtimes: runtimes)
            } else {
                placeholder("Background tasks unavailable")
            }
        case .routines:
            RoutinesView(model: model)
        case .files:
            FilesPage(roots: model.deps.fileRoots)
        case .settings:
            if let controller = model.deps.controller {
                SettingsView(controller: controller)
            } else {
                placeholder("Settings unavailable")
            }
        case .whatsNew:
            WhatsNewView(onDone: { model.sidebarSelection = nil })
        case nil:
            HomeWelcomeView(model: model)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Morning suggestion cards (Phase 9 §4.6): read-only research over connected
/// apps, ranked; "Do it" runs the card's action as a goal on a new thread.
private struct SuggestionsView: View {
    @ObservedObject var model: HomeModel
    @AppStorage(SuggestionController.enabledKey) private var enabled = false
    @State private var editing: SuggestionCard?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Toggle("Suggestions from connected apps", isOn: $enabled)
                Text("When enabled, Perry reads recent activity in your connected apps to suggest useful tasks. It does not watch your screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
                ForEach(model.suggestions) { card in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(card.title).font(.headline)
                        if let source = card.sourceServiceName {
                            Text("From \(source)").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(card.body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Button("Do it") { model.onSuggestionAct?(card) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            Button("Dismiss") { model.onSuggestionDismiss?(card) }
                                .controlSize(.small)
                            Button("Adjust") { editing = card }
                                .controlSize(.small)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
                if model.suggestions.isEmpty {
                    Text(enabled ? "No suggestions yet. Perry checks your connected apps each morning." : "Suggestions are off. Turn them on when you’d like Perry to look for useful tasks.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .sheet(item: $editing) { card in
            SuggestionEditor(card: card) { adjusted in
                model.onSuggestionAdjust?(adjusted)
                editing = nil
            }
        }
    }
}

private struct SuggestionEditor: View {
    @State var card: SuggestionCard
    let save: (SuggestionCard) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Adjust suggestion").font(.title2.weight(.semibold))
            Text(card.title).font(.headline)
            if let source = card.sourceServiceName {
                Text("From \(source)").foregroundStyle(.secondary)
            }
            TextEditor(text: $card.body)
                .accessibilityLabel("Proposed task")
                .frame(minHeight: 120)
                .border(.separator)
            Text("Saving changes the suggestion. Choose Do it when you’re ready to run it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(card) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(card.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

/// Learned routines (Phase 9): replay goes through the foreground path, so
/// Run kicks off a typed-plan run exactly like the menu command.
private struct RoutinesView: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(model.routines) { routine in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(routine.name).font(.headline)
                            Text("\(routine.steps.count) steps · \(routine.appBundleIDs.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Run") { model.onRoutineRun?(routine) }
                            .controlSize(.small)
                        Button(role: .destructive) { model.onRoutineRemove?(routine) } label: {
                            Image(systemName: "trash")
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
                if model.routines.isEmpty {
                    Text("No routines yet — record a demonstration and Perry learns it.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }
}

/// Files Perry owns, grouped into one pile per root directory. Rows drag
/// out as real file URLs (Finder/Desktop drops work via `Transferable`
/// URL), double-click opens, ⌥-click reveals.
private struct FilesPage: View {
    let roots: [URL]

    private func files(in root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?
        .filter { !$0.hasDirectoryPath }
        .sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        } ?? []
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(roots, id: \.path) { root in
                    let files = files(in: root)
                    if !files.isEmpty {
                        Text(root.lastPathComponent)
                            .font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 12) {
                            ForEach(files, id: \.path) { url in
                                FilePileItem(url: url)
                            }
                        }
                    }
                }
                if roots.allSatisfy({ files(in: $0).isEmpty }) {
                    Text("No files yet — files Perry makes for you show up here.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }
}

private struct FilePileItem: View {
    let url: URL

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 40, height: 40)
            Text(url.lastPathComponent)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(width: 90)
        .draggable(url)
        .onTapGesture(count: 2) {
            NSWorkspace.shared.open(url)
        }
        .onTapGesture(count: 1) {}
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("Open") { NSWorkspace.shared.open(url) }
        }
        .help(url.path)
    }
}

struct UnsavedInputRecoveryButton: View {
    @ObservedObject var model: HomeModel
    @State private var isPresented = false

    var body: some View {
        if !model.unsavedInputs.isEmpty {
            Button {
                isPresented = true
            } label: {
                Label("Requests not saved (\(model.unsavedInputs.count))", systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(16)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                UnsavedInputRecoveryView(model: model).frame(width: 420)
            }
            .onChange(of: model.unsavedInputs.count) { _, count in
                if count == 0 { isPresented = false }
            }
        }
    }
}

struct UnsavedInputRecoveryView: View {
    @ObservedObject var model: HomeModel
    @State private var discarding: UUID?

    var body: some View {
        if !model.unsavedInputs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Requests not saved", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text("Keep Perry open or copy your text. Saving again won’t send it.")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(model.unsavedInputs) { input in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(input.request.text).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(input.error).font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                HStack {
                                    Button(model.savingInputs.contains(input.id) ? "Saving…" : "Save again") {
                                        model.onRetryInputSave?(input.id)
                                    }
                                    .disabled(model.savingInputs.contains(input.id))
                                    Button("Copy") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(input.request.text, forType: .string)
                                    }
                                    Spacer()
                                    Button("Discard", role: .destructive) { discarding = input.id }
                                        .disabled(model.savingInputs.contains(input.id))
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))
            .alert("Discard this unsaved request?", isPresented: Binding(
                get: { discarding != nil }, set: { if !$0 { discarding = nil } }
            ), presenting: discarding) { id in
                Button("Cancel", role: .cancel) { discarding = nil }
                Button("Discard", role: .destructive) {
                    model.onDiscardUnsavedInput?(id)
                    discarding = nil
                }
            } message: { _ in
                Text("This text hasn’t been saved. You won’t be able to recover it from Perry.")
            }
        }
    }
}
