import AppKit
import XCTest
import PerryBrain
import PerryCore
import PerryGuide
import PerryOverlay
@testable import Perry

@MainActor
final class ModifierHoldMonitorTests: XCTestCase {
    private func makeMonitor(commitDelay: TimeInterval = 0, talkHold: ModifierSet = [.control, .option]) -> (ModifierHoldMonitor, CallLog) {
        let log = CallLog()
        let monitor = ModifierHoldMonitor(
            commitDelay: commitDelay,
            talkHold: { talkHold },
            onHoldStart: { log.starts += 1 },
            onHoldCommit: { log.commits += 1 },
            onHoldEnd: { log.ends += 1 },
            onHoldCancel: { log.cancels += 1 },
            onHoldTap: { log.taps += 1 },
            onComposer: { log.composers += 1 }
        )
        return (monitor, log)
    }

    final class CallLog {
        var starts = 0
        var commits = 0
        var ends = 0
        var cancels = 0
        var taps = 0
        var composers = 0
    }

    func testHoldStartsOnControlOptionAndEndsOnRelease() {
        let (monitor, log) = makeMonitor()
        monitor.handle(timestamp: 1.0, control: true, option: true, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.1, control: true, option: true, isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.starts, 1)
        monitor.handle(timestamp: 1.4, control: false, option: true, isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.ends, 1)
        XCTAssertEqual(log.cancels, 0)
        XCTAssertEqual(log.taps, 0)
    }

    func testHoldingControlOptionCommandNeverSubmitsATalkTurn() {
        let (monitor, log) = makeMonitor()
        monitor.handle(timestamp: 1.0, modifiers: [.control, .option], isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.05, modifiers: [.control, .option, .command], isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.6, modifiers: [], isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.ends, 0)
        XCTAssertEqual(log.cancels, 1)

        let (late, lateLog) = makeMonitor()
        late.handle(timestamp: 2.0, modifiers: [.command], isFlagsChanged: true, tapDisabled: false)
        late.handle(timestamp: 2.05, modifiers: [.command, .control, .option], isFlagsChanged: true, tapDisabled: false)
        late.handle(timestamp: 2.6, modifiers: [], isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(lateLog.starts, 0)
    }

    func testASavedCustomHoldFiresAndTheDefaultNoLongerDoes() {
        let (monitor, log) = makeMonitor(talkHold: [.function])
        monitor.handle(timestamp: 1.0, modifiers: [.control, .option], isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.5, modifiers: [], isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.starts, 0)
        monitor.handle(timestamp: 2.0, modifiers: ModifierSet(CGEventFlags.maskSecondaryFn), isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 2.6, modifiers: [], isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.starts, 1)
        XCTAssertEqual(log.ends, 1)
    }

    func testRightOptionIsItsOwnHold() {
        let (monitor, log) = makeMonitor(talkHold: [.option, .rightOption])
        monitor.handle(timestamp: 1.0, modifiers: ModifierSet(CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)), isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.starts, 0)
        monitor.handle(timestamp: 1.1, modifiers: [], isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 2.0, modifiers: ModifierSet(CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)), isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.starts, 1)
    }

    func testGesturesSurviveSavingAndReadTheWayTheyArePressed() {
        let gestures: [Gesture] = [.hold([.control, .option]), .hold([.function]), .hold([.option, .rightOption]), .chord([.option, .command], keyCode: 49), .doubleTap([.control])]
        for gesture in gestures {
            XCTAssertEqual(Gesture(rawValue: gesture.rawValue), gesture, gesture.rawValue)
        }
        XCTAssertNil(Gesture(rawValue: "hold:"))
        XCTAssertNil(Gesture(rawValue: "hold:hyper"))
        XCTAssertEqual(Gesture.defaultTalk.spoken, "Hold ⌃⌥")
        XCTAssertEqual(Gesture.hold([.option, .rightOption]).spoken, "Hold right ⌥")
        XCTAssertEqual(Gesture.hold([.function]).spoken, "Hold fn")
        XCTAssertEqual(Gesture.chord([.option, .command], keyCode: 49).keys, "⌥⌘Space")
    }

    func testBareOptionOrControlAloneDoesNotHold() {
        let (monitor, log) = makeMonitor()
        monitor.handle(timestamp: 1.0, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.1, control: false, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.2, control: false, option: true, isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.starts, 0)
        XCTAssertEqual(log.ends, 0)
    }

    func testKeyPressDuringHoldCancelsInsteadOfSubmitting() {
        let (monitor, log) = makeMonitor()
        monitor.handle(timestamp: 1.0, control: true, option: true, isFlagsChanged: true, tapDisabled: false)
        monitor.handleKeyDown()
        monitor.handle(timestamp: 1.4, control: false, option: false, isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.starts, 1)
        XCTAssertEqual(log.cancels, 1)
        XCTAssertEqual(log.ends, 0)
    }

    func testReleaseBeforeCommitCancels() {
        let (monitor, log) = makeMonitor(commitDelay: 60)
        monitor.handle(timestamp: 1.0, control: true, option: true, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.3, control: false, option: false, isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.starts, 1)
        XCTAssertEqual(log.cancels, 1)
        XCTAssertEqual(log.ends, 0)
        XCTAssertEqual(log.commits, 0)
        XCTAssertEqual(log.taps, 0)
    }

    func testPressShorterThan250msIsATapNotASend() {
        let (monitor, log) = makeMonitor(commitDelay: 0)
        monitor.handle(timestamp: 1.0, control: true, option: true, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.2, control: false, option: false, isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.commits, 1)
        XCTAssertEqual(log.taps, 1)
        XCTAssertEqual(log.ends, 0)
        XCTAssertEqual(log.cancels, 0)
    }

    func testChordDuringAShortPressStillCancels() {
        let (monitor, log) = makeMonitor(commitDelay: 60)
        monitor.handle(timestamp: 1.0, control: true, option: true, isFlagsChanged: true, tapDisabled: false)
        monitor.handleKeyDown()
        monitor.handle(timestamp: 1.1, control: false, option: false, isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.cancels, 1)
        XCTAssertEqual(log.taps, 0)
    }

    func testHoldCommitsAfterThresholdAndSubmitsOnRelease() async throws {
        let (monitor, log) = makeMonitor(commitDelay: 0.02)
        monitor.handle(timestamp: 1.0, control: true, option: true, isFlagsChanged: true, tapDisabled: false)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(log.commits, 1)
        monitor.handle(timestamp: 1.5, control: false, option: false, isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.ends, 1)
        XCTAssertEqual(log.cancels, 0)
    }

    func testCancelledHoldNeverCommits() async throws {
        let (monitor, log) = makeMonitor(commitDelay: 0.02)
        monitor.handle(timestamp: 1.0, control: true, option: true, isFlagsChanged: true, tapDisabled: false)
        monitor.handleKeyDown()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(log.commits, 0)
    }

    func testDoubleTapControlOpensComposer() {
        let (monitor, log) = makeMonitor()
        monitor.handle(timestamp: 1.0, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.1, control: false, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.2, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.composers, 1)
        XCTAssertEqual(log.starts, 0)
    }

    func testSlowSecondTapDoesNotOpenComposer() {
        let (monitor, log) = makeMonitor()
        monitor.handle(timestamp: 1.0, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.1, control: false, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 2.0, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.composers, 0)
    }

    func testControlChordsNeverOpenComposer() {
        let (monitor, log) = makeMonitor()
        monitor.handle(timestamp: 1.00, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handleKeyDown()
        monitor.handle(timestamp: 1.05, control: false, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.15, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handleKeyDown()
        monitor.handle(timestamp: 1.20, control: false, option: false, isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.composers, 0)
    }

    func testTypedKeyBetweenControlTapsBreaksDoubleTap() {
        let (monitor, log) = makeMonitor()
        monitor.handle(timestamp: 1.0, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.1, control: false, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handleKeyDown()
        monitor.handle(timestamp: 1.2, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.composers, 0)
    }

    func testLongControlPressDoesNotCountAsTap() {
        let (monitor, log) = makeMonitor()
        monitor.handle(timestamp: 1.0, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.5, control: false, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.6, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.composers, 0)
    }

    func testTapDisabledDuringHoldCancels() {
        let (monitor, log) = makeMonitor()
        monitor.handle(timestamp: 1.0, control: true, option: true, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.1, control: true, option: true, isFlagsChanged: false, tapDisabled: true)
        XCTAssertEqual(log.cancels, 1)
        XCTAssertEqual(log.ends, 0)
    }
}
