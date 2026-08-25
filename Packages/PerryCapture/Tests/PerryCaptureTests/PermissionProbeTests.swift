import XCTest
@testable import PerryCapture
import PerryCore

final class PermissionProbeTests: XCTestCase {
    func testProbeReturnsWithoutCrashingAndIsSelfConsistent() {
        let snapshot = PerryPermissionSnapshot.probe()
        XCTAssertEqual(snapshot.accessibility, PerryPermissionProbe.checkAccessibility())
        XCTAssertEqual(snapshot.screenRecording, PerryPermissionProbe.checkScreenRecording())
        XCTAssertEqual(snapshot.microphone, PerryPermissionProbe.checkMicrophone())
    }

    func testStatusUsabilityMapping() {
        XCTAssertTrue(PerryPermissionStatus.granted.isUsable)
        XCTAssertFalse(PerryPermissionStatus.denied.isUsable)
        XCTAssertFalse(PerryPermissionStatus.notDetermined.isUsable)
    }

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
