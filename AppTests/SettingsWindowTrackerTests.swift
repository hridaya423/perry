import AppKit
import XCTest
@testable import Perry

@MainActor
final class SettingsWindowTrackerTests: XCTestCase {
    func testTheHelperDocksInsideTheListColumnAtTheBottom() {
        let laptop = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let external = NSRect(x: 1440, y: 0, width: 1920, height: 1055)
        let cases: [(String, NSRect, NSRect, NSRect)] = [
            ("standard window", NSRect(x: 300, y: 300, width: 800, height: 500), laptop, NSRect(x: 564, y: 316, width: 520, height: 150)),
            ("narrow window keeps the sidebar floor", NSRect(x: 300, y: 300, width: 600, height: 500), laptop, NSRect(x: 531, y: 316, width: 353, height: 150)),
            ("wide window caps the sidebar", NSRect(x: 0, y: 100, width: 1400, height: 700), laptop, NSRect(x: 376, y: 116, width: 1008, height: 150)),
            ("bottom below the screen", NSRect(x: 300, y: -200, width: 800, height: 600), laptop, NSRect(x: 564, y: 16, width: 520, height: 150)),
            ("right edge past the screen", NSRect(x: 1000, y: 300, width: 800, height: 500), laptop, NSRect(x: 1264, y: 316, width: 280, height: 150)),
            ("second display", NSRect(x: 1700, y: 400, width: 800, height: 500), external, NSRect(x: 1964, y: 416, width: 520, height: 150)),
        ]
        for (name, settings, visible, frame) in cases {
            XCTAssertEqual(SettingsWindowTracker.dockFrame(settings: settings, visible: visible, cardHeight: 150), frame, name)
        }
    }

    func testWindowServerFramesFlipIntoAppKitCoordinates() {
        let frame = SettingsWindowTracker.appKitFrame(fromCG: CGRect(x: 100, y: 50, width: 800, height: 500), primaryHeight: 900)
        XCTAssertEqual(frame, CGRect(x: 100, y: 350, width: 800, height: 500))
    }

    func testMovesReportOnceAndTheWindowIsGoneOnlyAfterHalfASecondOfMisses() {
        var answers: [SettingsWindowSnapshot?] = [
            SettingsWindowSnapshot(id: 7, frame: CGRect(x: 0, y: 0, width: 800, height: 500)),
            SettingsWindowSnapshot(id: 7, frame: CGRect(x: 0, y: 0, width: 800, height: 500)),
            SettingsWindowSnapshot(id: 7, frame: CGRect(x: 40, y: 0, width: 800, height: 500)),
            nil, nil, nil, nil,
        ]
        let tracker = SettingsWindowTracker(locate: { answers.removeFirst() })
        var changes: [CGFloat] = []
        var gone = 0
        tracker.onChange = { changes.append($0.frame.minX) }
        tracker.onGone = { gone += 1 }
        for now in [0.0, 0.016, 0.032, 0.1, 0.5, 0.61, 0.7] {
            tracker.tick(now: now)
        }
        XCTAssertEqual(changes, [0, 40])
        XCTAssertEqual(gone, 1)
    }
}
