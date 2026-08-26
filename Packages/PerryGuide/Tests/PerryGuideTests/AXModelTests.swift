import XCTest
@testable import PerryGuide
import PerryCore

final class AXModelTests: XCTestCase {
    private func element(
        id: String,
        role: AXElement.Role = .button,
        label: String? = nil
    ) -> AXElement {
        AXElement(
            stableID: id,
            role: role,
            label: label,
            frame: AXElementFrame(x: 10, y: 10, width: 80, height: 24),
            isActionable: true
        )
    }

    func testSnapshotRoundTripsThroughCodable() throws {
        let snapshot = AXSnapshot(
            appBundleID: "com.apple.finder",
            windowTitle: "Desktop",
            elements: [element(id: "btn-1", label: "New Folder")]
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AXSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }

    func testActionableFiltering() {
        var inert = element(id: "text-1", role: .staticText)
        inert = AXElement(stableID: "text-1", role: .staticText, label: "Title", frame: AXElementFrame(x: 0, y: 0, width: 40, height: 12), isActionable: false)
        let snapshot = AXSnapshot(
            appBundleID: "com.apple.finder",
            windowTitle: "Desktop",
            elements: [element(id: "btn-1"), inert]
        )
        XCTAssertEqual(snapshot.actionableElements().map(\.stableID), ["btn-1"])
    }

    func testChangeDetectorDetectsAddedAndRemovedElements() {
        let detector = ScreenChangeDetector()
        let before = AXSnapshot(appBundleID: "x", windowTitle: "Same", elements: [
            element(id: "a"), element(id: "b"),
        ])
        let after = AXSnapshot(appBundleID: "x", windowTitle: "Same", elements: [
            element(id: "a"), element(id: "c"),
        ])
        XCTAssertTrue(detector.didChange(from: before, to: after))
    }

    func testChangeDetectorIgnoresIdenticalScreens() {
        let detector = ScreenChangeDetector()
        let before = AXSnapshot(appBundleID: "x", windowTitle: "Same", elements: [element(id: "a")])
        let after = AXSnapshot(appBundleID: "x", windowTitle: "Same", elements: [element(id: "a")])
        XCTAssertFalse(detector.didChange(from: before, to: after))
    }

    func testChangeDetectorCountsTitleChangeAlone() {
        let detector = ScreenChangeDetector()
        let before = AXSnapshot(appBundleID: "x", windowTitle: "General", elements: [])
        XCTAssertTrue(detector.didChange(from: before, titleAfter: "Accessibility"))
    }
}
