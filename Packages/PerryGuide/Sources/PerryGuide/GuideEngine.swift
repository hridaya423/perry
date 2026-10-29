import Foundation
import PerryCore

/// Receding-horizon guide engine. There is no upfront plan: after every
/// verified user action the engine re-observes the live window and asks the
/// planner for the next single step, so each instruction is grounded in the
/// UI the user actually sees. Every planner-produced step is validated
/// against the observation before it is presented.
public actor GuideEngine {
    public enum Phase: Equatable, Sendable {
        case idle
        case presenting(stepIndex: Int)
        case waitingForUser(stepIndex: Int)
        case finished
    }

    private let planner: GuidePlanner
    private let observer: GuideObserving
    private let clickMatcher: ClickAdvanceMatcher
    private(set) public var phase: Phase
    private(set) public var progress = GuideProgress()
    /// Every step the user was shown, in order — Back re-presents the
    /// previous one rather than asking the planner for it again.
    private var presentedSteps: [(step: GuideStep, snapshot: AXSnapshot)] = []

    /// True once a second presented step exists to go back to.
    public var canGoBack: Bool {
        currentStepIndex != nil && presentedSteps.count >= 2
    }
    private var currentStep: GuideStep?
    private var presentationObservation: GuideObservation?
    private var actionBaseline: GuideObservation?
    private var hasRepointed = false
    private var goal = ""
    private var context: GuideContext = .empty
    /// The user's answer to a `needsInput` question — merged into the next
    /// planner call only, then cleared so a later question can't silently
    /// reuse it.
    private var inputAnswer: String?
    private var maximumSteps: Int?
    /// The seeded horizon: steps the planner predicted up front. Consumed
    /// while each target still validates against the live window; the first
    /// deviation discards the rest and falls back to a live replan.
    private var plannedSteps: [GuideStep] = []
    private var plannedFrom: AXSnapshot?

    public init(
        planner: GuidePlanner,
        observer: GuideObserving,
        clickMatcher: ClickAdvanceMatcher = ClickAdvanceMatcher()
    ) {
        self.planner = planner
        self.observer = observer
        self.clickMatcher = clickMatcher
        self.phase = .idle
    }

    /// Starts the dynamic loop: observe, ask the planner for one step, present
    /// it. `maximumSteps` bounds the whole session, not a prefix of a plan.
    public func start(goal: String, maximumSteps: Int? = nil, context: GuideContext = .empty) async throws -> GuideStep? {
        reset(goal: goal, context: context, maximumSteps: maximumSteps)
        let observation = try await observer.observe()
        // Seed the horizon with one plan call; each later step validates
        // against the live window instead of paying a planner round-trip.
        plannedSteps = (try? await planner.visiblePath(goal: goal, observation: observation, context: context)) ?? []
        plannedFrom = observation.snapshot
        guard let (step, planned) = try await nextValidStep(observation: observation) else {
            phase = .finished
            return nil
        }
        present(step, observation: planned)
        return step
    }

    /// Enters the loop at a marker selected from the visible path. Steps
    /// before the selected one were seen on the map, so they count toward the
    /// bound and are never re-suggested.
    public func start(
        goal: String,
        observation: GuideObservation,
        steps: [GuideStep],
        selectedIndex: Int,
        maximumSteps: Int? = nil,
        context: GuideContext = .empty
    ) throws -> GuideStep? {
        reset(goal: goal, context: context, maximumSteps: maximumSteps)
        guard steps.indices.contains(selectedIndex) else {
            throw GuidePlannerError.malformedResponse("selected guide step is unavailable")
        }
        try GuideTargetValidator.requireUnprotected(observation)
        for prior in steps[..<selectedIndex] {
            progress.recordSkipped(prior)
        }
        // The map's remaining steps are the seeded horizon — same plan, no
        // extra planner call when the user picks up mid-path.
        plannedSteps = Array(steps.dropFirst(selectedIndex + 1))
        plannedFrom = observation.snapshot
        let step = try GuideTargetValidator.validated(steps[selectedIndex], in: observation)
        present(step, observation: observation)
        return step
    }

    public func currentPresentation() -> GuidePresentation? {
        guard let step = currentStep,
              let observation = presentationObservation,
              currentStepIndex != nil else { return nil }
        let target: AXElement?
        if case .axElement(let stableID) = step.target {
            target = observation.snapshot.element(withStableID: stableID)
        } else {
            target = nil
        }
        return GuidePresentation(step: step, target: target, snapshot: observation.snapshot)
    }

    /// Re-observes once to repoint the current step's target. A stale target
    /// is re-located by stable ID; it is never executed, so a moved window
    /// simply re-paints the highlight at its new frame. `force` is for an
    /// explicit user Re-point request; the automatic quiet-minute repoint
    /// stays one-shot.
    public func refreshPresentation(force: Bool = false) async throws -> GuidePresentation? {
        guard let step = currentStep, let baseline = presentationObservation else { return nil }
        guard !hasRepointed || force else { return currentPresentation() }
        hasRepointed = true
        let observation = try await observer.observe()
        try GuideTargetValidator.requireUnprotected(observation)
        try requireSameTarget(observation, as: baseline, allowsNewWindow: step.opensWindow)
        let rebound = try GuideTargetValidator.validated(step.rebound(from: baseline.snapshot, to: observation.snapshot), in: observation)
        currentStep = rebound
        presentedSteps[presentedSteps.count - 1] = (rebound, observation.snapshot)
        presentationObservation = observation
        actionBaseline = observation
        return currentPresentation()
    }

    public func acceptClick(at point: CGPointShim) async -> AdvanceResult {
        guard let step = currentStep,
              let presentation = presentationObservation,
              let actionBaseline,
              let index = currentStepIndex else {
            return .notPresenting
        }
        let outcome = clickMatcher.outcome(
            clickPoint: point,
            target: step.target,
            elements: presentation.snapshot.elements
        )
        guard case .hit = outcome else {
            let targetID: String?
            if case .axElement(let stableID) = step.target { targetID = stableID } else { targetID = nil }
            let hitLabel = clickMatcher.elementUnder(
                clickPoint: point,
                elements: presentation.snapshot.elements,
                excluding: targetID
            )?.label
            return .ignoredClick(stepIndex: index, hitLabel: hitLabel)
        }
        return await verifyAndAdvance(step: step, baseline: actionBaseline, stepIndex: index)
    }

    public func userActed() async -> AdvanceResult {
        guard let step = currentStep,
              let actionBaseline,
              let index = currentStepIndex else {
            return .notPresenting
        }
        return await verifyAndAdvance(step: step, baseline: actionBaseline, stepIndex: index, userConfirmed: true)
    }

    public func skip() async -> AdvanceResult {
        guard let step = currentStep, currentStepIndex != nil else {
            return .notPresenting
        }
        progress.recordSkipped(step)
        plannedSteps = []
        let observation: GuideObservation
        do {
            observation = try await observer.observe()
        } catch is CancellationError {
            return .notPresenting
        } catch {
            phase = .waitingForUser(stepIndex: progress.presentedCount - 1)
            return .blocked(reason: "I couldn’t read the window for the next step.")
        }
        return await presentNext(observation: observation)
    }

    /// Re-present the previous presented step ("Back") so the user can see
    /// its instruction again. The current step is unpresented — it counts
    /// neither toward the step bound nor the completed history — and the
    /// previous step's target is re-validated against a fresh observation
    /// so a moved or changed window never re-shows a stale mark.
    public func back() async -> AdvanceResult {
        guard currentStepIndex != nil, presentedSteps.count >= 2 else {
            return .notPresenting
        }
        let (planned, plannedAgainst) = presentedSteps[presentedSteps.count - 2]
        let observation: GuideObservation
        do {
            observation = try await observer.observe()
        } catch is CancellationError {
            return .notPresenting
        } catch {
            phase = .waitingForUser(stepIndex: progress.presentedCount - 1)
            return .blocked(reason: "I couldn’t read the window to go back.")
        }
        let previous: GuideStep
        do {
            try GuideTargetValidator.requireUnprotected(observation)
            if let baseline = presentationObservation {
                try requireSameTarget(observation, as: baseline)
            }
            previous = try GuideTargetValidator.validated(planned.rebound(from: plannedAgainst, to: observation.snapshot), in: observation)
        } catch is CancellationError {
            return .notPresenting
        } catch {
            phase = .waitingForUser(stepIndex: progress.presentedCount - 1)
            return .blocked(reason: error.localizedDescription)
        }
        presentedSteps.removeLast()
        presentedSteps[presentedSteps.count - 1] = (previous, observation.snapshot)
        progress.recordUnpresented()
        currentStep = previous
        presentationObservation = observation
        actionBaseline = observation
        hasRepointed = false
        phase = .presenting(stepIndex: progress.presentedCount - 1)
        return .wentBack(toStep: previous, stepIndex: progress.presentedCount - 1)
    }

    /// Continues after a planner `needsInput` pause: the chosen answer joins
    /// the next planner call alongside a fresh observation. `.idle` is
    /// accepted because a `needsInput` during `start` throws before any step
    /// is presented; an idle engine that never started has no goal and is
    /// rejected.
    public func resume(withAnswer answer: String) async -> AdvanceResult {
        guard !goal.isEmpty else { return .notPresenting }
        switch phase {
        case .idle, .waitingForUser:
            break
        default:
            return .notPresenting
        }
        inputAnswer = answer
        plannedSteps = []
        let observation: GuideObservation
        do {
            observation = try await observer.observe()
        } catch is CancellationError {
            return .notPresenting
        } catch {
            phase = .waitingForUser(stepIndex: progress.presentedCount - 1)
            return .blocked(reason: "I couldn’t read the window to continue.")
        }
        return await presentNext(observation: observation)
    }

    public func stop() {
        phase = .idle
        currentStep = nil
        presentationObservation = nil
        actionBaseline = nil
        progress = GuideProgress()
        hasRepointed = false
        inputAnswer = nil
        plannedSteps = []
        plannedFrom = nil
    }

    private func reset(goal: String, context: GuideContext, maximumSteps: Int?) {
        phase = .idle
        self.goal = goal
        self.context = context
        self.maximumSteps = maximumSteps
        currentStep = nil
        presentationObservation = nil
        actionBaseline = nil
        progress = GuideProgress()
        hasRepointed = false
        inputAnswer = nil
        plannedSteps = []
        plannedFrom = nil
        presentedSteps = []
    }

    private var currentStepIndex: Int? {
        switch phase {
        case .presenting(let index), .waitingForUser(let index): return index
        default: return nil
        }
    }

    /// How long the first wait listens for the action's UI effect. When
    /// nothing ever signals, verification costs no more than the legacy poll.
    private static let firstSignalWindow: Duration = .milliseconds(500)
    /// Total window a postcondition may take to become true. Signals that
    /// keep arriving reopen the read inside this bound — never beyond it.
    private static let verificationWindow: Duration = .milliseconds(1500)
    /// Each signaled wake re-reads the AX tree; the cap keeps a chatty app
    /// from turning verification into a capture storm.
    private static let maxVerificationReads = 4

    /// Event-driven verification: the observer waits on AX change signals
    /// rather than a fixed timer, and each wake re-reads only the element
    /// index — postcondition checks never need another screen capture.
    private func verifyAndAdvance(step: GuideStep, baseline: GuideObservation, stepIndex: Int, userConfirmed: Bool = false) async -> AdvanceResult {
        let deadline = ContinuousClock.now.advanced(by: Self.verificationWindow)
        var reads = 0
        while true {
            let observation: GuideObservation
            do {
                try Task.checkCancellation()
                let remaining = deadline - ContinuousClock.now
                if reads > 0, remaining <= .zero { break }
                // A signal wait only pays off when a postcondition needs
                // time to become true. Explicit confirms and postcondition-
                // less clicks have nothing to wait for — read immediately
                // instead of paying the first-signal window as dead time.
                let nothingToWaitFor = userConfirmed || step.postcondition == nil
                let window = reads == 0 ? (nothingToWaitFor ? .zero : min(remaining, Self.firstSignalWindow)) : remaining
                let signaled = await observer.awaitUIChange(within: max(window, .zero))
                // A deadline without a signal means the UI went quiet — the
                // last read's verdict stands rather than paying another.
                if reads > 0, !signaled { break }
                // A postconditionless click on the target counts as the user
                // doing the step — the element payload is never consulted, so
                // probe identity instead of paying for the full AX walk.
                observation = step.postcondition == nil && !userConfirmed
                    ? try await observer.probeTarget()
                    : try await observer.observeElements()
                try GuideTargetValidator.requireUnprotected(observation)
                try requireSameTarget(observation, as: baseline, allowsNewWindow: step.opensWindow)
            } catch is CancellationError {
                return .notPresenting
            } catch {
                phase = .waitingForUser(stepIndex: stepIndex)
                return .blocked(reason: "I couldn’t confirm that step.")
            }
            // stop()/skip() can interleave across the suspensions — a stale
            // verification must never advance past a step that's gone.
            guard currentStep?.id == step.id else { return .notPresenting }
            reads += 1
            guard let postcondition = step.postcondition else {
                progress.recordUserConfirmed(step)
                return await presentNext(observation: observation, allowsNewWindow: step.opensWindow)
            }
            let proof = postcondition.rebound(from: baseline.snapshot, to: observation.snapshot)
            if proof.isSatisfied(in: observation.snapshot) {
                if postcondition.isSatisfied(in: baseline.snapshot) {
                    progress.recordUserConfirmed(step)
                } else {
                    progress.recordCompleted(step)
                }
                return await presentNext(observation: observation, allowsNewWindow: step.opensWindow)
            }
            if userConfirmed || proof.citesVanishedElement || Self.clickedControlChanged(step, from: baseline.snapshot, to: observation.snapshot) {
                progress.recordUserConfirmed(step)
                return await presentNext(observation: observation, allowsNewWindow: step.opensWindow)
            }
            if reads >= Self.maxVerificationReads {
                phase = .waitingForUser(stepIndex: stepIndex)
                return .stillWaiting(stepIndex: stepIndex)
            }
        }
        phase = .waitingForUser(stepIndex: stepIndex)
        return .stillWaiting(stepIndex: stepIndex)
    }

    /// The control the user clicked vanished, changed in place, or opened
    /// its menu, so the click took effect even when the planner's proof
    /// cannot be read.
    static func clickedControlChanged(_ step: GuideStep, from before: AXSnapshot, to after: AXSnapshot) -> Bool {
        guard case .axElement(let id) = step.target, let clicked = before.element(withStableID: id) else { return false }
        if clicked.role == .menu, !before.elements.contains(where: { $0.role == .menuItem }),
           after.elements.contains(where: { $0.role == .menuItem }) {
            return true
        }
        guard let now = after.elements.counterpart(of: clicked, relabeled: true) else { return true }
        return now.label != clicked.label || now.value != clicked.value
    }

    /// Asks the planner for the next step from this observation, validates it,
    /// and presents it — or finishes when the planner has nothing honest left.
    /// Planner and validation failures surface as blocked, never as a silent
    /// success.
    private func presentNext(observation: GuideObservation, allowsNewWindow: Bool = false) async -> AdvanceResult {
        do {
            let observation = try await planningObservation(observation)
            guard let (step, planned) = try await nextValidStep(observation: observation, allowsNewWindow: allowsNewWindow) else {
                phase = .finished
                return .finished
            }
            present(step, observation: planned)
            return .advanced(toStep: step, stepIndex: progress.presentedCount - 1)
        } catch GuidePlannerError.explanationEnded {
            phase = .finished
            return .explanationEnded
        } catch GuidePlannerError.needsInput(let prompt, let choices) {
            phase = .waitingForUser(stepIndex: progress.presentedCount - 1)
            return .needsInput(prompt: prompt, choices: choices)
        } catch is CancellationError {
            return .notPresenting
        } catch {
            phase = .waitingForUser(stepIndex: progress.presentedCount - 1)
            return .blocked(reason: error.localizedDescription)
        }
    }

    private func planningObservation(_ observation: GuideObservation) async throws -> GuideObservation {
        guard observation.screenshotData == nil,
              plannedSteps.isEmpty || observation.snapshot.elements.isEmpty else { return observation }
        return try await observer.observe()
    }

    /// Planner call wrapped in the trust boundary: protected observations and
    /// targets that don't validate against the live window both throw.
    private func nextValidStep(observation: GuideObservation, allowsNewWindow: Bool = false) async throws -> (GuideStep, GuideObservation)? {
        var observation = observation
        try GuideTargetValidator.requireUnprotected(observation)
        if let baseline = presentationObservation {
            try requireSameTarget(observation, as: baseline, allowsNewWindow: allowsNewWindow)
        }
        if let maximumSteps, progress.presentedCount >= maximumSteps {
            throw GuidePlannerError.blocked("The guide stopped at its step limit. Perry didn’t check that the task is done.")
        }
        try Task.checkCancellation()
        // The input answer is consumed once: it answers the question it was
        // given for, then leaves the context so a later unrelated question
        // can't silently reuse it.
        let answer = inputAnswer
        inputAnswer = nil
        if !plannedSteps.isEmpty {
            let planned = plannedSteps.removeFirst()
            let candidate = plannedFrom.map { planned.rebound(from: $0, to: observation.snapshot) } ?? planned
            // Mid-run, a planned step that no longer grounds is a deviation:
            // drop the stale horizon and replan. At session start there is no
            // prior state to deviate from — a bad first step is the planner's
            // own output and surfaces instead of being silently retried.
            if presentationObservation != nil {
                if let validated = try? GuideTargetValidator.validated(candidate, in: observation) {
                    return (validated, observation)
                }
                plannedSteps = []
                if observation.screenshotData == nil {
                    observation = try await observer.observe()
                    try GuideTargetValidator.requireUnprotected(observation)
                    if let baseline = presentationObservation {
                        try requireSameTarget(observation, as: baseline, allowsNewWindow: allowsNewWindow)
                    }
                }
            } else {
                return (try GuideTargetValidator.validated(candidate, in: observation), observation)
            }
        }
        let decision = try await planner.nextStep(
            goal: goal,
            observation: observation,
            progress: progress,
            context: GuideContext(
                spatialRegionDescription: context.spatialRegionDescription,
                memoryContext: context.memoryContext,
                goalPostcondition: context.goalPostcondition,
                inputAnswer: answer
            )
        )
        try Task.checkCancellation()
        switch decision {
        case .step(let step): return (try GuideTargetValidator.validated(step, in: observation), observation)
        case .complete(evidence: .explanationOnly): throw GuidePlannerError.explanationEnded
        case .complete(evidence: .observedGoal(let condition)):
            guard context.goalPostcondition == condition, condition.isSatisfied(in: observation.snapshot) else {
                throw GuidePlannerError.blocked("Perry couldn’t confirm the task finished the way you asked.")
            }
            return nil
        case .blocked(let reason): throw GuidePlannerError.blocked(reason)
        case .needsInput(let prompt, let choices): throw GuidePlannerError.needsInput(prompt: prompt, choices: choices)
        }
    }

    private func present(_ step: GuideStep, observation: GuideObservation) {
        currentStep = step
        presentationObservation = observation
        actionBaseline = observation
        presentedSteps.append((step, observation.snapshot))
        progress.recordPresented()
        phase = .presenting(stepIndex: progress.presentedCount - 1)
    }

    /// Same app, same live window — unless the presented step predicted a new
    /// window (`opensWindow`), in which case a different windowID under the
    /// same pid/bundle/generation is the expected outcome, not a violation.
    /// Window identity is carried by pid + CGWindowID + bundle — all stable
    /// across a driver respawn. Connection generation is deliberately not
    /// compared: element tokens are only resolved inside the observation that
    /// produced them, so a restarted driver can never smuggle stale tokens
    /// into a click, and blocking on generation would kill every guide the
    /// moment the driver reconnects under a window that never moved.
    private func requireSameTarget(_ observation: GuideObservation, as baseline: GuideObservation, allowsNewWindow: Bool = false) throws {
        guard let processID = baseline.processID,
              let windowID = baseline.windowID,
              observation.snapshot.appBundleID == baseline.snapshot.appBundleID,
              observation.processID == processID,
              observation.windowID != nil,
              allowsNewWindow || observation.windowID == windowID else {
            throw GuidePlannerError.blocked("The target window changed or its identity is unavailable. Start a new guide.")
        }
    }

}

public struct GuidePresentation: Equatable, Sendable {
    public let step: GuideStep
    public let target: AXElement?
    public let snapshot: AXSnapshot

    public init(step: GuideStep, target: AXElement?, snapshot: AXSnapshot) {
        self.step = step
        self.target = target
        self.snapshot = snapshot
    }
}

public enum AdvanceResult: Equatable, Sendable {
    case advanced(toStep: GuideStep, stepIndex: Int)
    case wentBack(toStep: GuideStep, stepIndex: Int)
    case stillWaiting(stepIndex: Int)
    case ignoredClick(stepIndex: Int, hitLabel: String? = nil)
    case blocked(reason: String)
    case finished
    case explanationEnded
    case needsInput(prompt: String, choices: [String])
    case notPresenting
}
