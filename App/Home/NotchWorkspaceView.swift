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
    @Environment(\.notchMood) private var mood
    @Namespace private var railNamespace
    @AppStorage(PerryPreferences.$settingsTab.key) private var settingsPage = SettingsPage.general.rawValue

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if model.sidebarSelection == .settings {
                    SettingsSidebar { model.sidebarSelection = nil }
                } else {
                    rail
                }
            }
            .frame(width: 184)
            Rectangle()
                .fill(PerryTheme.Colors.subtleSeparator)
                .frame(width: 1)
            VStack(spacing: 0) {
                if let error = model.storageError {
                    storageErrorStrip(error)
                }
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
        }
        .foregroundStyle(PerryTheme.Colors.text)
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
        .onChange(of: model.storageError) { _, error in
            if let error { AccessibilityNotification.Announcement(error).post() }
        }
        .onChange(of: model.composerNotice) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice).post() }
        }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeader
            railSearch
            railLinks
            railThreads
            Rectangle()
                .fill(PerryTheme.Colors.subtleSeparator)
                .frame(height: 1)
            railFooter
        }
    }

    private var railHeader: some View {
        Button {
            searchFocused = false
            model.sidebarSelection = nil
        } label: {
            HStack(spacing: 8) {
                PerryCharacter(mood: .resting, size: 20)
                Text("perry")
                    .font(PerryTheme.Scale.wordmark)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Home")
        .help("Home (⌘[)")
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var railSearch: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(PerryTheme.Icon.rail)
                    .foregroundStyle(PerryTheme.Colors.icon)
                    .accessibilityHidden(true)
                TextField("Search…", text: $model.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.control, style: .continuous))
            Button {
                searchFocused = false
                model.sidebarSelection = nil
                focusComposer = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(PerryTheme.Icon.utility)
                    .frame(width: PerryTheme.Icon.hit, height: PerryTheme.Icon.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RailRowStyle(cornerRadius: PerryTheme.Radius.control))
            .foregroundStyle(PerryTheme.Colors.icon)
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityLabel("New conversation")
            .help("New conversation (⌘N)")
        }
        .padding(.horizontal, 12)
    }

    private var railLinks: some View {
        VStack(alignment: .leading, spacing: 1) {
            railLink("Tasks", systemImage: "bolt.fill", tint: PerryCharacterView.sage, selection: .tasks, shortcut: "1", count: model.deps.backgroundTasks?.runningCount ?? 0)
            railLink("Routines", systemImage: "repeat", tint: TileTint.blue, selection: .routines, shortcut: "2")
            railLink("Files", systemImage: "folder.fill", tint: TileTint.teal, selection: .files, shortcut: "3")
            railLink("Suggestions", systemImage: "lightbulb.fill", tint: TileTint.peach, selection: .suggestions, shortcut: "4", count: model.suggestions.count)
            railLink("History", systemImage: "clock.fill", tint: TileTint.lilac, selection: .history, shortcut: "5")
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
    }

    private var railThreads: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !model.threads.isEmpty {
                        recentThreads
                    }
                    helpersSection
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
    }

    private var recentThreads: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            Text("Recent")
                .font(PerryTheme.Scale.meta)
                .foregroundStyle(PerryTheme.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            ForEach(model.filteredThreads) { thread in
                threadRow(thread)
            }
            if !model.search.isEmpty, model.filteredThreads.isEmpty {
                Text("No matches for “\(model.search)”")
                    .font(PerryTheme.Scale.secondary)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .padding(.horizontal, 8)
            }
        }
    }

    private func threadRow(_ thread: PerryThread) -> some View {
        Button {
            model.sidebarSelection = .thread(thread.id)
        } label: {
            Text(thread.title.isEmpty ? "Untitled" : thread.title)
                .font(PerryTheme.Scale.body)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background { selectionPill(model.sidebarSelection == .thread(thread.id)) }
                .contentShape(RoundedRectangle(cornerRadius: PerryTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(RailRowStyle(cornerRadius: PerryTheme.Radius.control))
        .accessibilityAddTraits(model.sidebarSelection == .thread(thread.id) ? .isSelected : [])
        .help("\(thread.title.isEmpty ? "Untitled" : thread.title)\n\(thread.updatedAt.formatted(.relative(presentation: .named)))")
    }

    private var helpersSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Helpers")
                    .font(PerryTheme.Scale.meta)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                Spacer()
                Button {
                    searchFocused = false
                    model.sidebarSelection = .perryEditor(nil)
                } label: {
                    Image(systemName: "plus").font(PerryTheme.Icon.utility).imageScale(.small)
                }
                .buttonStyle(.pressable)
                .foregroundStyle(PerryTheme.Colors.icon)
                .accessibilityLabel("New helper")
                .help("New helper: its own job, schedule, and memory")
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
            if model.perrys.isEmpty {
                Button {
                    searchFocused = false
                    model.sidebarSelection = .perryEditor(nil)
                } label: {
                    Text("New helper")
                        .font(PerryTheme.Scale.secondary)
                        .lineLimit(1)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RailRowStyle(cornerRadius: PerryTheme.Radius.control))
                .help("Make a helper for a job you repeat")
            }
            ForEach(model.perrys) { perry in
                helperRow(perry)
            }
        }
    }

    private func helperRow(_ perry: Perry) -> some View {
        Button {
            model.onPerrySelected?(perry)
        } label: {
            HStack(spacing: 10) {
                PerryCharacterView(pose: PerryCharacterPose(), size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(perry.name)
                        .font(PerryTheme.Scale.chip)
                        .lineLimit(1)
                    Text(perry.job)
                        .font(PerryTheme.Scale.secondary)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: PerryTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(RailRowStyle(cornerRadius: PerryTheme.Radius.control))
        .help("\(perry.name)\n\(perry.job)")
        .contextMenu {
            Button("Edit \(perry.name)…") { model.sidebarSelection = .perryEditor(perry.id) }
        }
    }

    private var railFooter: some View {
        HStack {
            Button {
                openSettings(.apps)
            } label: {
                Label {
                    Text("Apps")
                } icon: {
                    SymbolTile(systemImage: "square.grid.2x2.fill", tint: TileTint.pink)
                }
                .font(PerryTheme.Scale.body)
            }
            .buttonStyle(.pressable)
            .accessibilityHint("Open connected apps settings")
            Spacer()
            Button {
                model.sidebarSelection = .settings
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
                    .font(PerryTheme.Icon.rail)
                    .foregroundStyle(PerryTheme.Colors.icon)
            }
            .buttonStyle(.pressable)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, NotchLayout.bottomInset)
    }

    private var resting: some View {
        VStack(spacing: 0) {
            windowControls
                .padding(.horizontal, 14)
                .padding(.top, 12)

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 14) {
                    PerryCharacter(mood: mood, size: 40)
                        .padding(.trailing, 16)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(greeting)
                            .font(PerryTheme.Scale.display)
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
                        onVoice: model.deps.controller.map { controller in { controller.subsystems.talkSession.startClick() } }
                    ) {
                        model.onStartConversation?(model.newConversationDraft)
                    }
                    ComposerModeChip(mode: $model.composerMode,
                                     window: model.newConversationTarget.map(CompactTargetChooser.targetName),
                                     chooseWindow: { choosesTarget = true },
                                     clearWindow: { model.newConversationTarget = nil })
                    if let notice = model.composerNotice {
                        StatusLabel(notice, .attention)
                            .font(PerryTheme.Scale.body)
                    }
                }
            }
            .frame(maxWidth: 500, alignment: .leading)
            .padding(.horizontal, 32)

            Spacer(minLength: 20)

            VStack(spacing: 8) {
                UnsavedInputRecoveryButton(model: model)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func storageErrorStrip(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            StatusLabel(error, .attention)
                .font(PerryTheme.Scale.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(6)
                .help(error)
                .textSelection(.enabled)
            WindowControlButton(systemImage: "xmark", label: "Dismiss") { model.storageError = nil }
        }
        .padding(10)
        .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.control, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
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

    private func railLink(_ title: String, systemImage: String, tint: Color, selection: HomeModel.Selection, shortcut: KeyEquivalent, count: Int = 0) -> some View {
        Button {
            searchFocused = false
            model.sidebarSelection = selection
        } label: {
            HStack(spacing: 10) {
                SymbolTile(systemImage: systemImage, tint: tint)
                Text(title)
                    .font(PerryTheme.Scale.body)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)")
                        .font(PerryTheme.Scale.section)
                        .monospacedDigit()
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .contentTransition(.numericText(value: Double(count)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background { selectionPill(model.sidebarSelection == selection) }
            .contentShape(RoundedRectangle(cornerRadius: PerryTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(RailRowStyle(cornerRadius: PerryTheme.Radius.control))
        .keyboardShortcut(shortcut, modifiers: .command)
        .help("\(title) (⌘\(shortcut.character))")
        .accessibilityAddTraits(model.sidebarSelection == selection ? .isSelected : [])
    }

    @ViewBuilder
    private func selectionPill(_ selected: Bool) -> some View {
        if selected {
            RoundedRectangle(cornerRadius: PerryTheme.Radius.control, style: .continuous)
                .fill(PerryTheme.Colors.veil(0.1))
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
                    .font(PerryTheme.Scale.title)
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
            Label {
                Text(target.map(CompactTargetChooser.targetName) ?? "Window")
            } icon: {
                if let bundleID = target.flatMap(CompactTargetChooser.bundleID) {
                    BrandMark(id: bundleID, name: target.map(CompactTargetChooser.applicationName), bundleID: bundleID, size: 16)
                } else {
                    Image(systemName: "macwindow")
                }
            }
            .lineLimit(1)
        }
        .buttonStyle(ChipStyle())
        .help(target?.windowTitle ?? "Choose which window Perry can see")
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
        case .settings: SettingsPage(stored: settingsPage).title
        case .whatsNew: "What’s new"
        case .perryEditor(let id):
            id.flatMap { id in model.perrys.first { $0.id == id }?.name } ?? "New helper"
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
                pagePlaceholder("Pick a conversation")
            }
        case .suggestions:
            SuggestionsView(model: model)
        case .history:
            if let store = model.deps.transcriptStore, let log = model.deps.activityLog {
                HistoryView(store: store, activityLog: log, undoableEntryIDs: model.deps.undoableEntryIDs, askPerry: { model.sidebarSelection = nil })
            } else {
                pagePlaceholder("Couldn’t load History. Reopen Perry.")
            }
        case .tasks:
            if let tasks = model.deps.backgroundTasks {
                BackgroundTasksView(backgroundTasks: tasks, askPerry: { model.sidebarSelection = nil })
            } else {
                pagePlaceholder("Couldn’t load Tasks. Reopen Perry.")
            }
        case .routines:
            RoutinesView(model: model)
        case .files:
            FilesPage(roots: model.deps.fileRoots, perrys: model.perrys)
        case .settings:
            if let controller = model.deps.controller {
                SettingsView(controller: controller)
            } else {
                pagePlaceholder("Couldn’t load Settings. Reopen Perry.")
            }
        case .whatsNew:
            WhatsNewView(onDone: { model.sidebarSelection = nil })
        case .perryEditor(let id):
            if let store = model.deps.controller?.subsystems.perryStore {
                PerryEditorView(perry: id.flatMap { id in model.perrys.first { $0.id == id } }, model: model, store: store)
                    .id(id)
            } else {
                pagePlaceholder("Couldn’t load helpers. Reopen Perry.")
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

    private func openSettings(_ page: SettingsPage) {
        PerryPreferences.settingsTab = page.rawValue
        model.sidebarSelection = .settings
    }
}

private struct GestureHint: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("Hold")
            Keycap(TalkGesture.keys)
            Text("to talk")
        }
        .font(PerryTheme.Scale.body)
        .foregroundStyle(PerryTheme.Colors.textSecondary)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TalkGesture.talk)
    }
}

struct WindowControlButton: View {
    let systemImage: String
    let label: String
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(PerryTheme.Icon.utility)
                .frame(width: PerryTheme.Icon.hit, height: PerryTheme.Icon.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(RailRowStyle(cornerRadius: PerryTheme.Radius.control))
        .foregroundStyle(PerryTheme.Colors.icon)
        .accessibilityLabel(label)
        .help(help ?? label)
    }
}

struct RailRowStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        RailRowBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct RailRowBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        @Environment(\.isFocused) private var isFocused
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(PerryTheme.Colors.veil(configuration.isPressed ? 0.1 : hovering ? 0.05 : 0))
                )
                .overlay {
                    if isFocused { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(PerryTheme.Colors.accent, lineWidth: 2) }
                }
                .onHover { hovering = $0 }
                .animation(PerryTheme.Motion.snap, value: hovering)
        }
    }
}

private struct ComposerModeChip: View {
    @Binding var mode: HomeModel.ComposerMode
    var window: String?
    var chooseWindow: () -> Void
    var clearWindow: () -> Void

    var body: some View {
        Menu {
            Picker("Mode", selection: $mode) {
                ForEach(HomeModel.ComposerMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Share a window…", systemImage: "macwindow", action: chooseWindow)
            if window != nil {
                Button("Stop sharing", systemImage: "xmark", action: clearWindow)
            }
        } label: {
            Label(window.map { "\(mode.title) · \($0)" } ?? mode.title, systemImage: mode.systemImage)
                .lineLimit(1)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(ChipStyle())
        .fixedSize()
        .accessibilityLabel("Mode: \(mode.title)")
        .help("Choose whether I answer, guide you, or act")
    }
}
