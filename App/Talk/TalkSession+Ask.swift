import Foundation
import PerryBrain
import PerryGuide
import PerryOverlay

/// The typed Ask surface, folded into TalkSession: a composer question runs
/// the same accept → capture → run → stream pipeline as a spoken turn, on
/// `SessionState.asking` instead of `.talking`. Ask never acts — the same
/// draw/observe-only request shape the spoken path builds.
extension TalkSession {

    /// Ask-mode entry point. A first question opens a new session; while a
    /// session is live the same call is a follow-up that keeps its bounded
    /// conversation. Any other session kind must finish first — Ask never
    /// preempts Guide or Do.
    func submitComposer(question rawQuestion: String) {
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
            startAskTurn(question: question, askID: existing.id)
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
            startAskTurn(question: question, askID: askID)
        case .guiding, .executing, .reporting, .failed, .talking:
            output?.guideSetStatus("Finish or dismiss the current session before asking.")
        }
    }

    /// Stops pending capture/run work and drops follow-up context. The
    /// session-state transition itself belongs to SessionController.dismiss.
    /// `cancel()` calls this; it is also safe to call alone during `.asking`.
    func cancelAsk() {
        askTransitionTask?.cancel()
        askTransitionTask = nil
        turnTask?.cancel()
        turnTask = nil
        activeAskID = nil
        overlayState.visualGuidanceOverlays = []
    }

    /// Maintenance drains in-flight input persistence through here before
    /// erasure or shutdown.
    func joinInputSaves() async {
        _ = await askInputSaveTask?.value
    }

    func afterCurrentAnswer(
        prepare: @escaping @MainActor () async -> Bool = { true },
        _ action: @escaping @MainActor (AskSessionState) -> Void
    ) {
        guard case .asking(let original) = sessionController.state else { return }
        askTransitionTask?.cancel()
        let answerTask = turnTask
        let previousSave = askInputSaveTask
        let saveTask = Task { @MainActor in
            _ = await previousSave?.value
            return await prepare()
        }
        askInputSaveTask = saveTask
        askTransitionTask = Task { @MainActor [weak self] in
            guard await saveTask.value, !Task.isCancelled else { return }
            await answerTask?.value
            guard !Task.isCancelled, let self else { return }
            await self.presentationTask?.value
            guard !Task.isCancelled,
                  case .asking(let current) = self.sessionController.state,
                  current.id == original.id, !current.isWorking else { return }
            self.askTransitionTask = nil
            action(current)
        }
    }

    private func startAskTurn(question: String, askID: UUID) {
        askTransitionTask?.cancel()
        askTransitionTask = nil
        turnTask?.cancel()
        guard case .asking(let ask) = sessionController.state else { return }
        let accepted = services.acceptInput(question, ask.threadID, nil)
        sessionController.updateAsk { $0.threadID = accepted.threadID }
        output?.guideSetBuddyState(.thinking)
        output?.guideSetStatus("Looking at the screen…")
        turnTask = Task { @MainActor [weak self] in
            await self?.runAsk(askID: askID, accepted: accepted)
        }
    }

    private func runAsk(askID: UUID, accepted: HomeController.AcceptedInput) async {
        do {
            try await accepted.saved.value
            try Task.checkCancellation()
            await presentationTask?.value
            try Task.checkCancellation()
            let baseline = try await services.capture()
            PerfMark.mark("capture.done")
            try GuideTargetValidator.requireUnprotected(baseline)
            try Task.checkCancellation()
            guard case .asking(let ask) = sessionController.state, ask.id == askID else { throw CancellationError() }
            let spatial = AgentCoordinator.SpatialContext(
                observation: baseline,
                bindings: [],
                skill: services.skill(baseline)
            )
            let run = services.run(accepted, spatial)
            presentationTask = run.completion
            sessionController.updateAsk { $0.threadID = run.threadID }
            try await streamAsk(run.events, askID: askID)
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

    private func streamAsk(_ events: AsyncStream<AgentLoopEvent>, askID: UUID) async throws {
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
}
