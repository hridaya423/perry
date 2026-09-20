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
}
