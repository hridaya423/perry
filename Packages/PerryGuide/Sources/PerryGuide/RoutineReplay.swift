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
    case unsupportedShortcut(step: Int)
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
        case .unsupportedShortcut(let step): return "step \(step + 1) uses a shortcut Perry cannot press"
        }
    }
}

public struct RoutineStepBinding: Equatable, Sendable {
    public let command: ExecutableAction.ComputerCommand
    public let baselineSHA256: String?

    public init(command: ExecutableAction.ComputerCommand, baselineSHA256: String?) {
        self.command = command
        self.baselineSHA256 = baselineSHA256
    }
}

public enum RoutineReplay {
    public static func plan(
        routine: LearnedRoutine,
        observation: GuideObservation,
        taskID: TaskID,
        parameters: [String: String] = [:]
    ) throws -> ExecutionPlan {
        guard routine.appBundleIDs.contains(observation.snapshot.appBundleID) else {
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
            if case .wait = step.action { continue }
            if step.requiresHuman {
                actions.append(try ExecutableAction(
                    id: ActionID("\(stepIDPrefix)\(index)"),
                    summary: step.summary,
                    approvalRequirement: .action,
                    operation: .askUser(prompt: "Your turn: \(step.summary)", choices: ["Done"]),
                    postcondition: .answered
                ))
                continue
            }
            let selector: ExecutableAction.Selector? = try step.target.map { target in
                guard !actions.isEmpty else {
                    return .accessibilityID(try resolve(target, in: observation.snapshot.elements, step: index))
                }
                return (try? resolve(target, in: observation.snapshot.elements, step: index))
                    .map(ExecutableAction.Selector.accessibilityID)
                    ?? .accessibilityID("deferred-step-\(index)")
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
            case .hotkey(let key, let modifiers):
                command = .hotkey(key: key, modifiers: try keyModifiers(modifiers, step: index), target: selector)
                postcondition = try visualBaseline(for: observation, step: index)
            case .wait:
                continue
            }
            actions.append(try ExecutableAction(
                id: ActionID("\(stepIDPrefix)\(index)"),
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
            requestedScopes: Set(actions.flatMap { $0.operation.requiredScopes })
        )
    }

    public static func stepIndex(of action: ExecutableAction) -> Int? {
        guard action.id.rawValue.hasPrefix(stepIDPrefix) else { return nil }
        return Int(action.id.rawValue.dropFirst(stepIDPrefix.count))
    }

    public static func binding(
        for action: ExecutableAction,
        of routine: LearnedRoutine,
        in observation: GuideObservation
    ) throws -> RoutineStepBinding? {
        guard case .computer(_, let command) = action.operation,
              let index = stepIndex(of: action),
              routine.steps.indices.contains(index) else { return nil }
        let selector = try routine.steps[index].target.map {
            ExecutableAction.Selector.accessibilityID(try resolve($0, in: observation.snapshot.elements, step: index))
        }
        switch command {
        case .click:
            return RoutineStepBinding(
                command: .click(try require(selector, step: index)),
                baselineSHA256: try screenshotDigest(of: observation, step: index)
            )
        case .doubleClick:
            return RoutineStepBinding(
                command: .doubleClick(try require(selector, step: index)),
                baselineSHA256: try screenshotDigest(of: observation, step: index)
            )
        case .typeText(let text, _):
            return RoutineStepBinding(command: .typeText(text, target: try require(selector, step: index)), baselineSHA256: nil)
        case .pressKey(let key, let modifiers, _):
            return RoutineStepBinding(
                command: .pressKey(key, modifiers: modifiers, target: selector),
                baselineSHA256: try screenshotDigest(of: observation, step: index)
            )
        case .hotkey(let key, let modifiers, _):
            return RoutineStepBinding(
                command: .hotkey(key: key, modifiers: modifiers, target: selector),
                baselineSHA256: try screenshotDigest(of: observation, step: index)
            )
        default:
            return nil
        }
    }

    private static func keyModifiers(_ names: [String], step: Int) throws -> [ExecutableAction.ComputerCommand.KeyModifier] {
        try names.map {
            guard let modifier = ExecutableAction.ComputerCommand.KeyModifier(rawValue: $0) else {
                throw RoutineReplayError.unsupportedShortcut(step: step)
            }
            return modifier
        }
    }

    private static let stepIDPrefix = "routine-step-"

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
        .visualChange(baselineSHA256: try screenshotDigest(of: observation, step: step))
    }

    private static func screenshotDigest(of observation: GuideObservation, step: Int) throws -> String {
        guard let screenshot = observation.screenshotData, !screenshot.isEmpty else {
            throw RoutineReplayError.missingVisualBaseline(step: step)
        }
        return SHA256.hash(data: screenshot).map { String(format: "%02x", $0) }.joined()
    }

    private static func require(_ selector: ExecutableAction.Selector?, step: Int) throws -> ExecutableAction.Selector {
        guard let selector else { throw RoutineReplayError.targetNotFound(step: step) }
        return selector
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
