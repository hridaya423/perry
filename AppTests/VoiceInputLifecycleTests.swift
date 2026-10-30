import XCTest
@testable import Perry

@MainActor
final class VoiceInputLifecycleTests: XCTestCase {
    func testKeyEventSourceMaskIncludesBothDisabledEventTypes() {
        let timeoutMask = CGEventMask(1) &<< CGEventType.tapDisabledByTimeout.rawValue
        let userInputMask = CGEventMask(1) &<< CGEventType.tapDisabledByUserInput.rawValue

        XCTAssertNotEqual(KeyEventSource.eventMask & timeoutMask, 0)
        XCTAssertNotEqual(KeyEventSource.eventMask & userInputMask, 0)
    }

    private struct WakeRun {
        var matcher = WakeWordMatcher()
        var clock: TimeInterval = 50
        var wakes: [String] = []
        var heard = 0

        mutating func frames(_ seconds: Double, rms: Double) {
            for _ in 0..<Int((seconds / 0.02).rounded()) {
                clock += 0.02
                if let command = matcher.hear(rms: rms, at: clock) { wakes.append(command) }
            }
        }

        mutating func inspect(_ transcript: String) {
            if matcher.inspect(transcript, at: clock) { heard += 1 }
        }
    }

    func testWakeWordWaitsForTheEndOfTheSentence() {
        var run = WakeRun()
        run.frames(1.0, rms: 0.001)
        let stream = ["hey", "hey perry", "hey perry what's", "hey perry what's the weather", "hey perry what's the weather in paris"]
        for partial in stream {
            run.frames(0.3, rms: 0.06)
            run.inspect(partial)
            XCTAssertTrue(run.wakes.isEmpty, "dispatched after \"\(partial)\"")
        }
        XCTAssertEqual(run.heard, 1)
        run.frames(0.5, rms: 0.001)
        XCTAssertTrue(run.wakes.isEmpty)
        run.frames(0.7, rms: 0.001)
        XCTAssertEqual(run.wakes, ["what's the weather in paris"])
    }

    func testHeyPerryAloneWaitsForTheRequest() {
        var run = WakeRun()
        run.frames(1.0, rms: 0.001)
        run.frames(0.4, rms: 0.06)
        run.inspect("Hey Perry.")
        run.frames(2, rms: 0.001)
        XCTAssertTrue(run.wakes.isEmpty)
        run.frames(0.6, rms: 0.06)
        run.inspect("Hey Perry. Open my notes.")
        run.frames(1.0, rms: 0.001)
        XCTAssertEqual(run.wakes, ["Open my notes."])
    }

    func testHeyPerryWithNothingAfterGivesUpQuietly() {
        var run = WakeRun()
        run.inspect("hey perry")
        run.frames(8.2, rms: 0.001)
        XCTAssertEqual(run.wakes, [""])
    }

    func testWakeRemainderKeepsTheSpokenText() {
        XCTAssertEqual(WakeWordMatcher.remainder(of: "Hey Perry, what's the weather in Paris?"), "what's the weather in Paris?")
        XCTAssertEqual(WakeWordMatcher.remainder(of: "hey perry"), "")
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
private final class PushToTalkTestState {
    var presses = 0
    var releases = 0
}
