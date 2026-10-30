import AppKit
import PerryCore
import PerryOverlay
import SwiftUI
import XCTest
@testable import Perry

@MainActor
final class IconRenderTests: XCTestCase {
    func testLeadMarksKeepTheirTintUnderTheNotchMask() async throws {
        let size = CGSize(width: 480, height: 120)
        let view = HStack(spacing: 14) {
            LeadDisc(systemImage: "exclamationmark", tint: PerryTheme.Colors.caution)
            LeadDisc(systemImage: "checkmark", tint: PerryTheme.Colors.success)
            LeadDisc(systemImage: "arrow.right", tint: PerryTheme.Colors.accent)
            LeadDisc(systemImage: "xmark", tint: PerryTheme.Colors.danger)
            StatusMark(.ok)
            StatusMark(.attention)
            StatusMark(.failed)
            RadioMark(selected: true)
        }
        .frame(width: size.width, height: size.height)
        .mask(alignment: .top) { NotchShape.open.frame(width: size.width, height: size.height) }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        let bitmap = try await render(view, name: "lead-tint", size: size)
        var white = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.97, color.greenComponent > 0.97, color.blueComponent > 0.97 { white += 1 }
            }
        }
        XCTAssertEqual(white, 0)
    }

    func testRenderTaskAndHistoryLeads() async throws {
        let now = Date()
        func entry(_ outcome: TranscriptEntry.Outcome, app: String?) -> TranscriptEntry {
            TranscriptEntry(request: "Rename the files in Downloads", appBundleID: app, summary: "Renamed 14 files.", outcome: outcome,
                            startedAt: now, finishedAt: now, steps: [], verified: outcome == .completed ? true : nil, providerRoute: nil)
        }
        let view = VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                LeadDisc(systemImage: "clock", tint: PerryTheme.Colors.icon)
                LeadSpinner()
                LeadDisc(systemImage: "pause", tint: PerryTheme.Colors.caution)
                LeadDisc(systemImage: "checkmark", tint: PerryTheme.Colors.success)
                LeadDisc(systemImage: "hand.raised", tint: PerryTheme.Colors.caution)
                LeadDisc(systemImage: "xmark", tint: PerryTheme.Colors.danger)
                LeadDisc(systemImage: "lightbulb", tint: PerryTheme.Colors.icon)
                LeadDisc(systemImage: "arrow.right", tint: PerryTheme.Colors.accent)
            }
            HStack(spacing: 14) {
                ForEach(["notion", "slack", "linear", "github", "google-drive", "google-calendar", "google-gmail", "microsoft", "apple-calendar"], id: \.self) {
                    BrandMark(id: $0, name: $0)
                }
            }
            HStack(spacing: 18) {
                StatusLabel("Connected", .ok)
                StatusLabel("Needs attention", .attention)
                StatusLabel("Failed", .failed)
            }
            .font(PerryTheme.Scale.body)
            VStack(spacing: 0) {
                HistoryRow(entry: entry(.completed, app: "com.apple.finder"), undoable: true, emphasized: false)
                HistoryRow(entry: entry(.stopped, app: "com.example.missing"), undoable: false, emphasized: false)
                HistoryRow(entry: entry(.failed, app: nil), undoable: false, emphasized: false)
            }
        }
        .padding(20)
        .frame(width: 520, height: 520, alignment: .topLeading)
        .background(PerryTheme.Colors.canvas)
        .environment(\.colorScheme, .dark)
        try await render(view, name: "leads-gallery", size: CGSize(width: 520, height: 520))
    }

    @discardableResult
    private func render<Content: View>(_ content: Content, name: String, size: CGSize) async throws -> NSBitmapImageRep {
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/icon-evidence")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let frame = NSRect(origin: .zero, size: size)
        let window = PerryPanel(frame: frame, canBecomeKey: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        window.contentView = host
        host.frame = frame
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(name + ".png"))
        return bitmap
    }
}
