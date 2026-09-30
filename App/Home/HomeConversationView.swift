import AppKit
import SwiftUI
import PerryBrain

struct HomeWelcomeView: View {
    @ObservedObject var model: HomeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if model.onboarding == nil {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "cursorarrow.rays")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(PerryTheme.Colors.accent)
                            .accessibilityHidden(true)
                        Text("A hand with whatever’s next.")
                            .font(.system(.title, design: .rounded, weight: .semibold))
                        Text("Ask a question, work through something together, or give Perry a task.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                if model.onboarding == nil, let brain = model.deps.brain {
                    HomeConnectionView(brain: brain) { model.sidebarSelection = .settings }
                }
                HomeComposer(text: Binding(get: { model.newConversationDraft }, set: { model.updateNewDraft($0) }), placeholder: "What would you like help with?", canSend: !model.isCreatingConversation) {
                    model.onStartConversation?(model.newConversationDraft)
                }
                Label("Hold ⌃⌥ to talk while you point", systemImage: "mic")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.onboarding == nil, !model.threads.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pick up where you left off")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        ForEach(model.threads.prefix(3)) { thread in
                            Button {
                                model.sidebarSelection = .thread(thread.id)
                            } label: {
                                HStack {
                                    Text(thread.title.isEmpty ? "New conversation" : thread.title)
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: 540, alignment: .leading)
            .padding(model.onboarding == nil ? 32 : 20)
            .frame(maxWidth: .infinity)
        }
    }
}

struct HomeConversationView: View {
    let thread: PerryThread
    @ObservedObject var model: HomeModel
    var focusComposer = false

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
                        VStack(alignment: .leading, spacing: 12) {
                            Text(turn.question)
                                .font(.headline)
                                .textSelection(.enabled)
                            if !turn.answer.isEmpty {
                                Text(turn.answer)
                                    .textSelection(.enabled)
                                    .lineSpacing(4)
                            }
                            if let reason = turn.failureReason {
                                Label(reason, systemImage: "exclamationmark.circle")
                                    .font(.callout)
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
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("I’ve reviewed the changes") { model.onResolveInterrupted?(thread.id) }
                        }
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(24)
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
                        .buttonStyle(.bordered)
                    }
                }
                if isWorking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.stoppingThreads.contains(thread.id) ? "Stopping…" : "Working on it")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop", systemImage: "stop.fill") { model.onStop?(thread.id) }
                            .controlSize(.small)
                            .disabled(model.stoppingThreads.contains(thread.id))
                    }
                } else if let error = model.threadErrors[thread.id], error != thread.turns.last?.failureReason {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HomeComposer(
                    text: Binding(
                        get: { model.draft(for: thread) },
                        set: { model.draftChanged(threadID: thread.id, draft: $0) }
                    ),
                    placeholder: "Ask a follow-up…",
                    canSend: !isWorking && thread.pendingTurn == nil,
                    focusOnAppear: focusComposer
                ) {
                    model.send(threadID: thread.id, text: model.draft(for: thread))
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
                .font(.headline)
            Text("These requests haven’t started. Review one in the composer when you’re ready.")
                .font(.callout)
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
        .confirmationDialog("Discard this saved request?", isPresented: Binding(
            get: { discarding != nil }, set: { if !$0 { discarding = nil } }
        ), titleVisibility: .visible) {
            Button("Discard request", role: .destructive) {
                if let input = discarding { remove(input.id) }
                discarding = nil
            }
            Button("Cancel", role: .cancel) { discarding = nil }
        }
    }
}

struct HomeComposer: View {
    @Binding var text: String
    let placeholder: String
    var canSend = true
    var focusOnAppear = false
    @FocusState private var focused: Bool
    let send: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(placeholder, text: $text, axis: .vertical)
                .focused($focused)
                .task { if focusOnAppear { focused = true } }
                .textFieldStyle(.plain)
                .lineLimit(2...6)
                .font(.body)
                .accessibilityLabel(placeholder)
            HStack {
                Spacer()
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Send message")
                .help("Send message (⌘Return)")
                .disabled(!canSend || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 20).fill(Color(nsColor: .controlBackgroundColor))
            } else if #available(macOS 26, *) {
                RoundedRectangle(cornerRadius: 20)
                    .fill(.clear)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
            } else {
                RoundedRectangle(cornerRadius: 20).fill(.regularMaterial)
            }
        }
    }
}

struct HomeConnectionView: View {
    @ObservedObject var brain: BrainController
    var onConnected: () -> Void = {}
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if brain.modelChoice != BrainController.ModelChoice.chatGPT.rawValue {
                Text(BrainController.ModelChoice(rawValue: brain.modelChoice).map { "\($0.title) selected" } ?? "Saved model unavailable")
                    .font(.headline)
                Text("Perry uses this choice for new Home and Talk requests. Change it or complete setup in model settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Model settings", action: openSettings)
            } else if case .signedIn = brain.account {
                Label("Connected to ChatGPT", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Connect your ChatGPT account")
                    .font(.headline)
                Text("Use your existing account to talk with Perry. Other models are available in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(brain.isSigningIn ? "Waiting for sign-in…" : "Connect ChatGPT") {
                        brain.signInWithChatGPT { connected in
                            if connected { onConnected() }
                        }
                    }
                    .disabled(brain.isSigningIn)
                    if brain.isSigningIn {
                        Button("Cancel") { brain.cancelSignIn() }
                    } else {
                        Button("Other models", action: openSettings)
                    }
                }
            }
            if let error = brain.signInError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: brain.account) { _, account in
            if brain.modelChoice == BrainController.ModelChoice.chatGPT.rawValue, case .signedIn = account { onConnected() }
        }
        .task {
            await brain.refresh()
            if brain.modelChoice == BrainController.ModelChoice.chatGPT.rawValue, case .signedIn = brain.account { onConnected() }
        }
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
