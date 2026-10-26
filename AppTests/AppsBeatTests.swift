import AppKit
import SwiftUI
import XCTest
@testable import Perry

@MainActor
final class AppsBeatTests: XCTestCase {
    func testTilesComeFromTheAppsNamedInTheInterview() {
        let tiles = AppsBeatPlan.tiles(apps: "Notion, Figma, Slack", mentions: "", available: { _ in true })
        XCTAssertEqual(tiles.map(\.id), ["notion", "slack"])
        XCTAssertEqual(tiles.map(\.action), [.connect, .later], "at most one connect is suggested")
    }

    func testGmailNeverShowsConnect() {
        let tiles = AppsBeatPlan.tiles(apps: "Gmail and Linear", mentions: "", available: { _ in true })
        XCTAssertEqual(tiles.first { $0.id == "google-gmail" }?.action, .useOwnApp)
        XCTAssertEqual(tiles.first { $0.id == "linear" }?.action, .connect)
    }

    func testMeetingsBringInTheCalendar() {
        XCTAssertEqual(AppsBeatPlan.tiles(apps: "", mentions: "I run meetings all day", available: { _ in true }).map(\.id), ["apple-calendar"])
        XCTAssertEqual(AppsBeatPlan.tiles(apps: "Google Calendar", mentions: "", available: { _ in true }).map(\.id), ["google-calendar"])
    }

    func testAppsWithoutPerrysSignInSayComingSoon() {
        let tiles = AppsBeatPlan.tiles(apps: "Slack, Notion", mentions: "calendar", available: { $0 == "apple-calendar" })
        XCTAssertEqual(tiles.map(\.action), [.comingSoon, .comingSoon, .connect])
    }

    func testNothingNamedMeansNoTiles() {
        XCTAssertTrue(AppsBeatPlan.tiles(apps: "Figma, Xcode", mentions: "Spanish", available: { _ in true }).isEmpty)
    }

    func testRenderTheAppsBeat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = AppController(debugStorageDirectory: directory)
        defer { controller.notchPresence.stop() }
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/onboarding-evidence")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let director = OnboardingDirector()
        director.start(resume: false)
        while director.beat != .apps { director.skip() }
        defer { director.stop() }
        let tiles = AppsBeatPlan.tiles(apps: "Notion, Slack, Gmail", mentions: "weekly meetings", available: { $0 != "slack" })
        let frame = NSRect(x: 0, y: 0, width: PerryTheme.Sizing.onboardingContentWidth, height: 380)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }
        let host = NSHostingView(rootView: AppsBeat(director: director, controller: controller, tiles: tiles)
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            .frame(width: frame.width, height: frame.height)
            .background(PerryTheme.Colors.canvas)
            .foregroundStyle(PerryTheme.Colors.text)
            .environment(\.colorScheme, .dark))
        window.contentView = host
        host.frame = frame
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: destination.appendingPathComponent("apps-tiles.png"))
    }
}
