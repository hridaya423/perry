import XCTest
import PerryGuide
@testable import Perry

final class RoutineReviewStateTests: XCTestCase {
    func testTypedTextDefaultsToAskMeEachTime() {
        let state = RoutineReviewState()
        state.presentReview(steps: [
            RoutineStep(summary: "Click Notes", action: .click),
            RoutineStep(summary: "Type", action: .typeText(.literal("hello"))),
            RoutineStep(summary: "Type again", action: .typeText(.parameter(name: "q", prompt: "?"))),
            RoutineStep(summary: "Type last", action: .typeText(.literal("world")))
        ])
        XCTAssertEqual(state.parameterizedSteps, [1, 3])
    }

    func testDefaultStaysWithinTheParameterLimit() {
        let state = RoutineReviewState()
        state.presentReview(steps: (0..<(LearnedRoutine.maximumParameters + 5)).map {
            RoutineStep(summary: "Type \($0)", action: .typeText(.literal("x")))
        })
        XCTAssertEqual(state.parameterizedSteps.count, LearnedRoutine.maximumParameters)
    }
}
