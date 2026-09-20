import AppKit
import Combine
import SwiftUI
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

    static let shared = AppController()

    private var hotkey: HotkeyController?
    private let overlayState = PerryCursorState()
    private lazy var overlaySampleLog: PerformanceSampleLog? = {
        try? PerformanceSampleLog.configured()
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
        return manager
    }()
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var settingsWindow: NSWindow?
    private var intentCardWindow: IntentCardWindow?
    private var historyWindow: HistoryWindow?
    private var backgroundTasksWindow: BackgroundTasksWindow?
    private lazy var updateNoticeController = UpdateNoticeController(
        onPresent: { [weak self] in self?.showWhatsNew() },
        onSpeak: { [weak self] text in self?.voice.speak(text) }
    )
    private let workers = CuaWorkerService()
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
        guidePlannerProvider: { [weak self] in
            guard let self else { return nil }
            return self.runtimes.makeGuidePlanner(storageDirectory: self.storageDirectory)
        }
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
        guidePlannerProvider: { [weak self] in
            guard let self else { return nil }
            return self.runtimes.makeGuidePlanner(storageDirectory: self.storageDirectory)
        }
    )
#endif
    lazy var askController = AskSessionController(
        sessionController: sessionController,
        workers: workers,
        overlayState: overlayState,
        output: self,
        context: self,
        answererFactory: { [weak self] in
            guard let answerer = self?.runtimes.makeSpatialAnswerer() else { return nil }
            return { question, observation, conversation, spatial in
                try await answerer.answer(
                    question: question,
                    observation: observation,
                    conversation: conversation,
                    spatialRegionDescription: spatial
                )
            }
        }
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
            refreshStatusItem: { [weak self] in self?.refreshStatusItemIndicator() },
            guideSpeechFinished: { [weak self] identity in self?.guideCoordinator.handleSpeechFinished(identity: identity) }
        )
    )
    private let oauthCoordinator = OAuthCoordinator()
    private let remoteIntegrationPermissions = RemoteIntegrationPermissionStore()
    private lazy var integrationClient = RemoteIntegrationClient(permissionStore: remoteIntegrationPermissions)
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
            dismissIntentCard: { [weak self] in
                self?.intentCardWindow?.cancel()
                self?.intentCardWindow = nil
            },
            stopSpatialMonitoring: { [weak self] in self?.spatialMonitor.stop() },
            stopGuideObservation: { [weak self] in self?.guideCoordinator.stopClickObservation() },
            makeConfirmer: { [weak self] in self?.makeConfirmer() ?? InteractiveConfirmer(controller: nil) }
        )
#if DEBUG
        return ForegroundTaskController(
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
            typedVerifier: debugTypedVerifier
        )
#else
        return ForegroundTaskController(
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
            hooks: hooks
        )
#endif
    }()
    private lazy var backgroundTaskCoordinator = TaskCoordinator(storageDirectory: storageDirectory)
    private lazy var backgroundTaskRunner = ResumableTaskRunner(
        coordinator: backgroundTaskCoordinator,
        notifier: notifier,
        activityLog: activityLog
    )
    private lazy var routineLibrary = RoutineLibraryController(
        store: RoutineStore(storageDirectory: storageDirectory),
        workers: workers,
        context: self,
        setStatus: { [weak self] status in self?.sessionStatus = status },
        speak: { [weak self] text in self?.voice.speak(text) },
        runRoutine: { [weak self] routine in self?.foreground.startRoutine(routine) }
    )
    private lazy var backgroundTaskContextStore = BackgroundTaskContextStore(storageDirectory: storageDirectory)
    lazy var backgroundTasks: BackgroundTaskController = {
        let hooks = BackgroundTaskController.Hooks(
            setStatus: { [weak self] status in self?.sessionStatus = status },
            isErasureInProgress: { [weak self] in self?.erasureInProgress ?? false },
            requestOnboarding: { [weak self] in self?.runOnboarding(force: true) },
            recordCountChanged: { [weak self] count in
                self?.backgroundTasksMenuItem?.title = "Background Tasks (\(count))"
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
    private var onboardingFlow: OnboardingFlow?
    private var memoryMenuItem: NSMenuItem?
    private var backgroundTasksMenuItem: NSMenuItem?
    private var recordDemoMenuItem: NSMenuItem?
    private var watchLearnMenu: NSMenu?
    private var activeSpatialSelection: SpatialSelection?
    private var backgroundPromptTask: Task<Void, Never>?
    private var terminationPrepared = false
    private var maintenanceOwner: MaintenanceOperation?
    private var spatialWaiter: CheckedContinuation<SpatialSelection?, Never>?
    private var spatialWorkerTask: Task<Void, Never>?
    private var persistenceTasks: [UUID: Task<Void, Never>] = [:]
    private var erasureInProgress = false
#if DEBUG
    private var debugMaintenanceBarrier: (@MainActor () async throws -> Void)?
    private var debugSkipEraseConfirmation = false
    private let debugConfirmer: (any Confirmer)?
    private let debugAskUser: (@Sendable (String, [String]) async throws -> Void)?
#endif
    @Published private(set) var sessionStatus = "Press ⌥⌘P when you want Perry."
    @Published private(set) var transcriptPreview = ""
    private let sessionController: SessionController
    private var sessionStateObservation: AnyCancellable?
    private var runtimeChoicesObservation: AnyCancellable?

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
        debugFinalizationBarrier = nil
        debugTypedVerifier = nil
        debugConfirmer = nil
        debugAskUser = nil
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
        debugStorageDirectory = nil
        debugRuntimeInventoryLoader = nil
        debugPermissionSnapshotLoader = nil
        debugCuaHealthLoader = nil
        debugScreenContextLoader = nil
        debugFullGuideCaptureLoader = nil
        debugFullGuideContinuationBarrier = nil
        debugFullGuidePlanner = nil
        debugFinalizationBarrier = nil
        debugTypedVerifier = nil
        debugConfirmer = nil
        debugAskUser = nil
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
        taskCoordinator: TaskCoordinator? = nil,
        runtimeInventoryLoader: RuntimeCatalog.InventoryLoader? = nil,
        permissionSnapshotLoader: EnvironmentProbe.PermissionSnapshotLoader? = nil,
        cuaHealthLoader: EnvironmentProbe.CuaHealthLoader? = nil,
        fullGuideCaptureLoader: FullGuideCaptureLoader? = nil,
        fullGuideContinuationBarrier: FullGuideContinuationBarrier? = nil,
        fullGuidePlanner: FullGuidePlanner? = nil,
        finalizationBarrier: FinalizationBarrier? = nil,
        finalizationPersistenceBarrier: FinalizationPersistenceBarrier? = nil,
        screenContextLoader: EnvironmentProbe.ScreenContextLoader? = nil,
        typedVerifier: (any TypedActionVerifier)? = nil,
        notifier: (any AppNotificationClient)? = nil,
        confirmer: (any Confirmer)? = nil,
        askUser: (@Sendable (String, [String]) async throws -> Void)? = nil
    ) {
        self.debugStorageDirectory = debugStorageDirectory
        self.debugRuntimeInventoryLoader = runtimeInventoryLoader
        self.debugPermissionSnapshotLoader = permissionSnapshotLoader
        self.debugCuaHealthLoader = cuaHealthLoader
        self.debugScreenContextLoader = screenContextLoader
        self.debugFullGuideCaptureLoader = fullGuideCaptureLoader
        self.debugFullGuideContinuationBarrier = fullGuideContinuationBarrier
        self.debugFullGuidePlanner = fullGuidePlanner
        self.debugFinalizationBarrier = finalizationBarrier
        self.debugFinalizationPersistenceBarrier = finalizationPersistenceBarrier
        self.debugTypedVerifier = typedVerifier
        self.debugConfirmer = confirmer
        self.debugAskUser = askUser
        self.notifier = notifier ?? SystemNotifier()
        self.sessionController = SessionController()
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
        wipeDataAction()
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
            self.objectWillChange.send()
        }
    }

    static var supportDirectory: URL? {
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


    private static let onboardingCompletedKey = "perry.onboarding.completed"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
        installStatusItem()
        installHotkey()
        voice.startInputListeners()
#if DEBUG
        if debugSurface == nil {
            runOnboardingIfNeeded()
        }
        if debugSurface == .settings {
            DispatchQueue.main.async { [weak self] in
                self?.settingsAction()
                NSApp.activate(ignoringOtherApps: true)
            }
        } else if debugSurface == .onboarding {
            DispatchQueue.main.async { [weak self] in
                self?.runDebugOnboarding()
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
        runOnboardingIfNeeded()
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
        backgroundPromptTask?.cancel()
        backgroundTasks.closeControls()
        guideCoordinator.prepareForTermination()
        Task { @MainActor [self] in
            defer { self.releaseMaintenance(.termination) }
            do {
                try await self.prepareForTermination()
                try await self.workers.shutdown()
                await self.joinAfterWorkerShutdown()
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

    private func acquireMaintenance(_ operation: MaintenanceOperation) -> Bool {
        guard maintenanceOwner == nil else { return false }
        maintenanceOwner = operation
        return true
    }

    private func releaseMaintenance(_ operation: MaintenanceOperation) {
        guard maintenanceOwner == operation else { return }
        maintenanceOwner = nil
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
        wipeDataAction()
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
        let shortcut = WakeShortcut(rawValue: UserDefaults.standard.string(forKey: "perry.wakeShortcut") ?? "") ?? .optionCommandP
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
        if isIdle {
            wake()
        } else {
            dismiss()
        }
    }

    private func wake() {
        guard isIdle, transitionSession({ try sessionController.wake() }) else { return }
        voice.refreshWakeWordListener()
        sessionStatus = "Listening for a request."
        transcriptPreview = ""
        activeSpatialSelection = nil
        overlayState.voiceState = .idle
        overlayState.taskBubbleText = "Circle a window with ⌥⌘ and drag, or type a request."
        overlayState.circleSelectSnappedRect = nil
        overlayState.circleSelectSnapLabel = nil
        overlayManager.showOverlay(onScreens: NSScreen.screens, state: overlayState)
        spatialMonitor.start()
        showPanel()
        SoundPlayer.play(.wake)
        voice.speak("Perry here.")
        runtimes.refreshChoices()
    }

    func dismiss() {
        if guideCoordinator.dismissIfActive() { return }
        if sessionController.requestDismissal() == .stopExecution {
            sessionStatus = "Stopping safely…"
            voice.cancelInput()
            intentCardWindow?.cancel()
            intentCardWindow = nil
            Task { await self.foreground.cancelActiveSupervisor() }
            hidePanel()
            return
        }
        foreground.cancelStartTask()
        if case .invoking(let invocation) = sessionState {
            foreground.cancelInvocationIfCurrent(invocation.id)
        }
        sessionStatus = "Ready when you are."
        askController.cancel()
        guideCoordinator.stopClickObservation()
        guideCoordinator.cancelPendingDemoInputs()
        spatialMonitor.stop()
        if let spatialWaiter {
            self.spatialWaiter = nil
            spatialWaiter.resume(returning: nil)
        }
        voice.cancelInput()
        intentCardWindow?.cancel()
        intentCardWindow = nil
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
    // MARK: Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = buildMenu()
        item.menu?.delegate = self
        statusItem = item
        refreshStatusItemIndicator()
    }

    private func refreshStatusItemIndicator() {
        let ambientWakeEnabled = UserDefaults.standard.bool(forKey: "perry.wakeWord.enabled")
        let symbolName = ambientWakeEnabled ? "waveform.circle.fill" : "scope"
        let description = ambientWakeEnabled ? "Perry is listening for hey Perry" : "Perry"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.title = image == nil ? (ambientWakeEnabled ? "Mic" : "Perry") : ""
        statusItem?.button?.toolTip = description
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Wake Perry (⌥⌘P)", action: #selector(wakeAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Ask Perry…", action: #selector(askPromptAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Guide me…", action: #selector(guidePromptAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show full guide", action: #selector(everythingAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Do a task…", action: #selector(doPromptAction), keyEquivalent: "").target = self
        let backgroundItem = NSMenuItem(title: "Run in background…", action: #selector(backgroundPromptAction), keyEquivalent: "")
        backgroundItem.target = self
        menu.addItem(backgroundItem)
        let backgroundTasksItem = NSMenuItem(title: "Background tasks", action: #selector(backgroundTasksAction), keyEquivalent: "")
        backgroundTasksItem.target = self
        backgroundTasksMenuItem = backgroundTasksItem
        menu.addItem(backgroundTasksItem)
        menu.addItem(withTitle: "Retry last task", action: #selector(retryAction), keyEquivalent: "").target = self
        let watchItem = NSMenuItem(title: "Watch & Learn", action: nil, keyEquivalent: "")
        let watchMenu = NSMenu()
        watchMenu.delegate = self
        let recordItem = NSMenuItem(title: "Record a demonstration…", action: #selector(recordDemoAction), keyEquivalent: "")
        recordItem.target = self
        recordDemoMenuItem = recordItem
        watchMenu.addItem(recordItem)
        watchMenu.addItem(.separator())
        watchItem.submenu = watchMenu
        watchLearnMenu = watchMenu
        menu.addItem(watchItem)
#if DEBUG
        menu.addItem(withTitle: "Run live Perry demo", action: #selector(demoAction), keyEquivalent: "").target = self
        let drills = NSMenuItem(title: "Failure drills", action: nil, keyEquivalent: "")
        let drillMenu = NSMenu()
        for drill in FailureDrill.allCases {
            let item = NSMenuItem(title: drill.title, action: #selector(failureDrillAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = drill.rawValue
            drillMenu.addItem(item)
        }
        drills.submenu = drillMenu
        menu.addItem(drills)
        let fixtures = NSMenuItem(title: "State fixtures", action: nil, keyEquivalent: "")
        let fixtureMenu = NSMenu()
        for fixture in DebugStateFixture.allCases {
            let item = NSMenuItem(title: fixture.title, action: #selector(stateFixtureAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = fixture.rawValue
            fixtureMenu.addItem(item)
        }
        fixtures.submenu = fixtureMenu
        menu.addItem(fixtures)
        menu.addItem(withTitle: "Invocation prototypes", action: #selector(prototypeAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Cursor prototypes", action: #selector(cursorPrototypeAction), keyEquivalent: "").target = self
#endif
        menu.addItem(.separator())
        menu.addItem(withTitle: "History", action: #selector(historyAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Export diagnostics…", action: #selector(diagnosticsAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "What’s New", action: #selector(whatsNewAction), keyEquivalent: "").target = self
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesAction), keyEquivalent: "")
        updateItem.target = self
        updateItem.isEnabled = updateNoticeController.availability == .available
        menu.addItem(updateItem)
        menu.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: ",").target = self

        let memoryItem = NSMenuItem(title: "Memory:…", action: #selector(toggleMemoryAction), keyEquivalent: "")
        memoryItem.target = self
        memoryMenuItem = memoryItem
        menu.addItem(memoryItem)

        let wipeItem = NSMenuItem(title: "Erase all Perry data…", action: #selector(wipeDataAction), keyEquivalent: "")
        wipeItem.target = self
        menu.addItem(wipeItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Perry", action: #selector(quitAction), keyEquivalent: "q").target = self
        return menu
    }

    @objc private func wakeAction() { wake() }
    @objc private func checkForUpdatesAction() { updateNoticeController.checkForUpdates() }
    @objc private func quitAction() { NSApp.terminate(nil) }

    private func refreshMemoryMenuTitle() async {
        let current = await memoryStore.currentConfiguration()
        memoryMenuItem?.title = "Memory: \(current.enabled ? "on" : "off")"
    }

    @objc private func askPromptAction() {
        wake()
        voice.speak("What are you curious about?")
    }

    @objc private func guidePromptAction() {
        wake()
        voice.speak("What should I teach you?")
    }

    @objc private func recordDemoAction() {
        routineLibrary.toggleRecording()
    }

    @objc private func runRoutineAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw),
              let routine = routineLibrary.routines().first(where: { $0.id == id }) else { return }
        routineLibrary.run(routine)
    }

    private func refreshWatchLearnMenu(_ menu: NSMenu) {
        recordDemoMenuItem?.title = routineLibrary.isRecording ? "Stop recording & review" : "Record a demonstration…"
        while menu.items.count > 2 { menu.removeItem(at: menu.items.count - 1) }
        let routines = routineLibrary.routines()
        guard !routines.isEmpty else {
            let empty = NSMenuItem(title: "No routines yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for routine in routines {
            let item = NSMenuItem(title: "Run \"\(routine.name)\"", action: #selector(runRoutineAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = routine.id.uuidString
            menu.addItem(item)
        }
    }

    @objc private func everythingAction() {
        Task { await showEverything(goal: "walk through the frontmost window") }
    }

    @objc private func doPromptAction() {
        wake()
        voice.speak("What are we taking off your hands?")
    }

    @objc private func backgroundPromptAction() {
        backgroundPromptTask?.cancel()
        backgroundPromptTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let choices = await runtimes.availableChoices()
            guard !Task.isCancelled else { return }
            presentBackgroundPrompt(runtimeChoices: choices)
        }
    }

    private func presentBackgroundPrompt(runtimeChoices: [RuntimeChoice]) {
        let alert = NSAlert()
        alert.messageText = "Run a task in the background"
        alert.informativeText = "Perry will keep this task locally and resume it from the Background tasks window if it pauses or the app restarts."
        let taskLabel = NSTextField(labelWithString: "Task")
        let field = NSTextField(string: "")
        field.placeholderString = "What should Perry do?"
        field.frame.size = NSSize(width: 330, height: 24)
        field.setAccessibilityLabel("Background task")
        let runtimeLabel = NSTextField(labelWithString: "Runtime")
        let runtimePicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 26), pullsDown: false)
        runtimePicker.setAccessibilityLabel("Background task runtime")
        runtimeChoices.forEach { choice in
            runtimePicker.addItem(withTitle: choice.name)
            runtimePicker.lastItem?.representedObject = choice.id
        }
        let stack = NSStackView(views: [taskLabel, field, runtimeLabel, runtimePicker])
        stack.orientation = .vertical
        stack.spacing = 5
        stack.frame.size = NSSize(width: 330, height: 94)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Queue task")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        backgroundTasks.queue(
            goal: field.stringValue,
            preferredRuntimeID: runtimePicker.selectedItem?.representedObject as? String
        )
    }

    @objc private func backgroundTasksAction() {
        showBackgroundTasks()
    }

    @objc private func retryAction() {
        foreground.retry()
    }

    @objc private func demoAction() {
        demoDirector.run()
    }

#if DEBUG
    @objc private func failureDrillAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let drill = FailureDrill(rawValue: rawValue) else { return }
        runFailureDrill(drill)
    }

    @objc private func stateFixtureAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let fixture = DebugStateFixture(rawValue: rawValue) else { return }
        applyDebugStateFixture(fixture)
    }

    @objc private func prototypeAction() {
        DebugPrototypeWindow.show()
    }

    @objc private func cursorPrototypeAction() {
        DebugCursorGalleryWindow.show()
    }

    private func runFailureDrill(_ drill: FailureDrill) {
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

    @objc private func historyAction() {
        showHistory()
    }

    @objc private func diagnosticsAction() {
        exportDiagnostics()
    }

    @objc private func whatsNewAction() {
        showWhatsNew()
    }

    func openSettings(tab: SettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.userDefaultsKey)
        settingsAction()
    }

    @objc private func settingsAction() {
        if settingsWindow == nil {
#if DEBUG
            let rootView = PerryDebugTextScale(arguments: ProcessInfo.processInfo.arguments).apply(to: SettingsView())
#else
            let rootView = SettingsView()
#endif
            let window = NSWindow(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: PerryTheme.Sizing.settingsWidth,
                    height: PerryTheme.Sizing.settingsHeight
                ),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Perry Settings"
            window.contentView = NSHostingView(rootView: rootView)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleMemoryAction() {
        schedulePersistence { [weak self, memoryStore] in
            let current = await memoryStore.currentConfiguration()
            await memoryStore.setConfiguration(
                MemoryConfiguration(enabled: !current.enabled, categoryToggles: current.categoryToggles)
            )
            await self?.refreshMemoryMenuTitle()
        }
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

    @objc private func wipeDataAction() {
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
                return await self.completeErasureCoordinator.erase()
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
        askController.cancel()
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
        await voice.joinInputWork()
        if let spatialWorkerTask {
            await spatialWorkerTask.value
        }
        await foreground.joinStartTask()
        await backgroundTasks.joinAll()
    }

    private func stopWorkForErasure() async {
        demoDirector.cancel()
        askController.cancel()
        routineLibrary.stop()
        await guideCoordinator.stopForErasure()
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

    private func showPanel() {
        if panel == nil {
#if DEBUG
            let rootView = PerryDebugTextScale(arguments: ProcessInfo.processInfo.arguments).apply(
                to: SessionPanelView(controller: self)
            )
#else
            let rootView = SessionPanelView(controller: self)
#endif
            let host = NSHostingView(rootView: rootView)
            let p = NSPanel(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: PerryTheme.Sizing.panelWidth,
                    height: PerryTheme.Sizing.panelHeight
                ),
                styleMask: [.titled, .utilityWindow, .fullSizeContentView, .resizable],
                backing: .buffered,
                defer: false
            )
            p.contentView = host
            p.identifier = SessionPanelView.windowIdentifier
            p.contentMinSize = NSSize(width: PerryTheme.Sizing.panelWidth, height: PerryTheme.Sizing.panelHeight)
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isOpaque = false
            p.backgroundColor = .clear
            p.titlebarAppearsTransparent = true
            p.level = .floating
            panel = p
        }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel?.setFrameOrigin(
                NSPoint(x: frame.maxX - 410, y: frame.minY + 120)
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    func showBackgroundTasks() {
        runtimes.refreshChoices()
        backgroundTasksWindow?.close()
        backgroundTasksWindow = BackgroundTasksWindow(backgroundTasks: backgroundTasks, runtimes: runtimes)
        backgroundTasksWindow?.show()
    }

#if DEBUG
    private func showDebugBackgroundTasksStorageError() {
        backgroundTasksWindow?.close()
        backgroundTasksWindow = BackgroundTasksWindow(backgroundTasks: backgroundTasks, runtimes: runtimes)
        backgroundTasksWindow?.show()
    }
#endif

    func startGuiding(goal: String) {
        guideCoordinator.startGuiding(goal: goal)
    }

    func ask(question: String) {
        askController.submit(question: question)
    }

    func advanceGuide() {
        guideCoordinator.advanceGuide()
    }

    func showEverything(goal: String) async {
        await guideCoordinator.showEverything(goal: goal)
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
        intentCardWindow?.cancel()
        intentCardWindow = nil
        Task { await self.foreground.cancelActiveSupervisor() }
    }

    private func runGuideForDemo(goal: String) async -> Bool {
        await guideCoordinator.runGuideForDemo(goal: goal)
    }

    private func handleDemoReport(_: DoOutcome) {
        showHistory()
    }

    private func showWhatsNew() {
        WhatsNewWindow.show()
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

    func integrationIsConnected(_ definition: RemoteIntegrationDefinition) async throws -> Bool {
        try await oauthCoordinator.hasCredential(for: definition)
    }

    func connectIntegration(
        _ definition: RemoteIntegrationDefinition,
        clientID: String,
        clientSecret: String? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        oauthCoordinator.authorize(
            definition: definition,
            configuration: OAuthConfiguration(
                clientID: clientID,
                clientSecret: clientSecret,
                scopes: definition.scopes
            )
        ) { result in
            completion(result.map { _ in () })
        }
    }

    func disconnectIntegration(_ definition: RemoteIntegrationDefinition) async throws {
        try await oauthCoordinator.disconnect(definition)
        remoteIntegrationPermissions.setWritesEnabled(false, for: definition)
    }

    func readIntegration(
        _ definition: RemoteIntegrationDefinition,
        path: String
    ) async throws -> Data {
        try await integrationClient.request(definition: definition, path: path)
    }

    func testIntegration(
        _ definition: RemoteIntegrationDefinition,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        Task { @MainActor in
            do {
                let summary = try await integrationClient.testConnection(definition: definition)
                completion(.success(summary))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func previewIntegration(
        _ definition: RemoteIntegrationDefinition,
        action: RemoteIntegrationQuickAction,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        Task { @MainActor in
            do {
                let summary = try await integrationClient.preview(definition: definition, action: action)
                completion(.success(summary))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func showHistory() {
        historyWindow?.close()
        historyWindow = HistoryWindow(store: transcriptStore, activityLog: activityLog)
        historyWindow?.show()
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
                    claudeInstalled: (try? CLIRuntime.locateExecutable()) != nil
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
        guard !Task.isCancelled, sessionController.approvalIsCurrent(id) else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                let window = IntentCardWindow(approvalID: id, card: card) { [weak self] approved in
                    if self?.intentCardWindow?.approvalID == id {
                        self?.intentCardWindow = nil
                    }
                    continuation.resume(returning: approved)
                }
                intentCardWindow = window
                window.showNearCursor()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.intentCardWindow?.approvalID == id else { return }
                self?.intentCardWindow?.cancel()
            }
        }
    }

    private func dispatch(commandText: String?) {
        guard let text = commandText, !text.isEmpty else {
            showPanel()
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
            startGuiding(goal: text)
        }
    }

    // MARK: Onboarding

    private func runOnboardingIfNeeded() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await PerryPermissionSnapshot.probe()
            if !snapshot.requiredPermissionsGranted || !UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey) {
                runOnboarding(force: false)
            }
        }
    }

    func runOnboarding(force: Bool) {
        if onboardingFlow != nil && !force { return }
        let flow = OnboardingFlow()
        onboardingFlow = flow
        OnboardingWindow.show(
            flow: flow,
            controller: self,
            onClose: { self.onboardingFlow = nil },
            onFinish: {
                UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
                self.onboardingFlow = nil
            }
        )
    }

#if DEBUG
    private func runDebugOnboarding() {
        let denied = PerryPermissionSnapshot(
            accessibility: false,
            screenRecording: .denied,
            microphone: .denied
        )
        let flow = OnboardingFlow(
            probe: { denied },
            cliDetector: { URL(fileURLWithPath: "/usr/bin/false") },
            codexDetector: { URL(fileURLWithPath: "/usr/bin/codex") }
        )
        onboardingFlow = flow
        OnboardingWindow.show(
            flow: flow,
            controller: self,
            onClose: { self.onboardingFlow = nil },
            permissionProbe: { denied }
        )
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
    private func applyDebugStateFixture(_ fixture: DebugStateFixture) {
        switch fixture {
        case .permissionDenied:
            runDebugOnboarding()
        case .approvalOrange, .approvalRed:
            guard let card = fixture.intentCard else { return }
            intentCardWindow = IntentCardWindow(card: card) { _ in }
            intentCardWindow?.showNearCursor()
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
        UserDefaults.standard.set(shortcut.rawValue, forKey: "perry.wakeShortcut")
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
        [panel?.frame, intentCardWindow?.frame].compactMap { $0 }
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

    func guideRequestTakeOver(goal: String) {
        _ = guideCoordinator.dismissIfActive()
        foreground.start(goal: goal)
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
}

extension AppController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === watchLearnMenu {
            refreshWatchLearnMenu(menu)
            return
        }
        Task { await refreshMemoryMenuTitle() }
    }
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
}
