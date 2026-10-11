import AppKit
import Combine
import UniformTypeIdentifiers
import SwiftUI
import PerryBrain
import PerryCore
import PerryOverlay
import PerryCapture
import PerryGuide
import PerryRuntimes

/// Owns the live session: hotkey → overlay + panel, Guide/Do flows, intent
/// cards, notifications, memory. Everything the PRD's Session Orchestrator
/// implies, bound to real UI.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, ObservableObject {


    private var hotkey: HotkeyController?
    let overlayState = PerryCursorState()
    let brain = BrainController()
    let foregroundWorkerLease = ForegroundWorkerLease()

    lazy var toolHost = AppToolHost.make(
        overlayState: overlayState,
        workers: workers,
        lease: foregroundWorkerLease,
        supportDirectory: storageDirectory,
        integrationBackend: integrationBackend,
        perryStore: perryStore,
        openSettings: { [weak self] in self?.openSettings(tab: $0) }
    )

    /// The shared Perry registry — agent tools, the scheduler, and Home's
    /// sidebar all read the same directory.
    private lazy var perryStore: PerryStore? = storageDirectory.map {
        PerryStore(directory: $0.appendingPathComponent("perrys", isDirectory: true))
    }

    /// The integration tool backend, shared with the morning researcher.
    private lazy var integrationBackend = AppIntegrationBackend(
        client: integrationClient,
        oauth: oauthCoordinator,
        permissionStore: remoteIntegrationPermissions
    )

    /// Phase 9: morning suggestion researcher over connected apps.
    lazy var suggestionController: SuggestionController = {
        let controller = SuggestionController(
            coordinator: agentCoordinator,
            backend: integrationBackend,
            isBusy: { [weak self] in self?.foreground.supervisorActive ?? false }
        )
        controller.onSuggestionsChanged = { [weak self] cards in
            self?.homeController.updateSuggestions(cards)
        }
        return controller
    }()

    /// Phase 9: fires scheduled Perrys into the agent loop and publishes the
    /// Perry list for Home's sidebar.
    lazy var perryScheduler: PerrySchedulerController? = {
        guard let perryStore else { return nil }
        let scheduler = PerrySchedulerController(
            store: perryStore,
            coordinator: agentCoordinator,
            isBusy: { [weak self] in self?.foreground.supervisorActive ?? false }
        )
        scheduler.onPerrysChanged = { [weak self] perrys in
            self?.homeController.updatePerrys(perrys)
        }
        return scheduler
    }()

    lazy var mcp = MCPSocketLifecycle(
        makeSocket: { [unowned self] directory in
            PerryMCPSocket(host: toolHost, directory: directory, workers: workers, workerLease: foregroundWorkerLease)
        },
        mayStart: { [unowned self] in maintenance.isIdle },
        reportFailure: { [unowned self] in sessionStatus = $0 }
    )
    private lazy var maintenance = MaintenanceCoordinator(host: self)
    private lazy var overlaySampleLog: PerformanceSampleLog? = {
        try? PerformanceSampleLog.shared.get()
    }()
    lazy var overlayManager: OverlayWindowManager = {
        let manager = OverlayWindowManager()
        manager.onSample = { [weak self] metricID, unit, value in
            guard let log = self?.overlaySampleLog else { return }
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
    private lazy var statusMenu = StatusMenuController(host: self)
    private lazy var sessionPanel = SessionPanelPresenter { [unowned self] in
#if DEBUG
        NSHostingView(rootView: PerryDebugTextScale(arguments: ProcessInfo.processInfo.arguments).apply(
            to: CompactConversationView(controller: self)
        ))
#else
        NSHostingView(rootView: CompactConversationView(controller: self))
#endif
    }
    private let intentCards = IntentCardPresenter()
    private var guideOverlay: GuideOverlayPresenter { GuideOverlayPresenter(overlayState: overlayState) }
    private lazy var updateNoticeController = UpdateNoticeController(
        onPresent: { [weak self] in self?.showWhatsNew() },
        onSpeak: { [weak self] text in self?.voice.speak(text) }
    )
    let workers = CuaWorkerService()
    private var manifestRefresher: CuaCapabilityManifest.Refresher?
    lazy var spatial = SpatialSelectionController(
        overlayState: overlayState,
        workers: workers,
        targetHint: { [unowned self] in await probe.currentTargetHint() },
        speak: { [unowned self] in voice.deliverVoiceReply($0) },
        setStatus: { [unowned self] in sessionStatus = $0 }
    )
    private lazy var demoFlow = DemoFlowController(host: self)
    var demoDirector: DemoDirector { demoFlow.director }

    /// Whether open-ended Do goals route through `AgentCoordinator`/`AgentLoop`.
    /// Production always does; the DEBUG harness init defaults to the typed
    /// plan path so fixtures stay deterministic without a provider.
    private let foregroundUsesAgentRunner: Bool
    private var storageDirectory: URL? {
#if DEBUG
        return debugSeams.storageDirectory ?? Self.supportDirectory
#else
        return Self.supportDirectory
#endif
    }
    private lazy var activityLog = ActivityLog(storageDirectory: storageDirectory)
    private lazy var memoryStore = MemoryStore(storageDirectory: storageDirectory)
    private lazy var transcriptStore = TranscriptStore(directory: storageDirectory)
    private let notifier: any AppNotificationClient
#if DEBUG
    private let debugSeams: DebugLaunchSeams
#endif
    private let debugFinalizationPersistenceBarrier: (@Sendable () async -> Void)?
    private lazy var guideBridge = GuideSessionBridge(host: self)
#if DEBUG
    lazy var guideCoordinator = GuideSessionCoordinator(
        sessionController: sessionController,
        workers: workers,
        transcriptStore: transcriptStore,
        memoryStore: memoryStore,
        storageDirectory: storageDirectory,
        output: guideBridge,
        context: guideBridge,
        fullGuideCaptureLoader: debugSeams.fullGuideCaptureLoader,
        fullGuideContinuationBarrier: debugSeams.fullGuideContinuationBarrier,
        fullGuidePlanner: debugSeams.fullGuidePlanner,
        guidePlannerProvider: { [weak self] guide in
            guard let self else { return nil }
            return self.debugSeams.guidePlanner ?? self.brain.makeGuidePlanner(storageDirectory: self.storageDirectory) { [weak self] provider, request in
                guard let self else { throw CancellationError() }
                return try await self.agentCoordinator.prepareGuideRequest(
                    threadID: guide.threadID, runID: guide.id, provider: provider, request: request
                )
            }
        },
        executionOwner: agentCoordinator
    )
#else
    lazy var guideCoordinator = GuideSessionCoordinator(
        sessionController: sessionController,
        workers: workers,
        transcriptStore: transcriptStore,
        memoryStore: memoryStore,
        storageDirectory: storageDirectory,
        output: guideBridge,
        context: guideBridge,
        guidePlannerProvider: { [weak self] guide in
            guard let self else { return nil }
            return self.brain.makeGuidePlanner(storageDirectory: self.storageDirectory) { [weak self] provider, request in
                guard let self else { throw CancellationError() }
                return try await self.agentCoordinator.prepareGuideRequest(
                    threadID: guide.threadID, runID: guide.id, provider: provider, request: request
                )
            }
        },
        executionOwner: agentCoordinator
    )
#endif
    lazy var askController = AskSessionController(
        sessionController: sessionController,
        workers: workers,
        overlayState: overlayState,
        output: guideBridge,
        context: guideBridge,
        runner: .init(accept: { [unowned self] in homeController.acceptInput($0, threadID: $1) }, run: { [unowned self] input, observation in
            homeController.runSpokenTurn(
                input,
                spatial: .init(observation: observation, bindings: [], skill: talkSkillLibrary.promptContext(for: observation.snapshot.appBundleID)),
                coordinator: agentCoordinator
            )
        })
    )
    private lazy var talkCapture = TalkObservationCapture(
        workers: workers,
        targetHint: { [unowned self] in self.guideBridge.guideTargetHint() },
        appBundleID: { [unowned self] in self.guideBridge.guideAppBundleID(for: $0) }
    )
    private lazy var talkSkillLibrary = AppSkillLibrary(storageDirectory: storageDirectory)
    private var talkSessionStarted = false
    lazy var talkSession = TalkSession(
        sessionController: sessionController,
        overlayState: overlayState,
        output: guideBridge,
        services: TalkSession.Services(
            makeInput: {
#if DEBUG
                if let lab = TalkLabInput.makeInput(arguments: ProcessInfo.processInfo.arguments) {
                    return lab
                }
#endif
                return SFSpeechInput()
            },
            output: SharedTalkOutput(voice: voice),
            capture: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.talkCapture.capture()
            },
            acceptInput: { [unowned self] in homeController.acceptInput($0, threadID: $1, contextKey: $2) },
            targetHint: { [unowned self] in self.guideBridge.guideTargetHint() },
            run: { [unowned self] input, spatial in
                homeController.runSpokenTurn(input, spatial: spatial, coordinator: agentCoordinator)
            },
            waitForConversation: { [weak self] threadID in
                await self?.agentCoordinator.waitForCompletion(threadID: threadID)
            },
            guide: { [weak self] input, spatial, full in
                guard let self else { return }
                let id = input.threadID
                self.homeController.homeModel.sidebarSelection = .thread(id)
                self.homeController.homeModel.conversationTargets[id] = spatial.target
                self.guideCoordinator.startGuiding(goal: input.request.text, threadID: id, targetHint: spatial.target, full: full, waitingInput: input.request)
            },
            warm: { [weak self] in
                guard let self, let decision = try? await brain.route(RouteRequirement(capabilities: [.vision, .streaming], tier: .fast)), !Task.isCancelled else { return }
                await decision.provider.warm()
            },
            skill: { [weak self] observation in
                self?.talkSkillLibrary.promptContext(for: observation.snapshot.appBundleID)
            }
        )
    )
    private lazy var modifierHoldMonitor = ModifierHoldMonitor(
        onHoldStart: { [weak self] in
            guard self?.maintenance.isUnderMaintenance != true else { return }
            self?.probe.pinInvocationTarget()
            self?.talkSessionStarted = true
            self?.talkSession.keyDown()
        },
        onHoldCommit: { [weak self] in self?.talkSession.holdCommitted() },
        onHoldEnd: { [weak self] in self?.talkSession.keyUp() },
        onHoldCancel: { [weak self] in self?.talkSession.holdCancelled() },
        onComposer: { [weak self] in self?.toggleSession() }
    )
    lazy var voice = VoiceController(
        overlayState: overlayState,
        workers: workers,
        notifier: notifier,
        supportDirectory: { [weak self] in self?.storageDirectory },
        hooks: VoiceController.Hooks(
            setStatus: { [weak self] status in self?.sessionStatus = status },
            setTranscriptPreview: { [weak self] text in self?.transcriptPreview = text },
            dispatch: { [weak self] text in self?.dispatch(commandText: text) },
            wake: { [weak self] in self?.wake() },
            sessionIsIdle: { [weak self] in self?.isIdle ?? false },
            refreshStatusItem: { [weak self] in self?.statusMenu.refreshIndicator() },
            guideSpeechFinished: { [weak self] identity in self?.guideCoordinator.handleSpeechFinished(identity: identity) }
        )
    )
    let oauthCoordinator = OAuthCoordinator()
    private let remoteIntegrationPermissions = RemoteIntegrationPermissionStore()
    private lazy var integrationClient = RemoteIntegrationClient(permissionStore: remoteIntegrationPermissions)
    lazy var integrationConnections = IntegrationConnections(
        oauth: oauthCoordinator, client: integrationClient, permissions: remoteIntegrationPermissions
    )
    private lazy var remoteIntegrationExecutor = RemoteIntegrationActionRuntime(
        client: integrationClient,
        permissionStore: remoteIntegrationPermissions
    )
    private lazy var executionFinalizer = ExecutionFinalizer(
        transcriptStore: transcriptStore,
        memoryStore: memoryStore,
        notifier: notifier,
        beforeTranscriptAppend: debugFinalizationPersistenceBarrier
    )
    lazy var runtimes: RuntimeCatalog = {
#if DEBUG
        return RuntimeCatalog(
            setStatus: { [weak self] status in self?.sessionStatus = status },
            inventoryLoader: debugSeams.runtimeInventoryLoader
        )
#else
        return RuntimeCatalog(setStatus: { [weak self] status in self?.sessionStatus = status })
#endif
    }()
    lazy var probe: EnvironmentProbe = {
#if DEBUG
        return EnvironmentProbe(
            workers: workers,
            memoryStore: memoryStore,
            oauthCoordinator: oauthCoordinator,
            remoteIntegrationPermissions: remoteIntegrationPermissions,
            spatialSelection: { [weak self] in self?.spatial.selection },
            storageDirectory: { [weak self] in self?.storageDirectory },
            permissionSnapshotLoader: debugSeams.permissionSnapshotLoader,
            cuaHealthLoader: debugSeams.cuaHealthLoader,
            screenContextLoader: debugSeams.screenContextLoader
        )
#else
        return EnvironmentProbe(
            workers: workers,
            memoryStore: memoryStore,
            oauthCoordinator: oauthCoordinator,
            remoteIntegrationPermissions: remoteIntegrationPermissions,
            spatialSelection: { [weak self] in self?.spatial.selection },
            storageDirectory: { [weak self] in self?.storageDirectory }
        )
#endif
    }()
    lazy var foreground: ForegroundTaskController = {
        let hooks = ForegroundTaskController.Hooks(
            setStatus: { [weak self] status in self?.sessionStatus = status },
            setTranscriptPreview: { [weak self] text in self?.transcriptPreview = text },
            isErasureInProgress: { [weak self] in self?.maintenance.isErasureInProgress ?? false },
            requestOnboarding: { [weak self] in self?.runOnboarding(force: true) },
            hidePanel: { [weak self] in self?.hidePanel() },
            dismissIntentCard: { [weak self] in self?.intentCards.dismiss() },
            stopSpatialMonitoring: { [weak self] in self?.spatial.stopMonitoring() },
            stopGuideObservation: { [weak self] in self?.guideCoordinator.stopClickObservation() },
            makeConfirmer: { [weak self] in self?.makeConfirmer() ?? InteractiveConfirmer(controller: nil) }
        )
#if DEBUG
        let controller = ForegroundTaskController(
            sessionController: sessionController,
            workers: workers,
            probe: probe,
            runtimes: runtimes,
            voice: voice,
            remoteIntegrationExecutor: remoteIntegrationExecutor,
            activityLog: activityLog,
            executionFinalizer: executionFinalizer,
            transcriptStore: transcriptStore,
            overlayState: overlayState,
            hooks: hooks,
            finalizationBarrier: debugSeams.finalizationBarrier,
            confirmer: debugSeams.confirmer,
            askUser: debugSeams.askUser,
            typedVerifier: debugSeams.typedVerifier,
            workspaceCoordinator: backgroundTaskCoordinator
        )
#else
        let controller = ForegroundTaskController(
            sessionController: sessionController,
            workers: workers,
            probe: probe,
            runtimes: runtimes,
            voice: voice,
            remoteIntegrationExecutor: remoteIntegrationExecutor,
            activityLog: activityLog,
            executionFinalizer: executionFinalizer,
            transcriptStore: transcriptStore,
            overlayState: overlayState,
            workspaceCoordinator: backgroundTaskCoordinator,
            hooks: hooks
        )
#endif
        // Open-ended Do goals route through the agent loop; its tools run on
        // the session's claimed worker, not a competing background one.
        // Test harnesses opt out (`usesAgentRunner: false`) to keep the typed
        // plan path deterministic.
        controller.agentCoordinator = foregroundUsesAgentRunner ? agentCoordinator : nil
        controller.workerLease = foregroundWorkerLease
        return controller
    }()
    private lazy var backgroundTaskCoordinator = TaskCoordinator(storageDirectory: storageDirectory)
    private lazy var backgroundTaskRunner = ResumableTaskRunner(
        coordinator: backgroundTaskCoordinator,
        notifier: notifier,
        activityLog: activityLog
    )
    lazy var notchStatus = NotchStatusController()
    private lazy var homeThreadStore = ThreadStore(
        directory: (storageDirectory ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Threads", isDirectory: true)
    )
    private lazy var toolConsent = ToolConsentStore(directory: Self.supportDirectory)
    lazy var agentCoordinator = AgentCoordinator(
        provider: { [unowned self] requirement in
            try await self.brain.route(requirement).provider
        },
        host: toolHost, threads: homeThreadStore, consent: toolConsent,
        perrys: perryStore,
        workers: workers, workerLease: foregroundWorkerLease,
        memoryContext: { [memoryStore] in
            let config = await memoryStore.currentConfiguration()
            return (config.enabled, await memoryStore.promptContext(appBundleID: nil))
        }
    )
    lazy var homeController: HomeController = {
        let controller = HomeController()
        controller.threadStore = homeThreadStore
        controller.captureTarget = { [weak self] in self?.probe.presentationTarget() }
        controller.answerProvider = { [weak self] input, target, onPartial in
            guard let self else { return .failed("Perry is shutting down.") }
            let threadID = input.threadID
            let prompt = input.request.text
            switch GuideIntentParser.parse(prompt) {
            case .guide:
                return await self.runHomeGuide(input: input, target: target, full: false, onPartial: onPartial)
            case .showEverything:
                return await self.runHomeGuide(input: input, target: target, full: true, onPartial: onPartial)
            default: break
            }
            var text = ""
            var finish: AgentFinish = .interrupted
            for await event in agentCoordinator.run(threadID: threadID, goal: prompt, runID: input.request.id, target: target, waitingInputID: input.request.id) {
                if case .textDelta(let delta) = event {
                    text += delta
                    onPartial(text)
                }
                if case .finished(let outcome) = event { finish = outcome }
            }
            if finish == .completed { self.onboarding.noteTalkTurnCompleted() }
            return finish
        }
        controller.onStop = { [weak self] id in self?.agentCoordinator.stop(threadID: id) }
        agentRunningObservation = controller.bindWorkingThreads(agentCoordinator.$runningThreads)
        controller.perryListProvider = { [weak self] in
            await self?.perryStore?.list() ?? []
        }
        controller.suggestionController = suggestionController
        controller.routineListProvider = { [weak self] in
            self?.routineLibrary.routines() ?? []
        }
        controller.onRoutineRun = { [weak self] routine in
            self?.routineLibrary.run(routine)
        }
        controller.onRoutineRemove = { [weak self] routine in
            self?.routineLibrary.remove(routine)
        }
        controller.configure(deps: HomeModel.Deps(
            controller: self,
            brain: brain,
            transcriptStore: transcriptStore,
            activityLog: activityLog,
            undoableEntryIDs: { [backgroundTasks] in
                await backgroundTasks.reloadRecords()
                return Set(backgroundTasks.records.compactMap { record -> UUID? in
                    guard !backgroundTasks.undoableDescriptions(for: record).isEmpty else { return nil }
                    if case .executable(let plan) = record.plan { return plan.planID }
                    return UUID(uuidString: record.id.rawValue)
                })
            },
            backgroundTasks: backgroundTasks,
            runtimes: runtimes,
            fileRoots: (storageDirectory.map {
                [$0.appendingPathComponent("PracticeSandbox", isDirectory: true),
                 $0.appendingPathComponent("Files", isDirectory: true)]
            } ?? [])
        ))
        return controller
    }()
    private var lastBackgroundCount = 0
    private var lastAwaitingApprovalCount = 0
    lazy var routineLibrary = RoutineLibraryController(
        store: RoutineStore(storageDirectory: storageDirectory),
        workers: workers,
        context: guideBridge,
        setStatus: { [weak self] status in self?.sessionStatus = status },
        speak: { [weak self] text in self?.voice.speak(text) },
        runRoutine: { [weak self] routine, parameters in self?.foreground.startRoutine(routine, parameters: parameters) },
        onRecordingChanged: { [weak self] recording in
            self?.notchStatus.update(
                isRecording: recording,
                backgroundCount: self?.lastBackgroundCount ?? 0,
                awaitingApproval: self?.lastAwaitingApprovalCount ?? 0
            )
            self?.updateHomePeek(isRecording: recording)
        },
        providerCompleter: { [weak self] in
            guard let brain = self?.brain else { return nil }
            return { prompt in try await brain.completeText(prompt) }
        }
    )
    private lazy var backgroundTaskContextStore = BackgroundTaskContextStore(storageDirectory: storageDirectory)
    lazy var backgroundTasks: BackgroundTaskController = {
        let hooks = BackgroundTaskController.Hooks(
            setStatus: { [weak self] status in self?.sessionStatus = status },
            isErasureInProgress: { [weak self] in self?.maintenance.isErasureInProgress ?? false },
            requestOnboarding: { [weak self] in self?.runOnboarding(force: true) },
            statusCountsChanged: { [weak self] total, active, awaiting in
                self?.statusMenu.setBackgroundTaskCount(total)
                self?.lastBackgroundCount = active
                self?.lastAwaitingApprovalCount = awaiting
                self?.notchStatus.update(
                    isRecording: self?.routineLibrary.isRecording ?? false,
                    backgroundCount: active,
                    awaitingApproval: awaiting
                )
                self?.updateHomePeek(isRecording: self?.routineLibrary.isRecording ?? false)
            }
        )
#if DEBUG
        return BackgroundTaskController(
            workers: workers,
            coordinator: backgroundTaskCoordinator,
            runner: backgroundTaskRunner,
            contextStore: backgroundTaskContextStore,
            transcriptStore: transcriptStore,
            notifier: notifier,
            runtimes: runtimes,
            probe: probe,
            remoteIntegrationExecutor: remoteIntegrationExecutor,
            storageDirectory: { [weak self] in self?.debugSeams.storageDirectory },
            hooks: hooks
        )
#else
        return BackgroundTaskController(
            workers: workers,
            coordinator: backgroundTaskCoordinator,
            runner: backgroundTaskRunner,
            contextStore: backgroundTaskContextStore,
            transcriptStore: transcriptStore,
            notifier: notifier,
            runtimes: runtimes,
            probe: probe,
            remoteIntegrationExecutor: remoteIntegrationExecutor,
            storageDirectory: { nil },
            hooks: hooks
        )
#endif
    }()
    private lazy var erasurePaths = PerryErasurePaths(supportDirectory: storageDirectory)
    lazy var completeErasure = CompleteErasureCoordinator(
        erasers: PerryLiveErasureErasers.make(
            paths: erasurePaths,
            taskCoordinator: backgroundTaskCoordinator,
            backgroundTaskContextStore: backgroundTaskContextStore,
            activityLog: activityLog,
            transcriptStore: transcriptStore,
            memoryStore: memoryStore
        ),
        ownedDataSweeper: PerryOwnedRootSweeper(
            roots: erasurePaths.completeErasureRoots
        )
    )
    private lazy var onboarding = OnboardingCoordinator(
        overlayState: overlayState,
        makeSpeech: { [unowned self] in SharedTalkOutput(voice: voice) },
        home: { [unowned self] in homeController },
        talkSession: { [unowned self] in talkSession },
        preferOnDeviceBrain: { [unowned self] in brain.preferOnDeviceModelIfUnchosen() }
    )
    private var persistenceTasks: [UUID: Task<Void, Never>] = [:]
#if DEBUG
    var debugUnsavedQuitDecision: (() -> Bool)? {
        get { maintenance.debugUnsavedQuitDecision }
        set { maintenance.debugUnsavedQuitDecision = newValue }
    }
#endif
    @Published private(set) var sessionStatus = "Press ⌥⌘P when you want Perry."
    @Published private(set) var transcriptPreview = ""
    private let sessionController: SessionController
    private var sessionStateObservation: AnyCancellable?
    private var runtimeChoicesObservation: AnyCancellable?
    private var agentRunningObservation: AnyCancellable?

    override init() {
#if DEBUG
        debugSeams = .launch(arguments: ProcessInfo.processInfo.arguments)
#endif
        debugFinalizationPersistenceBarrier = nil
        foregroundUsesAgentRunner = true
        let notifier = SystemNotifier()
        self.notifier = notifier
        sessionController = SessionController()
        super.init()
        observeSessionState()
    }

    init(sessionController: SessionController) {
#if DEBUG
        debugSeams = DebugLaunchSeams(guidePlanner: AXGuidePlanner())
#endif
        debugFinalizationPersistenceBarrier = nil
        foregroundUsesAgentRunner = false
        let notifier = SystemNotifier()
        self.notifier = notifier
        self.sessionController = sessionController
        super.init()
        observeSessionState()
    }

#if DEBUG
    init(
        debugStorageDirectory: URL,
        sessionController: SessionController? = nil,
        taskCoordinator: TaskCoordinator? = nil,
        runtimeInventoryLoader: RuntimeCatalog.InventoryLoader? = nil,
        permissionSnapshotLoader: EnvironmentProbe.PermissionSnapshotLoader? = nil,
        cuaHealthLoader: EnvironmentProbe.CuaHealthLoader? = nil,
        fullGuideCaptureLoader: FullGuideCaptureLoader? = nil,
        fullGuideContinuationBarrier: FullGuideContinuationBarrier? = nil,
        fullGuidePlanner: FullGuidePlanner? = nil,
        guidePlanner: (any GuidePlanner)? = AXGuidePlanner(),
        finalizationBarrier: FinalizationBarrier? = nil,
        finalizationPersistenceBarrier: FinalizationPersistenceBarrier? = nil,
        screenContextLoader: EnvironmentProbe.ScreenContextLoader? = nil,
        typedVerifier: (any TypedActionVerifier)? = nil,
        notifier: (any AppNotificationClient)? = nil,
        confirmer: (any Confirmer)? = nil,
        askUser: (@Sendable (String, [String]) async throws -> Void)? = nil,
        usesAgentRunner: Bool = false
    ) {
        debugSeams = DebugLaunchSeams(
            storageDirectory: debugStorageDirectory,
            runtimeInventoryLoader: runtimeInventoryLoader,
            permissionSnapshotLoader: permissionSnapshotLoader,
            cuaHealthLoader: cuaHealthLoader,
            screenContextLoader: screenContextLoader,
            fullGuideCaptureLoader: fullGuideCaptureLoader,
            fullGuideContinuationBarrier: fullGuideContinuationBarrier,
            fullGuidePlanner: fullGuidePlanner,
            guidePlanner: guidePlanner,
            finalizationBarrier: finalizationBarrier,
            typedVerifier: typedVerifier,
            confirmer: confirmer,
            askUser: askUser
        )
        debugFinalizationPersistenceBarrier = finalizationPersistenceBarrier
        foregroundUsesAgentRunner = usesAgentRunner
        self.notifier = notifier ?? SystemNotifier()
        self.sessionController = sessionController ?? SessionController()
        super.init()
        observeSessionState()
        if let taskCoordinator {
            self.backgroundTaskCoordinator = taskCoordinator
        }
    }
#endif

#if DEBUG
    func debugSetMaintenanceFixture(
        skipEraseConfirmation: Bool,
        barrier: (@MainActor () async throws -> Void)?
    ) {
        maintenance.debugSetFixture(skipEraseConfirmation: skipEraseConfirmation, barrier: barrier)
    }

    func debugInvokeWipeDataAction() {
        requestCompleteErasure()
    }

    var debugMaintenanceOwnerHeld: Bool {
        maintenance.isUnderMaintenance
    }
#endif

    var isTaskActive: Bool {
        if case .executing = sessionState { return true }
        return false
    }
    var sessionState: SessionState { sessionController.state }
    var taskProgress: Double? {
        guard case .executing(let execution) = sessionState else { return nil }
        return execution.progress
    }

    private var isIdle: Bool {
        if case .idle = sessionState { return true }
        return false
    }

    @discardableResult
    private func transitionSession(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return true
        } catch {
            sessionStatus = "Perry stopped because its session state changed unexpectedly."
            return false
        }
    }

    private func observeSessionState() {
        runtimeChoicesObservation = runtimes.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        sessionStateObservation = sessionController.$state.sink { [weak self] state in
            guard let self else { return }
            self.foreground.handleSessionState(state)
            if self.talkSessionStarted, !state.isTalkingSession {
                self.talkSession.cancel()
            }
            self.onboarding.noteSessionTransition(from: self.sessionController.state, to: state)
            // Last answer feeds the Home peek's preview line.
            if case .asking(let ask) = state, let text = ask.answerText {
                self.homeController.noteAnswer(text)
            }
            if case .talking(let talk) = state, let text = talk.answerText {
                self.homeController.noteAnswer(text)
            }
            self.objectWillChange.send()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
    }

    nonisolated static var supportDirectory: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Perry", isDirectory: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        homeController.openHome()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // A companion that gets terminated mid-setup loses the user's trust
        // (HeyClicky lost first-run setups to this). Opt out explicitly.
        ProcessInfo.processInfo.disableAutomaticTermination(
            "Perry is a session-ready companion"
        )
#if DEBUG
        let debugSurface = PerryDebugLaunchSurface(arguments: ProcessInfo.processInfo.arguments)
        if debugSurface == .backgroundTasksStorageError {
            guard debugSeams.storageDirectory != nil else { return }
            DispatchQueue.main.async { [weak self] in
                self?.showDebugBackgroundTasksStorageError()
            }
            return
        }
#endif
        if let support = storageDirectory {
            do {
                try FileManager.default.createDirectory(at: support.appendingPathComponent("workspace", isDirectory: true), withIntermediateDirectories: true)
            } catch {
                homeController.homeModel.storageError = "Couldn’t prepare Perry’s file workspace. \(error.localizedDescription)"
            }
        }
        notifier.configure(
            onApprove: { [weak self] taskID, actionID, revision in
                self?.backgroundTasks.approve(taskID, expectedActionID: actionID, expectedRevision: revision)
            },
            onDeny: { [weak self] taskID, revision in
                self?.backgroundTasks.deny(taskID, expectedRevision: revision)
            },
            onOpen: { [weak self] in
                self?.showBackgroundTasks()
            }
        )
        ensureSupportDirectory()
        statusMenu.install()
        installHotkey()
        voice.startInputListeners()
        modifierHoldMonitor.start()
        if let supportDirectory = AppController.supportDirectory {
            let refresher = CuaCapabilityManifest.Refresher(
                directory: supportDirectory.appendingPathComponent("CuaDriver", isDirectory: true),
                hostBundleID: Bundle.main.bundleIdentifier ?? "dev.perry.Perry"
            )
            refresher.start()
            manifestRefresher = refresher
        }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--perry-talk-drill") {
            installTalkDrillTrigger()
        }
#endif
        DispatchQueue.main.async { [weak self] in self?.warmSessionSurfaces() }
        homeController.start()
        perryScheduler?.start()
        suggestionController.start()
        if let dir = storageDirectory, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            mcp.startAfterLaunch(directory: dir)
        }
#if DEBUG
        if debugSurface == nil {
            onboarding.runIfNeeded()
        }
        if debugSurface == .settings {
            DispatchQueue.main.async { [weak self] in
                self?.showSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
        } else if debugSurface == .onboarding {
            DispatchQueue.main.async { [weak self] in
                self?.onboarding.runDenied()
            }
        } else if debugSurface == .session {
            DispatchQueue.main.async { [weak self] in
                self?.showPanel()
            }
        } else if debugSurface == .activity {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.foreground.debugShowActivityFixture()
            }
        } else if debugSurface == .guideControls {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.guideCoordinator.debugShowGuideControlsFixture()
            }
        } else if debugSurface == .history {
            DispatchQueue.main.async { [weak self] in
                self?.debugShowHistoryFixture()
            }
        } else if debugSurface == .prototypes {
            DispatchQueue.main.async {
                DebugPrototypeWindow.show()
            }
        } else if debugSurface == .cursors {
            DispatchQueue.main.async {
                DebugCursorGalleryWindow.show()
            }
        } else if debugSurface == .intentCard {
            DispatchQueue.main.async {
                IntentCardWindow(card: PerryDebugLaunchSurface.intentCardFixture, allowsStepThrough: true) { _ in }.show()
            }
        } else if debugSurface == .notch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.notchStatus.update(isRecording: true, backgroundCount: 2, awaitingApproval: 1)
            }
        } else if debugSurface == .backgroundTasksStorageError {
            DispatchQueue.main.async { [weak self] in
                self?.showBackgroundTasks()
            }
        }
        if let fixture = DebugStateFixture(arguments: ProcessInfo.processInfo.arguments) {
            DispatchQueue.main.async { [weak self] in
                self?.applyDebugStateFixture(fixture)
            }
        }
#else
        onboarding.runIfNeeded()
#endif
        updateNoticeController.start()
        SoundPlayer.warmUp()
        voice.refreshWakeWordListener()
        Task { @MainActor [weak self] in
            await self?.backgroundTasks.recoverInterruptedAndStartQueued()
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let health = await workers.health()
            if !health.ready {
                sessionStatus = health.summary
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWipeDataRequested),
            name: .perryWipeDataRequested,
            object: nil
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        maintenance.requestTermination(sender)
    }

    func unsavedRequestQuitAlert() -> NSAlert {
        MaintenanceCoordinator.unsavedRequestQuitAlert()
    }

    @objc private func handleWipeDataRequested() {
        requestCompleteErasure()
    }

    private func ensureSupportDirectory() {
        guard let directory = Self.supportDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let codexRuntimeHome = RuntimeCatalog.codexRuntimeHome {
                try FileManager.default.createDirectory(at: codexRuntimeHome, withIntermediateDirectories: true)
            }
        } catch {
            sessionStatus = "Perry could not prepare its local data directory."
        }
    }

    // MARK: Wake / dismiss

    private func installHotkey() {
        let shortcut = WakeShortcut(rawValue: PerryPreferences.wakeShortcut) ?? .optionCommandP
        do {
            hotkey = try HotkeyController(modifiers: shortcut.modifiers, keyCode: shortcut.keyCode) { [weak self] in
                Task { @MainActor in self?.toggleSession() }
            }
        } catch {
            hotkey = nil
            sessionStatus = "Perry could not register \(shortcut.title). Choose another wake shortcut in Settings."
        }
    }

    func toggleSession() {
        PerfMark.mark("invoke.keydown")
        if isIdle {
            wake()
        } else {
            dismiss()
        }
    }

    func wake() {
        guard isIdle, transitionSession({ try sessionController.wake() }) else { return }
        voice.refreshWakeWordListener()
        sessionStatus = "Listening for a request."
        transcriptPreview = ""
        spatial.clearSelection()
        probe.pinInvocationTarget()
        PerfMark.mark("wake.pinned")
        overlayState.voiceState = .idle
        overlayState.taskBubbleText = "Circle a window with ⌥⌘ and drag, or type a request."
        overlayState.circleSelectSnappedRect = nil
        overlayState.circleSelectSnapLabel = nil
        overlayManager.showOverlay(onScreens: NSScreen.screens, state: overlayState)
        PerfMark.mark("wake.overlay")
        spatial.startMonitoring()
        showPanel()
        SoundPlayer.play(.wake)
    }

    func dismiss() {
        if guideCoordinator.dismissIfActive() { return }
        if sessionController.requestDismissal() == .stopExecution {
            sessionStatus = "Stopping safely…"
            voice.cancelInput()
            intentCards.dismiss()
            Task { await self.foreground.cancelActiveSupervisor() }
            hidePanel()
            return
        }
        foreground.cancelStartTask()
        if case .invoking(let invocation) = sessionState {
            foreground.cancelInvocationIfCurrent(invocation.id)
        }
        sessionStatus = "Ready when you are."
        probe.clearInvocationTarget()
        askController.cancel()
        guideCoordinator.stopClickObservation()
        guideCoordinator.cancelPendingDemoInputs()
        spatial.stopMonitoring()
        spatial.releaseWaiter()
        voice.cancelInput()
        intentCards.dismiss()
        Task { await self.foreground.cancelActiveSupervisor() }
        clearSessionSurfaces()
    }

    /// Takes every session mark off the overlay, hides the overlay and panel,
    /// and lets the wake word listen again.
    func clearSessionSurfaces() {
        guideOverlay.clearAll()
        overlayManager.fadeOutAndHideOverlay()
        hidePanel()
        voice.refreshWakeWordListener()
    }

    // MARK: Status item

    /// System sleep settles an active run at a step boundary and hands
    /// control to the user — after wake, Continue replans against whatever
    /// the screen became rather than trusting pre-sleep observations.
    @objc private func handleSystemSleep() {
        foreground.takeOver()
    }

    /// Onboarding's post-demo offer: starts a Watch & Learn recording once
    /// onboarding has finished — never a required step.
    func startDemonstrationRecording() {
        guard !routineLibrary.isRecording else { return }
        routineLibrary.toggleRecording()
    }

    /// Mirrors notch-pill status into the Home peek (Phase 5): the pill says
    /// *that* something is running; the peek says *what* — a live step line
    /// per active agent.
    private func updateHomePeek(isRecording: Bool) {
        var lines: [String] = []
        for record in backgroundTasks.records where !record.isTerminal {
            if case .executable(let plan) = record.plan, !plan.actions.isEmpty {
                let step = min(record.checkpoint.nextStepIndex + 1, plan.actions.count)
                lines.append("\(record.goal) — step \(step) of \(plan.actions.count)")
            } else {
                lines.append(record.goal)
            }
        }
        if lines.isEmpty && lastBackgroundCount > 0 {
            lines.append(lastBackgroundCount == 1 ? "1 background task" : "\(lastBackgroundCount) background tasks")
        }
        homeController.updateStatus(
            isRecording: isRecording,
            agentLines: lines,
            unreadCount: lastAwaitingApprovalCount
        )
    }

#if DEBUG
    func runFailureDrill(_ drill: FailureDrill) {
        switch drill {
        case .routeFlip:
            voice.speak("The audio route drill is speaking now.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.voice.debugSimulateAudioRouteChange("simulated AirPods")
            }
        case .microphoneWedge:
            voice.debugSimulateDictationFailure()
        case .mutedOutput:
            let message = "This reply is from the muted-output recovery drill."
            voice.speak(message)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.voice.copyReplyToClipboard(
                    message,
                    status: "Muted-output drill passed; the reply is on your clipboard."
                )
            }
        case .runtimeMissing:
            runOnboarding(force: true)
            voice.speak("The runtime precheck drill stopped here honestly. Install Codex or Claude Code, then try again.")
        }
    }
#endif

    func openSettings(tab: SettingsTab) {
        PerryPreferences.settingsTab = tab.rawValue
        showSettings()
    }

    func currentMemoryConfiguration() async -> MemoryConfiguration {
        await memoryStore.currentConfiguration()
    }

    func setMemoryEnabled(_ enabled: Bool) async {
        guard !maintenance.isErasureInProgress else { return }
        let current = await memoryStore.currentConfiguration()
        await memoryStore.setConfiguration(
            MemoryConfiguration(enabled: enabled, categoryToggles: current.categoryToggles)
        )
    }

    func setMemoryCategoryEnabled(_ category: MemoryRecord.Category, enabled: Bool) async {
        guard !maintenance.isErasureInProgress else { return }
        let current = await memoryStore.currentConfiguration()
        var toggles = current.categoryToggles
        toggles[category] = enabled
        await memoryStore.setConfiguration(
            MemoryConfiguration(enabled: current.enabled, categoryToggles: toggles)
        )
    }

    func requestCompleteErasure() {
        maintenance.requestCompleteErasure()
    }

    // MARK: Panel (the type/talk surface)

    /// Text the panel seeds into its field — a rehearsal "Edit" answer lands
    /// here with the goal ready to revise and resubmit. Consumed on read.
    @Published var pendingPromptText: String?
    /// Edit answers come from a plan card — the panel must reopen in Do, not
    /// whatever mode the picker was last on.
    var pendingPromptDoMode = false
    /// The background-task menu entry arms the composer's background toggle
    /// so the task is one send away — there is no separate background UI.
    var pendingPromptRunInBackground = false

    func presentPrompt(prefill: String, asTask: Bool = false) {
        pendingPromptDoMode = asTask
        pendingPromptText = prefill
        showPanel()
    }

    private func showPanel() {
        probe.pinInvocationTargetIfNeeded()
        homeController.prepareConversation(target: probe.presentationTarget())
        sessionPanel.show()
    }

    /// Pays the one-time render cost for the session surfaces at launch so a
    /// first invocation only orders already-rendered windows on screen.
    private func warmSessionSurfaces() {
        sessionPanel.warm()
        overlayManager.warmRenderPipeline(state: overlayState)
    }

    func hidePanel() {
        sessionPanel.hide()
    }

    func showBackgroundTasks() {
        runtimes.refreshChoices()
        homeController.openHome(selection: .tasks)
    }

#if DEBUG
    private func showDebugBackgroundTasksStorageError() {
        runtimes.refreshChoices()
        homeController.openHome(selection: .tasks)
    }
#endif

    private func guideConversationID() -> UUID {
        if case .thread(let id) = homeController.homeModel.sidebarSelection,
           !agentCoordinator.runningThreads.contains(id) { return id }
        let id = UUID()
        homeController.homeModel.sidebarSelection = .thread(id)
        return id
    }

    func startGuiding(goal: String) {
        let threadID = guideConversationID()
        guideCoordinator.startGuiding(
            goal: goal, threadID: threadID,
            targetHint: homeController.homeModel.conversationTargets[threadID]
        )
    }

    func ask(question: String) {
        guard !maintenance.isUnderMaintenance else { return }
        askController.submit(question: question)
    }

    func advanceGuide() {
        guideCoordinator.advanceGuide()
    }

    func showEverything(goal: String, targetHint: CuaTargetHint? = nil) async {
        let threadID = guideConversationID()
        if let targetHint { homeController.homeModel.conversationTargets[threadID] = targetHint }
        await guideCoordinator.showEverything(
            goal: goal, threadID: threadID,
            targetHint: homeController.homeModel.conversationTargets[threadID]
        )
    }
    func reloadCuaDriverConfiguration() {
        guard isIdle, !foreground.supervisorActive, !backgroundTasks.hasRunningTasks, !foreground.startIsInFlight else {
            sessionStatus = "Finish active computer-use tasks before changing the Cua driver."
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await workers.reloadConfiguration()
                sessionStatus = "Cua computer-use configuration applied."
            } catch {
                sessionStatus = "Cua computer-use configuration could not be applied: \(error.localizedDescription)"
            }
        }
    }

    /// Verified result text from the last completed live demo — onboarding
    /// ends on this evidence rather than a generic "you're set".
    var demoVerifiedSummary: String? { demoFlow.verifiedSummary }

    func runFlagshipDemo(completion: ((Bool) -> Void)? = nil) {
        demoFlow.run(completion: completion)
    }

    func showWhatsNew() {
        homeController.openHome(selection: .whatsNew)
    }

    private func schedulePersistence(_ operation: @escaping @Sendable () async -> Void) {
        guard !maintenance.isErasureInProgress else { return }
        let id = UUID()
        persistenceTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.persistenceTasks[id] = nil }
            guard !Task.isCancelled, !self.maintenance.isErasureInProgress else { return }
            await operation()
        }
    }

    func showHistory() {
        homeController.openHome(selection: .history)
    }

    func exportActivityLog() {
        Task { @MainActor in
            do {
                let data = try await activityLog.exportData()
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "perry-activity.json"
                panel.allowedContentTypes = [.json]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                sessionStatus = "Activity log exported."
            } catch {
                sessionStatus = "Activity export failed: \(error.localizedDescription)"
            }
        }
    }

    func exportDiagnostics() {
        Task { @MainActor in
            do {
                let activity = await activityLog.snapshot()
                let transcripts = await transcriptStore.snapshot()
                let memoryConfiguration = await memoryStore.currentConfiguration()
                let memoryRecords = await memoryStore.snapshot()
                let data = try DiagnosticsReporter.makeData(
                    activity: activity,
                    transcripts: transcripts,
                    memoryConfiguration: memoryConfiguration,
                    memoryRecords: memoryRecords,
                    permissions: await PerryPermissionSnapshot.probe(),
                    codexBundled: (try? CodexRuntime.bundledLocator()) != nil,
                    claudeInstalled: (try? CLIRuntime.locateExecutable()) != nil,
                    codexLogURL: RuntimeCatalog.codexRuntimeHome?.appendingPathComponent("app-server-stderr.log")
                )
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "perry-diagnostics.json"
                panel.allowedContentTypes = [.json]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                sessionStatus = "Redacted diagnostics exported."
            } catch {
                sessionStatus = "Diagnostics export failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Intent card confirmation

    func requestIntentApproval(id: UUID, card: IntentCard) async -> Bool {
        await presentIntentCard(id: id, card: card, allowsStepThrough: false) == .run
    }

    /// Plan-level card: the same intent card plus a "Step through" choice that
    /// walks the plan one confirmed action at a time.
    func requestPlanDecision(id: UUID, card: IntentCard) async -> PlanDecision {
        await presentIntentCard(id: id, card: card, allowsStepThrough: true)
    }

    private func presentIntentCard(id: UUID, card: IntentCard, allowsStepThrough: Bool) async -> PlanDecision {
        guard !Task.isCancelled, sessionController.approvalIsCurrent(id) else { return .cancel }
        return await intentCards.present(id: id, card: card, allowsStepThrough: allowsStepThrough)
    }

    private func dispatch(commandText: String?) {
        guard let text = commandText, !text.isEmpty else {
            showPanel()
            return
        }
        if case .asking = sessionController.state {
            switch GuideIntentParser.parse(text) {
            case .dismiss:
                dismiss()
            case .guide:
                continueAskInGuide(request: text, full: false)
            case .showEverything:
                continueAskInGuide(request: text, full: true)
            case .doTask, .notAGuideRequest:
                ask(question: text)
            }
            return
        }
        switch GuideIntentParser.parse(text) {
        case .guide(let goal):
            startGuiding(goal: goal)
        case .showEverything(let goal):
            Task { await showEverything(goal: goal) }
        case .doTask(let goal):
            foreground.start(goal: goal)
        case .dismiss:
            dismiss()
        case .notAGuideRequest:
            ask(question: text)
        }
    }

    private func runHomeGuide(
        input: HomeController.AcceptedInput, target: CuaTargetHint?, full: Bool,
        onPartial: @MainActor @Sendable (String) -> Void
    ) async -> AgentFinish {
        guard let task = guideCoordinator.startGuiding(goal: input.request.text, threadID: input.threadID, targetHint: target, full: full, waitingInput: input.request) else {
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
        guard case .asking(let ask) = sessionController.state, !maintenance.isUnderMaintenance else { return }
        let accepted = homeController.acceptInput(request, threadID: ask.threadID ?? UUID())
        let input = accepted.request
        let threadID = accepted.threadID
        sessionController.updateAsk {
            $0.threadID = threadID
            $0.pendingGuideRequest = input
        }
        sessionStatus = "Saving your request while this answer finishes…"
        askController.afterCurrentAnswer(prepare: { [weak self] in
            guard let self else { return false }
            do {
                try await accepted.saved.value
                return !self.maintenance.isUnderMaintenance
            } catch {
                self.homeController.homeModel.storageError = error.localizedDescription
                self.sessionStatus = "Couldn’t save your Guide request. Your text is still here."
                return false
            }
        }) { [weak self] current in
            guard let self, !self.maintenance.isUnderMaintenance,
                  current.pendingGuideRequest?.id == input.id else { return }
            let target = self.homeController.homeModel.conversationTargets[threadID]
            self.dismiss()
            self.homeController.homeModel.sidebarSelection = .thread(threadID)
            self.guideCoordinator.startGuiding(
                goal: input.text, threadID: threadID, targetHint: target, full: full, waitingInput: input
            )
        }
    }

    // MARK: Onboarding

    func runOnboarding(force: Bool) {
        onboarding.run(force: force)
    }

#if DEBUG
    /// Test seam for the dictated-command path — identical to what
    /// VoiceController's dispatch hook delivers after wake word/dictation.
    func debugDispatch(_ text: String) {
        dispatch(commandText: text)
    }

    /// Seeds the History fixture and opens History for the capture lane.
    private func debugShowHistoryFixture() {
        Task { @MainActor in
            for entry in PerryDebugLaunchSurface.historyEntries() {
                await transcriptStore.append(entry)
            }
            showHistory()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Applies a deterministic `DebugStateFixture` — see DebugStateFixtures.swift.
    func applyDebugStateFixture(_ fixture: DebugStateFixture) {
        switch fixture {
        case .permissionDenied:
            onboarding.runDenied()
        case .approvalOrange, .approvalRed:
            guard let card = fixture.intentCard else { return }
            intentCards.showFixture(card)
        default:
            if let state = fixture.sessionState {
                sessionController.debugSet(state)
            }
            if let status = fixture.statusText {
                sessionStatus = status
            }
            showPanel()
        }
    }
#endif

    func updateWakeShortcut(_ shortcut: WakeShortcut) throws {
        if let hotkey {
            try hotkey.update(modifiers: shortcut.modifiers, keyCode: shortcut.keyCode)
        } else {
            hotkey = try HotkeyController(modifiers: shortcut.modifiers, keyCode: shortcut.keyCode) { [weak self] in
                Task { @MainActor in self?.toggleSession() }
            }
        }
        PerryPreferences.wakeShortcut = shortcut.rawValue
        sessionStatus = "Wake shortcut changed to \(shortcut.title)."
    }

    // MARK: Interactive confirmer bridging supervisor → card

    func makeConfirmer() -> Confirmer {
        InteractiveConfirmer(controller: self)
    }

#if DEBUG
    /// Lab drill trigger (`--perry-talk-drill`): the scripts/lab driver posts
    /// `app.perry.talk-drill` distributed notifications with `phase` `down`/`up`.
    /// Each phase feeds ModifierHoldMonitor's `handle` seam — the same entry
    /// point the event tap and fallback monitors call — so the full gesture
    /// state machine, commit threshold, and PerfMarks run for real. Only the
    /// TCC-protected session tap is bypassed.
    private func installTalkDrillTrigger() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.perry.talk-drill"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            switch note.userInfo?["phase"] as? String {
            case "down":
                self.modifierHoldMonitor.handle(timestamp: now, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
                self.modifierHoldMonitor.handle(timestamp: now, control: true, option: true, isFlagsChanged: true, tapDisabled: false)
            case "up":
                self.modifierHoldMonitor.handle(timestamp: now, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
                self.modifierHoldMonitor.handle(timestamp: now, control: false, option: false, isFlagsChanged: true, tapDisabled: false)
            default:
                break
            }
        }
    }
#endif
}

extension AppController: StatusMenuHost {
    var isUpdateAvailable: Bool { updateNoticeController.availability == .available }
    var isNotchStatusEnabled: Bool { notchStatus.isEnabled }
    var isRecordingDemonstration: Bool { routineLibrary.isRecording }

    func speak(_ text: String) { voice.speak(text) }
    func checkForUpdates() { updateNoticeController.checkForUpdates() }
    func toggleDemonstrationRecording() { routineLibrary.toggleRecording() }

    func toggleNotchStatus() -> Bool {
        let enabled = !notchStatus.isEnabled
        notchStatus.setEnabled(enabled)
        if enabled {
            notchStatus.update(
                isRecording: routineLibrary.isRecording,
                backgroundCount: lastBackgroundCount,
                awaitingApproval: lastAwaitingApprovalCount
            )
        }
        return enabled
    }

    func routines() -> [LearnedRoutine] { routineLibrary.routines() }
    func runRoutine(_ routine: LearnedRoutine) { routineLibrary.run(routine) }
    func importRoutine(from url: URL) { routineLibrary.importRoutine(from: url) }
    func exportRoutine(_ routine: LearnedRoutine, to url: URL) { routineLibrary.exportRoutine(routine, to: url) }
    func removeRoutine(_ routine: LearnedRoutine) { routineLibrary.remove(routine) }

    func setWorkspaceRoot(_ url: URL) {
        WorkspaceScope.setRoot(url)
        sessionStatus = "Workspace folder set to \(url.lastPathComponent) — new file tasks stay inside it."
    }

    func showFullGuideForFrontmostWindow() {
        let target = probe.currentTargetHint()
        Task { await showEverything(goal: "walk through the frontmost window", targetHint: target) }
    }

    /// "Run in background" lives on the composer's send action — the menu
    /// item opens that composer in Do mode with the toggle already on.
    func presentBackgroundComposer() {
        pendingPromptRunInBackground = true
        presentPrompt(prefill: "", asTask: true)
    }

    func retryLastTask() { foreground.retry() }
    func runDemo() { demoFlow.director.run() }
    func showSettings() { homeController.openHome(selection: .settings) }

    func toggleMemory() {
        schedulePersistence { [weak self, memoryStore] in
            let current = await memoryStore.currentConfiguration()
            await memoryStore.setConfiguration(
                MemoryConfiguration(enabled: !current.enabled, categoryToggles: current.categoryToggles)
            )
            await self?.statusMenu.refreshMemoryTitle()
        }
    }

#if DEBUG
    func runBrainSmokeTest() {
        brain.smokeTest { [weak self] status in self?.sessionStatus = status }
    }
#endif
}

struct InteractiveConfirmer: Confirmer {
    weak var controller: AppController?

    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool {
        guard let controller = await MainActor.run(body: { controller }) else { return false }
        let card = IntentCard(
            title: "About to \(request.actionSummary)",
            detail: request.reason,
            tier: request.tier,
            targetSummary: request.targetSummary ?? request.actionSummary,
            requiredPhrase: request.requiredText,
            approveLabel: request.actionSummary,
            reversible: request.reversible
        )
        SoundPlayer.play(.receive)
        await MainActor.run { controller.voice.speak(card.spokenLine) }
        return await controller.requestIntentApproval(id: request.id, card: card)
    }

    func requestPlanDecision(_ request: ConfirmationRequest) async -> PlanDecision {
        guard let controller = await MainActor.run(body: { controller }) else { return .cancel }
        let card = IntentCard(
            title: "About to \(request.actionSummary)",
            detail: request.reason,
            tier: request.tier,
            targetSummary: request.targetSummary ?? request.actionSummary,
            requiredPhrase: request.requiredText,
            // The plan card approves the whole rehearsal — the button is the
            // action, not the goal.
            approveLabel: "Run",
            reversible: request.reversible
        )
        SoundPlayer.play(.receive)
        await MainActor.run { controller.voice.speak(card.spokenLine) }
        let decision = await controller.requestPlanDecision(id: request.id, card: card)
        if decision == .edit {
            await controller.presentPrompt(prefill: request.actionSummary, asTask: true)
        }
        return decision
    }
}

extension AppController: GuideBridgeHost {
    var sessionPanelFrame: CGRect? { sessionPanel.frame }
    var intentCardFrame: CGRect? { intentCards.frame }

    func reportGuideStatus(_ status: String) {
        sessionStatus = status
    }
}

extension AppController: DemoFlowHost {
    func wakeForDemo() { wake() }
    func dismissIntentCard() { intentCards.dismiss() }
    func reportDemoStatus(_ status: String) { sessionStatus = status }
    func runOnboardingForDemo() { runOnboarding(force: true) }
    func showDemoReport() { showHistory() }
}

extension AppController: MaintenanceHost {
    var hasUnsavedHomeRequests: Bool {
        !homeController.homeModel.unsavedInputs.isEmpty
    }

    func reportMaintenanceStatus(_ status: String) {
        sessionStatus = status
    }
}
