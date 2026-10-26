@testable import PerryBrain
import CoreGraphics
import XCTest

final class TalkPromptTests: XCTestCase {
    private func element(_ id: String, label: String, windowID: Int = 42) -> ObservedElement {
        ObservedElement(
            id: id, role: "AXButton", label: label,
            frame: CGRect(x: 0, y: 0, width: 10, height: 10), windowID: windowID
        )
    }

    func testElementIndexDeterministicIDs() {
        let index = ElementIndex(elements: [element("ax-export", label: "Export"), element("ax-save", label: "Save")])
        XCTAssertEqual(index.entries.map(\.compactID), ["e1", "e2"])
        XCTAssertEqual(index.validIDs, ["e1", "e2"])
        XCTAssertEqual(index.element(for: "e1")?.id, "ax-export")
        XCTAssertEqual(index.compactID(forElementID: "ax-save"), "e2")
        XCTAssertNil(index.element(for: "e3"))
    }

    func testContextContainsElementsBindingsMemorySkill() {
        let index = ElementIndex(elements: [element("ax-export", label: "Export")])
        let binding = DeixisBinding(
            word: "this", time: 1.0, point: CGPoint(x: 5, y: 5),
            windowID: 42, element: index.entries[0].element, isWindowLevel: false
        )
        let prompt = TalkPrompt.context(index: index, bindings: [binding], memory: "User likes dark mode.", skill: "Figma skill body")
        XCTAssertTrue(prompt.contains("e1 AXButton \"Export\" window 42"))
        XCTAssertTrue(prompt.contains("(1) \"this\" → AXButton \"Export\" in window 42"))
        XCTAssertTrue(prompt.contains("Memory:\nUser likes dark mode."))
        XCTAssertTrue(prompt.contains("Figma skill body"))
    }

    func testEmptyContextIsEmpty() {
        XCTAssertEqual(TalkPrompt.context(index: ElementIndex(elements: [])), "")
    }
}
