import AppKit
import XCTest
import PerryBrain
import PerryCore
import PerryGuide
import PerryOverlay
@testable import Perry

@MainActor
final class TalkObservedElementsTests: XCTestCase {
    func testSecureElementsAreFilteredOut() {
        let observation = GuideObservation(
            snapshot: AXSnapshot(
                appBundleID: "com.example",
                windowTitle: "Main",
                elements: [
                    AXElement(
                        stableID: "e1", role: .button, label: "Save",
                        frame: AXElementFrame(x: 10, y: 20, width: 80, height: 30),
                        isActionable: true
                    ),
                    AXElement(
                        stableID: "e2", role: .textField, label: "Password",
                        frame: AXElementFrame(x: 10, y: 60, width: 200, height: 30),
                        isActionable: true,
                        sensitivity: .secure
                    ),
                ]
            ),
            windowID: 42
        )
        let elements = observation.observedElements
        XCTAssertEqual(elements.map(\.id), ["e1"])
        XCTAssertEqual(elements.first?.windowID, 42)
        XCTAssertEqual(elements.first?.frame, CGRect(x: 10, y: 20, width: 80, height: 30))
    }
}
