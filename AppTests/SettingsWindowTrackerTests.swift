import AppKit
import XCTest
@testable import Perry

@MainActor
final class SettingsWindowTrackerTests: XCTestCase {
    func testTheHelperDocksBelowThenInsideThenBesideThenClamps() {
        let laptop = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let external = NSRect(x: 1440, y: 0, width: 1920, height: 1055)
        let card = CGSize(width: 360, height: 140)
        let cases: [(String, NSRect, NSRect, NSRect, SettingsDock)] = [
            ("room below", NSRect(x: 300, y: 300, width: 800, height: 500), laptop, NSRect(x: 636, y: 150, width: 360, height: 140), .below),
            ("tall window at the bottom", NSRect(x: 300, y: 50, width: 800, height: 600), laptop, NSRect(x: 636, y: 70, width: 360, height: 140), .inside),
            ("short window, room right", NSRect(x: 100, y: 40, width: 700, height: 400), laptop, NSRect(x: 810, y: 40, width: 360, height: 140), .right),
            ("short window, room left", NSRect(x: 700, y: 40, width: 700, height: 400), laptop, NSRect(x: 330, y: 40, width: 360, height: 140), .left),
            ("no room anywhere", NSRect(x: 0, y: 0, width: 1440, height: 400), laptop, NSRect(x: 656, y: 10, width: 360, height: 140), .clamped),
            ("second display", NSRect(x: 1700, y: 400, width: 800, height: 500), external, NSRect(x: 2036, y: 250, width: 360, height: 140), .below),
            ("list centre past the edge", NSRect(x: 1000, y: 400, width: 800, height: 500), laptop, NSRect(x: 1080, y: 250, width: 360, height: 140), .below),
        ]
        for (name, settings, visible, frame, dock) in cases {
            let result = SettingsWindowTracker.dockFrame(settings: settings, visible: visible, cardSize: card)
            XCTAssertEqual(result.0, frame, name)
            XCTAssertEqual(result.1, dock, name)
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
