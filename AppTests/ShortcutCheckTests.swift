import AppKit
import SwiftUI
import XCTest
@testable import Perry

@MainActor
final class ShortcutCheckTests: XCTestCase {
    func testOnlyTheEventTapCountsAsHearingTheKeyEverywhere() {
        let check = ShortcutCheck()
        check.begin(captureMode: .fallbackMonitors)
        XCTAssertEqual(check.result, .needsInputMonitoring)
        XCTAssertFalse(check.intercept())
        check.begin(captureMode: nil)
        XCTAssertEqual(check.result, .needsInputMonitoring)
        check.begin(captureMode: .eventTap)
        XCTAssertEqual(check.result, .listening)
        XCTAssertTrue(check.intercept())
        XCTAssertEqual(check.result, .heard)
        XCTAssertFalse(check.intercept())
    }

    func testTheCheckedHoldNeverStartsATalkTurnAndTheNextOneDoes() {
        var starts = 0, ends = 0, cancels = 0
        var intercepts = 1
        let monitor = ModifierHoldMonitor(
            commitDelay: 0,
            talkHold: { [.control, .option] },
            onHoldStart: { starts += 1 },
            onHoldCommit: {},
            onHoldEnd: { ends += 1 },
            onHoldCancel: { cancels += 1 },
            onHoldTap: {},
            onComposer: {}
        )
        monitor.interceptHold = {
            defer { intercepts -= 1 }
            return intercepts > 0
        }
        monitor.handle(timestamp: 1.0, modifiers: [.control, .option], isFlagsChanged: true, tapDisabled: false)
        monitor.handleKeyDown()
        monitor.handle(timestamp: 1.6, modifiers: [], isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual([starts, ends, cancels], [0, 0, 0])
        monitor.handle(timestamp: 2.0, modifiers: [.control, .option], isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 2.6, modifiers: [], isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual([starts, ends, cancels], [1, 1, 0])
    }

    func testRenderCheckStates() async throws {
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/shortcut-check-evidence")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let setups: [(String, (ShortcutCheck) -> Void)] = [
            ("idle", { _ in }),
            ("listening", { $0.begin(captureMode: .eventTap) }),
            ("heard", { $0.begin(captureMode: .eventTap); _ = $0.intercept() }),
            ("needs-input-monitoring", { $0.begin(captureMode: .fallbackMonitors) }),
        ]
        for (name, setup) in setups {
            let check = ShortcutCheck()
            setup(check)
            let frame = NSRect(x: 0, y: 0, width: 520, height: 90)
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: Form { ShortcutCheckRow(check: check, gesture: .defaultTalk, start: {}) }.formStyle(.grouped))
            window.contentView = host
            host.frame = frame
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(name + ".png"))
            window.close()
        }
    }
}
