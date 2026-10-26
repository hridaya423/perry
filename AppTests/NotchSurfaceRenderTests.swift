import AppKit
import SwiftUI
import XCTest
import PerryGuide
import PerryBrain
import PerryCapture
import PerryOverlay
@testable import Perry

@MainActor
final class NotchSurfaceRenderTests: XCTestCase {
    func testRenderTaskQuestionChoices() async throws {
        try await render(TaskQuestionView(prompt: "Which version should I use?", choices: ["Latest draft", "Shared version"], onChoose: { _ in }, onCancel: {}), name: "task-question", size: NSSize(width: 512, height: 240))
        try await render(TaskQuestionView(prompt: "Which version of the project report should I use for the summary?", choices: ["The latest draft with the updated research notes", "The version shared with the team yesterday", "The original report before revisions"], onChoose: { _ in }, onCancel: {}), name: "task-question-long", size: NSSize(width: 512, height: 360))
    }

    func testTaskQuestionInsideNotch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = AppController(debugStorageDirectory: directory)
        let presentation = NotchPresentation.shared
        let previousOnPresent = presentation.onPresent
        presentation.onPresent = nil
        let presenter = TaskQuestionPresenter(prompt: "Which version should I use?", choices: ["The latest draft with updated research notes", "The version shared with the team yesterday"])
        let asking = Task { try await presenter.ask() }
        defer {
            presenter.cancel()
            presentation.onPresent = previousOnPresent
            controller.notchPresence.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        for _ in 0..<100 where !presentation.contains(presenter.requestID) { await Task.yield() }
        XCTAssertEqual(presentation.current?.id, presenter.requestID)
        try await render(openNotch(controller), name: "task-question-notch", size: NSSize(width: 592, height: 400))
        presenter.cancel()
        do {
            try await asking.value
            XCTFail("Cancelling a question must cancel the pending task")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(presentation.contains(presenter.requestID))
    }

    func testRenderActiveInteractionSurfaces() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = AppController(debugStorageDirectory: directory)
        let presentation = NotchPresentation.shared
        for entry in presentation.entries { presentation.remove(entry.id) }
        let id = UUID()
        defer {
            presentation.remove(id)
            controller.notchPresence.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        let guide = GuideControlsState()
        guide.stepPosition = 2
        guide.targetLabel = "Choose the project folder in the sidebar."
        let guideView = GuideControlsView(state: guide, onDone: {}, onBack: {}, onSkip: {}, onRepoint: {}, onSelectMarker: { _ in }, onChooseInput: { _ in }, onTakeOver: {}, onStop: {})
        presentation.present(id: id, priority: .guide, content: guideView, reveal: false)
        presentation.showsInteraction = true
        try await render(openNotch(controller), name: "guide-step", size: NSSize(width: 592, height: 420), wait: 0.8)
        guide.pendingPrompt = "Which version should I use?"
        guide.pendingChoices = ["The latest draft", "The version shared yesterday"]
        try await render(openNotch(controller), name: "guide-question", size: NSSize(width: 592, height: 420), wait: 0.8)
        guide.pendingPrompt = "Which of these folders holds the launch notes you mentioned earlier?"
        guide.pendingChoices = ["The Launch folder on the desktop, which was shared with the whole team last week", "The Archive folder inside Documents", "Neither of them"]
        try await render(openNotch(controller), name: "guide-question-long", size: NSSize(width: 592, height: 420), wait: 0.8)
        guide.pendingPrompt = nil
        guide.pendingChoices = []
        let routine = RoutineReviewState()
        routine.presentReview(steps: [RoutineStep(summary: "Open a new note", action: .click), RoutineStep(summary: "Write the meeting heading", action: .typeText(.parameter(name: "heading", prompt: "Meeting heading")))])
        routine.name = "Prepare meeting notes"
        let routineView = RoutineReviewView(state: routine, onStopRecording: {}, onDiscard: {}, onSave: {}, onSaveAndTry: {}, onRun: {})
        presentation.present(id: id, priority: .routine, content: routineView, reveal: false)
        try await render(openNotch(controller), name: "routine-review", size: NSSize(width: 592, height: 492), wait: 0.8)
        let activity = AgentActivityStripState()
        activity.phase = .working
        activity.title = "Preparing meeting notes"
        activity.detail = "Writing the outline"
        activity.progress = 0.5
        activity.isExpanded = true
        let activityView = AgentActivityStripView(state: activity, onPause: {}, onResume: {}, onStop: {}, onRetry: {}, onSteer: { _ in }, onTakeOver: {}, onToggleExpanded: {})
        presentation.present(id: id, priority: .activity, content: activityView, reveal: false)
        try await render(openNotch(controller), name: "task-working", size: NSSize(width: 592, height: 492))
        activity.phase = .failed
        activity.title = "I lost the connection."
        activity.detail = "Your message is saved."
        activity.progress = nil
        activity.canRetry = true
        try await render(openNotch(controller), name: "task-failed", size: NSSize(width: 592, height: 492))
    }

    func testRenderRoutineOfferStates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = AppController(debugStorageDirectory: directory)
        let presentation = NotchPresentation.shared
        for entry in presentation.entries { presentation.remove(entry.id) }
        var id = UUID()
        defer {
            presentation.remove(id)
            controller.notchPresence.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        let size = NSSize(width: 592, height: 420)
        presentation.present(id: id, priority: .routine, content: RoutineOfferView(onShowMe: {}, onNotNow: {}), reveal: false)
        presentation.showsInteraction = true
        try await render(openNotch(controller), name: "offer", size: size, wait: 0.8, folder: "first-impressions-7.11")

        let recording = RoutineReviewState()
        recording.eventCount = 4
        let noop = {}
        presentation.remove(id)
        id = UUID()
        presentation.present(id: id, priority: .routine, content: RoutineReviewView(state: recording, onStopRecording: noop, onDiscard: noop, onSave: noop, onSaveAndTry: noop, onRun: noop), reveal: false)
        try await render(openNotch(controller), name: "recording", size: size, wait: 0.8, folder: "first-impressions-7.11")

        let review = RoutineReviewState()
        review.presentReview(steps: [
            RoutineStep(summary: "Click File", target: RoutineTarget(role: "menuItem", label: "File"), action: .click),
            RoutineStep(summary: "Click Export", target: RoutineTarget(role: "menuItem", label: "Export"), action: .click),
            RoutineStep(summary: "Click something I could not identify", action: .click, requiresHuman: true),
            RoutineStep(summary: "Type \"Weekly report\" into Name", target: RoutineTarget(role: "textField", label: "Name"), action: .typeText(.literal("Weekly report")))
        ])
        review.name = "Export the weekly report"
        presentation.remove(id)
        id = UUID()
        presentation.present(id: id, priority: .routine, content: RoutineReviewView(state: review, onStopRecording: noop, onDiscard: noop, onSave: noop, onSaveAndTry: noop, onRun: noop), reveal: false)
        try await render(openNotch(controller), name: "review", size: NSSize(width: 592, height: 420), wait: 1.6, folder: "first-impressions-7.11")

        let longReview = RoutineReviewState()
        longReview.presentReview(steps: (1...8).map { RoutineStep(summary: "Click Menu item \($0)", target: RoutineTarget(role: "menuItem", label: "Menu item \($0)"), action: .click) } + [RoutineStep(summary: "Click something I could not identify", action: .click, requiresHuman: true)])
        longReview.name = "Export the weekly report"
        presentation.remove(id)
        id = UUID()
        presentation.present(id: id, priority: .routine, content: RoutineReviewView(state: longReview, onStopRecording: noop, onDiscard: noop, onSave: noop, onSaveAndTry: noop, onRun: noop), reveal: false)
        try await render(openNotch(controller), name: "review-long", size: NSSize(width: 592, height: 420), wait: 1.6, folder: "first-impressions-7.11")

        let routine = try LearnedRoutine(name: "Export the weekly report", appBundleIDs: ["com.example.app"], steps: [
            RoutineStep(summary: "Click File", target: RoutineTarget(role: "menuItem", label: "File"), action: .click),
            RoutineStep(summary: "Click Edit", target: RoutineTarget(role: "menuItem", label: "Edit"), action: .click),
            RoutineStep(summary: "Click Export", target: RoutineTarget(role: "button", label: "Export"), action: .click)
        ])
        let activity = AgentActivityStripState()
        activity.phase = .reporting
        activity.title = "Done"
        activity.detail = try XCTUnwrap(RoutineRunCopy.success(priorVerifiedRuns: 0))
        let strip = AgentActivityStripView(state: activity, onPause: {}, onResume: {}, onStop: {}, onRetry: {}, onSteer: { _ in }, onTakeOver: {}, onToggleExpanded: {})
        presentation.remove(id)
        id = UUID()
        presentation.present(id: id, priority: .activity, content: strip, reveal: false)
        try await render(openNotch(controller), name: "rehearsal-success", size: size, wait: 0.8, folder: "first-impressions-7.11")
        activity.title = "Stopped"
        activity.detail = RoutineRunCopy.stopped(routine: routine, step: 2, error: .targetNotFound(step: 2), reason: "") + " I finished 2 of 3 steps and checked each one. I didn’t touch the rest."
        try await render(openNotch(controller), name: "rehearsal-failure", size: size, wait: 0.8, folder: "first-impressions-7.11")
    }

    func testRenderNotchWorkspaceDestinations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for entry in NotchPresentation.shared.entries {
            NotchPresentation.shared.remove(entry.id)
        }
        let controller = AppController(debugStorageDirectory: directory)
        let model = controller.homeController.homeModel
        defer { controller.notchPresence.stop() }
        let selections: [(String, HomeModel.Selection?)] = [
            ("workspace", nil), ("settings", .settings), ("routines", .routines),
            ("files", .files), ("tasks", .tasks), ("history", .history),
            ("suggestions", .suggestions), ("whats-new", .whatsNew)
        ]
        for (name, selection) in selections {
            model.sidebarSelection = selection
            try await render(openNotch(controller), name: name, size: NSSize(width: 892, height: 552))
        }
        let previousTab = UserDefaults.standard.object(forKey: PerryPreferences.$settingsTab.key)
        defer {
            if let previousTab { UserDefaults.standard.set(previousTab, forKey: PerryPreferences.$settingsTab.key) }
            else { UserDefaults.standard.removeObject(forKey: PerryPreferences.$settingsTab.key) }
        }
        model.sidebarSelection = .settings
        for page in SettingsPage.allCases {
            UserDefaults.standard.set(page.rawValue, forKey: PerryPreferences.$settingsTab.key)
            try await render(openNotch(controller), name: "settings-\(page.rawValue)", size: NSSize(width: 892, height: 552))
        }
        model.routines = [try LearnedRoutine(name: "Prepare project notes", appBundleIDs: ["com.apple.Notes"], steps: [
            RoutineStep(summary: "Open a new note", action: .click),
            RoutineStep(summary: "Write the meeting heading", action: .typeText(.parameter(name: "heading", prompt: "Meeting heading")))
        ])]
        model.sidebarSelection = .routines
        try await render(openNotch(controller), name: "routines-populated", size: NSSize(width: 892, height: 552))
        let thread = PerryThread(title: "Project notes", turns: [.init(question: "Summarize the meeting", answer: "The team agreed to finish the outline before Friday.\n\n## Next steps\n- Review the outline.\n- Share the open questions.")])
        model.threads = [thread]
        model.sidebarSelection = .thread(thread.id)
        try await render(openNotch(controller), name: "conversation", size: NSSize(width: 892, height: 552))
    }

    func testRenderOnboardingBeats() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for entry in NotchPresentation.shared.entries {
            NotchPresentation.shared.remove(entry.id)
        }
        let controller = AppController(debugStorageDirectory: directory)
        let model = controller.homeController.homeModel
        defer { controller.notchPresence.stop() }
        var snapshot = PerryPermissionSnapshot(accessibility: false, screenRecording: .denied, microphone: .denied)
        var effects = OnboardingDirector.Effects()
        effects.permissionProbe = { snapshot }
        let director = OnboardingDirector(effects: effects)
        model.sidebarSelection = nil
        model.onboarding = director
        director.start(resume: false)
        defer {
            director.stop()
            model.onboarding = nil
        }
        let size = NSSize(width: 592, height: 492)
        func shot(_ name: String, wait: Double = 1.1) async throws {
            try await render(openNotch(controller), name: "onboarding-\(name)", size: size, wait: wait, folder: "onboarding-evidence")
        }
        try await render(openNotch(controller).environment(\._accessibilityReduceMotion, true), name: "onboarding-1-hello-reduced-motion", size: size, wait: 0.3, folder: "onboarding-evidence")
        for (index, beat) in OnboardingDirector.Beat.allCases.enumerated() {
            XCTAssertEqual(director.beat, beat)
            try await shot("\(index + 1)-\(beat.rawValue)", wait: beat == .hello ? HelloInk.peekDelay + 0.8 : 1.1)
            try await render(
                OnboardingNotchView(director: director, model: model)
                    .frame(width: 524, height: 325, alignment: .top)
                    .background(PerryTheme.Colors.canvas)
                    .environment(\.colorScheme, .dark),
                name: "onboarding-small-\(index + 1)-\(beat.rawValue)", size: NSSize(width: 524, height: 325),
                wait: beat == .hello ? HelloInk.peekDelay + 0.8 : 1.1, folder: "onboarding-evidence")
            if beat == .access {
                snapshot = PerryPermissionSnapshot(accessibility: true, screenRecording: .denied, microphone: .denied)
                await director.refreshPermissions()
                try await shot("3b-access-half")
                snapshot = PerryPermissionSnapshot(accessibility: true, screenRecording: .denied, microphone: .granted)
                await director.refreshPermissions()
                try await shot("3c-access-granted")
            }
            director.skip()
        }
    }

    func testApprovalWindowFitsShortContentAndBoundsLongContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = AppController(debugStorageDirectory: directory)
        let presentation = NotchPresentation.shared
        for entry in presentation.entries { presentation.remove(entry.id) }
        let id = UUID()
        defer {
            presentation.remove(id)
            controller.collapseNotch()
            controller.notchPresence.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        var shortHeight: CGFloat = 0
        var windowFrame: NSRect?
        for isLong in [false, true] {
            let detail = isLong ? Array(repeating: "Review this document before saving changes to the selected folder.", count: 45).joined(separator: "\n") : "Both files keep their contents; nothing else changes."
            let card = IntentCard(title: "Move two files into Archive", detail: detail, tier: .orange, targetSummary: "draft-a.txt, draft-b.txt → Archive")
            presentation.present(id: id, priority: .approval, content: IntentCardView(card: card) { _ in })
            controller.showPanel(activate: false)
            try await Task.sleep(for: .milliseconds(500))
            let window = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "perry.session" && $0.isVisible })
            let screen = try XCTUnwrap(window.screen)
            let visible = try XCTUnwrap(controller.sessionPanel.frame)
            XCTAssertEqual(window.frame, windowFrame ?? window.frame, "the window never resizes")
            windowFrame = window.frame
            XCTAssertTrue(window.frame.contains(visible))
            XCTAssertEqual(visible.maxY, screen.frame.maxY, accuracy: 1)
            if isLong {
                XCTAssertGreaterThan(visible.height, shortHeight)
                XCTAssertLessThanOrEqual(visible.height, NotchLayout.cap(screen: screen.frame.size).height)
            } else {
                shortHeight = visible.height
                XCTAssertLessThan(shortHeight, 320)
            }
            let host = try XCTUnwrap(window.contentView)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/notch-rebuild-evidence")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(isLong ? "approval-long.png" : "approval-short.png"))
        }
    }

    func testAnswerFormattingPreservesBlockBoundariesAndInlineContent() {
        let source = "Intro **bold**.\n\n## Next steps\n- Review the outline.\n- Share questions.\n\n```swift\nlet value = 1\n```\n\n[Read more](https://example.com)"
        let answer = ConversationAnswer.format(source)
        let text = String(answer.characters)
        XCTAssertTrue(text.contains("Intro bold.\n\nNext steps\n• Review the outline.\n• Share questions."))
        XCTAssertTrue(text.contains("let value = 1"))
        XCTAssertTrue(answer.runs.contains { $0.link == URL(string: "https://example.com") })
        XCTAssertFalse(text.contains("##"))
        XCTAssertFalse(text.contains("```"))
    }

    func testAnswerSplitsFencedCodeIntoCopyableBlocks() {
        let parts = ConversationAnswer.parts("Run this:\n\n```sh\nfind . -size +100M\n```\n\nThen check.")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[1], .code("find . -size +100M"))
        XCTAssertEqual(ConversationAnswer.parts("Streaming:\n```\nls -la").last, .code("ls -la"))
    }

    func testAnswerLinksOnlyOpenTheWeb() {
        let answer = ConversationAnswer.format("[Invoice](file:///etc/hosts) and [Docs](https://example.com) and [App](x-apple.systempreferences:com.apple.preference)")
        XCTAssertEqual(answer.runs.compactMap(\.link), [URL(string: "https://example.com")!])
        XCTAssertEqual(String(answer.characters), "Invoice and Docs and App")
    }

    func testRenderNarrowWorkspace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = AppController(debugStorageDirectory: directory)
        await controller.homeController.joinAll()
        let model = controller.homeController.homeModel
        defer { controller.notchPresence.stop() }
        let thread = PerryThread(title: "Review the launch plan and summarize the remaining decisions before Friday", turns: [.init(question: "What remains?", answer: "Review the outline and share the open questions.")])
        let store = try XCTUnwrap(controller.homeController.threadStore)
        try await store.upsert(thread)
        model.threads = [thread]
        model.sidebarSelection = .thread(thread.id)
        try await render(openNotch(controller), name: "conversation-narrow", size: NSSize(width: 720, height: 500))
        XCTAssertEqual(model.threads.first?.title, thread.title)
        model.sidebarSelection = .settings
        try await render(openNotch(controller), name: "settings-narrow", size: NSSize(width: 720, height: 500))
    }

    func testRenderGreetingMotionFrames() async throws {
        let fps = 30.0
        for frame in 0...Int((HelloInk.peekDelay + 0.7) * fps) {
            let time = Double(frame) / fps
            let peek = min(max((time - HelloInk.peekDelay) / 0.4, 0), 1)
            let settle = 1 + 0.12 * sin(.pi * min(peek * 1.4, 1)) * (1 - peek)
            try await render(
                VStack(spacing: 0) {
                    NotchPeek(progress: min(peek * settle, 1.08))
                        .frame(height: 36, alignment: .top)
                    HelloScene(time: time).frame(width: 420, height: 210).padding(.top, 16)
                    Spacer()
                }
                .frame(width: 560, height: 300)
                .clipped()
                .background(Color.black),
                name: String(format: "greet-%03d", frame),
                size: NSSize(width: 560, height: 300),
                wait: 0.02,
                folder: "onboarding-evidence/greet-motion"
            )
        }
    }

    func testRenderOnboardingReel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for entry in NotchPresentation.shared.entries {
            NotchPresentation.shared.remove(entry.id)
        }
        let controller = AppController(debugStorageDirectory: directory)
        let model = controller.homeController.homeModel
        defer { controller.notchPresence.stop() }
        var effects = OnboardingDirector.Effects()
        effects.permissionProbe = { PerryPermissionSnapshot(accessibility: false, screenRecording: .denied, microphone: .denied) }
        let director = OnboardingDirector(effects: effects)
        model.sidebarSelection = nil
        model.onboarding = director
        director.start(resume: false)
        defer {
            director.stop()
            model.onboarding = nil
        }
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/onboarding-evidence/reel")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let frame = NSRect(x: 0, y: 0, width: 592, height: 492)
        let window = CompactConversationPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: openNotch(controller))
        host.sizingOptions = []
        window.contentView = host
        host.frame = frame
        window.orderFrontRegardless()
        defer { window.close() }
        var index = 0
        func capture(for seconds: Double) async throws {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: destination.appendingPathComponent(String(format: "frame-%04d.png", index)))
                index += 1
                try await Task.sleep(for: .milliseconds(40))
            }
        }
        try await capture(for: HelloInk.peekDelay + 1.2)
        for _ in 1..<OnboardingDirector.Beat.allCases.count {
            director.skip()
            try await capture(for: 1.4)
        }
        print("onboarding.reel.frames=\(index)")
    }

    func testRenderPerfectPassSurfaces() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let presentation = NotchPresentation.shared
        for entry in presentation.entries { presentation.remove(entry.id) }
        let controller = AppController(debugStorageDirectory: directory)
        let model = controller.homeController.homeModel
        defer {
            controller.clearFailure()
            controller.notchPresence.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        let size = NSSize(width: 892, height: 552)
        model.sidebarSelection = .perryEditor(nil)
        try await render(openNotch(controller), name: "perry-editor-new", size: size)
        let store = try XCTUnwrap(controller.perryStore)
        let perry = try await store.create(job: "Summarize my unread newsletters every morning", schedule: RoutineSchedule(kind: .daily(hour: 8, minute: 30)))
        model.perrys = await store.list()
        model.sidebarSelection = .perryEditor(perry.id)
        try await render(openNotch(controller), name: "perry-editor-existing", size: NSSize(width: 892, height: 720), wait: 0.5)

        model.sidebarSelection = nil
        controller.presentFailure("I can’t see your screen. Until you turn on Screen Recording, I answer from window text.", recovery: .privacy(.screenRecording))
        presentation.showsInteraction = true
        try await render(openNotch(controller), name: "failure-notice", size: NSSize(width: 592, height: 420))
        controller.clearFailure()

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "perry.render.\(UUID().uuidString)"))
        let profileStore = ModelProfileStore(defaults: defaults)
        let profiles = [
            ModelProfile(id: "a", presetID: "anthropic", baseURL: URL(string: "https://api.anthropic.com")!, model: "claude-sonnet-5-5", fastModel: "claude-haiku-5-5"),
            ModelProfile(id: "b", presetID: "ollama", baseURL: URL(string: "http://127.0.0.1:11434")!, model: "qwen3:14b")
        ]
        profileStore.save(profiles)
        profileStore.activeID = "a"
        let brain = BrainController(readCredential: { _ in "key" }, defaults: defaults, discoverLocalModels: { [] }, codexFactory: { nil })
        let settings = Form { Section("Your providers") { ModelProfilesSection(brain: brain) } }
            .formStyle(.grouped)
            .controlSize(.small)
            .preferredColorScheme(.dark)
        try await render(settings, name: "model-profiles", size: NSSize(width: 640, height: 420))
        let agents = Form { Section("Agent") { AcpAgentSection(brain: brain) } }
            .formStyle(.grouped)
            .controlSize(.small)
            .preferredColorScheme(.dark)
        try await render(agents, name: "acp-agent", size: NSSize(width: 640, height: 300))
        let registry = AcpRegistry.parse(Data(#"""
        {"agents":[
          {"id":"gemini","name":"Gemini CLI","version":"1","description":"Google's agent in your terminal.","distribution":{"npx":{"package":"@google/gemini-cli@1","args":["--experimental-acp"]}}},
          {"id":"goose","name":"Goose","version":"1","description":"An open-source agent from Block.","distribution":{"binary":{"darwin-aarch64":{"archive":"https://example.invalid/g.tar.bz2","cmd":"./goose","sha256":"abc"}}}},
          {"id":"devin","name":"Devin","version":"1","description":"Cognition's coding agent.","distribution":{"binary":{"darwin-aarch64":{"archive":"https://example.invalid/d.tar.gz","cmd":"./devin"}}}}
        ]}
        """#.utf8))
        let list = Form { Section("More agents from the ACP registry") { AcpRegistryList(entries: registry, brain: brain, failure: .constant(nil)) } }
            .formStyle(.grouped)
            .controlSize(.small)
            .preferredColorScheme(.dark)
        try await render(list, name: "acp-registry", size: NSSize(width: 640, height: 320))
    }

    func testFocusedNotchHugsItsContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = AppController(debugStorageDirectory: directory)
        let presentation = NotchPresentation.shared
        for entry in presentation.entries { presentation.remove(entry.id) }
        let id = UUID()
        defer {
            presentation.remove(id)
            controller.notchPresence.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        presentation.present(id: id, priority: .approval, content: Rectangle().fill(Color(red: 1, green: 0, blue: 0)).frame(height: 100), reveal: false)
        presentation.showsInteraction = true
        let bitmap = try await render(openNotch(controller), name: "hug-100", size: NSSize(width: 696, height: 488), wait: 0.6)
        let scale = CGFloat(bitmap.pixelsHigh) / 488
        let screen = NotchPresence.screenUnderPointer()
        let column = bitmap.pixelsWide / 2
        let rows = (0..<bitmap.pixelsHigh).map { bitmap.colorAt(x: column, y: $0)?.usingColorSpace(.sRGB) }
        let red = rows.indices.filter { rows[$0].map { $0.redComponent > 0.8 && $0.greenComponent < 0.3 && $0.blueComponent < 0.3 } ?? false }
        let shapeBottom = try XCTUnwrap(rows.indices.last { rows[$0].map { $0.alphaComponent > 0.9 } ?? false })
        XCTAssertEqual(CGFloat(red.count) / scale, 100, accuracy: 1, "content is clipped")
        XCTAssertEqual(CGFloat(shapeBottom - (red.last ?? 0)) / scale, NotchLayout.bottomInset, accuracy: 2, "slack under the content")
        XCTAssertEqual(CGFloat(shapeBottom + 1) / scale, NotchLayout.size(.focused(content: 100), cameraInset: max(24, screen?.safeAreaInsets.top ?? 0), screen: screen?.frame.size ?? .zero).height, accuracy: 2)
    }

    func testCloseRemovesContentThenShapeThenWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = AppController(debugStorageDirectory: directory)
        let presentation = NotchPresentation.shared
        for entry in presentation.entries { presentation.remove(entry.id) }
        defer {
            controller.notchPresence.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        let expansion = controller.sessionPanel.expansion
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        controller.showPanel(activate: false)
        try await Task.sleep(for: .milliseconds(600))
        let window = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "perry.session" && !existing.contains(ObjectIdentifier($0)) })
        XCTAssertTrue(expansion.open && expansion.contentShown)

        controller.hidePanel()
        XCTAssertFalse(controller.sessionPanel.isVisible)
        XCTAssertTrue(window.isVisible, "the window stays while the shape closes")
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(expansion.open)
        XCTAssertEqual(controller.notchPresence.surface, .resting)

        controller.showPanel(activate: false)
        try await Task.sleep(for: .milliseconds(600))
        controller.hidePanel()
        try await Task.sleep(for: .milliseconds(40))
        controller.showPanel(activate: false)
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertTrue(window.isVisible, "reopening during the close keeps the window")
        XCTAssertTrue(expansion.open && expansion.contentShown)
        controller.collapseNotch()
    }

    func testRenderOpenAndCloseMotionFrames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = AppController(debugStorageDirectory: directory)
        let presentation = NotchPresentation.shared
        for entry in presentation.entries { presentation.remove(entry.id) }
        let id = UUID()
        defer {
            presentation.remove(id)
            controller.notchPresence.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        let card = IntentCard(title: "Move two files into Archive", detail: "Both files keep their contents; nothing else changes.", tier: .orange, targetSummary: "draft-a.txt, draft-b.txt → Archive")
        presentation.present(id: id, priority: .approval, content: IntentCardView(card: card) { _ in }, reveal: false)
        presentation.showsInteraction = true
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/notch-motion")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let frame = NSRect(x: 0, y: 0, width: 696, height: 400)
        let window = CompactConversationPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = NSColor(white: 0.85, alpha: 1)
        let host = NSHostingView(rootView: CompactConversationView(controller: controller))
        host.sizingOptions = []
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let expansion = controller.sessionPanel.expansion
        var index = 0
        func capture(for seconds: Double) async throws {
            let end = Date.now.addingTimeInterval(seconds)
            while Date.now < end {
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: destination.appendingPathComponent(String(format: "frame-%03d.png", index)))
                index += 1
                try await Task.sleep(for: .milliseconds(16))
            }
        }
        withAnimation(NotchMotion.open) { expansion.open = true }
        withAnimation(NotchMotion.contentIn) { expansion.contentShown = true }
        try await capture(for: 0.7)
        print("notch.motion.close.from=\(index)")
        withAnimation(NotchMotion.contentOut) { expansion.contentShown = false } completion: {
            withAnimation(NotchMotion.close) { expansion.open = false }
        }
        try await capture(for: 0.7)
        print("notch.motion.frames=\(index)")
    }

    func testRenderPeekStates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let presentation = NotchPresentation.shared
        for entry in presentation.entries { presentation.remove(entry.id) }
        let controller = AppController(debugStorageDirectory: directory)
        let model = controller.homeController.homeModel
        defer {
            for entry in presentation.entries { presentation.remove(entry.id) }
            controller.notchPresence.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        func shot(_ name: String) async throws {
            controller.sessionPanel.expansion.peeking = true
            controller.sessionPanel.expansion.peekHeight = nil
            try await render(openNotch(controller), name: "peek-\(name)", size: NSSize(width: 592, height: 360), wait: 0.5)
        }
        model.sidebarSelection = nil
        model.threads = []
        model.perrys = []
        model.suggestions = []
        try await shot("empty")

        let drafting = PerryThread(title: "Draft the launch email", turns: [.init(question: "Draft the launch email", answer: "")])
        let notes = PerryThread(title: "Project notes", turns: [.init(question: "Summarize the meeting", answer: "The team agreed to finish the outline before Friday.")])
        model.threads = [notes, drafting]
        model.workingThreads = [drafting.id]
        model.streamingAnswers = [drafting.id: "Subject: Perry is here\nWriting the second paragraph"]
        try await shot("working")

        presentation.present(id: UUID(), priority: .approval, content: Text("Approve?"))
        presentation.showsInteraction = false
        try await shot("needs-you")
        for entry in presentation.entries { presentation.remove(entry.id) }

        let long = PerryThread(title: "Compare every quarterly revenue spreadsheet in the finance folder and write a summary", turns: [.init(question: "Compare", answer: "Read eleven of the fourteen spreadsheets so far, and the totals for the second quarter do not match the board deck")])
        model.threads = [long, drafting]
        try await shot("long-titles")
        model.workingThreads = []
        model.streamingAnswers = [:]

        model.threads = [notes]
        controller.sessionPanel.expansion.peekThread = notes.id
        try await shot("conversation")
        controller.sessionPanel.expansion.peekThread = nil

        model.threads = []
        model.perrys = [Perry(name: "Tidy Desktop", job: "Files new screenshots every evening", threadID: UUID().uuidString),
                        Perry(name: "Inbox Watch", job: "Flags emails that need a reply", threadID: UUID().uuidString)]
        try await shot("helpers")
        model.perrys = []
    }

    func testRenderMascotMoods() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in NotchPresentation.shared.entries { NotchPresentation.shared.remove(entry.id) }
        let controller = AppController(debugStorageDirectory: directory)
        defer {
            controller.overlayState.voiceState = .idle
            controller.overlayState.buddyState = .idle
            controller.notchPresence.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        controller.homeController.homeModel.sidebarSelection = nil
        let moods: [(String, PerryVoicePhase, PerryBuddyState)] = [
            ("resting", .idle, .idle), ("listening", .listening, .idle),
            ("working", .idle, .acting), ("needs-you", .idle, .awaitingApproval)
        ]
        for (name, voice, buddy) in moods {
            controller.overlayState.voiceState = voice
            controller.overlayState.buddyState = buddy
            try await render(openNotch(controller), name: "mascot-\(name)", size: NSSize(width: 892, height: 552), wait: 0.6)
        }
    }

    func testRenderListeningStates() async throws {
        final class Input: VoiceConversationInput {
            var onPartial: (String) -> Void = { _ in }
            var onLevel: (TimeInterval, Double) -> Void = { _, _ in }
            func start() throws {}
            func finish() {}
            func cancel() {}
        }
        final class Silent: TalkSpeechOutput {
            let isSpeaking = false
            func speak(_ sentence: String) {}
            func shutUp() {}
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in NotchPresentation.shared.entries { NotchPresentation.shared.remove(entry.id) }
        let controller = AppController(debugStorageDirectory: directory)
        defer {
            for entry in NotchPresentation.shared.entries { NotchPresentation.shared.remove(entry.id) }
            controller.overlayState.voiceState = .idle
            controller.notchPresence.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        var inputs: [Input] = []
        var clock: TimeInterval = 100
        let voice = TalkSession(
            sessionController: SessionController(),
            overlayState: PerryCursorState(),
            output: controller.guideBridge,
            services: .init(
                makeInput: { fatalError("hold input is not used") },
                output: Silent(),
                capture: { throw CancellationError() },
                acceptInput: { text, _, _ in .init(threadID: UUID(), request: .init(text: text), saved: Task {}) },
                run: { input, _ in (input.threadID, AsyncStream { _ in }, nil) },
                requestPermission: { true },
                makeClickInput: { _, onPartial, onLevel, _ in
                    let input = Input()
                    input.onPartial = onPartial
                    input.onLevel = onLevel
                    inputs.append(input)
                    return input
                },
                now: { clock },
                silenceTimeout: 60
            )
        )
        func hear(_ seconds: Double, rms: Double) async {
            for _ in 0..<Int((seconds / 0.02).rounded()) {
                clock += 0.02
                inputs.last?.onLevel(clock, rms)
            }
            for _ in 0..<10 { await Task.yield() }
        }
        NotchPresentation.shared.present(id: AppController.voiceEntryID, priority: .voice, content: NotchListeningView(voice: voice))
        controller.overlayState.voiceState = .listening

        voice.startClick()
        for _ in 0..<50 where voice.clickState != .listening { try await Task.sleep(for: .milliseconds(10)) }
        await hear(0.4, rms: 0.001)
        try await render(openNotch(controller), name: "listening-start", size: NSSize(width: 592, height: 360), wait: 0.5)
        await hear(0.6, rms: 0.08)
        inputs.last?.onPartial("Move the launch notes into the Archive folder")
        for _ in 0..<10 { await Task.yield() }
        try await render(openNotch(controller), name: "listening-speech", size: NSSize(width: 592, height: 360), wait: 0.3)
        await hear(0.6, rms: 0.001)
        try await render(openNotch(controller), name: "listening-ending", size: NSSize(width: 592, height: 360), wait: 0.3)
        voice.sendNow()
        controller.overlayState.voiceState = .processing
        try await render(openNotch(controller), name: "listening-thinking", size: NSSize(width: 592, height: 360), wait: 0.3)

        voice.cancelClick()
        voice.startClick()
        for _ in 0..<50 where voice.clickState != .listening { try await Task.sleep(for: .milliseconds(10)) }
        await hear(8.1, rms: 0.001)
        controller.overlayState.voiceState = .idle
        try await render(openNotch(controller), name: "listening-failed", size: NSSize(width: 592, height: 360), wait: 0.3)
    }

    private func openNotch(_ controller: AppController) -> CompactConversationView {
        controller.sessionPanel.expansion.open = true
        controller.sessionPanel.expansion.contentShown = true
        return CompactConversationView(controller: controller)
    }

    @discardableResult
    private func render<Content: View>(_ content: Content, name: String, size: NSSize, wait: Double = 0.2, folder: String = "notch-rebuild-evidence") async throws -> NSBitmapImageRep {
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build").appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let frame = NSRect(origin: .zero, size: size)
        let window = CompactConversationPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        window.contentView = host
        host.frame = frame
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .seconds(wait))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(name + ".png"))
        return bitmap
    }
}
