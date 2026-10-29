import AppKit
import PerryBrain
import PerryCapture
import SwiftUI
import XCTest
@testable import Perry

@MainActor
final class PaperOnboardingTests: XCTestCase {
    func testRenderSuggestionsWithoutAccessingConnectedApps() throws {
        let model = HomeModel()
        model.sidebarSelection = .suggestions
        model.suggestions = [
            SuggestionCard(title: "Prepare for the project review", body: "Gather the decisions from yesterday’s discussion into a short agenda for the next review.", score: 0.8),
            SuggestionCard(title: "Follow up on the draft", body: "Prepare a follow-up that includes the revised outline and the two questions still awaiting an answer.", score: 0.7)
        ]
        try render(AnyView(NotchWorkspaceView(model: model)), name: "suggestions")
        try render(AnyView(NotchWorkspaceView(model: model)), name: "suggestions-minimum",
                   size: NSSize(width: 600, height: 460))
        try render(AnyView(NotchWorkspaceView(model: model).environment(\.dynamicTypeSize, .accessibility3)),
                   name: "suggestions-large-text")
    }

    func testRenderSuggestionEditor() throws {
        let model = HomeModel()
        let card = SuggestionCard(title: "Prepare for the project review", body: "Gather yesterday’s decisions into a short agenda.", score: 0.8)
        model.suggestions = [card]
        try render(AnyView(SuggestionsView(model: model, editing: card)), name: "suggestion-editor",
                   size: NSSize(width: 560, height: 420))
    }

    func testPrefilledConversationShowsDraftWithoutSubmitting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = AppController(debugStorageDirectory: directory)
        let model = controller.homeController.homeModel
        var submissions = 0
        model.onStartConversation = { _ in submissions += 1 }
        defer { controller.collapseNotch(); controller.notchPresence.stop() }
        controller.presentPrompt(prefill: "Help me revise this request before running it.")
        let frame = NSRect(x: 0, y: 0, width: 480, height: 380)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close(); controller.talkSession.cancelClick() }
        let host = NSHostingView(rootView: CompactConversationView(controller: controller)
            .transaction { $0.disablesAnimations = true })
        window.contentView = host
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.newConversationDraft, "Help me revise this request before running it.")
        XCTAssertEqual(model.composerMode, .ask)
        XCTAssertEqual(controller.talkSession.clickState, .idle)
        XCTAssertEqual(submissions, 0)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/paper-onboarding-evidence")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: destination.appendingPathComponent("prefilled-conversation.png"))
        for prompt in ["Review the first task draft", "Review the revised task draft"] {
            controller.presentPrompt(prefill: prompt, mode: .task)
            XCTAssertEqual(model.newConversationDraft, prompt)
            XCTAssertEqual(model.composerMode, .task)
            XCTAssertEqual(controller.talkSession.clickState, .idle)
            XCTAssertEqual(submissions, 0)
        }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let taskBitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: taskBitmap)
        try XCTUnwrap(taskBitmap.representation(using: .png, properties: [:]))
            .write(to: destination.appendingPathComponent("prefilled-task.png"))
    }

    func testRenderNotchOnboarding() async throws {
        let director = OnboardingDirector()
        let model = HomeModel()
        director.start(resume: false)
        for beat in OnboardingDirector.Beat.allCases {
            let content = AnyView(OnboardingNotchView(director: director, model: model))
            let size = NSSize(width: PerryTheme.Sizing.onboardingContentWidth, height: 520)
            try render(content, name: beat.rawValue, size: size)
            director.skip()
        }
        director.stop()

        let permissions = OnboardingDirector(effects: .init(permissionProbe: {
            PerryPermissionSnapshot(accessibility: true, screenRecording: .denied, microphone: .denied)
        }))
        permissions.start(resume: false)
        while permissions.beat != .access { permissions.skip() }
        await permissions.refreshPermissions()
        XCTAssertEqual(permissions.beat, .access)
        XCTAssertEqual(permissions.permissions?.accessibility, true)
        try render(AnyView(OnboardingNotchView(director: permissions, model: model)), name: "access-half",
                   size: NSSize(width: PerryTheme.Sizing.onboardingContentWidth, height: 520))
        permissions.stop()
    }

    private func render(_ content: AnyView, name: String,
                        size requestedSize: NSSize? = nil) throws {
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/paper-onboarding-evidence")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let size = requestedSize ?? NSSize(width: 900, height: 640)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
            .background(PerryTheme.Colors.canvas))
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: destination.appendingPathComponent(name + ".png"))
    }
}
