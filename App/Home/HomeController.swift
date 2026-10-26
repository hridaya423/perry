import AppKit
import Combine
import SwiftUI
import PerryBrain
import PerryGuide
import PerryOverlay

@MainActor
final class HomeController {
    struct AcceptedInput {
        let threadID: UUID
        let request: PerryThread.WaitingInput
        let saved: Task<Void, Error>
    }

    private var acceptsInput = true
    private var work: [UUID: (task: Task<Void, Never>, cancelOnMaintenance: Bool)] = [:]
    private var inputSaveTask: Task<Void, Error>?
    private let talkContextStore = TalkContextStore()

    func joinInputSaves() async {
        _ = await inputSaveTask?.result
    }

    let homeModel = HomeModel()
    private var welcomeDraftEdited = false
    private var welcomeDraftLoaded = false
    private var welcomeDraftSaveTask: Task<Void, Never>?
    private var recoveryWriteTask: Task<Void, Never>?

    var threadStore: ThreadStore?
    var captureTarget: (() -> CuaTargetHint?)?
    var answerProvider: ((AcceptedInput, CuaTargetHint?, @MainActor @Sendable (String) -> Void) async -> AgentFinish)?
    var onStop: ((UUID) -> Void)?
    var onOpenConversation: (() -> Void)?

    /// Owner binds the coordinator's running set → composer's working row.
    func bindWorkingThreads(_ publisher: some Publisher<Set<UUID>, Never>) -> AnyCancellable {
        publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] threads in
                guard let self else { return }
                self.homeModel.workingThreads = threads
                self.performWork { await self.refreshThreads() }
            }
    }

    // MARK: - Lifecycle

    func closeAdmission() {
        acceptsInput = false
        for item in work.values where item.cancelOnMaintenance { item.task.cancel() }
    }

    func joinAll() async {
        for item in work.values { await item.task.value }
        await joinInputSaves()
    }

    func reopenAdmission() {
        acceptsInput = true
    }

    func reloadAfterErasure() async {
        _ = await threadStore?.reload()
        homeModel.drafts = [:]
        homeModel.pendingQuestions = [:]
        homeModel.streamingAnswers = [:]
        homeModel.threadErrors = [:]
        homeModel.storageError = nil
        homeModel.unsavedInputs = []
        homeModel.savingInputs = []
        homeModel.workingThreads = []
        homeModel.stoppingThreads = []
        homeModel.conversationPositions = [:]
        homeModel.conversationTargets = [:]
        homeModel.newConversationTarget = nil
        homeModel.newConversationDraft = ""
        homeModel.sidebarSelection = nil
        welcomeDraftLoaded = false
        welcomeDraftEdited = false
        await restoreWelcomeDraft()
        await refreshThreads()
        homeModel.perrys = await perryListProvider?() ?? []
        homeModel.routines = routineListProvider?() ?? []
        homeModel.suggestions = []
    }

    @discardableResult
    private func performWork(cancelOnMaintenance: Bool = false, _ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard acceptsInput else { return nil }
        let id = UUID()
        let task = Task { @MainActor in
            defer { self.work[id] = nil }
            await operation()
        }
        work[id] = (task, cancelOnMaintenance)
        return task
    }

    // MARK: - Content

    func updatePerrys(_ perrys: [Perry]) {
        guard homeModel.perrys != perrys else { return }
        homeModel.perrys = perrys
    }

    /// Refreshes the sidebar's Perry list — injected by AppController so the
    /// view never touches `PerryStore` directly.
    var perryListProvider: (() async -> [Perry])?

    /// Owns card lifecycle (act/dismiss bookkeeping); injected by the owner.
    var suggestionController: SuggestionController?

    /// Sidebar routines — injected so the view never touches RoutineStore.
    var routineListProvider: (() -> [LearnedRoutine])?
    var onRoutineRun: ((LearnedRoutine) -> Void)?
    var onRoutineRemove: ((LearnedRoutine) -> Void)?

    func updateSuggestions(_ cards: [SuggestionCard]) {
        homeModel.suggestions = cards
    }

    func refreshRoutines() {
        homeModel.routines = routineListProvider?() ?? []
    }

    /// Services the embedded pages need — set once by AppController.
    func configure(deps: HomeModel.Deps) {
        homeModel.deps = deps
    }

    // MARK: - Full Home

    func openHome(selection: HomeModel.Selection? = nil) {
        guard acceptsInput else { return }
        if homeModel.newConversationDraft.isEmpty || homeModel.newConversationTarget == nil {
            homeModel.newConversationTarget = captureTarget?()
        }
        if let selection { homeModel.sidebarSelection = selection }
        refreshRoutines()
        performWork {
            await self.restoreWelcomeDraft()
            await self.refreshThreads()
            if let perryListProvider = self.perryListProvider {
                self.homeModel.perrys = await perryListProvider()
            }
        }
        NotchPresentation.shared.showsInteraction = false
        onOpenConversation?()
        PerfMark.mark("notch.workspace.opened")
    }

    func closeHome() {
        homeModel.deps.controller?.collapseNotch()
    }

    init() {
        homeModel.onRetryInputSave = { [weak self] id in
            guard let self, self.acceptsInput, !self.homeModel.savingInputs.contains(id),
                  let input = self.homeModel.unsavedInputs.first(where: { $0.id == id }) else { return }
            _ = self.saveInput(input.request, to: input.threadID)
        }
        homeModel.onDiscardUnsavedInput = { [weak self] id in
            guard let self, self.acceptsInput, !self.homeModel.savingInputs.contains(id) else { return }
            self.homeModel.unsavedInputs.removeAll { $0.id == id }
        }
        homeModel.onNewDraftChanged = { [weak self] text in
            guard let self, self.acceptsInput else { return }
            self.welcomeDraftEdited = true
            self.welcomeDraftSaveTask?.cancel()
            self.welcomeDraftSaveTask = self.performWork {
                do {
                    try await Task.sleep(for: .milliseconds(400))
                    try await self.threadStore?.setWelcomeDraft(text)
                } catch is CancellationError {
                } catch {
                    self.homeModel.storageError = "Couldn’t save your draft. Keep Perry open and try again. \(error.localizedDescription)"
                }
            }
        }
        homeModel.onRestoreWaitingInput = { [weak self] id, inputID in
            guard let self, self.acceptsInput,
                  let thread = self.homeModel.threads.first(where: { $0.id == id }),
                  self.homeModel.draft(for: thread).isEmpty,
                  thread.pendingTurn == nil,
                  !self.homeModel.workingThreads.contains(id),
                  let input = thread.waitingInputs?.first(where: { $0.id == inputID }) else { return }
            self.homeModel.drafts[id] = input.text
            let previousWrite = self.recoveryWriteTask
            self.recoveryWriteTask = self.performWork {
                await previousWrite?.value
                do {
                    guard let store = self.threadStore else { throw CocoaError(.fileReadUnknown) }
                    try await store.restoreWaitingInput(inputID, from: id)
                    self.homeModel.storageError = nil
                    await self.refreshThreads()
                } catch { self.homeModel.storageError = error.localizedDescription }
            }
        }
        homeModel.onRemoveWaitingInput = { [weak self] id, inputID in
            guard let self, self.acceptsInput else { return }
            let previousWrite = self.recoveryWriteTask
            self.recoveryWriteTask = self.performWork {
                await previousWrite?.value
                do {
                    guard let store = self.threadStore else { throw CocoaError(.fileReadUnknown) }
                    try await store.removeWaitingInput(inputID, from: id)
                    self.homeModel.storageError = nil
                    await self.refreshThreads()
                } catch { self.homeModel.storageError = error.localizedDescription }
            }
        }
        homeModel.onResolveInterrupted = { [weak self] id in
            guard let self, self.acceptsInput, !self.homeModel.workingThreads.contains(id) else { return }
            self.performWork {
                guard let store = self.threadStore, let pending = await store.thread(id: id)?.pendingTurn else { return }
                do {
                    try await store.finishTurn(
                        to: id, runID: pending.id, answer: self.homeModel.streamingAnswers[id] ?? "",
                        outcome: .interrupted, failureReason: "You reviewed this task. I haven’t confirmed its changes."
                    )
                    self.homeModel.streamingAnswers[id] = nil
                    await self.refreshThreads()
                } catch {
                    self.homeModel.storageError = error.localizedDescription
                }
            }
        }
        homeModel.onStop = { [weak self] id in
            guard let self, self.acceptsInput,
                  self.homeModel.pendingQuestions[id] != nil || self.homeModel.workingThreads.contains(id),
                  self.homeModel.stoppingThreads.insert(id).inserted else { return }
            self.onStop?(id)
        }
        homeModel.onStartConversation = { [weak self] text in
            guard let self, self.acceptsInput, !self.homeModel.isCreatingConversation,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let mode = self.homeModel.composerMode
            if mode != .ask, let controller = self.homeModel.deps.controller {
                let goal = text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.homeModel.composerMode = .ask
                self.homeModel.updateNewDraft("")
                switch mode {
                case .guide: controller.startGuiding(goal: goal)
                case .task: controller.foreground.start(goal: goal)
                case .background: controller.backgroundTasks.queue(goal: goal)
                case .ask: break
                }
                return
            }
            self.homeModel.isCreatingConversation = true
            let target = self.homeModel.newConversationTarget
            let input = self.acceptInput(text, threadID: UUID())
            self.homeModel.conversationTargets[input.threadID] = target
            self.submitHomeInput(input, target: target, welcomeDraft: text)
        }
        homeModel.onSend = { [weak self] threadID, text in
            guard let self, self.acceptsInput else { return }
            let target = self.homeModel.conversationTargets[threadID]
            let input = self.acceptInput(text, threadID: threadID)
            self.homeModel.conversationTargets[input.threadID] = target
            self.submitHomeInput(input, target: target)
        }

        homeModel.onDraftChanged = { [weak self] id, draft in
            guard let self, self.acceptsInput else { return }
            self.performWork {
                do {
                    try await self.threadStore?.setDraft(draft, for: id)
                    self.homeModel.storageError = nil
                } catch {
                    self.homeModel.storageError = "Couldn’t save your draft. Keep Perry open and try again. \(error.localizedDescription)"
                }
            }
        }
        homeModel.onSuggestionAct = { [weak self] card in
            guard let self, self.acceptsInput else { return }
            self.performWork {
                guard let store = self.threadStore else {
                    self.homeModel.storageError = "Conversation storage is unavailable. The suggestion is still here."
                    return
                }
                let threadID = UUID()
                do {
                    try await store.upsert(PerryThread(id: threadID, title: card.title, sourceServiceID: card.sourceServiceID, draft: card.body))
                    await self.refreshThreads()
                    self.homeModel.sidebarSelection = .thread(threadID)
                    self.suggestionController?.act(on: card) { card in
                        self.homeModel.send(threadID: threadID, text: card.body)
                    }
                } catch {
                    self.homeModel.storageError = error.localizedDescription
                }
            }
        }
        homeModel.onSuggestionAdjust = { [weak self] card in
            guard let self, self.acceptsInput else { return }
            self.suggestionController?.adjust(card)
        }
        homeModel.onSuggestionDismiss = { [weak self] card in
            guard let self, self.acceptsInput else { return }
            self.suggestionController?.dismiss(card)
        }
        homeModel.onRoutineRun = { [weak self] routine in
            guard let self, self.acceptsInput else { return }
            self.onRoutineRun?(routine)
        }
        homeModel.onRoutineRemove = { [weak self] routine in
            guard let self, self.acceptsInput else { return }
            self.onRoutineRemove?(routine)
            self.refreshRoutines()
        }
        homeModel.onPerrySelected = { [weak self] perry in
            guard let self, self.acceptsInput, let uuid = UUID(uuidString: perry.threadID) else { return }
            self.performWork {
                // The Perry's thread is created on first open, stamped with
                // perryID so tool consent scopes to the Perry, not the turn.
                if await self.threadStore?.thread(id: uuid) == nil {
                    do {
                        try await self.threadStore?.upsert(
                            PerryThread(id: uuid, title: perry.name, perryID: perry.id.uuidString)
                        )
                    } catch {
                        self.homeModel.storageError = error.localizedDescription
                        return
                    }
                }
                await self.refreshThreads()
                self.homeModel.sidebarSelection = .thread(uuid)
            }
        }
    }

    private func submitHomeInput(_ input: AcceptedInput, target: CuaTargetHint?, welcomeDraft: String? = nil) {
        let threadID = input.threadID
        homeModel.pendingQuestions[threadID] = .init(
            text: input.request.text, turnIndex: homeModel.threads.first { $0.id == threadID }?.turns.count ?? 0
        )
        homeModel.threadErrors[threadID] = nil
        performWork(cancelOnMaintenance: true) {
            defer { if welcomeDraft != nil { self.homeModel.isCreatingConversation = false } }
            let finish = await self.presentRun(threadID: threadID, text: input.request.text) { onPartial in
                do {
                    try await input.saved.value
                    try Task.checkCancellation()
                    guard self.acceptsInput, !self.homeModel.stoppingThreads.contains(threadID) else { return .interrupted }
                    if let welcomeDraft, self.homeModel.newConversationDraft == welcomeDraft {
                        self.homeModel.updateNewDraft("")
                    }
                    return await self.answerProvider?(input, target, onPartial)
                        ?? .failed(PromptAssembler.noBrainAnswer)
                } catch is CancellationError {
                    return .interrupted
                } catch {
                    return .failed("Couldn’t save your message. Open Messages not saved to recover it.")
                }
            }
            if finish == .interrupted {
                // Accepted but never dispatched: promote the staged request
                // into the thread draft so it survives quit. restoreWaitingInput
                // refuses when the composer already holds another draft — the
                // staged copy stays listed for manual restore.
                try? await self.threadStore?.restoreWaitingInput(input.request.id, from: threadID)
            }
        }
    }

    func acceptInput(_ text: String, threadID requestedThreadID: UUID? = nil, contextKey: TalkContextKey? = nil) -> AcceptedInput {
        guard acceptsInput else {
            return AcceptedInput(threadID: requestedThreadID ?? UUID(), request: .init(text: text), saved: Task { throw CancellationError() })
        }
        let threadID: UUID
        if TalkContextStore.isResetPhrase(text) {
            if let contextKey { talkContextStore.reset(contextKey) }
            threadID = UUID()
        } else if let requestedThreadID {
            threadID = requestedThreadID
        } else if let contextKey {
            // Talk holds keep one thread per app window (Phase 2.5): a window
            // that already has a live thread continues it, a fresh window
            // starts fresh — never spilling into an unrelated selected thread.
            if let mapped = talkContextStore.thread(for: contextKey),
               homeModel.threads.contains(where: { $0.id == mapped }) {
                threadID = mapped
            } else {
                threadID = UUID()
            }
        } else if case .thread(let selected) = homeModel.sidebarSelection {
            threadID = selected
        } else {
            threadID = UUID()
        }
        if let contextKey { talkContextStore.record(contextKey, threadID: threadID) }
        let request = PerryThread.WaitingInput(text: text)
        PerfMark.mark("home.question.sent")
        let saved = saveInput(request, to: threadID)
        if !homeModel.threads.contains(where: { $0.id == threadID }) {
            var thread = PerryThread(id: threadID)
            thread.title = ThreadStore.derivedTitle(from: text)
            homeModel.threads.insert(thread, at: 0)
        }
        homeModel.sidebarSelection = .thread(threadID)
        return AcceptedInput(threadID: threadID, request: request, saved: saved)
    }

    private func saveInput(_ request: PerryThread.WaitingInput, to threadID: UUID) -> Task<Void, Error> {
        let isRetry = homeModel.unsavedInputs.contains { $0.id == request.id }
        homeModel.savingInputs.insert(request.id)
        let previousSave = inputSaveTask
        let saved = Task { @MainActor in
            _ = await previousSave?.result
            defer { self.homeModel.savingInputs.remove(request.id) }
            do {
                guard let store = self.threadStore else { throw CocoaError(.fileWriteUnknown) }
                if isRetry { _ = await store.reload() }
                try await store.stageInput(request, to: threadID)
                self.homeModel.unsavedInputs.removeAll { $0.id == request.id }
                await self.refreshThreads()
                if isRetry { self.homeModel.sidebarSelection = .thread(threadID) }
            } catch {
                self.retainUnsavedInput(request, threadID: threadID, error: error)
                throw error
            }
        }
        inputSaveTask = saved
        return saved
    }

    private func retainUnsavedInput(_ request: PerryThread.WaitingInput, threadID: UUID, error: Error) {
        if let index = homeModel.unsavedInputs.firstIndex(where: { $0.id == request.id }) {
            homeModel.unsavedInputs[index].error = error.localizedDescription
        } else {
            homeModel.unsavedInputs.append(.init(threadID: threadID, request: request, error: error.localizedDescription))
        }
    }

    func runSpokenTurn(_ input: AcceptedInput, spatial: AgentCoordinator.SpatialContext?, coordinator: AgentCoordinator) -> (threadID: UUID, events: AsyncStream<AgentLoopEvent>, completion: Task<Void, Never>?) {
        let threadID = input.threadID
        let text = input.request.text
        guard acceptsInput else {
            return (threadID, AsyncStream { $0.yield(.finished(.interrupted)); $0.finish() }, nil)
        }
        guard homeModel.pendingQuestions[threadID] == nil, !coordinator.runningThreads.contains(threadID) else {
            return (threadID, AsyncStream { continuation in
                continuation.yield(.finished(.failed("This conversation is still working. Stop it or wait before asking another question.")))
                continuation.finish()
            }, nil)
        }
        homeModel.pendingQuestions[threadID] = .init(
            text: text, turnIndex: homeModel.threads.first { $0.id == threadID }?.turns.count ?? 0
        )
        let target = spatial?.target ?? homeModel.conversationTargets[threadID] ?? homeModel.newConversationTarget
        homeModel.sidebarSelection = .thread(threadID)
        homeModel.conversationTargets[threadID] = target
        let (events, continuation) = AsyncStream<AgentLoopEvent>.makeStream()
        let task = performWork(cancelOnMaintenance: true) {
            do {
                try await input.saved.value
            } catch {
                self.homeModel.pendingQuestions[threadID] = nil
                self.homeModel.stoppingThreads.remove(threadID)
                continuation.yield(.finished(.failed(self.homeModel.storageError ?? error.localizedDescription)))
                continuation.finish()
                return
            }
            let finish = await self.presentRun(threadID: threadID, text: text) { onPartial in
                var answer = ""
                var finish: AgentFinish = .interrupted
                for await event in coordinator.run(threadID: threadID, goal: text, surface: .talk, runID: input.request.id, target: target, spatialContext: spatial, waitingInputID: input.request.id) {
                    switch event {
                    case .textDelta(let delta):
                        answer += delta
                        onPartial(answer)
                    case .finished(let outcome):
                        finish = outcome
                        continue
                    default: break
                    }
                    continuation.yield(event)
                }
                return finish
            }
            if finish == .interrupted {
                try? await self.threadStore?.restoreWaitingInput(input.request.id, from: threadID)
            }
            continuation.yield(.finished(finish))
            continuation.finish()
        }
        continuation.onTermination = { _ in task?.cancel() }
        return (threadID, events, task)
    }

    private func presentRun(
        threadID: UUID, text: String,
        operation: (@escaping @MainActor @Sendable (String) -> Void) async -> AgentFinish
    ) async -> AgentFinish {
        defer { homeModel.stoppingThreads.remove(threadID) }
        guard !Task.isCancelled, !homeModel.stoppingThreads.contains(threadID) else {
            homeModel.threadErrors[threadID] = "I stopped before starting. Your message is still here."
            homeModel.pendingQuestions[threadID] = nil
            return .interrupted
        }
        homeModel.threadErrors[threadID] = nil
        var markedFirstText = false
        let finish = await operation { [weak self] partial in
            if !markedFirstText, !partial.isEmpty {
                markedFirstText = true
                PerfMark.mark("home.answer.first_text")
            }
            self?.homeModel.streamingAnswers[threadID] = partial
        }
        if !markedFirstText, finish == .completed {
            // Non-streaming providers answer only at finish — the first
            // visible text lands here.
            PerfMark.mark("home.answer.first_text")
        }
        homeModel.threadErrors[threadID] = finish.failureReason
        if finish == .completed, homeModel.drafts[threadID] == text { homeModel.drafts[threadID] = nil }
        await refreshThreads()
        homeModel.pendingQuestions[threadID] = nil
        if homeModel.threads.first(where: { $0.id == threadID })?.pendingTurn == nil {
            homeModel.streamingAnswers[threadID] = nil
        }
        return finish
    }

    func prepareConversation(target: CuaTargetHint?) {
        guard acceptsInput else { return }
        if homeModel.newConversationDraft.isEmpty || homeModel.newConversationTarget == nil {
            homeModel.newConversationTarget = target
        }
        performWork {
            await self.restoreWelcomeDraft()
            await self.refreshThreads()
        }
    }


    @MainActor
    private func restoreWelcomeDraft() async {
        guard !welcomeDraftLoaded else { return }
        welcomeDraftLoaded = true
        do {
            let saved = try await threadStore?.welcomeDraft() ?? ""
            if !welcomeDraftEdited { homeModel.newConversationDraft = saved }
        } catch {
            homeModel.storageError = "Couldn’t open your unsent draft. Its file has been preserved. \(error.localizedDescription)"
        }
    }

    private func refreshThreads() async {
        homeModel.threads = await threadStore?.list() ?? []
        if let issue = await threadStore?.readIssues().first {
            homeModel.storageError = "Some conversations couldn’t be opened. Their original files are preserved at \(issue.file.path). \(issue.message)"
        }
    }
}
