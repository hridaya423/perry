import AppKit
import SwiftUI
import XCTest
import PerryGuide
import PerryRuntimes
@testable import Perry

@MainActor
final class NotchPresentationTests: XCTestCase {
    func testNavigationDismissesOnlyVisibleOptInContent() {
        let presentation = NotchPresentation()
        let progressID = UUID()
        let dialogID = UUID()
        var cancellations = 0
        presentation.present(id: progressID, priority: .activity, content: Text("Working"))
        presentation.dismissCurrent()
        XCTAssertTrue(presentation.contains(progressID))
        presentation.present(id: dialogID, priority: .approval, content: Text("Confirm"), onDismiss: {
            cancellations += 1
            presentation.remove(dialogID)
        })
        presentation.showsInteraction = false
        presentation.dismissCurrent()
        XCTAssertEqual(cancellations, 0)
        presentation.showsInteraction = true
        presentation.dismissCurrent()
        presentation.dismissCurrent()
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(presentation.current?.id, progressID)
    }

    func testReopeningSameContentRetainsMeasuredHeightUntilItChanges() {
        let presentation = NotchPresentation()
        let id = UUID()
        presentation.present(id: id, priority: .guide, content: Text("Guide"))
        presentation.measure(id, height: 180)
        presentation.showsInteraction = false
        presentation.present(id: id, priority: .guide, content: Text("Guide"))
        XCTAssertTrue(presentation.showsInteraction)
        XCTAssertEqual(presentation.entries.count, 1)
        XCTAssertEqual(presentation.current?.contentHeight, 180)
        presentation.measure(id, height: 240)
        XCTAssertEqual(presentation.current?.contentHeight, 240)
    }

    func testCollapsingDoesNotResolveApprovalAndCancelResolvesOnce() {
        let presentation = NotchPresentation()
        var decisions: [PlanDecision] = []
        let card = IntentCard(title: "Remove file", detail: "Remove selected file", tier: .red, targetSummary: "Selected file")
        let approval = IntentCardWindow(card: card, presentation: presentation) { decisions.append($0) }
        approval.show()
        presentation.showsInteraction = false
        XCTAssertTrue(decisions.isEmpty)
        XCTAssertEqual(presentation.current?.priority, .approval)
        approval.cancel()
        approval.cancel()
        XCTAssertEqual(decisions.count, 1)
        guard case .cancel? = decisions.first else { return XCTFail("Approval must cancel") }
        XCTAssertNil(presentation.current)
    }

    func testOrdinaryProgressDoesNotOpenNotch() {
        let presentation = NotchPresentation()
        var presentations = 0
        presentation.onPresent = { _ in presentations += 1 }
        presentation.present(id: UUID(), priority: .activity, content: Text("Working"), reveal: false)
        XCTAssertEqual(presentations, 0)
        presentation.present(id: UUID(), priority: .approval, content: Text("Approval"))
        XCTAssertEqual(presentations, 1)
    }

    func testNotchRemainsAttachedOnOffsetAndSmallDisplays() {
        for screen in [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -1280, y: 500, width: 1280, height: 720)] {
            let frame = HomeController.notchPanelFrame(size: CGSize(width: 892, height: 552), screenFrame: screen, centerX: screen.midX)
            XCTAssertEqual(frame.maxY, screen.maxY)
            XCTAssertEqual(frame.midX, screen.midX)
            XCTAssertGreaterThanOrEqual(frame.minX, screen.minX)
            XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
        }
    }
}
