import Foundation
import PerryRuntimes

struct ComputerCoordinates: Sendable, Equatable {
    let x: Double
    let y: Double
}

struct ComputerTarget: Sendable, Equatable {
    let stableID: String?
    let label: String?
    let coordinates: ComputerCoordinates?
    var hasFreshSelector: Bool { stableID != nil || label != nil }
}

struct ComputerAction: Sendable, Equatable {
    enum Direction: String, Sendable, Equatable { case up, down, left, right }
    enum Operation: Sendable, Equatable {
        case click(ComputerTarget)
        case typeText(text: String, target: ComputerTarget)
        case rightClick(ComputerTarget)
        case doubleClick(ComputerTarget)
        case scroll(direction: Direction, amount: Int, by: String?, target: ComputerTarget?)
        case pressKey(key: String, modifiers: [String]?, target: ComputerTarget?)
        case hotkey(keys: [String], target: ComputerTarget?)
        case drag(from: ComputerCoordinates, to: ComputerCoordinates, durationMilliseconds: Int?, steps: Int?)
    }

    let stepID: String
    let operation: Operation
    /// The live window identity the plan was bound to; the driver compares it
    /// against the refreshed session target before every action.
    let expectedWindow: ExecutableAction.WindowIdentity?

    init(stepID: String, operation: Operation, expectedWindow: ExecutableAction.WindowIdentity? = nil) {
        self.stepID = stepID
        self.operation = operation
        self.expectedWindow = expectedWindow
    }

    init(actionID: String, command: ExecutableAction.ComputerCommand, expectedWindow: ExecutableAction.WindowIdentity? = nil) throws {
        stepID = actionID
        self.expectedWindow = expectedWindow
        switch command {
        case .click(let target):
            operation = .click(try Self.typedTarget(target))
        case .rightClick(let target):
            operation = .rightClick(try Self.typedTarget(target))
        case .doubleClick(let target):
            operation = .doubleClick(try Self.typedTarget(target))
        case .typeText(let text, let target):
            operation = .typeText(text: text, target: try Self.typedTarget(target))
        case .scroll(let direction, let amount, let unit, let target):
            guard let direction = Direction(rawValue: direction.rawValue) else {
                throw CuaDriverError.unsupportedAction
            }
            operation = .scroll(
                direction: direction, amount: amount, by: unit.rawValue,
                target: try target.map(Self.typedTarget)
            )
        case .pressKey(let key, let modifiers, let target):
            operation = .pressKey(
                key: key.lowercased(),
                modifiers: modifiers.map(Self.typedModifier),
                target: try target.map(Self.typedTarget)
            )
        case .hotkey(let key, let modifiers, let target):
            operation = .hotkey(
                keys: modifiers.map(Self.typedModifier) + [key.lowercased()],
                target: try target.map(Self.typedTarget)
            )
        case .drag(let from, let to, let durationMilliseconds, let steps):
            operation = .drag(
                from: try Self.typedCoordinates(from),
                to: try Self.typedCoordinates(to),
                durationMilliseconds: durationMilliseconds,
                steps: steps
            )
        }
    }

    private static func typedTarget(_ selector: ExecutableAction.Selector) throws -> ComputerTarget {
        switch selector {
        case .accessibilityID(let identifier):
            return ComputerTarget(stableID: identifier, label: nil, coordinates: nil)
        case .windowPixels(let x, let y):
            return ComputerTarget(stableID: nil, label: nil, coordinates: ComputerCoordinates(x: x, y: y))
        }
    }

    private static func typedCoordinates(_ selector: ExecutableAction.Selector) throws -> ComputerCoordinates {
        guard case .windowPixels(let x, let y) = selector else {
            throw CuaDriverError.targetNotFound
        }
        return ComputerCoordinates(x: x, y: y)
    }

    private static func typedModifier(_ modifier: ExecutableAction.ComputerCommand.KeyModifier) -> String {
        switch modifier {
        case .command: return "cmd"
        case .shift: return "shift"
        case .option: return "option"
        case .control: return "ctrl"
        case .function: return "fn"
        }
    }

}
