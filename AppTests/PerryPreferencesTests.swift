import XCTest
@testable import Perry

final class PerryPreferencesTests: XCTestCase {
    func testGesturePreferencesKeepRawValuesAndFallBackOnUnknownOnes() {
        let key = PerryPreferences.$typeGesture.key
        restoreDefaultsAfterTest([key], clearing: false)

        PerryPreferences.typeGesture = .doubleTap([.option])
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "doubleTap:option")
        XCTAssertEqual(PerryPreferences.typeGesture, .doubleTap([.option]))

        UserDefaults.standard.set("gone", forKey: key)
        XCTAssertEqual(PerryPreferences.typeGesture, .doubleTap([.control]))
    }
}
