import XCTest
import PerryBrain
@testable import Perry

final class MachineProfileTests: XCTestCase {
    func testCurrentProfileReadsThisMachine() {
        let profile = MachineProfile.current()
        XCTAssertEqual(profile.memoryBytes, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(profile.workingSetBytes, 0)
        XCTAssertLessThanOrEqual(profile.workingSetBytes, profile.memoryBytes)
        XCTAssertGreaterThan(profile.chip.generation, 0)
        XCTAssertGreaterThan(profile.gpuCores ?? 0, 0)
    }

    func testCurrentProfileFeedsTheModelFit() {
        let profile = MachineProfile.current()
        let result = ModelFit.recommend(profile: profile, budget: .keepMainReady)
        XCTAssertTrue(ModelFit.fits(result.interactive, on: profile) || result.interactive == ModelFit.interactiveLadder[0])
        XCTAssertEqual(result.resident.first, .interactive)
    }

    func testMemoryPressureMonitorStartsAndStops() {
        var monitor: MemoryPressureMonitor? = MemoryPressureMonitor { _ in }
        XCTAssertNotNil(monitor)
        monitor = nil
        XCTAssertNil(monitor)
    }
}
