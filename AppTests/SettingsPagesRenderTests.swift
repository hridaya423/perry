import AppKit
import SwiftUI
import XCTest
@testable import Perry

@MainActor
final class SettingsPagesRenderTests: XCTestCase {
    func testRenderEveryPageAtFullHeight() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = AppController(debugStorageDirectory: directory)
        defer { controller.notchPresence.stop() }
        let previous = PerryPreferences.settingsTab
        defer { PerryPreferences.settingsTab = previous }
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/settings-pages")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for page in SettingsPage.allCases {
            PerryPreferences.settingsTab = page.rawValue
            let frame = NSRect(x: 0, y: 0, width: 600, height: 1500)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: SettingsView(controller: controller).frame(width: frame.width, height: frame.height))
            window.contentView = host
            host.frame = frame
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(500))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: destination.appendingPathComponent("\(page.rawValue).png"))
            window.close()
        }
    }
}
