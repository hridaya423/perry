import XCTest
@testable import PerryCapture
import PerryCore

final class PermissionProbeTests: XCTestCase {
    func testProbeReturnsWithoutCrashingAndIsSelfConsistent() async {
        let snapshot = await PerryPermissionSnapshot.probe()
        let direct = await Task.detached {
            PerryPermissionSnapshot(
                accessibility: PerryPermissionProbe.checkAccessibility(),
                screenRecording: PerryPermissionProbe.checkScreenRecording(),
                microphone: PerryPermissionProbe.checkMicrophone()
            )
        }.value
        XCTAssertEqual(snapshot, direct)
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
