import CryptoKit
import Foundation
import PerryCore
import PerryRuntimes

public enum RoutineReplayError: Error, Equatable {
    case wrongApplication
    case windowIdentityUnavailable
    case targetNotFound(step: Int)
    case ambiguousTarget(step: Int)
    case missingParameter(String)
    case missingVisualBaseline(step: Int)
    case noExecutableSteps
}

extension RoutineReplayError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .wrongApplication: return "this routine belongs to a different app than the observed window"
        case .windowIdentityUnavailable: return "the routine's window could not be identified"
        case .targetNotFound(let step): return "step \(step + 1)'s control is no longer on screen"
        case .ambiguousTarget(let step): return "step \(step + 1)'s control matches more than one element"
        case .missingParameter(let name): return "the routine needs a value for \"\(name)\""
        case .missingVisualBaseline(let step): return "step \(step + 1) could not capture a visual baseline"
        case .noExecutableSteps: return "the routine has no executable steps"
        }
    }
}

/// Turns a reviewed routine back into a typed execution plan. Every target
/// is re-resolved against a fresh observation — recorded coordinates are
/// never replayed — and every step declares the observable postcondition the
/// verifier will actually check: typed text must appear in the window, and
/// clicks/keys must visibly change it against the pre-run screenshot.
public enum RoutineReplay {
    public static func plan(
        routine: LearnedRoutine,
        observation: GuideObservation,
        taskID: TaskID,
        parameters: [String: String] = [:]
    ) throws -> ExecutionPlan {
        guard observation.snapshot.appBundleID == routine.bundleID else {
            throw RoutineReplayError.wrongApplication
        }
        guard let processID = observation.processID,
              let windowID = observation.windowID,
              let generation = observation.connectionGeneration,
              windowID > 0, windowID <= Int64(UInt32.max) else {
            throw RoutineReplayError.windowIdentityUnavailable
        }
        let window = ExecutableAction.WindowIdentity(
            bundleID: routine.bundleID,
            processID: processID,
            windowID: UInt32(windowID),
            connectionGeneration: generation
        )
        var actions: [ExecutableAction] = []
        for (index, step) in routine.steps.enumerated() {
            if case .wait = step.action { continue } // waits are absorbed by per-step verification
            let selector: ExecutableAction.Selector? = try step.target.map { target in
                .accessibilityID(try resolve(target, in: observation.snapshot.elements, step: index))
            }
            let command: ExecutableAction.ComputerCommand
            let postcondition: ExecutableAction.Postcondition
            switch step.action {
            case .click:
                command = .click(try require(selector, step: index))
                postcondition = try visualBaseline(for: observation, step: index)
            case .doubleClick:
                command = .doubleClick(try require(selector, step: index))
                postcondition = try visualBaseline(for: observation, step: index)
            case .typeText(let source):
                let text: String
                switch source {
                case .literal(let literal):
                    text = literal
                case .parameter(let name, _):
                    guard let value = parameters[name] else {
                        throw RoutineReplayError.missingParameter(name)
                    }
                    text = value
                }
                command = .typeText(text, target: try require(selector, step: index))
                postcondition = .elementValue(text)
            case .pressKey(let key):
                command = .pressKey(key, modifiers: [], target: selector)
                postcondition = try visualBaseline(for: observation, step: index)
            case .wait:
                continue
            }
            actions.append(try ExecutableAction(
                id: ActionID("routine-step-\(index)"),
                summary: step.summary,
                approvalRequirement: .plan,
                operation: .computer(window: window, command: command),
                postcondition: postcondition
            ))
        }
        guard !actions.isEmpty else { throw RoutineReplayError.noExecutableSteps }
        return try ExecutionPlan(
            taskID: taskID,
            goal: routine.name,
            actions: actions,
            requestedScopes: [.computerControl]
        )
    }

    /// A target resolves to exactly one element — a miss fails the plan and an
    /// A target resolves to exactly one element — a miss fails the plan and an
    /// ambiguous match refuses to guess rather than acting on the wrong
    /// control.
    private static func resolve(
        _ target: RoutineTarget,
        in elements: [AXElement],
        step: Int
    ) throws -> String {
        let matches = elements.filter { element in
            guard element.role.rawValue == target.role || element.rawRole == target.role else { return false }
            if let label = target.label, element.label != label { return false }
            if let subrole = target.subrole, element.subrole != subrole { return false }
            return true
        }
        guard let element = matches.only else {
            throw matches.isEmpty
                ? RoutineReplayError.targetNotFound(step: step)
                : RoutineReplayError.ambiguousTarget(step: step)
        }
        return element.stableID
    }

    private static func visualBaseline(
        for observation: GuideObservation,
        step: Int
    ) throws -> ExecutableAction.Postcondition {
        guard let screenshot = observation.screenshotData, !screenshot.isEmpty else {
            throw RoutineReplayError.missingVisualBaseline(step: step)
        }
        let digest = SHA256.hash(data: screenshot).map { String(format: "%02x", $0) }.joined()
        return .visualChange(baselineSHA256: digest)
    }

    private static func require(_ selector: ExecutableAction.Selector?, step: Int) throws -> ExecutableAction.Selector {
        guard let selector else { throw RoutineReplayError.targetNotFound(step: step) }
        return selector
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
