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

#if DEBUG
enum PerryDebugLaunchSurface: String, Equatable {
    case settings
    case onboarding
    case session
    case activity
    case guideControls = "guide-controls"
    case history
    case prototypes
    case cursors
    case notch
    case intentCard = "intent-card"
    case backgroundTasksStorageError = "background-tasks-storage-error"

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--perry-debug-surface"),
              arguments.indices.contains(index + 1) else { return nil }
        self.init(rawValue: arguments[index + 1])
    }
}
#endif

/// Owns the live session: hotkey → overlay + panel, Guide/Do flows, intent
/// cards, notifications, memory. Everything the PRD's Session Orchestrator
/// implies, bound to real UI.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, ObservableObject {
    private enum MaintenanceOperation: Equatable {
        case termination
        case erasure
    }


    private var hotkey: HotkeyController?
    let overlayState = PerryCursorState()
    let brain = BrainController()
    /// Model→world dispatch. Executors bind the app's real services (Cua
    /// workers, overlay ink, memory, Perrys); package-level executor cores
    /// (file/memory/integration/perry) plug in alongside these.
    /// The active foreground Do run lends its worker to tool executors so
    /// agent calls share the session's app lock instead of colliding with it.
    let foregroundWorkerLease = ForegroundWorkerLease()

    lazy var toolHost: PerryToolHost = {
        PerryToolHost(executors:
            DrawTools(overlayState: overlayState, observations: AgentObservationStore.shared).executors
            + ScreenTools(workers: workers, lease: foregroundWorkerLease, observations: AgentObservationStore.shared).executors
            + UITools(
                workers: workers,
                lease: foregroundWorkerLease,
                observations: AgentObservationStore.shared,
                onActuation: { [weak self] point, label in
                    Task { @MainActor in self?.agentDidAct(at: point, label: label) }
                }
            ).executors
            + BrowserTools(workers: workers, lease: foregroundWorkerLease, observations: AgentObservationStore.shared).executors
            + DocumentTools(workers: workers, lease: foregroundWorkerLease, observations: AgentObservationStore.shared).executors
            + AppTools().executors
            + packageExecutors()
        )
    }()

    /// Package-level executor cores (Phase 7c): workspace files, memory files,
    /// integrations, and Perrys. `files:`/support-dir pieces are skipped when
    /// the support directory is unavailable rather than silently rooted
    /// somewhere else.
    private func packageExecutors() -> [any ToolExecutor] {
        guard let support = storageDirectory else { return [] }
        var executors: [any ToolExecutor] = []
        // LocalWorkspaceFiles requires an existing root — the workspace is
        // created on first launch, empty until an agent writes to it.
        let workspace = support.appendingPathComponent("workspace", isDirectory: true)
        if let files = try? LocalWorkspaceFiles(root: workspace) {
            executors += FileToolExecutors.make(backend: files)
        }
        executors += MemoryToolExecutors.make(
            files: MemoryFiles(directory: support.appendingPathComponent("memory", isDirectory: true))
        )
        executors += IntegrationToolExecutors.make(backend: integrationBackend)
        if let perryStore {
            executors += PerryToolExecutors.make(
                store: perryStore,
                openSettings: { [weak self] page in
                    Task { @MainActor in
                        // perry.settings.open pages → nearest SettingsTab.
                        let tab: SettingsTab = switch page {
                        case "voice": .voice
                        case "apps": .integrations
                        case "memory": .memory
                        case "brain", "perrys": .runtimes
                        case "shortcuts", "about": .general
                        default: .general
                        }
                        self?.openSettings(tab: tab)
                    }
                }
            )
        }
        return executors
    }

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
    private lazy var suggestionController: SuggestionController = {
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
    private lazy var perryScheduler: PerrySchedulerController? = {
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

    /// Ghost cursor for agent work: a Perry cursor tracks each ui.* actuation
    /// point so the user can watch without their real pointer ever moving.
    private static let agentGhostCursorID = UUID(uuidString: "A6E11C7E-0000-4A00-9E00-000000000007")!

    private func agentDidAct(at axPoint: CGPoint, label: String?) {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let screenPoint = CGPoint(x: axPoint.x, y: primaryMaxY - axPoint.y)
        var cursor = overlayState.externalSecondaryCursors.first { $0.id == Self.agentGhostCursorID }
            ?? PerryExternalCursor(id: Self.agentGhostCursorID, screenLocation: screenPoint, caption: nil, accentHex: "#34D399")
        cursor.screenLocation = screenPoint
        cursor.caption = label
        overlayState.externalSecondaryCursors.removeAll { $0.id == Self.agentGhostCursorID }
        overlayState.externalSecondaryCursors.append(cursor)
    }
    private var mcpSocket: PerryMCPSocket?
    private var mcpStartupTask: Task<Void, Never>?
    private lazy var overlaySampleLog: PerformanceSampleLog? = {
        try? PerformanceSampleLog.shared.get()
    }()
    private lazy var overlayManager: OverlayWindowManager = {
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
    private lazy var updateNoticeController = UpdateNoticeController(
        onPresent: { [weak self] in self?.showWhatsNew() },
        onSpeak: { [weak self] text in self?.voice.speak(text) }
    )
    let workers = CuaWorkerService()
    private var manifestRefresher: CuaCapabilityManifest.Refresher?
    private lazy var spatialMonitor = SpatialInputMonitor(
        onPointsChanged: { [weak self] points in self?.handleSpatialPoints(points) },
        onSelection: { [weak self] selection in self?.handleSpatialSelection(selection) },
        onCancel: { [weak self] in self?.cancelSpatialSelection() }
    )
    private lazy var demoDirector = DemoDirector(hooks: DemoDirector.Hooks(
        preflight: { [weak self] in await self?.demoPreflight() ?? DemoPreflightResult(ready: false, failureMessage: "Perry could not run the live demo.") },
        wake: { [weak self] in self?.wake() },
        speak: { [weak self] text in self?.voice.speak(text) },
        waitForSpatialSelection: { [weak self] in await self?.waitForSpatialSelection() },
        cancelPendingInputs: { [weak self] in self?.cancelPendingDemoInputs() },
        describeSpatialSelection: { [weak self] selection in await self?.describeSpatialSelection(selection) ?? false },
        runGuide: { [weak self] goal in await self?.runGuideForDemo(goal: goal) ?? false },
        runDo: { [weak self] goal in await self?.foreground.runForDemo(goal: goal) },
        report: { [weak self] outcome in self?.handleDemoReport(outcome) }
    ))
#if DEBUG
    private let debugStorageDirectory: URL?
#endif
    /// Whether open-ended Do goals route through `AgentCoordinator`/`AgentLoop`.
    /// Production always does; the DEBUG harness init defaults to the typed
    /// plan path so fixtures stay deterministic without a provider.
    private let foregroundUsesAgentRunner: Bool
    private var storageDirectory: URL? {
#if DEBUG
        return debugStorageDirectory ?? Self.supportDirectory
#else
        return Self.supportDirectory
#endif
    }
    private lazy var activityLog = ActivityLog(storageDirectory: storageDirectory)
    private lazy var memoryStore = MemoryStore(storageDirectory: storageDirectory)
    private lazy var transcriptStore = TranscriptStore(directory: storageDirectory)
    private let notifier: any AppNotificationClient
#if DEBUG
    typealias FullGuideCaptureLoader = @MainActor (CuaWorkerHandle, CuaTargetHint?) async throws -> CuaCapturedWindow
    typealias FullGuideContinuationBarrier = @MainActor (UUID) async -> Void
    typealias FullGuidePlanner = @MainActor (String, GuideObservation, GuideContext) async throws -> [GuideStep]
    typealias FinalizationPersistenceBarrier = @Sendable () async -> Void
    private let debugRuntimeInventoryLoader: RuntimeCatalog.InventoryLoader?
    private let debugPermissionSnapshotLoader: EnvironmentProbe.PermissionSnapshotLoader?
    private let debugCuaHealthLoader: EnvironmentProbe.CuaHealthLoader?
    private let debugScreenContextLoader: EnvironmentProbe.ScreenContextLoader?
    private let debugFullGuideCaptureLoader: FullGuideCaptureLoader?
    private let debugFullGuideContinuationBarrier: FullGuideContinuationBarrier?
    private let debugFullGuidePlanner: FullGuidePlanner?
    private let debugGuidePlanner: (any GuidePlanner)?
    private let debugFinalizationBarrier: FinalizationBarrier?
    private let debugTypedVerifier: (any TypedActionVerifier)?
#endif
    private let debugFinalizationPersistenceBarrier: (@Sendable () async -> Void)?
#if DEBUG
    lazy var guideCoordinator = GuideSessionCoordinator(
        sessionController: sessionController,
        workers: workers,
        transcriptStore: transcriptStore,
        memoryStore: memoryStore,
        storageDirectory: storageDirectory,
        output: self,
        context: self,
        fullGuideCaptureLoader: debugFullGuideCaptureLoader,
        fullGuideContinuationBarrier: debugFullGuideContinuationBarrier,
        fullGuidePlanner: debugFullGuidePlanner,
        guidePlannerProvider: { [weak self] guide in
            guard let self else { return nil }
            return self.debugGuidePlanner ?? self.brain.makeGuidePlanner(storageDirectory: self.storageDirectory) { [weak self] provider, request in
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
        output: self,
        context: self,
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
        output: self,
        context: self,
        runner: .init(accept: { [unowned self] in homeController.acceptInput($0, threadID: $1) }, run: { [unowned self] input, observation in
            homeController.runSpokenTurn(
                input,
                spatial: .init(observation: observation, bindings: [], skill: talkSkillLibrary.promptContext(for: observation.snapshot.appBundleID)),
                coordinator: agentCoordinator
            )
        })
    )
    private let talkTargetStore = CuaGuideTargetStore()
    private lazy var talkSkillLibrary = AppSkillLibrary(storageDirectory: storageDirectory)
    private var talkSessionStarted = false
    lazy var talkSession = TalkSession(
        sessionController: sessionController,
        overlayState: overlayState,
        output: self,
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
                return try await self.captureTalkObservation()
            },
            acceptInput: { [unowned self] in homeController.acceptInput($0, threadID: $1, contextKey: $2) },
            targetHint: { [unowned self] in self.guideTargetHint() },
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
            guard self?.maintenanceOwner == nil else { return }
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
    private let oauthCoordinator = OAuthCoordinator()
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
            inventoryLoader: debugRuntimeInventoryLoader
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
            spatialSelection: { [weak self] in self?.activeSpatialSelection },
            storageDirectory: { [weak self] in self?.storageDirectory },
            permissionSnapshotLoader: debugPermissionSnapshotLoader,
            cuaHealthLoader: debugCuaHealthLoader,
            screenContextLoader: debugScreenContextLoader
        )
#else
        return EnvironmentProbe(
            workers: workers,
            memoryStore: memoryStore,
            oauthCoordinator: oauthCoordinator,
            remoteIntegrationPermissions: remoteIntegrationPermissions,
            spatialSelection: { [weak self] in self?.activeSpatialSelection },
            storageDirectory: { [weak self] in self?.storageDirectory }
        )
#endif
    }()
    lazy var foreground: ForegroundTaskController = {
        let hooks = ForegroundTaskController.Hooks(
            setStatus: { [weak self] status in self?.sessionStatus = status },
            setTranscriptPreview: { [weak self] text in self?.transcriptPreview = text },
            isErasureInProgress: { [weak self] in self?.erasureInProgress ?? false },
            requestOnboarding: { [weak self] in self?.runOnboarding(force: true) },
            hidePanel: { [weak self] in self?.hidePanel() },
            dismissIntentCard: { [weak self] in self?.intentCards.dismiss() },
            stopSpatialMonitoring: { [weak self] in self?.spatialMonitor.stop() },
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
            finalizationBarrier: debugFinalizationBarrier,
            confirmer: debugConfirmer,
            askUser: debugAskUser,
            typedVerifier: debugTypedVerifier,
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
    private lazy var notchStatus = NotchStatusController()
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
    private lazy var routineLibrary = RoutineLibraryController(
        store: RoutineStore(storageDirectory: storageDirectory),
        workers: workers,
        context: self,
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
            isErasureInProgress: { [weak self] in self?.erasureInProgress ?? false },
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
            storageDirectory: { [weak self] in self?.debugStorageDirectory },
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
    private lazy var completeErasureCoordinator = CompleteErasureCoordinator(
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
    private var activeSpatialSelection: SpatialSelection?
    private var terminationPrepared = false
    private var maintenanceOwner: MaintenanceOperation?
    private var spatialWaiter: CheckedContinuation<SpatialSelection?, Never>?
    private var spatialWorkerTask: Task<Void, Never>?
    private var persistenceTasks: [UUID: Task<Void, Never>] = [:]
    private var erasureInProgress = false
#if DEBUG
    private var debugMaintenanceBarrier: (@MainActor () async throws -> Void)?
    private var debugSkipEraseConfirmation = false
    var debugUnsavedQuitDecision: (() -> Bool)?
    private let debugConfirmer: (any Confirmer)?
    private let debugAskUser: (@Sendable (String, [String]) async throws -> Void)?
#endif
    @Published private(set) var sessionStatus = "Press ⌥⌘P when you want Perry."
    @Published private(set) var transcriptPreview = ""
    private let sessionController: SessionController
    private var sessionStateObservation: AnyCancellable?
    private var runtimeChoicesObservation: AnyCancellable?
    private var agentRunningObservation: AnyCancellable?

    override init() {
#if DEBUG
        debugStorageDirectory = Self.debugStorageDirectoryFromArguments(ProcessInfo.processInfo.arguments)
        debugRuntimeInventoryLoader = Self.debugRuntimeInventoryLoaderFromArguments(ProcessInfo.processInfo.arguments)
        debugPermissionSnapshotLoader = nil
        debugCuaHealthLoader = nil
        debugScreenContextLoader = nil
        debugFullGuideCaptureLoader = nil
        debugFullGuideContinuationBarrier = nil
        debugFullGuidePlanner = nil
        debugGuidePlanner = nil
        debugFinalizationBarrier = nil
        debugTypedVerifier = nil
        debugConfirmer = nil
        debugAskUser = nil
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
        debugStorageDirectory = nil
        debugRuntimeInventoryLoader = nil
        debugPermissionSnapshotLoader = nil
        debugCuaHealthLoader = nil
        debugScreenContextLoader = nil
        debugFullGuideCaptureLoader = nil
        debugFullGuideContinuationBarrier = nil
        debugFullGuidePlanner = nil
        debugGuidePlanner = AXGuidePlanner()
        debugFinalizationBarrier = nil
        debugTypedVerifier = nil
        debugConfirmer = nil
        debugAskUser = nil
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
        self.debugStorageDirectory = debugStorageDirectory
        self.debugRuntimeInventoryLoader = runtimeInventoryLoader
        self.debugPermissionSnapshotLoader = permissionSnapshotLoader
        self.debugCuaHealthLoader = cuaHealthLoader
        self.debugScreenContextLoader = screenContextLoader
        self.debugFullGuideCaptureLoader = fullGuideCaptureLoader
        self.debugFullGuideContinuationBarrier = fullGuideContinuationBarrier
        self.debugFullGuidePlanner = fullGuidePlanner
        self.debugGuidePlanner = guidePlanner
        self.debugFinalizationBarrier = finalizationBarrier
        self.debugFinalizationPersistenceBarrier = finalizationPersistenceBarrier
        self.debugTypedVerifier = typedVerifier
        self.debugConfirmer = confirmer
        self.debugAskUser = askUser
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
        debugSkipEraseConfirmation = skipEraseConfirmation
        debugMaintenanceBarrier = barrier
    }

    func debugInvokeWipeDataAction() {
        requestCompleteErasure()
    }

    var debugMaintenanceOwnerHeld: Bool {
        maintenanceOwner != nil
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

#if DEBUG
    private static func debugStorageDirectoryFromArguments(_ arguments: [String]) -> URL? {
        guard PerryDebugLaunchSurface(arguments: arguments) == .backgroundTasksStorageError,
              let index = arguments.firstIndex(of: "--perry-debug-storage-directory"),
              arguments.indices.contains(index + 1),
              !arguments[index + 1].isEmpty else { return nil }
        let path = arguments[index + 1]
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// `--perry-debug-runtimes none` reports an inventory with only Automatic +
    /// the planning-only local planner, so UI captures can exercise the
    /// panel's inline no-runtime recovery deterministically.
    private static func debugRuntimeInventoryLoaderFromArguments(
        _ arguments: [String]
    ) -> RuntimeCatalog.InventoryLoader? {
        guard let index = arguments.firstIndex(of: "--perry-debug-runtimes"),
              arguments.indices.contains(index + 1),
              arguments[index + 1] == "none" else { return nil }
        return { workingDirectory in
            try await RuntimeInventoryInspector(
                readDirectProvider: { nil },
                commandLineProviders: []
            ).inspect(workingDirectory: workingDirectory)
        }
    }
#endif


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
            guard debugStorageDirectory != nil else { return }
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
            mcpStartupTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(1))
                    guard let self, self.maintenanceOwner == nil, !self.terminationPrepared else { return }
                    defer { self.mcpStartupTask = nil }
                    let socket = PerryMCPSocket(host: self.toolHost, directory: dir, workers: self.workers, workerLease: self.foregroundWorkerLease)
                    try socket.start()
                    self.mcpSocket = socket
                } catch is CancellationError {
                } catch {
                    self?.sessionStatus = "Perry could not start its tool connection: \(error.localizedDescription)"
                }
            }
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
                let card = IntentCard(
                    title: "Rename 12 screenshots in ~/PerryDemo",
                    detail: "1. Observe Desktop\n2. Select screenshot files\n3. Rename each with its date",
                    tier: .orange,
                    targetSummary: "12 files",
                    approveLabel: "Run",
                    reversible: true
                )
                IntentCardWindow(card: card, allowsStepThrough: true) { _ in }.show()
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
        guard !terminationPrepared else { return .terminateNow }
        guard acquireMaintenance(.termination) else {
            sessionStatus = maintenanceConflictMessage()
            sender.reply(toApplicationShouldTerminate: false)
            return .terminateLater
        }
        runtimes.cancelPendingRefreshes()
        backgroundTasks.closeControls()
        guideCoordinator.prepareForTermination()
        Task { @MainActor [self] in
            var showRecovery = false
            defer {
                self.releaseMaintenance(.termination)
                if showRecovery { self.homeController.openHome() }
            }
            do {
                try await self.prepareForTermination()
                try await self.workers.shutdown()
                await self.mcpStartupTask?.value
                await self.mcpSocket?.stop()
                await self.joinAfterWorkerShutdown()
                guard self.confirmQuitDiscardingUnsavedRequests() else {
                    self.backgroundTasks.reopenControls()
                    self.sessionStatus = "Perry stayed open. Recover your requests before quitting."
                    showRecovery = true
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                self.terminationPrepared = true
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                self.backgroundTasks.reopenControls()
                self.sessionStatus = "Perry could not stop its computer-use workers safely."
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    func unsavedRequestQuitAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit with unsaved requests?"
        alert.informativeText = "Some requests haven’t been saved. Keep Perry open to copy them or try saving again. Quitting will discard this text."
        alert.addButton(withTitle: "Keep Perry open")
        alert.addButton(withTitle: "Quit without saving").hasDestructiveAction = true
        return alert
    }

    private func confirmQuitDiscardingUnsavedRequests() -> Bool {
        guard !homeController.homeModel.unsavedInputs.isEmpty else { return true }
#if DEBUG
        if let debugUnsavedQuitDecision { return debugUnsavedQuitDecision() }
#endif
        return unsavedRequestQuitAlert().runModal() == .alertSecondButtonReturn
    }

    private func acquireMaintenance(_ operation: MaintenanceOperation) -> Bool {
        guard maintenanceOwner == nil else { return false }
        maintenanceOwner = operation
        mcpStartupTask?.cancel()
        mcpSocket?.closeAdmission()
        agentCoordinator.closeAdmission()
        brain.closeAdmission()
        homeController.closeAdmission()
        hidePanel()
        return true
    }

    private func releaseMaintenance(_ operation: MaintenanceOperation) {
        guard maintenanceOwner == operation else { return }
        maintenanceOwner = nil
        if !terminationPrepared {
            agentCoordinator.reopenAdmission()
            brain.reopenAdmission()
            homeController.reopenAdmission()
            if let socket = mcpSocket {
                let previousStartup = mcpStartupTask
                mcpStartupTask = Task { @MainActor [weak self] in
                    await previousStartup?.value
                    await socket.stop()
                    guard let self, !Task.isCancelled, self.maintenanceOwner == nil else { return }
                    defer { self.mcpStartupTask = nil }
                    do {
                        try socket.start()
                    } catch {
                        self.sessionStatus = "Perry could not restart its tool connection: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func maintenanceConflictMessage() -> String {
        switch maintenanceOwner {
        case .termination:
            return "Perry is already preparing to quit."
        case .erasure:
            return "Perry is finishing a data erase."
        case nil:
            return "Perry is already stopping its workers."
        }
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
        activeSpatialSelection = nil
        probe.pinInvocationTarget()
        PerfMark.mark("wake.pinned")
        overlayState.voiceState = .idle
        overlayState.taskBubbleText = "Circle a window with ⌥⌘ and drag, or type a request."
        overlayState.circleSelectSnappedRect = nil
        overlayState.circleSelectSnapLabel = nil
        overlayManager.showOverlay(onScreens: NSScreen.screens, state: overlayState)
        PerfMark.mark("wake.overlay")
        spatialMonitor.start()
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
        spatialMonitor.stop()
        if let spatialWaiter {
            self.spatialWaiter = nil
            spatialWaiter.resume(returning: nil)
        }
        voice.cancelInput()
        intentCards.dismiss()
        Task { await self.foreground.cancelActiveSupervisor() }
        overlayState.voiceState = .idle
        overlayState.taskBubbleText = nil
        overlayState.agentTaskBubbleText = nil
        overlayState.detectedElementScreenLocation = nil
        overlayState.detectedElementDisplayFrame = nil
        overlayState.detectedElementBubbleText = nil
        overlayState.activeControlGlowRect = nil
        overlayState.activeControlGlowLabel = nil
        overlayState.circleSelectSnappedRect = nil
        overlayState.circleSelectSnapLabel = nil
        overlayState.visualGuidanceOverlays = []
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
        guard !erasureInProgress else { return }
        let current = await memoryStore.currentConfiguration()
        await memoryStore.setConfiguration(
            MemoryConfiguration(enabled: enabled, categoryToggles: current.categoryToggles)
        )
    }

    func setMemoryCategoryEnabled(_ category: MemoryRecord.Category, enabled: Bool) async {
        guard !erasureInProgress else { return }
        let current = await memoryStore.currentConfiguration()
        var toggles = current.categoryToggles
        toggles[category] = enabled
        await memoryStore.setConfiguration(
            MemoryConfiguration(enabled: current.enabled, categoryToggles: toggles)
        )
    }

    func requestCompleteErasure() {
#if DEBUG
        guard debugSkipEraseConfirmation || CompleteErasurePrompt.confirm() else { return }
#else
        guard CompleteErasurePrompt.confirm() else { return }
#endif
        guard acquireMaintenance(.erasure) else {
            sessionStatus = maintenanceConflictMessage()
            return
        }
        backgroundTasks.closeControls()
        guideCoordinator.stopClickObservation()
        Task { @MainActor [self] in
            await self.performCompleteErasure(owner: .erasure)
        }
    }

    private func performCompleteErasure(owner: MaintenanceOperation) async {
        guard owner == .erasure,
              maintenanceOwner == owner,
              !erasureInProgress else { return }
        erasureInProgress = true
        backgroundTasks.closeControls()
        guideCoordinator.stopClickObservation()
        defer {
            erasureInProgress = false
            backgroundTasks.reopenControls()
            releaseMaintenance(owner)
        }
        oauthCoordinator.cancelAuthorization()
        do {
#if DEBUG
            if let barrier = debugMaintenanceBarrier {
                try await barrier()
            }
#endif
            try await pauseOwnedBackgroundTasksForWorkerStop()
            let report = try await workers.withWorkersStopped { @MainActor [self] in
                await self.stopWorkForErasure()
                let report = await self.completeErasureCoordinator.erase()
                self.brain.reloadPreferences()
                await self.homeController.reloadAfterErasure()
                self.suggestionController.reloadCards()
                return report
            }
            voice.speak(report.summary)
        } catch {
            sessionStatus = "Perry could not stop its computer-use workers before erasing data."
        }
    }

    private func pauseOwnedBackgroundTasksForWorkerStop() async throws {
        try await backgroundTasks.pauseAllOwnedForWorkerStop()
        await foreground.cancelActiveSupervisor()
    }

    private func prepareForTermination() async throws {
        backgroundTasks.closeControls()
        await brain.stopSetup()
        askController.cancel()
        talkSession.cancel()
        await askController.joinInputSaves()
        notchStatus.hide()
        homeController.stop()
        perryScheduler?.stop()
        suggestionController.stop()
        routineLibrary.stop()
        guideCoordinator.stopClickObservation()
        try await pauseOwnedBackgroundTasksForWorkerStop()
        voice.cancelInput()
        foreground.cancelStartTask()
        guideCoordinator.prepareForTermination()
        spatialWorkerTask?.cancel()
    }

    private func joinAfterWorkerShutdown() async {
        await guideCoordinator.joinAfterWorkerShutdown()
        await agentCoordinator.joinAll()
        await perryScheduler?.joinAll()
        await suggestionController.joinAll()
        await homeController.joinAll()
        await voice.joinInputWork()
        if let spatialWorkerTask {
            await spatialWorkerTask.value
        }
        await foreground.joinStartTask()
        await backgroundTasks.joinAll()
    }

    private func stopWorkForErasure() async {
        await mcpStartupTask?.value
        mcpStartupTask = nil
        await mcpSocket?.stop()
        mcpSocket = nil
        await brain.stopSetup()
        demoDirector.cancel()
        askController.cancel()
        talkSession.cancel()
        await askController.joinInputSaves()
        notchStatus.hide()
        homeController.stop()
        perryScheduler?.stop()
        suggestionController.stop()
        routineLibrary.stop()
        await guideCoordinator.stopForErasure()
        await agentCoordinator.joinAll()
        await perryScheduler?.joinAll()
        await suggestionController.joinAll()
        await homeController.joinAll()
        spatialMonitor.stop()
        foreground.cancelStartTask()
        await foreground.cancelActiveSupervisor()
        backgroundTasks.cancelAllOwned()
        await voice.joinInputWork()
        spatialWorkerTask?.cancel()
        await spatialWorkerTask?.value
        await foreground.joinStartTask()
        await backgroundTasks.joinAll()
        backgroundTasks.resetTasks()
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

    private func hidePanel() {
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
        guard maintenanceOwner == nil else { return }
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
    private func handleSpatialPoints(_ points: [CGPoint]) {
        overlayState.circleSelectLivePoints = points
        if points.isEmpty {
            overlayState.circleSelectSnappedRect = nil
            overlayState.circleSelectSnapLabel = nil
        }
    }

    private func cancelSpatialSelection() {
        spatialWorkerTask?.cancel()
        overlayState.circleSelectLivePoints = []
        overlayState.circleSelectSnappedRect = nil
        overlayState.circleSelectSnapLabel = nil
        activeSpatialSelection = nil
        if let spatialWaiter {
            self.spatialWaiter = nil
            spatialWaiter.resume(returning: nil)
        }
        sessionStatus = "Circle a window with ⌥⌘ and drag."
    }

    private func handleSpatialSelection(_ selection: SpatialSelection) {
        activeSpatialSelection = selection
        overlayState.circleSelectLivePoints = selection.points
        overlayState.circleSelectSnappedRect = selection.rect
        sessionStatus = "Area selected. Tell Perry what to do there."
        let demoIsWaiting = spatialWaiter != nil
        if let spatialWaiter {
            self.spatialWaiter = nil
            spatialWaiter.resume(returning: selection)
        }
        if !demoIsWaiting {
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.spatialWorkerTask = nil }
                _ = await self.describeSpatialSelection(selection)
            }
            spatialWorkerTask = task
        }
    }

    private func describeSpatialSelection(_ selection: SpatialSelection) async -> Bool {
        let snapshot: AXSnapshot?
        do {
            snapshot = try await workers.withWorker(scope: .dictation, resources: []) { worker in
                let capture = try await worker.capture(target: await self.probe.currentTargetHint())
                return capture.accessibilitySnapshotModel
            }
        } catch {
            snapshot = nil
        }
        let label = Self.spatialLabel(for: selection.rect, snapshot: snapshot)
        overlayState.circleSelectSnapLabel = label
            voice.deliverVoiceReply(label == nil ? "I have the area you circled." : "I have \(label!).")
        return snapshot != nil
    }

    private static func spatialLabel(for rect: CGRect, snapshot: AXSnapshot?) -> String? {
        guard let snapshot else { return nil }
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let axRect = CGRect(
            x: rect.minX,
            y: primaryMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        let names = snapshot.actionableElements()
            .filter { element in
                let frame = CGRect(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height)
                return frame.intersects(axRect)
            }
            .prefix(3)
            .compactMap(\.label)
        guard !names.isEmpty else { return snapshot.windowTitle.isEmpty ? nil : snapshot.windowTitle }
        return names.joined(separator: ", ")
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
    var demoVerifiedSummary: String? { demoDirector.lastVerifiedResult }

    func runFlagshipDemo(completion: ((Bool) -> Void)? = nil) {
        guard isIdle else {
            voice.speak("Finish the current session before starting the live demo.")
            completion?(false)
            return
        }
        demoDirector.run(completion: completion)
    }

    private func demoPreflight() async -> DemoPreflightResult {
        let permissions = await probe.permissionSnapshot()
        guard permissions.requiredPermissionsGranted else {
            runOnboarding(force: true)
            return DemoPreflightResult(
                ready: false,
                failureMessage: "I can’t run the live demo until Accessibility and Screen Recording are granted in System Settings."
            )
        }
        let cuaHealth = await probe.cuaHealth()
        guard cuaHealth.ready else {
            return DemoPreflightResult(ready: false, failureMessage: cuaHealth.summary)
        }
        do {
            let inventory = try await runtimes.inspect()
            if !inventory.hasReadyCLIPlanner {
                sessionStatus = "Using Perry's private local planner for the supported demo task."
            }
            return .ready
        } catch is CancellationError {
            return DemoPreflightResult(ready: false, failureMessage: "Runtime inspection was canceled.")
        } catch {
            return DemoPreflightResult(ready: false, failureMessage: "Perry could not inspect the available runtimes. Refresh runtime setup and try again.")
        }
    }


    private func waitForSpatialSelection() async -> SpatialSelection? {
        await withCheckedContinuation { continuation in
            spatialWaiter = continuation
        }
    }

    private func cancelPendingDemoInputs() {
        askController.cancel()
        if case .invoking(let invocation) = sessionState {
            foreground.cancelInvocationIfCurrent(invocation.id)
        }
        if let spatialWaiter {
            self.spatialWaiter = nil
            spatialWaiter.resume(returning: nil)
        }
        guideCoordinator.cancelPendingDemoInputs()
        intentCards.dismiss()
        Task { await self.foreground.cancelActiveSupervisor() }
    }

    private func runGuideForDemo(goal: String) async -> Bool {
        await guideCoordinator.runGuideForDemo(goal: goal)
    }

    private func handleDemoReport(_: DoOutcome) {
        showHistory()
    }

    func showWhatsNew() {
        homeController.openHome(selection: .whatsNew)
    }

    private func schedulePersistence(_ operation: @escaping @Sendable () async -> Void) {
        guard !erasureInProgress else { return }
        let id = UUID()
        persistenceTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.persistenceTasks[id] = nil }
            guard !Task.isCancelled, !self.erasureInProgress else { return }
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
        guard case .asking(let ask) = sessionController.state, maintenanceOwner == nil else { return }
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
                return self.maintenanceOwner == nil
            } catch {
                self.homeController.homeModel.storageError = error.localizedDescription
                self.sessionStatus = "Couldn’t save your Guide request. Your text is still here."
                return false
            }
        }) { [weak self] current in
            guard let self, self.maintenanceOwner == nil,
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

    /// Seeds three deterministic transcript entries (two days, mixed
    /// outcomes) and opens History so the capture lane can screenshot a
    /// populated surface instead of an empty state.
    private func debugShowHistoryFixture() {
        let day = Calendar.current.startOfDay(for: Date())
        let entries: [TranscriptEntry] = [
            TranscriptEntry(
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!,
                request: "Move the two named files into Archive",
                appBundleID: "com.apple.finder",
                summary: "Verified: both files moved and contents unchanged.",
                outcome: .completed,
                startedAt: day.addingTimeInterval(-300),
                finishedAt: day.addingTimeInterval(-280),
                steps: ["Located draft-a.txt", "Moved to ~/Documents/Archive"],
                verified: true
            ),
            TranscriptEntry(
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!,
                request: "Guide me through exporting a PDF",
                appBundleID: "com.apple.Preview",
                summary: "Guided: File → Export as PDF completed.",
                outcome: .completed,
                startedAt: day.addingTimeInterval(-86_400),
                finishedAt: day.addingTimeInterval(-86_340),
                steps: ["Opened the File menu", "Pointed at Export as PDF"],
                verified: true
            ),
            TranscriptEntry(
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000F3")!,
                request: "Rename every screenshot in Downloads",
                appBundleID: "com.apple.finder",
                summary: "Stopped: the target window closed before the second step.",
                outcome: .failed,
                startedAt: day.addingTimeInterval(-86_000),
                finishedAt: day.addingTimeInterval(-85_970),
                steps: ["Renamed Screen Shot 1.png"],
                verified: false
            ),
        ]
        Task { @MainActor in
            for entry in entries {
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

}

extension AppController: GuideSessionOutput, GuideSessionContext {
    func guideShowOverlay() {
        if !overlayManager.isShowingOverlay() {
            overlayManager.showOverlay(onScreens: NSScreen.screens, state: overlayState)
        }
    }

    func guideStopSpatialInput() {
        spatialMonitor.stop()
    }

    func guideSetStatus(_ status: String) {
        sessionStatus = status
    }

    func guideSpeak(_ text: String, identity: GuideSpeechIdentity) {
        voice.deliverVoiceReply(text, guideSpeechIdentity: identity)
    }

    func guidePlay(_ cue: SoundPlayer.Cue) {
        SoundPlayer.play(cue)
    }

    func guideSetBuddyState(_ state: PerryBuddyState) {
        overlayState.buddyState = state
    }

    func guideInteractiveFrames() -> [CGRect] {
        [sessionPanel.frame, intentCards.frame].compactMap { $0 }
    }

    func guidePresent(_ presentation: GuidePresentation) {
        guard let target = presentation.target else {
            guideClearHighlight()
            return
        }
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = AXCoordinateConverter.appKitRect(
            axX: target.frame.x,
            axY: target.frame.y,
            width: target.frame.width,
            height: target.frame.height,
            primaryScreenMaxY: primaryMaxY
        )
        overlayState.detectedElementScreenLocation = CGPoint(x: frame.midX, y: frame.midY)
        overlayState.detectedElementDisplayFrame = frame
        overlayState.detectedElementBubbleText = presentation.step.instruction
        overlayState.activeControlGlowRect = frame.insetBy(dx: -6, dy: -6)
        overlayState.activeControlGlowLabel = target.label ?? presentation.step.instruction
    }

    func guideShowFullPath(_ viewPlan: EverythingViewPlan) {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let overlays = viewPlan.markers.map { marker in
            let point = AXCoordinateConverter.appKitPoint(
                axX: marker.position.x,
                axY: marker.position.y,
                primaryScreenMaxY: primaryMaxY,
                elementHeight: 24
            )
            return PerryGuidanceOverlay.scribble(
                points: [point, point],
                accentHex: "#34D399",
                lineWidth: 6,
                caption: "\(marker.number). \(marker.caption)",
                duration: 20
            )
        }
        overlayState.visualGuidanceOverlays.append(contentsOf: overlays)
    }

    func guideClearPresentation() {
        overlayState.voiceState = .idle
        overlayState.taskBubbleText = nil
        overlayState.agentTaskBubbleText = nil
        overlayState.detectedElementScreenLocation = nil
        overlayState.detectedElementDisplayFrame = nil
        overlayState.detectedElementBubbleText = nil
        overlayState.activeControlGlowRect = nil
        overlayState.activeControlGlowLabel = nil
        overlayState.circleSelectSnappedRect = nil
        overlayState.circleSelectSnapLabel = nil
        overlayState.visualGuidanceOverlays = []
        overlayManager.fadeOutAndHideOverlay()
        hidePanel()
        voice.refreshWakeWordListener()
    }

    func guideClearHighlight() {
        overlayState.detectedElementScreenLocation = nil
        overlayState.detectedElementDisplayFrame = nil
        overlayState.detectedElementBubbleText = nil
        overlayState.activeControlGlowRect = nil
        overlayState.activeControlGlowLabel = nil
    }

    func guideClearFullPath() {
        overlayState.visualGuidanceOverlays = []
    }

    func guideRequestTakeOver(_ handoff: GuideHandoff) {
        foreground.start(
            goal: "Continue the guided task: \(handoff.goal). Check the current window and finish the remaining work without repeating completed changes.",
            threadID: handoff.threadID, targetHint: handoff.target
        )
    }

    func guideTargetHint() -> CuaTargetHint {
        probe.currentTargetHint()
    }

    func guideAppBundleID(for targetHint: CuaTargetHint) -> String? {
        targetHint.processID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
            ?? activeSpatialSelection?.window?.appBundleID
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func guideSpatialRegionDescription() -> String? {
        activeSpatialSelection?.description
    }

    /// Talk's screen capture. The local observer (window list + AX hit-test +
    /// bounded index + ScreenCaptureKit) runs first — it's ~10x faster than
    /// the driver tree walk and claims no worker. The driver path remains for
    /// when Perry lacks grants or the local walk fails.
    func captureTalkObservation() async throws -> GuideObservation {
        PerfMark.mark("talk.capture_begin")
        let hint = guideTargetHint()
        await talkTargetStore.set(hint)
        do {
            if AXIsProcessTrusted() {
                do {
                    let observation = try await LocalTalkObserver(
                        hint: hint,
                        pointerAXPoint: PointerTraceRecorder.mouseLocationInAXSpace(),
                        targetStore: talkTargetStore
                    ).observe()
                    PerfMark.mark("talk.capture_local")
                    if observation.screenshotData == nil {
                        PerfMark.mark("talk.capture_no_screenshot")
                    }
                    PerfMark.mark("capture.done")
                    return observation
                } catch {
                    PerfMark.markDynamic("talk.capture_local_failed.\(String(describing: error))")
                }
            }
            var resources = Set<BackgroundTaskResource>()
            if let bundleID = guideAppBundleID(for: hint) {
                resources.insert(.application(bundleID))
            }
            let observation = try await workers.withWorker(scope: .dictation, resources: resources) { @MainActor worker in
                try await CuaGuideTreeReader(worker: worker, targetStore: self.talkTargetStore).observe()
            }
            PerfMark.mark("capture.done")
            return observation
        } catch {
            PerfMark.markDynamic("talk.capture_failed.\(String(describing: error))")
            throw error
        }
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
    func runDemo() { demoDirector.run() }
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
