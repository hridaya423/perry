import Foundation
import PerryBrain
import PerryGuide

/// One funnel for typed and dictated commands — the panel's submit, the
/// voice dispatch hook, and the debug seam all end here. Parsing decides the
/// session; the router performs it.
@MainActor
final class CommandRouter {
    private weak var host: AppController?
    private var taskOffer: NotchConfirmation?

    init(host: AppController) {
        self.host = host
    }

    enum Route: Equatable {
        case showPanel
        case status(String)
        case steer(String)
        case dismiss
        case askInGuide(String, full: Bool)
        case ask(String)
        case guide(String)
        case showEverything(String)
        case doTask(String)
        case offerTask(String)
    }

    func route(commandText: String?, voiceTaskScope: UUID? = nil) {
        guard let host else { return }
        switch Self.decide(commandText, state: host.sessionController.state, voiceTaskScope: voiceTaskScope) {
        case .showPanel: host.showPanel()
        case .status(let status): host.sessionStatus = status
        case .steer(let text): host.foreground.steer(text)
        case .dismiss: host.dismiss()
        case .askInGuide(let request, let full): continueAskInGuide(request: request, full: full)
        case .ask(let question): host.ask(question: question)
        case .guide(let goal): host.startGuiding(goal: goal)
        case .showEverything(let goal): Task { await host.showEverything(goal: goal, targetHint: nil) }
        case .doTask(let goal): host.foreground.start(goal: goal)
        case .offerTask(let goal): offerTask(goal: goal)
        }
    }

    /// `voiceTaskScope` is the task a dictation hold began against: steering
    /// goes to that task only, so speech never redirects a task that started
    /// or changed while the user was talking.
    nonisolated static func decide(_ commandText: String?, state: SessionState, voiceTaskScope: UUID?) -> Route {
        guard let text = commandText, !text.isEmpty else { return .showPanel }
        let intent = GuideIntentParser.parse(text)
        if let voiceTaskScope {
            guard case .executing(let execution) = state, execution.taskID == voiceTaskScope else {
                return .status("That task already moved on. Hold the shortcut again to steer the current one.")
            }
            if case .dismiss = intent { return .dismiss }
            guard execution.lifecycle == .running || execution.lifecycle == .paused else {
                return .status("I can’t take direction right now. Use the task controls, or say “stop”.")
            }
            return .steer(text)
        }
        if case .asking(let ask) = state {
            switch intent {
            case .dismiss: return .dismiss
            case .guide: return .askInGuide(text, full: false)
            case .showEverything: return .askInGuide(text, full: true)
            case .doTask(let goal):
                let bare = goal == text.trimmingCharacters(in: .whitespacesAndNewlines)
                return .offerTask(bare ? ask.question : goal)
            case .notAGuideRequest: return .ask(text)
            }
        }
        if case .executing = state {
            return .status("A task started while you were speaking. Hold the shortcut again to steer it.")
        }
        switch intent {
        case .guide(let goal): return .guide(goal)
        case .showEverything(let goal): return .showEverything(goal)
        case .doTask(let goal): return .doTask(goal)
        case .dismiss: return .dismiss
        case .notAGuideRequest: return .ask(text)
        }
    }

    func runHomeGuide(
        input: HomeController.AcceptedInput, target: CuaTargetHint?, full: Bool,
        onPartial: @MainActor @Sendable (String) -> Void
    ) async -> AgentFinish {
        guard let host,
              let task = host.guideCoordinator.startGuiding(
                  goal: input.request.text, threadID: input.threadID,
                  targetHint: target, full: full, waitingInput: input.request
              ) else {
            return .failed("Finish or stop the current session before starting Guide. Your request is still here.")
        }
        onPartial("Preparing a guide…")
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func offerTask(goal: String) {
        taskOffer?.cancel()
        let offer = NotchConfirmation(
            title: "Do this as a task?",
            detail: "Perry will use your apps to: \(goal). You can stop it at any time.",
            destructiveTitle: "Start task",
            cancelTitle: "Keep asking"
        )
        taskOffer = offer
        Task { [weak self] in
            let confirmed = await offer.confirm()
            guard let self, self.taskOffer === offer else { return }
            self.taskOffer = nil
            guard confirmed, let host = self.host,
                  case .asking(let ask) = host.sessionController.state,
                  !host.isUnderMaintenance else { return }
            host.dismiss()
            host.foreground.start(goal: goal, threadID: ask.threadID)
        }
    }

    private func continueAskInGuide(request: String, full: Bool) {
        guard let host,
              case .asking(let ask) = host.sessionController.state,
              !host.isUnderMaintenance else { return }
        let accepted = host.homeController.acceptInput(request, threadID: ask.threadID ?? UUID())
        let input = accepted.request
        let threadID = accepted.threadID
        host.sessionController.updateAsk {
            $0.threadID = threadID
            $0.pendingGuideRequest = input
        }
        host.sessionStatus = "Saving your request while this answer finishes…"
        host.talkSession.afterCurrentAnswer(prepare: { [weak host] in
            guard let host else { return false }
            do {
                try await accepted.saved.value
                return !host.isUnderMaintenance
            } catch {
                host.homeController.homeModel.storageError = error.localizedDescription
                host.sessionStatus = "Couldn’t save your Guide request. Your text is still here."
                return false
            }
        }) { [weak host] current in
            guard let host, !host.isUnderMaintenance,
                  current.pendingGuideRequest?.id == input.id else { return }
            let target = host.homeController.homeModel.conversationTargets[threadID]
            host.dismiss()
            host.homeController.homeModel.sidebarSelection = .thread(threadID)
            host.guideCoordinator.startGuiding(
                goal: input.text, threadID: threadID, targetHint: target, full: full, waitingInput: input
            )
        }
    }
}

extension AppController {
    var isUnderMaintenance: Bool { maintenance.isUnderMaintenance }
}
