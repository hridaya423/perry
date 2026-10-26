import AppKit
import PerryGuide
import SwiftUI
import XCTest
@testable import Perry

@MainActor
final class RealtimeVoiceSectionRenderTests: XCTestCase {
    func testRenderProviderStates() async throws {
        let keys = [
            PerryPreferences.$realtimeVoiceProvider.key,
            PerryPreferences.$realtimeVoiceEndpoint.key,
            PerryPreferences.$realtimeVoiceVoice.key,
            PerryPreferences.$realtimeVoiceModel.key,
        ]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        let keychain = KeychainStore(service: "dev.perry.keys.tests.\(UUID().uuidString)")
        defer {
            for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
            for id in RealtimeProviderID.allCases { try? keychain.deleteChecked(account: RealtimeProvider(id).keychainAccount) }
        }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        try keychain.save("xai-fixture", account: RealtimeProvider(.grok).keychainAccount)
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/realtime-settings-evidence")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        for (name, provider) in [("off", RealtimeVoiceSection.off), ("openai", "openAI"), ("grok-key-saved", "grok"), ("custom", "custom")] {
            PerryPreferences.realtimeVoiceProvider = provider
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let frame = NSRect(x: 0, y: 0, width: 560, height: 360)
                let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                let host = NSHostingView(rootView: Form { RealtimeVoiceSection(keychain: keychain, onError: { _ in }) }.formStyle(.grouped))
                window.contentView = host
                host.frame = frame
                window.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(300))
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let suffix = appearance == .aqua ? "light" : "dark"
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: destination.appendingPathComponent("\(name)-\(suffix).png"))
                window.close()
            }
        }
        XCTAssertEqual(RealtimeProvider.current?.id, .custom)
        PerryPreferences.realtimeVoiceProvider = RealtimeVoiceSection.off
        XCTAssertNil(RealtimeProvider.current)
    }
}
