import AppKit
import PerryGuide
import UniformTypeIdentifiers

/// What the status-item menu asks of the app. Every menu action is a call
/// through here; the menu itself owns only items, titles, and file panels.
@MainActor
protocol StatusMenuHost: AnyObject {
    var isUpdateAvailable: Bool { get }
    var isNotchStatusEnabled: Bool { get }
    var isRecordingDemonstration: Bool { get }
    func wake()
    func speak(_ text: String)
    func checkForUpdates()
    func toggleDemonstrationRecording()
    func toggleNotchStatus() -> Bool
    func routines() -> [LearnedRoutine]
    func runRoutine(_ routine: LearnedRoutine)
    func importRoutine(from url: URL)
    func exportRoutine(_ routine: LearnedRoutine, to url: URL)
    func removeRoutine(_ routine: LearnedRoutine)
    func setWorkspaceRoot(_ url: URL)
    func showFullGuideForFrontmostWindow()
    func presentBackgroundComposer()
    func showBackgroundTasks()
    func retryLastTask()
    func runDemo()
    func showHistory()
    func exportDiagnostics()
    func showWhatsNew()
    func showSettings()
    func toggleMemory()
    func currentMemoryConfiguration() async -> MemoryConfiguration
    func requestCompleteErasure()
#if DEBUG
    func runBrainSmokeTest()
    func runFailureDrill(_ drill: FailureDrill)
    func applyDebugStateFixture(_ fixture: DebugStateFixture)
#endif
}

/// Perry's menu-bar item: the indicator glyph and the menu behind it.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private weak var host: (any StatusMenuHost)?
    private var statusItem: NSStatusItem?
    private var memoryMenuItem: NSMenuItem?
    private var backgroundTasksMenuItem: NSMenuItem?
    private var recordDemoMenuItem: NSMenuItem?
    private var workspaceLabelItem: NSMenuItem?
    private var watchLearnMenu: NSMenu?

    init(host: any StatusMenuHost) {
        self.host = host
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = buildMenu()
        item.menu?.delegate = self
        statusItem = item
        refreshIndicator()
    }

    func refreshIndicator() {
        let ambientWakeEnabled = PerryPreferences.wakeWordEnabled
        let symbolName = ambientWakeEnabled ? "waveform.circle.fill" : "scope"
        let description = ambientWakeEnabled ? "Perry is listening for hey Perry" : "Perry"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.title = image == nil ? (ambientWakeEnabled ? "Mic" : "Perry") : ""
        statusItem?.button?.toolTip = description
    }

    func setBackgroundTaskCount(_ total: Int) {
        backgroundTasksMenuItem?.title = "Background Tasks (\(total))"
    }

    func refreshMemoryTitle() async {
        guard let host else { return }
        let current = await host.currentMemoryConfiguration()
        memoryMenuItem?.title = "Memory: \(current.enabled ? "on" : "off")"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === watchLearnMenu {
            refreshWatchLearnMenu(menu)
            return
        }
        refreshWorkspaceLabel()
        Task { await refreshMemoryTitle() }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Wake Perry (⌥⌘P)", action: #selector(wakeAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Ask Perry…", action: #selector(askPromptAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Guide me…", action: #selector(guidePromptAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show full guide", action: #selector(everythingAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Do a task…", action: #selector(doPromptAction), keyEquivalent: "").target = self
        let backgroundItem = NSMenuItem(title: "Run in background…", action: #selector(backgroundPromptAction), keyEquivalent: "")
        backgroundItem.target = self
        menu.addItem(backgroundItem)
        let backgroundTasksItem = NSMenuItem(title: "Background tasks", action: #selector(backgroundTasksAction), keyEquivalent: "")
        backgroundTasksItem.target = self
        backgroundTasksMenuItem = backgroundTasksItem
        menu.addItem(backgroundTasksItem)
        menu.addItem(withTitle: "Retry last task", action: #selector(retryAction), keyEquivalent: "").target = self
        let workspaceLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        workspaceLabel.isEnabled = false
        workspaceLabelItem = workspaceLabel
        menu.addItem(workspaceLabel)
        refreshWorkspaceLabel()
        menu.addItem(withTitle: "Choose workspace folder…", action: #selector(chooseWorkspaceAction), keyEquivalent: "").target = self
        let watchItem = NSMenuItem(title: "Watch & Learn", action: nil, keyEquivalent: "")
        let watchMenu = NSMenu()
        watchMenu.delegate = self
        let recordItem = NSMenuItem(title: "Record a demonstration…", action: #selector(recordDemoAction), keyEquivalent: "")
        recordItem.target = self
        recordDemoMenuItem = recordItem
        watchMenu.addItem(recordItem)
        let importItem = NSMenuItem(title: "Import routine…", action: #selector(importRoutineAction), keyEquivalent: "")
        importItem.target = self
        watchMenu.addItem(importItem)
        watchMenu.addItem(.separator())
        watchItem.submenu = watchMenu
        watchLearnMenu = watchMenu
        menu.addItem(watchItem)
#if DEBUG
        menu.addItem(withTitle: "Run live Perry demo", action: #selector(demoAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Brain smoke test", action: #selector(brainSmokeTestAction), keyEquivalent: "").target = self
        let drills = NSMenuItem(title: "Failure drills", action: nil, keyEquivalent: "")
        let drillMenu = NSMenu()
        for drill in FailureDrill.allCases {
            let item = NSMenuItem(title: drill.title, action: #selector(failureDrillAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = drill.rawValue
            drillMenu.addItem(item)
        }
        drills.submenu = drillMenu
        menu.addItem(drills)
        let fixtures = NSMenuItem(title: "State fixtures", action: nil, keyEquivalent: "")
        let fixtureMenu = NSMenu()
        for fixture in DebugStateFixture.allCases {
            let item = NSMenuItem(title: fixture.title, action: #selector(stateFixtureAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = fixture.rawValue
            fixtureMenu.addItem(item)
        }
        fixtures.submenu = fixtureMenu
        menu.addItem(fixtures)
        menu.addItem(withTitle: "Invocation prototypes", action: #selector(prototypeAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Cursor prototypes", action: #selector(cursorPrototypeAction), keyEquivalent: "").target = self
#endif
        menu.addItem(.separator())
        menu.addItem(withTitle: "History", action: #selector(historyAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Export diagnostics…", action: #selector(diagnosticsAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "What’s New", action: #selector(whatsNewAction), keyEquivalent: "").target = self
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesAction), keyEquivalent: "")
        updateItem.target = self
        updateItem.isEnabled = host?.isUpdateAvailable ?? false
        menu.addItem(updateItem)
        menu.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: ",").target = self

        let memoryItem = NSMenuItem(title: "Memory:…", action: #selector(toggleMemoryAction), keyEquivalent: "")
        memoryItem.target = self
        memoryMenuItem = memoryItem
        menu.addItem(memoryItem)

        let notchItem = NSMenuItem(title: "Notch status", action: #selector(toggleNotchStatusAction(_:)), keyEquivalent: "")
        notchItem.target = self
        notchItem.state = host?.isNotchStatusEnabled == true ? .on : .off
        menu.addItem(notchItem)

        let wipeItem = NSMenuItem(title: "Erase all Perry data…", action: #selector(wipeDataAction), keyEquivalent: "")
        wipeItem.target = self
        menu.addItem(wipeItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Perry", action: #selector(quitAction), keyEquivalent: "q").target = self
        return menu
    }

    private func refreshWatchLearnMenu(_ menu: NSMenu) {
        recordDemoMenuItem?.title = host?.isRecordingDemonstration == true ? "Stop recording & review" : "Record a demonstration…"
        while menu.items.count > 3 { menu.removeItem(at: menu.items.count - 1) }
        let routines = host?.routines() ?? []
        guard !routines.isEmpty else {
            let empty = NSMenuItem(title: "No routines yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for routine in routines {
            let item = NSMenuItem(title: routine.name, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let run = NSMenuItem(title: "Run", action: #selector(runRoutineAction(_:)), keyEquivalent: "")
            run.target = self
            run.representedObject = routine.id.uuidString
            let export = NSMenuItem(title: "Export…", action: #selector(exportRoutineAction(_:)), keyEquivalent: "")
            export.target = self
            export.representedObject = routine.id.uuidString
            let delete = NSMenuItem(title: "Delete", action: #selector(deleteRoutineAction(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = routine.id.uuidString
            submenu.addItem(run)
            submenu.addItem(export)
            submenu.addItem(delete)
            item.submenu = submenu
            menu.addItem(item)
        }
    }

    private func refreshWorkspaceLabel() {
        workspaceLabelItem?.title = "Workspace: \((WorkspaceScope.root.path() as NSString).abbreviatingWithTildeInPath)"
    }

    private func routineFrom(_ sender: NSMenuItem) -> LearnedRoutine? {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw) else { return nil }
        return host?.routines().first(where: { $0.id == id })
    }

    // MARK: Actions

    @objc private func wakeAction() { host?.wake() }
    @objc private func checkForUpdatesAction() { host?.checkForUpdates() }
    @objc private func quitAction() { NSApp.terminate(nil) }

    @objc private func askPromptAction() {
        host?.wake()
        host?.speak("What are you curious about?")
    }

    @objc private func guidePromptAction() {
        host?.wake()
        host?.speak("What should I teach you?")
    }

    @objc private func doPromptAction() {
        host?.wake()
        host?.speak("What are we taking off your hands?")
    }

    @objc private func everythingAction() { host?.showFullGuideForFrontmostWindow() }
    @objc private func backgroundPromptAction() { host?.presentBackgroundComposer() }
    @objc private func backgroundTasksAction() { host?.showBackgroundTasks() }
    @objc private func retryAction() { host?.retryLastTask() }
    @objc private func demoAction() { host?.runDemo() }
    @objc private func recordDemoAction() { host?.toggleDemonstrationRecording() }

    @objc private func toggleNotchStatusAction(_ sender: NSMenuItem) {
        guard let host else { return }
        sender.state = host.toggleNotchStatus() ? .on : .off
    }

    @objc private func chooseWorkspaceAction() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as workspace"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        host?.setWorkspaceRoot(url)
        refreshWorkspaceLabel()
    }

    @objc private func runRoutineAction(_ sender: NSMenuItem) {
        guard let routine = routineFrom(sender) else { return }
        host?.runRoutine(routine)
    }

    @objc private func importRoutineAction() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "md") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        host?.importRoutine(from: url)
    }

    @objc private func exportRoutineAction(_ sender: NSMenuItem) {
        guard let routine = routineFrom(sender) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(routine.name).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        host?.exportRoutine(routine, to: url)
    }

    @objc private func deleteRoutineAction(_ sender: NSMenuItem) {
        guard let routine = routineFrom(sender) else { return }
        host?.removeRoutine(routine)
    }

    @objc private func historyAction() { host?.showHistory() }
    @objc private func diagnosticsAction() { host?.exportDiagnostics() }
    @objc private func whatsNewAction() { host?.showWhatsNew() }
    @objc private func settingsAction() { host?.showSettings() }
    @objc private func toggleMemoryAction() { host?.toggleMemory() }
    @objc private func wipeDataAction() { host?.requestCompleteErasure() }

#if DEBUG
    @objc private func brainSmokeTestAction() { host?.runBrainSmokeTest() }

    @objc private func failureDrillAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let drill = FailureDrill(rawValue: rawValue) else { return }
        host?.runFailureDrill(drill)
    }

    @objc private func stateFixtureAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let fixture = DebugStateFixture(rawValue: rawValue) else { return }
        host?.applyDebugStateFixture(fixture)
    }

    @objc private func prototypeAction() { DebugPrototypeWindow.show() }
    @objc private func cursorPrototypeAction() { DebugCursorGalleryWindow.show() }
#endif
}

extension AppController: StatusMenuHost {
    var isUpdateAvailable: Bool { updateNoticeController.availability == .available }
    var isNotchStatusEnabled: Bool { notchStatus.isEnabled }
    var isRecordingDemonstration: Bool { routineLibrary.isRecording }

    func speak(_ text: String) { voice.speak(text) }
    func checkForUpdates() { updateNoticeController.checkForUpdates() }
    func toggleDemonstrationRecording() { routineLibrary.toggleRecording() }

    func toggleNotchStatus() -> Bool {
        let enabled = !notchStatus.isEnabled
        notchStatus.setEnabled(enabled)
        if enabled {
            notchStatus.update(
                isRecording: routineLibrary.isRecording,
                backgroundCount: lastBackgroundCount,
                awaitingApproval: lastAwaitingApprovalCount
            )
        }
        return enabled
    }

    func routines() -> [LearnedRoutine] { routineLibrary.routines() }
    func runRoutine(_ routine: LearnedRoutine) { routineLibrary.run(routine) }
    func importRoutine(from url: URL) { routineLibrary.importRoutine(from: url) }
    func exportRoutine(_ routine: LearnedRoutine, to url: URL) { routineLibrary.exportRoutine(routine, to: url) }
    func removeRoutine(_ routine: LearnedRoutine) { routineLibrary.remove(routine) }

    func setWorkspaceRoot(_ url: URL) {
        WorkspaceScope.setRoot(url)
        sessionStatus = "Workspace folder set to \(url.lastPathComponent) — new file tasks stay inside it."
    }

    func showFullGuideForFrontmostWindow() {
        let target = probe.currentTargetHint()
        Task { await showEverything(goal: "walk through the frontmost window", targetHint: target) }
    }

    /// "Run in background" lives on the composer's send action — the menu
    /// item opens that composer in Do mode with the toggle already on.
    func presentBackgroundComposer() {
        pendingPromptRunInBackground = true
        presentPrompt(prefill: "", asTask: true)
    }

    func retryLastTask() { foreground.retry() }
    func runDemo() { demoFlow.director.run() }
    func showSettings() { homeController.openHome(selection: .settings) }

    func toggleMemory() {
        schedulePersistence { [weak self, memoryStore] in
            let current = await memoryStore.currentConfiguration()
            await memoryStore.setConfiguration(
                MemoryConfiguration(enabled: !current.enabled, categoryToggles: current.categoryToggles)
            )
            await self?.statusMenu.refreshMemoryTitle()
        }
    }

#if DEBUG
    func runBrainSmokeTest() {
        brain.smokeTest { [weak self] status in self?.sessionStatus = status }
    }
#endif
}

extension AppController {
    /// onboarding has finished — never a required step.
    func startDemonstrationRecording() {
        guard !routineLibrary.isRecording else { return }
        routineLibrary.toggleRecording()
    }

    /// Mirrors notch-pill status into the Home peek (Phase 5): the pill says
    /// *that* something is running; the peek says *what* — a live step line
    /// per active agent.
    func updateHomePeek(isRecording: Bool) {
        var lines: [String] = []
        for record in backgroundTasks.records where !record.isTerminal {
            if case .executable(let plan) = record.plan, !plan.actions.isEmpty {
                let step = min(record.checkpoint.nextStepIndex + 1, plan.actions.count)
                lines.append("\(record.goal) — step \(step) of \(plan.actions.count)")
            } else {
                lines.append(record.goal)
            }
        }
        if lines.isEmpty && lastBackgroundCount > 0 {
            lines.append(lastBackgroundCount == 1 ? "1 background task" : "\(lastBackgroundCount) background tasks")
        }
        homeController.updateStatus(
            isRecording: isRecording,
            agentLines: lines,
            unreadCount: lastAwaitingApprovalCount
        )
    }
}
