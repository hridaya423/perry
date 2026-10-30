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

    func testCollapsingDoesNotResolveApprovalAndDismissResolvesCancel() async {
        let presentation = NotchPresentation()
        let presenter = IntentCardPresenter(presentation: presentation)
        let card = IntentCard(title: "Remove file", detail: "Remove selected file", tier: .red, targetSummary: "Selected file")
        let asking = Task { await presenter.present(card: card) }
        for _ in 0..<200 where presentation.current == nil { await Task.yield() }
        presentation.showsInteraction = false
        XCTAssertEqual(presentation.current?.priority, .approval)
        presenter.dismiss()
        presenter.dismiss()
        let decision = await asking.value
        guard case .cancel = decision else { return XCTFail("Approval must cancel") }
        XCTAssertNil(presentation.current)
    }

    func testPresentingASecondIntentCardCancelsTheFirst() async {
        let presentation = NotchPresentation()
        let presenter = IntentCardPresenter(presentation: presentation)
        let card = IntentCard(title: "Remove file", detail: nil, tier: .orange, targetSummary: "Selected file")
        let first = Task { await presenter.present(card: card) }
        for _ in 0..<200 where presentation.current == nil { await Task.yield() }
        let second = Task { await presenter.present(card: card) }
        let firstDecision = await first.value
        guard case .cancel = firstDecision else { return XCTFail("The first card must be cancelled") }
        XCTAssertEqual(presentation.entries.count, 1)
        presenter.dismiss()
        _ = await second.value
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
            let frame = NotchPresence.notchPanelFrame(size: CGSize(width: 892, height: 552), screenFrame: screen, centerX: screen.midX)
            XCTAssertEqual(frame.maxY, screen.maxY)
            XCTAssertEqual(frame.midX, screen.midX)
            XCTAssertGreaterThanOrEqual(frame.minX, screen.minX)
            XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
        }
    }
}
