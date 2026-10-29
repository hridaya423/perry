import AppKit
import SwiftUI
import XCTest
@testable import PerryOverlay

@MainActor
final class InkRenderTests: XCTestCase {
    func testMarksAddedWhileTheOverlayIsShowingGetDrawn() throws {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let target = CGRect(x: 150, y: 100, width: 100, height: 60)
        let state = PerryCursorState()
        state.overlayVisible = true
        let view = NSHostingView(rootView: PerryOverlaySurface(screenFrame: frame, cursorState: state))
        view.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(try inkedPixels(in: view), 0)
        state.visualGuidanceOverlays = [
            .ringMark(around: target, accentHex: "#34D399"),
            .arrowMark(to: target.offsetBy(dx: 0, dy: 120), accentHex: "#34D399"),
        ]
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        XCTAssertGreaterThan(try inkedPixels(in: view), 60)
    }

    private func inkedPixels(in view: NSView) throws -> Int {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        var inked = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.alphaComponent > 0.5, color.greenComponent > 0.6, color.redComponent < 0.5 { inked += 1 }
            }
        }
        return inked
    }
}
