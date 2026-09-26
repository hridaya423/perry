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
                    ForEach(model.perryNames, id: \.self) { name in
                        Label(name, systemImage: "sparkle")
                    }
                    if model.perryNames.isEmpty {
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
                }
                .padding(16)
            }
            HStack {
                TextField("Reply…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                    .onChange(of: draft) { model.draftChanged(threadID: thread.id, draft: $0) }
                Button("Send") { send() }
                    .keyboardShortcut(.return, modifiers: .command)
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
    @Published var perryNames: [String] = []
    @Published var sidebarSelection: Selection?
    var deps = Deps()

    var onDraftChanged: ((UUID, String) -> Void)?
    var onSend: ((UUID, String) -> Void)?

    func draftChanged(threadID: UUID, draft: String) {
        onDraftChanged?(threadID, draft)
    }

    func send(threadID: UUID, text: String) {
        onSend?(threadID, text)
    }
}
