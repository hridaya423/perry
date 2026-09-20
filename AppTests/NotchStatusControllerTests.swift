import XCTest
@testable import Perry

final class NotchStatusControllerTests: XCTestCase {
    func testPillAppearsOnlyWithContentOnANotchedScreen() {
        XCTAssertFalse(NotchStatusController.shouldPresent(isEnabled: true, isRecording: false, backgroundCount: 0, hasNotchedScreen: true))
        XCTAssertTrue(NotchStatusController.shouldPresent(isEnabled: true, isRecording: true, backgroundCount: 0, hasNotchedScreen: true))
        XCTAssertTrue(NotchStatusController.shouldPresent(isEnabled: true, isRecording: false, backgroundCount: 2, hasNotchedScreen: true))
        XCTAssertFalse(NotchStatusController.shouldPresent(isEnabled: true, isRecording: true, backgroundCount: 3, hasNotchedScreen: false))
        XCTAssertFalse(NotchStatusController.shouldPresent(isEnabled: false, isRecording: true, backgroundCount: 3, hasNotchedScreen: true))
    }
}
