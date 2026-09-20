import XCTest
@testable import Perry

@MainActor
final class VoiceInputLifecycleTests: XCTestCase {
    func testPushToTalkRecognizesBothDisabledEventTypes() {
        XCTAssertTrue(PushToTalkController.tapIsDisabled(.tapDisabledByTimeout))
        XCTAssertTrue(PushToTalkController.tapIsDisabled(.tapDisabledByUserInput))
        XCTAssertFalse(PushToTalkController.tapIsDisabled(.keyDown))
    }

    func testPushToTalkEventMaskIncludesBothDisabledEventTypes() {
        let timeoutMask = CGEventMask(1) &<< CGEventType.tapDisabledByTimeout.rawValue
        let userInputMask = CGEventMask(1) &<< CGEventType.tapDisabledByUserInput.rawValue

        XCTAssertNotEqual(PushToTalkController.eventTapMask & timeoutMask, 0)
        XCTAssertNotEqual(PushToTalkController.eventTapMask & userInputMask, 0)
    }

    func testWakeWordDuplicateTerminalCallbacksScheduleOneRestartAndStartOneNewGeneration() {
        let state = WakeWordTestState()
        let listener = WakeWordListener(
            onWake: { _ in },
            scheduleRestart: { work in state.restarts.append(work) },
            startEngineOverride: { _, terminal in
                state.starts += 1
                state.terminals.append(terminal)
            }
        )

        listener.start()
        state.terminals[0]()
        state.terminals[0]()

        XCTAssertEqual(state.starts, 1)
        XCTAssertEqual(state.restarts.count, 1)

        state.restarts[0]()

        XCTAssertEqual(state.starts, 2)
    }

    func testWakeWordStopInvalidatesPendingRestart() {
        let state = WakeWordTestState()
        let listener = WakeWordListener(
            onWake: { _ in },
            scheduleRestart: { work in state.restarts.append(work) },
            startEngineOverride: { _, terminal in
                state.starts += 1
                state.terminals.append(terminal)
            }
        )

        listener.start()
        state.terminals[0]()
        listener.stop()
        state.restarts[0]()

        XCTAssertEqual(state.starts, 1)
    }

    func testWakeWordReplacementInvalidatesPendingRestart() {
        let state = WakeWordTestState()
        let listener = WakeWordListener(
            onWake: { _ in },
            scheduleRestart: { work in state.restarts.append(work) },
            startEngineOverride: { _, terminal in
                state.starts += 1
                state.terminals.append(terminal)
            }
        )

        listener.start()
        state.terminals[0]()
        listener.start()
        state.restarts[0]()

        XCTAssertEqual(state.starts, 2)
    }

    func testPushToTalkDisabledEventReleasesOnceAndIgnoresLaterKeyUp() {
        let state = PushToTalkTestState()
        let controller = PushToTalkController(onPress: { state.presses += 1 }, onRelease: { state.releases += 1 })

        controller.handle(keyCode: 49, timestamp: 1, isKeyDown: true, isKeyUp: false, modifiers: true, tapDisabled: false)
        controller.handle(keyCode: 0, timestamp: 2, isKeyDown: false, isKeyUp: false, modifiers: false, tapDisabled: true)
        controller.handle(keyCode: 49, timestamp: 3, isKeyDown: false, isKeyUp: true, modifiers: false, tapDisabled: false)

        XCTAssertEqual(state.presses, 1)
        XCTAssertEqual(state.releases, 1)
    }

    func testPushToTalkStopReleasesOnceAndClearsLatchedState() {
        let state = PushToTalkTestState()
        let controller = PushToTalkController(onPress: { state.presses += 1 }, onRelease: { state.releases += 1 })

        controller.handle(keyCode: 49, timestamp: 1, isKeyDown: true, isKeyUp: false, modifiers: true, tapDisabled: false)
        controller.stop()
        controller.stop()
        controller.handle(keyCode: 49, timestamp: 2, isKeyDown: false, isKeyUp: true, modifiers: false, tapDisabled: false)

        XCTAssertEqual(state.presses, 1)
        XCTAssertEqual(state.releases, 1)
    }

    func testPushToTalkShortcutChangeReleasesOnceAndClearsLatchedState() {
        let state = PushToTalkTestState()
        let controller = PushToTalkController(onPress: { state.presses += 1 }, onRelease: { state.releases += 1 })

        controller.handle(keyCode: 49, timestamp: 1, isKeyDown: true, isKeyUp: false, modifiers: true, tapDisabled: false)
        controller.update(shortcut: .capsLockDoubleTap)
        controller.handle(keyCode: 49, timestamp: 2, isKeyDown: false, isKeyUp: true, modifiers: false, tapDisabled: false)

        XCTAssertEqual(state.presses, 1)
        XCTAssertEqual(state.releases, 1)
    }
}

@MainActor
private final class WakeWordTestState {
    var starts = 0
    var restarts: [@MainActor @Sendable () -> Void] = []
    var terminals: [() -> Void] = []
}

@MainActor
private final class PushToTalkTestState {
    var presses = 0
    var releases = 0
}
