import AppKit

/// What quit and erase need from the app: every subsystem they close,
/// stop, or join, plus the panel and status hooks. Implemented by
/// AppController — the member list is the documented blast radius of a
/// maintenance operation.
@MainActor
protocol MaintenanceHost: AnyObject {
    var mcp: MCPSocketLifecycle { get }
    var agentCoordinator: AgentCoordinator { get }
    var brain: BrainController { get }
    var homeController: HomeController { get }
    var backgroundTasks: BackgroundTaskController { get }
    var guideCoordinator: GuideSessionCoordinator { get }
    var workers: CuaWorkerService { get }
    var foreground: ForegroundTaskController { get }
    var talkSession: TalkSession { get }
    var notchStatus: NotchStatusController { get }
    var perryScheduler: PerrySchedulerController? { get }
    var suggestionController: SuggestionController { get }
    var routineLibrary: RoutineLibraryController { get }
    var voice: VoiceController { get }
    var spatial: SpatialSelectionController { get }
    var demoDirector: DemoDirector { get }
    var oauthCoordinator: OAuthCoordinator { get }
    var runtimes: RuntimeCatalog { get }
    var completeErasure: CompleteErasureCoordinator { get }
    var hasUnsavedHomeRequests: Bool { get }
    var sessionStatus: String { get set }
    func hidePanel()
}

/// Quit and erase are Perry's two "own the whole app" operations: both close
/// admission everywhere, run an ordered stop-and-join checklist, then hand
/// control back — or out. The ordering is the behavior, so it lives in one
/// place here rather than scattered across AppController's lifecycle methods.
@MainActor
final class MaintenanceCoordinator {
    private enum Operation { case termination, erasure }

    private weak var host: (any MaintenanceHost)?
    private var owner: Operation?
    private(set) var terminationPrepared = false
    private(set) var isErasureInProgress = false

    /// Nothing held and no quit underway — safe to accept new work.
    var isIdle: Bool { owner == nil && !terminationPrepared }
    /// A quit or erase currently owns the app.
    var isUnderMaintenance: Bool { owner != nil }

#if DEBUG
    var debugUnsavedQuitDecision: (() -> Bool)?
    private var debugMaintenanceBarrier: (@MainActor () async throws -> Void)?
    private var debugSkipEraseConfirmation = false

    func debugSetFixture(
        skipEraseConfirmation: Bool,
        barrier: (@MainActor () async throws -> Void)?
    ) {
        debugSkipEraseConfirmation = skipEraseConfirmation
        debugMaintenanceBarrier = barrier
    }
#endif

    init(host: any MaintenanceHost) {
        self.host = host
    }

    func requestTermination(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPrepared else { return .terminateNow }
        guard acquire(.termination) else {
            host?.sessionStatus = conflictMessage()
            sender.reply(toApplicationShouldTerminate: false)
            return .terminateLater
        }
        host?.runtimes.cancelPendingRefreshes()
        host?.backgroundTasks.closeControls()
        host?.guideCoordinator.prepareForTermination()
        Task { @MainActor [self] in
            var showRecovery = false
            defer {
                self.release(.termination)
                if showRecovery { self.host?.homeController.openHome() }
            }
            guard let host else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            do {
                try await self.prepareForTermination()
                try await host.workers.shutdown()
                await host.mcp.stop()
                await self.joinAfterWorkerShutdown()
                guard self.confirmQuitDiscardingUnsavedRequests() else {
                    host.backgroundTasks.reopenControls()
                    host.sessionStatus = "Perry stayed open. Recover your requests before quitting."
                    showRecovery = true
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                self.terminationPrepared = true
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                host.backgroundTasks.reopenControls()
                host.sessionStatus = "Perry could not stop its computer-use workers safely."
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    func requestCompleteErasure() {
#if DEBUG
        guard debugSkipEraseConfirmation || CompleteErasurePrompt.confirm() else { return }
#else
        guard CompleteErasurePrompt.confirm() else { return }
#endif
        guard acquire(.erasure) else {
            host?.sessionStatus = conflictMessage()
            return
        }
        host?.backgroundTasks.closeControls()
        host?.guideCoordinator.stopClickObservation()
        Task { @MainActor [self] in
            await self.performCompleteErasure(operation: .erasure)
        }
    }

    private func acquire(_ operation: Operation) -> Bool {
        guard owner == nil, let host else { return false }
        owner = operation
        host.mcp.suspend()
        host.agentCoordinator.closeAdmission()
        host.brain.closeAdmission()
        host.homeController.closeAdmission()
        host.hidePanel()
        return true
    }

    private func release(_ operation: Operation) {
        guard owner == operation else { return }
        owner = nil
        guard !terminationPrepared, let host else { return }
        host.agentCoordinator.reopenAdmission()
        host.brain.reopenAdmission()
        host.homeController.reopenAdmission()
        host.mcp.resume()
    }

    private func conflictMessage() -> String {
        switch owner {
        case .termination:
            return "Perry is already preparing to quit."
        case .erasure:
            return "Perry is finishing a data erase."
        case nil:
            return "Perry is already stopping its workers."
        }
    }

    static func unsavedRequestQuitAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit with unsaved requests?"
        alert.informativeText = "Some requests haven’t been saved. Keep Perry open to copy them or try saving again. Quitting will discard this text."
        alert.addButton(withTitle: "Keep Perry open")
        alert.addButton(withTitle: "Quit without saving").hasDestructiveAction = true
        return alert
    }

    private func confirmQuitDiscardingUnsavedRequests() -> Bool {
        guard let host, host.hasUnsavedHomeRequests else { return true }
#if DEBUG
        if let debugUnsavedQuitDecision { return debugUnsavedQuitDecision() }
#endif
        return Self.unsavedRequestQuitAlert().runModal() == .alertSecondButtonReturn
    }

    private func performCompleteErasure(operation: Operation) async {
        guard operation == .erasure,
              owner == operation,
              !isErasureInProgress else { return }
        isErasureInProgress = true
        host?.backgroundTasks.closeControls()
        host?.guideCoordinator.stopClickObservation()
        defer {
            isErasureInProgress = false
            host?.backgroundTasks.reopenControls()
            release(operation)
        }
        host?.oauthCoordinator.cancelAuthorization()
        guard let host else { return }
        do {
#if DEBUG
            if let barrier = debugMaintenanceBarrier {
                try await barrier()
            }
#endif
            try await pauseOwnedBackgroundTasksForWorkerStop()
            let report = try await host.workers.withWorkersStopped { @MainActor [self] in
                await self.stopWorkForErasure()
                let report = await host.completeErasure.erase()
                host.brain.reloadPreferences()
                await host.homeController.reloadAfterErasure()
                host.suggestionController.reloadCards()
                return report
            }
            host.voice.speak(report.summary)
        } catch {
            host.sessionStatus = "Perry could not stop its computer-use workers before erasing data."
        }
    }

    private func pauseOwnedBackgroundTasksForWorkerStop() async throws {
        guard let host else { return }
        try await host.backgroundTasks.pauseAllOwnedForWorkerStop()
        await host.foreground.cancelActiveSupervisor()
    }

    private func prepareForTermination() async throws {
        guard let host else { return }
        host.backgroundTasks.closeControls()
        await host.brain.stopSetup()
        host.talkSession.cancelAsk()
        host.talkSession.cancel()
        await host.talkSession.joinInputSaves()
        host.notchStatus.hide()
        host.homeController.stop()
        host.perryScheduler?.stop()
        host.suggestionController.stop()
        host.routineLibrary.stop()
        host.guideCoordinator.stopClickObservation()
        try await pauseOwnedBackgroundTasksForWorkerStop()
        host.voice.cancelInput()
        host.foreground.cancelStartTask()
        host.guideCoordinator.prepareForTermination()
        host.spatial.cancelDescription()
    }

    private func joinAfterWorkerShutdown() async {
        guard let host else { return }
        await host.guideCoordinator.joinAfterWorkerShutdown()
        await host.agentCoordinator.joinAll()
        await host.perryScheduler?.joinAll()
        await host.suggestionController.joinAll()
        await host.homeController.joinAll()
        await host.voice.joinInputWork()
        await host.spatial.joinDescription()
        await host.foreground.joinStartTask()
        await host.backgroundTasks.joinAll()
    }

    private func stopWorkForErasure() async {
        guard let host else { return }
        await host.mcp.discard()
        await host.brain.stopSetup()
        host.demoDirector.cancel()
        host.talkSession.cancelAsk()
        host.talkSession.cancel()
        await host.talkSession.joinInputSaves()
        host.notchStatus.hide()
        host.homeController.stop()
        host.perryScheduler?.stop()
        host.suggestionController.stop()
        host.routineLibrary.stop()
        await host.guideCoordinator.stopForErasure()
        await host.agentCoordinator.joinAll()
        await host.perryScheduler?.joinAll()
        await host.suggestionController.joinAll()
        await host.homeController.joinAll()
        host.spatial.stopMonitoring()
        host.foreground.cancelStartTask()
        await host.foreground.cancelActiveSupervisor()
        host.backgroundTasks.cancelAllOwned()
        await host.voice.joinInputWork()
        host.spatial.cancelDescription()
        await host.spatial.joinDescription()
        await host.foreground.joinStartTask()
        await host.backgroundTasks.joinAll()
        host.backgroundTasks.resetTasks()
    }
}

extension AppController: MaintenanceHost {
    var hasUnsavedHomeRequests: Bool {
        !homeController.homeModel.unsavedInputs.isEmpty
    }

}

extension AppController {
    func requestCompleteErasure() {
        maintenance.requestCompleteErasure()
    }
}

extension AppController {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        maintenance.requestTermination(sender)
    }

    func unsavedRequestQuitAlert() -> NSAlert {
        MaintenanceCoordinator.unsavedRequestQuitAlert()
    }
}

extension AppController {
    @objc func handleWipeDataRequested() {
        maintenance.requestCompleteErasure()
    }
}
