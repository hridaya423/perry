import XCTest
import PerryGuide
@testable import Perry

final class RoutineRunCopyTests: XCTestCase {
    private func routine() throws -> LearnedRoutine {
        try LearnedRoutine(name: "Export", appBundleIDs: ["com.example.app"], steps: [
            RoutineStep(summary: "Click File", target: RoutineTarget(role: "menuItem", label: "File"), action: .click),
            RoutineStep(summary: "Click Edit", target: RoutineTarget(role: "menuItem", label: "Edit"), action: .click),
            RoutineStep(summary: "Click Export", target: RoutineTarget(role: "button", label: "Export"), action: .click)
        ])
    }

    func testTheFirstSuccessfulRunSaysItWorked() {
        XCTAssertEqual(RoutineRunCopy.success(priorVerifiedRuns: 0), "Done. I’ll remember this routine.")
        XCTAssertNil(RoutineRunCopy.success(priorVerifiedRuns: 1))
    }

    func testAMissingControlNamesTheStepAndTheControl() throws {
        let copy = RoutineRunCopy.stopped(routine: try routine(), step: 2, error: .targetNotFound(step: 2), reason: "ignored")
        XCTAssertEqual(copy, "I stopped at step 3. I couldn’t find “Export”.")
    }

    func testAnAmbiguousControlNamesTheStepAndTheControl() throws {
        let copy = RoutineRunCopy.stopped(routine: try routine(), step: 1, error: .ambiguousTarget(step: 1), reason: "ignored")
        XCTAssertEqual(copy, "I stopped at step 2. More than one control looks like “Edit”.")
    }

    func testAnyOtherFailureStillNamesTheStep() throws {
        let copy = RoutineRunCopy.stopped(routine: try routine(), step: 0, error: nil, reason: "the screen did not change")
        XCTAssertEqual(copy, "I stopped at step 1. The screen did not change.")
    }

    func testAFailureWithoutAKnownStepFallsBackToTheReason() throws {
        let copy = RoutineRunCopy.stopped(routine: try routine(), step: nil, error: nil, reason: "paused")
        XCTAssertEqual(copy, "I stopped before the first step. Paused.")
    }

    func testReplayErrorsCarryTheirStep() {
        XCTAssertEqual(RoutineRunCopy.step(of: .targetNotFound(step: 4)), 4)
        XCTAssertEqual(RoutineRunCopy.step(of: .ambiguousTarget(step: 1)), 1)
        XCTAssertNil(RoutineRunCopy.step(of: .wrongApplication))
    }
}
