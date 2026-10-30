import AppKit
import Combine
import UniformTypeIdentifiers
import SwiftUI
import PerryBrain
import PerryCore
import PerryOverlay
import PerryGuide
import PerryRuntimes

@MainActor
final class AppController: NSObject, NSApplicationDelegate, ObservableObject {

    private(set) var hotkey: HotkeyController?
    var conversationVoiceObservation: AnyCancellable?
    var markObservation: AnyCancellable?
    var markClickMonitor: Any?
#if DEBUG
    var overlayDump: AnyCancellable?
#endif
    lazy var subsystems = AppSubsystems(app: self)
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
        onSpeak: { [weak self] text in self?.subsystems.voice.speak(text) }
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
        home: { [unowned self] in subsystems.homeController },
        showNotch: { [unowned self] in showPanel() }
    )
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
    var isIdle: Bool {
        if case .idle = sessionState { return true }
        return false
    }

    private func observeSessionState() {
        sessionController.onTransitionRejected = { [weak self] in
            self?.sessionStatus = "I stopped because something changed unexpectedly. Try again."
        }
        sessionStateObservation = sessionController.$state.sink { [weak self] state in
            guard let self else { return }
            self.subsystems.foreground.handleSessionState(state)
            if self.talkSessionStarted, !state.isTalkingSession {
                self.subsystems.talkSession.cancel()
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
        subsystems.homeController.openHome()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.accessory)
        NotchPresentation.shared.onPresent = { [weak self] priority in self?.showPanel(activate: priority == .approval || priority == .routine) }
        ProcessInfo.processInfo.disableAutomaticTermination(
            "Perry is a session-ready companion"
        )
#if DEBUG
        if debugHandleEarlyLaunchSurface() { return }
#endif
        if let support = subsystems.storageDirectory {
            do {
                try FileManager.default.createDirectory(at: support.appendingPathComponent("workspace", isDirectory: true), withIntermediateDirectories: true)
            } catch {
                subsystems.homeController.homeModel.storageError = "Couldn’t prepare Perry’s file workspace. \(error.localizedDescription)"
            }
        }
        notifier.configure(
            onApprove: { [weak self] taskID, actionID, revision in
                self?.subsystems.backgroundTasks.approve(taskID, expectedActionID: actionID, expectedRevision: revision)
            },
            onDeny: { [weak self] taskID, revision in
                self?.subsystems.backgroundTasks.deny(taskID, expectedRevision: revision)
            },
            onOpen: { [weak self] in
                self?.showBackgroundTasks()
            }
        )
        ensureSupportDirectory()
        installHotkey()
        subsystems.voice.startInputListeners()
        subsystems.modifierHoldMonitor.interceptHold = { [weak self] in self?.subsystems.shortcutCheck.intercept() ?? false }
        subsystems.modifierHoldMonitor.start()
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
        markObservation = subsystems.overlayState.$visualGuidanceOverlays
            .scan(([PerryGuidanceOverlay](), [PerryGuidanceOverlay]())) { ($0.1, $1) }
            .filter { $0.1.count > $0.0.count }
            .sink { [weak self] _ in self?.showOverlayForMarks() }
        markClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.subsystems.overlayState.dismissMarks(at: point) }
        }
        subsystems.notchPresence.start()
        subsystems.perryScheduler?.start()
        subsystems.suggestionController.start()
        if let dir = subsystems.storageDirectory, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            subsystems.mcp.startAfterLaunch(directory: dir)
            subsystems.customConnectors.connectAll()
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
        Task { [brain = subsystems.brain] in
            guard let decision = try? await brain.route(RouteRequirement(capabilities: [.vision, .streaming], tier: .fast)) else { return }
            await decision.provider.warm()
        }
        subsystems.voice.refreshWakeWordListener()
        subsystems.notchStatus.setListeningForWake(PerryPreferences.wakeWordEnabled)
        Task { @MainActor [weak self] in
            await self?.subsystems.backgroundTasks.recoverInterruptedAndStartQueued()
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let health = await subsystems.workers.health()
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
        subsystems.voice.refreshWakeWordListener()
        sessionStatus = "Listening for a request."
        transcriptPreview = ""
        subsystems.spatial.clearSelection()
        subsystems.probe.pinInvocationTarget()
        PerfMark.mark("wake.pinned")
        subsystems.overlayState.voiceState = .idle
        subsystems.overlayState.taskBubbleText = nil
        subsystems.overlayState.circleSelectSnappedRect = nil
        subsystems.overlayState.circleSelectSnapLabel = nil
        subsystems.overlayManager.showOverlay(onScreens: NSScreen.screens, state: subsystems.overlayState)
        PerfMark.mark("wake.overlay")
        subsystems.spatial.startMonitoring()
        showPanel()
        if cue { SoundPlayer.play(.wake) }
    }

    func dismiss() {
        if subsystems.guideCoordinator.dismissIfActive() { return }
        if sessionController.requestDismissal() == .stopExecution {
            sessionStatus = "Stopping safely…"
            subsystems.voice.cancelInput()
            intentCards.dismiss()
            Task { await self.subsystems.foreground.cancelActiveSupervisor() }
            hidePanel()
            return
        }
        subsystems.foreground.cancelStartTask()
        if case .invoking(let invocation) = sessionState {
            subsystems.foreground.cancelInvocationIfCurrent(invocation.id)
        }
        sessionStatus = "Ready when you are."
        subsystems.probe.clearInvocationTarget()
        subsystems.guideCoordinator.stopClickObservation()
        subsystems.spatial.stopMonitoring()
        subsystems.voice.cancelInput()
        intentCards.dismiss()
        Task { await self.subsystems.foreground.cancelActiveSupervisor() }
        clearSessionSurfaces()
    }

    func showOverlayForMarks() {
        guard !subsystems.overlayManager.isShowingOverlay() else { return }
        subsystems.overlayManager.showOverlay(onScreens: NSScreen.screens, state: subsystems.overlayState)
    }

    func clearSessionSurfaces() {
        subsystems.overlayState.clearGuideOverlays()
        subsystems.overlayManager.fadeOutAndHideOverlay()
        hidePanel()
        subsystems.voice.refreshWakeWordListener()
    }


    @objc private func handleSystemSleep() {
        subsystems.foreground.takeOver()
    }

    func showWhatsNew() {
        subsystems.homeController.openHome(selection: .whatsNew)
    }


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

