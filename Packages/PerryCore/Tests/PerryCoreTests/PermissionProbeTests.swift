import XCTest
@testable import PerryCore

final class PermissionProbeTests: XCTestCase {
    func testAllGrantedRequiresEveryPermission() {
        let partial = PerryPermissionSnapshot(
            accessibility: true,
            screenRecording: .granted,
            microphone: .notDetermined
        )
        XCTAssertFalse(partial.allGranted)

        let full = PerryPermissionSnapshot(
            accessibility: true,
            screenRecording: .granted,
            microphone: .granted
        )
        XCTAssertTrue(full.allGranted)
    }
}
