@testable import PerryBrain
import CoreGraphics
import XCTest

final class DeixisResolverTests: XCTestCase {
    private func element(_ id: String, role: String = "AXButton", label: String = "Export",
                         frame: CGRect, windowID: Int = 42) -> ObservedElement {
        ObservedElement(id: id, role: role, label: label, frame: frame, windowID: windowID)
    }

    func testSingleThis() {
        let export = element("export", frame: CGRect(x: 100, y: 100, width: 80, height: 30))
        let trace = [
            TraceSample(t: 0, point: CGPoint(x: 10, y: 10), windowID: 42),
            TraceSample(t: 1.0, point: CGPoint(x: 140, y: 115), windowID: 42),
        ]
        let words = [SpokenWord(text: "this", start: 1.0, duration: 0.2)]
        let bindings = DeixisResolver.resolve(words: words, trace: trace, elements: [export])
        XCTAssertEqual(bindings.count, 1)
        XCTAssertEqual(bindings[0].element?.id, "export")
        XCTAssertEqual(bindings[0].point, CGPoint(x: 140, y: 115))
        XCTAssertEqual(bindings[0].windowID, 42)
        XCTAssertFalse(bindings[0].isWindowLevel)
    }

    func testMoveThisHereBindsTwoElements() {
        let source = element("source", label: "Source", frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        let target = element("target", label: "Target", frame: CGRect(x: 300, y: 300, width: 50, height: 50))
        let trace = [
            TraceSample(t: 0, point: CGPoint(x: 25, y: 25), windowID: 42),
            TraceSample(t: 1.0, point: CGPoint(x: 25, y: 25), windowID: 42),
            TraceSample(t: 2.0, point: CGPoint(x: 325, y: 325), windowID: 42),
        ]
        let words = [
            SpokenWord(text: "move", start: 0.8, duration: 0.2),
            SpokenWord(text: "this", start: 1.0, duration: 0.2),
            SpokenWord(text: "over", start: 1.4, duration: 0.2),
            SpokenWord(text: "here", start: 2.0, duration: 0.2),
        ]
        let bindings = DeixisResolver.resolve(words: words, trace: trace, elements: [source, target])
        XCTAssertEqual(bindings.count, 2)
        XCTAssertEqual(bindings[0].element?.id, "source")
        XCTAssertEqual(bindings[1].element?.id, "target")
    }

    func testStillPointerOnElementBindsElement() {
        // Holding the pointer steady on a control while saying "this" is the
        // natural pointing gesture — it must bind the element, not the window.
        let trace = [
            TraceSample(t: 0, point: CGPoint(x: 100, y: 100), windowID: 42),
            TraceSample(t: 1, point: CGPoint(x: 102, y: 101), windowID: 42),
        ]
        let words = [SpokenWord(text: "this", start: 1, duration: 0.2)]
        let bindings = DeixisResolver.resolve(words: words, trace: trace, elements: [
            element("a", frame: CGRect(x: 90, y: 90, width: 40, height: 40)),
        ])
        XCTAssertEqual(bindings.count, 1)
        XCTAssertFalse(bindings[0].isWindowLevel)
        XCTAssertEqual(bindings[0].element?.id, "a")
        XCTAssertEqual(bindings[0].point, CGPoint(x: 100, y: 100))
        XCTAssertEqual(bindings[0].windowID, 42)
    }

    func testStillPointerOffElementIsWindowLevel() {
        let trace = [
            TraceSample(t: 0, point: CGPoint(x: 200, y: 200), windowID: 42),
            TraceSample(t: 1, point: CGPoint(x: 202, y: 201), windowID: 42),
        ]
        let words = [SpokenWord(text: "this", start: 1, duration: 0.2)]
        let bindings = DeixisResolver.resolve(words: words, trace: trace, elements: [
            element("a", frame: CGRect(x: 90, y: 90, width: 40, height: 40)),
        ])
        XCTAssertEqual(bindings.count, 1)
        XCTAssertTrue(bindings[0].isWindowLevel)
        XCTAssertNil(bindings[0].element)
        XCTAssertEqual(bindings[0].point, CGPoint(x: 200, y: 200))
        XCTAssertEqual(bindings[0].windowID, 42)
    }

    func testEmptyTraceIsWindowLevelWithZeroPoint() {
        let bindings = DeixisResolver.resolve(
            words: [SpokenWord(text: "that", start: 0, duration: 0.1)],
            trace: [], elements: []
        )
        XCTAssertEqual(bindings.count, 1)
        XCTAssertTrue(bindings[0].isWindowLevel)
        XCTAssertEqual(bindings[0].point, .zero)
        XCTAssertNil(bindings[0].windowID)
    }

    func testOverPerrySamplesIgnored() {
        let real = element("real", label: "Real", frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        let overlay = element("overlay", label: "Overlay", frame: CGRect(x: 200, y: 200, width: 50, height: 50))
        let trace = [
            TraceSample(t: 0, point: CGPoint(x: 25, y: 25), windowID: 42),
            // Pointer over a Perry overlay window near the word — must be skipped.
            TraceSample(t: 1.0, point: CGPoint(x: 225, y: 225), windowID: 42, overPerry: true),
            TraceSample(t: 1.1, point: CGPoint(x: 25, y: 25), windowID: 42),
            TraceSample(t: 2.0, point: CGPoint(x: 300, y: 300), windowID: 42),
        ]
        let words = [SpokenWord(text: "this", start: 1.05, duration: 0.1)]
        let bindings = DeixisResolver.resolve(words: words, trace: trace, elements: [real, overlay])
        XCTAssertEqual(bindings[0].element?.id, "real")
    }

    func testWindowOffsetsReResolveStaleElements() {
        // Element observed at (100,100) in window 42, which has since moved +50/+40.
        let stale = element("stale", frame: CGRect(x: 100, y: 100, width: 50, height: 50))
        let trace = [
            TraceSample(t: 0, point: CGPoint(x: 10, y: 10), windowID: 42),
            TraceSample(t: 1.0, point: CGPoint(x: 175, y: 165), windowID: 42),
        ]
        let words = [SpokenWord(text: "this", start: 1.0, duration: 0.2)]
        let bindings = DeixisResolver.resolve(
            words: words, trace: trace, elements: [stale],
            windowOffsets: [42: CGVector(dx: 50, dy: 40)]
        )
        XCTAssertEqual(bindings[0].element?.id, "stale")
        XCTAssertEqual(bindings[0].point, CGPoint(x: 175, y: 165))
    }

    func testEnglishDemonstratives() {
        for word in ["this", "That.", "HERE", "those", "it,"] {
            XCTAssertTrue(DeixisResolver.isDemonstrative(word), word)
        }
        XCTAssertFalse(DeixisResolver.isDemonstrative("button"))
    }

    func testSpanishDemonstratives() {
        for word in ["esto", "esa", "aquí", "allí"] {
            XCTAssertTrue(DeixisResolver.isDemonstrative(word), word)
        }
    }

    func testFrenchDemonstratives() {
        for word in ["ceci", "cela", "ici", "cette"] {
            XCTAssertTrue(DeixisResolver.isDemonstrative(word), word)
        }
    }

    func testGermanDemonstratives() {
        for word in ["das", "dieser", "hier", "dort"] {
            XCTAssertTrue(DeixisResolver.isDemonstrative(word), word)
        }
    }

    func testHindiDemonstratives() {
        for word in ["yahan", "vahan", "यह", "यहां", "वो"] {
            XCTAssertTrue(DeixisResolver.isDemonstrative(word), word)
        }
    }

    func testJapanesePrefixDemonstratives() {
        XCTAssertTrue(DeixisResolver.isDemonstrative("これ"))
        XCTAssertTrue(DeixisResolver.isDemonstrative("これは"))
        XCTAssertTrue(DeixisResolver.isDemonstrative("あそこ"))
        XCTAssertFalse(DeixisResolver.isDemonstrative("ボタン"))
    }

    func testChinesePrefixDemonstratives() {
        XCTAssertTrue(DeixisResolver.isDemonstrative("这"))
        XCTAssertTrue(DeixisResolver.isDemonstrative("这个按钮"))
        XCTAssertTrue(DeixisResolver.isDemonstrative("那里"))
        XCTAssertFalse(DeixisResolver.isDemonstrative("按钮"))
    }

    func testPointer200msBeforeWordStillBinds() {
        let export = element("export", frame: CGRect(x: 100, y: 100, width: 80, height: 30))
        let trace = [
            TraceSample(t: 0, point: CGPoint(x: 10, y: 10), windowID: 42),
            TraceSample(t: 0.8, point: CGPoint(x: 140, y: 115), windowID: 42),
        ]
        // Word at 1.0; window is [0.75, 1.2], so t=0.8 is inside the pointer lead.
        let words = [SpokenWord(text: "this", start: 1.0, duration: 0.2)]
        let bindings = DeixisResolver.resolve(words: words, trace: trace, elements: [export])
        XCTAssertEqual(bindings[0].element?.id, "export")
        XCTAssertEqual(bindings[0].point, CGPoint(x: 140, y: 115))
    }

    func testPointer400msBeforeFallsBackToLatestBefore() {
        let export = element("export", frame: CGRect(x: 100, y: 100, width: 80, height: 30))
        let trace = [
            TraceSample(t: 0, point: CGPoint(x: 10, y: 10), windowID: 42),
            TraceSample(t: 0.6, point: CGPoint(x: 140, y: 115), windowID: 42),
        ]
        // Word at 1.0; window is [0.75, 1.1], so t=0.6 is outside — latest-before wins.
        let words = [SpokenWord(text: "this", start: 1.0, duration: 0.1)]
        let bindings = DeixisResolver.resolve(words: words, trace: trace, elements: [export])
        XCTAssertEqual(bindings[0].element?.id, "export")
    }

    func testSmallestNestedElementWins() {
        let outer = element("outer", frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let inner = element("inner", frame: CGRect(x: 100, y: 100, width: 50, height: 50))
        let trace = [
            TraceSample(t: 0, point: CGPoint(x: 10, y: 10), windowID: 42),
            TraceSample(t: 1.0, point: CGPoint(x: 125, y: 125), windowID: 42),
        ]
        let words = [SpokenWord(text: "this", start: 1.0, duration: 0.2)]
        let bindings = DeixisResolver.resolve(words: words, trace: trace, elements: [outer, inner])
        XCTAssertEqual(bindings[0].element?.id, "inner")
    }

    func testContextLinesExactStrings() {
        let export = element("export", role: "AXButton", label: "Export",
                             frame: CGRect(x: 100, y: 100, width: 80, height: 30), windowID: 42)
        let trace = [
            TraceSample(t: 0, point: CGPoint(x: 512, y: 300), windowID: 42),
            TraceSample(t: 1.0, point: CGPoint(x: 140, y: 115), windowID: 42),
            TraceSample(t: 2.0, point: CGPoint(x: 512, y: 300), windowID: 42),
        ]
        let words = [
            SpokenWord(text: "this", start: 1.0, duration: 0.2),
            SpokenWord(text: "here", start: 2.0, duration: 0.2),
        ]
        let lines = DeixisResolver.contextLines(
            DeixisResolver.resolve(words: words, trace: trace, elements: [export])
        )
        XCTAssertEqual(lines, [
            "(1) \"this\" → AXButton \"Export\" in window 42",
            "(2) \"here\" → point (512, 300) in window 42",
        ])

        let still = DeixisResolver.contextLines(DeixisResolver.resolve(
            words: [SpokenWord(text: "this", start: 0, duration: 0.1)],
            trace: [TraceSample(t: 0, point: CGPoint(x: 1, y: 1), windowID: 42)],
            elements: [export]
        ))
        XCTAssertEqual(still, ["(1) \"this\" → the whole window 42"])

        let screen = DeixisResolver.contextLines(DeixisResolver.resolve(
            words: [SpokenWord(text: "this", start: 0, duration: 0.1)],
            trace: [], elements: []
        ))
        XCTAssertEqual(screen, ["(1) \"this\" → the whole screen"])
    }
}
