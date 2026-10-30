import Foundation
import PerryCore

/// Receding-horizon guide engine: after each verified user action it re-observes the live window and asks the planner for the next single step.
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
    private var presentedSteps: [(step: GuideStep, snapshot: AXSnapshot)] = []

    public var canGoBack: Bool {
        currentStepIndex != nil && presentedSteps.count >= 2
    }
    private var currentStep: GuideStep?
    private var presentationObservation: GuideObservation?
    private var actionBaseline: GuideObservation?
    private var hasRepointed = false
    private var goal = ""
    private var context: GuideContext = .empty
    private var inputAnswer: String?
    private var maximumSteps: Int?
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

    /// Observes, asks the planner for one step, and presents it. `maximumSteps` bounds the whole session.
    public func start(goal: String, maximumSteps: Int? = nil, context: GuideContext = .empty) async throws -> GuideStep? {
        reset(goal: goal, context: context, maximumSteps: maximumSteps)
        let observation = try await observer.observe()
        plannedSteps = (try? await planner.visiblePath(goal: goal, observation: observation, context: context)) ?? []
        plannedFrom = observation.snapshot
        guard let (step, planned) = try await nextValidStep(observation: observation) else {
            phase = .finished
            return nil
        }
        present(step, observation: planned)
        return step
    }

    /// Enters the loop at a marker chosen from the visible path; earlier steps count toward the bound and are never re-suggested.
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

    /// Re-observes to repoint the current step's target. `force` is for an explicit user request; the automatic repoint is one-shot.
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

    /// Re-presents the previous step against a fresh observation; the current step is unpresented.
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

    /// Continues after a `needsInput` pause with the user's answer.
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
        stop()
        self.goal = goal
        self.context = context
        self.maximumSteps = maximumSteps
        presentedSteps = []
    }

    private var currentStepIndex: Int? {
        switch phase {
        case .presenting(let index), .waitingForUser(let index): return index
        default: return nil
        }
    }

    private static let firstSignalWindow: Duration = .milliseconds(500)
    private static let verificationWindow: Duration = .milliseconds(1500)
    private static let maxVerificationReads = 4

    private func verifyAndAdvance(step: GuideStep, baseline: GuideObservation, stepIndex: Int, userConfirmed: Bool = false) async -> AdvanceResult {
        let deadline = ContinuousClock.now.advanced(by: Self.verificationWindow)
        var reads = 0
        while true {
            let observation: GuideObservation
            do {
                try Task.checkCancellation()
                let remaining = deadline - ContinuousClock.now
                if reads > 0, remaining <= .zero { break }
                let nothingToWaitFor = userConfirmed || step.postcondition == nil
                let window = reads == 0 ? (nothingToWaitFor ? .zero : min(remaining, Self.firstSignalWindow)) : remaining
                let signaled = await observer.awaitUIChange(within: max(window, .zero))
                if reads > 0, !signaled { break }
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

    static func clickedControlChanged(_ step: GuideStep, from before: AXSnapshot, to after: AXSnapshot) -> Bool {
        guard case .axElement(let id) = step.target, let clicked = before.element(withStableID: id) else { return false }
        if clicked.role == .menu, !before.elements.contains(where: { $0.role == .menuItem }),
           after.elements.contains(where: { $0.role == .menuItem }) {
            return true
        }
        guard let now = after.elements.counterpart(of: clicked, relabeled: true) else { return true }
        return now.label != clicked.label || now.value != clicked.value
    }

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
        let answer = inputAnswer
        inputAnswer = nil
        if !plannedSteps.isEmpty {
            let planned = plannedSteps.removeFirst()
            let candidate = plannedFrom.map { planned.rebound(from: $0, to: observation.snapshot) } ?? planned
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

    // Connection generation is not compared: element tokens only resolve inside the observation that produced them,
    // and comparing it would end every guide when the driver reconnects under an unmoved window.
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
