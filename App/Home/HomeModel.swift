import Combine
import SwiftUI
import PerryBrain
import PerryCore
import PerryGuide

@MainActor
final class HomeModel: ObservableObject {
    enum Selection: Hashable {
        case thread(UUID)
        case history
        case tasks
        case files
        case routines
        case suggestions
        case settings
        case whatsNew
        case perryEditor(UUID?)
    }

    enum ComposerMode: CaseIterable {
        case ask, guide, task, background

        var title: String {
            switch self {
            case .ask: "Ask"
            case .guide: "Guide"
            case .task: "Do"
            case .background: "Do in background"
            }
        }

        var systemImage: String {
            switch self {
            case .ask: "bubble.left"
            case .guide: "hand.point.up.left"
            case .task: "bolt"
            case .background: "tray.and.arrow.down"
            }
        }
    }

    struct Deps {
        weak var controller: AppController?
        var brain: BrainController?
        var transcriptStore: TranscriptStore?
        var activityLog: ActivityLog?
        var undoableEntryIDs: (@MainActor () async -> Set<UUID>)?
        var backgroundTasks: BackgroundTaskController?
        var fileRoots: [URL] = []
    }

    struct ConversationScrollPosition: Equatable {
        var offset: CGFloat = 0
        var followsLatest = true
    }

    @Published var newConversationTarget: ScreenTargetHint?
    @Published var conversationTargets: [UUID: ScreenTargetHint] = [:]

    @Published var conversationPositions: [UUID: ConversationScrollPosition] = [:]
    @Published var onboarding: OnboardingDirector?
    @Published var newConversationDraft = ""
    @Published var isCreatingConversation = false
    @Published var search = ""
    struct UnsavedInput: Identifiable {
        let threadID: UUID
        let request: PerryThread.WaitingInput
        var error: String
        var id: UUID { request.id }
    }

    @Published var unsavedInputs: [UnsavedInput] = []
    @Published var savingInputs: Set<UUID> = []
    var onRetryInputSave: ((UUID) -> Void)?
    var onDiscardUnsavedInput: ((UUID) -> Void)?
    @Published var storageError: String?
    @Published var drafts: [UUID: String] = [:]
    struct PendingQuestion: Equatable {
        let text: String
        let turnIndex: Int
        var inputID: UUID?
    }

    @Published var pendingQuestions: [UUID: PendingQuestion] = [:] {
        didSet { sendQueuedFollowUps() }
    }
    struct QueuedFollowUp: Identifiable, Equatable {
        let id: UUID
        let text: String

        init(id: UUID = UUID(), text: String) {
            self.id = id
            self.text = text
        }
    }

    @Published var queuedFollowUps: [UUID: [QueuedFollowUp]] = [:]
    @Published var pausedQueues: Set<UUID> = []
    private var sendingNow: Set<UUID> = []
    @Published var threadErrors: [UUID: String] = [:]
    var onNewDraftChanged: ((String) -> Void)?
    var onStartConversation: ((String) -> Void)?
    var onStop: ((UUID) -> Void)?
    var onResolveInterrupted: ((UUID) -> Void)?
    var onRestoreWaitingInput: ((UUID, UUID) -> Void)?
    var onRemoveWaitingInput: ((UUID, UUID) -> Void)?

    var filteredThreads: [PerryThread] {
        guard !search.isEmpty else { return threads }
        return threads.filter { thread in
            thread.title.localizedCaseInsensitiveContains(search)
                || thread.turns.contains { $0.question.localizedCaseInsensitiveContains(search) || $0.answer.localizedCaseInsensitiveContains(search) }
        }
    }

    func updateNewDraft(_ text: String) {
        guard text != newConversationDraft else { return }
        composerNotice = nil
        newConversationDraft = text
        onNewDraftChanged?(text)
    }

    func draft(for thread: PerryThread) -> String { drafts[thread.id] ?? thread.draft }

    func displayedTurns(for thread: PerryThread) -> [PerryThread.Turn] {
        var turns = thread.turns
        let pending = pendingQuestions[thread.id]
        let question = pending.flatMap { $0.turnIndex == turns.count ? $0.text : nil } ?? thread.pendingTurn?.question
        if let question {
            turns.append(PerryThread.Turn(
                question: question, answer: streamingAnswers[thread.id] ?? "",
                at: thread.pendingTurn?.startedAt ?? thread.updatedAt
            ))
        }
        return turns
    }

    @Published var threads: [PerryThread] = [] {
        didSet { sendQueuedFollowUps() }
    }
    @Published var perrys: [Perry] = []
    @Published var sidebarSelection: Selection?
    @Published var composerMode: ComposerMode = .ask
    @Published var composerNotice: String?
    @Published var workingThreads: Set<UUID> = [] {
        didSet { sendQueuedFollowUps() }
    }
    @Published var stoppingThreads: Set<UUID> = []
    @Published var streamingAnswers: [UUID: String] = [:]
    @Published var suggestions: [SuggestionCard] = []
    @Published var routines: [LearnedRoutine] = []
    @Published var remembered: [UUID: [MemoryRecord]] = [:]
    var onForgetMemory: ((MemoryRecord) -> Void)?
    var deps = Deps() {
        didSet {
            backgroundTasksObservation = deps.backgroundTasks?.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }
    private var backgroundTasksObservation: AnyCancellable?

    var onDraftChanged: ((UUID, String) -> Void)?
    var onSend: ((UUID, String, UUID?) -> Bool)?
    var onQueueFollowUp: ((UUID, PerryThread.WaitingInput) -> Void)?
    var onPerrySelected: ((Perry) -> Void)?
    var onSuggestionAct: ((SuggestionCard) -> Void)?
    var onSuggestionAdjust: ((SuggestionCard) -> Void)?
    var onSuggestionDismiss: ((SuggestionCard) -> Void)?
    var onRoutineRun: ((LearnedRoutine) -> Void)?
    var onRoutineRemove: ((LearnedRoutine) -> Void)?

    func draftChanged(threadID: UUID, draft: String) {
        drafts[threadID] = draft
        onDraftChanged?(threadID, draft)
    }

    func isBusy(_ threadID: UUID) -> Bool {
        workingThreads.contains(threadID) || pendingQuestions[threadID] != nil
    }

    func send(threadID: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard isBusy(threadID) else {
            _ = onSend?(threadID, text, nil)
            return
        }
        let inFlight = pendingQuestions[threadID]?.text ?? threads.first { $0.id == threadID }?.pendingTurn?.question
        if trimmed != inFlight?.trimmingCharacters(in: .whitespacesAndNewlines) {
            let queued = QueuedFollowUp(text: trimmed)
            queuedFollowUps[threadID, default: []].append(queued)
            onQueueFollowUp?(threadID, .init(id: queued.id, text: trimmed))
        }
        draftChanged(threadID: threadID, draft: "")
    }

    func stop(threadID: UUID) {
        if !(queuedFollowUps[threadID] ?? []).isEmpty { pausedQueues.insert(threadID) }
        onStop?(threadID)
    }

    func sendQueuedNow(threadID: UUID, id: UUID) {
        guard var queue = queuedFollowUps[threadID], let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.insert(queue.remove(at: index), at: 0)
        queuedFollowUps[threadID] = queue
        pausedQueues.remove(threadID)
        if isBusy(threadID) {
            sendingNow.insert(threadID)
            onStop?(threadID)
        } else {
            sendQueuedFollowUps()
        }
    }

    func removeQueued(threadID: UUID, id: UUID) {
        guard queuedFollowUps[threadID]?.contains(where: { $0.id == id }) == true else { return }
        onRemoveWaitingInput?(threadID, id)
        queuedFollowUps[threadID]?.removeAll { $0.id == id }
        if queuedFollowUps[threadID]?.isEmpty == true {
            queuedFollowUps[threadID] = nil
            pausedQueues.remove(threadID)
        }
    }

    func turnEnded(threadID: UUID, finish: AgentFinish) {
        if finish != .completed, !sendingNow.contains(threadID), !(queuedFollowUps[threadID] ?? []).isEmpty {
            pausedQueues.insert(threadID)
        }
        sendingNow.remove(threadID)
    }

    func clearQueues() {
        queuedFollowUps = [:]
        pausedQueues = []
        sendingNow = []
    }

    func sendQueuedFollowUps() {
        for (threadID, queue) in queuedFollowUps {
            guard !isBusy(threadID) else { continue }
            guard let thread = threads.first(where: { $0.id == threadID }) else {
                queuedFollowUps[threadID] = nil
                pausedQueues.remove(threadID)
                sendingNow.remove(threadID)
                continue
            }
            guard let next = queue.first, !pausedQueues.contains(threadID), thread.pendingTurn == nil else { continue }
            queuedFollowUps[threadID] = queue.count > 1 ? Array(queue.dropFirst()) : nil
            if onSend?(threadID, next.text, next.id) == true {
                sendingNow.remove(threadID)
            } else {
                queuedFollowUps[threadID, default: []].insert(next, at: 0)
            }
        }
    }
}
