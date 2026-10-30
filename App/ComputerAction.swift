import Foundation
import PerryRuntimes

struct ComputerCoordinates: Sendable, Equatable {
    let x: Double
    let y: Double
}

enum ComputerTarget: Sendable, Equatable {
    case element(id: String, label: String?, point: ComputerCoordinates?)
    case label(String, point: ComputerCoordinates?)
    case point(ComputerCoordinates)

    var id: String? {
        if case .element(let id, _, _) = self { return id }
        return nil
    }

    var label: String? {
        switch self {
        case .element(_, let label, _): return label
        case .label(let label, _): return label
        case .point: return nil
        }
    }

    var point: ComputerCoordinates? {
        switch self {
        case .element(_, _, let point), .label(_, let point): return point
        case .point(let point): return point
        }
    }

    var hasFreshSelector: Bool {
        if case .point = self { return false }
        return true
    }

    func mappingPoint(_ transform: (ComputerCoordinates) -> ComputerCoordinates) -> ComputerTarget {
        switch self {
        case .element(let id, let label, let point): return .element(id: id, label: label, point: point.map(transform))
        case .label(let label, let point): return .label(label, point: point.map(transform))
        case .point(let point): return .point(transform(point))
        }
    }
}

struct ComputerAction: Sendable, Equatable {
    typealias Direction = ExecutableAction.ComputerCommand.Direction
    typealias ScrollUnit = ExecutableAction.ComputerCommand.ScrollUnit

    enum Operation: Sendable, Equatable {
        case click(ComputerTarget)
        case rightClick(ComputerTarget)
        case doubleClick(ComputerTarget)
        case typeText(text: String, target: ComputerTarget?)
        case setValue(value: String, target: ComputerTarget)
        case scroll(direction: Direction, amount: Int, by: ScrollUnit?, target: ComputerTarget?)
        case pressKey(key: String, modifiers: [String]?, target: ComputerTarget?)
        case hotkey(keys: [String], target: ComputerTarget?)
        case drag(from: ComputerCoordinates, to: ComputerCoordinates, durationMilliseconds: Int?, steps: Int?)
        indirect case steps([Operation])

        var target: ComputerTarget? {
            switch self {
            case .click(let target), .rightClick(let target), .doubleClick(let target), .setValue(_, let target):
                return target
            case .typeText(_, let target), .scroll(_, _, _, let target), .pressKey(_, _, let target), .hotkey(_, let target):
                return target
            case .drag, .steps:
                return nil
            }
        }

        var defaultMessage: String {
            switch self {
            case .click: return "Clicked it."
            case .rightClick: return "Opened the context menu."
            case .doubleClick: return "Double-clicked it."
            case .typeText: return "Typed the text."
            case .setValue: return "Set the value."
            case .scroll(let direction, _, _, _): return "Scrolled \(direction.rawValue)."
            case .pressKey(let key, _, _): return "Pressed \(key)."
            case .hotkey(let keys, _): return "Pressed \(keys.joined(separator: "+"))."
            case .drag: return "Dragged it."
            case .steps(let operations): return "Did all \(operations.count) steps."
            }
        }
    }

    let stepID: String
    let operation: Operation
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
            operation = .click(Self.target(target))
        case .rightClick(let target):
            operation = .rightClick(Self.target(target))
        case .doubleClick(let target):
            operation = .doubleClick(Self.target(target))
        case .typeText(let text, let target):
            operation = .typeText(text: text, target: Self.target(target))
        case .scroll(let direction, let amount, let unit, let target):
            operation = .scroll(direction: direction, amount: amount, by: unit, target: target.map(Self.target))
        case .pressKey(let key, let modifiers, let target):
            operation = .pressKey(
                key: key.lowercased(),
                modifiers: modifiers.map(Self.modifier),
                target: target.map(Self.target)
            )
        case .hotkey(let key, let modifiers, let target):
            operation = .hotkey(
                keys: modifiers.map(Self.modifier) + [key.lowercased()],
                target: target.map(Self.target)
            )
        case .drag(let from, let to, let durationMilliseconds, let steps):
            operation = .drag(
                from: try Self.coordinates(from),
                to: try Self.coordinates(to),
                durationMilliseconds: durationMilliseconds,
                steps: steps
            )
        }
    }

    private static func target(_ selector: ExecutableAction.Selector) -> ComputerTarget {
        switch selector {
        case .accessibilityID(let identifier):
            return .element(id: identifier, label: nil, point: nil)
        case .windowPixels(let x, let y):
            return .point(ComputerCoordinates(x: x, y: y))
        }
    }

    private static func coordinates(_ selector: ExecutableAction.Selector) throws -> ComputerCoordinates {
        guard case .windowPixels(let x, let y) = selector else {
            throw CuaDriverError.targetNotFound
        }
        return ComputerCoordinates(x: x, y: y)
    }

    private static func modifier(_ modifier: ExecutableAction.ComputerCommand.KeyModifier) -> String {
        switch modifier {
        case .command: return "cmd"
        case .shift: return "shift"
        case .option: return "option"
        case .control: return "ctrl"
        case .function: return "fn"
        }
    }
}
