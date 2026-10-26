import AppKit
import SwiftUI
import PerryBrain
import PerryOverlay

struct HomeConversationView: View {
    let thread: PerryThread
    @ObservedObject var model: HomeModel
    var focusComposer = false
    var composerAccessory: AnyView?

    private var isWorking: Bool {
        model.workingThreads.contains(thread.id) || model.pendingQuestions[thread.id] != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    let turns = model.displayedTurns(for: thread)
                    ForEach(turns.indices, id: \.self) { index in
                        let turn = turns[index]
                        VStack(alignment: .leading, spacing: 14) {
                            Text(turn.question)
                                .font(PerryTheme.Scale.body)
                                .textSelection(.enabled)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            if !turn.answer.isEmpty {
                                ConversationAnswer(text: turn.answer)
                                    .textSelection(.enabled)
                                    .lineSpacing(4)
                            }
                            if let reason = turn.failureReason {
                                Label(reason, systemImage: "exclamationmark.circle")
                                    .font(PerryTheme.Scale.body)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let waiting = thread.waitingInputs, !waiting.isEmpty {
                        WaitingInputRecoveryView(
                            inputs: waiting,
                            canRestore: !isWorking && thread.pendingTurn == nil && model.draft(for: thread).isEmpty,
                            restore: { model.onRestoreWaitingInput?(thread.id, $0) },
                            remove: { model.onRemoveWaitingInput?(thread.id, $0) }
                        )
                    }
                    if thread.pendingTurn != nil && !isWorking {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("This task was interrupted. Review any changes in the affected app before continuing. Perry will not repeat the task automatically.", systemImage: "pause.circle")
                                .font(PerryTheme.Scale.body)
                                .foregroundStyle(.secondary)
                            Button("I’ve reviewed the changes") { model.onResolveInterrupted?(thread.id) }
                        }
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(20)
                .background(ConversationScrollObservation(
                    position: model.conversationPositions[thread.id] ?? .init(),
                    onScroll: { model.conversationPositions[thread.id] = $0 }
                ))
            }
            .transaction { transaction in
                if #available(macOS 15, *) {
                    transaction.scrollContentOffsetAdjustmentBehavior = .disabled
                }
            }
            .onChange(of: model.pendingQuestions[thread.id]) { _, question in
                if question != nil { model.conversationPositions[thread.id] = .init() }
            }
            VStack(alignment: .leading, spacing: 12) {
                if model.conversationPositions[thread.id]?.followsLatest == false {
                    HStack {
                        Spacer()
                        Button("Latest", systemImage: "arrow.down") {
                            model.conversationPositions[thread.id] = .init()
                        }
                        .buttonStyle(InkButtonStyle(.secondary))
                    }
                }
                if isWorking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.stoppingThreads.contains(thread.id) ? "Stopping…" : "Working on it")
                            .font(PerryTheme.Scale.body)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop", systemImage: "stop.fill") { model.onStop?(thread.id) }
                            .controlSize(.small)
                            .disabled(model.stoppingThreads.contains(thread.id))
                    }
                } else if let error = model.threadErrors[thread.id], error != thread.turns.last?.failureReason {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(PerryTheme.Scale.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                WorkspaceComposer(
                    text: Binding(
                        get: { model.draft(for: thread) },
                        set: { model.draftChanged(threadID: thread.id, draft: $0) }
                    ),
                    placeholder: "Ask a follow-up",
                    canSend: !isWorking && thread.pendingTurn == nil,
                    focusOnAppear: focusComposer,
                    onVoice: isWorking || thread.pendingTurn != nil ? nil : model.deps.controller.map { controller in
                        {
                            model.sidebarSelection = .thread(thread.id)
                            controller.talkSession.startClick()
                        }
                    }
                ) {
                    model.send(threadID: thread.id, text: model.draft(for: thread))
                }
                if let composerAccessory {
                    composerAccessory
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: 680)
            .padding(20)
        }
    }
}

struct WaitingInputRecoveryView: View {
    let inputs: [PerryThread.WaitingInput]
    let canRestore: Bool
    let restore: (UUID) -> Void
    let remove: (UUID) -> Void
    @State private var discarding: PerryThread.WaitingInput?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Saved requests", systemImage: "tray")
                .font(PerryTheme.Scale.rowTitle)
            Text("These requests haven’t started. Review one in the composer when you’re ready.")
                .font(PerryTheme.Scale.body)
                .foregroundStyle(.secondary)
            ForEach(inputs) { input in
                VStack(alignment: .leading, spacing: 8) {
                    Text(input.text).textSelection(.enabled)
                    HStack {
                        Button("Use in composer") { restore(input.id) }
                            .disabled(!canRestore)
                            .help(canRestore ? "Restore without sending" : "Finish the active task and clear the composer first")
                        Button("Discard", role: .destructive) { discarding = input }
                    }
                    .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .notchDialog("Discard this saved request?", item: $discarding) { input in
            [NotchDialog.Action("Discard request", role: .destructive) {
                remove(input.id)
            }]
        }
    }
}

struct HomeConnectionView: View {
    @ObservedObject var brain: BrainController
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if brain.modelChoice != .chatGPT {
                Text("\(brain.modelChoice.title) selected")
                    .font(PerryTheme.Scale.rowTitle)
                Text("You can change this choice in model settings.")
                    .font(PerryTheme.Scale.body)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                Button("Model settings", action: openSettings).buttonStyle(.borderless)
            } else if case .signedIn(let email, _) = brain.account {
                HStack {
                    Label(email.isEmpty ? "Connected to ChatGPT" : "Connected to ChatGPT as \(email)", systemImage: "checkmark.circle")
                        .font(PerryTheme.Scale.body)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                    Spacer()
                    Button("Sign out") { Task { await brain.signOut() } }
                        .buttonStyle(InkButtonStyle(.secondary))
                        .controlSize(.small)
                }
            } else {
                Text("Connect your ChatGPT account")
                    .font(PerryTheme.Scale.rowTitle)
                Text("Use your existing account to talk with Perry. You can switch models any time.")
                    .font(PerryTheme.Scale.body)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                HStack {
                    Button(brain.isSigningIn ? "Waiting for sign-in…" : "Connect ChatGPT") {
                        brain.signInWithChatGPT()
                    }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.small)
                    .disabled(brain.isSigningIn)
                    Group {
                        if brain.isSigningIn {
                            Button("Cancel") { brain.cancelSignIn() }
                        } else {
                            Button("Other models", action: openSettings)
                        }
                    }
                    .buttonStyle(InkButtonStyle(.secondary))
                    .controlSize(.small)
                }
            }
            if let error = brain.signInError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(PerryTheme.Scale.body)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
            }
        }
        .task {
            await brain.refresh()
        }
    }
}

struct ModelSettingsButton: View {
    @ObservedObject var brain: BrainController
    let openSettings: () -> Void

    private var title: String {
        let choice = brain.modelChoice
        if choice == .chatGPT, case .signedOut = brain.account { return "Connect ChatGPT" }
        return choice.title
    }

    var body: some View {
        Button(action: openSettings) {
            Label(title, systemImage: "cpu")
        }
        .fixedSize()
        .accessibilityLabel("Model: \(title)")
        .accessibilityHint("Open model settings")
        .help("Model")
    }
}

private struct ConversationScrollObservation: NSViewRepresentable {
    let position: HomeModel.ConversationScrollPosition
    let onScroll: (HomeModel.ConversationScrollPosition) -> Void

    func makeNSView(context: Context) -> Observer { Observer() }

    func updateNSView(_ view: Observer, context: Context) {
        view.position = position
        view.onScroll = onScroll
        view.applyPosition()
    }

    final class Observer: NSView {
        var position = HomeModel.ConversationScrollPosition()
        var onScroll: ((HomeModel.ConversationScrollPosition) -> Void)?
        private weak var observedScrollView: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            observedScrollView = window == nil ? nil : enclosingScrollView
            guard window != nil, let scroll = observedScrollView, let document = scroll.documentView else { return }
            document.postsFrameChangedNotifications = true
            scroll.contentView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSScrollView.didLiveScrollNotification, object: scroll)
            for view in [document, scroll.contentView] {
                NotificationCenter.default.addObserver(self, selector: #selector(resized(_:)), name: NSView.frameDidChangeNotification, object: view)
            }
            applyPosition()
        }

        func applyPosition() {
            guard let scroll = observedScrollView, let document = scroll.documentView else { return }
            let maximum = max(document.bounds.height - scroll.contentView.bounds.height, 0)
            let bottom = document.isFlipped ? maximum : 0
            let y = position.followsLatest ? bottom : min(max(position.offset, 0), maximum)
            guard abs(scroll.contentView.bounds.minY - y) > 0.5 else { return }
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        @objc private func resized(_ notification: Notification) {
            applyPosition()
        }

        @objc private func scrolled(_ notification: Notification) {
            guard let scroll = notification.object as? NSScrollView,
                  let document = scroll.documentView else { return }
            let visible = scroll.documentVisibleRect
            position = .init(
                offset: scroll.contentView.bounds.minY,
                followsLatest: document.isFlipped
                    ? visible.maxY >= document.bounds.maxY - 32
                    : visible.minY <= document.bounds.minY + 32
            )
            onScroll?(position)
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

struct ConversationAnswer: View {
    enum Part: Equatable {
        case text(AttributedString)
        case code(String)
    }

    let text: String
    @State private var parts: [Part] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(parts.indices, id: \.self) { index in
                switch parts[index] {
                case .text(let formatted): Text(formatted)
                case .code(let code): CodeBlock(code: code)
                }
            }
        }
        .task(id: text) { parts = Self.parts(text) }
    }

    static func parts(_ source: String) -> [Part] {
        var parts: [Part] = []
        var prose: [Substring] = []
        var code: [Substring]?
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { parts.append(.text(format(joined))) }
            prose = []
        }
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let open = code {
                    parts.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flushProse()
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else {
                prose.append(line)
            }
        }
        if let open = code { parts.append(.code(open.joined(separator: "\n"))) }
        flushProse()
        return parts
    }

    static func format(_ source: String) -> AttributedString {
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else {
            return AttributedString(source)
        }
        if parsed.runs.contains(where: { run in
            run.presentationIntent?.components.contains(where: {
                if case .table = $0.kind { return true }
                return false
            }) == true
        }) { return AttributedString(source) }
        var output = AttributedString()
        var previousBlock: Int?
        var previousWasListItem = false
        var previousWasHeader = false
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            var fragment = AttributedString(parsed[run.range])
            fragment.presentationIntent = nil
            if let scheme = fragment.link?.scheme?.lowercased(), scheme != "https", scheme != "http" {
                fragment.link = nil
            }
            if block != previousBlock {
                let item = components.first(where: {
                    if case .listItem = $0.kind { return true }
                    return false
                })
                if !output.characters.isEmpty {
                    output += AttributedString((item != nil && previousWasListItem) || previousWasHeader ? "\n" : "\n\n")
                }
                if let item, case .listItem(let ordinal) = item.kind {
                    let ordered = components.contains { $0.kind == .orderedList }
                    output += AttributedString(ordered ? "\(ordinal). " : "• ")
                }
                previousWasListItem = item != nil
                previousWasHeader = components.contains {
                    if case .header = $0.kind { return true }
                    return false
                }
                previousBlock = block
            }
            if run.inlinePresentationIntent?.contains(.code) == true {
                fragment.font = .system(.body, design: .monospaced)
                fragment.backgroundColor = Color.white.opacity(0.08)
            }
            if let kind = components.first?.kind {
                switch kind {
                case .header(let level):
                    fragment.font = level == 1 ? PerryTheme.Scale.title : PerryTheme.Scale.rowTitle
                case .codeBlock:
                    fragment.font = .system(.body, design: .monospaced)
                default:
                    break
                }
            }
            output += fragment
        }
        return output
    }
}

private struct CodeBlock: View {
    let code: String
    @State private var copied = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(PerryTheme.Scale.code)
                .lineSpacing(2)
                .fixedSize()
                .padding(.vertical, 12)
                .padding(.leading, 14)
                .padding(.trailing, 72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(PerryTheme.Scale.secondary)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
            }
            .buttonStyle(.borderless)
            .padding(8)
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
    }
}
