import AppKit

@MainActor
final class MaintenanceCoordinator {
    private enum Operation { case termination, erasure }

    private weak var host: AppController?
    private var owner: Operation?
    private(set) var terminationPrepared = false
    private(set) var isErasureInProgress = false
    private var pendingConfirmation: NotchConfirmation?

    var isIdle: Bool { owner == nil && !terminationPrepared }
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

    init(host: AppController) {
        self.host = host
    }

    func requestTermination(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPrepared else { return .terminateNow }
        guard acquire(.termination) else {
            host?.sessionStatus = conflictMessage()
            sender.reply(toApplicationShouldTerminate: false)
            return .terminateLater
        }
        host?.subsystems.backgroundTasks.closeControls()
        host?.subsystems.guideCoordinator.prepareForTermination()
        Task { @MainActor [self] in
            var showRecovery = false
            defer {
                self.release(.termination)
                if showRecovery { self.host?.subsystems.homeController.openHome() }
            }
            guard let host else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            do {
                try await self.prepareForTermination()
                try await host.subsystems.workers.shutdown()
                await host.subsystems.mcp.stop()
                await self.joinAfterWorkerShutdown()
                guard await self.confirmQuitDiscardingUnsavedRequests() else {
                    host.subsystems.backgroundTasks.reopenControls()
                    host.sessionStatus = "Perry stayed open. Recover your requests before quitting."
                    showRecovery = true
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                self.terminationPrepared = true
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                host.subsystems.backgroundTasks.reopenControls()
                host.sessionStatus = "I couldn’t stop my work safely."
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    func requestCompleteErasure() {
        guard pendingConfirmation == nil else { return }
        guard owner == nil else {
            host?.sessionStatus = conflictMessage()
            return
        }
        let confirmation = CompleteErasurePrompt.makeConfirmation()
        pendingConfirmation = confirmation
        Task { @MainActor [self] in
            defer { if pendingConfirmation === confirmation { pendingConfirmation = nil } }
#if DEBUG
            let confirmed = debugSkipEraseConfirmation ? true : await confirmation.confirm()
#else
            let confirmed = await confirmation.confirm()
#endif
            guard confirmed else { return }
            guard acquire(.erasure) else {
                host?.sessionStatus = conflictMessage()
                return
            }
            host?.subsystems.backgroundTasks.closeControls()
            host?.subsystems.guideCoordinator.stopClickObservation()
            await performCompleteErasure(operation: .erasure)
        }
    }

    func cancelConfirmation() {
        pendingConfirmation?.cancel()
    }

    private func acquire(_ operation: Operation) -> Bool {
        guard owner == nil, let host else { return false }
        owner = operation
        host.subsystems.mcp.suspend()
        host.subsystems.agentCoordinator.closeAdmission()
        host.subsystems.brain.closeAdmission()
        host.subsystems.homeController.closeAdmission()
        host.subsystems.notchPresence.suspend()
        host.hidePanel()
        return true
    }

    private func release(_ operation: Operation) {
        guard owner == operation else { return }
        owner = nil
        guard !terminationPrepared, let host else { return }
        host.subsystems.agentCoordinator.reopenAdmission()
        host.subsystems.brain.reopenAdmission()
        host.subsystems.homeController.reopenAdmission()
        host.subsystems.notchPresence.resume()
        host.subsystems.mcp.resume()
        host.subsystems.customConnectors.connectAll()
    }

    private func conflictMessage() -> String {
        switch owner {
        case .termination:
            return "I’m already getting ready to quit."
        case .erasure:
            return "I’m finishing a data erase."
        case nil:
            return "I’m already stopping my work."
        }
    }

    static func unsavedRequestQuitConfirmation() -> NotchConfirmation {
        NotchConfirmation(
            title: "Quit with unsaved requests?",
            detail: "Some requests haven’t been saved. Keep Perry open to copy them or try saving again. Quitting will discard this text.",
            destructiveTitle: "Quit without saving",
            cancelTitle: "Keep Perry open"
        )
    }

    private func confirmQuitDiscardingUnsavedRequests() async -> Bool {
        guard let host, host.hasUnsavedHomeRequests else { return true }
#if DEBUG
        if let debugUnsavedQuitDecision { return debugUnsavedQuitDecision() }
#endif
        let confirmation = Self.unsavedRequestQuitConfirmation()
        pendingConfirmation = confirmation
        defer { if pendingConfirmation === confirmation { pendingConfirmation = nil } }
        return await confirmation.confirm()
    }

    private func performCompleteErasure(operation: Operation) async {
        guard operation == .erasure,
              owner == operation,
              !isErasureInProgress else { return }
        isErasureInProgress = true
        host?.subsystems.backgroundTasks.closeControls()
        host?.subsystems.guideCoordinator.stopClickObservation()
        defer {
            isErasureInProgress = false
            host?.subsystems.backgroundTasks.reopenControls()
            release(operation)
        }
        host?.subsystems.oauthCoordinator.cancelAuthorization()
        guard let host else { return }
        do {
#if DEBUG
            if let barrier = debugMaintenanceBarrier {
                try await barrier()
            }
#endif
            try await pauseOwnedBackgroundTasksForWorkerStop()
            let report = try await host.subsystems.workers.withWorkersStopped { @MainActor [self] in
                await self.stopWorkForErasure()
                let report = await host.subsystems.completeErasure.erase()
                host.subsystems.brain.reloadPreferences()
                await host.subsystems.homeController.reloadAfterErasure()
                host.subsystems.suggestionController.reloadCards()
                return report
            }
            host.subsystems.voice.speak(report.summary)
        } catch {
            host.sessionStatus = "I couldn’t stop my work before erasing data."
        }
    }

    private func pauseOwnedBackgroundTasksForWorkerStop() async throws {
        guard let host else { return }
        try await host.subsystems.backgroundTasks.pauseAllOwnedForWorkerStop()
        await host.subsystems.foreground.cancelActiveSupervisor()
    }

    private func prepareForTermination() async throws {
        guard let host else { return }
        host.subsystems.backgroundTasks.closeControls()
        await host.subsystems.brain.stopSetup()
        host.subsystems.talkSession.cancelAsk()
        host.subsystems.talkSession.cancel()
        await host.subsystems.talkSession.joinInputSaves()
        host.subsystems.notchStatus.hide()
        host.subsystems.notchPresence.stop()
        host.subsystems.perryScheduler?.stop()
        host.subsystems.suggestionController.stop()
        host.subsystems.customConnectors.disconnectAll()
        host.subsystems.routineLibrary.stop()
        host.subsystems.guideCoordinator.stopClickObservation()
        try await pauseOwnedBackgroundTasksForWorkerStop()
        host.subsystems.voice.cancelInput()
        host.subsystems.foreground.cancelStartTask()
        host.subsystems.guideCoordinator.prepareForTermination()
        host.subsystems.spatial.cancelDescription()
    }

    private func joinAfterWorkerShutdown() async {
        guard let host else { return }
        await host.subsystems.guideCoordinator.joinAfterWorkerShutdown()
        await host.subsystems.agentCoordinator.joinAll()
        await host.subsystems.perryScheduler?.joinAll()
        await host.subsystems.suggestionController.joinAll()
        await host.subsystems.homeController.joinAll()
        await host.subsystems.voice.joinInputWork()
        await host.subsystems.spatial.joinDescription()
        await host.subsystems.foreground.joinStartTask()
        await host.subsystems.backgroundTasks.joinAll()
    }

    private func stopWorkForErasure() async {
        guard let host else { return }
        await host.subsystems.mcp.discard()
        await host.subsystems.brain.stopSetup()
        host.subsystems.talkSession.resetConversation()
        host.subsystems.talkSession.cancelAsk()
        host.subsystems.talkSession.cancel()
        await host.subsystems.talkSession.joinInputSaves()
        host.subsystems.notchStatus.hide()
        host.subsystems.notchPresence.stop()
        host.subsystems.perryScheduler?.stop()
        host.subsystems.suggestionController.stop()
        host.subsystems.customConnectors.forgetAll()
        host.subsystems.routineLibrary.stop()
        await host.subsystems.guideCoordinator.stopForErasure()
        await host.subsystems.agentCoordinator.joinAll()
        await host.subsystems.perryScheduler?.joinAll()
        await host.subsystems.suggestionController.joinAll()
        await host.subsystems.homeController.joinAll()
        host.subsystems.spatial.stopMonitoring()
        host.subsystems.foreground.cancelStartTask()
        await host.subsystems.foreground.cancelActiveSupervisor()
        host.subsystems.backgroundTasks.cancelAllOwned()
        await host.subsystems.voice.joinInputWork()
        host.subsystems.spatial.cancelDescription()
        await host.subsystems.spatial.joinDescription()
        await host.subsystems.foreground.joinStartTask()
        await host.subsystems.backgroundTasks.joinAll()
        host.subsystems.backgroundTasks.resetTasks()
    }
}

extension AppController {
    var hasUnsavedHomeRequests: Bool {
        !subsystems.homeController.homeModel.unsavedInputs.isEmpty
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

    func applicationWillTerminate(_ notification: Notification) {
        if GrantMonitor.reopensOnQuit { GrantMonitor.reopenAfterQuit() }
    }

    func unsavedRequestQuitConfirmation() -> NotchConfirmation {
        MaintenanceCoordinator.unsavedRequestQuitConfirmation()
    }

    func cancelNotchConfirmations() {
        maintenance.cancelConfirmation()
    }
}

extension AppController {
    @objc func handleWipeDataRequested() {
        maintenance.requestCompleteErasure()
    }
}
