import AppKit
import SwiftUI
import PerryBrain
import PerryCore
import PerryGuide
import PerryOverlay
import PerryRuntimes

struct NotchWorkspaceView: View {
    @ObservedObject var model: HomeModel
    @State private var focusComposer = true
    @State private var choosesTarget = false
    @FocusState private var searchFocused: Bool
    @FocusState private var targetBackFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var railNamespace

    var body: some View {
        HStack(spacing: 0) {
            rail
                .frame(width: 148)
            Rectangle()
                .fill(PerryTheme.Colors.subtleSeparator)
                .frame(width: 1)
            Group {
                if model.sidebarSelection == nil {
                    resting
                        .transition(pageTransition)
                } else {
                    focusedPage
                        .transition(pageTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : PerryTheme.Motion.glide, value: model.sidebarSelection)
        }
        .foregroundStyle(PerryTheme.Colors.text)
        .background(PerryTheme.Colors.canvas)
        .disabled(choosesTarget)
        .accessibilityHidden(choosesTarget)
        .overlay {
            if choosesTarget {
                VStack(alignment: .leading, spacing: 12) {
                    Button("Back", systemImage: "chevron.left") { choosesTarget = false }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.cancelAction)
                        .focusable()
                        .focused($targetBackFocused)
                        .onAppear { targetBackFocused = true }
                        .onKeyPress(keys: [.return, .space]) { _ in
                            choosesTarget = false
                            return .handled
                        }
                    CompactTargetChooser { target in
                        if case .thread(let id) = model.sidebarSelection {
                            model.conversationTargets[id] = target
                        } else {
                            model.newConversationTarget = target
                        }
                        choosesTarget = false
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PerryTheme.Colors.canvas)
            }
        }
        .tint(PerryTheme.Colors.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: choosesTarget) { _, choosing in
            searchFocused = false
            targetBackFocused = choosing
        }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                searchFocused = false
                model.sidebarSelection = nil
            } label: {
                HStack(spacing: 8) {
                    PerryCharacterView(pose: PerryCharacterPose(), size: 20)
                    Text("perry")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Home")
            .help("Home (⌘[)")
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .accessibilityHidden(true)
                    TextField("Search…", text: $model.search)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button {
                    searchFocused = false
                    model.sidebarSelection = nil
                    focusComposer = true
                } label: {
                    Image(systemName: "plus")
                        .font(.callout.weight(.medium))
                        .frame(width: 27, height: 27)
                        .background(PerryTheme.Colors.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityLabel("New conversation")
                .help("New conversation (⌘N)")
            }
            .padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 1) {
                railLink("Tasks", systemImage: "checklist", selection: .tasks, shortcut: "1", count: model.deps.backgroundTasks?.runningCount ?? 0)
                railLink("Routines", systemImage: "repeat", selection: .routines, shortcut: "2")
                railLink("Files", systemImage: "folder", selection: .files, shortcut: "3")
                railLink("Suggestions", systemImage: "lightbulb", selection: .suggestions, shortcut: "4", count: model.suggestions.count)
                railLink("History", systemImage: "clock.arrow.circlepath", selection: .history, shortcut: "5")
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)

            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Perrys")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(PerryTheme.Colors.textSecondary)
                            Spacer()
                            Button {
                                searchFocused = false
                                model.sidebarSelection = .perryEditor(nil)
                            } label: {
                                Image(systemName: "plus").font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("New Perry")
                            .help("Make a Perry: a named helper with its own job, schedule, and memory")
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 2)
                        if model.perrys.isEmpty {
                            Button {
                                searchFocused = false
                                model.sidebarSelection = .perryEditor(nil)
                            } label: {
                                Text("Make a helper for a job you repeat")
                                    .font(.caption)
                                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(RailRowStyle(cornerRadius: 8))
                        }
                        ForEach(model.perrys) { perry in
                            Button {
                                model.onPerrySelected?(perry)
                            } label: {
                                HStack(spacing: 10) {
                                    PerryCharacterView(pose: PerryCharacterPose(), size: 22)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(perry.name)
                                            .font(.callout.weight(.medium))
                                            .lineLimit(1)
                                        Text(perry.job)
                                            .font(.caption)
                                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(RailRowStyle(cornerRadius: 8))
                            .help("\(perry.name)\n\(perry.job)")
                            .contextMenu {
                                Button("Edit \(perry.name)…") { model.sidebarSelection = .perryEditor(perry.id) }
                            }
                        }
                    }

                    LazyVStack(alignment: .leading, spacing: 2) {
                        Text("Recent")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 2)
                        ForEach(model.filteredThreads) { thread in
                            Button {
                                model.sidebarSelection = .thread(thread.id)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                                        .frame(width: 22)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(thread.title.isEmpty ? "Untitled" : thread.title)
                                            .font(.callout)
                                            .lineLimit(1)
                                        Text(thread.updatedAt.formatted(.relative(presentation: .named)))
                                            .font(.caption)
                                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background { selectionPill(model.sidebarSelection == .thread(thread.id)) }
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(RailRowStyle(cornerRadius: 8))
                            .accessibilityAddTraits(model.sidebarSelection == .thread(thread.id) ? .isSelected : [])
                            .help(thread.title.isEmpty ? "Untitled" : thread.title)
                        }
                        if model.threads.isEmpty {
                            Text("No conversations yet")
                                .font(.caption)
                                .foregroundStyle(PerryTheme.Colors.textSecondary)
                                .padding(.horizontal, 8)
                        } else if !model.search.isEmpty, model.filteredThreads.isEmpty {
                            Text("No matches")
                                .font(.caption)
                                .foregroundStyle(PerryTheme.Colors.textSecondary)
                                .padding(.horizontal, 8)
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 10)
            }
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 20)
                }
            }
            .onChange(of: model.sidebarSelection) { _, selection in
                if case .thread(let id) = selection { proxy.scrollTo(id) }
            }
            }
            .background {
                Button("Search conversations") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .hidden()
            }

            Rectangle()
                .fill(PerryTheme.Colors.subtleSeparator)
                .frame(height: 1)

            HStack {
                Button {
                    openSettingsTab(.integrations)
                } label: {
                    Label("Apps", systemImage: "square.grid.2x2")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Open connected apps settings")
                Spacer()
                Button {
                    model.sidebarSelection = .settings
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var resting: some View {
        VStack(spacing: 0) {
            windowControls
                .padding(.horizontal, 14)
                .padding(.top, 12)

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 14) {
                    PerryCharacterView(pose: PerryCharacterPose(), size: 40)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(greeting)
                            .font(.system(size: 26, weight: .semibold, design: .serif))
                        GestureHint()
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    WorkspaceComposer(
                        text: Binding(
                            get: { model.newConversationDraft },
                            set: { model.updateNewDraft($0) }
                        ),
                        canSend: !model.isCreatingConversation,
                        focusOnAppear: focusComposer,
                        onVoice: model.deps.controller.map { controller in { controller.conversationVoice.start() } }
                    ) {
                        model.onStartConversation?(model.newConversationDraft)
                    }
                    if let voice = model.deps.controller?.conversationVoice {
                        WorkspaceVoiceStatus(voice: voice)
                    }
                    HStack(spacing: 6) {
                        ComposerModeChip(mode: $model.composerMode)
                        targetButton
                        if let brain = model.deps.brain {
                            ModelSettingsButton(brain: brain) {
                                openSettingsTab(.runtimes)
                            }
                        }
                    }
                    .buttonStyle(ContextChipStyle())
                }
            }
            .frame(maxWidth: 500, alignment: .leading)
            .padding(.horizontal, 32)

            Spacer(minLength: 20)

            VStack(spacing: 8) {
                UnsavedInputRecoveryButton(model: model)
                if let error = model.storageError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var windowControls: some View {
        HStack(spacing: 2) {
            Spacer()
            if let controller = model.deps.controller {
                NotchCommandsMenu(controller: controller)
                    .frame(width: 28, height: 28)
                    .help("More")
            }
            WindowControlButton(systemImage: "xmark", label: "Close") {
                model.deps.controller?.collapseNotch()
            }
        }
    }

    private func railLink(_ title: String, systemImage: String, selection: HomeModel.Selection, shortcut: KeyEquivalent, count: Int = 0) -> some View {
        Button {
            searchFocused = false
            model.sidebarSelection = selection
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.callout)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .contentTransition(.numericText(value: Double(count)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background { selectionPill(model.sidebarSelection == selection) }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(RailRowStyle(cornerRadius: 8))
        .keyboardShortcut(shortcut, modifiers: .command)
        .help("\(title) (⌘\(shortcut.character))")
        .accessibilityAddTraits(model.sidebarSelection == selection ? .isSelected : [])
    }

    @ViewBuilder
    private func selectionPill(_ selected: Bool) -> some View {
        if selected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.1))
                .matchedGeometryEffect(id: "railSelection", in: railNamespace)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let daypart: String
        switch hour {
        case 5..<12: daypart = "morning"
        case 12..<17: daypart = "afternoon"
        default: daypart = "evening"
        }
        let name = NSFullUserName().components(separatedBy: .whitespaces).first ?? ""
        return name.isEmpty ? "\(daypart.capitalized)." : "\(daypart.capitalized), \(name)."
    }

    private var focusedPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(pageTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .help(pageTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                windowControls
                    .fixedSize()
            }
            .padding(.leading, 20)
            .padding(.trailing, 14)
            .frame(height: 52)
            .background {
                Button("Home") { model.sidebarSelection = nil }
                    .keyboardShortcut("[", modifiers: .command)
                    .hidden()
            }

            Rectangle()
                .fill(PerryTheme.Colors.subtleSeparator)
                .frame(height: 1)

            page
                .id(model.sidebarSelection)
                .transition(pageTransition)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var pageTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6))
    }

    private var targetButton: some View {
        let threadID: UUID? = {
            if case .thread(let id) = model.sidebarSelection { return id }
            return nil
        }()
        let target = threadID.flatMap { model.conversationTargets[$0] }
            ?? (threadID == nil ? model.newConversationTarget : nil)
        return Button {
            choosesTarget = true
        } label: {
            Label(target.map(CompactTargetChooser.targetName) ?? "Choose a window", systemImage: "macwindow")
                .lineLimit(1)
        }
        .buttonStyle(ContextChipStyle())
        .help(target?.windowTitle ?? "Choose which window Perry can inspect")
        .disabled(threadID.map { model.workingThreads.contains($0) || model.pendingQuestions[$0] != nil } ?? false)
    }

    private var pageTitle: String {
        switch model.sidebarSelection {
        case .thread(let id):
            model.threads.first { $0.id == id }.flatMap { $0.title.isEmpty ? nil : $0.title } ?? "New conversation"
        case .history: "History"
        case .tasks: "Tasks"
        case .routines: "Routines"
        case .files: "Files"
        case .suggestions: "Suggestions"
        case .settings: "Settings"
        case .whatsNew: "What’s New"
        case .perryEditor(let id):
            id.flatMap { id in model.perrys.first { $0.id == id }?.name } ?? "New Perry"
        case nil: "Perry"
        }
    }

    @ViewBuilder
    private var page: some View {
        switch model.sidebarSelection {
        case .thread(let id):
            if let thread = model.threads.first(where: { $0.id == id }) {
                HomeConversationView(thread: thread, model: model, focusComposer: true, composerAccessory: AnyView(targetButton))
                    .id(thread.id)
            } else {
                pagePlaceholder("Pick a thread")
            }
        case .suggestions:
            SuggestionsView(model: model)
        case .history:
            if let store = model.deps.transcriptStore, let log = model.deps.activityLog {
                HistoryView(store: store, activityLog: log, undoableEntryIDs: model.deps.undoableEntryIDs, askPerry: { model.sidebarSelection = nil })
            } else {
                pagePlaceholder("History unavailable")
            }
        case .tasks:
            if let tasks = model.deps.backgroundTasks, let runtimes = model.deps.runtimes {
                BackgroundTasksView(backgroundTasks: tasks, runtimes: runtimes, askPerry: { model.sidebarSelection = nil })
            } else {
                pagePlaceholder("Background tasks unavailable")
            }
        case .routines:
            RoutinesView(model: model)
        case .files:
            FilesPage(roots: model.deps.fileRoots, perrys: model.perrys)
        case .settings:
            if let controller = model.deps.controller {
                SettingsView(controller: controller)
            } else {
                pagePlaceholder("Settings unavailable")
            }
        case .whatsNew:
            WhatsNewView(onDone: { model.sidebarSelection = nil })
        case .perryEditor(let id):
            if let store = model.deps.controller?.perryStore {
                PerryEditorView(perry: id.flatMap { id in model.perrys.first { $0.id == id } }, model: model, store: store)
                    .id(id)
            } else {
                pagePlaceholder("Perrys unavailable")
            }
        case nil:
            EmptyView()
        }
    }

    private func pagePlaceholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(PerryTheme.Colors.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openSettingsTab(_ tab: SettingsTab) {
        PerryPreferences.settingsTab = tab.rawValue
        model.sidebarSelection = .settings
    }
}

private struct WorkspaceVoiceStatus: View {
    @ObservedObject var voice: VoiceConversationController

    var body: some View {
        switch voice.state {
        case .idle:
            EmptyView()
        case .requestingPermission:
            statusRow("Requesting microphone access…")
        case .listening:
            statusRow(voice.transcript.isEmpty ? "Listening…" : voice.transcript)
        case .thinking:
            statusRow("Thinking…")
        case .speaking:
            statusRow(voice.answer.isEmpty ? "Speaking…" : voice.answer)
        case .failed:
            VStack(spacing: 8) {
                Label(voice.error ?? "Voice failed.", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(PerryTheme.Colors.warning)
                    .textSelection(.enabled)
                Button("Dismiss") { voice.resetConversation() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            .frame(maxWidth: 460)
        }
    }

    private func statusRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(PerryTheme.Colors.accent)
            Text(text)
                .font(.callout)
                .lineLimit(2)
            Button("Stop") { voice.cancel() }
                .controlSize(.small)
        }
        .frame(maxWidth: 460)
    }
}

private struct GestureHint: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("Hold")
            Keycap(TalkGesture.keys)
            Text("to talk, or double-tap")
            Keycap("⌃")
            Text("to type")
        }
        .font(.callout)
        .foregroundStyle(PerryTheme.Colors.textSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(TalkGesture.talk). \(TalkGesture.type).")
    }
}

struct WindowControlButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(RailRowStyle(cornerRadius: 7))
        .foregroundStyle(PerryTheme.Colors.textSecondary)
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct RailRowStyle: ButtonStyle {
    var cornerRadius: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        RailRowBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct RailRowBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(configuration.isPressed ? 0.1 : hovering ? 0.05 : 0))
                )
                .onHover { hovering = $0 }
                .animation(PerryTheme.Motion.snap, value: hovering)
        }
    }
}

private struct ComposerModeChip: View {
    @Binding var mode: HomeModel.ComposerMode

    var body: some View {
        Menu {
            Picker("Mode", selection: $mode) {
                ForEach(HomeModel.ComposerMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(mode.title, systemImage: mode.systemImage)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(ContextChipStyle())
        .fixedSize()
        .accessibilityLabel("Mode: \(mode.title)")
        .help("Ask, guide, or do")
    }
}
