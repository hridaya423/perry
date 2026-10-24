import Foundation
import XCTest

final class SemanticTypographyTests: XCTestCase {
    func testCustomerFacingAppViewsDoNotUseFixedPointFonts() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "AgentActivityStrip.swift",
            "IntegrationRow.swift",
            "IntentCardWindow.swift",
            "PerryTheme.swift",
            "SettingsView.swift",
        ]
        // Phase 5: History/BackgroundTasks/WhatsNew moved into Home pages.
        let homeFiles = [
            "BackgroundTasksView.swift",
            "HistoryView.swift",
            "HomeView.swift",
            "WhatsNewView.swift"
        ]

        for file in files {
            let source = try String(
                contentsOf: repository.appendingPathComponent("App/\(file)"),
                encoding: .utf8
            )
            XCTAssertFalse(
                source.contains(".font(.system(size:"),
                "\(file) uses fixed point typography instead of a semantic text style"
            )
            XCTAssertFalse(
                file == "PerryTheme.swift" && source.contains("Font.system(size:"),
                "PerryTheme typography tokens must use semantic text styles"
            )
        }
        for file in homeFiles {
            let source = try String(
                contentsOf: repository.appendingPathComponent("App/Home/\(file)"),
                encoding: .utf8
            )
            XCTAssertFalse(
                source.contains(".font(.system(size:"),
                "\(file) uses fixed point typography instead of a semantic text style"
            )
            XCTAssertFalse(
                file == "PerryTheme.swift" && source.contains("Font.system(size:"),
                "PerryTheme typography tokens must use semantic text styles"
            )
        }
    }
}
