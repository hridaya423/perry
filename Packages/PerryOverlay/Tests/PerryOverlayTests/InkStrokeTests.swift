import XCTest
import SwiftUI
@testable import PerryOverlay

final class InkStrokeTests: XCTestCase {
    private let line = [CGPoint(x: 0, y: 0), CGPoint(x: 60, y: 4), CGPoint(x: 120, y: 0)]

    func testSampledIsDeterministicPerSeed() {
        let a = InkStroke.sampled(through: line, seed: 42)
        let b = InkStroke.sampled(through: line, seed: 42)
        XCTAssertEqual(a, b)
        let c = InkStroke.sampled(through: line, seed: 43)
        XCTAssertNotEqual(a, c)
    }

    func testSampledDensifiesAndPreservesEndpoints() {
        let out = InkStroke.sampled(through: line, step: 2.5, jitter: 0.6, seed: 1)
        XCTAssertGreaterThan(out.count, line.count)
        XCTAssertEqual(out.first, line.first)
        XCTAssertEqual(out.last, line.last)
    }

    func testZeroJitterStaysOnTheSpline() {
        // A straight segment with zero jitter keeps every sample on the line.
        let out = InkStroke.sampled(
            through: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)],
            jitter: 0, seed: 9
        )
        for p in out {
            XCTAssertEqual(p.y, 0, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(p.x, -0.001)
            XCTAssertLessThanOrEqual(p.x, 100.001)
        }
    }

    func testJitterIsBounded() {
        let jitter: CGFloat = 0.6
        let out = InkStroke.sampled(
            through: [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0)],
            jitter: jitter, seed: 7
        )
        for p in out.dropFirst().dropLast() {
            XCTAssertLessThanOrEqual(abs(p.y), jitter + 0.001)
        }
    }

    func testWidthsMatchSampleCountAndTaperEnds() {
        let widths = InkStroke.widths(count: 20, baseWidth: 5, seed: 3)
        XCTAssertEqual(widths.count, 20)
        XCTAssertLessThan(widths[0], widths[10]) // taper in
        XCTAssertLessThan(widths[19], widths[10]) // taper out
        for w in widths {
            XCTAssertGreaterThanOrEqual(w, 0.5)
            XCTAssertLessThanOrEqual(w, 5.9) // base * 1.0 taper * 1.18 wobble ceiling
        }
    }

    func testPointOnSamplesTracksArcLength() {
        let samples = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 100, y: 0)]
        XCTAssertEqual(InkStroke.point(on: samples, progress: 0)?.x ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(InkStroke.point(on: samples, progress: 0.5)?.x ?? -1, 50, accuracy: 0.01)
        XCTAssertEqual(InkStroke.point(on: samples, progress: 1)?.x ?? -1, 100, accuracy: 0.01)
        XCTAssertNil(InkStroke.point(on: [], progress: 0.5))
    }

    func testStrokeShapeDrawOnProgressGrows() {
        let samples = InkStroke.sampled(through: line, jitter: 0, seed: 1)
        let widths = InkStroke.widths(count: samples.count, baseWidth: 4, seed: 1)
        let half = InkStrokeShape(samples: samples, widths: widths, progress: 0.4)
            .path(in: .zero).boundingRect
        let full = InkStrokeShape(samples: samples, widths: widths, progress: 1)
            .path(in: .zero).boundingRect
        XCTAssertFalse(half.isNull)
        XCTAssertGreaterThan(full.width, half.width)
    }

    func testStrokeShapeRejectsMismatchedWidths() {
        let path = InkStrokeShape(
            samples: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)],
            widths: [4]
        ).path(in: .zero)
        XCTAssertTrue(path.isEmpty)
    }
}

final class InkColorTests: XCTestCase {
    private func patch(_ r: UInt8, _ g: UInt8, _ b: UInt8, pixels: Int = 24 * 24) -> [UInt8] {
        var data = [UInt8]()
        for _ in 0..<pixels { data.append(contentsOf: [r, g, b, 255]) }
        return data
    }

    func testLuminanceExtremes() {
        patch(0, 0, 0).withUnsafeBufferPointer {
            XCTAssertEqual(InkColor.luminance(of: $0) ?? -1, 0, accuracy: 0.001)
        }
        patch(255, 255, 255).withUnsafeBufferPointer {
            XCTAssertEqual(InkColor.luminance(of: $0) ?? -1, 1, accuracy: 0.001)
        }
    }

    func testDarkGetsMintLightGetsTeal() {
        XCTAssertEqual(InkColor.hex(forLuminance: 0.1), InkColor.onDarkHex)
        XCTAssertEqual(InkColor.hex(forLuminance: 0.9), InkColor.onLightHex)
        XCTAssertEqual(InkColor.hex(forLuminance: InkColor.threshold), InkColor.onLightHex)
    }

    func testEmptyPatchReturnsNil() {
        [UInt8]().withUnsafeBufferPointer {
            XCTAssertNil(InkColor.luminance(of: $0))
        }
        [UInt8](repeating: 0, count: 3).withUnsafeBufferPointer {
            XCTAssertNil(InkColor.luminance(of: $0))
        }
    }
}

final class CaptionPlacerTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 120, height: 32)

    func testPrefersBelowWhenClear() {
        let anchor = CGRect(x: 600, y: 300, width: 80, height: 40)
        let placed = CaptionPlacer.place(size: size, anchor: anchor, in: screen)
        XCTAssertEqual(placed.minY, anchor.maxY + CaptionPlacer.defaultGap, accuracy: 0.5)
        XCTAssertFalse(placed.intersects(anchor))
    }

    func testPrefersBelowForFractionalCaptionSizes() {
        let anchor = CGRect(x: 150, y: 140, width: 100, height: 60)
        let placed = CaptionPlacer.place(
            size: CGSize(width: 123.6, height: 25), anchor: anchor,
            in: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        XCTAssertEqual(placed.minY, anchor.maxY + CaptionPlacer.defaultGap, accuracy: 0.5)
    }

    func testFlipsAboveWhenBottomIsCrowded() {
        // Target hugging the bottom edge: below overflows, above is clean.
        let anchor = CGRect(x: 600, y: 860, width: 80, height: 40)
        let placed = CaptionPlacer.place(size: size, anchor: anchor, in: screen)
        XCTAssertLessThan(placed.maxY, anchor.minY)
        XCTAssertTrue(screen.contains(placed))
    }

    func testAvoidsObstacleRect() {
        let anchor = CGRect(x: 600, y: 300, width: 80, height: 40)
        // Block the below slot so "above" wins.
        let obstacle = CGRect(x: 540, y: 340, width: 320, height: 60)
        let placed = CaptionPlacer.place(size: size, anchor: anchor, avoiding: [obstacle], in: screen)
        XCTAssertLessThan(placed.maxY, anchor.minY)
        XCTAssertFalse(placed.intersects(obstacle))
    }

    func testNeverLeavesScreen() {
        let anchor = CGRect(x: 1390, y: 860, width: 40, height: 30)
        let placed = CaptionPlacer.place(size: size, anchor: anchor, in: screen)
        XCTAssertTrue(screen.contains(placed), "placed \(placed) must fit \(screen)")
    }

    func testNegativeOriginMultiDisplay() {
        let leftScreen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let anchor = CGRect(x: -1400, y: 300, width: 80, height: 40)
        let placed = CaptionPlacer.place(size: size, anchor: anchor, in: leftScreen)
        XCTAssertTrue(leftScreen.contains(placed))
        XCTAssertFalse(placed.intersects(anchor))
    }

    func testOversizedCaptionCentersOnScreen() {
        let huge = CGSize(width: 2000, height: 1200)
        let anchor = CGRect(x: 600, y: 300, width: 80, height: 40)
        let placed = CaptionPlacer.place(size: huge, anchor: anchor, in: screen)
        XCTAssertEqual(placed.midX, screen.midX, accuracy: 1)
        XCTAssertEqual(placed.midY, screen.midY, accuracy: 1)
    }
}

@MainActor
final class CaptionLayoutTests: XCTestCase {
    func testCaptionsOfNeighbouringMarksNeitherOverlapNorCoverAMark() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let state = PerryCursorState()
        let left = CGRect(x: 300, y: 300, width: 60, height: 40)
        state.visualGuidanceOverlays = [
            .ringMark(around: left, caption: "Seven"),
            .ringMark(around: left.offsetBy(dx: 64, dy: 0), caption: "Eight"),
        ]
        state.activeControlGlowRect = left.offsetBy(dx: 0, dy: -60)
        state.activeControlGlowLabel = "Click Four"

        let layout = state.captionLayout(in: screen)
        let captions = [layout.stepLabel].compactMap { $0 } + layout.markCaptions.values
        XCTAssertEqual(captions.count, 3)
        for (i, a) in captions.enumerated() {
            for b in captions.dropFirst(i + 1) { XCTAssertFalse(a.intersects(b), "\(a) overlaps \(b)") }
            for mark in state.localMarkRects(in: screen) { XCTAssertFalse(a.intersects(mark), "\(a) covers \(mark)") }
        }
        XCTAssertEqual(layout.obstacles.count, 6)
    }
}
