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
            ("accessibility-retry", .accessibility, .retry),
            ("accessibility-settings-closed", .accessibility, .settingsClosed),
            ("wrong-location", .accessibility, .wrongLocation),
        ]
        for (name, pane, phase) in cases {
            let backdrop = NSRect(x: 0, y: 0, width: 800, height: 500)
            let window = NSWindow(contentRect: backdrop, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            let card = SettingsWindowTracker.dockFrame(settings: backdrop, visible: backdrop, cardHeight: PermissionHelperPanel.cardSize.height)
            let host = NSHostingView(rootView: ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    Color(white: 0.17).frame(width: card.minX - 16)
                    VStack(spacing: 0) {
                        ForEach(0..<9) { _ in
                            HStack {
                                RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.35)).frame(width: 22, height: 22)
                                RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.3)).frame(width: 120, height: 8)
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .frame(height: 44)
                        }
                        Spacer()
                    }
                    .background(Color(white: 0.12))
                }
                PermissionHelperView(pane: pane, appURL: Bundle.main.bundleURL, phase: phase)
                    .frame(width: card.width, height: card.height)
                    .offset(x: card.minX, y: backdrop.height - card.maxY)
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
