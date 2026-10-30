import AppKit
import PerryBrain
import PerryCapture
import PerryCore
import PerryGuide
import PerryOverlay
import PerryRuntimes

@MainActor
final class GuideSessionCoordinator {
    typealias FullGuideCaptureLoader = @MainActor (CuaWorkerHandle, CuaTargetHint?) async throws -> CuaCapturedWindow
    typealias FullGuideContinuationBarrier = @MainActor (UUID) async -> Void
    typealias GuidePlannerProvider = @MainActor (GuideSessionState) -> (any GuidePlanner)?

    let sessionController: SessionController
    let memoryStore: MemoryStore
    weak var output: (any GuideSessionOutput)?
    weak var context: (any GuideSessionContext)?
    lazy var clickObserver = ClickAdvanceObserver { [weak self] point in
        self?.handleSessionClick(point)
    }
    var everythingGuideSession: EverythingGuideSession?
    let guideControlsState = GuideControlsState()
    var guideStepPosition = 0
    var activeGuideStepID: UUID?
    let fullGuideContinuationBarrier: FullGuideContinuationBarrier?

    private let workers: CuaWorkerService
    private let executionOwner: AgentCoordinator?
    private let finalizer: GuideFinalizer
    private var guideScopes: [UUID: GuideWorkerSession] = [:]
    private var currentGuideScopeID: UUID?
    private var lastGuideSpeechIdentity: GuideSpeechIdentity?
    private var guideControlsWindow: GuideControlsWindow?
    private lazy var guideVoiceCommands = GuideVoiceCommands(
        onCommand: { [weak self] command in self?.handleVoiceCommand(command) },
        isSpeaking: { [weak self] in self?.output?.guideIsSpeaking() ?? false }
    )
    private let fullGuideCaptureLoader: FullGuideCaptureLoader?
    private let guidePlannerProvider: GuidePlannerProvider?
    private var guideAdmissionOpen = true

    init(
        sessionController: SessionController,
        workers: CuaWorkerService,
        transcriptStore: TranscriptStore,
        memoryStore: MemoryStore,
        output: any GuideSessionOutput,
        context: any GuideSessionContext,
        fullGuideCaptureLoader: FullGuideCaptureLoader? = nil,
        fullGuideContinuationBarrier: FullGuideContinuationBarrier? = nil,
        guidePlannerProvider: GuidePlannerProvider? = nil,
        executionOwner: AgentCoordinator? = nil
    ) {
        self.sessionController = sessionController
        self.workers = workers
        self.executionOwner = executionOwner
        self.finalizer = GuideFinalizer(transcriptStore: transcriptStore, memoryStore: memoryStore)
        self.memoryStore = memoryStore
        self.output = output
        self.context = context
        self.fullGuideCaptureLoader = fullGuideCaptureLoader
        self.fullGuideContinuationBarrier = fullGuideContinuationBarrier
        self.guidePlannerProvider = guidePlannerProvider
    }

    #if DEBUG
    func debugGuideDrillClick(axX: Double, axY: Double) {
        handleSessionClick(CGPointShim(x: axX, y: axY))
    }

    func debugShowGuideControlsFixture() {
        guideStepPosition = 2
        guideControlsState.stepPosition = 2
        guideControlsState.targetLabel = "Share button"
        guideControlsState.markerCaptions = []
        showGuideControls()
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

    var currentGuideScope: GuideWorkerSession? {
        currentGuideScopeID.flatMap { guideScopes[$0] }
    }

    var activeGuideID: UUID? {
        guard case .guiding(let guide) = sessionController.state else { return nil }
        return guide.id
    }

    func guideIsCurrent(_ id: UUID) -> Bool {
        activeGuideID == id && currentGuideScopeID == id && guideScopes[id] != nil
    }

    func makeGuidePlanner(for guide: GuideSessionState) -> any GuidePlanner {
        guidePlannerProvider?(guide) ?? AXGuidePlanner()
    }

    @discardableResult
    func startGuiding(goal: String, threadID: UUID = UUID(), targetHint: CuaTargetHint? = nil, full: Bool = false, waitingInput: PerryThread.WaitingInput? = nil) -> Task<AgentFinish, Never>? {
        guard guideAdmissionOpen else { return nil }
        let attemptID = sessionController.currentOrFreshAttemptID
        guard beginInvokingIfNeeded(attemptID: attemptID) else {
            output?.guideSetStatus("Finish or stop what I’m doing first.")
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
        let scope = currentGuideScope
        teardown(scope)
        if let scope, scope.id == guide.id {
            scope.requestFinalization(GuideFinalizationRequest(
                guide: guide, outcome: .stopped, summary: "Guide stopped before it finished."
            ))
            if !scope.workerBodyActive {
                finalizer.schedule(for: scope)
            }
        }
        scope?.abort()
        _ = sessionController.requestDismissal()
        output?.guideStopSpatialInput()
        output?.guideSetBuddyState(.idle)
        output?.guideSetStatus("Ready when you are.")
        output?.guideClearPresentation()
        return true
    }

    func prepareForTermination() {
        guideAdmissionOpen = false
        teardown(currentGuideScope)
        guideScopes.values.forEach { $0.abort() }
    }

    func joinAfterWorkerShutdown() async {
        let scopes = Array(guideScopes.values)
        await waitForScopeCompletion(scopes)
        for scope in scopes where scope.isFinished {
            await scope.scopeTask?.value
        }
        for scope in scopes where !scope.isFinished {
            scope.suppressFinalization()
            scope.abort()
        }
        guideScopes.removeAll()
        currentGuideScopeID = nil
    }

    func stopForErasure() async {
        guideAdmissionOpen = false
        teardown(currentGuideScope)
        currentGuideScopeID = nil
        finalizer.suppressInFlight()
        let scopes = Array(guideScopes.values)
        for scope in scopes {
            scope.suppressFinalization()
            scope.abort()
        }
        for scope in scopes {
            await scope.scopeTask?.value
        }
        await finalizer.settle(scopes)
        guideScopes.removeAll()
        lastGuideSpeechIdentity = nil
        guideAdmissionOpen = true
    }

    func advanceGuide() {
        perform { await $0.userActed() }
    }

    func answerGuideInput(at index: Int) {
        guard guideControlsState.pendingChoices.indices.contains(index) else { return }
        let answer = guideControlsState.pendingChoices[index]
        perform(onStart: {
            guideControlsState.pendingPrompt = nil
            guideControlsState.pendingChoices = []
        }) { await $0.resume(withAnswer: answer) }
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
                self.output?.guideSetStatus(scope.savedOutcome?.failureReason ?? "I couldn’t save the guide. Review it before continuing.")
                return
            }
            self.output?.guideRequestTakeOver(handoff)
        }
    }

    func showGuideControls() {
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

    func speak(_ text: String, guideID: UUID, stepID: UUID? = nil) {
        guard let scopeID = currentGuideScope?.id else { return }
        let identity = GuideSpeechIdentity(guideID: guideID, scopeID: scopeID, stepID: stepID, text: text)
        lastGuideSpeechIdentity = identity
        output?.guideSpeak(text, identity: identity)
    }

    func planningContext(appBundleID: String?) async -> GuideContext {
        GuideContext(
            spatialRegionDescription: context?.guideSpatialRegionDescription(),
            memoryContext: await memoryStore.promptContext(appBundleID: appBundleID)
        )
    }

    func transitionSession(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return true
        } catch {
            output?.guideSetStatus("I stopped because something changed unexpectedly. Try again.")
            return false
        }
    }

    func schedule(_ slot: GuideWorkerSession.Slot, after delay: Duration, _ body: @escaping @MainActor (GuideSessionCoordinator, UUID) async -> Void) {
        guard let guideID = activeGuideID, let scope = currentGuideScope else { return }
        scope.start(slot) { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.activeGuideID == guideID else { return }
            await body(self, guideID)
        }
    }

    func present(step: GuideStep) {
        guard let scope = currentGuideScope, let engine = scope.engine else { return }
        activeGuideStepID = step.id
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
        scope.start(.presentation) { [weak self] in
            guard let self, let presentation = await engine.currentPresentation(), presentation.step.id == step.id, self.activeGuideID == guideID else { return }
            self.output?.guidePresent(presentation)
            self.guideControlsState.targetLabel = presentation.target?.label ?? presentation.target?.role.rawValue
            self.guideControlsState.canGoBack = await engine.canGoBack
        }
    }

    func finishGuide(guideID: UUID, outcome: TranscriptEntry.Outcome, summary: String? = nil) {
        guard guideIsCurrent(guideID), case .guiding(let guide) = sessionController.state else { return }
        let scope = currentGuideScope
        teardown(scope)
        let isComplete = outcome == .completed
        let finalSummary = summary ?? "I checked that it worked."
        if let scope, scope.workerBodyActive {
            scope.requestFinalization(GuideFinalizationRequest(guide: guide, outcome: outcome, summary: finalSummary))
        }
        output?.guideSetStatus(isComplete ? "Guide complete." : finalSummary)
        output?.guidePlay(isComplete ? .done : .fail)
        output?.guideSetBuddyState(isComplete ? .success : (outcome == .stopped ? .idle : .blocked))
        guard transitionSession({ try sessionController.finishGuide(summary: finalSummary, outcome: isComplete ? .completed : .stopped) }) else { return }
        scope?.finishContinuation.finish()
        _ = sessionController.requestDismissal()
        output?.guideClearPresentation()
        speak(isComplete ? "That’s the whole flow." : finalSummary, guideID: guide.id)
    }

    private func teardown(_ scope: GuideWorkerSession?) {
        scope?.closeAndCancel()
        clickObserver.stop()
        activeGuideStepID = nil
        everythingGuideSession = nil
        hideGuideControls()
    }

    private func hideGuideControls() {
        guideVoiceCommands.stop()
        guideControlsWindow?.orderOut(nil)
        guideControlsWindow = nil
        guideControlsState.reset()
        guideStepPosition = 0
    }

    private func perform(onStart: () -> Void = {}, _ operation: @escaping @MainActor (GuideEngine) async -> AdvanceResult) {
        guard let guideID = activeGuideID, let scope = currentGuideScope, let engine = scope.engine else { return }
        let started = scope.startAction { [weak self] in
            let result = await operation(engine)
            guard !Task.isCancelled, let self, self.guideIsCurrent(guideID) else { return }
            self.handleGuideResult(result, guideID: guideID)
        }
        if started { onStart() }
    }

    private func skipGuideStep() {
        perform { await $0.skip() }
    }

    private func goBackGuideStep() {
        perform { await $0.back() }
    }

    private func repointGuideStep() {
        guard let guideID = activeGuideID, let scope = currentGuideScope, let engine = scope.engine else { return }
        scope.startAction { [weak self] in
            do {
                guard let presentation = try await engine.refreshPresentation(force: true) else { return }
                guard !Task.isCancelled, let self, self.guideIsCurrent(guideID) else { return }
                self.output?.guidePresent(presentation)
                self.output?.guideSetStatus("Found it again.")
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.guideIsCurrent(guideID) else { return }
                self.finishGuide(guideID: guideID, outcome: .failed, summary: "I couldn’t read that window again. Try again.")
            }
        }
    }

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

    private func handleSessionClick(_ axPoint: CGPointShim) {
        guard activeGuideID != nil else { return }
        let clickPoint = AXCoordinateConverter.appKitPoint(of: axPoint)
        let interactiveFrames = ([guideControlsWindow?.frame] + (output?.guideInteractiveFrames() ?? []))
            .compactMap { $0 }
        if interactiveFrames.contains(where: { $0.contains(clickPoint) }) || selectMarker(at: axPoint) {
            return
        }
        perform(onStart: { PerfMark.mark("guide.click") }) { await $0.acceptClick(at: axPoint) }
    }

    private func handleGuideResult(_ result: AdvanceResult, guideID: UUID) {
        guard guideIsCurrent(guideID) else { return }
        switch result {
        case .advanced(let step, _):
            guideStepPosition += 1
            show(step, guideID: guideID)
        case .wentBack(let step, _):
            guideStepPosition = max(1, guideStepPosition - 1)
            show(step, guideID: guideID)
        case .finished:
            finishGuide(guideID: guideID, outcome: .completed)
        case .explanationEnded:
            finishGuide(guideID: guideID, outcome: .stopped, summary: "I finished explaining. I didn’t check that the task is done.")
        case .needsInput(let prompt, let choices):
            presentGuideInput(guideID: guideID, prompt: prompt, choices: choices)
        case .stillWaiting:
            output?.guideSetStatus("I can’t see that step done yet. Finish it, then choose Done.")
        case .blocked(let reason):
            finishGuide(guideID: guideID, outcome: .failed, summary: reason)
        case .ignoredClick(_, let hitLabel):
            PerfMark.mark("guide.click.ignored")
            if let hitLabel, !hitLabel.isEmpty {
                output?.guideSetStatus("That’s \(hitLabel). Click the highlighted control instead.")
                speak("That’s \(hitLabel). Try the highlighted one.", guideID: guideID, stepID: activeGuideStepID)
            } else {
                output?.guideSetStatus("Not quite. Click the highlighted control.")
            }
        case .notPresenting:
            break
        }
    }

    private func show(_ step: GuideStep, guideID: UUID) {
        present(step: step)
        speak(step.instruction, guideID: guideID, stepID: step.id)
        if !step.waitForUserAction { scheduleExplanationEnd() }
    }

    private func presentGuideInput(guideID: UUID, prompt: String, choices: [String]) {
        guideControlsState.pendingPrompt = prompt
        guideControlsState.pendingChoices = choices
        output?.guideSetStatus(prompt)
        speak(prompt, guideID: guideID)
        showGuideControls()
    }

    private func scheduleGuideRepoint() {
        guard let engine = currentGuideScope?.engine else { return }
        schedule(.repoint, after: .seconds(90)) { coordinator, guideID in
            do {
                guard let presentation = try await engine.refreshPresentation() else { return }
                guard coordinator.activeGuideID == guideID else { return }
                coordinator.output?.guidePresent(presentation)
                coordinator.output?.guideSetStatus("I looked again after a quiet minute.")
                coordinator.speak("I’ll try that step again.", guideID: guideID, stepID: coordinator.activeGuideStepID)
            } catch {
                coordinator.finishGuide(guideID: guideID, outcome: .failed, summary: "I couldn’t read that window again. Try again.")
            }
        }
    }

    private func scheduleExplanationEnd() {
        schedule(.finish, after: .seconds(1.5)) { coordinator, guideID in
            coordinator.finishGuide(guideID: guideID, outcome: .stopped, summary: "I finished explaining. I didn’t check that the task is done.")
        }
    }

    private func beginInvokingIfNeeded(attemptID: UUID) -> Bool {
        switch sessionController.state {
        case .idle: transitionSession { try sessionController.wake(attemptID: attemptID) }
        case .invoking(let invocation): invocation.id == attemptID
        default: false
        }
    }

    private func startGuideSession(goal: String, full: Bool, threadID: UUID, targetHint: CuaTargetHint?, attemptID: UUID, waitingInput: PerryThread.WaitingInput?) -> GuideWorkerSession? {
        guard guideAdmissionOpen, case .invoking(let invocation) = sessionController.state,
              invocation.id == attemptID else { return nil }
        output?.guideSetStatus(full ? "Showing the full path." : "Finding two places to show you.")
        output?.guideStopSpatialInput()
        let targetHint = targetHint ?? context?.guideTargetHint() ?? CuaTargetHint(bundleID: nil, processID: nil, windowTitle: nil)
        let appBundleID = context?.guideAppBundleID(for: targetHint)
        let guide = GuideSessionState(id: waitingInput?.id ?? UUID(), threadID: threadID, goal: goal, startedAt: Date(), appBundleID: appBundleID)
        guard transitionSession({ try sessionController.startGuide(guide, attemptID: attemptID) }) else { return nil }
        let scope = GuideWorkerSession(id: guide.id)
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
                    scope.isFinished = true
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
                    scope.isFinished = true
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
            await waitForScopeCompletion(guideScopes.values.filter { $0 !== scope })
            try await workers.withWorker(scope: .guide, resources: []) { @MainActor worker in
                scope.workerBodyActive = true
                do {
                    let engine = GuideEngine(
                        planner: self.makeGuidePlanner(for: guide),
                        observer: CuaGuideTreeReader(worker: worker, targetStore: scope.targetStore)
                    )
                    if self.guideScopes[scope.id] === scope {
                        scope.bind(engine: engine)
                    }
                    await scope.targetStore.set(targetHint)
                    guard self.guideIsCurrent(guide.id) else { return }
                    try Task.checkCancellation()
                    if full {
                        let capture: CuaCapturedWindow
                        if let loader = self.fullGuideCaptureLoader {
                            capture = try await loader(worker, targetHint)
                        } else {
                            capture = try await worker.capture(target: targetHint)
                        }
                        try await self.runFullGuide(guide: guide, capture: capture)
                    } else {
                        try await self.runTwoStepGuide(guide: guide, engine: engine)
                    }
                    for await _ in scope.finishStream { break }
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError) else { return }
                    switch error {
                    case GuidePlannerError.protectedWindow:
                        self.finishGuide(guideID: guide.id, outcome: .failed, summary: "That window is protected, so I can’t guide inside it.")
                    case GuidePlannerError.explanationEnded:
                        self.finishGuide(guideID: guide.id, outcome: .stopped, summary: "I finished explaining. I didn’t check that the task is done.")
                    case GuidePlannerError.needsInput(let prompt, let choices):
                        self.presentGuideInput(guideID: guide.id, prompt: prompt, choices: choices)
                        for await _ in scope.finishStream { break }
                    default:
                        self.finishGuide(
                            guideID: guide.id, outcome: .failed,
                            summary: full ? "I couldn’t prepare the guide. Try again." : "I couldn’t continue the guide. Try again."
                        )
                    }
                }
            }
            if !guideIsCurrent(guide.id) {
                scope.finishContinuation.finish()
            }
        } catch is CancellationError {
            resetGuideAfterWorkerFailure(guideID: guide.id, summary: "The guide stopped before it finished.")
        } catch {
            let message = "I couldn’t start the guide. Try again."
            scope.conversationOutcome = (message, .failed(message))
            resetGuideAfterWorkerFailure(guideID: guide.id, summary: message)
        }
        await closeGuideScope(scope)
        return scope.conversationOutcome ?? ("Guide stopped before it finished.", .interrupted)
    }

    private func runTwoStepGuide(guide: GuideSessionState, engine: GuideEngine) async throws {
        let guideContext = await planningContext(appBundleID: guide.appBundleID)
        guard guideIsCurrent(guide.id) else { return }
        let firstStep = try await engine.start(goal: guide.goal, maximumSteps: 25, context: guideContext)
        guard guideIsCurrent(guide.id) else { return }
        guard let firstStep else {
            finishGuide(guideID: guide.id, outcome: .failed, summary: "I couldn’t see anything to point at.")
            return
        }
        clickObserver.start()
        scheduleGuideRepoint()
        guideStepPosition = 1
        show(firstStep, guideID: guide.id)
    }

    private func resetGuideAfterWorkerFailure(guideID: UUID, summary: String) {
        guard guideIsCurrent(guideID) else { return }
        let scope = currentGuideScope
        scope?.workerBodyActive = false
        teardown(scope)
        scope?.finishContinuation.finish()
        _ = sessionController.requestDismissal()
        output?.guideSetStatus(summary)
        output?.guideClearPresentation()
    }

    private func closeGuideScope(_ scope: GuideWorkerSession) async {
        scope.closeAndCancel()
        if currentGuideScope === scope {
            clickObserver.stop()
        }
        await scope.drain()
        finalizer.schedule(for: scope)
        await scope.finalizationTask?.value
        await scope.engine?.stop()
        scope.workerBodyActive = false
    }

    private func clearGuideScope(_ scope: GuideWorkerSession) {
        guideScopes[scope.id] = nil
        if currentGuideScopeID == scope.id {
            currentGuideScopeID = nil
        }
    }

    private func waitForScopeCompletion(_ scopes: [GuideWorkerSession]) async {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while scopes.contains(where: { !$0.isFinished }), ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
        }
    }
}
