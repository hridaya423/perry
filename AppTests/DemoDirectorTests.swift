import XCTest
import PerryRuntimes
@testable import Perry

@MainActor
final class DemoDirectorTests: XCTestCase {
    func testBlockedTaskFailsDemoAndDoesNotReportCompletion() async {
        var reported = false
        let completed = expectation(description: "demo completion callback")
        let selection = SpatialSelection(
            window: nil,
            rect: CGRect(x: 0, y: 0, width: 100, height: 100),
            points: [.zero, CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), .zero]
        )
        let director = DemoDirector(hooks: .init(
            preflight: { .ready },
            wake: {},
            speak: { _ in },
            waitForSpatialSelection: { selection },
            cancelPendingInputs: {},
            describeSpatialSelection: { _ in true },
            runGuide: { _ in true },
            runDo: { _ in .blocked(reason: "approval denied") },
            report: { _ in reported = true }
        ))

        director.run { succeeded in
            XCTAssertFalse(succeeded)
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(director.phase, .failed)
        XCTAssertFalse(reported)
    }

    /// Onboarding's first magic moment must answer a real question about the
    /// screen before it teaches or acts — the demo runs spatial Ask first,
    /// then Guide, then Do, and only reports once everything verified.
    func testDemoAnswersAboutTheScreenBeforeGuidingOrDoing() async {
        var order: [String] = []
        var reportedOutcome: DoOutcome?
        let completed = expectation(description: "demo completion callback")
        let selection = SpatialSelection(
            window: nil,
            rect: CGRect(x: 0, y: 0, width: 100, height: 100),
            points: [.zero, CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), .zero]
        )
        let director = DemoDirector(hooks: .init(
            preflight: { .ready },
            wake: {},
            speak: { _ in },
            waitForSpatialSelection: { selection },
            cancelPendingInputs: {},
            describeSpatialSelection: { _ in order.append("ask"); return true },
            runGuide: { _ in order.append("guide"); return true },
            runDo: { _ in order.append("do"); return .completed(stepsRun: 1) },
            report: { outcome in order.append("report"); reportedOutcome = outcome }
        ))

        director.run { succeeded in
            XCTAssertTrue(succeeded)
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(order, ["ask", "guide", "do", "report"])
        XCTAssertEqual(reportedOutcome, .completed(stepsRun: 1))
        XCTAssertEqual(director.lastVerifiedResult, DemoRecipe.current.expectedResult)
        XCTAssertEqual(director.phase, .idle)
    }
}
