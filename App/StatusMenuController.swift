import AppKit

/// Perry's command menu, opened from the notch's More button. Perry has no
/// menu-bar item; the notch owns every first-party entry point.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private weak var host: AppController?
    private var backgroundTasksMenuItem: NSMenuItem?
    private var recordMenuItem: NSMenuItem?
    private var updateMenuItem: NSMenuItem?
    private var backgroundTaskCount = 0

    init(host: AppController) {
        self.host = host
    }

    func makeMenu() -> NSMenu {
        let menu = buildMenu()
        menu.delegate = self
        return menu
    }

    func setBackgroundTaskCount(_ total: Int) {
        backgroundTaskCount = total
        backgroundTasksMenuItem?.title = "Tasks (\(total))"
        backgroundTasksMenuItem?.isHidden = total == 0
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        recordMenuItem?.title = host?.isRecordingDemonstration == true ? "Stop recording" : "Record a routine…"
        updateMenuItem?.isHidden = host?.isUpdateAvailable != true
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Talk to Perry", action: #selector(wakeAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Ask Perry…", action: #selector(askPromptAction), keyEquivalent: "").target = self
        let backgroundTasksItem = NSMenuItem(title: "Tasks (\(backgroundTaskCount))", action: #selector(backgroundTasksAction), keyEquivalent: "")
        backgroundTasksItem.target = self
        backgroundTasksItem.isHidden = backgroundTaskCount == 0
        backgroundTasksMenuItem = backgroundTasksItem
        menu.addItem(backgroundTasksItem)
        let recordItem = NSMenuItem(title: "Record a routine…", action: #selector(recordAction), keyEquivalent: "")
        recordItem.target = self
        recordMenuItem = recordItem
        menu.addItem(recordItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: ",").target = self
        menu.addItem(.separator())
#if DEBUG
        let developer = NSMenuItem(title: "Developer", action: nil, keyEquivalent: "")
        let developerMenu = NSMenu()
        developerMenu.addItem(withTitle: "Brain smoke test", action: #selector(brainSmokeTestAction), keyEquivalent: "").target = self
        let drills = NSMenuItem(title: "Failure drills", action: nil, keyEquivalent: "")
        let drillMenu = NSMenu()
        for drill in FailureDrill.allCases {
            let item = NSMenuItem(title: drill.title, action: #selector(failureDrillAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = drill.rawValue
            drillMenu.addItem(item)
        }
        drills.submenu = drillMenu
        developerMenu.addItem(drills)
        let fixtures = NSMenuItem(title: "State fixtures", action: nil, keyEquivalent: "")
        let fixtureMenu = NSMenu()
        for fixture in DebugStateFixture.allCases {
            let item = NSMenuItem(title: fixture.title, action: #selector(stateFixtureAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = fixture.rawValue
            fixtureMenu.addItem(item)
        }
        fixtures.submenu = fixtureMenu
        developerMenu.addItem(fixtures)
        developer.submenu = developerMenu
        menu.addItem(developer)
#endif
        let updateItem = NSMenuItem(title: "Update Perry", action: #selector(checkForUpdatesAction), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = host?.isUpdateAvailable != true
        updateMenuItem = updateItem
        menu.addItem(updateItem)
        menu.addItem(withTitle: "Quit Perry", action: #selector(quitAction), keyEquivalent: "q").target = self
        return menu
    }

    // MARK: Actions

    @objc private func wakeAction() { host?.wake() }
    @objc private func checkForUpdatesAction() { host?.checkForUpdates() }
    @objc private func quitAction() { NSApp.terminate(nil) }
    @objc private func askPromptAction() { host?.presentPrompt(prefill: "") }
    @objc private func backgroundTasksAction() { host?.showBackgroundTasks() }
    @objc private func recordAction() { host?.toggleDemonstrationRecording() }
    @objc private func settingsAction() { host?.showSettings() }

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

#endif
}

extension AppController {
    var isUpdateAvailable: Bool { updateNoticeController.availability == .available }
    var isRecordingDemonstration: Bool { routineLibrary.isRecording }

    func checkForUpdates() { updateNoticeController.checkForUpdates() }
    func toggleDemonstrationRecording() { routineLibrary.toggleRecording() }
    func showSettings() { homeController.openHome(selection: .settings) }

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
}
