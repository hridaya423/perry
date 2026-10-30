import AppKit
import Combine
import UniformTypeIdentifiers
import SwiftUI
import PerryBrain
import PerryCore
import PerryOverlay
import PerryGuide
import PerryRuntimes

/// Owns the live session: hotkey → overlay + panel, Guide/Do flows, intent
/// cards, notifications, memory. Everything the PRD's Session Orchestrator
/// implies, bound to real UI.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, ObservableObject {

    private(set) var hotkey: HotkeyController?
    // Subsystem forwards; the composition graph lives in `subsystems`.
    var overlayState: PerryCursorState { subsystems.overlayState }
    var brain: BrainController { subsystems.brain }
    var foregroundWorkerLease: ForegroundWorkerLease { subsystems.foregroundWorkerLease }
    var toolHost: PerryToolHost { subsystems.toolHost }
    var perryStore: PerryStore? { subsystems.perryStore }
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
    var shortcutCheck: ShortcutCheck { subsystems.shortcutCheck }
    var localBrain: LocalBrain { subsystems.localBrain }
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
    var notchStatus: NotchStatusController { subsystems.notchStatus }
    var agentCoordinator: AgentCoordinator {
        get { subsystems.agentCoordinator }
        set { subsystems.agentCoordinator = newValue }
    }
    var homeController: HomeController { subsystems.homeController }
    var notchPresence: NotchPresence { subsystems.notchPresence }
    var conversationVoiceObservation: AnyCancellable?
    var markObservation: AnyCancellable?
    var markClickMonitor: Any?
#if DEBUG
    var overlayDump: AnyCancellable?
#endif
    var routineLibrary: RoutineLibraryController { subsystems.routineLibrary }
    var routineOffer: RoutineOffer { subsystems.routineOffer }
    var backgroundTaskContextStore: BackgroundTaskContextStore { subsystems.backgroundTaskContextStore }
    var backgroundTasks: BackgroundTaskController { subsystems.backgroundTasks }
    var completeErasure: CompleteErasureCoordinator { subsystems.completeErasure }
    private lazy var subsystems = AppSubsystems(app: self)
    lazy var maintenance = MaintenanceCoordinator(host: self)
    lazy var statusMenu = StatusMenuController(host: self)
    lazy var sessionPanel = SessionPanelPresenter { [unowned self] in
#if DEBUG
        let host = FirstClickHostingView(rootView: PerryDebugTextScale(arguments: ProcessInfo.processInfo.arguments).apply(
            to: CompactConversationView(controller: self)
        ))
#else
        let host = FirstClickHostingView(rootView: CompactConversationView(controller: self))
#endif
        host.sizingOptions = []
        return host
    }
    let intentCards = IntentCardPresenter.shared
    lazy var updateNoticeController = UpdateNoticeController(
        onPresent: { [weak self] in self?.showWhatsNew() },
        onSpeak: { [weak self] text in self?.voice.speak(text) }
    )

    let notifier: any AppNotificationClient
    let overrides: LaunchOverrides
    lazy var guideBridge = GuideSessionBridge(host: self)
    lazy var commandRouter = CommandRouter(host: self)
    var talkSessionStarted = false
    var voiceOpenedNotch = false
    var modifierHoldIsSteering = false
    var lastBackgroundCount = 0
    var lastAwaitingApprovalCount = 0
    lazy var onboarding = OnboardingCoordinator(
        home: { [unowned self] in homeController },
        showNotch: { [unowned self] in showPanel() }
    )
    var persistenceTasks: [UUID: Task<Void, Never>] = [:]
#if DEBUG
    var debugUnsavedQuitDecision: (() -> Bool)? {
        get { maintenance.debugUnsavedQuitDecision }
        set { maintenance.debugUnsavedQuitDecision = newValue }
    }
#endif
    @Published var sessionStatus = "Press \(PerryPreferences.wakeGesture.keys) when you want Perry."
    @Published var transcriptPreview = ""
    let sessionController: SessionController
    private var sessionStateObservation: AnyCancellable?
    private var runtimeChoicesObservation: AnyCancellable?
    var agentRunningObservation: AnyCancellable?

    init(sessionController: SessionController, overrides: LaunchOverrides) {
        self.sessionController = sessionController
        self.overrides = overrides
        notifier = overrides.notifier ?? SystemNotifier()
        super.init()
        observeSessionState()
    }

    override convenience init() {
#if DEBUG
        self.init(sessionController: SessionController(), overrides: .launch(arguments: ProcessInfo.processInfo.arguments))
#else
        self.init(sessionController: SessionController(), overrides: LaunchOverrides())
#endif
    }

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

    private func observeSessionState() {
        sessionController.onTransitionRejected = { [weak self] in
            self?.sessionStatus = "I stopped because something changed unexpectedly. Try again."
        }
        runtimeChoicesObservation = runtimes.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        sessionStateObservation = sessionController.$state.sink { [weak self] state in
            guard let self else { return }
            self.foreground.handleSessionState(state)
            if self.talkSessionStarted, !state.isTalkingSession {
                self.talkSession.cancel()
            }
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
        modifierHoldMonitor.interceptHold = { [weak self] in self?.subsystems.shortcutCheck.intercept() ?? false }
        modifierHoldMonitor.start()
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--perry-talk-drill") {
            installTalkDrillTrigger()
        }
        if GuideDrillRecorder.enabled {
            installGuideDrillTrigger()
        }
        if ProcessInfo.processInfo.arguments.contains("--perry-task-drill") {
            installTaskDrillTrigger()
        }
        installOverlayDump()
#endif
        DispatchQueue.main.async { [weak self] in self?.warmSessionSurfaces() }
        markObservation = overlayState.$visualGuidanceOverlays
            .scan(([PerryGuidanceOverlay](), [PerryGuidanceOverlay]())) { ($0.1, $1) }
            .filter { $0.1.count > $0.0.count }
            .sink { [weak self] _ in self?.showOverlayForMarks() }
        markClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.overlayState.dismissMarks(at: point) }
        }
        notchPresence.start()
        perryScheduler?.start()
        suggestionController.start()
        if let dir = storageDirectory, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            mcp.startAfterLaunch(directory: dir)
            customConnectors.connectAll()
        }
        if PerryPreferences.speechEngine.isEmpty, VoiceController.naturalVoices().isEmpty {
            PerryPreferences.speechEngine = SpeechEngineChoice.kokoro.rawValue
        }
        if SpeechEngineChoice.current == .kokoro { KokoroInstaller.shared.start() }
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
            sessionStatus = "I couldn’t prepare my data folder."
        }
    }

    // MARK: Wake / dismiss

    private func installHotkey() {
        let gesture = PerryPreferences.wakeGesture
        do {
            guard let registration = gesture.carbonHotkey else { throw HotkeyController.HotkeyError.needsModifier }
            hotkey = try HotkeyController(modifiers: registration.modifiers, keyCode: registration.keyCode) { [weak self] in
                Task { @MainActor in self?.toggleSession() }
            }
        } catch {
            hotkey = nil
            sessionStatus = "I couldn’t set \(gesture.keys). Choose another shortcut in Settings > Shortcuts."
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

    func wake(cue: Bool = true) {
        guard isIdle, sessionController.transition({ try sessionController.wake() }) else { return }
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
        if cue { SoundPlayer.play(.wake) }
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

    /// Marks drawn from any surface (Home, a routine, a Do run) need the
    /// overlay window, which only wake and Guide used to show.
    func showOverlayForMarks() {
        guard !overlayManager.isShowingOverlay() else { return }
        overlayManager.showOverlay(onScreens: NSScreen.screens, state: overlayState)
    }

    /// Takes every session mark off the overlay, hides the overlay and panel,
    /// and lets the wake word listen again.
    func clearSessionSurfaces() {
        overlayState.clearGuideOverlays()
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
        openSettings(.brain)
    }

    func updateWakeShortcut(_ gesture: Gesture) throws {
        guard let registration = gesture.carbonHotkey else { throw HotkeyController.HotkeyError.needsModifier }
        if let hotkey {
            try hotkey.update(modifiers: registration.modifiers, keyCode: registration.keyCode)
        } else {
            hotkey = try HotkeyController(modifiers: registration.modifiers, keyCode: registration.keyCode) { [weak self] in
                Task { @MainActor in self?.toggleSession() }
            }
        }
        PerryPreferences.wakeGesture = gesture
        sessionStatus = "Wake shortcut changed to \(gesture.keys)."
    }

}

