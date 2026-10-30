import Foundation
import PerryCore
import PerryOverlay

extension AXSnapshot {
    func counterpartID(of id: String, from earlier: AXSnapshot, relabeled: Bool = false) -> String {
        guard element(withStableID: id) == nil, let original = earlier.element(withStableID: id) else { return id }
        return elements.counterpart(of: original, relabeled: relabeled)?.stableID ?? "gone:\(id)"
    }
}

extension GuideStep {
    func rebound(from earlier: AXSnapshot, to later: AXSnapshot) -> GuideStep {
        let target: Target
        if case .axElement(let id) = self.target {
            target = .axElement(stableID: later.counterpartID(of: id, from: earlier))
        } else {
            target = self.target
        }
        return GuideStep(
            id: id, instruction: instruction, target: target, waitForUserAction: waitForUserAction,
            postcondition: postcondition?.rebound(from: earlier, to: later), opensWindow: opensWindow
        )
    }
}

extension GuideStep.Postcondition {
    var citesVanishedElement: Bool {
        switch self {
        case .elementExists(let id), .elementLabelEquals(let id, _): return id.hasPrefix("gone:")
        case .elementAbsent, .windowTitleEquals: return false
        }
    }

    func rebound(from earlier: AXSnapshot, to later: AXSnapshot) -> Self {
        switch self {
        case .elementExists(let id): return .elementExists(stableID: later.counterpartID(of: id, from: earlier))
        case .elementAbsent(let id): return .elementAbsent(stableID: later.counterpartID(of: id, from: earlier))
        case .elementLabelEquals(let id, let label):
            return .elementLabelEquals(stableID: later.counterpartID(of: id, from: earlier, relabeled: true), label: label)
        case .windowTitleEquals: return self
        }
    }
}

public struct GuideStep: Codable, Equatable, Sendable, Identifiable {
    public enum Target: Codable, Equatable, Sendable {
        case axElement(stableID: String)
        case screenPoint(CGPointShim)
        case verbalOnly

        public var isVerbal: Bool {
            if case .verbalOnly = self { return true }
            return false
        }
    }

    public enum Postcondition: Codable, Equatable, Sendable {
        case elementExists(stableID: String)
        case elementAbsent(stableID: String)
        case elementLabelEquals(stableID: String, label: String)
        case windowTitleEquals(String)

        public func isSatisfied(in snapshot: AXSnapshot) -> Bool {
            switch self {
            case .elementExists(let stableID):
                return snapshot.element(withStableID: stableID) != nil
            case .elementAbsent(let stableID):
                return snapshot.element(withStableID: stableID) == nil
            case .elementLabelEquals(let stableID, let label):
                return snapshot.element(withStableID: stableID)?.label == label
            case .windowTitleEquals(let title):
                return snapshot.windowTitle == title
            }
        }
    }

    public let id: UUID
    public let instruction: String
    public let target: Target
    public let waitForUserAction: Bool
    public let postcondition: Postcondition?
    public let opensWindow: Bool

    public init(
        id: UUID = UUID(),
        instruction: String,
        target: Target,
        waitForUserAction: Bool = true,
        postcondition: Postcondition? = nil,
        opensWindow: Bool = false
    ) {
        self.id = id
        self.instruction = instruction
        self.target = target
        self.waitForUserAction = waitForUserAction
        self.postcondition = postcondition
        self.opensWindow = opensWindow
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        instruction = try c.decode(String.self, forKey: .instruction)
        target = try c.decode(Target.self, forKey: .target)
        waitForUserAction = try c.decode(Bool.self, forKey: .waitForUserAction)
        postcondition = try c.decodeIfPresent(Postcondition.self, forKey: .postcondition)
        opensWindow = try c.decodeIfPresent(Bool.self, forKey: .opensWindow) ?? false
    }
}

public typealias GuidePostcondition = GuideStep.Postcondition

/// One live read of the target window. Deliberately not Codable: screenshot bytes exist only in memory so pixels never reach history, memory, diagnostics, or test reports.
public struct GuideObservation: Sendable {
    public let observationID: String
    public let snapshot: AXSnapshot
    public let processID: Int32?
    public let windowID: Int64?
    public let connectionGeneration: UInt64?
    public let windowBounds: AXElementFrame?
    public let screenshotData: Data?
    public let screenshotMIMEType: String

    public init(
        snapshot: AXSnapshot,
        processID: Int32? = nil,
        windowID: Int64? = nil,
        connectionGeneration: UInt64? = nil,
        windowBounds: AXElementFrame? = nil,
        screenshotData: Data? = nil,
        screenshotMIMEType: String = "image/jpeg",
        observationID: String? = nil
    ) {
        self.observationID = observationID ?? UUID().uuidString
        self.snapshot = snapshot
        self.processID = processID
        self.windowID = windowID
        self.connectionGeneration = connectionGeneration
        self.windowBounds = windowBounds
        self.screenshotData = screenshotData
        self.screenshotMIMEType = screenshotMIMEType
    }
}

/// Reads the target window's accessibility tree.
public protocol GuideObserving: Sendable {
    func observe() async throws -> GuideObservation

    /// Suspends until the observed UI signals a change or `within` elapses. True means a signal ended the wait.
    func awaitUIChange(within: Duration) async -> Bool

    /// Reads the accessibility tree without capturing the screen.
    func observeElements() async throws -> GuideObservation

    /// Confirms the target window is still the same window without reading its element tree. Must throw on a dead or swapped target.
    func probeTarget() async throws -> GuideObservation
}

public extension GuideObserving {
    func awaitUIChange(within: Duration) async -> Bool {
        try? await Task.sleep(for: min(within, .milliseconds(250)))
        return false
    }

    func observeElements() async throws -> GuideObservation {
        try await observe()
    }

    func probeTarget() async throws -> GuideObservation {
        try await observeElements()
    }
}

/// Bounded record of what the guide has presented; history is capped so a long session cannot grow model context without limit.
public struct GuideProgress: Equatable, Sendable {
    public static let historyLimit = 8

    public private(set) var presentedCount: Int
    public private(set) var completedInstructions: [String]
    public private(set) var completedTargetIDs: [String]
    public private(set) var userConfirmedInstructions: [String]

    public init(presentedCount: Int = 0, completedInstructions: [String] = [], completedTargetIDs: [String] = [], userConfirmedInstructions: [String] = []) {
        self.presentedCount = presentedCount
        self.completedInstructions = Self.capped(completedInstructions)
        self.completedTargetIDs = Self.capped(completedTargetIDs)
        self.userConfirmedInstructions = Self.capped(userConfirmedInstructions)
    }

    public mutating func recordUserConfirmed(_ step: GuideStep) {
        userConfirmedInstructions = Self.capped(userConfirmedInstructions + [step.instruction])
        recordSkipped(step)
    }

    public mutating func recordPresented() {
        presentedCount += 1
    }

    public mutating func recordUnpresented() {
        presentedCount = max(0, presentedCount - 1)
    }

    public mutating func recordCompleted(_ step: GuideStep) {
        completedInstructions = Self.capped(completedInstructions + [step.instruction])
        recordSkipped(step)
    }

    public mutating func recordSkipped(_ step: GuideStep) {
        if case .axElement(let stableID) = step.target {
            completedTargetIDs = Self.capped(completedTargetIDs + [stableID])
        }
    }

    private static func capped(_ values: [String]) -> [String] {
        Array(values.suffix(historyLimit))
    }
}

public enum GuidePlannerError: Error, Equatable, Sendable, LocalizedError {
    case invalidTarget(String)
    case protectedWindow
    case malformedResponse(String)
    case blocked(String)
    case explanationEnded
    case needsInput(prompt: String, choices: [String])

    public var errorDescription: String? {
        switch self {
        case .invalidTarget: return "Perry couldn’t point at that control safely, so it stopped."
        case .protectedWindow: return "That window is protected, so Perry will not guide inside it."
        case .malformedResponse: return "Perry got a step it couldn’t use, so it stopped. Try again."
        case .blocked(let reason): return reason
        case .explanationEnded: return "Perry finished explaining. It didn’t check that the task is done."
        case .needsInput(let prompt, _): return prompt
        }
    }
}

/// Trust boundary for planner-produced steps: every step is checked against the live observation before the user sees it.
public enum GuideTargetValidator {
    public static func requireUnprotected(_ observation: GuideObservation) throws {
        let window = WindowContext(
            appBundleID: observation.snapshot.appBundleID,
            title: observation.snapshot.windowTitle
        )
        if TrustGuard().isWindowBlocked(window) {
            throw GuidePlannerError.protectedWindow
        }
    }

    @discardableResult
    public static func validated(_ step: GuideStep, in observation: GuideObservation) throws -> GuideStep {
        switch step.target {
        case .verbalOnly:
            return step
        case .axElement(let stableID):
            guard let element = observation.snapshot.element(withStableID: stableID) else {
                throw GuidePlannerError.invalidTarget("no element with id \(stableID) in the live window")
            }
            guard element.isActionable else {
                throw GuidePlannerError.invalidTarget("element \(stableID) is not actionable")
            }
            return step
        case .screenPoint(let point):
            if let bounds = observation.windowBounds {
                let inside = point.x >= bounds.x && point.x <= bounds.x + bounds.width
                    && point.y >= bounds.y && point.y <= bounds.y + bounds.height
                guard inside else {
                    throw GuidePlannerError.invalidTarget("point (\(point.x), \(point.y)) is outside the target window")
                }
            }
            return step
        }
    }
}

public enum GuideCompletionEvidence: Equatable, Sendable {
    case explanationOnly
    case observedGoal(GuidePostcondition)
}

public enum GuideDecision: Equatable, Sendable {
    case step(GuideStep)
    case complete(evidence: GuideCompletionEvidence)
    case blocked(reason: String)
    case needsInput(prompt: String, choices: [String])
}

/// Returns the next single step for the current observation, or a decision that the goal is complete or blocked.
public protocol GuidePlanner: Sendable {
    func nextStep(goal: String, observation: GuideObservation, progress: GuideProgress, context: GuideContext) async throws -> GuideDecision

    /// The visible part of the path. Steps that cannot be grounded in `observation` are omitted.
    func visiblePath(goal: String, observation: GuideObservation, context: GuideContext) async throws -> [GuideStep]
}

public extension GuidePlanner {
    func nextStep(goal: String, observation: GuideObservation, context: GuideContext) async throws -> GuideDecision {
        try await nextStep(goal: goal, observation: observation, progress: GuideProgress(), context: context)
    }
}

public struct GuideContext: Equatable, Sendable {
    public let spatialRegionDescription: String?
    public let memoryContext: String?
    public let goalPostcondition: GuidePostcondition?
    public let inputAnswer: String?

    public init(spatialRegionDescription: String? = nil, memoryContext: String? = nil, goalPostcondition: GuidePostcondition? = nil, inputAnswer: String? = nil) {
        self.spatialRegionDescription = spatialRegionDescription
        self.memoryContext = memoryContext
        self.goalPostcondition = goalPostcondition
        self.inputAnswer = inputAnswer
    }

    public static let empty = GuideContext()
}

/// Offline planner that only points at controls visible right now, ranked by goal words.
public struct AXGuidePlanner: GuidePlanner {
    public init() {}

    public func nextStep(
        goal: String,
        observation: GuideObservation,
        progress: GuideProgress,
        context: GuideContext
    ) async throws -> GuideDecision {
        let candidates = rankedCandidates(
            goal: goal,
            snapshot: observation.snapshot,
            excluding: Set(progress.completedTargetIDs)
        )
        if let best = candidates.first, best.score > 0 || Self.goalWords(for: goal).isEmpty {
            return .step(Self.step(for: best.element, ordinal: progress.presentedCount == 0 ? "this" : "next"))
        }
        if progress.presentedCount == 0 {
            return .step(GuideStep(
                instruction: "I can't see a control in \"\(observation.snapshot.windowTitle)\" that matches \"\(goal)\". Click the control yourself, or describe the one you mean and I’ll watch for it.",
                target: .verbalOnly,
                waitForUserAction: false
            ))
        }
        return .blocked(reason: "Perry couldn’t find the control for the next step, so it stopped.")
    }

    public func visiblePath(
        goal: String,
        observation: GuideObservation,
        context: GuideContext
    ) async throws -> [GuideStep] {
        let candidates = rankedCandidates(goal: goal, snapshot: observation.snapshot, excluding: [])
        guard Self.goalWords(for: goal).isEmpty || candidates.contains(where: { $0.score > 0 }) else {
            return []
        }
        return candidates.prefix(8).enumerated().map { index, item in
            Self.step(for: item.element, ordinal: index == 0 ? "this" : "next")
        }
    }

    private struct Candidate {
        let index: Int
        let element: AXElement
        let score: Int
    }

    private func rankedCandidates(goal: String, snapshot: AXSnapshot, excluding completed: Set<String>) -> [Candidate] {
        let goalWords = Self.goalWords(for: goal)
        let ranked = snapshot.actionableElements()
            .filter { !completed.contains($0.stableID) }
            .enumerated()
            .map { index, element in
                Candidate(index: index, element: element, score: Self.relevance(of: element, to: goalWords))
            }
        guard ranked.contains(where: { $0.score > 0 }) else { return ranked }
        return ranked.sorted { left, right in
            if left.score == right.score { return left.index < right.index }
            return left.score > right.score
        }
    }

    static func goalWords(for goal: String) -> Set<String> {
        Set(goal.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !guideStopWords.contains($0) })
    }

    private static func step(for element: AXElement, ordinal: String) -> GuideStep {
        let label = element.label.map { " \($0)" } ?? ""
        return GuideStep(
            instruction: "\(ordinal) one\(label), the \(readableRole(element.role))",
            target: .axElement(stableID: element.stableID)
        )
    }

    private static let guideStopWords: Set<String> = [
        "the", "and", "for", "with", "from", "into", "this", "that", "how", "can", "please", "want", "show", "teach", "guide",
        "walk", "through", "around", "everything", "frontmost", "window", "steps", "all"
    ]

    private static func relevance(of element: AXElement, to goalWords: Set<String>) -> Int {
        let labelWords = Set((element.label ?? "")
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
            .map(normalizeToken))
        let labelScore = goalWords.reduce(0) { score, goalWord in
            score + (labelWords.contains(normalizeToken(goalWord)) ? 3 : 0)
        }
        let role = element.role.rawValue.lowercased()
        let roleScore = goalWords.contains { role.contains($0) } ? 1 : 0
        return labelScore + roleScore
    }

    private static func normalizeToken(_ token: String) -> String {
        guard token.count > 3, token.hasSuffix("s") else { return token }
        return String(token.dropLast())
    }

    static func readableRole(_ role: AXElement.Role) -> String {
        switch role {
        case .button: return "button"
        case .textField: return "text field"
        case .slider: return "slider"
        case .checkBox: return "checkbox"
        case .menu: return "menu"
        case .menuItem: return "menu item"
        case .tabGroup: return "tab group"
        case .staticText: return "label"
        case .image: return "image"
        case .other: return "control"
        }
    }
}
