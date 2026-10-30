import AppKit
import XCTest
import PerryBrain
import PerryCore
import PerryGuide
import PerryOverlay
@testable import Perry

@MainActor
final class PointerTraceRecorderTests: XCTestCase {
    func testRecordsSamplesWithWindowAndPerryFlags() {
        var point = CGPoint(x: 100, y: 100)
        let recorder = PointerTraceRecorder(
            point: { point },
            perryFrames: { [CGRect(x: 0, y: 0, width: 50, height: 50)] },
            windowUnder: { _ in 42 },
            now: { 10 }
        )
        recorder.start()
        let first = recorder.record()
        XCTAssertEqual(first.windowID, 42)
        XCTAssertFalse(first.overPerry)
        point = CGPoint(x: 10, y: 10)
        let second = recorder.record()
        XCTAssertTrue(second.overPerry)
        let samples = recorder.stop()
        XCTAssertEqual(samples.count, 2)
    }

    func testRingBufferDropsOldestBeyondCapacity() {
        let recorder = PointerTraceRecorder(
            point: { .zero },
            capacity: 3,
            now: { 0 }
        )
        for _ in 0..<5 { recorder.record() }
        XCTAssertEqual(recorder.samples.count, 3)
    }

    /// Regression: Talk shows a full-screen click-through overlay before the
    /// trace starts. If that window counted as "Perry UI", every sample would
    /// be flagged overPerry and deixis could never bind. Only Perry windows
    /// the user can actually interact with may flag a sample.
    func testClickThroughAndInvisibleWindowsDoNotCountAsPerry() {
        guard let screen = NSScreen.screens.first else { return }
        let clickThrough = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        clickThrough.ignoresMouseEvents = true
        clickThrough.orderFrontRegardless()
        let invisible = NSPanel(
            contentRect: NSRect(x: 50, y: 50, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 100, y: 100, width: 200, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.orderFrontRegardless()
        defer {
            clickThrough.orderOut(nil)
            invisible.orderOut(nil)
            panel.orderOut(nil)
        }

        let frames = PointerTraceRecorder.perryInteractiveFrames(
            of: [clickThrough, invisible, panel],
            primaryMaxY: screen.frame.maxY
        )
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.width, 200)
    }

    /// Integration: drive the real overlay machinery and prove the windows it
    /// orders can never leak into the deixis "over Perry" set.
    func testLiveOverlayWindowsAreNotCountedAsPerry() {
        let manager = OverlayWindowManager()
        manager.showOverlay(onScreens: NSScreen.screens, state: PerryCursorState())
        defer { manager.hideOverlay() }

        let maxY = NSScreen.screens.first?.frame.maxY ?? 0
        let flagged = PointerTraceRecorder.perryWindowFramesInAXSpace()
        for window in NSApp.windows where window.ignoresMouseEvents {
            let ax = CGRect(
                x: window.frame.minX,
                y: maxY - window.frame.maxY,
                width: window.frame.width,
                height: window.frame.height
            )
            XCTAssertFalse(
                flagged.contains(ax),
                "click-through Perry window leaked into the deixis frame set"
            )
        }
    }
}
