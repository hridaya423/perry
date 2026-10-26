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
        var runtimes: RuntimeCatalog?
        var fileRoots: [URL] = []
    }

    struct ConversationScrollPosition: Equatable {
        var offset: CGFloat = 0
        var followsLatest = true
    }

    @Published var newConversationTarget: CuaTargetHint?
    @Published var conversationTargets: [UUID: CuaTargetHint] = [:]

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
    }

    @Published var pendingQuestions: [UUID: PendingQuestion] = [:]
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

    @Published var threads: [PerryThread] = []
    @Published var perrys: [Perry] = []
    @Published var sidebarSelection: Selection?
    @Published var composerMode: ComposerMode = .ask
    @Published var workingThreads: Set<UUID> = []
    @Published var stoppingThreads: Set<UUID> = []
    @Published var streamingAnswers: [UUID: String] = [:]
    @Published var suggestions: [SuggestionCard] = []
    @Published var routines: [LearnedRoutine] = []
    @Published var remembered: [UUID: [MemoryRecord]] = [:]
    var onForgetMemory: ((MemoryRecord) -> Void)?
    var deps = Deps()

    var onDraftChanged: ((UUID, String) -> Void)?
    var onSend: ((UUID, String) -> Void)?
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

    func send(threadID: UUID, text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !workingThreads.contains(threadID), pendingQuestions[threadID] == nil else { return }
        onSend?(threadID, text)
    }
}
