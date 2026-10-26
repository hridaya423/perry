import XCTest
@testable import Perry

final class PerryPreferencesTests: XCTestCase {
    func testGesturePreferencesKeepRawValuesAndFallBackOnUnknownOnes() {
        let key = PerryPreferences.$typeGesture.key
        let saved = UserDefaults.standard.object(forKey: key)
        addTeardownBlock {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }

        PerryPreferences.typeGesture = .doubleTap([.option])
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "doubleTap:option")
        XCTAssertEqual(PerryPreferences.typeGesture, .doubleTap([.option]))

        UserDefaults.standard.set("gone", forKey: key)
        XCTAssertEqual(PerryPreferences.typeGesture, .doubleTap([.control]))
    }
}
