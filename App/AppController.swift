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
    // Subsystem forwards — the composition graph lives in `subsystems`;
    // these keep existing call sites and host-protocol conformances working.
    var overlayState: PerryCursorState { subsystems.overlayState }
    var brain: BrainController { subsystems.brain }
    var foregroundWorkerLease: ForegroundWorkerLease { subsystems.foregroundWorkerLease }
    var toolHost: PerryToolHost { subsystems.toolHost }
    var perryStore: PerryStore? { subsystems.perryStore }
    var integrationBackend: AppIntegrationBackend { subsystems.integrationBackend }
    var suggestionController: SuggestionController { subsystems.suggestionController }
    var customConnectors: CustomConnectors { subsystems.customConnectors }
    var perryScheduler: PerrySchedulerController? { subsystems.perryScheduler }
    var mcp: MCPSocketLifecycle { subsystems.mcp }
    var overlaySampleLog: PerformanceSampleLog? { subsystems.overlaySampleLog }
    var overlayManager: OverlayWindowManager { subsystems.overlayManager }
    var workers: CuaWorkerService { subsystems.workers }
    var spatial: SpatialSelectionController { subsystems.spatial }
    var storageDirectory: URL? { subsystems.storageDirectory }
    var activityLog: ActivityLog { subsystems.activityLog }
    var memoryStore: MemoryStore { subsystems.memoryStore }
    var transcriptStore: TranscriptStore { subsystems.transcriptStore }
    var guideCoordinator: GuideSessionCoordinator { subsystems.guideCoordinator }
    var talkCapture: TalkObservationCapture { subsystems.talkCapture }
    var talkSkillLibrary: AppSkillLibrary { subsystems.talkSkillLibrary }
    var talkSession: TalkSession { subsystems.talkSession }
    var modifierHoldMonitor: ModifierHoldMonitor { subsystems.modifierHoldMonitor }
    var voice: VoiceController { subsystems.voice }
    var oauthCoordinator: OAuthCoordinator { subsystems.oauthCoordinator }
    var remoteIntegrationPermissions: RemoteIntegrationPermissionStore { subsystems.remoteIntegrationPermissions }
    var integrationClient: RemoteIntegrationClient { subsystems.integrationClient }
    var integrationConnections: IntegrationConnections { subsystems.integrationConnections }
    var remoteIntegrationExecutor: RemoteIntegrationActionRuntime { subsystems.remoteIntegrationExecutor }
    var executionFinalizer: ExecutionFinalizer { subsystems.executionFinalizer }
    var runtimes: RuntimeCatalog { subsystems.runtimes }
    var probe: EnvironmentProbe { subsystems.probe }
    var foreground: ForegroundTaskController { subsystems.foreground }
    var backgroundTaskCoordinator: TaskCoordinator {
        get { subsystems.backgroundTaskCoordinator }
        set { subsystems.backgroundTaskCoordinator = newValue }
    }
    var backgroundTaskRunner: ResumableTaskRunner { subsystems.backgroundTaskRunner }
    var notchStatus: NotchStatusController { subsystems.notchStatus }
    var homeThreadStore: ThreadStore { subsystems.homeThreadStore }
    var toolConsent: ToolConsentStore { subsystems.toolConsent }
    var agentCoordinator: AgentCoordinator {
        get { subsystems.agentCoordinator }
        set { subsystems.agentCoordinator = newValue }
    }
    var homeController: HomeController { subsystems.homeController }
    var conversationVoice: VoiceConversationController { subsystems.conversationVoice }
    var conversationVoiceObservation: AnyCancellable?
    var routineLibrary: RoutineLibraryController { subsystems.routineLibrary }
    var backgroundTaskContextStore: BackgroundTaskContextStore { subsystems.backgroundTaskContextStore }
    var backgroundTasks: BackgroundTaskController { subsystems.backgroundTasks }
    var erasurePaths: PerryErasurePaths { subsystems.erasurePaths }
    var completeErasure: CompleteErasureCoordinator { subsystems.completeErasure }
    private lazy var subsystems = AppSubsystems(app: self)
    lazy var maintenance = MaintenanceCoordinator(host: self)
    lazy var statusMenu = StatusMenuController(host: self)
    lazy var sessionPanel = SessionPanelPresenter { [unowned self] in
#if DEBUG
        let host = NSHostingView(rootView: PerryDebugTextScale(arguments: ProcessInfo.processInfo.arguments).apply(
            to: CompactConversationView(controller: self)
        ))
#else
        let host = NSHostingView(rootView: CompactConversationView(controller: self))
#endif
        host.sizingOptions = []
        return host
    }
    let intentCards = IntentCardPresenter()
    private var guideOverlay: GuideOverlayPresenter { GuideOverlayPresenter(overlayState: overlayState) }
    lazy var updateNoticeController = UpdateNoticeController(
        onPresent: { [weak self] in self?.showWhatsNew() },
        onSpeak: { [weak self] text in self?.voice.speak(text) }
    )
    private var manifestRefresher: CuaCapabilityManifest.Refresher?

    /// Whether open-ended Do goals route through `AgentCoordinator`/`AgentLoop`.
    /// Production always does; the DEBUG harness init defaults to the typed
    /// plan path so fixtures stay deterministic without a provider.
    let notifier: any AppNotificationClient
#if DEBUG
    let debugSeams: DebugLaunchSeams
#endif
    let debugFinalizationPersistenceBarrier: (@Sendable () async -> Void)?
    lazy var guideBridge = GuideSessionBridge(host: self)
    lazy var commandRouter = CommandRouter(host: self)
    var talkSessionStarted = false
    var modifierHoldIsSteering = false
    var lastBackgroundCount = 0
    var lastAwaitingApprovalCount = 0
    lazy var onboarding = OnboardingCoordinator(
        overlayState: overlayState,
        home: { [unowned self] in homeController },
        talkSession: { [unowned self] in talkSession },
        preferOnDeviceBrain: { [unowned self] in brain.preferOnDeviceModelIfUnchosen() },
        showNotch: { [unowned self] in showPanel() },
        endTalk: { [unowned self] in conversationVoice.cancel() }
    )
    var persistenceTasks: [UUID: Task<Void, Never>] = [:]
#if DEBUG
    var debugUnsavedQuitDecision: (() -> Bool)? {
        get { maintenance.debugUnsavedQuitDecision }
        set { maintenance.debugUnsavedQuitDecision = newValue }
    }
#endif
    @Published var sessionStatus = "Press ⌥⌘P when you want Perry."
    @Published var transcriptPreview = ""
    let sessionController: SessionController
    private var sessionStateObservation: AnyCancellable?
    private var runtimeChoicesObservation: AnyCancellable?
    var agentRunningObservation: AnyCancellable?

    override init() {
#if DEBUG
        debugSeams = .launch(arguments: ProcessInfo.processInfo.arguments)
#endif
        debugFinalizationPersistenceBarrier = nil
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
        self.notifier = notifier ?? SystemNotifier()
        self.sessionController = sessionController ?? SessionController()
        super.init()
        observeSessionState()
        if let taskCoordinator {
            self.backgroundTaskCoordinator = taskCoordinator
        }
    }
#endif

    var isTaskActive: Bool {
        if case .executing = sessionState { return true }
        return false
    }
    var executingTaskID: UUID? {
        guard case .executing(let execution) = sessionState else { return nil }
        return execution.taskID
    }
    var sessionState: SessionState { sessionController.state }
    var taskProgress: Double? {
        guard case .executing(let execution) = sessionState else { return nil }
        return execution.progress
    }

    var isIdle: Bool {
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
            if let cue = SoundPlayer.cue(from: self.sessionController.state, to: state) {
                SoundPlayer.play(cue)
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
        if let override = ProcessInfo.processInfo.environment["PERRY_DATA_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Perry", isDirectory: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        homeController.openHome()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.accessory)
        NotchPresentation.shared.onPresent = { [weak self] priority in self?.showPanel(activate: priority == .approval || priority == .routine) }
        // A companion that gets terminated mid-setup loses the user's trust
        // (HeyClicky lost first-run setups to this). Opt out explicitly.
        ProcessInfo.processInfo.disableAutomaticTermination(
            "Perry is a session-ready companion"
        )
#if DEBUG
        if debugHandleEarlyLaunchSurface() { return }
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
        if ProcessInfo.processInfo.arguments.contains("--perry-guide-drill") {
            installGuideDrillTrigger()
        }
#endif
        DispatchQueue.main.async { [weak self] in self?.warmSessionSurfaces() }
        homeController.start()
        perryScheduler?.start()
        suggestionController.start()
        if let dir = storageDirectory, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            mcp.startAfterLaunch(directory: dir)
            customConnectors.connectAll()
        }
#if DEBUG
        applyDebugLaunchSurface()
#else
        onboarding.runIfNeeded()
#endif
        updateNoticeController.start()
        SoundPlayer.warmUp()
        DictationController.warmPermissionCache()
        subsystems.talkSpeechInput.warmUp()
        subsystems.realtimeTalkVoice()?.warmUp()
        Task { [brain] in
            guard let decision = try? await brain.route(RouteRequirement(capabilities: [.vision, .streaming], tier: .fast)) else { return }
            await decision.provider.warm()
        }
        voice.refreshWakeWordListener()
        notchStatus.setListeningForWake(PerryPreferences.wakeWordEnabled)
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged() {
        handleScreenLayoutChanged()
    }

    func buildMenu() -> NSMenu {
        statusMenu.makeMenu()
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
        let shortcut = PerryPreferences.wakeShortcut
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
        sessionPanel.keyboardInitiated = true
        defer { sessionPanel.keyboardInitiated = false }
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
        overlayState.taskBubbleText = nil
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
        guideCoordinator.stopClickObservation()
        spatial.stopMonitoring()
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

    func showWhatsNew() {
        homeController.openHome(selection: .whatsNew)
    }

    func schedulePersistence(_ operation: @escaping @Sendable () async -> Void) {
        guard !maintenance.isErasureInProgress else { return }
        let id = UUID()
        persistenceTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.persistenceTasks[id] = nil }
            guard !Task.isCancelled, !self.maintenance.isErasureInProgress else { return }
            await operation()
        }
    }

    // MARK: Onboarding

    func runOnboarding(force: Bool) {
        onboarding.run(force: force)
    }

    func openOnboardingSettings() {
        openSettings(tab: .runtimes)
    }

    func updateWakeShortcut(_ shortcut: WakeShortcut) throws {
        if let hotkey {
            try hotkey.update(modifiers: shortcut.modifiers, keyCode: shortcut.keyCode)
        } else {
            hotkey = try HotkeyController(modifiers: shortcut.modifiers, keyCode: shortcut.keyCode) { [weak self] in
                Task { @MainActor in self?.toggleSession() }
            }
        }
        PerryPreferences.wakeShortcut = shortcut
        sessionStatus = "Wake shortcut changed to \(shortcut.title)."
    }

}

