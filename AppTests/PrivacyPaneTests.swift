import XCTest
@testable import Perry

final class PrivacyPaneTests: XCTestCase {
    func testEachPaneOpensItsListInPrivacyAndSecurity() {
        XCTAssertEqual(
            PrivacyPane.accessibility.url.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        )
        XCTAssertEqual(PrivacyPane.screenRecording.url.query, "Privacy_ScreenCapture")
        XCTAssertEqual(PrivacyPane.inputMonitoring.url.query, "Privacy_ListenEvent")
        XCTAssertEqual(PrivacyPane.microphone.url.query, "Privacy_Microphone")
        XCTAssertEqual(
            PrivacyPane.screenRecording.legacyURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    func testMacOS27CallsAccessibilityDeviceControlAndDataAccess() {
        XCTAssertEqual(PrivacyPane.accessibility.displayName(osMajor: 26), "Accessibility")
        XCTAssertEqual(PrivacyPane.accessibility.displayName(osMajor: 27), "Device Control and Data Access")
        XCTAssertEqual(PrivacyPane.screenRecording.displayName(osMajor: 27), "Screen & System Audio Recording")
        XCTAssertEqual(PrivacyPane.inputMonitoring.displayName(osMajor: 27), "Input Monitoring")
    }

    func testOnlyListsThatTakeADraggedAppSupportDragAndOnlyCapturePanesNeedARelaunch() {
        XCTAssertEqual(PrivacyPane.allCases.filter(\.supportsDrag), [.accessibility, .screenRecording, .inputMonitoring])
        XCTAssertEqual(PrivacyPane.allCases.filter(\.relaunchLikelyAfterGrant), [.screenRecording, .inputMonitoring])
    }
}
