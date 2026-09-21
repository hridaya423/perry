import XCTest
import PerryCore
import PerryGuide
import PerryRuntimes
@testable import Perry

final class RehearsalMarksTests: XCTestCase {
    func testAccessibilityIDTargetsResolveToMarks() throws {
        let plan = try plan(actions: [
            computerAction("Click Save", command: .click(.accessibilityID("ax-save"))),
            computerAction("Type title", command: .typeText("hello", target: .accessibilityID("ax-field")))
        ])
        let elements = [
            element(id: "ax-save", x: 10, y: 20, width: 40, height: 20),
            element(id: "ax-field", x: 50, y: 60, width: 200, height: 24)
        ]

        let marks = RehearsalMarks.marks(for: plan, elements: elements)

        XCTAssertEqual(marks, [
            RehearsalMarks.Mark(stepNumber: 1, actionID: "Click Save", caption: "Click Save", frame: AXElementFrame(x: 10, y: 20, width: 40, height: 20), sensitive: false),
            RehearsalMarks.Mark(stepNumber: 2, actionID: "Type title", caption: "Type title", frame: AXElementFrame(x: 50, y: 60, width: 200, height: 24), sensitive: false)
        ])
    }

    func testPixelTargetsAndUngroundedSelectorsProduceNoMarks() throws {
        let plan = try plan(actions: [
            computerAction("Click pixel", command: .click(.windowPixels(x: 10, y: 10))),
            computerAction("Click missing", command: .click(.accessibilityID("ax-gone"))),
            computerAction("Press return", command: .pressKey("return", modifiers: [], target: nil))
        ])

        XCTAssertTrue(RehearsalMarks.marks(for: plan, elements: []).isEmpty)
    }

    func testNonComputerActionsProduceNoMarks() throws {
        let plan = try plan(actions: [
            try ExecutableAction(
                id: "ask",
                summary: "Ask the user",
                approvalRequirement: .action,
                operation: .askUser(prompt: "Which file?", choices: ["a", "b"]),
                postcondition: .answered
            )
        ])

        XCTAssertTrue(RehearsalMarks.marks(for: plan, elements: [element(id: "ax-save", x: 0, y: 0, width: 10, height: 10)]).isEmpty)
    }

    func testSensitiveTargetsFlagForMasking() throws {
        let plan = try plan(actions: [
            computerAction("Type password", command: .typeText("hunter2", target: .accessibilityID("ax-secret")))
        ])
        let elements = [
            AXElement(stableID: "ax-secret", role: .textField, label: "Password",
                      frame: AXElementFrame(x: 1, y: 2, width: 3, height: 4),
                      isActionable: true, sensitivity: .secure)
        ]

        let marks = RehearsalMarks.marks(for: plan, elements: elements)
        XCTAssertEqual(marks.map(\.sensitive), [true])
        XCTAssertEqual(Set(marks.map(\.actionID)), [ActionID("Type password")])

        let masked = try plan.maskingSensitiveSummaries(Set(marks.filter(\.sensitive).map(\.actionID)))
        XCTAssertEqual(masked.actions.map(\.summary), ["Enter sensitive input"])
        XCTAssertEqual(masked.actions.map(\.operation), plan.actions.map(\.operation))
        XCTAssertEqual(masked.planID, plan.planID)
        XCTAssertEqual(masked.taskID, plan.taskID)
    }

    func testOrdinaryTargetsAreNotMasked() throws {
        let plan = try plan(actions: [
            computerAction("Click Save", command: .click(.accessibilityID("ax-save")))
        ])
        let elements = [
            element(id: "ax-save", x: 0, y: 0, width: 10, height: 10)
        ]

        let marks = RehearsalMarks.marks(for: plan, elements: elements)
        XCTAssertEqual(marks.map(\.sensitive), [false])
        let masked = try plan.maskingSensitiveSummaries([])
        XCTAssertEqual(masked.actions.map(\.summary), plan.actions.map(\.summary))
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
