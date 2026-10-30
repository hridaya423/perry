import AppKit

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private final class ActionItem: NSMenuItem {
        private let handler: () -> Void

        init(_ title: String, key: String = "", handler: @escaping () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(fire), keyEquivalent: key)
            target = self
        }

        required init(coder: NSCoder) { fatalError() }

        @objc private func fire() { handler() }
    }

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
        recordMenuItem?.title = host?.subsystems.routineLibrary.isRecording == true ? "Stop recording" : "Record a routine…"
        updateMenuItem?.isHidden = host?.updateNoticeController.availability != .available
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionItem("Talk to Perry") { [weak host] in host?.wake() })
        menu.addItem(ActionItem("Ask Perry…") { [weak host] in host?.presentPrompt(prefill: "") })
        let backgroundTasksItem = ActionItem("Tasks (\(backgroundTaskCount))") { [weak host] in host?.showBackgroundTasks() }
        backgroundTasksItem.isHidden = backgroundTaskCount == 0
        backgroundTasksMenuItem = backgroundTasksItem
        menu.addItem(backgroundTasksItem)
        let recordItem = ActionItem("Record a routine…") { [weak host] in host?.subsystems.routineLibrary.toggleRecording() }
        recordMenuItem = recordItem
        menu.addItem(recordItem)
        menu.addItem(.separator())
        menu.addItem(ActionItem("Settings…", key: ",") { [weak host] in host?.showSettings() })
        menu.addItem(.separator())
#if DEBUG
        menu.addItem(developerItem())
#endif
        let updateItem = ActionItem("Update Perry") { [weak host] in host?.updateNoticeController.checkForUpdates() }
        updateItem.isHidden = host?.updateNoticeController.availability != .available
        updateMenuItem = updateItem
        menu.addItem(updateItem)
        menu.addItem(ActionItem("Quit Perry", key: "q") { NSApp.terminate(nil) })
        return menu
    }

#if DEBUG
    private func developerItem() -> NSMenuItem {
        let developer = NSMenuItem(title: "Developer", action: nil, keyEquivalent: "")
        let developerMenu = NSMenu()
        developerMenu.addItem(ActionItem("Brain smoke test") { [weak host] in
            host?.subsystems.brain.smokeTest { status in host?.sessionStatus = status }
        })
        let drills = NSMenuItem(title: "Failure drills", action: nil, keyEquivalent: "")
        let drillMenu = NSMenu()
        for drill in FailureDrill.allCases {
            drillMenu.addItem(ActionItem(drill.title) { [weak host] in host?.runFailureDrill(drill) })
        }
        drills.submenu = drillMenu
        developerMenu.addItem(drills)
        let fixtures = NSMenuItem(title: "State fixtures", action: nil, keyEquivalent: "")
        let fixtureMenu = NSMenu()
        for fixture in DebugStateFixture.allCases {
            fixtureMenu.addItem(ActionItem(fixture.title) { [weak host] in host?.applyDebugStateFixture(fixture) })
        }
        fixtures.submenu = fixtureMenu
        developerMenu.addItem(fixtures)
        developer.submenu = developerMenu
        return developer
    }
#endif
}

extension AppController {
    func showSettings() { subsystems.homeController.openHome(selection: .settings) }

    func startDemonstrationRecording() {
        guard !subsystems.routineLibrary.isRecording else { return }
        subsystems.routineLibrary.toggleRecording()
    }
}
