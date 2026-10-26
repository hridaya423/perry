import AppKit
import Combine
import XCTest
@testable import Perry

@MainActor
final class PermissionGuideCoordinatorTests: XCTestCase {
    private var opened: [PrivacyPane] = []
    private var surfaceEvents: [String] = []
    private var phases: [PermissionHelperView.Phase] = []
    private var subscription: AnyCancellable?
    private var settingsOpen = true
    private var readings: [GrantMonitor.Reading] = []

    private func makeGuide(
        pane: PrivacyPane = .accessibility,
        bundle: String = "/Applications/Perry.app",
        granted: Bool = false
    ) -> PermissionGuideCoordinator {
        let window = SettingsWindowSnapshot(id: 1, frame: NSRect(x: 300, y: 300, width: 800, height: 500))
        let monitor = GrantMonitor(
            read: { [unowned self] _ in readings.count > 1 ? readings.removeFirst() : readings.first ?? (false, false) },
            idleInterval: .milliseconds(20),
            fastInterval: .milliseconds(10)
        )
        let guide = PermissionGuideCoordinator(
            pane: pane,
            bundleURL: URL(fileURLWithPath: bundle),
            isGranted: { _ in granted },
            open: { [unowned self] in opened.append($0) },
            tracker: SettingsWindowTracker(locate: { [unowned self] in settingsOpen ? window : nil }),
            monitor: monitor,
            visibleFrame: { _ in NSRect(x: 0, y: 0, width: 1440, height: 875) },
            retryAfter: .milliseconds(100),
            grantedHold: .milliseconds(20)
        )
        guide.surface = .init(
            show: { [unowned self] in surfaceEvents.append("show \(Int($0.minX)),\(Int($0.minY))") },
            move: { _ in },
            setHidden: { [unowned self] in surfaceEvents.append($0 ? "hide" : "unhide") },
            close: { [unowned self] in surfaceEvents.append("close") }
        )
        subscription = guide.$phase.removeDuplicates().sink { [unowned self] in phases.append($0) }
        return guide
    }

    func testDraggingInAndSwitchingOnEndsWithGotIt() async {
        readings = [(false, false), (false, false), (true, true)]
        let status = await makeGuide().present()
        XCTAssertEqual(status, .granted)
        XCTAssertEqual(opened, [.accessibility])
        XCTAssertEqual(phases, [.instruction, .granted])
        XCTAssertEqual(surfaceEvents.first, "show 636,114")
        XCTAssertEqual(surfaceEvents.last, "close")
    }

    func testClosingSettingsOffersToOpenItAgainAndReopeningResumes() async throws {
        let guide = makeGuide()
        let run = Task { await guide.present() }
        try await Task.sleep(for: .milliseconds(200))
        settingsOpen = false
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(guide.phase, .settingsClosed)
        guide.reopenSettings()
        settingsOpen = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(guide.phase, .instruction)
        guide.close()
        let status = await run.value
        XCTAssertEqual(status, .notGranted)
        XCTAssertEqual(opened, [.accessibility, .accessibility])
        XCTAssertEqual(phases, [.instruction, .settingsClosed, .instruction])
    }

    func testACancelledPasswordBringsThePanelBackToDragAgain() async throws {
        let guide = makeGuide()
        let run = Task { await guide.present() }
        try await Task.sleep(for: .milliseconds(200))
        guide.dragBegan()
        guide.dragEnded(accepted: true)
        XCTAssertEqual(surfaceEvents.last, "hide")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(guide.phase, .retry)
        XCTAssertEqual(surfaceEvents.last, "unhide")
        guide.close()
        _ = await run.value
    }

    func testARefusedDropKeepsThePanelUp() async throws {
        let guide = makeGuide()
        let run = Task { await guide.present() }
        try await Task.sleep(for: .milliseconds(200))
        guide.dragBegan()
        guide.dragEnded(accepted: false)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(guide.phase, .instruction)
        XCTAssertFalse(surfaceEvents.contains("hide"))
        guide.close()
        _ = await run.value
    }

    func testScreenRecordingSeenOnlyByAFreshProcessAsksForARestart() async throws {
        readings = [(true, false)]
        let guide = makeGuide(pane: .screenRecording)
        let run = Task { await guide.present() }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(guide.phase, .restart)
        guide.close()
        let status = await run.value
        XCTAssertEqual(status, .needsRelaunch)
    }

    func testAnExistingGrantOpensNothing() async {
        let status = await makeGuide(granted: true).present()
        XCTAssertEqual(status, .granted)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(surfaceEvents.isEmpty)
    }

    func testACopyRunningFromADiskImageAsksToMoveFirst() async throws {
        let guide = makeGuide(bundle: "/Volumes/Perry/Perry.app")
        let run = Task { await guide.present() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(guide.phase, .wrongLocation)
        XCTAssertTrue(opened.isEmpty)
        guide.close()
        let status = await run.value
        XCTAssertEqual(status, .notGranted)
        XCTAssertFalse(PermissionGuideCoordinator.canGrant(from: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Perry.app")))
    }
}
