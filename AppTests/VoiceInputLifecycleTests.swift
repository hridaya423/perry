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
        let controller = PushToTalkController(shortcut: .optionCommandSpace, onPress: { state.presses += 1 }, onRelease: { state.releases += 1 })

        controller.handle(keyCode: 49, timestamp: 1, isKeyDown: true, isKeyUp: false, modifiers: true, tapDisabled: false)
        controller.handle(keyCode: 0, timestamp: 2, isKeyDown: false, isKeyUp: false, modifiers: false, tapDisabled: true)
        controller.handle(keyCode: 49, timestamp: 3, isKeyDown: false, isKeyUp: true, modifiers: false, tapDisabled: false)

        XCTAssertEqual(state.presses, 1)
        XCTAssertEqual(state.releases, 1)
    }

    func testPushToTalkStopReleasesOnceAndClearsLatchedState() {
        let state = PushToTalkTestState()
        let controller = PushToTalkController(shortcut: .optionCommandSpace, onPress: { state.presses += 1 }, onRelease: { state.releases += 1 })

        controller.handle(keyCode: 49, timestamp: 1, isKeyDown: true, isKeyUp: false, modifiers: true, tapDisabled: false)
        controller.stop()
        controller.stop()
        controller.handle(keyCode: 49, timestamp: 2, isKeyDown: false, isKeyUp: true, modifiers: false, tapDisabled: false)

        XCTAssertEqual(state.presses, 1)
        XCTAssertEqual(state.releases, 1)
    }

    func testPushToTalkShortcutChangeReleasesOnceAndClearsLatchedState() {
        let state = PushToTalkTestState()
        let controller = PushToTalkController(shortcut: .optionCommandSpace, onPress: { state.presses += 1 }, onRelease: { state.releases += 1 })

        controller.handle(keyCode: 49, timestamp: 1, isKeyDown: true, isKeyUp: false, modifiers: true, tapDisabled: false)
        controller.update(shortcut: .capsLockDoubleTap)
        controller.handle(keyCode: 49, timestamp: 2, isKeyDown: false, isKeyUp: true, modifiers: false, tapDisabled: false)

        XCTAssertEqual(state.presses, 1)
        XCTAssertEqual(state.releases, 1)
    }

    func testPushToTalkStartReportsCaptureModeAndStopClearsIt() {
        let controller = PushToTalkController(onPress: {}, onRelease: {})
        XCTAssertNil(controller.captureMode)

        controller.start()
        XCTAssertNotNil(controller.captureMode)

        controller.stop()
        XCTAssertNil(controller.captureMode)
    }

    func testPushToTalkCapsLockDoubleTapWithinWindowPressesThenNextTapReleases() {
        let state = PushToTalkTestState()
        let controller = PushToTalkController(
            shortcut: .capsLockDoubleTap,
            onPress: { state.presses += 1 },
            onRelease: { state.releases += 1 }
        )

        controller.handle(keyCode: 57, timestamp: 1.0, isKeyDown: true, isKeyUp: false, modifiers: false, tapDisabled: false)
        controller.handle(keyCode: 57, timestamp: 1.1, isKeyDown: false, isKeyUp: true, modifiers: false, tapDisabled: false)
        XCTAssertEqual(state.presses, 0)

        controller.handle(keyCode: 57, timestamp: 1.2, isKeyDown: true, isKeyUp: false, modifiers: false, tapDisabled: false)
        XCTAssertEqual(state.presses, 1)

        controller.handle(keyCode: 57, timestamp: 1.3, isKeyDown: false, isKeyUp: true, modifiers: false, tapDisabled: false)
        controller.handle(keyCode: 57, timestamp: 1.4, isKeyDown: true, isKeyUp: false, modifiers: false, tapDisabled: false)
        XCTAssertEqual(state.releases, 1)
    }

    func testBluetoothRouteSwitchGetsPrerollAndBuiltInDoesNot() {
        XCTAssertGreaterThan(VoiceController.bluetoothPrerollDelay(isBluetooth: true), 0)
        XCTAssertEqual(VoiceController.bluetoothPrerollDelay(isBluetooth: false), 0)
    }

    func testDefaultOutputBluetoothProbeReturnsWithoutCrashing() {
        _ = AudioRouteMonitor.defaultOutputIsBluetooth()
    }

    /// fn-hold: the modifiers alone commit after the grace window; a real key
    /// inside the window means a chord (fn+arrow) and never presses.
    func testPushToTalkFunctionHoldGraceCommitsAndChordBusts() async throws {
        let state = PushToTalkTestState()
        let controller = PushToTalkController(
            shortcut: .functionHold,
            onPress: { state.presses += 1 },
            onRelease: { state.releases += 1 }
        )

        // fn chord-bust: flagsChanged carries fn, an arrow keydown follows
        // inside the grace window → no press, and the release drops nothing.
        controller.handle(keyCode: 63, timestamp: 1.0, flags: .maskSecondaryFn, isKeyDown: false, isKeyUp: false, tapDisabled: false)
        controller.handle(keyCode: 123, timestamp: 1.05, flags: .maskSecondaryFn, isKeyDown: true, isKeyUp: false, tapDisabled: false)
        controller.handle(keyCode: 63, timestamp: 1.2, flags: [], isKeyDown: false, isKeyUp: false, tapDisabled: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(state.presses, 0)
        XCTAssertEqual(state.releases, 0)

        // Clean hold: flagsChanged with fn, no other key, grace elapses →
        // press; flags clear → release.
        controller.handle(keyCode: 63, timestamp: 2.0, flags: .maskSecondaryFn, isKeyDown: false, isKeyUp: false, tapDisabled: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(state.presses, 1)
        controller.handle(keyCode: 63, timestamp: 2.5, flags: [], isKeyDown: false, isKeyUp: false, tapDisabled: false)
        XCTAssertEqual(state.releases, 1)
    }

    /// ⌃⌥⌘-hold commits after the same grace, and ⇧ or fn in the mix means
    /// it was a chord, not a hold.
    func testPushToTalkControlOptionCommandHoldPressesAndExtraModifiersBust() async throws {
        let state = PushToTalkTestState()
        let controller = PushToTalkController(
            shortcut: .controlOptionCommandHold,
            onPress: { state.presses += 1 },
            onRelease: { state.releases += 1 }
        )
        let hold: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

        // ⇧ inside the hold = a chord — must never press.
        controller.handle(keyCode: 0, timestamp: 1.0, flags: hold.union(.maskShift), isKeyDown: false, isKeyUp: false, tapDisabled: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(state.presses, 0)

        controller.handle(keyCode: 0, timestamp: 2.0, flags: hold, isKeyDown: false, isKeyUp: false, tapDisabled: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(state.presses, 1)
        controller.handle(keyCode: 0, timestamp: 2.5, flags: [], isKeyDown: false, isKeyUp: false, tapDisabled: false)
        XCTAssertEqual(state.releases, 1)
    }

    /// stop() mid-hold releases exactly once and drops the pending grace task.
    func testPushToTalkModifierHoldStopReleasesOnce() async throws {
        let state = PushToTalkTestState()
        let controller = PushToTalkController(
            shortcut: .functionHold,
            onPress: { state.presses += 1 },
            onRelease: { state.releases += 1 }
        )

        controller.handle(keyCode: 63, timestamp: 1.0, flags: .maskSecondaryFn, isKeyDown: false, isKeyUp: false, tapDisabled: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(state.presses, 1)
        controller.stop()
        XCTAssertEqual(state.releases, 1)
        controller.stop()
        controller.handle(keyCode: 63, timestamp: 2.0, flags: [], isKeyDown: false, isKeyUp: false, tapDisabled: false)
        XCTAssertEqual(state.releases, 1)
    }

    func testPushToTalkCapsLockTapsOutsideWindowDoNotPress() {
        let state = PushToTalkTestState()
        let controller = PushToTalkController(
            shortcut: .capsLockDoubleTap,
            onPress: { state.presses += 1 },
            onRelease: { state.releases += 1 }
        )

        controller.handle(keyCode: 57, timestamp: 1.0, isKeyDown: true, isKeyUp: false, modifiers: false, tapDisabled: false)
        controller.handle(keyCode: 57, timestamp: 1.1, isKeyDown: false, isKeyUp: true, modifiers: false, tapDisabled: false)
        controller.handle(keyCode: 57, timestamp: 2.0, isKeyDown: true, isKeyUp: false, modifiers: false, tapDisabled: false)

        XCTAssertEqual(state.presses, 0)
        XCTAssertEqual(state.releases, 0)
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
