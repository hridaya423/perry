import AppKit
import SwiftUI
import PerryBrain
import PerryCore
import PerryGuide
import PerryOverlay
import PerryRuntimes

/// Morning suggestion cards (Phase 9 §4.6): read-only research over connected
/// apps, ranked; "Do it" runs the card's action as a goal on a new thread.
struct SuggestionsView: View {
    @ObservedObject var model: HomeModel
    @AppStorage(PerryPreferences.$suggestionsEnabled.key) private var enabled = false
    @State var editing: SuggestionCard?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A head start on your day")
                            .font(PerryTheme.Scale.title)
                        Text("Each morning Perry reads recent activity in your connected apps and suggests a few useful tasks. It never watches your screen.")
                            .font(PerryTheme.Scale.body)
                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle(isOn: $enabled) {}
                        .toggleStyle(InkSwitchStyle())
                        .fixedSize()
                        .accessibilityLabel("Suggestions from connected apps")
                }
                .padding(16)
                .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.bottom, 6)
                ForEach(model.suggestions) { card in
                    suggestionCard(card)
                }
                if !enabled {
                    suggestionCard(SuggestionCard(title: "Reply to Maya about the launch date", body: "She asked in Slack yesterday and the thread is still open.", score: 0), example: true)
                        .opacity(0.7)
                        .accessibilityHidden(true)
                }
                if enabled, model.suggestions.isEmpty {
                    WorkspaceEmptyState(title: "Nothing yet today", message: "New suggestions show up here after Perry’s morning check.")
                        .padding(.top, 48)
                }
            }
            .padding(20)
        }
        .disabled(editing != nil)
        .accessibilityHidden(editing != nil)
        .overlay {
            if let card = editing {
                SuggestionEditor(card: card, cancel: { editing = nil }) { adjusted in
                    model.onSuggestionAdjust?(adjusted)
                    editing = nil
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PerryTheme.Colors.canvas)
            }
        }
    }

    private func suggestionCard(_ card: SuggestionCard, example: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(example ? "Example" : card.sourceServiceName.map { "From \($0)" } ?? "Suggestion")
                .font(PerryTheme.Scale.secondary)
                .foregroundStyle(PerryTheme.Colors.textSecondary)
            Text(card.title).font(PerryTheme.Scale.rowTitle)
            Text(card.body)
                .font(PerryTheme.Scale.body)
                .foregroundStyle(PerryTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Button("Do it") { model.onSuggestionAct?(card) }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.small)
                Button("Adjust") { editing = card }
                    .buttonStyle(.plain)
                Button("Dismiss") { model.onSuggestionDismiss?(card) }
                    .buttonStyle(.plain)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
            }
            .font(PerryTheme.Scale.body)
            .padding(.top, 6)
            .disabled(example)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SuggestionEditor: View {
    @State var card: SuggestionCard
    let cancel: () -> Void
    let save: (SuggestionCard) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Adjust suggestion").font(PerryTheme.Scale.title)
            Text(card.title).font(PerryTheme.Scale.rowTitle)
            if let source = card.sourceServiceName {
                Text("From \(source)").foregroundStyle(.secondary)
            }
            TextEditor(text: $card.body)
                .accessibilityLabel("Proposed task")
                .frame(minHeight: 120)
                .border(.separator)
            Text("Saving changes the suggestion. Choose Do it when you’re ready to run it.")
                .font(PerryTheme.Scale.body)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { cancel() }
                    .buttonStyle(InkButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(card) }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(card.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(24)
        .frame(width: 420)
    }
}

/// Learned routines (Phase 9): replay goes through the foreground path, so
/// Run kicks off a typed-plan run exactly like the menu command.
struct RoutinesView: View {
    @ObservedObject var model: HomeModel
    @State private var selectedID: UUID?
    @State private var deleting: LearnedRoutine?

    private var selected: LearnedRoutine? {
        model.routines.first { $0.id == selectedID } ?? model.routines.first
    }

    var body: some View {
        if model.routines.isEmpty {
            WorkspaceEmptyState(
                face: .open,
                title: "Teach Perry a routine",
                message: "Show Perry once. You check every step before it’s saved.",
                actionTitle: model.deps.controller == nil ? nil : "Record a routine",
                action: model.deps.controller.map { controller in { controller.startDemonstrationRecording() } }
            )
        } else {
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.routines) { routine in
                            Button { selectedID = routine.id } label: {
                                HStack(spacing: 8) {
                                    if let bundleID = routine.appBundleIDs.first {
                                        appIcon(bundleID)
                                    } else {
                                        Image(systemName: "repeat")
                                            .frame(width: 16, height: 16)
                                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                                            .accessibilityHidden(true)
                                    }
                                    Text(routine.name)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                    .font(PerryTheme.Scale.body)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(
                                        selected?.id == routine.id ? PerryTheme.Colors.surface : .clear,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected?.id == routine.id ? .isSelected : [])
                        }
                    }
                    .padding(12)
                }
                .frame(width: 160)

                Rectangle()
                    .fill(PerryTheme.Colors.subtleSeparator)
                    .frame(width: 1)

                if let routine = selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(routine.name)
                                    .font(PerryTheme.Scale.heading)
                                HStack(spacing: 6) {
                                    ForEach(routine.appBundleIDs, id: \.self) { bundleID in
                                        appIcon(bundleID)
                                    }
                                    Text(([routine.appBundleIDs.map(appName).joined(separator: ", ")] + ["\(routine.steps.count) \(routine.steps.count == 1 ? "step" : "steps")"]).filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(PerryTheme.Scale.body)
                                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                                }
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(routine.steps.enumerated()), id: \.offset) { index, step in
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text("\(index + 1)")
                                            .font(PerryTheme.Scale.section)
                                            .monospacedDigit()
                                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                                            .frame(width: 20, height: 20)
                                            .background(PerryTheme.Colors.surface, in: Circle())
                                            .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] }
                                        Text(step.summary)
                                            .font(PerryTheme.Scale.body)
                                        if step.requiresHuman {
                                            Text("You do this one")
                                                .font(PerryTheme.Scale.secondary)
                                                .foregroundStyle(PerryTheme.Colors.textSecondary)
                                        }
                                    }
                                }
                            }
                            Text(routine.workedSummary ?? "Perry checks the current app before each step.")
                                .font(PerryTheme.Scale.secondary)
                                .foregroundStyle(PerryTheme.Colors.textSecondary)
                            HStack(spacing: 14) {
                                Button { model.onRoutineRun?(routine) } label: {
                                    Label("Run now", systemImage: "play.fill")
                                }
                                .buttonStyle(InkButtonStyle())
                                .controlSize(.small)
                                Button(role: .destructive) { deleting = routine } label: {
                                    Label("Delete…", systemImage: "trash")
                                }
                                .buttonStyle(.plain)
                                .font(PerryTheme.Scale.body)
                                .foregroundStyle(PerryTheme.Colors.textSecondary)
                            }
                            .padding(.top, 4)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .notchDialog(
                "Delete this routine?",
                item: $deleting,
                message: "Perry removes the saved routine from this Mac."
            ) { routine in
                [NotchDialog.Action("Delete routine", role: .destructive) {
                    model.onRoutineRemove?(routine)
                }]
            }
        }
    }

    private func appIcon(_ bundleID: String) -> some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    private func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleName") as? String }
            ?? bundleID
    }
}

/// Files Perry owns, grouped into one pile per root directory. Rows drag
/// out as real file URLs (Finder/Desktop drops work via `Transferable`
/// URL), double-click opens, ⌥-click reveals.
struct FilesPage: View {
    let roots: [URL]
    var perrys: [Perry] = []
    @State private var listed: [(pile: Pile, files: [URL])]?

    private struct Pile {
        let label: String
        let root: URL
    }

    private var piles: [Pile] {
        let all = roots.map { Pile(label: "Made by Perry", root: $0) }
            + perrys.compactMap { perry in
                perry.folderPath.map {
                    Pile(label: perry.name, root: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath))
                }
            }
        var seen = Set<String>()
        return all.filter { seen.insert($0.root.standardizedFileURL.path).inserted }
    }

    private static func files(in root: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { !$0.hasDirectoryPath }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    var body: some View {
        content
            .task(id: piles.map(\.root)) {
                listed = piles.map { (pile: $0, files: Self.files(in: $0.root)) }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let listed { page(listed) } else { Color.clear }
    }

    @ViewBuilder
    private func page(_ listed: [(pile: Pile, files: [URL])]) -> some View {
        if listed.allSatisfy(\.files.isEmpty) {
            WorkspaceEmptyState(title: "No files yet", message: "Files Perry makes for you show up here. Drag one into any app.", actionTitle: piles.isEmpty ? nil : "Open in Finder") {
                if let root = piles.first?.root {
                    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(root)
                }
            }
        } else {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(listed, id: \.pile.root.path) { entry in
                    let pile = entry.pile
                    let files = entry.files
                    if !files.isEmpty {
                        Text(pile.label)
                            .font(PerryTheme.Scale.rowTitle)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .top)], spacing: 12) {
                            ForEach(files, id: \.path) { url in
                                FilePileItem(url: url)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        }
    }
}

struct FilePileItem: View {
    let url: URL

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 40, height: 40)
            Text(url.lastPathComponent)
                .font(PerryTheme.Scale.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(width: 90)
        .draggable(url)
        .onTapGesture(count: 2) {
            NSWorkspace.shared.open(url)
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("Open") { NSWorkspace.shared.open(url) }
        }
        .focusable()
        .onKeyPress(.return) {
            NSWorkspace.shared.open(url)
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(url.lastPathComponent)
        .accessibilityHint("Press Return to open. Use the context menu to reveal in Finder.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            NSWorkspace.shared.open(url)
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
            .onChange(of: model.unsavedInputs.count) { _, count in
                if count == 0 { isPresented = false }
            }
            if isPresented {
                ScrollView { UnsavedInputRecoveryView(model: model) }
                    .frame(maxHeight: 180)
                Button("Hide unsaved requests") { isPresented = false }
                    .buttonStyle(.borderless)
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
                    .font(PerryTheme.Scale.rowTitle)
                Text("Keep Perry open or copy your text. Saving again won’t send it.")
                    .font(PerryTheme.Scale.body).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(model.unsavedInputs) { input in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(input.request.text).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(input.error).font(PerryTheme.Scale.secondary).foregroundStyle(.secondary)
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
            .notchDialog(
                "Discard this unsaved request?",
                item: $discarding,
                message: "This text hasn’t been saved. You won’t be able to recover it from Perry."
            ) { id in
                [NotchDialog.Action("Discard", role: .destructive) {
                    model.onDiscardUnsavedInput?(id)
                }]
            }
        }
    }
}
