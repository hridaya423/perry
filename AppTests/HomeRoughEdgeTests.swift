import AppKit
import SwiftUI
import XCTest
import PerryBrain
@testable import Perry

@MainActor
final class HomeRoughEdgeTests: XCTestCase {
    func testStorageErrorShowsOnAThreadPage() async throws {
        let thread = PerryThread(title: "Rename the report")
        let model = HomeModel()
        model.threads = [thread]
        model.sidebarSelection = .thread(thread.id)
        let clean = try await render(NotchWorkspaceView(model: model), name: "storage-error-thread-clean")
        model.storageError = "Couldn’t save your draft. Keep Perry open and try again."
        let failing = try await render(NotchWorkspaceView(model: model), name: "storage-error-thread-failing")
        var differing = 0
        for y in 0..<48 {
            for x in stride(from: 200, to: clean.pixelsWide, by: 2) where clean.colorAt(x: x, y: y) != failing.colorAt(x: x, y: y) {
                differing += 1
            }
        }
        XCTAssertGreaterThan(differing, 50, "The thread page drew no storage error strip")
    }

    func testRefusedDoStartKeepsTheDraftAndMode() throws {
        let session = SessionController()
        let controller = AppController.testing(directory: try directory(), session: session)
        try session.wake()
        try session.startAsk(AskSessionState(id: UUID(), startedAt: Date(), question: "What is on screen?"))
        let model = controller.subsystems.homeController.homeModel
        model.composerMode = .task
        model.updateNewDraft("tidy my desktop")
        model.onStartConversation?("tidy my desktop")
        XCTAssertEqual(model.composerMode, .task)
        XCTAssertEqual(model.newConversationDraft, "tidy my desktop")
        XCTAssertNotNil(model.composerNotice)
        XCTAssertTrue(model.pendingQuestions.isEmpty)
        model.updateNewDraft("tidy my desktop now")
        XCTAssertNil(model.composerNotice)
    }

    func testRefusedGuideStartKeepsTheDraftAndMode() throws {
        let session = SessionController()
        let controller = AppController.testing(directory: try directory(), session: session)
        try session.wake()
        try session.startAsk(AskSessionState(id: UUID(), startedAt: Date(), question: "What is on screen?"))
        let model = controller.subsystems.homeController.homeModel
        model.composerMode = .guide
        model.updateNewDraft("show me how to export")
        model.onStartConversation?("show me how to export")
        XCTAssertEqual(model.composerMode, .guide)
        XCTAssertEqual(model.newConversationDraft, "show me how to export")
        XCTAssertNotNil(model.composerNotice)
    }

    func testSecondConversationStartsWhileTheFirstAnswerStreams() async throws {
        let home = HomeController()
        home.threadStore = ThreadStore(directory: try directory())
        var started: [String] = []
        var gates: [CheckedContinuation<Void, Never>] = []
        home.answerProvider = { input, _, _ in
            started.append(input.request.text)
            await withCheckedContinuation { gates.append($0) }
            return .completed
        }
        home.homeModel.updateNewDraft("first question")
        home.homeModel.onStartConversation?("first question")
        XCTAssertTrue(home.homeModel.isCreatingConversation)
        let released = await pollUntil { !home.homeModel.isCreatingConversation }
        XCTAssertTrue(released)
        home.homeModel.updateNewDraft("second question")
        home.homeModel.onStartConversation?("second question")
        let both = await pollUntil { started.count == 2 }
        XCTAssertTrue(both, "Second conversation never started: \(started)")
        gates.forEach { $0.resume() }
        await home.joinAll()
    }

    func testDialogReturnConfirmsOnlyWhenTheDialogOptsIn() {
        let confirm = NotchDialogView(
            title: "Do this as a task?", message: nil, cancelTitle: "Keep asking",
            actions: [NotchDialog.Action("Start task") {}], onCancel: {}, confirmsOnReturn: true)
        XCTAssertEqual(confirm.defaultAction?.title, "Start task")
        let undo = NotchDialogView(
            title: "Undo my changes?", message: nil, cancelTitle: "Cancel",
            actions: [NotchDialog.Action("Undo 2 changes") {}], onCancel: {})
        XCTAssertNil(undo.defaultAction)
        let destructive = NotchDialogView(
            title: "Erase?", message: nil, cancelTitle: "Cancel",
            actions: [NotchDialog.Action("Erase", role: .destructive) {}], onCancel: {})
        XCTAssertNil(destructive.defaultAction)
        let acknowledgement = NotchDialogView(
            title: "Saved", message: nil, cancelTitle: "OK", actions: [], onCancel: {})
        XCTAssertNil(acknowledgement.defaultAction)
    }

    func testToggleOffKeepsHoverAndClickZones() {
        let previous = PerryPreferences.notchStatusEnabled
        PerryPreferences.notchStatusEnabled = false
        defer { PerryPreferences.notchStatusEnabled = previous }
        let presence = NotchPresence(home: HomeController())
        XCTAssertNotNil(presence.currentZones())
        presence.suspend()
        XCTAssertNil(presence.currentZones())
    }

    private func render<Content: View>(_ content: Content, name: String) async throws -> NSBitmapImageRep {
        let size = NSSize(width: 592, height: 492)
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/notch-rebuild-evidence")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let frame = NSRect(origin: .zero, size: size)
        let window = PerryPanel(frame: frame, canBecomeKey: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: content.environment(\.colorScheme, .dark))
        host.sizingOptions = []
        window.contentView = host
        host.frame = frame
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .seconds(0.4))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(name + ".png"))
        return bitmap
    }
}
