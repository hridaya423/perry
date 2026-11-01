import XCTest
import PerryGuide
@testable import Perry

@MainActor
final class RoutineRecordingStartTests: XCTestCase {
    private func makeController(
        granted: Bool,
        guided: GrantMonitor.Status,
        guideCalls: Counter,
        statuses: StatusLog
    ) -> RoutineLibraryController {
        RoutineLibraryController(
            store: RoutineStore(storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            workers: ScreenWorkerService(),
            context: nil,
            setStatus: { statuses.lines.append($0) },
            speak: { _ in },
            runRoutine: { _, _ in },
            inputMonitoringGranted: { granted },
            guideInputMonitoring: {
                guideCalls.count += 1
                return guided
            }
        )
    }

    private final class Counter { var count = 0 }
    private final class StatusLog { var lines: [String] = [] }

    func testMissingInputMonitoringOpensTheDragHelperAndDoesNotRecordWhenDenied() async {
        let calls = Counter()
        let statuses = StatusLog()
        let controller = makeController(granted: false, guided: .notGranted, guideCalls: calls, statuses: statuses)
        await controller.beginRecording()
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(statuses.lines.last, "I need Input Monitoring to see your typing, so I have not started recording.")
    }

    func testAGrantThatNeedsARelaunchDoesNotRecord() async {
        let calls = Counter()
        let statuses = StatusLog()
        let controller = makeController(granted: false, guided: .needsRelaunch, guideCalls: calls, statuses: statuses)
        await controller.beginRecording()
        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(statuses.lines.last, "Input Monitoring is on. Restart Perry, then start the recording again.")
    }

    func testGrantedInputMonitoringSkipsTheHelperAndRecordsUntilCancelled() async {
        let calls = Counter()
        let statuses = StatusLog()
        let presentation = NotchPresentation.shared
        let previous = presentation.onPresent
        presentation.onPresent = nil
        let controller = makeController(granted: true, guided: .notGranted, guideCalls: calls, statuses: statuses)
        defer {
            controller.stop()
            presentation.onPresent = previous
        }
        await controller.beginRecording()
        XCTAssertEqual(calls.count, 0)
        XCTAssertTrue(controller.isRecording)
        controller.stop()
        XCTAssertFalse(controller.isRecording)
    }
}
