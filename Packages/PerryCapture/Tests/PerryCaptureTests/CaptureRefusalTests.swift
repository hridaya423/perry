import XCTest
@testable import PerryCapture
import PerryCore

final class CaptureRefusalTests: XCTestCase {
    func testRefusalWhenPasswordManagerWindowOnScreen() {
        let windows = [
            PerryScreenCaptureUtility.PerryCapturedWindow(bundleID: "com.apple.Safari", title: "Documentation"),
            PerryScreenCaptureUtility.PerryCapturedWindow(bundleID: "com.agilebits.onepassword-osx", title: "1Password"),
        ]
        XCTAssertEqual(
            PerryScreenCaptureUtility.blockedWindowRefusal(for: windows),
            "capture refused: a blocked window is on screen"
        )
    }

    func testRefusalWhenCheckoutPageTitleOnScreen() {
        let windows = [
            PerryScreenCaptureUtility.PerryCapturedWindow(bundleID: "com.google.Chrome", title: "Store — Checkout"),
        ]
        XCTAssertNotNil(PerryScreenCaptureUtility.blockedWindowRefusal(for: windows))
    }

    func testNoRefusalForOrdinaryWindows() {
        let windows = [
            PerryScreenCaptureUtility.PerryCapturedWindow(bundleID: "com.apple.finder", title: "Desktop"),
            PerryScreenCaptureUtility.PerryCapturedWindow(bundleID: "dev.perry", title: "Perry"),
            PerryScreenCaptureUtility.PerryCapturedWindow(bundleID: "", title: ""),
        ]
        XCTAssertNil(PerryScreenCaptureUtility.blockedWindowRefusal(for: windows))
    }
}
