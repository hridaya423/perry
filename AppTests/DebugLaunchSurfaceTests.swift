import XCTest
@testable import Perry

#if DEBUG
final class DebugLaunchSurfaceTests: XCTestCase {
    func testSettingsSurfaceRequiresAnExactArgumentPair() {
        XCTAssertEqual(
            PerryDebugLaunchSurface(arguments: ["Perry", "--perry-debug-surface", "settings"]),
            .settings
        )
        XCTAssertEqual(
            PerryDebugLaunchSurface(arguments: ["Perry", "--perry-debug-surface", "onboarding"]),
            .onboarding
        )
        XCTAssertEqual(
            PerryDebugLaunchSurface(arguments: ["Perry", "--perry-debug-surface", "session"]),
            .session
        )
        XCTAssertEqual(
            PerryDebugLaunchSurface(arguments: ["Perry", "--perry-debug-surface", "guide-controls"]),
            .guideControls
        )
        XCTAssertEqual(
            PerryDebugLaunchSurface(arguments: ["Perry", "--perry-debug-surface", "history"]),
            .history
        )
        XCTAssertNil(PerryDebugLaunchSurface(arguments: ["Perry", "--perry-debug-surface"]))
        XCTAssertNil(PerryDebugLaunchSurface(arguments: ["Perry", "--perry-debug-surface", "unknown"]))
    }

    func testTextScaleDefaultsToSystemForMissingOrInvalidArguments() {
        XCTAssertEqual(PerryDebugTextScale(arguments: ["Perry"]), .system)
        XCTAssertEqual(
            PerryDebugTextScale(arguments: ["Perry", "--perry-debug-text-scale"]),
            .system
        )
        XCTAssertEqual(
            PerryDebugTextScale(arguments: ["Perry", "--perry-debug-text-scale", "unknown"]),
            .system
        )
    }

    func testAccessibilityTextScaleRequiresAnExactArgumentPair() {
        XCTAssertEqual(
            PerryDebugTextScale(arguments: ["Perry", "--perry-debug-text-scale", "accessibility3"]),
            .accessibility3
        )
    }
}
#endif
