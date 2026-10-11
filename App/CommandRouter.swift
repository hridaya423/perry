import Foundation
import PerryBrain
import PerryGuide

/// What routing a text command needs from the app: the sessions it can
/// dispatch to and the surfaces it dismisses into. Implemented by
/// AppController.
@MainActor
protocol CommandRouteHost: AnyObject {
    var sessionController: SessionController { get }
    var homeController: HomeController { get }
    var askController: AskSessionController { get }
    var guideCoordinator: GuideSessionCoordinator { get }
    var foreground: ForegroundTaskController { get }
    var sessionStatus: String { get set }
    var isUnderMaintenance: Bool { get }
    func showPanel()
    func dismiss()
    func ask(question: String)
    func startGuiding(goal: String)
    func showEverything(goal: String, targetHint: CuaTargetHint?) async
}

/// One funnel for typed and dictated commands — the panel's submit, the
/// voice dispatch hook, and the debug seam all end here. Parsing decides the
/// session; the router performs it.
@MainActor
final class CommandRouter {
    private weak var host: (any CommandRouteHost)?

    init(host: any CommandRouteHost) {
        self.host = host
    }

    func route(commandText: String?) {
        guard let host else { return }
        guard let text = commandText, !text.isEmpty else {
            host.showPanel()
            return
        }
        if case .asking = host.sessionController.state {
            switch GuideIntentParser.parse(text) {
            case .dismiss:
                host.dismiss()
            case .guide:
                continueAskInGuide(request: text, full: false)
            case .showEverything:
                continueAskInGuide(request: text, full: true)
            case .doTask, .notAGuideRequest:
                host.ask(question: text)
            }
            return
        }
        switch GuideIntentParser.parse(text) {
        case .guide(let goal):
            host.startGuiding(goal: goal)
        case .showEverything(let goal):
            Task { await host.showEverything(goal: goal, targetHint: nil) }
        case .doTask(let goal):
            host.foreground.start(goal: goal)
        case .dismiss:
            host.dismiss()
        case .notAGuideRequest:
            host.ask(question: text)
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
        host.askController.afterCurrentAnswer(prepare: { [weak host] in
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
