import AppKit
import SwiftUI
import XCTest
@testable import Perry

@MainActor
final class PermissionHelperRenderTests: XCTestCase {
    func testRenderHelperPhases() async throws {
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/permission-helper-evidence")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let cases: [(String, PrivacyPane, PermissionHelperView.Phase)] = [
            ("accessibility-instruction", .accessibility, .instruction),
            ("screen-recording-instruction", .screenRecording, .instruction),
            ("screen-recording-restart", .screenRecording, .restart),
            ("accessibility-granted", .accessibility, .granted),
        ]
        for (name, pane, phase) in cases {
            let backdrop = NSRect(x: 0, y: 0, width: 440, height: 256)
            let window = NSWindow(contentRect: backdrop, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            let host = NSHostingView(rootView: ZStack {
                Color(white: 0.93)
                PermissionHelperView(pane: pane, appURL: Bundle.main.bundleURL, phase: phase)
            })
            host.sizingOptions = []
            window.contentView = host
            host.frame = backdrop
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(name + ".png"))
            window.close()
        }
    }
}
