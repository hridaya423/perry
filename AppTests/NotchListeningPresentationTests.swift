import AppKit
import XCTest
import PerryBrain
import PerryCore
import PerryGuide
import PerryOverlay
@testable import Perry

@MainActor
final class NotchListeningPresentationTests: XCTestCase {
    func testListeningKeepsTheNotchOpenUntilTheTurnEnds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = AppController.testing(directory: directory)
        let presentation = NotchPresentation.shared
        for entry in presentation.entries { presentation.remove(entry.id) }
        defer {
            for entry in presentation.entries { presentation.remove(entry.id) }
            controller.collapseNotch()
            try? FileManager.default.removeItem(at: directory)
        }

        controller.presentConversationVoice(.listening)
        XCTAssertEqual(presentation.current?.id, AppController.voiceEntryID)
        XCTAssertEqual(presentation.current?.priority, .voice)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(controller.sessionPanel.isVisible)

        controller.presentConversationVoice(.thinking)
        controller.presentConversationVoice(.speaking)
        XCTAssertTrue(presentation.contains(AppController.voiceEntryID))
        XCTAssertTrue(controller.sessionPanel.isVisible)

        controller.presentConversationVoice(.idle)
        XCTAssertFalse(presentation.contains(AppController.voiceEntryID))
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(controller.sessionPanel.isVisible)
    }
}
