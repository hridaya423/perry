import AppKit
import XCTest
import SwiftUI
import PerryBrain
@testable import Perry

@MainActor
final class HomeRecoveryTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testHomeFollowUpSaveFailurePreservesAcceptedTextAndCannotDispatch() async throws {
        let root = try directory()
        let store = ThreadStore(directory: root)
        let thread = try await store.upsert(PerryThread(draft: "Original follow-up"))
        let home = HomeController()
        home.threadStore = store
        home.homeModel.threads = [thread]
        var dispatched = false
        home.answerProvider = { _, _, _ in dispatched = true; return .completed }
        try FileManager.default.removeItem(at: root)
        try Data("Unavailable directory".utf8).write(to: root)
        home.homeModel.send(threadID: thread.id, text: "Original follow-up")
        home.homeModel.drafts[thread.id] = "A different draft"
        await home.joinAll()
        XCTAssertFalse(dispatched)
        XCTAssertEqual(home.homeModel.unsavedInputs.map(\.request.text), ["Original follow-up"])
        XCTAssertTrue(home.homeModel.pendingQuestions.isEmpty)
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        home.homeModel.onRetryInputSave?(try XCTUnwrap(home.homeModel.unsavedInputs.first?.id))
        await home.joinInputSaves()
        let saved = await ThreadStore(directory: root).thread(id: thread.id)
        XCTAssertEqual(saved?.waitingInputs?.first?.text, "Original follow-up")
        XCTAssertNil(saved?.pendingTurn)
        XCTAssertFalse(dispatched)
        XCTAssertEqual(home.homeModel.drafts[thread.id], "A different draft")
    }

    func testFailedInputsRemainSeparateAndRetryOnlySaves() async throws {
        let root = try directory()
        let home = HomeController()
        var dispatched = false
        home.answerProvider = { _, _, _ in dispatched = true; return .failed("Must not run") }
        home.homeModel.newConversationDraft = "Another draft"
        let first = home.acceptInput("First unsaved request")
        let second = home.acceptInput("Second unsaved request", threadID: first.threadID)
        for input in [first, second] {
            do { try await input.saved.value; XCTFail("Missing storage must fail") }
            catch { }
        }
        XCTAssertEqual(home.homeModel.unsavedInputs.map(\.request.text), [first.request.text, second.request.text])
        home.homeModel.onRetryInputSave?(first.request.id)
        await home.joinInputSaves()
        XCTAssertEqual(home.homeModel.unsavedInputs.count, 2)
        home.threadStore = ThreadStore(directory: root)
        home.homeModel.onRetryInputSave?(first.request.id)
        home.homeModel.onRetryInputSave?(first.request.id)
        await home.joinInputSaves()
        XCTAssertEqual(home.homeModel.unsavedInputs.map(\.id), [second.request.id])
        let disk = await ThreadStore(directory: root).thread(id: first.threadID)
        XCTAssertEqual(disk?.waitingInputs?.map(\.id), [first.request.id])
        XCTAssertNil(disk?.pendingTurn)
        XCTAssertTrue(disk?.turns.isEmpty == true)
        XCTAssertFalse(dispatched)
        XCTAssertEqual(home.homeModel.newConversationDraft, "Another draft")
        home.closeAdmission()
        home.homeModel.onDiscardUnsavedInput?(second.request.id)
        XCTAssertEqual(home.homeModel.unsavedInputs.count, 1)
        home.reopenAdmission()
        home.homeModel.onDiscardUnsavedInput?(second.request.id)
        XCTAssertTrue(home.homeModel.unsavedInputs.isEmpty)
    }

    func testSaveRetryRechecksRepairedStorageWithoutReplacingTheStore() async throws {
        let root = try directory().appendingPathComponent("Threads")
        try Data("Unavailable directory".utf8).write(to: root)
        let home = HomeController()
        home.threadStore = ThreadStore(directory: root)
        let input = home.acceptInput("Keep this request")
        do { try await input.saved.value; XCTFail("Storage must fail") }
        catch { }
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        home.homeModel.onRetryInputSave?(input.request.id)
        await home.joinInputSaves()
        XCTAssertTrue(home.homeModel.unsavedInputs.isEmpty)
        let saved = await ThreadStore(directory: root).thread(id: input.threadID)
        XCTAssertEqual(saved?.waitingInputs?.first?.text, input.request.text)
        XCTAssertNil(saved?.pendingTurn)
    }

    func testWelcomeFailureRetainsOriginalTextAfterComposerChanges() async throws {
        let home = HomeController()
        home.homeModel.onStartConversation?("Original request")
        await home.joinAll()
        home.homeModel.newConversationDraft = "Replacement draft"
        XCTAssertEqual(home.homeModel.unsavedInputs.map(\.request.text), ["Original request"])
        home.threadStore = ThreadStore(directory: try directory())
        home.homeModel.onRetryInputSave?(try XCTUnwrap(home.homeModel.unsavedInputs.first?.id))
        await home.joinInputSaves()
        XCTAssertEqual(home.homeModel.newConversationDraft, "Replacement draft")
        XCTAssertEqual(home.homeModel.threads.first?.waitingInputs?.first?.text, "Original request")
        XCTAssertNil(home.homeModel.threads.first?.pendingTurn)
    }

    func testRenderUnsavedRequestsInBothAppearances() throws {
        let model = HomeModel()
        model.unsavedInputs = [
            .init(threadID: UUID(), request: .init(text: "Show me how to save this document"), error: "The disk is full."),
            .init(threadID: UUID(), request: .init(text: "Summarize this document and keep the original names, dates, and references. Then help me revise the introduction before I share it."), error: "The disk is full.")
        ]
        model.savingInputs = [model.unsavedInputs[0].id]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let frame = NSRect(x: 0, y: 0, width: 520, height: 310)
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            let host = NSHostingView(rootView: UnsavedInputRecoveryView(model: model))
            window.contentView = host
            host.frame = frame
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/dependable-evidence/unsaved-requests-\(name).png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination)
            window.close()
        }
    }

    func testRenderHomeWithUnsavedRequests() async throws {
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }
        let model = HomeModel()
        model.unsavedInputs = [.init(threadID: UUID(), request: .init(text: "Explain this document, keeping the original names and dates."), error: "The disk is full.")]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let frame = NSRect(x: 0, y: 0, width: 720, height: 480)
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            NSApp.appearance = window.appearance
            let host = NSHostingView(rootView: HomeView(model: model)
                .environment(\.colorScheme, name == "light" ? .light : .dark)
                .background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = host
            host.frame = frame
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/dependable-evidence/unsaved-home-\(name).png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination)
            window.close()
        }
    }

    func testMaintenanceDrainsInputAndInvalidatesErasedConversationCache() async throws {
        let root = try directory()
        let store = ThreadStore(directory: root)
        let thread = try await store.upsert(PerryThread(draft: "Old draft", turns: [.init(question: "Old secret", answer: "Old answer")]))
        let home = HomeController()
        home.threadStore = store
        home.homeModel.threads = [thread]
        home.homeModel.sidebarSelection = .thread(thread.id)
        home.homeModel.drafts[thread.id] = "Unsaved old draft"
        home.homeModel.newConversationDraft = "Old welcome draft"
        let accepted = home.acceptInput("Accepted before maintenance", threadID: thread.id)
        home.closeAdmission()
        let rejected = home.acceptInput("Too late", threadID: UUID())
        do { try await rejected.saved.value; XCTFail("Closed Home accepted input") }
        catch is CancellationError {}
        await home.joinAll()
        try await accepted.saved.value
        let before = await store.thread(id: thread.id)
        XCTAssertEqual(before?.waitingInputs?.count, 1)
        try FileManager.default.removeItem(at: root)
        await home.reloadAfterErasure()
        XCTAssertTrue(home.homeModel.threads.isEmpty)
        XCTAssertTrue(home.homeModel.drafts.isEmpty)
        XCTAssertTrue(home.homeModel.newConversationDraft.isEmpty)
        XCTAssertNil(home.homeModel.sidebarSelection)
        home.reopenAdmission()
        let fresh = home.acceptInput("Fresh request", threadID: thread.id)
        try await fresh.saved.value
        let reopened = await ThreadStore(directory: root).thread(id: thread.id)
        XCTAssertTrue(reopened?.turns.isEmpty == true)
        XCTAssertEqual(reopened?.waitingInputs?.map(\.text), ["Fresh request"])
        XCTAssertEqual(reopened?.draft, "")
    }

    func testMaintenanceBlocksQueuedHomeSendAndJoinsDraftWrites() async throws {
        let store = ThreadStore(directory: try directory())
        let home = HomeController()
        home.threadStore = store
        var dispatched = false
        home.answerProvider = { _, _, _ in dispatched = true; return .completed }
        home.homeModel.updateNewDraft("Save this before quitting")
        home.homeModel.onStartConversation?("Save this before quitting")
        home.closeAdmission()
        await home.joinAll()
        XCTAssertFalse(dispatched)
        XCTAssertFalse(home.homeModel.isCreatingConversation)
        XCTAssertTrue(home.homeModel.pendingQuestions.isEmpty)
        let welcome = try await store.welcomeDraft()
        XCTAssertEqual(welcome, "Save this before quitting")
        let saved = await store.list()
        XCTAssertEqual(saved.first?.draft, "Save this before quitting")
        XCTAssertTrue(saved.first?.turns.isEmpty == true)
    }

    func testWaitingRequestRestoresWithoutSendingOrOverwritingOtherDrafts() async throws {
        let store = ThreadStore(directory: try directory())
        let threadID = UUID()
        let input = PerryThread.WaitingInput(text: "Show me how to save this document")
        try await store.stageInput(input, to: threadID)
        let home = HomeController()
        home.threadStore = store
        home.homeModel.threads = await store.list()
        home.homeModel.newConversationDraft = "Welcome draft"
        var sent = false
        home.answerProvider = { _, _, _ in sent = true; return .completed }
        home.homeModel.drafts[threadID] = "Unrelated draft"
        home.homeModel.onRestoreWaitingInput?(threadID, input.id)
        XCTAssertEqual(home.homeModel.drafts[threadID], "Unrelated draft")
        home.homeModel.drafts[threadID] = ""
        home.homeModel.onRestoreWaitingInput?(threadID, input.id)
        XCTAssertEqual(home.homeModel.drafts[threadID], input.text)
        home.homeModel.drafts[threadID] = "Edited during the save"
        let restored = await waitUntil { home.homeModel.threads.first?.waitingInputs?.isEmpty == true }
        XCTAssertTrue(restored)
        XCTAssertEqual(home.homeModel.drafts[threadID], "Edited during the save")
        XCTAssertEqual(home.homeModel.newConversationDraft, "Welcome draft")
        XCTAssertFalse(sent)
        let saved = await store.thread(id: threadID)
        XCTAssertEqual(saved?.draft, input.text)
        XCTAssertNil(saved?.pendingTurn)
    }

    func testRenderWaitingRequestRecoveryAppearances() throws {
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/dependable-evidence")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let content = WaitingInputRecoveryView(
                inputs: [.init(text: "Show me how to save this document"), .init(text: "Find the export settings for this illustration, keep the original colours, and show me where to choose a transparent background before exporting a copy.")],
                canRestore: scheme == .light, restore: { _ in }, remove: { _ in }
            )
            .padding(24)
            .frame(width: 560)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: destination.appendingPathComponent("waiting-recovery-\(name).png"))
        }
    }

    func testStopBeforeProviderDispatchPreservesDraftAndPreventsRun() async throws {
        let store = ThreadStore(directory: try directory())
        let thread = try await store.upsert(PerryThread(draft: "Do not lose this request"))
        let home = HomeController()
        home.threadStore = store
        home.homeModel.threads = [thread]
        var dispatched = false
        home.answerProvider = { _, _, _ in dispatched = true; return .completed }
        home.homeModel.send(threadID: thread.id, text: thread.draft)
        home.homeModel.onStop?(thread.id)
        XCTAssertTrue(home.homeModel.stoppingThreads.contains(thread.id))
        let settled = await waitUntil { home.homeModel.pendingQuestions.isEmpty }
        XCTAssertTrue(settled)
        XCTAssertFalse(dispatched)
        XCTAssertTrue(home.homeModel.stoppingThreads.isEmpty)
        XCTAssertEqual(home.homeModel.draft(for: thread), "Do not lose this request")
        let saved = await store.thread(id: thread.id)
        XCTAssertTrue(saved?.turns.isEmpty == true)
    }

    func testStopAcknowledgesWhileCoordinatorRetiresAndPreservesInput() async throws {
        let store = ThreadStore(directory: try directory())
        let thread = try await store.upsert(PerryThread(draft: "Keep this unfinished task"))
        let entered = expectation(description: "Provider setup started")
        let coordinator = AgentCoordinator(
            provider: { _ in
                entered.fulfill()
                try await Task.sleep(for: .seconds(60))
                throw NSError(domain: "fixture", code: 1)
            }, host: PerryToolHost(executors: []), threads: store,
            consent: ToolConsentStore(directory: nil)
        )
        let home = HomeController()
        home.threadStore = store
        home.homeModel.threads = [thread]
        home.answerProvider = { input, target, partial in
            var finish = AgentFinish.interrupted
            for await event in coordinator.run(threadID: input.threadID, goal: input.request.text, runID: input.request.id, target: target, waitingInputID: input.request.id) {
                if case .finished(let result) = event { finish = result }
            }
            return finish
        }
        var stopRequests = 0
        home.onStop = { id in stopRequests += 1; coordinator.stop(threadID: id) }
        home.homeModel.send(threadID: thread.id, text: thread.draft)
        await fulfillment(of: [entered], timeout: 2)
        home.homeModel.onStop?(thread.id)
        home.homeModel.onStop?(thread.id)
        XCTAssertEqual(stopRequests, 1)
        XCTAssertTrue(home.homeModel.stoppingThreads.contains(thread.id))
        let settled = await waitUntil { home.homeModel.pendingQuestions.isEmpty }
        XCTAssertTrue(settled)
        XCTAssertTrue(home.homeModel.stoppingThreads.isEmpty)
        XCTAssertTrue(coordinator.runningThreads.isEmpty)
        let saved = await store.thread(id: thread.id)
        XCTAssertEqual(saved?.turns.first?.outcome, .interrupted)
        XCTAssertNil(saved?.pendingTurn)
        XCTAssertEqual(saved?.draft, thread.draft)
        let refreshed = try XCTUnwrap(home.homeModel.threads.first { $0.id == thread.id })
        XCTAssertEqual(home.homeModel.draft(for: refreshed), thread.draft)
    }

    func testCompactConversationSavesBeforeHomeOpensAndReopensInHome() async throws {
        let root = try directory()
        let store = ThreadStore(directory: root)
        let home = HomeController()
        home.threadStore = store
        defer { home.stop() }
        let target = CuaTargetHint(bundleID: "fixture.editor", processID: 10, windowID: 20)
        home.answerProvider = { input, receivedTarget, partial in
            XCTAssertEqual(receivedTarget, target)
            do {
                let thread = try await store.beginTurn(to: input.threadID, question: input.request.text, runID: input.request.id, waitingInputID: input.request.id)
                partial("Cedar")
                try await store.finishTurn(to: input.threadID, runID: XCTUnwrap(thread.pendingTurn?.id), answer: "Cedar", outcome: .completed)
                return .completed
            } catch { return .failed(error.localizedDescription) }
        }
        home.prepareConversation(target: target)
        home.homeModel.updateNewDraft("Our project is Cedar")
        home.homeModel.onStartConversation?(home.homeModel.newConversationDraft)
        let finished = await waitUntil { home.homeModel.threads.first?.turns.count == 1 && home.homeModel.pendingQuestions.isEmpty }
        XCTAssertTrue(finished)
        XCTAssertNil(home.homeWindow)
        let id = try XCTUnwrap(home.homeModel.threads.first?.id)
        let saved = await ThreadStore(directory: root).thread(id: id)
        XCTAssertEqual(saved?.turns.first?.answer, "Cedar")
        XCTAssertEqual(home.homeModel.sidebarSelection, .thread(id))
        home.openHome(selection: home.homeModel.sidebarSelection)
        XCTAssertNotNil(home.homeWindow)
        XCTAssertEqual(home.homeModel.sidebarSelection, .thread(id))
        XCTAssertEqual(home.homeModel.conversationTargets[id], target)
    }

    func testConversationRetainsItsInvocationTargetAcrossFollowUps() async throws {
        let home = HomeController()
        home.threadStore = ThreadStore(directory: try directory())
        let first = CuaTargetHint(bundleID: "fixture.editor", processID: 10, windowID: 20)
        let next = CuaTargetHint(bundleID: "fixture.preview", processID: 30, windowID: 40)
        var capturedBeforePresentation = false
        var delivered: [(UUID, CuaTargetHint?)] = []
        home.captureTarget = {
            capturedBeforePresentation = home.homeWindow?.isKeyWindow != true
            return first
        }
        home.answerProvider = { input, target, _ in
            delivered.append((input.threadID, target))
            return .completed
        }
        home.openHome()
        defer { home.stop() }
        home.homeModel.updateNewDraft("First question")
        home.captureTarget = { next }
        home.openHome(selection: .settings)
        XCTAssertEqual(home.homeModel.newConversationTarget, first)
        home.homeModel.onStartConversation?("First question")
        home.homeModel.newConversationTarget = next
        let firstFinished = await waitUntil { delivered.count == 1 && home.homeModel.pendingQuestions.isEmpty }
        XCTAssertTrue(firstFinished)
        XCTAssertTrue(capturedBeforePresentation)
        let id = try XCTUnwrap(delivered.first?.0)
        home.homeModel.send(threadID: id, text: "Follow-up")
        let followUpFinished = await waitUntil { delivered.count == 2 }
        XCTAssertTrue(followUpFinished)
        XCTAssertEqual(delivered.map { $0.1 }, [first, first])
    }

    func testClosingInterruptedTaskPreservesInputAndNeverExecutesIt() async throws {
        let root = try directory()
        let store = ThreadStore(directory: root)
        let id = UUID()
        _ = try await store.beginTurn(to: id, question: "Rename these files")
        try await store.setDraft("A separate follow-up", for: id)
        let home = HomeController()
        home.threadStore = store
        var dispatched = 0
        home.answerProvider = { _, _, _ in dispatched += 1; return .completed }
        defer { home.stop() }
        home.openHome(selection: .thread(id))
        let loaded = await waitUntil { home.homeModel.threads.first?.pendingTurn != nil }
        XCTAssertTrue(loaded)
        home.homeModel.streamingAnswers[id] = "I renamed one file before stopping."
        home.homeModel.onResolveInterrupted?(id)
        let reconciled = await waitUntil { home.homeModel.threads.first?.turns.count == 1 }
        XCTAssertTrue(reconciled)
        let saved = await ThreadStore(directory: root).thread(id: id)
        XCTAssertNil(saved?.pendingTurn)
        XCTAssertEqual(saved?.turns.first?.question, "Rename these files")
        XCTAssertEqual(saved?.turns.first?.answer, "I renamed one file before stopping.")
        XCTAssertEqual(saved?.turns.first?.outcome, .interrupted)
        XCTAssertEqual(saved?.draft, "A separate follow-up")
        XCTAssertEqual(dispatched, 0)
    }

    func testHomeRestoresTheUnsentWelcomeDraft() async throws {
        let store = ThreadStore(directory: try directory())
        try await store.setWelcomeDraft("Help me think through a trip")
        let home = HomeController()
        home.threadStore = store
        defer { home.stop() }
        home.openHome()
        let loaded = await waitUntil { home.homeModel.newConversationDraft == "Help me think through a trip" }
        let diskDraft = try await store.welcomeDraft()
        XCTAssertTrue(loaded, "Visible: \(home.homeModel.newConversationDraft), disk: \(diskDraft), error: \(home.homeModel.storageError ?? "none")")
        XCTAssertTrue(home.homeModel.threads.isEmpty)
    }

    func testSavingAStreamedAnswerKeepsOneVisibleTurn() {
        var thread = PerryThread(turns: [.init(question: "First", answer: "First answer")])
        let model = HomeModel()
        model.pendingQuestions[thread.id] = .init(text: "Second", turnIndex: 1)
        model.streamingAnswers[thread.id] = "Second answer"
        let streamed = model.displayedTurns(for: thread)
        XCTAssertEqual(streamed.map(\.question), ["First", "Second"])
        XCTAssertEqual(streamed.last?.answer, "Second answer")
        thread.turns.append(.init(question: "Second", answer: "Second answer"))
        let saved = model.displayedTurns(for: thread)
        XCTAssertEqual(saved.map(\.question), streamed.map(\.question))
        XCTAssertEqual(saved.map(\.answer), streamed.map(\.answer))
    }

    func testReadingPositionSurvivesStreamingAndSave() async throws {
        let store = ThreadStore(directory: try directory())
        let id = UUID()
        let thread = try await store.beginTurn(to: id, question: "Tell me a long story")
        let home = HomeController()
        home.threadStore = store
        home.homeModel.pendingQuestions[id] = .init(text: "Tell me a long story", turnIndex: 0)
        home.homeModel.workingThreads = [id]
        let first = (1...80).map { "Paragraph \($0): Cedar is a fictional town beside a river." }.joined(separator: "\n\n")
        home.homeModel.streamingAnswers[id] = first
        home.openHome(selection: .thread(id))
        defer { home.stop() }
        let loaded = await waitUntil { home.homeModel.threads.first?.pendingTurn != nil }
        XCTAssertTrue(loaded)
        let content = try XCTUnwrap(home.homeWindow?.contentView)
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        let laidOut = await waitUntil { scrollViews(in: content).contains { ($0.documentView?.bounds.height ?? 0) > 1000 } }
        XCTAssertTrue(laidOut)
        let scroll = try XCTUnwrap(scrollViews(in: content).max { $0.bounds.width < $1.bounds.width })
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        XCTAssertEqual(home.homeModel.conversationPositions[id]?.followsLatest, false)
        let readingY = scroll.contentView.bounds.minY
        let answer = first + "\n\nThe river reaches the sea."
        home.homeModel.streamingAnswers[id] = answer
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(scroll.contentView.bounds.minY, readingY, accuracy: 2)
        try await store.finishTurn(to: id, runID: try XCTUnwrap(thread.pendingTurn?.id), answer: answer, outcome: .completed)
        home.homeModel.threads = await store.list()
        home.homeModel.pendingQuestions[id] = nil
        home.homeModel.streamingAnswers[id] = nil
        home.homeModel.workingThreads = []
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(scroll.contentView.bounds.minY, readingY, accuracy: 2)
        XCTAssertEqual(home.homeModel.displayedTurns(for: try XCTUnwrap(home.homeModel.threads.first)).count, 1)
        home.homeModel.sidebarSelection = nil
        try await Task.sleep(for: .milliseconds(50))
        home.homeModel.sidebarSelection = .thread(id)
        try await Task.sleep(for: .milliseconds(50))
        let restored = try XCTUnwrap(scrollViews(in: content).max { $0.bounds.width < $1.bounds.width })
        XCTAssertEqual(restored.contentView.bounds.minY, readingY, accuracy: 2)
        home.homeModel.conversationPositions[id] = .init()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(restored.contentView.bounds.maxY, try XCTUnwrap(restored.documentView).bounds.maxY, accuracy: 2)
    }

    func testSetupAndSidebarFitInsideHomeWindow() async throws {
        let home = HomeController()
        let director = OnboardingDirector()
        director.start()
        home.homeModel.onboarding = director
        home.openHome()
        defer { home.stop(); director.stop() }
        let content = try XCTUnwrap(home.homeWindow?.contentView)
        func splitView(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            return view.subviews.lazy.compactMap { splitView(in: $0) }.first
        }
        let loaded = await waitUntil { splitView(in: content) != nil }
        XCTAssertTrue(loaded)
        content.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(splitView(in: content))
        let bounds = split.convert(split.bounds, to: content)
        XCTAssertGreaterThanOrEqual(bounds.minY, -1)
        XCTAssertLessThanOrEqual(bounds.maxY, content.bounds.maxY + 1)
        home.homeModel.threads = (1...3).map { PerryThread(title: "A conversation about project \($0)") }
        home.homeModel.onboarding = nil
        await Task.yield()
        content.layoutSubtreeIfNeeded()
        let welcomeBounds = split.convert(split.bounds, to: content)
        XCTAssertGreaterThanOrEqual(welcomeBounds.minY, -1)
        XCTAssertLessThanOrEqual(welcomeBounds.maxY, content.bounds.maxY + 1)
    }

}
