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
    private let changeDetector: ScreenChangeDetector
    private let clickMatcher: ClickAdvanceMatcher
    private(set) public var phase: Phase
    private(set) public var progress = GuideProgress()
    private var currentStep: GuideStep?
    private var presentationObservation: GuideObservation?
    private var actionBaseline: AXSnapshot?
    private var hasRepointed = false
    private var goal = ""
    private var context: GuideContext = .empty
    private var maximumSteps: Int?

    public init(
        planner: GuidePlanner,
        observer: GuideObserving,
        changeDetector: ScreenChangeDetector = ScreenChangeDetector(),
        clickMatcher: ClickAdvanceMatcher = ClickAdvanceMatcher()
    ) {
        self.planner = planner
        self.observer = observer
        self.changeDetector = changeDetector
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
            phase = .finished
            return nil
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
        guard currentStep != nil else { return nil }
        guard !hasRepointed || force else { return currentPresentation() }
        hasRepointed = true
        let observation = try await observer.observe()
        try GuideTargetValidator.requireUnprotected(observation)
        presentationObservation = observation
        actionBaseline = observation.snapshot
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
            return .ignoredClick(stepIndex: index)
        }
        return await verifyAndAdvance(step: step, baseline: actionBaseline, stepIndex: index)
    }

    public func userActed() async -> AdvanceResult {
        guard let step = currentStep,
              let actionBaseline,
              let index = currentStepIndex else {
            return .notPresenting
        }
        return await verifyAndAdvance(step: step, baseline: actionBaseline, stepIndex: index)
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

    public func stop() {
        phase = .idle
        currentStep = nil
        presentationObservation = nil
        actionBaseline = nil
        progress = GuideProgress()
        hasRepointed = false
    }

    private func reset(goal: String, context: GuideContext, maximumSteps: Int?) {
        self.goal = goal
        self.context = context
        self.maximumSteps = maximumSteps
        currentStep = nil
        presentationObservation = nil
        actionBaseline = nil
        progress = GuideProgress()
        hasRepointed = false
    }

    private var currentStepIndex: Int? {
        switch phase {
        case .presenting(let index), .waitingForUser(let index): return index
        default: return nil
        }
    }

    private func verifyAndAdvance(step: GuideStep, baseline: AXSnapshot, stepIndex: Int) async -> AdvanceResult {
        let after: GuideObservation
        do {
            try await Task.sleep(nanoseconds: 250_000_000)
            after = try await observer.observe()
        } catch is CancellationError {
            return .notPresenting
        } catch {
            phase = .waitingForUser(stepIndex: stepIndex)
            return .blocked(reason: "Cua could not verify that step: \(error.localizedDescription)")
        }
        guard isVerified(step: step, before: baseline, after: after.snapshot) else {
            phase = .waitingForUser(stepIndex: stepIndex)
            return .stillWaiting(stepIndex: stepIndex)
        }
        progress.recordCompleted(step)
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
        if let maximumSteps, progress.presentedCount >= maximumSteps { return nil }
        try Task.checkCancellation()
        try GuideTargetValidator.requireUnprotected(observation)
        guard let step = try await planner.nextStep(
            goal: goal,
            observation: observation,
            progress: progress,
            context: context
        ) else { return nil }
        return try GuideTargetValidator.validated(step, in: observation)
    }

    private func present(_ step: GuideStep, observation: GuideObservation) {
        currentStep = step
        presentationObservation = observation
        actionBaseline = observation.snapshot
        progress.recordPresented()
        phase = .presenting(stepIndex: progress.presentedCount - 1)
    }

    private func isVerified(step: GuideStep, before: AXSnapshot, after: AXSnapshot) -> Bool {
        if changeDetector.didChange(from: before, to: after) {
            return true
        }
        if changeDetector.didChange(from: before, titleAfter: after.windowTitle) {
            return true
        }
        if before.appBundleID != after.appBundleID {
            return true
        }
        return step.postcondition?.isSatisfied(in: after) == true
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
    case ignoredClick(stepIndex: Int)
    case blocked(reason: String)
    case finished
    case notPresenting
}
