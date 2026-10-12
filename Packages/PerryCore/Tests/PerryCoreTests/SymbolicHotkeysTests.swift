import XCTest
@testable import PerryCore

final class SymbolicHotkeysTests: XCTestCase {
    private var plist: [String: Any] {
        [
            "AppleSymbolicHotKeys": [
                // Spotlight "Show Finder search window" — ⌥⌘Space.
                "61": [
                    "enabled": 1,
                    "value": [
                        "type": "standard",
                        "parameters": [32, 49, 1572864],
                    ],
                ],
                // Disabled entries never conflict.
                "64": [
                    "enabled": 0,
                    "value": [
                        "type": "standard",
                        "parameters": [32, 49, 1572864],
                    ],
                ],
                // Malformed rows are skipped.
                "200": ["enabled": 1],
            ],
        ]
    }

    func testEntriesParsesEnabledHotkeysOnly() {
        let entries = SymbolicHotkeys.entries(from: plist)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first, SymbolicHotkey(keyCode: 49, modifiers: 1572864))
    }

    func testConflictsMatchesKeyCodeAndModifiers() {
        let entries = SymbolicHotkeys.entries(from: plist)
        XCTAssertTrue(SymbolicHotkeys.conflicts(keyCode: 49, modifiers: 1572864, in: entries))
        XCTAssertFalse(SymbolicHotkeys.conflicts(keyCode: 49, modifiers: 262144, in: entries))
        XCTAssertFalse(SymbolicHotkeys.conflicts(keyCode: 48, modifiers: 1572864, in: entries))
    }

    func testEntriesFromMissingOrEmptyPlist() {
        XCTAssertTrue(SymbolicHotkeys.entries(from: [:]).isEmpty)
        XCTAssertTrue(SymbolicHotkeys.entries(from: ["AppleSymbolicHotKeys": "nope"]).isEmpty)
    }
}
