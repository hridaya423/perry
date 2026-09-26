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
        guard let step = try await nextValidStep(observation: observation) else {
            phase = .finished
            return nil
        }
        present(step, observation: observation)
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
        try requireSameTarget(observation, as: baseline)
        try GuideTargetValidator.validated(step, in: observation)
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
        let observation: GuideObservation
        do {
            observation = try await observer.observe()
        } catch is CancellationError {
            return .notPresenting
        } catch {
            phase = .waitingForUser(stepIndex: progress.presentedCount - 1)
            return .blocked(reason: "Cua could not read the window for the next step: \(error.localizedDescription)")
        }
        return await presentNext(observation: observation)
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
        let observation: GuideObservation
        do {
            observation = try await observer.observe()
        } catch is CancellationError {
            return .notPresenting
        } catch {
            phase = .waitingForUser(stepIndex: progress.presentedCount - 1)
            return .blocked(reason: "Cua could not read the window to continue: \(error.localizedDescription)")
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
    }

    private var currentStepIndex: Int? {
        switch phase {
        case .presenting(let index), .waitingForUser(let index): return index
        default: return nil
        }
    }

    private func verifyAndAdvance(step: GuideStep, baseline: GuideObservation, stepIndex: Int, userConfirmed: Bool = false) async -> AdvanceResult {
        let after: GuideObservation
        do {
            try await Task.sleep(nanoseconds: 250_000_000)
            after = try await observer.observe()
            try GuideTargetValidator.requireUnprotected(after)
            try requireSameTarget(after, as: baseline)
        } catch is CancellationError {
            return .notPresenting
        } catch {
            phase = .waitingForUser(stepIndex: stepIndex)
            return .blocked(reason: "Cua could not verify that step: \(error.localizedDescription)")
        }
        if let postcondition = step.postcondition {
            guard postcondition.isSatisfied(in: after.snapshot) else {
                phase = .waitingForUser(stepIndex: stepIndex)
                return .stillWaiting(stepIndex: stepIndex)
            }
            progress.recordCompleted(step)
        } else {
            guard userConfirmed else {
                phase = .waitingForUser(stepIndex: stepIndex)
                return .stillWaiting(stepIndex: stepIndex)
            }
            progress.recordUserConfirmed(step)
        }
        return await presentNext(observation: after)
    }

    /// Asks the planner for the next step from this observation, validates it,
    /// and presents it — or finishes when the planner has nothing honest left.
    /// Planner and validation failures surface as blocked, never as a silent
    /// success.
    private func presentNext(observation: GuideObservation) async -> AdvanceResult {
        do {
            guard let step = try await nextValidStep(observation: observation) else {
                phase = .finished
                return .finished
            }
            present(step, observation: observation)
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

    /// Planner call wrapped in the trust boundary: protected observations and
    /// targets that don't validate against the live window both throw.
    private func nextValidStep(observation: GuideObservation) async throws -> GuideStep? {
        try GuideTargetValidator.requireUnprotected(observation)
        if let baseline = presentationObservation { try requireSameTarget(observation, as: baseline) }
        if let maximumSteps, progress.presentedCount >= maximumSteps {
            throw GuidePlannerError.blocked("The guide reached its step limit. Goal completion has not been verified.")
        }
        try Task.checkCancellation()
        // The input answer is consumed once: it answers the question it was
        // given for, then leaves the context so a later unrelated question
        // can't silently reuse it.
        let answer = inputAnswer
        inputAnswer = nil
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
        case .step(let step): return try GuideTargetValidator.validated(step, in: observation)
        case .complete(evidence: .explanationOnly): throw GuidePlannerError.explanationEnded
        case .complete(evidence: .observedGoal(let condition)):
            guard context.goalPostcondition == condition, condition.isSatisfied(in: observation.snapshot) else {
                throw GuidePlannerError.blocked("Goal completion could not be verified against the requested outcome.")
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
        progress.recordPresented()
        phase = .presenting(stepIndex: progress.presentedCount - 1)
    }

    private func requireSameTarget(_ observation: GuideObservation, as baseline: GuideObservation) throws {
        guard let processID = baseline.processID,
              let windowID = baseline.windowID,
              let generation = baseline.connectionGeneration,
              observation.snapshot.appBundleID == baseline.snapshot.appBundleID,
              observation.processID == processID,
              observation.windowID == windowID,
              observation.connectionGeneration == generation else {
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
    case stillWaiting(stepIndex: Int)
    case ignoredClick(stepIndex: Int, hitLabel: String? = nil)
    case blocked(reason: String)
    case finished
    case explanationEnded
    case needsInput(prompt: String, choices: [String])
    case notPresenting
}
