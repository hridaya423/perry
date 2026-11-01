import XCTest
@testable import Perry

@MainActor
final class WakeWordRetryTests: XCTestCase {
    private struct StartFailure: LocalizedError {
        var errorDescription: String? { "mic busy" }
    }

    func testOneThrownStartRetriesWithoutReportingFailure() async {
        var attempts = 0
        var failures: [String] = []
        let listener = WakeWordListener(onWake: { _ in }, onFailure: { failures.append($0) })
        listener.retryDelays = [0.01, 0.01, 0.01]
        listener.beginListening = {
            attempts += 1
            if attempts == 1 { throw StartFailure() }
        }

        listener.start()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(failures.isEmpty)
        listener.stop()
    }

    func testPersistentFailureIsReportedAfterThreeRetries() async {
        var attempts = 0
        var failures: [String] = []
        let listener = WakeWordListener(onWake: { _ in }, onFailure: { failures.append($0) })
        listener.retryDelays = [0.01, 0.01, 0.01]
        listener.beginListening = {
            attempts += 1
            throw StartFailure()
        }

        listener.start()
        try? await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(attempts, 4)
        XCTAssertEqual(failures, ["mic busy"])
        listener.stop()
    }

    func testStoppingCancelsPendingRetries() async {
        var attempts = 0
        let listener = WakeWordListener(onWake: { _ in })
        listener.retryDelays = [0.05, 0.05, 0.05]
        listener.beginListening = {
            attempts += 1
            throw StartFailure()
        }

        listener.start()
        listener.stop()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(attempts, 1)
    }

    func testStartingAgainDuringARetryRunsOneChainAndReportsOnce() async {
        var attempts = 0
        var failures: [String] = []
        let listener = WakeWordListener(onWake: { _ in }, onFailure: { failures.append($0) })
        listener.retryDelays = [0.02, 0.02, 0.02]
        listener.beginListening = {
            attempts += 1
            throw StartFailure()
        }

        listener.start()
        listener.start()
        try? await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(attempts, 5)
        XCTAssertEqual(failures, ["mic busy"])
        listener.stop()
    }
}
