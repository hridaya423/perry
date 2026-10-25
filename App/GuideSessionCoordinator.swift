import AppKit
import PerryCore
import PerryBrain
import PerryOverlay
import PerryCapture
import PerryGuide
import PerryRuntimes

@MainActor
struct GuideSpeechIdentity: Equatable {
    let guideID: UUID
    let scopeID: UUID
    let stepID: UUID?
    let text: String
}

struct GuideHandoff {
    let threadID: UUID
    let goal: String
    let target: CuaTargetHint
}

@MainActor
protocol GuideSessionOutput: AnyObject {
    func guideShowOverlay()
    func guideStopSpatialInput()
    func guideSetStatus(_ status: String)
    func guideSpeak(_ text: String, identity: GuideSpeechIdentity)
    func guidePlay(_ cue: SoundPlayer.Cue)
    func guidePresent(_ presentation: GuidePresentation)
    func guideSetBuddyState(_ state: PerryBuddyState)
    /// Frames of Perry-owned interactive surfaces; clicks inside them are
    /// controls, not wrong-target user clicks.
    func guideInteractiveFrames() -> [CGRect]
    func guideShowFullPath(_ viewPlan: EverythingViewPlan)
    func guideClearPresentation()
    func guideClearHighlight()
    func guideClearFullPath()
    /// The user asked Perry to finish the guided task itself — shared
    /// control, one direction. The coordinator hands over the same goal.
    func guideRequestTakeOver(_ handoff: GuideHandoff)
    /// True while Perry's synthesizer is talking — voice commands gate on
    /// it so Perry's own instruction can't echo in as a command.
    func guideIsSpeaking() -> Bool
    func guideReportFailure(_ message: String, recovery: FailureRecovery?)
    func guideClearFailure()
}

extension GuideSessionOutput {
    func guideRequestTakeOver(_ handoff: GuideHandoff) {}
    func guideIsSpeaking() -> Bool { false }
    func guideReportFailure(_ message: String, recovery: FailureRecovery?) { guideSetStatus(message) }
    func guideClearFailure() {}
}

@MainActor
protocol GuideSessionContext: AnyObject {
    func guideTargetHint() -> CuaTargetHint
    func guideAppBundleID(for targetHint: CuaTargetHint) -> String?
    func guideSpatialRegionDescription() -> String?
}

private struct EverythingGuideSession {
    let id: UUID
    let viewPlan: EverythingViewPlan
    let steps: [GuideStep]
    let observation: GuideObservation
    let context: GuideContext
    let goal: String
}

private struct GuideFinalizationRequest {
    let id: UUID
    let goal: String
    let startedAt: Date
    let steps: [String]
    let outcome: TranscriptEntry.Outcome
    let summary: String
    let appBundleID: String?
}

@MainActor
final class GuideWorkerSession {
    let id: UUID
    let targetStore: CuaGuideTargetStore
    let finishStream: AsyncStream<Void>
    let finishContinuation: AsyncStream<Void>.Continuation
    private(set) var worker: CuaWorkerHandle?
    var conversationOutcome: (answer: String, finish: AgentFinish)?
    var savedOutcome: AgentFinish?
    var takeoverRequested = false
    private(set) var engine: GuideEngine?
    var scopeTask: Task<Void, Never>?
    var finalizationTask: Task<Void, Never>?
    var repointTask: Task<Void, Never>?
    var highlightClearTask: Task<Void, Never>?
    var finishTask: Task<Void, Never>?
    var everythingTimeoutTask: Task<Void, Never>?
    private(set) var workerBodyActive = false
    private(set) var scopeFinished = false
    private(set) var finalizationSuppressed = false
    private var actionCallbackID: UUID?
    private var actionTask: Task<Void, Never>?
    private var callbackTasks: [UUID: Task<Void, Never>] = [:]
    private var callbackAdmissionOpen = true

    init(
        id: UUID,
        targetStore: CuaGuideTargetStore,
        finishStream: AsyncStream<Void>,
        finishContinuation: AsyncStream<Void>.Continuation
    ) {
        self.id = id
        self.targetStore = targetStore
        self.finishStream = finishStream
        self.finishContinuation = finishContinuation
    }

    func bind(worker: CuaWorkerHandle, engine: GuideEngine) {
        precondition(self.worker == nil && self.engine == nil)
        self.worker = worker
        self.engine = engine
    }

    func beginWorkerBody() {
        precondition(!workerBodyActive)
        workerBodyActive = true
    }

    func endWorkerBody() {
        workerBodyActive = false
    }

    func markFinished() {
        scopeFinished = true
    }

    func suppressFinalization() {
        finalizationSuppressed = true
        pendingFinalization = nil
    }

    func closeCallbackAdmission() {
        callbackAdmissionOpen = false
    }

    fileprivate func requestFinalization(_ request: GuideFinalizationRequest) {
        guard request.id == id, pendingFinalization == nil, finalizationTask == nil else { return }
        pendingFinalization = request
    }

    fileprivate var pendingFinalization: GuideFinalizationRequest?

    fileprivate func consumePendingFinalization() -> GuideFinalizationRequest? {
        guard finalizationTask == nil else { return nil }
        let request = pendingFinalization
        pendingFinalization = nil
        return request
    }

    func reserveAction() -> UUID? {
        guard callbackAdmissionOpen, actionCallbackID == nil else { return nil }
        let id = UUID()
        actionCallbackID = id
        return id
    }

    @discardableResult
    func addAction(_ task: Task<Void, Never>, id: UUID) -> Bool {
        guard callbackAdmissionOpen else {
            task.cancel()
            if actionCallbackID == id {
                actionCallbackID = nil
            }
            return false
        }
        precondition(actionCallbackID == id)
        actionTask = task
        callbackTasks[id] = task
        return true
    }

    @discardableResult
    func addCallback(_ task: Task<Void, Never>, id: UUID) -> Bool {
        guard callbackAdmissionOpen else {
            task.cancel()
            return false
        }
        callbackTasks[id] = task
        return true
    }

    func removeCallback(_ id: UUID) {
        callbackTasks[id] = nil
        if actionCallbackID == id {
            actionCallbackID = nil
            actionTask = nil
        }
    }

    func cancelCallbacks() {
        repointTask?.cancel()
        highlightClearTask?.cancel()
        finishTask?.cancel()
        everythingTimeoutTask?.cancel()
        actionTask?.cancel()
        callbackTasks.values.forEach { $0.cancel() }
    }

    func callbacks() -> [Task<Void, Never>] {
        callbackTasks.values.map { $0 }
    }
}

@MainActor
final class GuideSessionCoordinator {
    typealias FullGuideCaptureLoader = @MainActor (CuaWorkerHandle, CuaTargetHint?) async throws -> CuaCapturedWindow
    typealias FullGuideContinuationBarrier = @MainActor (UUID) async -> Void
    typealias FullGuidePlanner = @MainActor (String, GuideObservation, GuideContext) async throws -> [GuideStep]
    typealias GuidePlannerProvider = @MainActor (GuideSessionState) -> (any GuidePlanner)?

    private let sessionController: SessionController
    private let workers: CuaWorkerService
    private let executionOwner: AgentCoordinator?
    private let transcriptStore: TranscriptStore
    private let memoryStore: MemoryStore
    private let storageDirectory: URL?
    private weak var output: (any GuideSessionOutput)?
    private weak var context: (any GuideSessionContext)?
    private lazy var clickObserver = ClickAdvanceObserver { [weak self] point in
        self?.handleSessionClick(point)
    }
    private var guideScopes: [UUID: GuideWorkerSession] = [:]
    private var finalizingScopes: [UUID: GuideWorkerSession] = [:]
    private var currentGuideScopeID: UUID?
    private var guidePersistenceSuppressed = false
    private var lastGuideSpeechIdentity: GuideSpeechIdentity?
    private var everythingGuideSession: EverythingGuideSession?
    private var guideControlsState = GuideControlsState()
    private var guideControlsWindow: GuideControlsWindow?
    /// §3.4 voice controls — only listens while the guide controls are up
    /// and only when mic + speech permission is already granted.
    private lazy var guideVoiceCommands = GuideVoiceCommands(
        onCommand: { [weak self] command in self?.handleVoiceCommand(command) },
        isSpeaking: { [weak self] in self?.output?.guideIsSpeaking() ?? false }
    )
    private var guideStepPosition = 0
    private var activeGuideStepID: UUID?
    private var activeGuideInstruction: String?
    private let fullGuideCaptureLoader: FullGuideCaptureLoader?
    private let fullGuideContinuationBarrier: FullGuideContinuationBarrier?
    private let fullGuidePlanner: FullGuidePlanner?
    private let guidePlannerProvider: GuidePlannerProvider?
    private var guideAdmissionOpen = true

    init(
        sessionController: SessionController,
        workers: CuaWorkerService,
        transcriptStore: TranscriptStore,
        memoryStore: MemoryStore,
        storageDirectory: URL?,
        output: any GuideSessionOutput,
        context: any GuideSessionContext,
        fullGuideCaptureLoader: FullGuideCaptureLoader? = nil,
        fullGuideContinuationBarrier: FullGuideContinuationBarrier? = nil,
        fullGuidePlanner: FullGuidePlanner? = nil,
        guidePlannerProvider: GuidePlannerProvider? = nil,
        executionOwner: AgentCoordinator? = nil
    ) {
        self.sessionController = sessionController
        self.workers = workers
        self.executionOwner = executionOwner
        self.transcriptStore = transcriptStore
        self.memoryStore = memoryStore
        self.storageDirectory = storageDirectory
        self.output = output
        self.context = context
        self.fullGuideCaptureLoader = fullGuideCaptureLoader
        self.fullGuideContinuationBarrier = fullGuideContinuationBarrier
        self.fullGuidePlanner = fullGuidePlanner
        self.guidePlannerProvider = guidePlannerProvider
    }

    private func makeGuidePlanner(for guide: GuideSessionState) -> any GuidePlanner {
        guidePlannerProvider?(guide) ?? AXGuidePlanner(skillLibrary: AppSkillLibrary(storageDirectory: storageDirectory))
    }

    #if DEBUG
    /// Lab seam: injects a click at an AX-space point through the real
    /// handleSessionClick → engine.acceptClick path (hit test, postcondition
    /// verification, and presentation all run unchanged). Only the
    /// CGEvent→global-monitor hop is bypassed.
    func debugGuideDrillClick(axX: Double, axY: Double) {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        handleSessionClick(ClickLocation(
            axPoint: CGPointShim(x: axX, y: axY),
            appKitPoint: CGPointShim(x: axX, y: Double(primaryMaxY) - axY)
        ))
    }
    #endif

    var debugGuideScopeID: UUID? {
        currentGuideScope?.id
    }

    var debugGuideScopeCount: Int {
        guideScopes.count
    }

    var debugGuideSpeechIdentity: GuideSpeechIdentity? {
        lastGuideSpeechIdentity
    }

    func debugHandleSpeechFinished(_ identity: GuideSpeechIdentity) {
        handleSpeechFinished(identity: identity)
    }

    #if DEBUG
    /// Deterministic guide-controls surface for UI capture: step mode with a
    /// target label, no worker or session required.
    func debugShowGuideControlsFixture() {
        guideStepPosition = 2
        guideControlsState.stepPosition = 2
        guideControlsState.targetLabel = "Share button"
        guideControlsState.markerCaptions = []
        showGuideControls()
    }
    #endif

    @discardableResult
    func startGuiding(goal: String, threadID: UUID = UUID(), targetHint: CuaTargetHint? = nil, full: Bool = false, waitingInput: PerryThread.WaitingInput? = nil) -> Task<AgentFinish, Never>? {
        guard guideAdmissionOpen else { return nil }
        let attemptID = sessionController.currentOrFreshAttemptID
        guard beginInvokingIfNeeded(attemptID: attemptID) else {
            output?.guideSetStatus("Finish or stop the current session first.")
            return nil
        }
        guard let scope = startGuideSession(goal: goal, full: full, threadID: threadID, targetHint: targetHint, attemptID: attemptID, waitingInput: waitingInput),
              let task = scope.scopeTask else { return nil }
        return Task {
            await withTaskCancellationHandler {
                await task.value
                return scope.savedOutcome ?? .interrupted
            } onCancel: {
                task.cancel()
            }
        }
    }

    func showEverything(goal: String, threadID: UUID = UUID(), targetHint: CuaTargetHint? = nil) async {
        startGuiding(goal: goal, threadID: threadID, targetHint: targetHint, full: true)
    }

    func stopClickObservation() {
        clickObserver.stop()
    }

    func dismissIfActive() -> Bool {
        guard case .guiding(let guide) = sessionController.state else { return false }
        currentGuideScope?.closeCallbackAdmission()
        clickObserver.stop()
        currentGuideScope?.cancelCallbacks()
        activeGuideStepID = nil
        activeGuideInstruction = nil
        everythingGuideSession = nil
        hideGuideControls()
        if let scope = currentGuideScope,
           scope.id == guide.id {
            scope.requestFinalization(
                GuideFinalizationRequest(
                    id: guide.id,
                    goal: guide.goal,
                    startedAt: guide.startedAt,
                    steps: guide.steps,
                    outcome: .stopped,
                    summary: "Guide stopped before it finished.",
                    appBundleID: guide.appBundleID
                )
            )
            if !scope.workerBodyActive {
                // Body not started (or already closed): nothing else will
                // drain the pending request, so schedule the write now.
                scheduleGuideFinalization(for: scope)
            }
        }
        currentGuideScope?.finishContinuation.finish()
        // A body suspended in a planner/capture call only unwinds via
        // cancellation — free the worker slot for any replacement guide.
        currentGuideScope?.scopeTask?.cancel()
        _ = sessionController.requestDismissal()
        output?.guideStopSpatialInput()
        output?.guideSetBuddyState(.idle)
        output?.guideSetStatus("Ready when you are.")
        output?.guideClearPresentation()
        return true
    }

    func prepareForTermination() {
        guideAdmissionOpen = false
        clickObserver.stop()
        hideGuideControls()
        for scope in guideScopes.values {
            scope.closeCallbackAdmission()
            scope.cancelCallbacks()
            scope.finishContinuation.finish()
            scope.scopeTask?.cancel()
        }
    }

    func joinAfterWorkerShutdown() async {
        let scopes = Array(guideScopes.values)
        await waitForScopeCompletion(scopes)
        for scope in scopes where scope.scopeFinished {
            await scope.scopeTask?.value
        }
        for scope in scopes where !scope.scopeFinished {
            scope.suppressFinalization()
            scope.closeCallbackAdmission()
            scope.finishContinuation.finish()
            scope.scopeTask?.cancel()
            guideScopes[scope.id] = nil
            if currentGuideScopeID == scope.id {
                currentGuideScopeID = nil
            }
        }
        guideScopes = guideScopes.filter { !$0.value.scopeFinished }
    }

    func stopForErasure() async {
        guidePersistenceSuppressed = true
        guideAdmissionOpen = false
        clickObserver.stop()
        activeGuideStepID = nil
        activeGuideInstruction = nil
        everythingGuideSession = nil
        hideGuideControls()
        currentGuideScopeID = nil
        for scope in finalizingScopes.values {
            scope.suppressFinalization()
        }
        for scope in guideScopes.values {
            scope.suppressFinalization()
            scope.closeCallbackAdmission()
            scope.cancelCallbacks()
            scope.finishContinuation.finish()
            scope.scopeTask?.cancel()
        }
        let scopes = Array(guideScopes.values)
        for scope in scopes {
            if let guideTask = scope.scopeTask {
                await guideTask.value
            }
        }
        for scope in scopes + finalizingScopes.values {
            if let finalizationTask = scope.finalizationTask {
                await finalizationTask.value
            }
        }
        guideScopes.removeAll()
        lastGuideSpeechIdentity = nil
        guidePersistenceSuppressed = false
        guideAdmissionOpen = true
    }

    func handleSpeechFinished(identity: GuideSpeechIdentity) {
        guard lastGuideSpeechIdentity == identity else { return }
        scheduleGuideHighlightClear(after: identity)
    }

    private var currentGuideScope: GuideWorkerSession? {
        guard let currentGuideScopeID else { return nil }
        return guideScopes[currentGuideScopeID]
    }

    private func waitForScopeCompletion(_ scopes: [GuideWorkerSession]) async {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while scopes.contains(where: { !$0.scopeFinished }), ContinuousClock.now < deadline {
            do {
                try await Task.sleep(
                    until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(5))),
                    clock: .continuous
                )
            } catch {
                return
            }
        }
    }

    func advanceGuide() {
        guard let guideID = activeGuideID else { return }
        guard let scope = currentGuideScope, let engine = scope.engine else { return }
        guard let callbackID = scope.reserveAction() else { return }
        let task = Task { @MainActor [weak self, weak scope] in
            defer { scope?.removeCallback(callbackID) }
            guard !Task.isCancelled else { return }
            let result = await engine.userActed()
            guard !Task.isCancelled,
                  let self,
                  self.guideIsCurrent(guideID) else { return }
            self.handleGuideResult(result, guideID: guideID)
        }
        scope.addAction(task, id: callbackID)
    }

    private func showGuideControls() {
        guideVoiceCommands.startIfPermitted()
        output?.guideSetBuddyState(.guiding)
        if guideControlsWindow == nil {
            guideControlsWindow = GuideControlsWindow(
                state: guideControlsState,
                onDone: { [weak self] in self?.advanceGuide() },
                onBack: { [weak self] in self?.goBackGuideStep() },
                onSkip: { [weak self] in self?.skipGuideStep() },
                onRepoint: { [weak self] in self?.repointGuideStep() },
                onSelectMarker: { [weak self] index in self?.selectMarker(index: index) },
                onChooseInput: { [weak self] index in self?.answerGuideInput(at: index) },
                onTakeOver: { [weak self] in self?.takeOverGuide() },
                onStop: { [weak self] in _ = self?.dismissIfActive() }
            )
        }
        guard let window = guideControlsWindow, !window.isVisible else { return }
        window.show()
    }

    private func hideGuideControls() {
        guideVoiceCommands.stop()
        guideControlsWindow?.orderOut(nil)
        guideControlsWindow = nil
        guideControlsState.reset()
        guideStepPosition = 0
    }

    func takeOverGuide() {
        guard let scope = currentGuideScope, !scope.takeoverRequested,
              executionOwner != nil,
              case .guiding(let guide) = sessionController.state else { return }
        scope.takeoverRequested = true
        Task { @MainActor [weak self, scope] in
            guard let self, let target = await scope.targetStore.current(), self.guideIsCurrent(guide.id) else {
                scope.takeoverRequested = false
                return
            }
            let handoff = GuideHandoff(threadID: guide.threadID, goal: guide.goal, target: target)
            let attemptID = UUID()
            guard self.dismissIfActive(), self.beginInvokingIfNeeded(attemptID: attemptID) else { return }
            self.output?.guideSetStatus("Saving the guide before continuing…")
            await scope.scopeTask?.value
            guard self.guideAdmissionOpen,
                  case .invoking(let invocation) = self.sessionController.state,
                  invocation.id == attemptID else { return }
            guard scope.savedOutcome == .interrupted else {
                _ = try? self.sessionController.cancelInvocation(attemptID)
                self.output?.guideSetStatus(scope.savedOutcome?.failureReason ?? "The guide could not be saved. Review it before continuing.")
                return
            }
            self.output?.guideRequestTakeOver(handoff)
        }
    }

    private func presentGuideInput(guideID: UUID, prompt: String, choices: [String]) {
        guideControlsState.pendingPrompt = prompt
        guideControlsState.pendingChoices = choices
        output?.guideSetStatus(prompt)
        speak(prompt, guideID: guideID)
        showGuideControls()
    }

    /// The user picked one of the planner's `needsInput` choices — resume the
    /// paused engine with the answer so it re-plans from a fresh observation.
    func answerGuideInput(at index: Int) {
        guard let guideID = activeGuideID,
              guideControlsState.pendingChoices.indices.contains(index),
              let scope = currentGuideScope,
              let engine = scope.engine,
              let callbackID = scope.reserveAction() else { return }
        let answer = guideControlsState.pendingChoices[index]
        guideControlsState.pendingPrompt = nil
        guideControlsState.pendingChoices = []
        let task = Task { @MainActor [weak self, weak scope] in
            defer { scope?.removeCallback(callbackID) }
            guard !Task.isCancelled else { return }
            let result = await engine.resume(withAnswer: answer)
            guard !Task.isCancelled, let self, self.guideIsCurrent(guideID) else { return }
            self.handleGuideResult(result, guideID: guideID)
        }
        scope.addAction(task, id: callbackID)
    }

    private func skipGuideStep() {
        guard let guideID = activeGuideID,
              let scope = currentGuideScope,
              let engine = scope.engine,
              let callbackID = scope.reserveAction() else { return }
        let task = Task { @MainActor [weak self, weak scope] in
            defer { scope?.removeCallback(callbackID) }
            guard !Task.isCancelled else { return }
            let result = await engine.skip()
            guard !Task.isCancelled, let self, self.guideIsCurrent(guideID) else { return }
            self.handleGuideResult(result, guideID: guideID)
        }
        scope.addAction(task, id: callbackID)
    }

    /// §3.4: "next" / "back" / "skip" / "stop" / "do it" route to the same
    /// affordances the controls panel exposes.
    private func handleVoiceCommand(_ command: GuideVoiceCommands.Command) {
        PerfMark.mark("guide.voice.command")
        switch command {
        case .next: advanceGuide()
        case .back: goBackGuideStep()
        case .skip: skipGuideStep()
        case .stop: _ = dismissIfActive()
        case .doIt: takeOverGuide()
        }
    }

    private func goBackGuideStep() {
        guard let guideID = activeGuideID,
              let scope = currentGuideScope,
              let engine = scope.engine,
              let callbackID = scope.reserveAction() else { return }
        let task = Task { @MainActor [weak self, weak scope] in
            defer { scope?.removeCallback(callbackID) }
            guard !Task.isCancelled else { return }
            let result = await engine.back()
            guard !Task.isCancelled, let self, self.guideIsCurrent(guideID) else { return }
            self.handleGuideResult(result, guideID: guideID)
        }
        scope.addAction(task, id: callbackID)
    }

    private func repointGuideStep() {
        guard let guideID = activeGuideID,
              let scope = currentGuideScope,
              let engine = scope.engine,
              let callbackID = scope.reserveAction() else { return }
        let task = Task { @MainActor [weak self, weak scope] in
            defer { scope?.removeCallback(callbackID) }
            do {
                guard let presentation = try await engine.refreshPresentation(force: true) else { return }
                guard !Task.isCancelled, let self, self.guideIsCurrent(guideID) else { return }
                self.output?.guidePresent(presentation)
                self.output?.guideSetStatus("Found the target again.")
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.guideIsCurrent(guideID) else { return }
                self.finishGuide(guideID: guideID, outcome: .failed, summary: "Cua could not refresh the target window: \(error.localizedDescription)")
            }
        }
        scope.addAction(task, id: callbackID)
    }

    private var activeGuideID: UUID? {
        guard case .guiding(let guide) = sessionController.state else { return nil }
        return guide.id
    }

    private var isGuiding: Bool {
        activeGuideID != nil
    }

    private func transitionSession(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return true
        } catch {
            output?.guideSetStatus("Perry stopped because its session state changed unexpectedly.")
            return false
        }
    }

    private func startGuideSession(goal: String, full: Bool, threadID: UUID, targetHint: CuaTargetHint?, attemptID: UUID, waitingInput: PerryThread.WaitingInput?) -> GuideWorkerSession? {
        guard guideAdmissionOpen, case .invoking(let invocation) = sessionController.state,
              invocation.id == attemptID else { return nil }
        output?.guideSetStatus(full ? "Painting the complete path." : "Finding two useful places to show you.")
        output?.guideStopSpatialInput()
        let targetHint = targetHint ?? context?.guideTargetHint() ?? CuaTargetHint(bundleID: nil, processID: nil, windowTitle: nil)
        let appBundleID = context?.guideAppBundleID(for: targetHint)
        let guide = GuideSessionState(id: waitingInput?.id ?? UUID(), threadID: threadID, goal: goal, startedAt: Date(), appBundleID: appBundleID)
        guard transitionSession({ try sessionController.startGuide(guide, attemptID: attemptID) }) else { return nil }
        let (finishStream, finishContinuation) = AsyncStream<Void>.makeStream()
        let scope = GuideWorkerSession(
            id: guide.id,
            targetStore: CuaGuideTargetStore(),
            finishStream: finishStream,
            finishContinuation: finishContinuation
        )
        guideScopes[scope.id] = scope
        currentGuideScopeID = scope.id
        PerfMark.mark("guide.start")
        output?.guideShowOverlay()
        if let executionOwner {
            scope.scopeTask = executionOwner.runGuide(
                threadID: threadID, goal: goal, runID: guide.id, waitingInputID: waitingInput?.id,
                operation: { [weak self, scope] _ in
                    guard let self else { return ("Guide stopped.", .interrupted) }
                    return await self.runGuideScope(scope, guide: guide, full: full, targetHint: targetHint)
                },
                onFinish: { [weak self, scope] finish in
                    scope.savedOutcome = finish
                    scope.markFinished()
                    guard let self else { return }
                    if self.guideIsCurrent(guide.id) {
                        self.resetGuideAfterWorkerFailure(
                            guideID: guide.id, summary: finish.failureReason ?? "Guide stopped."
                        )
                    }
                    self.clearGuideScope(scope)
                }
            )
        } else {
            scope.scopeTask = Task { @MainActor [weak self, scope] in
                guard let self else { return }
                defer {
                    scope.markFinished()
                    self.clearGuideScope(scope)
                }
                _ = await self.runGuideScope(scope, guide: guide, full: full, targetHint: targetHint)
            }
        }
        return scope
    }

    private func runGuideScope(
        _ scope: GuideWorkerSession, guide: GuideSessionState, full: Bool, targetHint: CuaTargetHint
    ) async -> (answer: String, finish: AgentFinish) {
        do {
            // A dismissed or finished scope can still be unwinding while
            // it holds the single guide worker — wait briefly for prior
            // scopes to release before claiming it.
            await self.waitForScopeCompletion(guideScopes.values.filter { $0 !== scope })
            // The worker stays alive for the whole guide session: every
            // verified click, repoint, and dynamic replan reads the live
            // window through it. The body returns only when the guide's
            // finish stream closes.
            try await self.workers.withWorker(scope: .guide, resources: []) { @MainActor worker in
                scope.beginWorkerBody()
                do {
                    let engine = GuideEngine(
                        planner: self.makeGuidePlanner(for: guide),
                        observer: CuaGuideTreeReader(worker: worker, targetStore: scope.targetStore)
                    )
                    self.bindGuideScope(scope, worker: worker, engine: engine)
                    await scope.targetStore.set(targetHint)
                    guard self.guideIsCurrent(guide.id) else { return }
                    try Task.checkCancellation()
                    if full {
                        #if DEBUG
                        if let captureLoader = self.fullGuideCaptureLoader {
                            try await self.runFullGuide(guide: guide, capture: try await captureLoader(worker, targetHint))
                        } else {
                            try await self.runFullGuide(guide: guide, capture: try await worker.capture(target: targetHint))
                        }
                        #else
                        try await self.runFullGuide(guide: guide, capture: try await worker.capture(target: targetHint))
                        #endif
                    } else {
                        try await self.runTwoStepGuide(guide: guide, engine: engine)
                    }
                    for await _ in scope.finishStream { break }
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError) else { return }
                    switch error {
                    case GuidePlannerError.protectedWindow:
                        self.finishGuide(guideID: guide.id, outcome: .failed, summary: "That window is protected, so Perry won't guide inside it.")
                    case GuidePlannerError.explanationEnded:
                        self.finishGuide(guideID: guide.id, outcome: .stopped, summary: "Perry finished explaining. It didn’t check that the task is done.")
                    case GuidePlannerError.needsInput(let prompt, let choices):
                        self.presentGuideInput(guideID: guide.id, prompt: prompt, choices: choices)
                        for await _ in scope.finishStream { break }
                    default:
                        if full {
                            self.failFullGuide(guideID: guide.id, error: error)
                        } else {
                            self.failGuideFromWorker(guideID: guide.id, error: error)
                        }
                    }
                }
            }
            if !self.guideIsCurrent(guide.id) {
                scope.finishContinuation.finish()
            }
        } catch is CancellationError {
            #if DEBUG
            GuideDrillRecorder.status("cancelled outer=\(Task.isCancelled) opFinished=\(scope.workerBodyActive)")
            #endif
            self.resetGuideAfterWorkerFailure(
                guideID: guide.id,
                summary: "The guide stopped before its Cua worker could finish."
            )
        } catch {
            let message = "Cua could not start the guide: \(error.localizedDescription)"
            scope.conversationOutcome = (message, .failed(message))
            self.resetGuideAfterWorkerFailure(guideID: guide.id, summary: message)
        }
        // Drains pending finalization even when the worker was cancelled
        // out from under the body (dismiss, erasure, termination).
        await self.closeGuideScope(scope)
        return scope.conversationOutcome ?? ("Guide stopped before it finished.", .interrupted)
    }

    private func failGuideFromWorker(guideID: UUID, error: Error) {
        guard guideIsCurrent(guideID) else { return }
        finishGuide(guideID: guideID, outcome: .failed, summary: "Perry could not continue the guide: \(error.localizedDescription)")
    }

    private func failFullGuide(guideID: UUID, error: Error) {
        guard guideIsCurrent(guideID) else { return }
        finishGuide(guideID: guideID, outcome: .failed, summary: "Perry could not prepare the guide: \(error.localizedDescription)")
    }

    private func resetGuideAfterWorkerFailure(guideID: UUID, summary: String) {
        guard guideIsCurrent(guideID) else { return }
        currentGuideScope?.endWorkerBody()
        currentGuideScope?.closeCallbackAdmission()
        currentGuideScope?.cancelCallbacks()
        currentGuideScope?.finishContinuation.finish()
        clickObserver.stop()
        activeGuideStepID = nil
        activeGuideInstruction = nil
        everythingGuideSession = nil
        _ = sessionController.requestDismissal()
        output?.guideSetStatus(summary)
        output?.guideClearPresentation()
    }

    private func closeGuideScope(_ scope: GuideWorkerSession) async {
        scope.closeCallbackAdmission()
        if currentGuideScope === scope {
            clickObserver.stop()
        }
        scope.cancelCallbacks()
        for callback in scope.callbacks() { await callback.value }
        if scope.pendingFinalization != nil, !scope.finalizationSuppressed {
            scheduleGuideFinalization(for: scope)
        }
        if let finalizationTask = scope.finalizationTask {
            await finalizationTask.value
        }
        if let engine = scope.engine {
            await engine.stop()
        }
        scope.endWorkerBody()
    }

    private func clearGuideScope(_ scope: GuideWorkerSession) {
        guideScopes[scope.id] = nil
        if currentGuideScopeID == scope.id {
            currentGuideScopeID = nil
        }
    }

    private func scheduleGuideFinalization(for scope: GuideWorkerSession) {
        guard !guidePersistenceSuppressed, !scope.finalizationSuppressed else {
            _ = scope.consumePendingFinalization()
            return
        }
        guard let request = scope.consumePendingFinalization() else { return }
        let entry = TranscriptEntry(
            id: request.id,
            sessionID: request.id,
            request: request.goal,
            appBundleID: request.appBundleID,
            summary: request.summary,
            outcome: request.outcome,
            startedAt: request.startedAt,
            finishedAt: Date(),
            steps: request.steps,
            verified: nil
        )
        let workflow: MemoryRecord? = request.outcome == .completed && !request.steps.isEmpty
            ? MemoryRecord(category: .appWorkflow, appBundleID: request.appBundleID, summary: "\(request.goal): \(request.steps.joined(separator: " → "))")
            : nil
        finalizingScopes[scope.id] = scope
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finalizingScopes[scope.id] = nil }
            let progress = await scope.engine?.progress
            let current = await scope.engine?.currentPresentation()?.step.instruction
            var details = [request.summary]
            if let progress {
                if !progress.completedInstructions.isEmpty {
                    details.append("Observed completed steps:\n" + progress.completedInstructions.joined(separator: "\n"))
                }
                if !progress.userConfirmedInstructions.isEmpty {
                    details.append("User-confirmed steps, not independently verified:\n" + progress.userConfirmedInstructions.joined(separator: "\n"))
                }
            }
            if let current { details.append("Last instruction, not verified complete: " + current) }
            let finish: AgentFinish
            switch request.outcome {
            case .completed: finish = .completed
            case .stopped: finish = .interrupted
            case .failed: finish = .failed(request.summary)
            }
            scope.conversationOutcome = (details.joined(separator: "\n\n"), finish)
            guard !self.guidePersistenceSuppressed, !scope.finalizationSuppressed else { return }
            _ = await self.transcriptStore.append(entry)
            if let workflow {
                _ = await self.memoryStore.remember(workflow)
            }
        }
        scope.finalizationTask = task
    }

    private func bindGuideScope(_ scope: GuideWorkerSession, worker: CuaWorkerHandle, engine: GuideEngine) {
        guard guideScopes[scope.id] === scope else { return }
        scope.bind(worker: worker, engine: engine)
    }

    private func guideIsCurrent(_ id: UUID) -> Bool {
        activeGuideID == id && currentGuideScopeID == id && guideScopes[id] != nil
    }

    private func runTwoStepGuide(guide: GuideSessionState, engine: GuideEngine) async throws {
        let memoryContext = await memoryStore.promptContext(appBundleID: guide.appBundleID)
        guard await MainActor.run(body: { self.guideIsCurrent(guide.id) }) else { return }
        let guideContext = await MainActor.run {
            GuideContext(spatialRegionDescription: self.context?.guideSpatialRegionDescription(), memoryContext: memoryContext)
        }
        let firstStep = try await engine.start(goal: guide.goal, maximumSteps: 25, context: guideContext)
        guard await MainActor.run(body: { self.guideIsCurrent(guide.id) }) else { return }
        if let firstStep {
            clickObserver.start()
            scheduleGuideRepoint()
            guideStepPosition = 1
            present(step: firstStep)
            speak(firstStep.instruction, guideID: guide.id, stepID: firstStep.id)
            if !firstStep.waitForUserAction {
                scheduleGuideFinish(after: 1.5)
            }
        } else {
            finishGuide(guideID: guide.id, outcome: .failed, summary: "I couldn't see anything to point at there.")
        }
    }

    private func runFullGuide(guide: GuideSessionState, capture: CuaCapturedWindow) async throws {
        guard let snapshot = capture.accessibilitySnapshotModel else {
            guard await MainActor.run(body: { self.guideIsCurrent(guide.id) }) else { return }
            finishBlockedFullGuide(guideID: guide.id, summary: "Cua could not read the target window, so I couldn't paint the path.")
            return
        }
        let target = capture.target
        guard guideIsCurrent(guide.id), let scope = currentGuideScope, scope.id == guide.id else { return }
        await scope.targetStore.set(target.hint)
        let observation = GuideObservation(
            snapshot: snapshot,
            processID: target.processID,
            windowID: target.windowID,
            connectionGeneration: target.connectionGeneration,
            windowBounds: AXElementFrame(x: target.x, y: target.y, width: target.width, height: target.height),
            screenshotData: capture.screenshotData.isEmpty ? nil : capture.screenshotData,
            screenshotMIMEType: capture.screenshotMIMEType,
            observationID: capture.snapshotID
        )
        do {
            try GuideTargetValidator.requireUnprotected(observation)
        } catch {
            guard await MainActor.run(body: { self.guideIsCurrent(guide.id) }) else { return }
            finishBlockedFullGuide(guideID: guide.id, summary: "That window is protected, so Perry won't guide inside it.")
            return
        }
        let memoryContext = await memoryStore.promptContext(appBundleID: snapshot.appBundleID)
        guard await MainActor.run(body: { self.guideIsCurrent(guide.id) }) else { return }
        let guideContext = await MainActor.run {
            GuideContext(spatialRegionDescription: self.context?.guideSpatialRegionDescription(), memoryContext: memoryContext)
        }
        let steps: [GuideStep]
        #if DEBUG
        if let planner = fullGuidePlanner {
            steps = try await planner(guide.goal, observation, guideContext)
        } else {
            steps = try await makeGuidePlanner(for: guide).visiblePath(goal: guide.goal, observation: observation, context: guideContext)
        }
        #else
        steps = try await makeGuidePlanner(for: guide).visiblePath(goal: guide.goal, observation: observation, context: guideContext)
        #endif
        #if DEBUG
        if let barrier = fullGuideContinuationBarrier {
            await barrier(guide.id)
        }
        #endif
        try Task.checkCancellation()
        guard await MainActor.run(body: { self.guideIsCurrent(guide.id) }),
              let viewPlan = EverythingViewBuilder.build(steps: steps, snapshot: snapshot, goal: guide.goal) else {
            guard await MainActor.run(body: { self.guideIsCurrent(guide.id) }) else { return }
            finishBlockedFullGuide(guideID: guide.id, summary: "Nothing visible to map there yet.")
            return
        }
        guard transitionSession({ try sessionController.replaceGuidePlan(steps: steps.map { ($0.id, $0.instruction, !$0.target.isVerbal) }) }) else { return }
        everythingGuideSession = EverythingGuideSession(
            id: guide.id,
            viewPlan: viewPlan,
            steps: steps,
            observation: observation,
            context: guideContext,
            goal: guide.goal
        )
        clickObserver.start()
        paint(everything: viewPlan)
        speak("Here's the visible path, \(viewPlan.markers.count) steps.", guideID: guide.id)
    }

    private func finishBlockedFullGuide(guideID: UUID, summary: String) {
        guard guideIsCurrent(guideID) else { return }
        finishGuide(guideID: guideID, outcome: .failed, summary: summary)
    }

    private func handleSessionClick(_ click: ClickLocation) {
        guard isGuiding else { return }
        let clickPoint = CGPoint(x: click.appKitPoint.x, y: click.appKitPoint.y)
        let interactiveFrames = ([guideControlsWindow?.frame] + (output?.guideInteractiveFrames() ?? []))
            .compactMap { $0 }
        if interactiveFrames.contains(where: { $0.contains(clickPoint) }) {
            return
        }
        if let everythingGuideSession,
           everythingGuideSession.id == activeGuideID,
           let marker = marker(at: click.appKitPoint, in: everythingGuideSession.viewPlan) {
            select(marker)
            return
        }
        guard let guideID = activeGuideID, let scope = currentGuideScope, let engine = scope.engine, let callbackID = scope.reserveAction() else { return }
        PerfMark.mark("guide.click")
        let task = Task { @MainActor [weak self, weak scope] in
            defer { scope?.removeCallback(callbackID) }
            guard !Task.isCancelled else { return }
            let result = await engine.acceptClick(at: click.axPoint)
            guard !Task.isCancelled, let self, self.guideIsCurrent(guideID) else { return }
            self.handleGuideResult(result, guideID: guideID)
        }
        scope.addAction(task, id: callbackID)
    }

    private func selectMarker(index: Int) {
        guard let everythingGuideSession,
              everythingGuideSession.id == activeGuideID,
              everythingGuideSession.viewPlan.markers.indices.contains(index) else { return }
        select(everythingGuideSession.viewPlan.markers[index])
    }

    private func select(_ marker: EverythingViewPlan.Marker) {
        guard let everythingGuideSession,
              everythingGuideSession.id == activeGuideID,
              let scope = currentGuideScope, let engine = scope.engine, let callbackID = scope.reserveAction() else { return }
        let selectedSession = everythingGuideSession
        self.everythingGuideSession = nil
        guideControlsState.markerCaptions = []
        let guideID = selectedSession.id
        let task = Task { @MainActor [weak self, weak scope] in
            defer { scope?.removeCallback(callbackID) }
            do {
                guard let self, !Task.isCancelled, self.guideIsCurrent(guideID),
                      let firstStep = try await engine.start(
                        goal: selectedSession.goal,
                        observation: selectedSession.observation,
                        steps: selectedSession.steps,
                        selectedIndex: marker.id,
                        context: selectedSession.context
                      ),
                      !Task.isCancelled, self.guideIsCurrent(guideID) else { return }
                self.guideStepPosition = marker.id + 1
                self.present(step: firstStep)
                self.speak(firstStep.instruction, guideID: guideID, stepID: firstStep.id)
            } catch {
                guard let self, self.guideIsCurrent(guideID) else { return }
                self.finishGuide(guideID: guideID, outcome: .failed, summary: "That step's target is no longer where the map put it.")
            }
        }
        scope.addAction(task, id: callbackID)
    }

    private func handleGuideResult(_ result: AdvanceResult, guideID: UUID) {
        guard guideIsCurrent(guideID) else { return }
        switch result {
        case .advanced(let step, _):
            guideStepPosition += 1
            present(step: step)
            speak(step.instruction, guideID: guideID, stepID: step.id)
            if !step.waitForUserAction { scheduleGuideFinish(after: 1.5) }
        case .wentBack(let step, _):
            guideStepPosition = max(1, guideStepPosition - 1)
            present(step: step)
            speak(step.instruction, guideID: guideID, stepID: step.id)
            if !step.waitForUserAction { scheduleGuideFinish(after: 1.5) }
        case .finished:
            finishGuide(guideID: guideID, outcome: .completed)
        case .explanationEnded:
            finishGuide(guideID: guideID, outcome: .stopped, summary: "Perry finished explaining. It didn’t check that the task is done.")
        case .needsInput(let prompt, let choices):
            presentGuideInput(guideID: guideID, prompt: prompt, choices: choices)
        case .stillWaiting:
            output?.guideSetStatus("Not verified yet. Complete the step, then choose Done.")
        case .blocked(let reason):
            finishGuide(guideID: guideID, outcome: .failed, summary: reason)
        case .ignoredClick(_, let hitLabel):
            PerfMark.mark("guide.click.ignored")
            if let hitLabel, !hitLabel.isEmpty {
                output?.guideSetStatus("That’s \(hitLabel). We want the highlighted control.")
                speak("That’s \(hitLabel). We want the highlighted one.", guideID: guideID, stepID: activeGuideStepID)
            } else {
                output?.guideSetStatus("Not quite. Click the highlighted control.")
            }
        case .notPresenting:
            break
        }
    }

    private func scheduleGuideRepoint() {
        guard let guideID = activeGuideID, let scope = currentGuideScope, let engine = scope.engine else { return }
        scope.repointTask?.cancel()
        let callbackID = UUID()
        let task = Task { @MainActor [weak self, weak scope] in
            defer { scope?.removeCallback(callbackID) }
            do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
            guard let self, self.activeGuideID == guideID else { return }
            do {
                guard let presentation = try await engine.refreshPresentation() else { return }
                guard self.activeGuideID == guideID else { return }
                self.output?.guidePresent(presentation)
                self.output?.guideSetStatus("I refreshed the target after a quiet minute.")
                self.speak("Let’s try that target again.", guideID: guideID, stepID: self.activeGuideStepID)
            } catch {
                guard self.activeGuideID == guideID else { return }
                self.finishGuide(guideID: guideID, outcome: .failed, summary: "Cua could not refresh the target window: \(error.localizedDescription)")
            }
        }
        scope.repointTask = task
        scope.addCallback(task, id: callbackID)
    }

    private func beginInvokingIfNeeded(attemptID: UUID) -> Bool {
        guard case .idle = sessionController.state else {
            if case .invoking(let invocation) = sessionController.state, invocation.id == attemptID {
                return true
            }
            return false
        }
        return transitionSession { try sessionController.wake(attemptID: attemptID) }
    }

    private func finishGuide(guideID: UUID, outcome: TranscriptEntry.Outcome, summary: String? = nil) {
        guard guideIsCurrent(guideID), case .guiding(let guide) = sessionController.state else { return }
        currentGuideScope?.closeCallbackAdmission()
        clickObserver.stop()
        currentGuideScope?.cancelCallbacks()
        activeGuideStepID = nil
        activeGuideInstruction = nil
        everythingGuideSession = nil
        hideGuideControls()
        let isComplete = outcome == .completed
        let finalSummary = summary ?? "The requested outcome was verified."
        let scope = currentGuideScope
        if let scope, scope.id == guide.id, scope.workerBodyActive {
            scope.requestFinalization(GuideFinalizationRequest(id: guide.id, goal: guide.goal, startedAt: guide.startedAt, steps: guide.steps, outcome: outcome, summary: finalSummary, appBundleID: guide.appBundleID))
        }
        output?.guideSetStatus(isComplete ? "Guide complete." : finalSummary)
        output?.guidePlay(isComplete ? .done : .fail)
        output?.guideSetBuddyState(isComplete ? .success : (outcome == .stopped ? .idle : .blocked))
        guard transitionSession({ try sessionController.finishGuide(summary: finalSummary, outcome: isComplete ? .completed : .stopped) }) else { return }
        if let scope, scope.id == guide.id { scope.finishContinuation.finish() }
        _ = sessionController.requestDismissal()
        output?.guideClearPresentation()
        if isComplete {
            speak("That’s the whole flow.", guideID: guide.id, scopeID: scope?.id)
        } else {
            speak(finalSummary, guideID: guide.id, scopeID: scope?.id)
        }
    }

    private func paint(everything viewPlan: EverythingViewPlan) {
        guard let guideID = activeGuideID else { return }
        output?.guideShowFullPath(viewPlan)
        guideControlsState.markerCaptions = viewPlan.markers.map(\.caption)
        guideControlsState.targetLabel = nil
        showGuideControls()
        guard let scope = currentGuideScope else { return }
        scope.everythingTimeoutTask?.cancel()
        let callbackID = UUID()
        let task = Task { @MainActor [weak self, weak scope] in
            defer { scope?.removeCallback(callbackID) }
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            guard let self, self.activeGuideID == guideID else { return }
            guard self.everythingGuideSession?.id == guideID else { return }
            self.everythingGuideSession = nil
            self.clickObserver.stop()
            self.output?.guideClearFullPath()
            self.finishGuide(guideID: guideID, outcome: .failed, summary: "The full guide timed out before a step was selected.")
        }
        scope.everythingTimeoutTask = task
        scope.addCallback(task, id: callbackID)
    }

    private func scheduleGuideFinish(after delay: TimeInterval) {
        guard let guideID = activeGuideID, let scope = currentGuideScope else { return }
        scope.finishTask?.cancel()
        let callbackID = UUID()
        let task = Task { @MainActor [weak self, weak scope] in
            defer { scope?.removeCallback(callbackID) }
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, self.activeGuideID == guideID else { return }
            self.finishGuide(guideID: guideID, outcome: .stopped, summary: "Perry finished explaining. It didn’t check that the task is done.")
        }
        scope.finishTask = task
        scope.addCallback(task, id: callbackID)
    }

    private func marker(at point: CGPointShim, in plan: EverythingViewPlan) -> EverythingViewPlan.Marker? {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return plan.markers.first { marker in
            let screenPoint = AXCoordinateConverter.appKitPoint(axX: marker.position.x, axY: marker.position.y, primaryScreenMaxY: primaryMaxY, elementHeight: 24)
            return hypot(screenPoint.x - point.x, screenPoint.y - point.y) <= 32
        }
    }

    private func speak(_ text: String, guideID: UUID, scopeID: UUID? = nil, stepID: UUID? = nil) {
        guard let scopeID = scopeID ?? currentGuideScope?.id else { return }
        let identity = GuideSpeechIdentity(guideID: guideID, scopeID: scopeID, stepID: stepID, text: text)
        lastGuideSpeechIdentity = identity
        output?.guideSpeak(text, identity: identity)
    }

    private func present(step: GuideStep) {
        guard let scope = currentGuideScope, let engine = scope.engine else { return }
        scope.highlightClearTask?.cancel()
        scope.highlightClearTask = nil
        activeGuideStepID = step.id
        activeGuideInstruction = step.instruction
        output?.guideSetStatus(step.instruction)
        guideControlsState.markerCaptions = []
        guideControlsState.pendingPrompt = nil
        guideControlsState.pendingChoices = []
        guideControlsState.stepPosition = guideStepPosition
        guideControlsState.targetLabel = nil
        guideControlsState.hasPostcondition = step.postcondition != nil
        showGuideControls()
        _ = transitionSession { try sessionController.recordGuideStep(id: step.id, instruction: step.instruction, actionable: !step.target.isVerbal) }
        let guideID = scope.id
        let callbackID = UUID()
        let task = Task { @MainActor [weak self, weak scope] in
            defer { scope?.removeCallback(callbackID) }
            guard let self, let presentation = await engine.currentPresentation(), presentation.step.id == step.id, self.activeGuideID == guideID else { return }
            self.output?.guidePresent(presentation)
            self.guideControlsState.targetLabel = presentation.target?.label ?? presentation.target?.role.rawValue
            self.guideControlsState.canGoBack = await engine.canGoBack
        }
        scope.addCallback(task, id: callbackID)
    }

    private func scheduleGuideHighlightClear(after identity: GuideSpeechIdentity) {
        guard isGuiding,
              let guideID = activeGuideID,
              guideID == identity.guideID,
              activeGuideInstruction == identity.text,
              let stepID = activeGuideStepID,
              identity.stepID == stepID,
              let scope = currentGuideScope,
              scope.id == identity.scopeID else { return }
        scope.highlightClearTask?.cancel()
        let callbackID = UUID()
        let task = Task { @MainActor [weak self, weak scope] in
            defer { scope?.removeCallback(callbackID) }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            guard let self,
                  self.activeGuideID == guideID,
                  self.currentGuideScope === scope,
                  self.activeGuideStepID == stepID,
                  self.lastGuideSpeechIdentity == identity else { return }
            self.output?.guideClearHighlight()
        }
        scope.highlightClearTask = task
        scope.addCallback(task, id: callbackID)
    }
}
