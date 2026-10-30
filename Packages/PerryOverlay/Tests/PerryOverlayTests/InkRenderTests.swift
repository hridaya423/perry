import AppKit
import SwiftUI
import XCTest
@testable import PerryOverlay

@MainActor
final class InkRenderTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let target = CGRect(x: 150, y: 100, width: 100, height: 60)
    private var window: NSWindow?

    override func tearDown() {
        window?.orderOut(nil)
        super.tearDown()
    }

    private func showOverlay(_ state: PerryCursorState) -> NSView {
        state.overlayVisible = true
        let view = NSHostingView(rootView: PerryOverlaySurface(screenFrame: frame, cursorState: state))
        view.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return view
    }

    func testMarksAddedWhileTheOverlayIsShowingGetDrawn() throws {
        let state = PerryCursorState()
        let view = showOverlay(state)

        XCTAssertEqual(try inkedPixels(in: view), 0)
        state.visualGuidanceOverlays = [
            .ringMark(around: target, accentHex: "#9CCBB6"),
            .arrowMark(to: target.offsetBy(dx: 0, dy: 120), accentHex: "#9CCBB6"),
        ]
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        XCTAssertGreaterThan(try inkedPixels(in: view), 60)
    }

    func testAMarkCaptionSitsBesideItsMarkWithoutCoveringIt() throws {
        let state = PerryCursorState()
        let view = showOverlay(state)
        state.visualGuidanceOverlays = [.ringMark(around: target, accentHex: "#9CCBB6", caption: "Per cent")]
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        let ring = PerryOverlaySpace.localRect(target.insetBy(dx: -8, dy: -8), in: frame)
        let caption = try XCTUnwrap(try captionBounds(in: view))
        XCTAssertFalse(caption.intersects(ring), "\(caption) covers \(ring)")
        XCTAssertEqual(caption.midX, ring.midX, accuracy: 6)
        XCTAssertLessThan(caption.minY - ring.maxY, 24)
    }

    func testAGuideStepLabelSitsBesideItsControlWithoutCoveringIt() throws {
        let state = PerryCursorState()
        let view = showOverlay(state)
        state.activeControlGlowLabel = "Click Appearance"
        state.activeControlGlowRect = target
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        let control = PerryOverlaySpace.localRect(target, in: frame)
        let caption = try XCTUnwrap(try captionBounds(in: view))
        XCTAssertFalse(caption.intersects(control), "\(caption) covers \(control)")
        XCTAssertEqual(caption.midX, control.midX, accuracy: 6)
    }

    func testAPointMarkIsBigEnoughToSee() throws {
        let state = PerryCursorState()
        let view = showOverlay(state)
        state.visualGuidanceOverlays = [.pointMark(center: CGPoint(x: target.midX, y: target.midY), accentHex: "#9CCBB6")]
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        let ink = try XCTUnwrap(try pixelBounds(in: view, where: Self.isInk))
        XCTAssertGreaterThan(ink.width, 40)
        XCTAssertGreaterThan(ink.height, 55)
    }

    private static func isInk(_ color: NSColor) -> Bool {
        color.alphaComponent > 0.5 && color.greenComponent > 0.6 && color.greenComponent > color.redComponent + 0.1
    }

    private static func isCaption(_ color: NSColor) -> Bool {
        color.alphaComponent > 0.8 && color.redComponent > 0.9 && color.greenComponent > 0.9 && color.blueComponent > 0.9
    }

    private func captionBounds(in view: NSView) throws -> CGRect? {
        try pixelBounds(in: view, where: Self.isCaption)
    }

    private func pixelBounds(in view: NSView, where matches: (NSColor) -> Bool) throws -> CGRect? {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        var bounds: CGRect?
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), matches(color) else { continue }
                let pixel = CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: 1 / scale, height: 1 / scale)
                bounds = bounds?.union(pixel) ?? pixel
            }
        }
        return bounds
    }

    private func inkedPixels(in view: NSView) throws -> Int {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        var inked = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if Self.isInk(color) { inked += 1 }
            }
        }
        return inked
    }
}
