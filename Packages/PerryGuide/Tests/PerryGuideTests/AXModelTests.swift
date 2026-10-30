import XCTest
@testable import PerryGuide
import PerryCore

final class AXModelTests: XCTestCase {
    private func element(
        id: String,
        role: AXElement.Role = .button,
        label: String? = nil,
        frame: AXElementFrame = AXElementFrame(x: 10, y: 10, width: 80, height: 24)
    ) -> AXElement {
        AXElement(
            stableID: id,
            role: role,
            label: label,
            frame: frame,
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

    func testMissingSensitivityDecodesAsUnknown() throws {
        let json = #"{"stableID":"f1","role":"textField","label":"Name","frame":{"x":0,"y":0,"width":100,"height":24},"isActionable":true}"#
        let decoded = try JSONDecoder().decode(AXElement.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.sensitivity, .unknown)
        XCTAssertNil(decoded.value)
        XCTAssertNil(decoded.rawRole)
        XCTAssertNil(decoded.subrole)
    }

    func testUnrecognizedSensitivityDecodesAsUnknown() throws {
        let json = #"{"stableID":"f1","role":"textField","label":null,"frame":{"x":0,"y":0,"width":100,"height":24},"isActionable":true,"sensitivity":"totally-fine"}"#
        let decoded = try JSONDecoder().decode(AXElement.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.sensitivity, .unknown)
    }

    func testValueStaysSeparateFromLabel() throws {
        let field = AXElement(
            stableID: "f1",
            role: .textField,
            label: "Username",
            frame: AXElementFrame(x: 0, y: 0, width: 100, height: 24),
            isActionable: true,
            value: "alice",
            sensitivity: .ordinary
        )
        let decoded = try JSONDecoder().decode(AXElement.self, from: JSONEncoder().encode(field))
        XCTAssertEqual(decoded.label, "Username")
        XCTAssertEqual(decoded.value, "alice")
        XCTAssertEqual(decoded.sensitivity, .ordinary)
        XCTAssertEqual(decoded, field)
    }

    func testSensitiveAndUnknownValuesAreDiscardedBeforeEncoding() throws {
        for sensitivity in [AXSensitivity.secure, .unknown] {
            let field = AXElement(
                stableID: "f1", role: .textField, label: "Input",
                frame: AXElementFrame(x: 0, y: 0, width: 100, height: 24),
                isActionable: true, value: "private-sentinel", sensitivity: sensitivity
            )
            XCTAssertNil(field.value)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(field), as: UTF8.self).contains("private-sentinel"))
            let json = """
            {"stableID":"f1","role":"textField","label":"Input","value":"private-sentinel","frame":{"x":0,"y":0,"width":100,"height":24},"isActionable":true,"sensitivity":"\(sensitivity.rawValue)"}
            """
            let decoded = try JSONDecoder().decode(AXElement.self, from: Data(json.utf8))
            XCTAssertNil(decoded.value)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("private-sentinel"))
        }
    }

    func testObservationCarriesExplicitID() {
        let snapshot = AXSnapshot(appBundleID: "x", windowTitle: "w", elements: [])
        let driverBound = GuideObservation(snapshot: snapshot, observationID: "snapshot-7")
        XCTAssertEqual(driverBound.observationID, "snapshot-7")
        let generated = GuideObservation(snapshot: snapshot)
        XCTAssertFalse(generated.observationID.isEmpty)
        XCTAssertNotEqual(generated.observationID, GuideObservation(snapshot: snapshot).observationID)
    }

    func testAStepFollowsItsControlIntoTheNextReadEvenWhenIndexesShift() {
        let earlier = AXSnapshot(appBundleID: "com.apple.systempreferences", windowTitle: "General", elements: [
            element(id: "s00000001:12", label: "Appearance", frame: AXElementFrame(x: 10, y: 200, width: 180, height: 24)),
            element(id: "s00000001:13", label: "Desktop & Dock", frame: AXElementFrame(x: 10, y: 224, width: 180, height: 24)),
            element(id: "s00000001:14", label: "Play", frame: AXElementFrame(x: 300, y: 40, width: 40, height: 20)),
        ])
        let later = AXSnapshot(appBundleID: "com.apple.systempreferences", windowTitle: "Appearance", elements: [
            element(id: "s00000002:12", label: "Dark", frame: AXElementFrame(x: 400, y: 120, width: 60, height: 40)),
            element(id: "s00000002:13", label: "Appearance", frame: AXElementFrame(x: 10, y: 200, width: 180, height: 24)),
            element(id: "s00000002:15", label: "Pause", frame: AXElementFrame(x: 300, y: 40, width: 40, height: 20)),
        ])
        let step = GuideStep(
            instruction: "Click Appearance", target: .axElement(stableID: "s00000001:12"),
            postcondition: .elementAbsent(stableID: "s00000001:13")
        )

        let moved = step.rebound(from: earlier, to: later)
        XCTAssertEqual(moved.target, .axElement(stableID: "s00000002:13"))
        XCTAssertTrue(try XCTUnwrap(moved.postcondition).isSatisfied(in: later))
        XCTAssertNil(later.element(withStableID: "s00000001:12"))
        XCTAssertTrue(GuidePostcondition.elementLabelEquals(stableID: "s00000001:14", label: "Pause")
            .rebound(from: earlier, to: later).isSatisfied(in: later))
        XCTAssertFalse(GuidePostcondition.elementExists(stableID: "s00000001:13")
            .rebound(from: earlier, to: later).isSatisfied(in: later))
    }
}
