import XCTest
@testable import Perry

final class PerryPreferencesTests: XCTestCase {
    func testEnumPreferencesKeepRawValuesAndFallBackOnUnknownOnes() {
        let key = PerryPreferences.$pttShortcut.key
        let saved = UserDefaults.standard.object(forKey: key)
        addTeardownBlock {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }

        PerryPreferences.pttShortcut = .optionCommandSpace
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), PushToTalkShortcut.optionCommandSpace.rawValue)
        XCTAssertEqual(PerryPreferences.pttShortcut, .optionCommandSpace)

        UserDefaults.standard.set("gone", forKey: key)
        XCTAssertEqual(PerryPreferences.pttShortcut, .functionHold)
    }
}
