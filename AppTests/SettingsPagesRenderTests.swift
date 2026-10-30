import AppKit
import PerryCore
import SwiftUI
import XCTest
@testable import Perry

@MainActor
final class SettingsPagesRenderTests: XCTestCase {
    func testRenderEveryPageAtFullHeight() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = AppController.testing(directory: directory)
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

    func testRenderAppRowsWithAndWithoutPerrysSignIn() async throws {
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/settings-pages")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let suite = "dev.perry.tests.render-apps.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let permissions = RemoteIntegrationPermissionStore(suiteName: suite)
        let client = RemoteIntegrationClient(
            keychain: KeychainStore(service: "dev.perry.tests.render-apps.\(UUID().uuidString)"),
            permissionStore: permissions
        )
        let oauth = OAuthCoordinator(credentialStore: OAuthCredentialStore(keychain: KeychainStore(service: "dev.perry.tests.render-apps.\(UUID().uuidString)")))
        let withPerry = IntegrationConnections(
            oauth: oauth, client: client, permissions: permissions,
            bundled: BundledOAuthClients(infoDictionary: ["PerryOAuthLinearClientID": "id", "PerryOAuthGitHubClientID": "id"])
        )
        let withoutPerry = IntegrationConnections(
            oauth: oauth, client: client, permissions: permissions,
            bundled: BundledOAuthClients(infoDictionary: nil)
        )
        let catalog = RemoteIntegrationDefinition.catalog
        let views: [(String, AnyView)] = [
            ("apps-with-perry-sign-in", AnyView(SettingsScroll {
                SettingsCard(title: "Connected apps") {
                    ForEach(catalog) { definition in
                        IntegrationRow(definition: definition, connections: withPerry).settingsRowPadding()
                    }
                }
            })),
            ("apps-bring-your-own", AnyView(SettingsScroll {
                SettingsCard(title: "Connected apps") {
                    ForEach(catalog) { definition in
                        IntegrationRow(definition: definition, connections: withoutPerry).settingsRowPadding()
                    }
                }
            })),
        ]
        for (name, view) in views {
            let frame = NSRect(x: 0, y: 0, width: 600, height: 520)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: view.frame(width: frame.width, height: frame.height))
            window.contentView = host
            host.frame = frame
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(500))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: destination.appendingPathComponent("\(name).png"))
            window.close()
        }
    }

    func testRenderShortcutsAtNotchContentWidth() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = AppController.testing(directory: directory)
        defer { controller.notchPresence.stop() }
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/settings-pages")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var conflict = ShortcutRole.dictate.capture(gestures: ShortcutRole.current, hotkeys: [])
        conflict.choose(.doubleTap([.control]))
        let views: [(String, AnyView)] = [
            ("shortcuts-narrow", AnyView(ShortcutsSettingsPage(controller: controller))),
            ("shortcuts-conflict-narrow", AnyView(SettingsScroll {
                SettingsCard {
                    ShortcutRecorder(
                        title: "Dictate",
                        capture: .constant(conflict),
                        presets: ShortcutRole.dictate.presets,
                        presetLabel: ShortcutRole.dictate.label(for:)
                    )
                    .settingsRowPadding()
                }
            })),
        ]
        for (name, view) in views {
            let frame = NSRect(x: 0, y: 0, width: 380, height: name == "shortcuts-narrow" ? 760 : 200)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: view.frame(width: frame.width, height: frame.height))
            window.contentView = host
            host.frame = frame
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(500))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: destination.appendingPathComponent("\(name).png"))
            window.close()
        }
    }

    func testRenderTheLocalBrainOnSmallAndLargeMacs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = AppController.testing(directory: directory)
        defer { controller.notchPresence.stop() }
        let local = LocalBrain(engine: nil, modelsDirectory: directory, benchURL: directory.appendingPathComponent("bench.json"))
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/settings-pages")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for (name, profile) in [("local-8gb", BrainChoiceTests.profile(gb: 8, chip: "Apple M2", appleIntelligence: false)), ("local-48gb", BrainChoiceTests.profile(gb: 48, chip: "Apple M4 Pro"))] {
            let view = SettingsScroll { LocalBrainView(brain: controller.brain, local: local, profile: profile) }
                .background(PerryTheme.Colors.canvas)
                .toggleStyle(InkSwitchStyle())
                .buttonStyle(InkButtonStyle(.secondary))
                .controlSize(.small)
                .font(PerryTheme.Scale.body)
                .foregroundStyle(PerryTheme.Colors.text)
            let frame = NSRect(x: 0, y: 0, width: 600, height: 1100)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: view.frame(width: frame.width, height: frame.height))
            window.contentView = host
            host.frame = frame
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(500))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: destination.appendingPathComponent("\(name).png"))
            window.close()
        }
    }
}
