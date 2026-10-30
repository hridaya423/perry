import XCTest
@testable import Perry

@MainActor
final class VoiceInputLifecycleTests: XCTestCase {
    func testKeyEventSourceRecognizesBothDisabledEventTypes() {
        XCTAssertTrue(KeyEventSource.isTapDisabled(.tapDisabledByTimeout))
        XCTAssertTrue(KeyEventSource.isTapDisabled(.tapDisabledByUserInput))
        XCTAssertFalse(KeyEventSource.isTapDisabled(.keyDown))
    }

    func testKeyEventSourceMaskIncludesBothDisabledEventTypes() {
        let timeoutMask = CGEventMask(1) &<< CGEventType.tapDisabledByTimeout.rawValue
        let userInputMask = CGEventMask(1) &<< CGEventType.tapDisabledByUserInput.rawValue

        XCTAssertNotEqual(KeyEventSource.eventMask & timeoutMask, 0)
        XCTAssertNotEqual(KeyEventSource.eventMask & userInputMask, 0)
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

    private func capturingListener(clock: @escaping () -> TimeInterval, wakes: @escaping (String) -> Void, heard: @escaping () -> Void = {}) -> WakeWordListener {
        WakeWordListener(
            onWake: wakes,
            onHeard: heard,
            now: clock,
            scheduleRestart: { _ in },
            startEngineOverride: { _, _ in }
        )
    }

    func testWakeWordWaitsForTheEndOfTheSentence() {
        var clock: TimeInterval = 50
        var wakes: [String] = []
        var heard = 0
        let listener = capturingListener(clock: { clock }, wakes: { wakes.append($0) }, heard: { heard += 1 })
        func frames(_ seconds: Double, rms: Double) {
            for _ in 0..<Int((seconds / 0.02).rounded()) {
                clock += 0.02
                listener.hear(rms: rms, at: clock)
            }
        }
        listener.start()
        frames(1.0, rms: 0.001)
        let stream = ["hey", "hey perry", "hey perry what's", "hey perry what's the weather", "hey perry what's the weather in paris"]
        for partial in stream {
            frames(0.3, rms: 0.06)
            listener.inspect(partial)
            XCTAssertTrue(wakes.isEmpty, "dispatched after \"\(partial)\"")
        }
        XCTAssertEqual(heard, 1)
        frames(0.5, rms: 0.001)
        XCTAssertTrue(wakes.isEmpty)
        frames(0.7, rms: 0.001)
        XCTAssertEqual(wakes, ["what's the weather in paris"])
    }

    func testHeyPerryAloneWaitsForTheRequest() {
        var clock: TimeInterval = 50
        var wakes: [String] = []
        let listener = capturingListener(clock: { clock }, wakes: { wakes.append($0) })
        func frames(_ seconds: Double, rms: Double) {
            for _ in 0..<Int((seconds / 0.02).rounded()) {
                clock += 0.02
                listener.hear(rms: rms, at: clock)
            }
        }
        listener.start()
        frames(1.0, rms: 0.001)
        frames(0.4, rms: 0.06)
        listener.inspect("Hey Perry.")
        frames(2, rms: 0.001)
        XCTAssertTrue(wakes.isEmpty)
        frames(0.6, rms: 0.06)
        listener.inspect("Hey Perry. Open my notes.")
        frames(1.0, rms: 0.001)
        XCTAssertEqual(wakes, ["Open my notes."])
    }

    func testHeyPerryWithNothingAfterGivesUpQuietly() {
        var clock: TimeInterval = 50
        var wakes: [String] = []
        let listener = capturingListener(clock: { clock }, wakes: { wakes.append($0) })
        listener.start()
        listener.inspect("hey perry")
        for _ in 0..<410 {
            clock += 0.02
            listener.hear(rms: 0.001, at: clock)
        }
        XCTAssertEqual(wakes, [""])
    }

    func testWakeRemainderKeepsTheSpokenText() {
        XCTAssertEqual(WakeWordListener.remainder(of: "Hey Perry, what's the weather in Paris?"), "what's the weather in Paris?")
        XCTAssertEqual(WakeWordListener.remainder(of: "hey perry"), "")
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
        let controller = PushToTalkController(gesture: .chord([.option, .command], keyCode: 49), onPress: { state.presses += 1 }, onRelease: { state.releases += 1 })

        controller.handle(keyCode: 49, timestamp: 1, isKeyDown: true, isKeyUp: false, modifiers: true, tapDisabled: false)
        controller.handle(keyCode: 0, timestamp: 2, isKeyDown: false, isKeyUp: false, modifiers: false, tapDisabled: true)
        controller.handle(keyCode: 49, timestamp: 3, isKeyDown: false, isKeyUp: true, modifiers: false, tapDisabled: false)

        XCTAssertEqual(state.presses, 1)
        XCTAssertEqual(state.releases, 1)
    }

    func testPushToTalkStopReleasesOnceAndClearsLatchedState() {
        let state = PushToTalkTestState()
        let controller = PushToTalkController(gesture: .chord([.option, .command], keyCode: 49), onPress: { state.presses += 1 }, onRelease: { state.releases += 1 })

        controller.handle(keyCode: 49, timestamp: 1, isKeyDown: true, isKeyUp: false, modifiers: true, tapDisabled: false)
        controller.stop()
        controller.stop()
        controller.handle(keyCode: 49, timestamp: 2, isKeyDown: false, isKeyUp: true, modifiers: false, tapDisabled: false)

        XCTAssertEqual(state.presses, 1)
        XCTAssertEqual(state.releases, 1)
    }

    func testPushToTalkShortcutChangeReleasesOnceAndClearsLatchedState() {
        let state = PushToTalkTestState()
        let controller = PushToTalkController(gesture: .chord([.option, .command], keyCode: 49), onPress: { state.presses += 1 }, onRelease: { state.releases += 1 })

        controller.handle(keyCode: 49, timestamp: 1, isKeyDown: true, isKeyUp: false, modifiers: true, tapDisabled: false)
        controller.update(gesture: .doubleTap([.capsLock]))
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
            gesture: .doubleTap([.capsLock]),
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

    /// fn-hold: the modifiers alone commit after the grace window; a real key
    /// inside the window means a chord (fn+arrow) and never presses.
    func testPushToTalkFunctionHoldGraceCommitsAndChordBusts() async throws {
        let state = PushToTalkTestState()
        let controller = PushToTalkController(
            gesture: .hold([.function]),
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
            gesture: .hold([.control, .option, .command]),
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
            gesture: .hold([.function]),
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
            gesture: .doubleTap([.capsLock]),
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
