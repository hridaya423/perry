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
    var askController: AskSessionController { subsystems.askController }
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
    var routineLibrary: RoutineLibraryController { subsystems.routineLibrary }
    var backgroundTaskContextStore: BackgroundTaskContextStore { subsystems.backgroundTaskContextStore }
    var backgroundTasks: BackgroundTaskController { subsystems.backgroundTasks }
    var erasurePaths: PerryErasurePaths { subsystems.erasurePaths }
    var completeErasure: CompleteErasureCoordinator { subsystems.completeErasure }
    private lazy var subsystems = AppSubsystems(app: self)
    lazy var maintenance = MaintenanceCoordinator(host: self)
    lazy var statusMenu = StatusMenuController(host: self)
    private lazy var sessionPanel = SessionPanelPresenter { [unowned self] in
#if DEBUG
        NSHostingView(rootView: PerryDebugTextScale(arguments: ProcessInfo.processInfo.arguments).apply(
            to: CompactConversationView(controller: self)
        ))
#else
        NSHostingView(rootView: CompactConversationView(controller: self))
#endif
    }
    let intentCards = IntentCardPresenter()
    private var guideOverlay: GuideOverlayPresenter { GuideOverlayPresenter(overlayState: overlayState) }
    private lazy var updateNoticeController = UpdateNoticeController(
        onPresent: { [weak self] in self?.showWhatsNew() },
        onSpeak: { [weak self] text in self?.voice.speak(text) }
    )
    private var manifestRefresher: CuaCapabilityManifest.Refresher?
    private lazy var demoFlow = DemoFlowController(host: self)
    var demoDirector: DemoDirector { demoFlow.director }

    /// Whether open-ended Do goals route through `AgentCoordinator`/`AgentLoop`.
    /// Production always does; the DEBUG harness init defaults to the typed
    /// plan path so fixtures stay deterministic without a provider.
    let foregroundUsesAgentRunner: Bool
    let notifier: any AppNotificationClient
#if DEBUG
    let debugSeams: DebugLaunchSeams
#endif
    let debugFinalizationPersistenceBarrier: (@Sendable () async -> Void)?
    lazy var guideBridge = GuideSessionBridge(host: self)
    lazy var commandRouter = CommandRouter(host: self)
    var talkSessionStarted = false
    var lastBackgroundCount = 0
    var lastAwaitingApprovalCount = 0
    lazy var onboarding = OnboardingCoordinator(
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
    func updateHomePeek(isRecording: Bool) {
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

    func showPanel() {
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
        DiagnosticsExporter(
            activityLog: activityLog, transcripts: transcriptStore,
            memory: memoryStore, setStatus: { [weak self] in self?.sessionStatus = $0 }
        ).exportActivityLog()
    }

    func exportDiagnostics() {
        DiagnosticsExporter(
            activityLog: activityLog, transcripts: transcriptStore,
            memory: memoryStore, setStatus: { [weak self] in self?.sessionStatus = $0 }
        ).exportDiagnostics()
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

    // MARK: Onboarding

    func runOnboarding(force: Bool) {
        onboarding.run(force: force)
    }

#if DEBUG
    /// Test seam for the dictated-command path — identical to what
    /// VoiceController's dispatch hook delivers after wake word/dictation.
    func debugDispatch(_ text: String) {
        commandRouter.route(commandText: text)
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

}

extension AppController: DemoFlowHost {
    func wakeForDemo() { wake() }
    func dismissIntentCard() { intentCards.dismiss() }
    func runOnboardingForDemo() { runOnboarding(force: true) }
    func showDemoReport() { showHistory() }
}

extension AppController: CommandRouteHost {
    var isUnderMaintenance: Bool { maintenance.isUnderMaintenance }
}

extension AppController: MaintenanceHost {
    var hasUnsavedHomeRequests: Bool {
        !homeController.homeModel.unsavedInputs.isEmpty
    }

}
