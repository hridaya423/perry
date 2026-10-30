import Foundation
import PerryBrain
import PerryGuide
import PerryOverlay

extension TalkSession {
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
                output?.guideSetStatus("I couldn’t start that question.")
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
            output?.guideSetStatus("Finish or dismiss what I’m doing before you ask.")
        }
    }

    func cancelAsk() {
        askTransitionTask?.cancel()
        askTransitionTask = nil
        turnTask?.cancel()
        turnTask = nil
        activeAskID = nil
        overlayState.visualGuidanceOverlays = []
    }

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
            index = ElementIndex(elements: baseline.observedElements)
            let spatial = AgentCoordinator.SpatialContext(
                observation: baseline,
                bindings: [],
                skill: services.skill(baseline)
            )
            let run = services.run(accepted, spatial)
            presentationTask = run.completion
            sessionController.updateAsk { $0.threadID = run.threadID }
            try await streamAsk(run.events, askID: askID, observation: baseline)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, activeAskID == askID else { return }
            overlayState.visualGuidanceOverlays = []
            sessionController.updateAsk { $0.isWorking = false }
            output?.guideSetBuddyState(.blocked)
            Self.logger.error("ask turn failed: \(String(describing: error), privacy: .public)")
            output?.guideSetStatus(Self.failureText(error))
        }
    }

    private func streamAsk(_ events: AsyncStream<AgentLoopEvent>, askID: UUID, observation: GuideObservation) async throws {
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
            case .draw(let command): draw(command, observation: observation)
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
