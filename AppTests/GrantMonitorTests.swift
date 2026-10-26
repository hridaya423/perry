import XCTest
@testable import Perry

@MainActor
final class GrantMonitorTests: XCTestCase {
    func testCapturePanesGrantedOnlyInAFreshProcessNeedARelaunch() {
        let cases: [(PrivacyPane, Bool, Bool, GrantMonitor.Status)] = [
            (.screenRecording, false, false, .notGranted),
            (.screenRecording, true, false, .needsRelaunch),
            (.screenRecording, true, true, .granted),
            (.inputMonitoring, true, false, .needsRelaunch),
            (.accessibility, false, false, .notGranted),
            (.accessibility, true, true, .granted),
            (.accessibility, false, true, .granted),
        ]
        for (pane, fresh, inProcess, expected) in cases {
            XCTAssertEqual(GrantMonitor.status(for: pane, grantedInFreshProbe: fresh, grantedInProcess: inProcess), expected, "\(pane) \(fresh) \(inProcess)")
        }
    }

    func testTheFlagAnswersInJSONAndIgnoresNormalLaunches() {
        XCTAssertNil(PermissionCheck.output(for: ["Perry"]))
        XCTAssertEqual(PermissionCheck.output(for: ["Perry", "--check-permission", "nonsense"]), #"{"granted":false}"#)
        let answer = PermissionCheck.output(for: ["Perry", "--check-permission", "accessibility"])
        XCTAssertTrue(answer == #"{"granted":true}"# || answer == #"{"granted":false}"#, answer ?? "nil")
    }

    func testTheRealAppAnswersTheProbeAndExitsWithoutStartingItsUI() throws {
        let executable = try XCTUnwrap(Bundle.main.executableURL)
        XCTAssertEqual(executable.lastPathComponent, "Perry")
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--check-permission", "screenRecording"]
        process.standardOutput = output
        let started = Date()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Bool])
        XCTAssertNotNil(reply["granted"])
    }

    func testTheMonitorReportsEachChangeOnceAndStopsWhenGranted() async throws {
        var readings: [GrantMonitor.Reading] = [(false, false), (false, false), (true, false), (true, true), (true, true)]
        var reads = 0
        let monitor = GrantMonitor(
            read: { _ in reads += 1; return readings.removeFirst() },
            idleInterval: .milliseconds(10),
            fastInterval: .milliseconds(10)
        )
        var statuses: [GrantMonitor.Status] = []
        monitor.onStatus = { statuses.append($0) }
        monitor.start(pane: .screenRecording)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(statuses, [.notGranted, .needsRelaunch, .granted])
        XCTAssertEqual(reads, 4)
        monitor.stop()
    }
}
