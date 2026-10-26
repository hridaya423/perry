import XCTest
import PerryGuide
@testable import Perry

@MainActor
final class DemonstrationRecorderTests: XCTestCase {
    private func makeElement(stableID: String, label: String, frame: AXElementFrame, sensitivity: AXSensitivity = .ordinary) -> AXElement {
        AXElement(
            stableID: stableID,
            role: .button,
            label: label,
            frame: frame,
            isActionable: true,
            sensitivity: sensitivity
        )
    }

    private func makeRecorder(elements: [AXElement]) -> DemonstrationRecorder {
        DemonstrationRecorder(
            observe: {
                GuideObservation(snapshot: AXSnapshot(appBundleID: "com.example.app", windowTitle: "Main", elements: elements))
            },
            bundleIDProvider: { "com.example.app" }
        )
    }

    func testClickInsideElementRecordsAnchor() async {
        let element = makeElement(stableID: "ax-save", label: "Save", frame: AXElementFrame(x: 10, y: 10, width: 40, height: 20))
        let recorder = makeRecorder(elements: [element])
        recorder.start()
        await recorder.recordClick(axPoint: CGPointShim(x: 20, y: 15))
        let demo = await recorder.stop()
        XCTAssertEqual(demo?.events, [.click(RoutineTarget(role: "button", label: "Save"))])
        XCTAssertEqual(demo?.bundleID, "com.example.app")
    }

    func testClickOutsideEveryElementIsDropped() async {
        let element = makeElement(stableID: "ax-save", label: "Save", frame: AXElementFrame(x: 10, y: 10, width: 40, height: 20))
        let recorder = makeRecorder(elements: [element])
        recorder.start()
        await recorder.recordClick(axPoint: CGPointShim(x: 500, y: 500))
        let demo = await recorder.stop()
        XCTAssertNil(demo)
    }

    func testTypedTextFollowsLastClickTargetAndSecureFieldsDropText() async {
        let field = AXElement(
            stableID: "ax-field", role: .textField, label: "Notes",
            frame: AXElementFrame(x: 0, y: 0, width: 100, height: 20),
            isActionable: true, sensitivity: .ordinary
        )
        let secret = AXElement(
            stableID: "ax-secret", role: .textField, label: "Password",
            frame: AXElementFrame(x: 0, y: 30, width: 100, height: 20),
            isActionable: true, sensitivity: .secure
        )
        let recorder = makeRecorder(elements: [field, secret])
        recorder.start()
        await recorder.recordClick(axPoint: CGPointShim(x: 10, y: 10))
        recorder.recordKey(characters: "hello", keyCode: 4, modifiers: [])
        await recorder.recordClick(axPoint: CGPointShim(x: 10, y: 40))
        recorder.recordKey(characters: "s3cret", keyCode: 4, modifiers: [])
        let demo = await recorder.stop()
        XCTAssertEqual(demo?.events, [
            .click(RoutineTarget(role: "textField", label: "Notes")),
            .typed(text: "hello", into: RoutineTarget(role: "textField", label: "Notes")),
            .click(RoutineTarget(role: "textField", label: "Password"))
        ])
    }

    func testTimeLimitWarnsThenSignalsStop() async throws {
        var warnings = 0
        var limitHit = false
        let recorder = DemonstrationRecorder(
            observe: { GuideObservation(snapshot: AXSnapshot(appBundleID: "com.example.app", windowTitle: "Main", elements: [])) },
            bundleIDProvider: { "com.example.app" },
            maximumDuration: .milliseconds(120),
            warningLead: .milliseconds(40),
            onLimitWarning: { warnings += 1 },
            onTimeLimit: { limitHit = true }
        )
        recorder.start()
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(warnings, 1)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(limitHit)
        _ = await recorder.stop()
    }

    func testNamedKeysRecordPressesAndModifierChordsAreNotText() async {
        let recorder = makeRecorder(elements: [])
        recorder.start()
        recorder.recordKey(characters: "\r", keyCode: 36, modifiers: [])
        recorder.recordKey(characters: " ", keyCode: 49, modifiers: [])
        recorder.recordKey(characters: "a", keyCode: 0, modifiers: [.function])
        recorder.recordKey(characters: "a", keyCode: 0, modifiers: [])
        let demo = await recorder.stop()
        XCTAssertEqual(demo?.events, [
            .keyPress("return"),
            .keyPress("space"),
            .typed(text: "a", into: nil)
        ])
    }

    func testCommandChordIsRecordedNotDropped() async {
        let recorder = makeRecorder(elements: [])
        recorder.start()
        recorder.recordKey(characters: "c", keyCode: 8, modifiers: [.command])
        recorder.recordKey(characters: "S", charactersIgnoringModifiers: "s", keyCode: 1, modifiers: [.command, .shift])
        recorder.recordKey(characters: " ", keyCode: 49, modifiers: [.command])
        recorder.recordKey(characters: ",", charactersIgnoringModifiers: ",", keyCode: 43, modifiers: [.command])
        let demo = await recorder.stop()
        XCTAssertEqual(demo?.events, [
            .chord(key: "c", modifiers: ["command"]),
            .chord(key: "s", modifiers: ["command", "shift"]),
            .chord(key: "space", modifiers: ["command"])
        ])
    }
}
