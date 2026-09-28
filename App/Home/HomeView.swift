import AppKit
import SwiftUI
import PerryBrain
import PerryCore
import PerryGuide
import PerryRuntimes

/// Full Home (Phase 5 §4.7): sidebar (Perrys / Threads / Routines /
/// Suggestions / Settings), a thread view with selectable reply text and a
/// per-thread draft composer, and a preview slot for files. Popped out as a
/// regular resizable NSWindow that remembers its frame. History, background
/// tasks, Settings and What's New all live here as pages — the standalone
/// windows were deleted in the Phase 5 migration.
struct HomeView: View {
    /// Injected so the view never touches the filesystem itself.
    @ObservedObject var model: HomeModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.sidebarSelection) {
                Section("Perrys") {
                    ForEach(model.perrys) { perry in
                        Button { model.onPerrySelected?(perry) } label: {
                            Label(perry.name, systemImage: "sparkle")
                        }
                        .buttonStyle(.plain)
                    }
                    if model.perrys.isEmpty {
                        Text("No Perrys yet").foregroundStyle(.secondary)
                    }
                }
                Section("Threads") {
                    ForEach(model.threads) { thread in
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
            detail
        }
        .frame(minWidth: 520, minHeight: 380)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.sidebarSelection {
        case .thread(let id):
            if let thread = model.threads.first(where: { $0.id == id }) {
                ThreadDetailView(thread: thread, model: model)
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
        case .files:
            FilesPage(roots: model.deps.fileRoots)
        case .settings:
            SettingsView()
        case .whatsNew:
            WhatsNewView(onDone: { model.sidebarSelection = nil })
        case nil:
            placeholder("Perry Home")
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Selectable reply text + per-thread draft composer.
private struct ThreadDetailView: View {
    let thread: PerryThread
    @ObservedObject var model: HomeModel
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(thread.turns.indices, id: \.self) { i in
                        let turn = thread.turns[i]
                        VStack(alignment: .leading, spacing: 4) {
                            Text(turn.question).font(.headline)
                            Text(turn.answer)
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                            if !turn.elementLabels.isEmpty {
                                Text("on: " + turn.elementLabels.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if let partial = model.streamingAnswers[thread.id], !partial.isEmpty {
                        Text(partial)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            if model.workingThreads.contains(thread.id) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Perry is working — it can act on your screen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
            }
            HStack {
                TextField("Reply…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                    .onChange(of: draft) { model.draftChanged(threadID: thread.id, draft: $0) }
                Button("Send") { send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.workingThreads.contains(thread.id))
            }
            .padding(12)
        }
        .onAppear { draft = thread.draft }
    }

    private func send() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.send(threadID: thread.id, text: draft)
        draft = ""
    }
}

/// Morning suggestion cards (Phase 9 §4.6): read-only research over connected
/// apps, ranked; "Do it" runs the card's action as a goal on a new thread.
private struct SuggestionsView: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(model.suggestions) { card in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(card.title).font(.headline)
                        Text(card.body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Button("Do it") { model.onSuggestionAct?(card) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            Button("Next") { model.onSuggestionDismiss?(card) }
                                .controlSize(.small)
                            Button("Adjust") { model.onSuggestionDismiss?(card) }
                                .controlSize(.small)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
                if model.suggestions.isEmpty {
                    Text("Nothing to suggest — Perry checks your connected apps each morning.")
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

/// View-model seam between HomeView (SwiftUI) and HomeController (AppKit):
/// the controller pushes thread updates in; user edits flow out through
/// `draftChanged`/`send`.
@MainActor
final class HomeModel: ObservableObject {
    enum Selection: Hashable {
        case thread(UUID)
        case history
        case tasks
        case files
        case suggestions
        case settings
        case whatsNew
    }

    /// App-owned services the embedded pages need — injected by
    /// HomeController's owner so the model stays testable.
    struct Deps {
        var transcriptStore: TranscriptStore?
        var activityLog: ActivityLog?
        var undoableEntryIDs: (@MainActor () async -> Set<UUID>)?
        var backgroundTasks: BackgroundTaskController?
        var runtimes: RuntimeCatalog?
        /// Directories whose files Perry owns and the user may drag out —
        /// practice sandbox today; Perry folders land here in Phase 9.
        var fileRoots: [URL] = []
    }

    @Published var threads: [PerryThread] = []
    @Published var perrys: [Perry] = []
    @Published var sidebarSelection: Selection?
    /// Threads with an agent turn in flight — drives the working row.
    @Published var workingThreads: Set<UUID> = []
    /// In-flight answers by thread, rendered as they stream in.
    @Published var streamingAnswers: [UUID: String] = [:]
    /// Morning suggestion cards (Phase 9), newest run's ranked set.
    @Published var suggestions: [SuggestionCard] = []
    var deps = Deps()

    var onDraftChanged: ((UUID, String) -> Void)?
    var onSend: ((UUID, String) -> Void)?
    /// Selecting a Perry row opens its bound thread — created on demand by
    /// the owner so `perryID` rides along for consent scoping.
    var onPerrySelected: ((Perry) -> Void)?
    /// Card actions route to the owner: `act` runs the card's body as a goal.
    var onSuggestionAct: ((SuggestionCard) -> Void)?
    var onSuggestionDismiss: ((SuggestionCard) -> Void)?

    func draftChanged(threadID: UUID, draft: String) {
        onDraftChanged?(threadID, draft)
    }

    func send(threadID: UUID, text: String) {
        onSend?(threadID, text)
    }
}
