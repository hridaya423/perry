import AppKit
import Combine
import SwiftUI
import PerryBrain
import PerryGuide

/// Notch Home (Phase 5 §4.7): a resting strip in the notch, a hover peek,
/// and the full Home window. Event-driven only — pointer position arrives
/// through NSEvent monitors, and dwell/tuck run on a single deadline timer
/// owned by `HomeHoverIntent`. The strip stays invisible on notched Macs
/// (dead space beside the camera) and renders as a slim dot below the menu
/// bar on Macs without a notch.
@MainActor
final class HomeController {
    struct AcceptedInput {
        let threadID: UUID
        let request: PerryThread.WaitingInput
        let saved: Task<Void, Error>
    }

    private var acceptsInput = true
    private var resumeMonitoring = false
    private var work: [UUID: (task: Task<Void, Never>, cancelOnMaintenance: Bool)] = [:]
    private var inputSaveTask: Task<Void, Error>?

    func joinInputSaves() async {
        _ = await inputSaveTask?.result
    }

    static let homeFrameKey = "perry.home.frame"

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: NotchStatusController.enabledKey) as? Bool ?? true }
    }

    private var intent = HomeHoverIntent()
    private var monitors: [Any] = []
    private var deadlineTimer: Timer?
    private var insideZone = false
    private var peekPanel: NSPanel?
    private let peekView = HomePeekView()
    private var dotPanel: NSPanel?
    /// Internal (not private) so tests can assert the window is key-capable
    /// and resizable — the properties the deleted panels were tested for.
    var homeWindow: NSWindow?
    let homeModel = HomeModel()
    private var welcomeDraftEdited = false
    private var welcomeDraftLoaded = false
    private var welcomeDraftSaveTask: Task<Void, Never>?
    private var recoveryWriteTask: Task<Void, Never>?

    private var peekContent = HomePeekContent()
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var threadStore: ThreadStore?
    var captureTarget: (() -> CuaTargetHint?)?
    var answerProvider: ((AcceptedInput, CuaTargetHint?, @MainActor @Sendable (String) -> Void) async -> AgentFinish)?
    var onStop: ((UUID) -> Void)?

    /// Owner binds the coordinator's running set → composer's working row.
    func bindWorkingThreads(_ publisher: some Publisher<Set<UUID>, Never>) -> AnyCancellable {
        publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] threads in
                guard let self else { return }
                self.homeModel.workingThreads = threads
                self.performWork { await self.refreshThreads() }
            }
    }

    // MARK: - Lifecycle

    func start() {
        guard monitors.isEmpty else { return }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in self?.pointerMoved() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.pointerMoved()
            return event
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in self?.mouseDown() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.mouseDown()
            return event
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.keyDown(event) }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.keyDown(event)
            return event
        } as Any)
        showRestingDotIfNeeded()
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        hidePeek()
        dotPanel?.orderOut(nil)
        homeWindow?.close()
        insideZone = false
        intent = HomeHoverIntent()
    }

    func closeAdmission() {
        acceptsInput = false
        resumeMonitoring = !monitors.isEmpty
        stop()
        for item in work.values where item.cancelOnMaintenance { item.task.cancel() }
    }

    func joinAll() async {
        for item in work.values { await item.task.value }
        await joinInputSaves()
    }

    func reopenAdmission() {
        acceptsInput = true
        if resumeMonitoring { start() }
        resumeMonitoring = false
    }

    func reloadAfterErasure() async {
        _ = await threadStore?.reload()
        homeModel.drafts = [:]
        homeModel.pendingQuestions = [:]
        homeModel.streamingAnswers = [:]
        homeModel.threadErrors = [:]
        homeModel.storageError = nil
        homeModel.unsavedInputs = []
        homeModel.savingInputs = []
        homeModel.workingThreads = []
        homeModel.stoppingThreads = []
        homeModel.conversationPositions = [:]
        homeModel.conversationTargets = [:]
        homeModel.newConversationTarget = nil
        homeModel.newConversationDraft = ""
        homeModel.sidebarSelection = nil
        welcomeDraftLoaded = false
        welcomeDraftEdited = false
        peekContent = HomePeekContent()
        peekView.update(peekContent)
        await restoreWelcomeDraft()
        await refreshThreads()
        homeModel.perrys = await perryListProvider?() ?? []
        homeModel.routines = routineListProvider?() ?? []
        homeModel.suggestions = []
    }

    @discardableResult
    private func performWork(cancelOnMaintenance: Bool = false, _ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard acceptsInput else { return nil }
        let id = UUID()
        let task = Task { @MainActor in
            defer { self.work[id] = nil }
            await operation()
        }
        work[id] = (task, cancelOnMaintenance)
        return task
    }

    // MARK: - Content

    /// Status pill contents feed the peek's agent/unread rows.
    func updateStatus(isRecording: Bool, agentLines: [String], unreadCount: Int) {
        var lines = agentLines
        if isRecording { lines.insert("Recording a demonstration", at: 0) }
        peekContent.agentLines = lines
        peekContent.unreadCount = unreadCount
        peekView.update(peekContent)
    }

    func updatePerrys(_ perrys: [Perry]) {
        peekContent.pinnedPerryNames = perrys.map(\.name)
        homeModel.perrys = perrys
        peekView.update(peekContent)
    }

    /// Refreshes the sidebar's Perry list — injected by AppController so the
    /// view never touches `PerryStore` directly.
    var perryListProvider: (() async -> [Perry])?

    /// Owns card lifecycle (act/dismiss bookkeeping); injected by the owner.
    var suggestionController: SuggestionController?

    /// Sidebar routines — injected so the view never touches RoutineStore.
    var routineListProvider: (() -> [LearnedRoutine])?
    var onRoutineRun: ((LearnedRoutine) -> Void)?
    var onRoutineRemove: ((LearnedRoutine) -> Void)?

    func updateSuggestions(_ cards: [SuggestionCard]) {
        homeModel.suggestions = cards
    }

    func refreshRoutines() {
        homeModel.routines = routineListProvider?() ?? []
    }

    func noteAnswer(_ text: String) {
        peekContent.lastAnswer = text
        peekView.update(peekContent)
    }

    // MARK: - Zone geometry

    /// The hover strip: on a notched screen, the dead space beside/under the
    /// camera (auxiliary areas bracket the notch); otherwise a small zone
    /// around the resting dot below the menu bar.
    nonisolated static func zoneRect(for screen: NSScreen) -> CGRect {
        let top = screen.frame.maxY
        if screen.safeAreaInsets.top > 0 {
            let left = screen.auxiliaryTopLeftArea?.maxX ?? screen.frame.midX - 100
            let right = screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX + 100
            let center = (left + right) / 2
            let width = max(220, right - left + 40)
            return CGRect(x: center - width / 2,
                          y: top - screen.safeAreaInsets.top - 8,
                          width: width,
                          height: screen.safeAreaInsets.top + 8)
        }
        // Pill fallback: slim dot just below the menu bar, top-center.
        return CGRect(x: screen.frame.midX - 20, y: top - 24 - 14, width: 40, height: 14)
    }

    private func currentZone() -> CGRect? {
        guard acceptsInput, isEnabled else { return nil }
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
        guard let screen else { return nil }
        var zone = Self.zoneRect(for: screen)
        // While the peek is open the zone grows to include it, so sliding
        // the pointer down into the peek keeps it open.
        if let peek = peekPanel, peek.isVisible {
            zone = zone.union(peek.frame)
        }
        return zone
    }

    private func pointerMoved() {
        guard isEnabled, let zone = currentZone() else {
            if insideZone { insideZone = false; apply(intent.exited(at: now)) }
            return
        }
        let inside = zone.contains(NSEvent.mouseLocation)
        if inside && !insideZone {
            insideZone = true
            PerfMark.mark("home.hover_start")
            apply(intent.entered(at: now))
        } else if !inside && insideZone {
            insideZone = false
            apply(intent.exited(at: now))
        }
    }

    private func mouseDown() {
        guard isEnabled, let zone = currentZone() else { return }
        if zone.contains(NSEvent.mouseLocation) {
            openHome()
        }
    }

    private func keyDown(_ event: NSEvent) {
        if event.keyCode == 53 {
            if homeWindow?.isVisible == true {
                closeHome()
            } else {
                apply(intent.escape())
            }
            return
        }
        // ⌃⌘Space toggles full Home (§4.7).
        if event.keyCode == 49 {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) && flags.contains(.control)
                && !flags.contains(.option) && !flags.contains(.shift) {
                if homeWindow?.isVisible == true { closeHome() } else { openHome() }
            }
        }
    }

    private func apply(_ action: HomeHoverIntent.Action) {
        switch action {
        case .showPeek: showPeek()
        case .hidePeek: hidePeek()
        case .none: break
        }
        rescheduleDeadline()
    }

    private func rescheduleDeadline() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard let deadline = intent.pendingDeadline else { return }
        let delay = max(0, deadline - now)
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.apply(self.intent.deadlineReached(at: self.now))
            }
        }
        timer.tolerance = 0
        deadlineTimer = timer
    }

    // MARK: - Panels

    private func showRestingDotIfNeeded() {
        guard isEnabled else { return }
        let notched = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
        guard !notched else { return }
        guard dotPanel == nil, let screen = NSScreen.main else { return }
        let zone = Self.zoneRect(for: screen)
        let dot = NSPanel(
            contentRect: CGRect(x: zone.midX - 3, y: zone.midY - 3, width: 6, height: 6),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        dot.level = .statusBar
        dot.isOpaque = false
        dot.backgroundColor = .clear
        dot.hasShadow = false
        dot.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.6).cgColor
        view.layer?.cornerRadius = 3
        dot.contentView = view
        dot.orderFrontRegardless()
        dotPanel = dot
    }

    private func showPeek() {
        guard acceptsInput else { return }
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
        guard let screen else { return }
        let zone = Self.zoneRect(for: screen)
        let panel = peekPanel ?? Self.makePeekPanel(content: peekView)
        peekView.onOpenHome = { [weak self] in self?.openHome() }
        let size = peekView.fittingSize
        panel.setFrame(
            CGRect(x: zone.midX - size.width / 2,
                   y: zone.minY - 4 - size.height,
                   width: size.width, height: size.height),
            display: true
        )
        panel.contentView?.layer?.cornerRadius = 12
        peekPanel = panel
        panel.orderFrontRegardless()
        PerfMark.mark("home.peek_shown")
    }

    private func hidePeek() {
        peekPanel?.orderOut(nil)
    }

    private static func makePeekPanel(content: NSView) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let capsule = NSVisualEffectView()
        capsule.material = .popover
        capsule.state = .active
        capsule.blendingMode = .behindWindow
        capsule.wantsLayer = true
        capsule.layer?.masksToBounds = true
        capsule.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: capsule.topAnchor),
            content.bottomAnchor.constraint(equalTo: capsule.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: capsule.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: capsule.trailingAnchor)
        ])
        panel.contentView = capsule
        return panel
    }

    /// Services the embedded pages need — set once by AppController.
    func configure(deps: HomeModel.Deps) {
        homeModel.deps = deps
    }

    // MARK: - Full Home

    func openHome(selection: HomeModel.Selection? = nil) {
        guard acceptsInput else { return }
        if homeModel.newConversationDraft.isEmpty || homeModel.newConversationTarget == nil {
            homeModel.newConversationTarget = captureTarget?()
        }
        if let selection {
            homeModel.sidebarSelection = selection
        }
        let window = homeWindow ?? makeHomeWindow()
        homeWindow = window
        refreshRoutines()
        performWork {
            await self.restoreWelcomeDraft()
            await self.refreshThreads()
            if let perryListProvider = self.perryListProvider {
                self.homeModel.perrys = await perryListProvider()
            }
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
        apply(intent.setHomeOpen(true))
        PerfMark.mark("home.opened")
    }

    func closeHome() {
        homeWindow?.close()
    }

    private func makeHomeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Perry Home"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HomeView(model: homeModel))
        if let saved = UserDefaults.standard.string(forKey: Self.homeFrameKey) {
            window.setFrame(from: saved)
        } else {
            window.center()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.acceptsInput, let window = self.homeWindow else { return }
                UserDefaults.standard.set(window.frameDescriptor, forKey: Self.homeFrameKey)
                _ = self.intent.setHomeOpen(false)
            }
        }
        return window
    }

    init() {
        homeModel.onRetryInputSave = { [weak self] id in
            guard let self, self.acceptsInput, !self.homeModel.savingInputs.contains(id),
                  let input = self.homeModel.unsavedInputs.first(where: { $0.id == id }) else { return }
            _ = self.saveInput(input.request, to: input.threadID)
        }
        homeModel.onDiscardUnsavedInput = { [weak self] id in
            guard let self, self.acceptsInput, !self.homeModel.savingInputs.contains(id) else { return }
            self.homeModel.unsavedInputs.removeAll { $0.id == id }
        }
        homeModel.onNewDraftChanged = { [weak self] text in
            guard let self, self.acceptsInput else { return }
            self.welcomeDraftEdited = true
            self.welcomeDraftSaveTask?.cancel()
            self.welcomeDraftSaveTask = self.performWork {
                do {
                    try Task.checkCancellation()
                    try await self.threadStore?.setWelcomeDraft(text)
                } catch is CancellationError {
                } catch {
                    self.homeModel.storageError = "Couldn’t save your draft. Keep Perry open and try again. \(error.localizedDescription)"
                }
            }
        }
        homeModel.onRestoreWaitingInput = { [weak self] id, inputID in
            guard let self, self.acceptsInput,
                  let thread = self.homeModel.threads.first(where: { $0.id == id }),
                  self.homeModel.draft(for: thread).isEmpty,
                  thread.pendingTurn == nil,
                  !self.homeModel.workingThreads.contains(id),
                  let input = thread.waitingInputs?.first(where: { $0.id == inputID }) else { return }
            self.homeModel.drafts[id] = input.text
            let previousWrite = self.recoveryWriteTask
            self.recoveryWriteTask = self.performWork {
                await previousWrite?.value
                do {
                    guard let store = self.threadStore else { throw CocoaError(.fileReadUnknown) }
                    try await store.restoreWaitingInput(inputID, from: id)
                    self.homeModel.storageError = nil
                    await self.refreshThreads()
                } catch { self.homeModel.storageError = error.localizedDescription }
            }
        }
        homeModel.onRemoveWaitingInput = { [weak self] id, inputID in
            guard let self, self.acceptsInput else { return }
            let previousWrite = self.recoveryWriteTask
            self.recoveryWriteTask = self.performWork {
                await previousWrite?.value
                do {
                    guard let store = self.threadStore else { throw CocoaError(.fileReadUnknown) }
                    try await store.removeWaitingInput(inputID, from: id)
                    self.homeModel.storageError = nil
                    await self.refreshThreads()
                } catch { self.homeModel.storageError = error.localizedDescription }
            }
        }
        homeModel.onResolveInterrupted = { [weak self] id in
            guard let self, self.acceptsInput, !self.homeModel.workingThreads.contains(id) else { return }
            self.performWork {
                guard let store = self.threadStore, let pending = await store.thread(id: id)?.pendingTurn else { return }
                do {
                    try await store.finishTurn(
                        to: id, runID: pending.id, answer: self.homeModel.streamingAnswers[id] ?? "",
                        outcome: .interrupted, failureReason: "Interrupted task closed after your review. Its effects have not been independently verified."
                    )
                    self.homeModel.streamingAnswers[id] = nil
                    await self.refreshThreads()
                } catch {
                    self.homeModel.storageError = error.localizedDescription
                }
            }
        }
        homeModel.onStop = { [weak self] id in
            guard let self, self.acceptsInput,
                  self.homeModel.pendingQuestions[id] != nil || self.homeModel.workingThreads.contains(id),
                  self.homeModel.stoppingThreads.insert(id).inserted else { return }
            self.onStop?(id)
        }
        homeModel.onStartConversation = { [weak self] text in
            guard let self, self.acceptsInput, !self.homeModel.isCreatingConversation,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self.homeModel.isCreatingConversation = true
            let target = self.homeModel.newConversationTarget
            let input = self.acceptInput(text, threadID: UUID())
            self.homeModel.conversationTargets[input.threadID] = target
            self.submitHomeInput(input, target: target, welcomeDraft: text)
        }
        homeModel.onSend = { [weak self] threadID, text in
            guard let self, self.acceptsInput else { return }
            let target = self.homeModel.conversationTargets[threadID]
            let input = self.acceptInput(text, threadID: threadID)
            self.homeModel.conversationTargets[input.threadID] = target
            self.submitHomeInput(input, target: target)
        }

        homeModel.onDraftChanged = { [weak self] id, draft in
            guard let self, self.acceptsInput else { return }
            self.performWork {
                do {
                    try await self.threadStore?.setDraft(draft, for: id)
                    self.homeModel.storageError = nil
                } catch {
                    self.homeModel.storageError = "Couldn’t save your draft. Keep Perry open and try again. \(error.localizedDescription)"
                }
            }
        }
        homeModel.onSuggestionAct = { [weak self] card in
            guard let self, self.acceptsInput else { return }
            self.performWork {
                guard let store = self.threadStore else {
                    self.homeModel.storageError = "Conversation storage is unavailable. The suggestion is still here."
                    return
                }
                let threadID = UUID()
                do {
                    try await store.upsert(PerryThread(id: threadID, title: card.title, sourceServiceID: card.sourceServiceID, draft: card.body))
                    await self.refreshThreads()
                    self.homeModel.sidebarSelection = .thread(threadID)
                    self.suggestionController?.act(on: card) { card in
                        self.homeModel.send(threadID: threadID, text: card.body)
                    }
                } catch {
                    self.homeModel.storageError = error.localizedDescription
                }
            }
        }
        homeModel.onSuggestionAdjust = { [weak self] card in
            guard let self, self.acceptsInput else { return }
            self.suggestionController?.adjust(card)
        }
        homeModel.onSuggestionDismiss = { [weak self] card in
            guard let self, self.acceptsInput else { return }
            self.suggestionController?.dismiss(card)
        }
        homeModel.onRoutineRun = { [weak self] routine in
            guard let self, self.acceptsInput else { return }
            self.onRoutineRun?(routine)
        }
        homeModel.onRoutineRemove = { [weak self] routine in
            guard let self, self.acceptsInput else { return }
            self.onRoutineRemove?(routine)
            self.refreshRoutines()
        }
        homeModel.onPerrySelected = { [weak self] perry in
            guard let self, self.acceptsInput, let uuid = UUID(uuidString: perry.threadID) else { return }
            self.performWork {
                // The Perry's thread is created on first open, stamped with
                // perryID so tool consent scopes to the Perry, not the turn.
                if await self.threadStore?.thread(id: uuid) == nil {
                    do {
                        try await self.threadStore?.upsert(
                            PerryThread(id: uuid, title: perry.name, perryID: perry.id.uuidString)
                        )
                    } catch {
                        self.homeModel.storageError = error.localizedDescription
                        return
                    }
                }
                await self.refreshThreads()
                self.homeModel.sidebarSelection = .thread(uuid)
            }
        }
    }

    private func submitHomeInput(_ input: AcceptedInput, target: CuaTargetHint?, welcomeDraft: String? = nil) {
        let threadID = input.threadID
        homeModel.pendingQuestions[threadID] = .init(
            text: input.request.text, turnIndex: homeModel.threads.first { $0.id == threadID }?.turns.count ?? 0
        )
        homeModel.threadErrors[threadID] = nil
        performWork(cancelOnMaintenance: true) {
            defer { if welcomeDraft != nil { self.homeModel.isCreatingConversation = false } }
            let finish = await self.presentRun(threadID: threadID, text: input.request.text) { onPartial in
                do {
                    try await input.saved.value
                    try Task.checkCancellation()
                    guard self.acceptsInput, !self.homeModel.stoppingThreads.contains(threadID) else { return .interrupted }
                    if let welcomeDraft, self.homeModel.newConversationDraft == welcomeDraft {
                        self.homeModel.updateNewDraft("")
                    }
                    return await self.answerProvider?(input, target, onPartial)
                        ?? .failed("Connect a model in Settings to start a conversation.")
                } catch is CancellationError {
                    return .interrupted
                } catch {
                    return .failed("Couldn’t save your request. Open Requests not saved to recover it. \(error.localizedDescription)")
                }
            }
            if finish == .interrupted {
                // Accepted but never dispatched: promote the staged request
                // into the thread draft so it survives quit. restoreWaitingInput
                // refuses when the composer already holds another draft — the
                // staged copy stays listed for manual restore.
                try? await self.threadStore?.restoreWaitingInput(input.request.id, from: threadID)
            }
        }
    }

    func acceptInput(_ text: String, threadID requestedThreadID: UUID? = nil) -> AcceptedInput {
        guard acceptsInput else {
            return AcceptedInput(threadID: requestedThreadID ?? UUID(), request: .init(text: text), saved: Task { throw CancellationError() })
        }
        let threadID: UUID
        if let requestedThreadID, !TalkContextStore.isResetPhrase(text) {
            threadID = requestedThreadID
        } else if case .thread(let selected) = homeModel.sidebarSelection, !TalkContextStore.isResetPhrase(text) {
            threadID = selected
        } else {
            threadID = UUID()
        }
        let request = PerryThread.WaitingInput(text: text)
        PerfMark.mark("home.question.sent")
        let saved = saveInput(request, to: threadID)
        homeModel.sidebarSelection = .thread(threadID)
        return AcceptedInput(threadID: threadID, request: request, saved: saved)
    }

    private func saveInput(_ request: PerryThread.WaitingInput, to threadID: UUID) -> Task<Void, Error> {
        let isRetry = homeModel.unsavedInputs.contains { $0.id == request.id }
        homeModel.savingInputs.insert(request.id)
        let previousSave = inputSaveTask
        let saved = Task { @MainActor in
            _ = await previousSave?.result
            defer { self.homeModel.savingInputs.remove(request.id) }
            do {
                guard let store = self.threadStore else { throw CocoaError(.fileWriteUnknown) }
                if isRetry { _ = await store.reload() }
                try await store.stageInput(request, to: threadID)
                self.homeModel.unsavedInputs.removeAll { $0.id == request.id }
                await self.refreshThreads()
                if isRetry { self.homeModel.sidebarSelection = .thread(threadID) }
            } catch {
                self.retainUnsavedInput(request, threadID: threadID, error: error)
                throw error
            }
        }
        inputSaveTask = saved
        return saved
    }

    private func retainUnsavedInput(_ request: PerryThread.WaitingInput, threadID: UUID, error: Error) {
        if let index = homeModel.unsavedInputs.firstIndex(where: { $0.id == request.id }) {
            homeModel.unsavedInputs[index].error = error.localizedDescription
        } else {
            homeModel.unsavedInputs.append(.init(threadID: threadID, request: request, error: error.localizedDescription))
        }
    }

    func runSpokenTurn(_ input: AcceptedInput, spatial: AgentCoordinator.SpatialContext, coordinator: AgentCoordinator) -> (threadID: UUID, events: AsyncStream<AgentLoopEvent>, completion: Task<Void, Never>?) {
        let threadID = input.threadID
        let text = input.request.text
        guard acceptsInput else {
            return (threadID, AsyncStream { $0.yield(.finished(.interrupted)); $0.finish() }, nil)
        }
        guard homeModel.pendingQuestions[threadID] == nil, !coordinator.runningThreads.contains(threadID) else {
            return (threadID, AsyncStream { continuation in
                continuation.yield(.finished(.failed("This conversation is still working. Stop it or wait before asking another question.")))
                continuation.finish()
            }, nil)
        }
        homeModel.pendingQuestions[threadID] = .init(
            text: text, turnIndex: homeModel.threads.first { $0.id == threadID }?.turns.count ?? 0
        )
        let target = spatial.target
        homeModel.sidebarSelection = .thread(threadID)
        homeModel.conversationTargets[threadID] = target
        let (events, continuation) = AsyncStream<AgentLoopEvent>.makeStream()
        let task = performWork(cancelOnMaintenance: true) {
            do {
                try await input.saved.value
            } catch {
                self.homeModel.pendingQuestions[threadID] = nil
                self.homeModel.stoppingThreads.remove(threadID)
                continuation.yield(.finished(.failed(self.homeModel.storageError ?? error.localizedDescription)))
                continuation.finish()
                return
            }
            let finish = await self.presentRun(threadID: threadID, text: text) { onPartial in
                var answer = ""
                var markup = InlineMarkupParser(validElementIDs: [])
                var finish: AgentFinish = .interrupted
                for await event in coordinator.run(threadID: threadID, goal: text, surface: .talk, runID: input.request.id, target: target, spatialContext: spatial, waitingInputID: input.request.id) {
                    switch event {
                    case .textDelta(let delta):
                        answer += markup.feed(delta).text
                        onPartial(answer)
                    case .finished(let outcome):
                        finish = outcome
                        continue
                    default: break
                    }
                    continuation.yield(event)
                }
                return finish
            }
            if finish == .interrupted {
                try? await self.threadStore?.restoreWaitingInput(input.request.id, from: threadID)
            }
            continuation.yield(.finished(finish))
            continuation.finish()
        }
        continuation.onTermination = { _ in task?.cancel() }
        return (threadID, events, task)
    }

    private func presentRun(
        threadID: UUID, text: String,
        operation: (@escaping @MainActor @Sendable (String) -> Void) async -> AgentFinish
    ) async -> AgentFinish {
        defer { homeModel.stoppingThreads.remove(threadID) }
        guard !Task.isCancelled, !homeModel.stoppingThreads.contains(threadID) else {
            homeModel.threadErrors[threadID] = "Stopped before starting. Your request is still here."
            homeModel.pendingQuestions[threadID] = nil
            return .interrupted
        }
        homeModel.threadErrors[threadID] = nil
        var markedFirstText = false
        let finish = await operation { [weak self] partial in
            if !markedFirstText, !partial.isEmpty {
                markedFirstText = true
                PerfMark.mark("home.answer.first_text")
            }
            self?.homeModel.streamingAnswers[threadID] = partial
        }
        if !markedFirstText, finish == .completed {
            // Non-streaming providers answer only at finish — the first
            // visible text lands here.
            PerfMark.mark("home.answer.first_text")
        }
        homeModel.threadErrors[threadID] = finish.failureReason
        if finish == .completed, homeModel.drafts[threadID] == text { homeModel.drafts[threadID] = nil }
        await refreshThreads()
        homeModel.pendingQuestions[threadID] = nil
        if homeModel.threads.first(where: { $0.id == threadID })?.pendingTurn == nil {
            homeModel.streamingAnswers[threadID] = nil
        }
        return finish
    }

    func prepareConversation(target: CuaTargetHint?) {
        guard acceptsInput else { return }
        if homeModel.newConversationDraft.isEmpty || homeModel.newConversationTarget == nil {
            homeModel.newConversationTarget = target
        }
        performWork {
            await self.restoreWelcomeDraft()
            await self.refreshThreads()
        }
    }


    @MainActor
    private func restoreWelcomeDraft() async {
        guard !welcomeDraftLoaded else { return }
        welcomeDraftLoaded = true
        do {
            let saved = try await threadStore?.welcomeDraft() ?? ""
            if !welcomeDraftEdited { homeModel.newConversationDraft = saved }
        } catch {
            homeModel.storageError = "Couldn’t open your unsent draft. Its file has been preserved. \(error.localizedDescription)"
        }
    }

    private func refreshThreads() async {
        homeModel.threads = await threadStore?.list() ?? []
        if let issue = await threadStore?.readIssues().first {
            homeModel.storageError = "Some conversations couldn’t be opened. Their original files are preserved at \(issue.file.path). \(issue.message)"
        }
    }
}
