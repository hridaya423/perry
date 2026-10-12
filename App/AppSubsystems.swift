// AppSubsystems owns Perry's lazy composition graph: every subsystem is built
// here, once, on first access. AppController keeps one-line forwards so existing
// call sites (and the *Host protocol conformances it satisfies) see the same
// names. `app` is unowned — the controller outlives the container it holds.

import AppKit
import Combine
import Foundation
import PerryBrain
import PerryCapture
import PerryCore
import PerryGuide
import PerryOverlay
import PerryRuntimes
import SwiftUI

@MainActor
final class AppSubsystems {
    unowned let app: AppController

    init(app: AppController) {
        self.app = app
    }

    let overlayState = PerryCursorState()

    let brain = BrainController()

    let foregroundWorkerLease = ForegroundWorkerLease()


    lazy var toolHost = AppToolHost.make(
        overlayState: self.overlayState,
        workers: self.workers,
        lease: self.foregroundWorkerLease,
        supportDirectory: self.storageDirectory,
        integrationBackend: self.integrationBackend,
        perryStore: self.perryStore,
        openSettings: { [weak app = app] in app?.openSettings(tab: $0) }
    )


    /// The shared Perry registry — agent tools, the scheduler, and Home's
    /// sidebar all read the same directory.
    lazy var perryStore: PerryStore? = self.storageDirectory.map {
        PerryStore(directory: $0.appendingPathComponent("perrys", isDirectory: true))
    }


    /// The integration tool backend, shared with the morning researcher.
    lazy var integrationBackend = AppIntegrationBackend(
        client: self.integrationClient,
        oauth: self.oauthCoordinator,
        permissionStore: self.remoteIntegrationPermissions
    )


    /// Phase 9: morning suggestion researcher over connected apps.
    lazy var suggestionController: SuggestionController = {
        let controller = SuggestionController(
            coordinator: self.agentCoordinator,
            backend: self.integrationBackend,
            isBusy: { [weak app = app] in app?.foreground.supervisorActive ?? false }
        )
        controller.onSuggestionsChanged = { [weak app = app] cards in
            app?.homeController.updateSuggestions(cards)
        }
        return controller
    }()


    /// Phase 9: fires scheduled Perrys into the agent loop and publishes the
    /// Perry list for Home's sidebar.
    lazy var perryScheduler: PerrySchedulerController? = {
        guard let perryStore else { return nil }
        let scheduler = PerrySchedulerController(
            store: perryStore,
            coordinator: self.agentCoordinator,
            isBusy: { [weak app = app] in app?.foreground.supervisorActive ?? false }
        )
        scheduler.onPerrysChanged = { [weak app = app] perrys in
            app?.homeController.updatePerrys(perrys)
        }
        return scheduler
    }()


    lazy var mcp = MCPSocketLifecycle(
        makeSocket: { [unowned app = app] directory in
            PerryMCPSocket(host: self.toolHost, directory: directory, workers: self.workers, workerLease: self.foregroundWorkerLease)
        },
        mayStart: { [unowned app = app] in app.maintenance.isIdle },
        reportFailure: { [unowned app = app] in app.sessionStatus = $0 }
    )

    lazy var overlaySampleLog: PerformanceSampleLog? = {
        try? PerformanceSampleLog.shared.get()
    }()

    lazy var overlayManager: OverlayWindowManager = {
        let manager = OverlayWindowManager()
        manager.onSample = { [weak app = app] metricID, unit, value in
            guard let log = app?.overlaySampleLog else { return }
            Task {
                try? await log.append(
                    PerformanceSample(
                        metricID: metricID,
                        collector: "overlay",
                        unit: unit,
                        value: value,
                        scenario: "overlay"
                    )
                )
            }
        }
        OverlayPerfProbe.shared.onCursorTrackingDegraded = {
            PerfMark.markDynamic("cursor.follow.fallback")
        }
        return manager
    }()

    let workers = CuaWorkerService()

    lazy var spatial = SpatialSelectionController(
        overlayState: self.overlayState,
        workers: self.workers,
        targetHint: { [unowned app = app] in await self.probe.currentTargetHint() },
        speak: { [unowned app = app] in self.voice.deliverVoiceReply($0) },
        setStatus: { [unowned app = app] in app.sessionStatus = $0 }
    )

    var storageDirectory: URL? {
#if DEBUG
        return app.debugSeams.storageDirectory ?? AppController.supportDirectory
#else
        return AppController.supportDirectory
#endif
    }

    lazy var activityLog = ActivityLog(storageDirectory: self.storageDirectory)

    lazy var memoryStore = MemoryStore(storageDirectory: self.storageDirectory)

    lazy var transcriptStore = TranscriptStore(directory: self.storageDirectory)

#if DEBUG
    lazy var guideCoordinator = GuideSessionCoordinator(
        sessionController: app.sessionController,
        workers: self.workers,
        transcriptStore: self.transcriptStore,
        memoryStore: self.memoryStore,
        storageDirectory: self.storageDirectory,
        output: app.guideBridge,
        context: app.guideBridge,
        fullGuideCaptureLoader: app.debugSeams.fullGuideCaptureLoader,
        fullGuideContinuationBarrier: app.debugSeams.fullGuideContinuationBarrier,
        fullGuidePlanner: app.debugSeams.fullGuidePlanner,
        guidePlannerProvider: { [weak app = app] guide in
            guard let app else { return nil }
            return app.debugSeams.guidePlanner ?? app.brain.makeGuidePlanner(storageDirectory: app.storageDirectory) { [weak app = app] provider, request in
                guard let app else { throw CancellationError() }
                return try await app.agentCoordinator.prepareGuideRequest(
                    threadID: guide.threadID, runID: guide.id, provider: provider, request: request
                )
            }
        },
        executionOwner: self.agentCoordinator
    )
#else
    lazy var guideCoordinator = GuideSessionCoordinator(
        sessionController: app.sessionController,
        workers: self.workers,
        transcriptStore: self.transcriptStore,
        memoryStore: self.memoryStore,
        storageDirectory: self.storageDirectory,
        output: app.guideBridge,
        context: app.guideBridge,
        guidePlannerProvider: { [weak app = app] guide in
            guard let app else { return nil }
            return app.brain.makeGuidePlanner(storageDirectory: app.storageDirectory) { [weak app = app] provider, request in
                guard let app else { throw CancellationError() }
                return try await app.agentCoordinator.prepareGuideRequest(
                    threadID: guide.threadID, runID: guide.id, provider: provider, request: request
                )
            }
        },
        executionOwner: self.agentCoordinator
    )

#endif

    lazy var talkCapture = TalkObservationCapture(
        workers: self.workers,
        targetHint: { [unowned app = app] in app.guideBridge.guideTargetHint() },
        appBundleID: { [unowned app = app] in app.guideBridge.guideAppBundleID(for: $0) }
    )

    lazy var talkSkillLibrary = AppSkillLibrary(storageDirectory: self.storageDirectory)

    lazy var talkSession = TalkSession(
        sessionController: app.sessionController,
        overlayState: self.overlayState,
        output: app.guideBridge,
        services: TalkSession.Services(
            makeInput: {
#if DEBUG
                if let lab = TalkLabInput.makeInput(arguments: ProcessInfo.processInfo.arguments) {
                    return lab
                }
#endif
                return SFSpeechInput()
            },
            output: SharedTalkOutput(voice: self.voice),
            capture: { [weak app = app] in
                guard let app else { throw CancellationError() }
                return try await app.talkCapture.capture()
            },
            acceptInput: { [unowned app = app] in self.homeController.acceptInput($0, threadID: $1, contextKey: $2) },
            targetHint: { [unowned app = app] in app.guideBridge.guideTargetHint() },
            run: { [unowned app = app] input, spatial in
                self.homeController.runSpokenTurn(input, spatial: spatial, coordinator: self.agentCoordinator)
            },
            waitForConversation: { [weak app = app] threadID in
                await app?.agentCoordinator.waitForCompletion(threadID: threadID)
            },
            guide: { [weak app = app] input, spatial, full in
                guard let app else { return }
                let id = input.threadID
                app.homeController.homeModel.sidebarSelection = .thread(id)
                app.homeController.homeModel.conversationTargets[id] = spatial.target
                app.guideCoordinator.startGuiding(goal: input.request.text, threadID: id, targetHint: spatial.target, full: full, waitingInput: input.request)
            },
            warm: { [weak app = app] in
                guard let app, let decision = try? await self.brain.route(RouteRequirement(capabilities: [.vision, .streaming], tier: .fast)), !Task.isCancelled else { return }
                await decision.provider.warm()
            },
            skill: { [weak app = app] observation in
                app?.talkSkillLibrary.promptContext(for: observation.snapshot.appBundleID)
            }
        )
    )

    lazy var modifierHoldMonitor = ModifierHoldMonitor(
        onHoldStart: { [weak app = app] in
            guard app?.maintenance.isUnderMaintenance != true else { return }
            app?.probe.pinInvocationTarget()
            app?.talkSessionStarted = true
            app?.talkSession.keyDown()
        },
        onHoldCommit: { [weak app = app] in app?.talkSession.holdCommitted() },
        onHoldEnd: { [weak app = app] in app?.talkSession.keyUp() },
        onHoldCancel: { [weak app = app] in app?.talkSession.holdCancelled() },
        onComposer: { [weak app = app] in app?.toggleSession() }
    )

    lazy var voice = VoiceController(
        overlayState: self.overlayState,
        workers: self.workers,
        notifier: app.notifier,
        supportDirectory: { [weak app = app] in app?.storageDirectory },
        hooks: VoiceController.Hooks(
            setStatus: { [weak app = app] status in app?.sessionStatus = status },
            setTranscriptPreview: { [weak app = app] text in app?.transcriptPreview = text },
            dispatch: { [weak app = app] text in app?.commandRouter.route(commandText: text) },
            wake: { [weak app = app] in app?.wake() },
            sessionIsIdle: { [weak app = app] in app?.isIdle ?? false },
            refreshStatusItem: { [weak app = app] in app?.statusMenu.refreshIndicator() },
            guideSpeechFinished: { [weak app = app] identity in app?.guideCoordinator.handleSpeechFinished(identity: identity) }
        )
    )

    let oauthCoordinator = OAuthCoordinator()

    let remoteIntegrationPermissions = RemoteIntegrationPermissionStore()

    lazy var integrationClient = RemoteIntegrationClient(permissionStore: self.remoteIntegrationPermissions)

    lazy var integrationConnections = IntegrationConnections(
        oauth: self.oauthCoordinator, client: self.integrationClient, permissions: self.remoteIntegrationPermissions
    )

    lazy var remoteIntegrationExecutor = RemoteIntegrationActionRuntime(
        client: self.integrationClient,
        permissionStore: self.remoteIntegrationPermissions
    )

    lazy var executionFinalizer = ExecutionFinalizer(
        transcriptStore: self.transcriptStore,
        memoryStore: self.memoryStore,
        notifier: app.notifier,
        beforeTranscriptAppend: app.debugFinalizationPersistenceBarrier
    )

    lazy var runtimes: RuntimeCatalog = {
#if DEBUG
        return RuntimeCatalog(
            setStatus: { [weak app = app] status in app?.sessionStatus = status },
            inventoryLoader: app.debugSeams.runtimeInventoryLoader
        )
#else
        return RuntimeCatalog(setStatus: { [weak app = app] status in app?.sessionStatus = status })
#endif
    }()

    lazy var probe: EnvironmentProbe = {
#if DEBUG
        return EnvironmentProbe(
            workers: self.workers,
            memoryStore: self.memoryStore,
            oauthCoordinator: self.oauthCoordinator,
            remoteIntegrationPermissions: self.remoteIntegrationPermissions,
            spatialSelection: { [weak app = app] in app?.spatial.selection },
            storageDirectory: { [weak app = app] in app?.storageDirectory },
            permissionSnapshotLoader: app.debugSeams.permissionSnapshotLoader,
            cuaHealthLoader: app.debugSeams.cuaHealthLoader,
            screenContextLoader: app.debugSeams.screenContextLoader
        )
#else
        return EnvironmentProbe(
            workers: self.workers,
            memoryStore: self.memoryStore,
            oauthCoordinator: self.oauthCoordinator,
            remoteIntegrationPermissions: self.remoteIntegrationPermissions,
            spatialSelection: { [weak app = app] in app?.spatial.selection },
            storageDirectory: { [weak app = app] in app?.storageDirectory }
        )
#endif
    }()

    lazy var foreground: ForegroundTaskController = {
        let hooks = ForegroundTaskController.Hooks(
            setStatus: { [weak app = app] status in app?.sessionStatus = status },
            setTranscriptPreview: { [weak app = app] text in app?.transcriptPreview = text },
            isErasureInProgress: { [weak app = app] in app?.maintenance.isErasureInProgress ?? false },
            requestOnboarding: { [weak app = app] in app?.runOnboarding(force: true) },
            hidePanel: { [weak app = app] in app?.hidePanel() },
            dismissIntentCard: { [weak app = app] in app?.intentCards.dismiss() },
            stopSpatialMonitoring: { [weak app = app] in app?.spatial.stopMonitoring() },
            stopGuideObservation: { [weak app = app] in app?.guideCoordinator.stopClickObservation() },
            makeConfirmer: { [weak app = app] in app?.makeConfirmer() ?? InteractiveConfirmer(controller: nil) }
        )
#if DEBUG
        let controller = ForegroundTaskController(
            sessionController: app.sessionController,
            workers: self.workers,
            probe: self.probe,
            voice: self.voice,
            remoteIntegrationExecutor: self.remoteIntegrationExecutor,
            activityLog: self.activityLog,
            executionFinalizer: self.executionFinalizer,
            transcriptStore: self.transcriptStore,
            overlayState: self.overlayState,
            hooks: hooks,
            finalizationBarrier: app.debugSeams.finalizationBarrier,
            confirmer: app.debugSeams.confirmer,
            askUser: app.debugSeams.askUser,
            typedVerifier: app.debugSeams.typedVerifier,
            workspaceCoordinator: self.backgroundTaskCoordinator
        )
#else
        let controller = ForegroundTaskController(
            sessionController: app.sessionController,
            workers: self.workers,
            probe: self.probe,
            voice: self.voice,
            remoteIntegrationExecutor: self.remoteIntegrationExecutor,
            activityLog: self.activityLog,
            executionFinalizer: self.executionFinalizer,
            transcriptStore: self.transcriptStore,
            overlayState: self.overlayState,
            workspaceCoordinator: self.backgroundTaskCoordinator,
            hooks: hooks
        )
#endif
        // Open-ended Do goals route through the agent loop; its tools run on
        // the session's claimed worker, not a competing background one.
        controller.agentCoordinator = agentCoordinator
        controller.workerLease = self.foregroundWorkerLease
        return controller
    }()

    lazy var backgroundTaskCoordinator = TaskCoordinator(storageDirectory: self.storageDirectory)

    lazy var backgroundTaskRunner = ResumableTaskRunner(
        coordinator: self.backgroundTaskCoordinator,
        notifier: app.notifier,
        activityLog: self.activityLog
    )

    lazy var notchStatus = NotchStatusController()

    lazy var homeThreadStore = ThreadStore(
        directory: (self.storageDirectory ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Threads", isDirectory: true)
    )

    lazy var toolConsent = ToolConsentStore(directory: AppController.supportDirectory)

    lazy var agentCoordinator = AgentCoordinator(
        provider: { [unowned app = app] requirement in
            try await app.brain.route(requirement).provider
        },
        host: self.toolHost, threads: self.homeThreadStore, consent: self.toolConsent,
        perrys: self.perryStore,
        workers: self.workers, workerLease: self.foregroundWorkerLease,
        memoryContext: { [memoryStore = self.memoryStore] in
            let config = await self.memoryStore.currentConfiguration()
            return (config.enabled, await self.memoryStore.promptContext(appBundleID: nil))
        }
    )

    lazy var homeController: HomeController = {
        let controller = HomeController()
        controller.threadStore = self.homeThreadStore
        controller.captureTarget = { [weak app = app] in app?.probe.presentationTarget() }
        controller.answerProvider = { [weak app = app] input, target, onPartial in
            guard let app else { return .failed("Perry is shutting down.") }
            let threadID = input.threadID
            let prompt = input.request.text
            switch GuideIntentParser.parse(prompt) {
            case .guide:
                return await app.commandRouter.runHomeGuide(input: input, target: target, full: false, onPartial: onPartial)
            case .showEverything:
                return await app.commandRouter.runHomeGuide(input: input, target: target, full: true, onPartial: onPartial)
            default: break
            }
            var text = ""
            var finish: AgentFinish = .interrupted
            for await event in self.agentCoordinator.run(threadID: threadID, goal: prompt, runID: input.request.id, target: target, waitingInputID: input.request.id) {
                if case .textDelta(let delta) = event {
                    text += delta
                    onPartial(text)
                }
                if case .finished(let outcome) = event { finish = outcome }
            }
            if finish == .completed { app.onboarding.noteTalkTurnCompleted() }
            return finish
        }
        controller.onStop = { [weak app = app] id in app?.agentCoordinator.stop(threadID: id) }
        app.agentRunningObservation = controller.bindWorkingThreads(self.agentCoordinator.$runningThreads)
        controller.perryListProvider = { [weak app = app] in
            await app?.perryStore?.list() ?? []
        }
        controller.suggestionController = self.suggestionController
        controller.routineListProvider = { [weak app = app] in
            app?.routineLibrary.routines() ?? []
        }
        controller.onRoutineRun = { [weak app = app] routine in
            app?.routineLibrary.run(routine)
        }
        controller.onRoutineRemove = { [weak app = app] routine in
            app?.routineLibrary.remove(routine)
        }
        controller.configure(deps: HomeModel.Deps(
            controller: app,
            brain: self.brain,
            transcriptStore: self.transcriptStore,
            activityLog: self.activityLog,
            undoableEntryIDs: { [backgroundTasks = self.backgroundTasks] in
                await self.backgroundTasks.reloadRecords()
                return Set(self.backgroundTasks.records.compactMap { record -> UUID? in
                    guard !self.backgroundTasks.undoableDescriptions(for: record).isEmpty else { return nil }
                    if case .executable(let plan) = record.plan { return plan.planID }
                    return UUID(uuidString: record.id.rawValue)
                })
            },
            backgroundTasks: self.backgroundTasks,
            runtimes: self.runtimes,
            fileRoots: (self.storageDirectory.map {
                [$0.appendingPathComponent("PracticeSandbox", isDirectory: true),
                 $0.appendingPathComponent("Files", isDirectory: true)]
            } ?? [])
        ))
        return controller
    }()

    lazy var routineLibrary = RoutineLibraryController(
        store: RoutineStore(storageDirectory: self.storageDirectory),
        workers: self.workers,
        context: app.guideBridge,
        setStatus: { [weak app = app] status in app?.sessionStatus = status },
        speak: { [weak app = app] text in app?.voice.speak(text) },
        runRoutine: { [weak app = app] routine, parameters in app?.foreground.startRoutine(routine, parameters: parameters) },
        onRecordingChanged: { [weak app = app] recording in
            app?.notchStatus.update(
                isRecording: recording,
                backgroundCount: app?.lastBackgroundCount ?? 0,
                awaitingApproval: app?.lastAwaitingApprovalCount ?? 0
            )
            app?.updateHomePeek(isRecording: recording)
        },
        providerCompleter: { [weak app = app] in
            guard let brain = app?.brain else { return nil }
            return { prompt in try await self.brain.completeText(prompt) }
        }
    )

    lazy var backgroundTaskContextStore = BackgroundTaskContextStore(storageDirectory: self.storageDirectory)

    lazy var backgroundTasks: BackgroundTaskController = {
        let hooks = BackgroundTaskController.Hooks(
            setStatus: { [weak app = app] status in app?.sessionStatus = status },
            isErasureInProgress: { [weak app = app] in app?.maintenance.isErasureInProgress ?? false },
            requestOnboarding: { [weak app = app] in app?.runOnboarding(force: true) },
            statusCountsChanged: { [weak app = app] total, active, awaiting in
                app?.statusMenu.setBackgroundTaskCount(total)
                app?.lastBackgroundCount = active
                app?.lastAwaitingApprovalCount = awaiting
                app?.notchStatus.update(
                    isRecording: app?.routineLibrary.isRecording ?? false,
                    backgroundCount: active,
                    awaitingApproval: awaiting
                )
                app?.updateHomePeek(isRecording: app?.routineLibrary.isRecording ?? false)
            }
        )
#if DEBUG
        return BackgroundTaskController(
            workers: self.workers,
            coordinator: self.backgroundTaskCoordinator,
            runner: self.backgroundTaskRunner,
            contextStore: self.backgroundTaskContextStore,
            transcriptStore: self.transcriptStore,
            notifier: app.notifier,
            agentCoordinator: self.agentCoordinator,
            storageDirectory: { [weak app = app] in app?.debugSeams.storageDirectory },
            hooks: hooks
        )
#else
        return BackgroundTaskController(
            workers: self.workers,
            coordinator: self.backgroundTaskCoordinator,
            runner: self.backgroundTaskRunner,
            contextStore: self.backgroundTaskContextStore,
            transcriptStore: self.transcriptStore,
            notifier: app.notifier,
            agentCoordinator: self.agentCoordinator,
            storageDirectory: { nil },
            hooks: hooks
        )
#endif
    }()

    lazy var erasurePaths = PerryErasurePaths(supportDirectory: self.storageDirectory)

    lazy var completeErasure = CompleteErasureCoordinator(
        erasers: PerryLiveErasureErasers.make(
            paths: self.erasurePaths,
            taskCoordinator: self.backgroundTaskCoordinator,
            backgroundTaskContextStore: self.backgroundTaskContextStore,
            activityLog: self.activityLog,
            transcriptStore: self.transcriptStore,
            memoryStore: self.memoryStore
        ),
        ownedDataSweeper: PerryOwnedRootSweeper(
            roots: self.erasurePaths.completeErasureRoots
        )
    )
}
