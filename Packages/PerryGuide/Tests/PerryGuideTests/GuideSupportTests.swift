import XCTest
@testable import PerryGuide
import PerryOverlay
import PerryCore

final class GuideSupportTests: XCTestCase {
    private func button(_ id: String, x: Double, label: String?) -> AXElement {
        AXElement(
            stableID: id,
            role: .button,
            label: label,
            frame: AXElementFrame(x: x, y: 40, width: 90, height: 30),
            isActionable: true
        )
    }

    func testEverythingViewBuildsNumberedMarkersWithConnectors() {
        let snapshot = AXSnapshot(
            appBundleID: "com.apple.finder",
            windowTitle: "Desktop",
            elements: [button("a", x: 0, label: "First"), button("b", x: 200, label: "Second")]
        )
        let steps = [
            GuideStep(instruction: "this one First", target: .axElement(stableID: "a")),
            GuideStep(instruction: "next one Second", target: .axElement(stableID: "b")),
        ]

        let viewPlan = EverythingViewBuilder.build(steps: steps, snapshot: snapshot, goal: "tag a file")

        XCTAssertNotNil(viewPlan)
        XCTAssertEqual(viewPlan?.markers.map(\.number), [1, 2])
        XCTAssertEqual(viewPlan?.markers.count, 2)
        XCTAssertEqual(viewPlan?.connectors.count, 1)
        XCTAssertEqual(viewPlan?.markers[1].position.x ?? 0, 245)
    }

    func testEverythingViewSkipsMissingTargetsAndVerbalSteps() {
        let snapshot = AXSnapshot(
            appBundleID: "x",
            windowTitle: "W",
            elements: [button("exists", x: 10, label: nil)]
        )
        let steps = [
            GuideStep(instruction: "gone", target: .axElement(stableID: "missing")),
            GuideStep(instruction: "just words", target: .verbalOnly),
            GuideStep(instruction: "real one", target: .axElement(stableID: "exists")),
        ]

        let viewPlan = EverythingViewBuilder.build(steps: steps, snapshot: snapshot)
        XCTAssertEqual(viewPlan?.markers.count, 1)
        XCTAssertEqual(viewPlan?.connectors.count, 0)
    }

    func testEverythingViewNilWhenNothingDrawable() {
        let snapshot = AXSnapshot(appBundleID: "x", windowTitle: "W", elements: [])
        let steps = [GuideStep(instruction: "words", target: .verbalOnly)]
        XCTAssertNil(EverythingViewBuilder.build(steps: steps, snapshot: snapshot))
    }
}

final class GuideIntentParserTests: XCTestCase {
    func testGuideTriggers() {
        XCTAssertEqual(GuideIntentParser.parse("show me how to tag files"), .guide(goal: "how to tag files"))
        XCTAssertEqual(GuideIntentParser.parse("teach me the export flow"), .guide(goal: "the export flow"))
        XCTAssertEqual(GuideIntentParser.parse("how do I rename a clip"), .guide(goal: "rename a clip"))
    }

    func testShowEverythingTriggerWinsOverGuide() {
        XCTAssertEqual(
            GuideIntentParser.parse("show me everything for exporting"),
            .showEverything(goal: "for exporting")
        )
    }

    func testDoTrigger() {
        XCTAssertEqual(GuideIntentParser.parse("Perry, do the weekly backup"), .doTask(goal: "the weekly backup"))
    }

    func testDismissals() {
        XCTAssertEqual(GuideIntentParser.parse("stop"), .dismiss)
        XCTAssertEqual(GuideIntentParser.parse("cancel"), .dismiss)
    }

    func testNonRequestsAreRejected() {
        XCTAssertEqual(GuideIntentParser.parse(""), .notAGuideRequest)
        XCTAssertEqual(GuideIntentParser.parse("what a lovely day"), .notAGuideRequest)
        XCTAssertEqual(GuideIntentParser.parse("help me write a poem"), .notAGuideRequest)
    }
}
