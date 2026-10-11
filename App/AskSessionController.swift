import AppKit
import PerryBrain
import PerryGuide
import PerryOverlay

@MainActor
final class AskSessionController {
    struct Runner {
        let accept: @MainActor (String, UUID?) -> HomeController.AcceptedInput
        let run: @MainActor (HomeController.AcceptedInput, GuideObservation) -> (threadID: UUID, events: AsyncStream<AgentLoopEvent>, completion: Task<Void, Never>?)
    }

    typealias ObservationProvider = @MainActor () async throws -> GuideObservation

    private let sessionController: SessionController
    private let workers: CuaWorkerService
    private let overlayState: PerryCursorState
    private weak var output: (any GuideSessionOutput)?
    private weak var context: (any GuideSessionContext)?
    private let runner: Runner
    private let observationProvider: ObservationProvider?
    private let targetStore = CuaGuideTargetStore()

    private var runTask: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?
    private var inputSaveTask: Task<Bool, Never>?
    private var activeAskID: UUID?

    init(
        sessionController: SessionController,
        workers: CuaWorkerService,
        overlayState: PerryCursorState,
        output: any GuideSessionOutput,
        context: any GuideSessionContext,
        observationProvider: ObservationProvider? = nil,
        runner: Runner
    ) {
        self.sessionController = sessionController
        self.workers = workers
        self.overlayState = overlayState
        self.output = output
        self.context = context
        self.runner = runner
        self.observationProvider = observationProvider
    }

    /// Ask-mode entry point. A first question opens a new session; while a
    /// session is live the same call is a follow-up that keeps its bounded
    /// conversation. Any other session kind must finish first — Ask never
    /// preempts Guide or Do.
    func submit(question rawQuestion: String) {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        switch sessionController.state {
        case .asking(let existing):
            activeAskID = existing.id
            sessionController.updateAsk {
                $0.question = question
                $0.pendingGuideRequest = nil
                $0.isWorking = true
            }
            start(question: question, askID: existing.id)
        case .idle, .invoking:
            let attemptID: UUID
            do {
                if case .invoking(let invocation) = sessionController.state {
                    attemptID = invocation.id
                } else {
                    attemptID = UUID()
                    try sessionController.wake(attemptID: attemptID)
                }
                var ask = AskSessionState(id: UUID(), startedAt: Date(), question: question)
                ask.isWorking = true
                try sessionController.startAsk(ask, attemptID: attemptID)
            } catch {
                output?.guideSetStatus("Perry couldn't start a question.")
                return
            }
            let askID: UUID
            if case .asking(let ask) = sessionController.state {
                askID = ask.id
            } else {
                return
            }
            activeAskID = askID
            output?.guideShowOverlay()
            start(question: question, askID: askID)
        case .guiding, .executing, .reporting, .failed, .talking:
            output?.guideSetStatus("Finish or dismiss the current session before asking.")
        }
    }

    /// Stops pending provider/capture work and drops follow-up context. The
    /// session-state transition itself belongs to SessionController.dismiss.
    func cancel() {
        transitionTask?.cancel()
        transitionTask = nil
        runTask?.cancel()
        runTask = nil
        activeAskID = nil
        overlayState.visualGuidanceOverlays = []
    }

    func joinInputSaves() async {
        _ = await inputSaveTask?.value
    }

    func afterCurrentAnswer(
        prepare: @escaping @MainActor () async -> Bool = { true },
        _ action: @escaping @MainActor (AskSessionState) -> Void
    ) {
        guard case .asking(let original) = sessionController.state else { return }
        transitionTask?.cancel()
        let answerTask = runTask
        let previousSave = inputSaveTask
        let saveTask = Task { @MainActor in
            _ = await previousSave?.value
            return await prepare()
        }
        inputSaveTask = saveTask
        transitionTask = Task { @MainActor [weak self] in
            guard await saveTask.value, !Task.isCancelled else { return }
            await answerTask?.value
            guard !Task.isCancelled, let self else { return }
            await self.presentationTask?.value
            guard !Task.isCancelled,
                  case .asking(let current) = self.sessionController.state,
                  current.id == original.id, !current.isWorking else { return }
            self.transitionTask = nil
            action(current)
        }
    }

    private func start(question: String, askID: UUID) {
        transitionTask?.cancel()
        transitionTask = nil
        runTask?.cancel()
        guard case .asking(let ask) = sessionController.state else { return }
        let accepted = runner.accept(question, ask.threadID)
        sessionController.updateAsk { $0.threadID = accepted.threadID }
        output?.guideSetBuddyState(.thinking)
        output?.guideSetStatus("Looking at the screen…")
        runTask = Task { @MainActor [weak self] in
            await self?.run(askID: askID, accepted: accepted)
        }
    }

    private func run(askID: UUID, accepted: HomeController.AcceptedInput) async {
        do {
            try await accepted.saved.value
            try Task.checkCancellation()
            await presentationTask?.value
            try Task.checkCancellation()
            let baseline = try await capture()
            PerfMark.mark("capture.done")
            try GuideTargetValidator.requireUnprotected(baseline)
            try Task.checkCancellation()
            guard case .asking(let ask) = sessionController.state, ask.id == askID else { throw CancellationError() }
            let run = runner.run(accepted, baseline)
            presentationTask = run.completion
            sessionController.updateAsk { $0.threadID = run.threadID }
            try await stream(run.events, askID: askID)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, activeAskID == askID else { return }
            overlayState.visualGuidanceOverlays = []
            sessionController.updateAsk { $0.isWorking = false }
            output?.guideSetBuddyState(.blocked)
            output?.guideSetStatus(
                (error as? LocalizedError)?.errorDescription ?? "Perry couldn't answer that."
            )
        }
    }

    private func stream(_ events: AsyncStream<AgentLoopEvent>, askID: UUID) async throws {
        var answer = ""
        var finish: AgentFinish?
        for await event in events {
            try Task.checkCancellation()
            guard activeAskID == askID, case .asking(let ask) = sessionController.state, ask.id == askID else { throw CancellationError() }
            switch event {
            case .textDelta(let delta):
                if answer.isEmpty { PerfMark.mark("answer.first_text") }
                answer += delta
                sessionController.updateAsk { $0.answerText = answer }
            case .finished(let outcome): finish = outcome
            default: break
            }
        }
        try Task.checkCancellation()
        guard activeAskID == askID, case .asking(let ask) = sessionController.state, ask.id == askID else { throw CancellationError() }
        guard finish == .completed else {
            throw ModelProviderError(kind: .unavailable, provider: "ask", message: finish?.failureReason ?? "The answer ended before completion. Try again.")
        }
        sessionController.updateAsk {
            $0.followUpPrompt = nil
            $0.turnCount += 1
            $0.isWorking = false
        }
        output?.guideSpeak(answer, identity: GuideSpeechIdentity(guideID: askID, scopeID: askID, stepID: nil, text: answer))
        output?.guideSetBuddyState(.success)
        output?.guideSetStatus("Ask a follow-up or press Esc to finish.")
    }

    private func capture() async throws -> GuideObservation {
        if let observationProvider {
            return try await observationProvider()
        }
        let hint = context?.guideTargetHint() ?? CuaTargetHint()
        await targetStore.set(hint)
        var resources = Set<BackgroundTaskResource>()
        if let bundleID = context?.guideAppBundleID(for: hint) {
            resources.insert(.application(bundleID))
        }
        return try await workers.withWorker(scope: .dictation, resources: resources) { @MainActor worker in
            try await CuaGuideTreeReader(worker: worker, targetStore: self.targetStore).observe()
        }
    }
}
