import AppKit
import XCTest
@testable import Perry

@MainActor
final class StatusMenuTests: XCTestCase {
    private func makeController() throws -> (AppController, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (AppController.testing(directory: directory), directory)
    }

    private func visibleTitles(_ menu: NSMenu) -> [String] {
        menu.items
            .filter { !$0.isHidden && !$0.isSeparatorItem && $0.title != "Developer" }
            .map(\.title)
    }

    func testReleaseMenuTitlesInOrderWithNothingConditional() throws {
        let (controller, directory) = try makeController()
        defer {
            controller.subsystems.notchPresence.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        let menu = controller.buildMenu()
        menu.delegate?.menuNeedsUpdate?(menu)
        let titles = visibleTitles(menu)
        XCTAssertEqual(titles, [
            "Talk to Perry",
            "Ask Perry…",
            "Record a routine…",
            "Settings…",
            "Quit Perry"
        ])
        XCTAssertFalse(titles.contains { $0.contains("…:") || $0.contains(":") })
    }

    func testBackgroundTasksItemAppearsOnlyWhenCountIsPositive() throws {
        let (controller, directory) = try makeController()
        defer {
            controller.subsystems.notchPresence.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        let menu = controller.buildMenu()
        controller.statusMenu.setBackgroundTaskCount(2)
        XCTAssertEqual(visibleTitles(menu)[2], "Tasks (2)")
        controller.statusMenu.setBackgroundTaskCount(0)
        XCTAssertFalse(visibleTitles(menu).contains { $0.hasPrefix("Tasks") })
    }

    func testSettingsAndQuitKeepTheirShortcuts() throws {
        let (controller, directory) = try makeController()
        defer {
            controller.subsystems.notchPresence.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        let menu = controller.buildMenu()
        XCTAssertEqual(menu.items.first { $0.title == "Settings…" }?.keyEquivalent, ",")
        XCTAssertEqual(menu.items.first { $0.title == "Quit Perry" }?.keyEquivalent, "q")
    }
}
