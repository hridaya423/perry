import XCTest
import PerryCore
import PerryGuide
import PerryRuntimes
@testable import Perry

final class SensitiveInputMaskTests: XCTestCase {
    func testSecureFieldsAreMasked() throws {
        let plan = try plan(actions: [
            computerAction("Type password", command: .typeText("hunter2", target: .accessibilityID("ax-secret")))
        ])
        let elements = [
            AXElement(stableID: "ax-secret", role: .textField, label: "Password",
                      frame: AXElementFrame(x: 1, y: 2, width: 3, height: 4),
                      isActionable: true, sensitivity: .secure)
        ]

        let masked = try plan.maskingSensitiveInputs(in: elements)

        XCTAssertEqual(masked.actions.map(\.summary), ["Enter sensitive input"])
        XCTAssertEqual(masked.actions.map(\.operation), plan.actions.map(\.operation))
        XCTAssertEqual(masked.planID, plan.planID)
        XCTAssertEqual(masked.taskID, plan.taskID)
    }

    func testOnlyTypingIntoAnUnknownFieldIsMaskedNotAClick() throws {
        let plan = try plan(actions: [
            computerAction("Click Save", command: .click(.accessibilityID("ax-save"))),
            computerAction("Type note", command: .typeText("hello", target: .accessibilityID("ax-note"))),
        ])
        let elements = [
            AXElement(stableID: "ax-save", role: .button, label: "Save",
                      frame: AXElementFrame(x: 0, y: 0, width: 10, height: 10), isActionable: true),
            AXElement(stableID: "ax-note", role: .textField, label: "Note",
                      frame: AXElementFrame(x: 0, y: 20, width: 10, height: 10), isActionable: true),
        ]

        let masked = try plan.maskingSensitiveInputs(in: elements)

        XCTAssertEqual(masked.actions.map(\.summary), ["Click Save", "Enter sensitive input"])
    }

    func testOrdinaryTargetsAreNotMasked() throws {
        let plan = try plan(actions: [
            computerAction("Click Save", command: .click(.accessibilityID("ax-save")))
        ])

        let masked = try plan.maskingSensitiveInputs(in: [element(id: "ax-save", x: 0, y: 0, width: 10, height: 10)])

        XCTAssertEqual(masked.actions.map(\.summary), plan.actions.map(\.summary))
    }

    func testPixelTargetsAndMissingElementsAreNotMasked() throws {
        let plan = try plan(actions: [
            computerAction("Type pixel", command: .typeText("x", target: .windowPixels(x: 1, y: 1))),
            computerAction("Type missing", command: .typeText("x", target: .accessibilityID("ax-gone"))),
        ])

        let masked = try plan.maskingSensitiveInputs(in: [])

        XCTAssertEqual(masked.actions.map(\.summary), ["Type pixel", "Type missing"])
    }

    private func plan(actions: [ExecutableAction]) throws -> ExecutionPlan {
        try ExecutionPlan(
            taskID: "task",
            goal: "goal",
            actions: actions,
            requestedScopes: Set(actions.flatMap { $0.operation.requiredScopes })
        )
    }

    private func computerAction(_ summary: String, command: ExecutableAction.ComputerCommand) throws -> ExecutableAction {
        try ExecutableAction(
            id: ActionID(summary),
            summary: summary,
            approvalRequirement: .action,
            operation: .computer(
                window: ExecutableAction.WindowIdentity(
                    bundleID: "com.example.Editor",
                    processID: 4242,
                    windowID: 1001,
                    connectionGeneration: 7
                ),
                command: command
            ),
            postcondition: .visualChange(baselineSHA256: String(repeating: "a", count: 64))
        )
    }

    private func element(id: String, x: Double, y: Double, width: Double, height: Double) -> AXElement {
        AXElement(
            stableID: id,
            role: .button,
            label: id,
            frame: AXElementFrame(x: x, y: y, width: width, height: height),
            isActionable: true,
            sensitivity: .ordinary
        )
    }
}
