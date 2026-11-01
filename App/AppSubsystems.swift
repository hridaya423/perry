import AppKit
import Combine
import Foundation
import PerryBrain
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
        brain.toolScopes = toolScopes
        brain.bundledLocal = { [unowned self] in self.localBrain.provider }
        brain.redactionVaults = storageDirectory.map { directory in
            RedactionVaults {
                let profile = MemoryFiles(directory: directory.appendingPathComponent("memory", isDirectory: true)).profileField("Name")
                return [profile].compactMap { $0 } + PronunciationStore(directory: directory).entries().map(\.written)
            }
        }
    }

    let toolScopes = MCPScopeRelay()

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
        locate: self.localBrain.clicker,
        openSettings: { [weak app = app] in app?.openSettings($0) }
    )


    lazy var customConnectors = CustomConnectors(directory: self.storageDirectory, host: self.toolHost)

    lazy var localBrain: LocalBrain = {
        let storage = self.storageDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("Perry", isDirectory: true)
        let local = LocalBrain(engine: LocalBrain.bundledEngine(storage: storage), modelsDirectory: storage.appendingPathComponent("Models", isDirectory: true), benchURL: storage.appendingPathComponent("bench.json"))
        local.startWatchingMemoryPressure()
        return local
    }()

    lazy var perryStore: PerryStore? = self.storageDirectory.map {
        PerryStore(directory: $0.appendingPathComponent("perrys", isDirectory: true))
    }


    lazy var integrationBackend = AppIntegrationBackend(
        client: self.integrationClient,
        oauth: self.oauthCoordinator,
        permissionStore: self.remoteIntegrationPermissions
    )


    lazy var suggestionController: SuggestionController = {
        let controller = SuggestionController(
            coordinator: self.agentCoordinator,
            backend: self.integrationBackend,
            isBusy: { [unowned self] in self.foreground.supervisorActive }
        )
        controller.onSuggestionsChanged = { [unowned self] cards in
            self.homeController.updateSuggestions(cards)
        }
        return controller
    }()


    lazy var perryScheduler: PerrySchedulerController? = {
        guard let perryStore else { return nil }
        let scheduler = PerrySchedulerController(
            store: perryStore,
            coordinator: self.agentCoordinator,
            isBusy: { [unowned self] in self.foreground.supervisorActive }
        )
        scheduler.onPerrysChanged = { [unowned self] perrys in
            self.homeController.updatePerrys(perrys)
        }
        return scheduler
    }()


    lazy var mcp = MCPSocketLifecycle(
        makeSocket: { directory in
            PerryMCPSocket(host: self.toolHost, directory: directory, workers: self.workers, workerLease: self.foregroundWorkerLease)
        },
        mayStart: { [unowned app = app] in app.maintenance.isIdle },
        reportFailure: { [unowned app = app] in app.sessionStatus = $0 },
        scopes: self.toolScopes
    )

    lazy var overlaySampleLog: PerformanceSampleLog? = {
        try? PerformanceSampleLog.shared.get()
    }()

    lazy var overlayManager: OverlayWindowManager = {
        let manager = OverlayWindowManager()
        manager.onSample = { [unowned self] metricID, unit, value in
            guard let log = self.overlaySampleLog else { return }
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

    let workers = ScreenWorkerService()

    lazy var spatial: SpatialSelectionController = SpatialSelectionController(
        overlayState: self.overlayState,
        workers: self.workers,
        targetHint: { [unowned self] in await self.probe.currentTargetHint() },
        speak: { [unowned self] in self.voice.deliverVoiceReply($0) },
        setStatus: { [unowned app = app] in app.sessionStatus = $0 }
    )

    var storageDirectory: URL? {
        app.overrides.storageDirectory ?? AppController.supportDirectory
    }

    lazy var activityLog = ActivityLog(storageDirectory: self.storageDirectory)

    lazy var memoryStore = MemoryStore(storageDirectory: self.storageDirectory)

    lazy var transcriptStore = TranscriptStore(directory: self.storageDirectory)

    lazy var guideCoordinator = GuideSessionCoordinator(
        sessionController: app.sessionController,
        workers: self.workers,
        transcriptStore: self.transcriptStore,
        memoryStore: self.memoryStore,
        output: app.guideBridge,
        context: app.guideBridge,
        fullGuideCaptureLoader: app.overrides.fullGuideCaptureLoader,
        fullGuideContinuationBarrier: app.overrides.fullGuideContinuationBarrier,
        guidePlannerProvider: { [weak app = app] guide in
            guard let app else { return nil }
            return app.overrides.guidePlanner ?? self.brain.makeGuidePlanner(storageDirectory: self.storageDirectory) { [unowned self] provider, request in
                try await self.agentCoordinator.prepareGuideRequest(
                    threadID: guide.threadID, runID: guide.id, provider: provider, request: request
                )
            }
        },
        executionOwner: self.agentCoordinator
    )

    lazy var talkCapture = TalkObservationCapture(
        workers: self.workers,
        targetHint: { [unowned app = app] in app.guideBridge.guideTargetHint() },
        appBundleID: { [unowned app = app] in app.guideBridge.guideAppBundleID(for: $0) }
    )

    lazy var talkSkillLibrary = AppSkillLibrary(storageDirectory: self.storageDirectory)

    lazy var talkSpeechInput: SFSpeechInput = {
        let input = SFSpeechInput()
        input.preferences = { [unowned self] in (try? self.voice.currentDictationPreferences()) ?? .default }
        return input
    }()

    private var realtimeTalkVoiceInstance: RealtimeTalkVoice?
    func realtimeTalkVoice() -> RealtimeTalkVoice? {
        if let realtimeTalkVoiceInstance { return realtimeTalkVoiceInstance }
        guard let built = RealtimeTalkVoice.configured(
            fallbackInput: talkSpeechInput,
            fallbackOutput: talkOutput
        ) else { return nil }
        realtimeTalkVoiceInstance = built
        return built
    }

    lazy var talkOutput = SharedTalkOutput(voice: self.voice)

    lazy var talkSession: TalkSession = {
        app.talkSessionStarted = true
        let session = TalkSession(
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
                    let input: any TalkSpeechInput = self.realtimeTalkVoice()?.input ?? self.talkSpeechInput
                    return input
                },
                output: TalkSpeechOutputRouter(
                    realtime: { self.realtimeTalkVoice()?.output },
                    fallback: self.talkOutput
                ),
                capture: { [unowned self] in try await self.talkCapture.capture() },
                acceptInput: { [unowned self] in self.homeController.acceptInput($0, threadID: $1, contextKey: $2) },
                targetHint: { [unowned app = app] in app.guideBridge.guideTargetHint() },
                run: { [unowned self] input, spatial in
                    self.homeController.runSpokenTurn(input, spatial: spatial, coordinator: self.agentCoordinator)
                },
                waitForConversation: { [unowned self] threadID in
                    await self.agentCoordinator.waitForCompletion(threadID: threadID)
                },
                guide: { [unowned self] input, spatial, full in
                    let id = input.threadID
                    self.homeController.homeModel.sidebarSelection = .thread(id)
                    self.homeController.homeModel.conversationTargets[id] = spatial.target
                    self.guideCoordinator.startGuiding(goal: input.request.text, threadID: id, targetHint: spatial.target, full: full, waitingInput: input.request)
                },
                warm: { [unowned self] in
                    guard let decision = try? await self.brain.route(RouteRequirement(capabilities: [.vision, .streaming], tier: .fast)), !Task.isCancelled else { return }
                    await decision.provider.warm()
                },
                skill: { [unowned self] observation in
                    self.talkSkillLibrary.promptContext(for: observation.snapshot.appBundleID)
                },
                makeClickInput: { [unowned self] onTranscript, onPartial, onLevel, onFailure in
                    let input = DictationController(onTranscript: onTranscript, onPartial: onPartial, onLevel: onLevel, onFailure: onFailure)
                    input.configure((try? self.voice.currentDictationPreferences()) ?? .default)
                    return input
                },
                stop: { [unowned self] threadID in self.agentCoordinator.stop(threadID: threadID) },
                clickOutput: self.talkOutput
            )
        )
        app.conversationVoiceObservation = session.$clickState.removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak app = app] state in app?.presentConversationVoice(state) }
        return session
    }()

    let shortcutCheck = ShortcutCheck()

    lazy var modifierHoldMonitor = ModifierHoldMonitor(
        onHoldStart: { [weak app = app] in
            guard let app, !app.maintenance.isUnderMaintenance else { return }
            if self.talkSession.clickState == .listening {
                self.talkSession.sendNow()
                return
            }
            self.talkSession.cancelClick()
            self.probe.pinInvocationTarget()
            if app.isTaskActive {
                app.modifierHoldIsSteering = true
                self.voice.beginDictation(steering: true)
                return
            }
            self.talkSession.keyDown()
        },
        onHoldCommit: { [weak app = app] in
            guard app?.modifierHoldIsSteering == false else { return }
            self.talkSession.holdCommitted()
        },
        onHoldEnd: { [weak app = app] in
            guard let app else { return }
            if app.modifierHoldIsSteering {
                app.modifierHoldIsSteering = false
                self.voice.finishDictation()
            } else {
                self.talkSession.keyUp()
            }
        },
        onHoldCancel: { [weak app = app] in
            guard let app else { return }
            if app.modifierHoldIsSteering {
                app.modifierHoldIsSteering = false
                self.voice.cancelInput()
            } else {
                self.talkSession.holdCancelled()
            }
        },
        onHoldTap: { [weak app = app] in
            guard let app else { return }
            if app.modifierHoldIsSteering {
                app.modifierHoldIsSteering = false
                self.voice.cancelInput()
            } else if self.talkSession.phase == .listening {
                self.talkSession.holdCancelled()
                self.talkSession.startClick()
            }
        },
        onComposer: { [weak app = app] in app?.toggleSession() }
    )

    lazy var voice = VoiceController(
        overlayState: self.overlayState,
        workers: self.workers,
        notifier: app.notifier,
        supportDirectory: { [unowned self] in self.storageDirectory },
        hooks: VoiceController.Hooks(
            setStatus: { [weak app = app] status in app?.sessionStatus = status },
            setTranscriptPreview: { [weak app = app] text in app?.transcriptPreview = text },
            dispatch: { [weak app = app] text, taskScope in app?.commandRouter.route(commandText: text, voiceTaskScope: taskScope) },
            wake: { [weak app = app] in app?.wake(cue: false) },
            sessionIsIdle: { [weak app = app] in app?.isIdle ?? false },
            wakeListeningChanged: { [unowned self] listening in self.notchStatus.setListeningForWake(listening) },
            executingTaskID: { [weak app = app] in app?.executingTaskID }
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
        beforeTranscriptAppend: app.overrides.finalizationPersistenceBarrier
    )

    lazy var runtimes = RuntimeCatalog(setupLoader: app.overrides.runtimeSetupLoader)

    lazy var probe: EnvironmentProbe = EnvironmentProbe(
        workers: self.workers,
        memoryStore: self.memoryStore,
        oauthCoordinator: self.oauthCoordinator,
        remoteIntegrationPermissions: self.remoteIntegrationPermissions,
        spatialSelection: { [unowned self] in self.spatial.selection },
        storageDirectory: { [unowned self] in self.storageDirectory },
        permissionSnapshotLoader: app.overrides.permissionSnapshotLoader,
        screenHealthLoader: app.overrides.screenHealthLoader,
        screenContextLoader: app.overrides.screenContextLoader
    )

    lazy var foreground: ForegroundTaskController = {
        let hooks = ForegroundTaskController.Hooks(
            setStatus: { [weak app = app] status in app?.sessionStatus = status },
            setTranscriptPreview: { [weak app = app] text in app?.transcriptPreview = text },
            isErasureInProgress: { [weak app = app] in app?.maintenance.isErasureInProgress ?? false },
            requestOnboarding: { [weak app = app] in app?.runOnboarding(force: true) },
            hidePanel: { [weak app = app] in app?.hidePanel() },
            dismissIntentCard: { [weak app = app] in app?.intentCards.dismiss() },
            stopSpatialMonitoring: { [unowned self] in self.spatial.stopMonitoring() },
            stopGuideObservation: { [unowned self] in self.guideCoordinator.stopClickObservation() },
            makeConfirmer: { [weak app = app] in app?.makeConfirmer() ?? InteractiveConfirmer(controller: nil) },
            routineVerified: { [unowned self] id in self.routineLibrary.recordVerifiedRun(id) },
            guiTaskCompleted: { [unowned self] in self.routineOffer.taskFinished(usedGUI: true) }
        )
        return ForegroundTaskController(
            sessionController: app.sessionController,
            workers: self.workers,
            probe: self.probe,
            voice: self.voice,
            remoteIntegrationExecutor: self.remoteIntegrationExecutor,
            activityLog: self.activityLog,
            executionFinalizer: self.executionFinalizer,
            overlayState: self.overlayState,
            workspaceCoordinator: self.backgroundTaskCoordinator,
            hooks: hooks,
            agentCoordinator: self.agentCoordinator,
            workerLease: self.foregroundWorkerLease,
            finalizationBarrier: app.overrides.finalizationBarrier,
            confirmer: app.overrides.confirmer,
            askUser: app.overrides.askUser,
            typedVerifier: app.overrides.typedVerifier
        )
    }()

    lazy var backgroundTaskCoordinator = app.overrides.taskCoordinator ?? TaskCoordinator(storageDirectory: self.storageDirectory)

    lazy var backgroundTaskRunner = ResumableTaskRunner(
        coordinator: self.backgroundTaskCoordinator,
        notifier: app.notifier,
        activityLog: self.activityLog
    )

    lazy var notchStatus: NotchStatusController = {
        let controller = NotchStatusController()
        controller.onOpenConversation = { [weak app = app] in app?.showPanel() }
        return controller
    }()

    lazy var homeThreadStore = ThreadStore(
        directory: (self.storageDirectory ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Threads", isDirectory: true)
    )

    lazy var toolConsent = ToolConsentStore(directory: AppController.supportDirectory)

    lazy var conversationLearner: ConversationLearner = {
        let memory = self.memoryStore
        self.homeController.homeModel.onForgetMemory = { record in Task { _ = await memory.forget(record.id) } }
        return ConversationLearner(
            complete: { [unowned self] in try await self.brain.completeOnDevice($0) },
            threads: self.homeThreadStore, memory: memory,
            remembered: { [unowned self] id, records in self.homeController.homeModel.remembered[id, default: []] += records },
            titled: { [unowned self] in Task { await self.homeController.refreshThreads() } }
        )
    }()

    lazy var agentCoordinator = AgentCoordinator(
        provider: { [unowned app = app] requirement in
            try await self.brain.route(requirement).provider
        },
        host: self.toolHost, threads: self.homeThreadStore, consent: self.toolConsent,
        perrys: self.perryStore,
        workers: self.workers, workerLease: self.foregroundWorkerLease,
        memoryContext: { [memoryStore = self.memoryStore] question in
            let config = await memoryStore.currentConfiguration()
            let profile = AppController.supportDirectory.map {
                MemoryFiles(directory: $0.appendingPathComponent("memory", isDirectory: true)).promptBlock()
            }
            let records = await memoryStore.promptContext(appBundleID: nil, query: question)
            let text = [profile, records].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            return (config.enabled, text.isEmpty ? nil : text)
        },
        promptEnvironment: { [integrationBackend = self.integrationBackend] in
            let permissions = await PerryPermissionSnapshot.probe()
            let apps = (try? await integrationBackend.services()) ?? []
            return PromptEnvironment(
                accessibility: permissions.accessibility,
                screenRecording: permissions.screenRecording.isUsable,
                connectedApps: apps.filter(\.connected).map(\.name)
            )
        },
        onTurnCompleted: { [unowned self] id, question, answer in
            self.conversationLearner.turnCompleted(threadID: id, question: question, answer: answer)
        }
    )

    lazy var notchPresence: NotchPresence = {
        let presence = NotchPresence(home: self.homeController)
        presence.onPreviewConversation = { [weak app = app] in app?.showPeek() }
        presence.previewFrame = { [weak app = app] in app?.sessionPanel.frame }
        presence.onEndPreview = { [weak app = app] in
            let presentation = NotchPresentation.shared
            guard let app, app.sessionPanel.isVisible, app.sessionPanel.expansion.peeking, app.sessionPanel.expansion.peekThread == nil,
                  !(presentation.showsInteraction && (presentation.current?.priority ?? .activity) != .activity) else { return false }
            app.endPeek()
            return true
        }
        presence.onFocusPeek = { [weak app = app] in app?.sessionPanel.focusWithoutActivating() }
        presence.moodObservation = overlayState.$voiceState.combineLatest(overlayState.$buddyState)
            .map { NotchEyeMood(PerryMood(voice: $0, buddy: $1)) }
            .removeDuplicates()
            .sink { [weak presence] in presence?.eyes.setMood($0) }
        presence.onDismissConversation = { [weak app = app] in
            guard let app, app.sessionPanel.isVisible else { return false }
            app.collapseNotch()
            return true
        }
        return presence
    }()

    lazy var homeController: HomeController = {
        let controller = HomeController()
        controller.threadStore = self.homeThreadStore
        controller.captureTarget = { [unowned self] in self.probe.presentationTarget() }
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
            var chunker = SentenceChunker()
            for await event in self.agentCoordinator.run(threadID: threadID, goal: prompt, runID: input.request.id, target: target, waitingInputID: input.request.id) {
                switch event {
                case .textDelta(let delta):
                    text += delta
                    onPartial(text)
                    chunker.feed(delta).forEach(self.voice.enqueueSpeech)
                case .draw(let command): self.overlayState.apply(command)
                case .finished(let outcome): finish = outcome
                default: break
                }
            }
            if finish == .completed {
                if let rest = chunker.finish() { self.voice.enqueueSpeech(rest) }
                app.onboarding.noteTalkTurnCompleted()
            }
            return finish
        }
        controller.onStop = { [unowned self] id in self.agentCoordinator.stop(threadID: id) }
        controller.onOpenConversation = { [weak app = app] in app?.showPanel() }
        app.agentRunningObservation = controller.bindWorkingThreads(self.agentCoordinator.$runningThreads)
        controller.perryListProvider = { [unowned self] in
            await self.perryStore?.list() ?? []
        }
        controller.suggestionController = self.suggestionController
        controller.routineListProvider = { [unowned self] in
            self.routineLibrary.routines()
        }
        controller.onRoutineRun = { [unowned self] routine in
            self.routineLibrary.run(routine)
        }
        controller.onRoutineRemove = { [unowned self] routine in
            self.routineLibrary.remove(routine)
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
            fileRoots: (self.storageDirectory.map { [$0.appendingPathComponent("workspace", isDirectory: true)] } ?? [])
        ))
        return controller
    }()

    lazy var routineLibrary = RoutineLibraryController(
        store: RoutineStore(storageDirectory: self.storageDirectory),
        workers: self.workers,
        context: app.guideBridge,
        setStatus: { [weak app = app] status in app?.sessionStatus = status },
        speak: { [unowned self] text in self.voice.speak(text) },
        runRoutine: { [unowned self] routine, parameters in self.foreground.startRoutine(routine, parameters: parameters) },
        onRecordingChanged: { [weak app = app] recording in
            self.notchStatus.update(
                isRecording: recording,
                backgroundCount: app?.lastBackgroundCount ?? 0,
                awaitingApproval: app?.lastAwaitingApprovalCount ?? 0
            )
        },
        showRing: { [weak self] frame in self?.showRecognizedControlRing(frame) },
        providerCompleter: { [unowned self] in
            { prompt in try await self.brain.completeText(prompt) }
        }
    )

    private let routineOfferID = UUID()

    lazy var routineOffer = RoutineOffer(
        isOnboarding: { [unowned self] in self.homeController.homeModel.onboarding != nil },
        present: { [weak self] in self?.presentRoutineOffer() }
    )

    private func presentRoutineOffer() {
        NotchPresentation.shared.present(id: routineOfferID, priority: .routine, content: RoutineOfferView(
            onShowMe: { [weak self] in
                self?.closeRoutineOffer()
                Task { await self?.routineLibrary.beginRecording() }
            },
            onNotNow: { [weak self] in self?.closeRoutineOffer() }
        ))
    }

    private func closeRoutineOffer() {
        NotchPresentation.shared.remove(routineOfferID)
    }

    private func showRecognizedControlRing(_ frame: AXElementFrame) {
        let rect = AXCoordinateConverter.appKitRect(
            axX: frame.x, axY: frame.y, width: frame.width, height: frame.height,
            primaryScreenMaxY: Double(NSScreen.screens.first?.frame.maxY ?? 0)
        )
        let ring = PerryGuidanceOverlay.ellipse(rect: rect.insetBy(dx: -6, dy: -6), accentHex: "#F59E0B", lineWidth: 3, fillOpacity: 0, duration: 1.2)
        overlayState.visualGuidanceOverlays.append(ring)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.overlayState.visualGuidanceOverlays.removeAll { $0.id == ring.id }
        }
    }

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
                self.notchStatus.update(
                    isRecording: self.routineLibrary.isRecording,
                    backgroundCount: active,
                    awaitingApproval: awaiting
                )
            }
        )
        return BackgroundTaskController(
            workers: self.workers,
            coordinator: self.backgroundTaskCoordinator,
            runner: self.backgroundTaskRunner,
            contextStore: self.backgroundTaskContextStore,
            transcriptStore: self.transcriptStore,
            notifier: app.notifier,
            agentCoordinator: self.agentCoordinator,
            storageDirectory: { [weak app = app] in app?.overrides.storageDirectory },
            hooks: hooks
        )
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
