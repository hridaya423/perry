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

    func testNotchViewsUsePaletteTokensInsteadOfBlack() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App")
        let directories = ["Home", "Notch"].map { app.appendingPathComponent($0) }
        let files = try directories.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension == "swift" } + [app.appendingPathComponent("CompactConversationView.swift")]
        XCTAssertGreaterThan(files.count, 3)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertNil(source.range(of: #"\b(NS)?Color\.black\b"#, options: .regularExpression),
                         "\(file.lastPathComponent) paints black directly; use PerryTheme.Colors.crown or a palette token")
        }
    }
}
