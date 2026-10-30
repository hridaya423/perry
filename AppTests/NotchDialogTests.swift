import AppKit
import SwiftUI
import XCTest
@testable import Perry

@MainActor
final class NotchDialogTests: XCTestCase {
    func testActionRunsOnceAndClearsSource() {
        let presentation = NotchPresentation()
        var runs = 0
        var clears = 0
        let dialog = NotchDialog(
            title: "Delete this task and its workspace?",
            actions: [NotchDialog.Action("Delete task and workspace", role: .destructive) { runs += 1 }],
            presentation: presentation,
            onClearSource: { clears += 1 })
        dialog.present()
        XCTAssertEqual(presentation.current?.id, dialog.id)
        dialog.select(0)
        dialog.select(0)
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(clears, 1)
        XCTAssertFalse(presentation.contains(dialog.id))
    }

    func testCancelRunsNoAction() {
        let presentation = NotchPresentation()
        var runs = 0
        var clears = 0
        let dialog = NotchDialog(
            title: "Discard this saved request?",
            actions: [NotchDialog.Action("Discard request", role: .destructive) { runs += 1 }],
            presentation: presentation,
            onClearSource: { clears += 1 })
        dialog.present()
        dialog.cancel()
        dialog.select(0)
        XCTAssertEqual(runs, 0)
        XCTAssertEqual(clears, 1)
        XCTAssertNil(presentation.current)
    }

    func testNavigationDismissalCancelsWithoutAction() {
        let presentation = NotchPresentation()
        var runs = 0
        var clears = 0
        let dialog = NotchDialog(
            title: "Disconnect?",
            actions: [NotchDialog.Action("Disconnect", role: .destructive) { runs += 1 }],
            presentation: presentation,
            onClearSource: { clears += 1 })
        dialog.present()
        presentation.dismissCurrent()
        XCTAssertEqual(runs, 0)
        XCTAssertEqual(clears, 1)
        XCTAssertFalse(presentation.contains(dialog.id))
    }

    func testOKOnlyDialogResolvesThroughCancel() {
        let presentation = NotchPresentation()
        var clears = 0
        let dialog = NotchDialog(
            title: "Perry could not save that setting",
            message: "disk full",
            cancelTitle: "OK",
            actions: [],
            presentation: presentation,
            onClearSource: { clears += 1 })
        dialog.present()
        XCTAssertEqual(presentation.current?.id, dialog.id)
        dialog.cancel()
        XCTAssertEqual(clears, 1)
        XCTAssertNil(presentation.current)
    }

    func testSourceStateSurvivesDialogAndPresentsLaterFailure() async throws {
        let presentation = NotchPresentation()
        let probe = DialogSourceProbe()
        let host = NSHostingView(rootView: NotchInteractionHost(
            presentation: presentation) {
                DialogSourceFixture(presentation: presentation, probe: probe)
            })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 592, height: 320),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            presentation.dismissCurrent()
            window.close()
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(probe.appearances, 1)
        probe.open?()
        try await Task.sleep(for: .milliseconds(100))
        let confirmation = try XCTUnwrap(presentation.current?.id)
        XCTAssertTrue(presentation.current?.preservesWorkspace == true)
        presentation.dismissCurrent()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(presentation.current)
        probe.fail?()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(presentation.current)
        XCTAssertNotEqual(presentation.current?.id, confirmation)
        XCTAssertEqual(probe.appearances, 1)
    }

    func testRenderDialogLayouts() async throws {
        try await render(NotchDialogView(
            title: "Delete this task and its workspace?",
            message: "This removes the saved task and every file in its private Perry workspace.",
            cancelTitle: "Cancel",
            actions: [NotchDialog.Action("Delete task and workspace", role: .destructive) {}],
            onCancel: {}), name: "dialog-inline", size: NSSize(width: 512, height: 232))
        try await render(NotchDialogView(
            title: "Report a problem",
            message: "Perry never uploads anything automatically. Export the redacted diagnostics file, then attach it to a new issue in Perry’s GitHub repository.",
            cancelTitle: "Cancel",
            actions: [
                NotchDialog.Action("Export diagnostics first") {},
                NotchDialog.Action("Open GitHub issues") {},
            ],
            onCancel: {}), name: "dialog-stacked", size: NSSize(width: 512, height: 292))
        try await render(NotchDialogView(
            title: "Perry could not save that setting",
            message: "The settings file could not be written.",
            cancelTitle: "OK",
            actions: [],
            onCancel: {}), name: "dialog-ok-only", size: NSSize(width: 512, height: 212))
    }

    private func render<Content: View>(_ content: Content, name: String, size: NSSize) async throws {
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/notch-rebuild-evidence")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let frame = NSRect(origin: .zero, size: size)
        let window = PerryPanel(frame: frame, canBecomeKey: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let panel = NotchLayout.size(.focused(content: size.height - 28 - NotchLayout.bottomInset), cameraInset: 24, screen: CGSize(width: 1728, height: 1117))
        let host = NSHostingView(rootView: content
            .padding(.horizontal, NotchLayout.contentInset)
            .padding(.top, NotchLayout.topInset)
            .frame(width: panel.width - NotchShape.open.topRadius * 2, height: panel.height - 24 - NotchLayout.bottomInset, alignment: .topLeading)
            .padding(.top, 24)
            .padding(.horizontal, NotchShape.open.topRadius)
            .frame(width: panel.width, height: panel.height, alignment: .top)
            .background(alignment: .top) { NotchShape.open.surface(crown: 32, lifted: false).frame(width: panel.width, height: panel.height) }
            .frame(width: size.width, height: size.height, alignment: .top)
            .environment(\.colorScheme, .dark))
        host.sizingOptions = []
        window.contentView = host
        host.frame = frame
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .seconds(0.2))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(name + ".png"))
    }
}

@MainActor
private final class DialogSourceProbe {
    var appearances = 0
    var open: (() -> Void)?
    var fail: (() -> Void)?
}

private struct DialogSourceFixture: View {
    let presentation: NotchPresentation
    let probe: DialogSourceProbe
    @State private var confirming = false
    @State private var error: String?

    var body: some View {
        Text("Settings source")
            .onAppear {
                probe.appearances += 1
                probe.open = { confirming = true }
                probe.fail = { error = "The operation failed" }
            }
            .notchDialog("Confirm", isPresented: $confirming, presentation: presentation) { [] }
            .notchDialog("Could not save", item: $error, cancelTitle: "OK", presentation: presentation) { _ in [] }
    }
}
