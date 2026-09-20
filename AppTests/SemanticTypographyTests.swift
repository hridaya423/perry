import Foundation
import XCTest

final class SemanticTypographyTests: XCTestCase {
    func testCustomerFacingAppViewsDoNotUseFixedPointFonts() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "AgentActivityStrip.swift",
            "BackgroundTasksWindow.swift",
            "HistoryWindow.swift",
            "IntegrationRow.swift",
            "IntentCardWindow.swift",
            "OnboardingWindow.swift",
            "PerryTheme.swift",
            "SettingsView.swift",
            "WhatsNewWindow.swift"
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
    }
}
