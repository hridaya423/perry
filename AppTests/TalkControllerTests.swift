import AppKit
import class SwiftUI.NSHostingView
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

    /// ⌃⌥← / ⌃⌥⌘V style chords: a key press during the hold means the user
    /// wanted a shortcut, not a talk turn — cancel, never submit.
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

    /// A cancelled hold must not commit later — the timer dies with the hold.
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

    /// ⌃A ⌃E in a terminal: key presses inside a ⌃ press dirty it, so ⌃
    /// chords during normal typing can never compose a double-tap.
    func testControlChordsNeverOpenComposer() {
        let (monitor, log) = makeMonitor()
        monitor.handle(timestamp: 1.00, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handleKeyDown() // ⌃A
        monitor.handle(timestamp: 1.05, control: false, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.15, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handleKeyDown() // ⌃E
        monitor.handle(timestamp: 1.20, control: false, option: false, isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.composers, 0)
    }

    /// Any typed key between the two taps breaks the double-tap.
    func testTypedKeyBetweenControlTapsBreaksDoubleTap() {
        let (monitor, log) = makeMonitor()
        monitor.handle(timestamp: 1.0, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.1, control: false, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handleKeyDown() // regular typing between taps
        monitor.handle(timestamp: 1.2, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.composers, 0)
    }

    /// A long ⌃ press is a modifier hold, not a tap.
    func testLongControlPressDoesNotCountAsTap() {
        let (monitor, log) = makeMonitor()
        monitor.handle(timestamp: 1.0, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.5, control: false, option: false, isFlagsChanged: true, tapDisabled: false) // held 500 ms
        monitor.handle(timestamp: 1.6, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.composers, 0)
    }

    /// A disabled tap must discard the hold — submitting a turn on a dead
    /// event stream could send a truncated utterance.
    func testTapDisabledDuringHoldCancels() {
        let (monitor, log) = makeMonitor()
        monitor.handle(timestamp: 1.0, control: true, option: true, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.1, control: true, option: true, isFlagsChanged: false, tapDisabled: true)
        XCTAssertEqual(log.cancels, 1)
        XCTAssertEqual(log.ends, 0)
    }
}

@MainActor
final class PointerTraceRecorderTests: XCTestCase {
    func testRecordsSamplesWithWindowAndPerryFlags() {
        var point = CGPoint(x: 100, y: 100)
        let recorder = PointerTraceRecorder(
            point: { point },
            perryFrames: { [CGRect(x: 0, y: 0, width: 50, height: 50)] },
            windowUnder: { _ in 42 },
            now: { 10 }
        )
        recorder.start()
        let first = recorder.record()
        XCTAssertEqual(first.windowID, 42)
        XCTAssertFalse(first.overPerry)
        point = CGPoint(x: 10, y: 10)
        let second = recorder.record()
        XCTAssertTrue(second.overPerry)
        let samples = recorder.stop()
        XCTAssertEqual(samples.count, 2)
    }

    func testRingBufferDropsOldestBeyondCapacity() {
        let recorder = PointerTraceRecorder(
            point: { .zero },
            capacity: 3,
            now: { 0 }
        )
        for _ in 0..<5 { recorder.record() }
        XCTAssertEqual(recorder.samples.count, 3)
    }

    /// Regression: Talk shows a full-screen click-through overlay before the
    /// trace starts. If that window counted as "Perry UI", every sample would
    /// be flagged overPerry and deixis could never bind. Only Perry windows
    /// the user can actually interact with may flag a sample.
    func testClickThroughAndInvisibleWindowsDoNotCountAsPerry() {
        guard let screen = NSScreen.screens.first else { return }
        let clickThrough = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        clickThrough.ignoresMouseEvents = true
        clickThrough.orderFrontRegardless()
        let invisible = NSPanel(
            contentRect: NSRect(x: 50, y: 50, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 100, y: 100, width: 200, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.orderFrontRegardless()
        defer {
            clickThrough.orderOut(nil)
            invisible.orderOut(nil)
            panel.orderOut(nil)
        }

        let frames = PointerTraceRecorder.perryInteractiveFrames(
            of: [clickThrough, invisible, panel],
            primaryMaxY: screen.frame.maxY
        )
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.width, 200)
    }

    /// Integration: drive the real overlay machinery and prove the windows it
    /// orders can never leak into the deixis "over Perry" set.
    func testLiveOverlayWindowsAreNotCountedAsPerry() {
        let manager = OverlayWindowManager()
        manager.showOverlay(onScreens: NSScreen.screens, state: PerryCursorState())
        defer { manager.hideOverlay() }

        let maxY = NSScreen.screens.first?.frame.maxY ?? 0
        let flagged = PointerTraceRecorder.perryWindowFramesInAXSpace()
        for window in NSApp.windows where window.ignoresMouseEvents {
            let ax = CGRect(
                x: window.frame.minX,
                y: maxY - window.frame.maxY,
                width: window.frame.width,
                height: window.frame.height
            )
            XCTAssertFalse(
                flagged.contains(ax),
                "click-through Perry window leaked into the deixis frame set"
            )
        }
    }
}

@MainActor
final class TalkContextStoreTests: XCTestCase {
    private let key = TalkContextKey(processID: 7, windowID: 9)

    func testThreadPersistsWithinTTL() throws {
        var now: TimeInterval = 1000
        let store = TalkContextStore(now: { now })
        let thread = UUID()
        store.record(key, threadID: thread)
        now += 120
        XCTAssertEqual(store.thread(for: key), thread)
    }

    func testThreadExpiresAfterTTL() throws {
        var now: TimeInterval = 1000
        let store = TalkContextStore(now: { now }, ttl: 600)
        store.record(key, threadID: UUID())
        now += 601
        XCTAssertNil(store.thread(for: key))
    }

    func testReadRefreshesTTL() throws {
        var now: TimeInterval = 1000
        let store = TalkContextStore(now: { now }, ttl: 600)
        let thread = UUID()
        store.record(key, threadID: thread)
        now += 550
        XCTAssertEqual(store.thread(for: key), thread)
        now += 550
        XCTAssertEqual(store.thread(for: key), thread)
    }

    func testResetPhraseClearsContext() throws {
        let store = TalkContextStore()
        store.record(key, threadID: UUID())
        XCTAssertTrue(TalkContextStore.isResetPhrase("new topic: tell me about that"))
        store.reset(key)
        XCTAssertNil(store.thread(for: key))
    }

    func testKeysAreIndependent() throws {
        let store = TalkContextStore()
        let other = TalkContextKey(processID: 8, windowID: 9)
        let thread = UUID()
        store.record(key, threadID: thread)
        XCTAssertNil(store.thread(for: other))
        XCTAssertEqual(store.thread(for: key), thread)
    }

    func testAcceptInputReusesWindowThread() throws {
        let home = HomeController()
        let first = home.acceptInput("what is this", contextKey: key)
        home.homeModel.threads = [PerryThread(id: first.threadID)]
        let followUp = home.acceptInput("and that one", contextKey: key)
        XCTAssertEqual(first.threadID, followUp.threadID)
    }

    func testAcceptInputSeparatesWindows() throws {
        let home = HomeController()
        let editorKey = TalkContextKey(processID: 7, windowID: 9)
        let browserKey = TalkContextKey(processID: 8, windowID: 4)
        let editor = home.acceptInput("what is this", contextKey: editorKey)
        let browser = home.acceptInput("what is this", contextKey: browserKey)
        XCTAssertNotEqual(editor.threadID, browser.threadID)
    }

    func testAcceptInputResetPhraseStartsFreshForWindow() throws {
        let home = HomeController()
        let first = home.acceptInput("what is this", contextKey: key)
        let fresh = home.acceptInput("new topic — what's that", contextKey: key)
        XCTAssertNotEqual(first.threadID, fresh.threadID)
    }

    func testAcceptInputDropsMappedThreadThatNoLongerExists() throws {
        let home = HomeController()
        let first = home.acceptInput("what is this", contextKey: key)
        // The thread exists in the map but was deleted from the model —
        // a follow-up must not resurrect it.
        home.homeModel.threads.removeAll { $0.id == first.threadID }
        let next = home.acceptInput("and this", contextKey: key)
        XCTAssertNotEqual(first.threadID, next.threadID)
    }
}

@MainActor
final class TalkObservedElementsTests: XCTestCase {
    func testSecureElementsAreFilteredOut() {
        let observation = GuideObservation(
            snapshot: AXSnapshot(
                appBundleID: "com.example",
                windowTitle: "Main",
                elements: [
                    AXElement(
                        stableID: "e1", role: .button, label: "Save",
                        frame: AXElementFrame(x: 10, y: 20, width: 80, height: 30),
                        isActionable: true
                    ),
                    AXElement(
                        stableID: "e2", role: .textField, label: "Password",
                        frame: AXElementFrame(x: 10, y: 60, width: 200, height: 30),
                        isActionable: true,
                        sensitivity: .secure
                    ),
                ]
            ),
            windowID: 42
        )
        let elements = observation.observedElements
        XCTAssertEqual(elements.map(\.id), ["e1"])
        XCTAssertEqual(elements.first?.windowID, 42)
        XCTAssertEqual(elements.first?.frame, CGRect(x: 10, y: 20, width: 80, height: 30))
    }
}

@MainActor
final class TalkSessionStateTests: XCTestCase {
    func testTalkLifecycle() throws {
        let controller = SessionController()
        let attemptID = UUID()
        try controller.wake(attemptID: attemptID)
        var talk = TalkSessionState(id: UUID(), startedAt: Date(), transcript: "")
        talk.isListening = true
        try controller.startTalk(talk, attemptID: attemptID)
        guard case .talking = controller.state else {
            return XCTFail("expected .talking")
        }
        controller.updateTalk { $0.transcript = "what is this" }
        guard case .talking(let live) = controller.state else {
            return XCTFail("expected .talking")
        }
        XCTAssertEqual(live.transcript, "what is this")
        try controller.completeDismissal()
        XCTAssertEqual(controller.state, .idle)
    }

    func testStartTalkRequiresInvocation() {
        let controller = SessionController()
        XCTAssertThrowsError(
            try controller.startTalk(TalkSessionState(id: UUID(), startedAt: Date(), transcript: ""), attemptID: UUID())
        )
    }

    func testUpdateTalkIsNoOpOutsideTalking() {
        let controller = SessionController()
        controller.updateTalk { $0.transcript = "ghost" }
        XCTAssertEqual(controller.state, .idle)
    }
}

final class InkAccentSamplerTests: XCTestCase {
    private func makeJPEG(gray: UInt8, size: Int = 64) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            pixels[i * 4] = gray
            pixels[i * 4 + 1] = gray
            pixels[i * 4 + 2] = gray
            pixels[i * 4 + 3] = 255
        }
        let image = pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
        let cgImage = try XCTUnwrap(image)
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testMintOnDarkTealOnLight() throws {
        // Window is 100×100 AX pts captured at 64×64 px; mark its center.
        let bounds = CGRect(x: 500, y: 300, width: 100, height: 100)
        let center = CGPoint(x: 550, y: 350)
        XCTAssertEqual(
            InkAccentSampler.accentHex(
                imageJPEG: try makeJPEG(gray: 20),
                elementCenterAX: center, windowBoundsAX: bounds
            ),
            InkColor.onDarkHex
        )
        XCTAssertEqual(
            InkAccentSampler.accentHex(
                imageJPEG: try makeJPEG(gray: 235),
                elementCenterAX: center, windowBoundsAX: bounds
            ),
            InkColor.onLightHex
        )
    }

    func testNilOnBadInputs() throws {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(InkAccentSampler.accentHex(
            imageJPEG: Data(), elementCenterAX: .zero, windowBoundsAX: bounds))
        XCTAssertNil(InkAccentSampler.accentHex(
            imageJPEG: try makeJPEG(gray: 128),
            elementCenterAX: .zero, windowBoundsAX: .zero))
    }
}

@MainActor
final class TalkCompletionTests: XCTestCase {
    private final class Input: TalkSpeechInput {
        let text: String
        init(_ text: String = "Explain this") { self.text = text }
        func start() async throws {}
        func finalize() async -> (transcript: String, words: [SpokenWord]) { (text, []) }
        func cancel() {}
    }

    private final class Output: TalkSpeechOutput, GuideSessionOutput, GuideSessionContext {
        private(set) var isSpeaking = false
        private var pending = 0
        /// Holds playback open so tests can act while speech is still "playing".
        var speechHeld = false { didSet { if !speechHeld && pending == 0 { isSpeaking = false } } }
        var stopped = 0
        func speak(_ sentence: String) {
            pending += 1
            isSpeaking = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(20))
                self.pending -= 1
                self.isSpeaking = self.pending > 0 || self.speechHeld
            }
        }
        func shutUp() { pending = 0; isSpeaking = false; stopped += 1 }
        func guideShowOverlay() {}
        func guideStopSpatialInput() {}
        func guideSetStatus(_ status: String) {}
        func guideSpeak(_ text: String, identity: GuideSpeechIdentity) {}
        func guidePlay(_ cue: SoundPlayer.Cue) {}
        func guidePresent(_ presentation: GuidePresentation) {}
        func guideSetBuddyState(_ state: PerryBuddyState) {}
        func guideInteractiveFrames() -> [CGRect] { [] }
        func guideShowFullPath(_ viewPlan: EverythingViewPlan) {}
        func guideClearPresentation() {}
        func guideClearFullPath() {}
        func guideTargetHint() -> CuaTargetHint { CuaTargetHint() }
        func guideAppBundleID(for targetHint: CuaTargetHint) -> String? { targetHint.bundleID }
        func guideSpatialRegionDescription() -> String? { nil }
    }

    private struct Provider: ModelProvider {
        let id: ProviderID = .codex
        let displayName = "Test"
        let capabilities: ModelCapabilities = [.vision, .streaming]
        let reason: ModelStopReason?
        func warm() async {}
        func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.textDelta("A partial answer. "))
                if let reason { continuation.yield(.done(reason)) }
                continuation.finish()
            }
        }
    }

    private func execution(provider: any ModelProvider) throws -> (HomeController, AgentCoordinator, ThreadStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ThreadStore(directory: root)
        let home = HomeController()
        home.threadStore = store
        let router = ProviderRouter(providers: [provider])
        let coordinator = AgentCoordinator(
            provider: { try await router.route($0).provider }, host: PerryToolHost(executors: []),
            threads: store, consent: ToolConsentStore(directory: nil)
        )
        return (home, coordinator, store)
    }

    private struct WaitingProvider: ModelProvider {
        let id: ProviderID = .codex
        let displayName = "Waiting"
        let capabilities: ModelCapabilities = [.vision, .streaming]
        let started: XCTestExpectation
        let cancelled: XCTestExpectation
        func warm() async {}
        func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.onTermination = { _ in cancelled.fulfill() }
                continuation.yield(.textDelta("The first answer. "))
                started.fulfill()
            }
        }
    }

    func testSpokenInputSurvivesCancellationWhileCaptureIsPending() async throws {
        let session = SessionController()
        let output = Output()
        let (home, coordinator, store) = try execution(provider: Provider(reason: .endTurn))
        let thread = try await store.upsert(PerryThread(draft: "Separate conversation draft"))
        home.homeModel.sidebarSelection = .thread(thread.id)
        home.homeModel.newConversationDraft = "Separate welcome draft"
        let capture = AsyncStream<Void>.makeStream()
        var dispatched = false
        let talk = TalkSession(
            sessionController: session, overlayState: PerryCursorState(), output: output,
            services: .init(makeInput: { Input("Keep my spoken request") }, output: output, capture: {
                for await _ in capture.stream { break }
                return GuideObservation(snapshot: AXSnapshot(appBundleID: "fixture.app", windowTitle: "Fixture", elements: []))
            }, acceptInput: { home.acceptInput($0, threadID: $1, contextKey: $2) }, run: {
                dispatched = true
                return home.runSpokenTurn($0, spatial: $1, coordinator: coordinator)
            }), tracer: PointerTraceRecorder(point: { .zero })
        )
        talk.keyDown()
        talk.holdCommitted()
        talk.keyUp()
        for _ in 0..<200 {
            if await store.thread(id: thread.id)?.waitingInputs?.first != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let saved = await store.thread(id: thread.id)
        XCTAssertEqual(saved?.waitingInputs?.map(\.text), ["Keep my spoken request"])
        XCTAssertEqual(saved?.draft, "Separate conversation draft")
        XCTAssertNil(saved?.pendingTurn)
        XCTAssertFalse(dispatched)
        talk.cancel()
        capture.continuation.finish()
        await home.joinInputSaves()
        XCTAssertFalse(dispatched)
        XCTAssertEqual(home.homeModel.newConversationDraft, "Separate welcome draft")
        let afterCancellation = await store.thread(id: thread.id)
        XCTAssertEqual(afterCancellation?.waitingInputs?.count, 1)
        XCTAssertTrue(afterCancellation?.turns.isEmpty == true)
    }

    func testReleaseKeepsListening250msBeforeFinalizing() async throws {
        final class TimedInput: TalkSpeechInput {
            var finalizedAt: ContinuousClock.Instant?
            func start() async throws {}
            func finalize() async -> (transcript: String, words: [SpokenWord]) {
                finalizedAt = .now
                return ("Explain this", [])
            }
            func cancel() {}
        }
        let input = TimedInput()
        let output = Output()
        let (home, coordinator, _) = try execution(provider: Provider(reason: .endTurn))
        let talk = TalkSession(
            sessionController: SessionController(), overlayState: PerryCursorState(), output: output,
            services: .init(makeInput: { input }, output: output, capture: {
                GuideObservation(snapshot: AXSnapshot(appBundleID: "com.example.Editor", windowTitle: "Document", elements: []))
            }, acceptInput: { home.acceptInput($0, threadID: $1, contextKey: $2) }, run: { home.runSpokenTurn($0, spatial: $1, coordinator: coordinator) }),
            tracer: PointerTraceRecorder(point: { .zero })
        )
        talk.keyDown()
        talk.holdCommitted()
        let released = ContinuousClock.now
        talk.keyUp()
        for _ in 0..<100 where input.finalizedAt == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let finalizedAt = try XCTUnwrap(input.finalizedAt)
        XCTAssertGreaterThanOrEqual(finalizedAt - released, .milliseconds(250))
        talk.cancel()
    }

    func testBargeInKeepsTheNewListeningSessionActive() async throws {
        let started = expectation(description: "First provider stream started")
        let cancelled = expectation(description: "First provider stream cancelled")
        let controller = SessionController()
        let overlay = PerryCursorState()
        let output = Output()
        let (home, coordinator, _) = try execution(provider: WaitingProvider(started: started, cancelled: cancelled))
        let talk = TalkSession(
            sessionController: controller, overlayState: overlay, output: output,
            services: .init(makeInput: { Input() }, output: output, capture: {
                GuideObservation(snapshot: AXSnapshot(appBundleID: "com.example.Editor", windowTitle: "Document", elements: []))
            }, acceptInput: { home.acceptInput($0, threadID: $1, contextKey: $2) }, run: { home.runSpokenTurn($0, spatial: $1, coordinator: coordinator) }),
            tracer: PointerTraceRecorder(point: { .zero })
        )
        var completed = 0
        talk.onTurnCompleted = { completed += 1 }
        talk.keyDown()
        talk.holdCommitted()
        talk.keyUp()
        await fulfillment(of: [started], timeout: 2)
        talk.keyDown()
        await fulfillment(of: [cancelled], timeout: 2)
        await Task.yield()
        XCTAssertEqual(talk.phase, .listening)
        XCTAssertEqual(overlay.voiceState, .listening)
        XCTAssertEqual(overlay.buddyState, .listening)
        XCTAssertFalse(output.isSpeaking)
        XCTAssertEqual(completed, 0)
        guard case .talking(let state) = controller.state else { return XCTFail("Expected Talk state") }
        XCTAssertTrue(state.isListening)
        XCTAssertFalse(state.isWorking)
        XCTAssertEqual(state.turnCount, 0)
        talk.cancel()
    }

    func testKeyPressDuringSpeechPlaybackBargesIn() async throws {
        let controller = SessionController()
        let overlay = PerryCursorState()
        let output = Output()
        output.speechHeld = true
        let talk = TalkSession(
            sessionController: controller, overlayState: overlay, output: output,
            services: .init(makeInput: { Input() }, output: output, capture: {
                GuideObservation(snapshot: AXSnapshot(appBundleID: "com.example.Editor", windowTitle: "Document", elements: []))
            }, acceptInput: { text, id, _ in
                .init(threadID: id ?? UUID(), request: .init(text: text), saved: Task {})
            }, run: { input, _ in
                (input.threadID, AsyncStream { continuation in
                    continuation.yield(.textDelta("Done. "))
                    continuation.yield(.finished(.completed))
                    continuation.finish()
                }, nil)
            }), tracer: PointerTraceRecorder(point: { .zero })
        )
        talk.keyDown()
        talk.holdCommitted()
        talk.keyUp()
        for _ in 0..<200 {
            if case .talking(let state) = controller.state, state.turnCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        talk.keyDown()
        XCTAssertEqual(output.stopped, 1)
        XCTAssertFalse(output.isSpeaking)
        XCTAssertEqual(talk.phase, .listening)
        output.speechHeld = false
        talk.cancel()
    }

    func testSpokenSaveFailureReleasesPresentationWithoutProviderWork() async throws {
        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: blocked)
        addTeardownBlock { try? FileManager.default.removeItem(at: blocked) }
        let store = ThreadStore(directory: blocked)
        let home = HomeController()
        home.threadStore = store
        home.homeModel.newConversationDraft = "Keep this separate draft"
        let coordinator = AgentCoordinator(provider: { _ in
            XCTFail("Saving the input must precede provider work")
            return Provider(reason: .endTurn)
        }, host: PerryToolHost(executors: []), threads: store, consent: ToolConsentStore(directory: nil))
        let observation = GuideObservation(snapshot: AXSnapshot(appBundleID: "com.example.Editor", windowTitle: "Document", elements: []))
        let stream = home.runSpokenTurn(home.acceptInput("Explain this"), spatial: .init(observation: observation, bindings: [], skill: nil), coordinator: coordinator).events
        guard case .thread(let id) = home.homeModel.sidebarSelection else { return XCTFail("Missing conversation") }
        home.homeModel.onStop?(id)
        var finish: AgentFinish?
        for await event in stream { if case .finished(let result) = event { finish = result } }
        guard case .failed = finish else { return XCTFail("Expected save failure") }
        XCTAssertEqual(home.homeModel.unsavedInputs.map(\.request.text), ["Explain this"])
        XCTAssertFalse(home.homeModel.unsavedInputs.first?.error.isEmpty ?? true)
        XCTAssertTrue(home.homeModel.pendingQuestions.isEmpty)
        XCTAssertTrue(home.homeModel.stoppingThreads.isEmpty)
        XCTAssertTrue(coordinator.runningThreads.isEmpty)
        XCTAssertEqual(home.homeModel.newConversationDraft, "Keep this separate draft")
    }

    func testFreshObservationInvalidatesOldInlineInkTargets() async throws {
        let controller = SessionController()
        let overlay = PerryCursorState()
        let output = Output()
        let finished = expectation(description: "Spoken answer finished")
        let talk = TalkSession(
            sessionController: controller, overlayState: overlay, output: output,
            services: .init(makeInput: { Input() }, output: output, capture: {
                GuideObservation(snapshot: AXSnapshot(appBundleID: "com.example.Editor", windowTitle: "Document", elements: [
                    AXElement(stableID: "save", role: .button, label: "Save", frame: AXElementFrame(x: 10, y: 20, width: 80, height: 30), isActionable: true)
                ]))
            }, acceptInput: { text, id, _ in
                .init(threadID: id ?? UUID(), request: .init(text: text), saved: Task {})
            }, run: { input, _ in
                (input.threadID, AsyncStream { continuation in
                    // The coordinator decodes inline markup once: clean text
                    // deltas plus .draw commands (Phase 2 item 6).
                    continuation.yield(.textDelta("Before Save. "))
                    continuation.yield(.draw(DrawCommand(verb: .ring, elementID: "e1", label: "Save")))
                    continuation.yield(.toolCallStarted(ToolCall(id: "refresh", name: "screen.observe", arguments: .object([:]))))
                    continuation.yield(.textDelta("After Moved. "))
                    continuation.yield(.finished(.completed))
                    continuation.finish()
                }, nil)
            }), tracer: PointerTraceRecorder(point: { .zero })
        )
        talk.onTurnCompleted = { finished.fulfill() }
        talk.keyDown()
        talk.holdCommitted()
        talk.keyUp()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(overlay.visualGuidanceOverlays.isEmpty)
        guard case .talking(let state) = controller.state else { return XCTFail("Expected Talk state") }
        XCTAssertEqual(state.answerText, "Before Save. After Moved. ")
        talk.cancel()
    }

    func testSpokenGuideWaitsForRetirementAndSurvivesTalkCleanup() async throws {
        for cancelWhileWaiting in [false, true] {
            let session = SessionController()
            let output = Output()
            let (home, coordinator, store) = try execution(provider: Provider(reason: .endTurn))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let observation = GuideObservation(snapshot: AXSnapshot(appBundleID: "fixture.editor", windowTitle: "Orchid", elements: []), processID: 42, windowID: 73)
            var captured = false
            let guide = GuideSessionCoordinator(
                sessionController: session, workers: CuaWorkerService(),
                transcriptStore: TranscriptStore(directory: root), memoryStore: MemoryStore(storageDirectory: root),
                output: output, context: output,
                fullGuideCaptureLoader: { _, target in
                    XCTAssertEqual(target, CuaTargetHint(bundleID: "fixture.editor", processID: 42, windowID: 73, windowTitle: "Orchid"))
                    captured = true
                    throw CocoaError(.fileReadUnknown)
                }, executionOwner: coordinator
            )
            let waiting = expectation(description: "Talk waits before Guide")
            let release = AsyncStream<Void>.makeStream()
            var turn = 0
            var guideTask: Task<AgentFinish, Never>?
            let talk = TalkSession(
                sessionController: session, overlayState: PerryCursorState(), output: output,
                services: .init(makeInput: {
                    turn += 1
                    return Input(turn == 1 ? "Explain this" : "show me everything for saving")
                }, output: output, capture: { observation },
                acceptInput: { home.acceptInput($0, threadID: $1, contextKey: $2) },
                run: { home.runSpokenTurn($0, spatial: $1, coordinator: coordinator) },
                waitForConversation: { id in
                    await coordinator.waitForCompletion(threadID: id)
                    waiting.fulfill()
                    for await _ in release.stream { break }
                }, guide: { input, spatial, full in
                    XCTAssertEqual(session.state, .idle)
                    XCTAssertTrue(coordinator.runningThreads.isEmpty)
                    guideTask = guide.startGuiding(goal: input.request.text, threadID: input.threadID, targetHint: spatial.target, full: full, waitingInput: input.request)
                }), tracer: PointerTraceRecorder(point: { .zero })
            )
            talk.keyDown()
            talk.holdCommitted()
            talk.keyUp()
            for _ in 0..<200 where talk.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
            guard case .talking(let first) = session.state else { return XCTFail("Missing Talk session") }
            let threadID = try XCTUnwrap(first.threadID)
            home.homeModel.sidebarSelection = .thread(UUID())
            talk.keyDown()
            talk.holdCommitted()
            talk.keyUp()
            await fulfillment(of: [waiting], timeout: 2)
            XCTAssertNil(guideTask)
            if cancelWhileWaiting { talk.cancel() }
            release.continuation.finish()
            for _ in 0..<200 where talk.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
            if cancelWhileWaiting {
                await Task.yield()
                XCTAssertNil(guideTask)
                XCTAssertFalse(captured)
            } else {
                let task = try XCTUnwrap(guideTask)
                let finish = await task.value
                guard case .failed = finish else { return XCTFail("Guide must run after Talk cleanup, not inherit cancellation") }
                XCTAssertTrue(captured)
            }
            let saved = await store.list()
            XCTAssertEqual(saved.count, 1)
            XCTAssertEqual(saved.first?.id, threadID)
            XCTAssertEqual(saved.first?.turns.count, cancelWhileWaiting ? 1 : 2)
            XCTAssertNil(saved.first?.pendingTurn)
            talk.cancel()
            guide.prepareForTermination()
            await guide.joinAfterWorkerShutdown()
        }
    }

    func testSpokenFollowUpWaitsForPreviousPresentationLifetime() async throws {
        let session = SessionController()
        let output = Output()
        let (home, coordinator, store) = try execution(provider: Provider(reason: .endTurn))
        let thread = try await store.upsert(PerryThread(draft: "Unrelated draft"))
        home.homeModel.sidebarSelection = .thread(thread.id)
        let release = AsyncStream<Void>.makeStream()
        var retired = false
        var requests = 0
        var completion: Task<Void, Never>?
        let talk = TalkSession(
            sessionController: session, overlayState: PerryCursorState(), output: output,
            services: .init(makeInput: { Input() }, output: output, capture: {
                GuideObservation(snapshot: AXSnapshot(appBundleID: "fixture.app", windowTitle: "Fixture", elements: []))
            }, acceptInput: { home.acceptInput($0, threadID: $1, contextKey: $2) }, run: { input, spatial in
                requests += 1
                XCTAssertEqual(input.threadID, thread.id)
                let run = home.runSpokenTurn(input, spatial: spatial, coordinator: coordinator)
                if requests > 1 {
                    XCTAssertTrue(retired, "Spoken follow-up outran presentation cleanup")
                    return run
                }
                completion = Task { @MainActor in
                    await run.completion?.value
                    for await _ in release.stream { break }
                    retired = true
                }
                return (run.threadID, run.events, completion)
            }), tracer: PointerTraceRecorder(point: { .zero })
        )
        talk.keyDown()
        talk.holdCommitted()
        talk.keyUp()
        for _ in 0..<200 where talk.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(requests, 1)
        talk.keyDown()
        talk.holdCommitted()
        talk.keyUp()
        for _ in 0..<200 {
            if await store.thread(id: thread.id)?.waitingInputs?.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(requests, 1)
        let waiting = await store.thread(id: thread.id)
        XCTAssertEqual(waiting?.waitingInputs?.map(\.text), ["Explain this"])
        XCTAssertEqual(waiting?.draft, "Unrelated draft")
        XCTAssertEqual(waiting?.turns.count, 1)
        release.continuation.finish()
        for _ in 0..<200 where talk.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(requests, 2)
        guard case .talking(let state) = session.state else { return XCTFail("Missing Talk") }
        XCTAssertEqual(state.turnCount, 2)
        let finished = await store.thread(id: thread.id)
        XCTAssertTrue(finished?.waitingInputs?.isEmpty == true)
        XCTAssertEqual(finished?.draft, "Unrelated draft")
        talk.cancel()
        await completion?.value
    }

    func testTalkFollowUpRetainsConversationWhenHomeSelectionChanges() async throws {
        let controller = SessionController()
        let output = Output()
        let (home, coordinator, store) = try execution(provider: Provider(reason: .endTurn))
        let talk = TalkSession(
            sessionController: controller, overlayState: PerryCursorState(), output: output,
            services: .init(makeInput: { Input() }, output: output, capture: {
                GuideObservation(snapshot: AXSnapshot(appBundleID: "com.example.Editor", windowTitle: "Document", elements: []))
            }, acceptInput: { home.acceptInput($0, threadID: $1, contextKey: $2) }, run: { home.runSpokenTurn($0, spatial: $1, coordinator: coordinator) }),
            tracer: PointerTraceRecorder(point: { .zero })
        )
        var originalID: UUID?
        for count in 1...2 {
            talk.keyDown()
            talk.holdCommitted()
            talk.keyUp()
            for _ in 0..<200 where talk.phase != .idle {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(talk.phase, .idle)
            guard case .talking(let state) = controller.state else { return XCTFail("Missing Talk session") }
            let threadID = try XCTUnwrap(state.threadID)
            if let originalID { XCTAssertEqual(threadID, originalID) } else { originalID = threadID }
            XCTAssertEqual(state.turnCount, count)
            let saved = await store.list()
            XCTAssertEqual(saved.count, 1)
            XCTAssertEqual(saved.first?.turns.count, count)
            home.homeModel.sidebarSelection = .thread(UUID())
        }
        talk.cancel()
    }

    func testOnlyCompletedAnswersAdvanceTalkAndOnboarding() async throws {
        let reasons: [ModelStopReason?] = [nil, .maxTokens, .cancelled, .other("incomplete"), .toolUse, .endTurn]
        for reason in reasons {
            let controller = SessionController()
            let overlay = PerryCursorState()
            let output = Output()
            let (home, coordinator, store) = try execution(provider: Provider(reason: reason))
            let talk = TalkSession(
                sessionController: controller, overlayState: overlay, output: output,
                services: .init(makeInput: { Input() }, output: output, capture: {
                    GuideObservation(snapshot: AXSnapshot(appBundleID: "com.example.Editor", windowTitle: "Document", elements: []), processID: 42, windowID: 7)
                }, acceptInput: { home.acceptInput($0, threadID: $1, contextKey: $2) }, run: { home.runSpokenTurn($0, spatial: $1, coordinator: coordinator) }),
                tracer: PointerTraceRecorder(point: { .zero })
            )
            var completed = 0
            talk.onTurnCompleted = { completed += 1 }
            talk.keyDown()
            talk.holdCommitted()
            talk.keyUp()
            for _ in 0..<200 where talk.phase != .idle {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(talk.phase, .idle)
            guard case .talking(let state) = controller.state else { return XCTFail("Expected Talk state") }
            let succeeded = reason == .endTurn
            XCTAssertEqual(completed, succeeded ? 1 : 0)
            XCTAssertEqual(state.turnCount, succeeded ? 1 : 0)
            XCTAssertFalse(state.isWorking)
            XCTAssertEqual(state.transcript, "Explain this")
            XCTAssertTrue(state.answerText?.contains("partial answer") == true)
            guard case .thread(let id) = home.homeModel.sidebarSelection else { return XCTFail("Missing shared conversation") }
            let saved = await store.thread(id: id)
            XCTAssertEqual(saved?.turns.count, 1)
            XCTAssertEqual(saved?.turns.last?.outcome, succeeded ? .completed : (reason == .cancelled ? .interrupted : .failed))
            XCTAssertEqual(saved?.draft, succeeded ? "" : "Explain this")
            XCTAssertEqual(home.homeModel.threads.first?.id, id)
            if !succeeded {
                XCTAssertNotEqual(overlay.buddyState, .success)
                XCTAssertFalse(output.isSpeaking)
            }
            talk.cancel()
        }
    }
}

@MainActor
final class TalkClickToTalkTests: XCTestCase {
    private final class FakeInput: VoiceConversationInput {
        var onTranscript: (String) -> Void = { _ in }
        var onPartial: (String) -> Void = { _ in }
        var onLevel: (TimeInterval, Double) -> Void = { _, _ in }
        var onFailure: (Error) -> Void = { _ in }
        var startError: Error?
        private(set) var startCalls = 0
        private(set) var finishCalls = 0
        private(set) var cancelCalls = 0

        func start() throws {
            startCalls += 1
            if let startError { throw startError }
        }

        func finish() { finishCalls += 1 }
        func cancel() { cancelCalls += 1 }
    }

    @MainActor
    private final class FakeOutput: TalkSpeechOutput {
        var isSpeaking = false
        let probe: Probe

        init(probe: Probe) {
            self.probe = probe
        }

        func speak(_ sentence: String) { probe.spoken.append(sentence) }
        func shutUp() { probe.shutUps += 1 }
    }

    private final class Probe {
        let threadID = UUID()
        var inputs: [FakeInput] = []
        var runs: [String] = []
        var stopped: [UUID] = []
        var spoken: [String] = []
        var shutUps = 0
        var clock: TimeInterval = 100
        var pending: AsyncStream<AgentLoopEvent>.Continuation?
    }

    private final class GuideOutputStub: GuideSessionOutput {
        func guideShowOverlay() {}
        func guideStopSpatialInput() {}
        func guideSetStatus(_ status: String) {}
        func guideSpeak(_ text: String, identity: GuideSpeechIdentity) {}
        func guidePlay(_ cue: SoundPlayer.Cue) {}
        func guidePresent(_ presentation: GuidePresentation) {}
        func guideSetBuddyState(_ state: PerryBuddyState) {}
        func guideInteractiveFrames() -> [CGRect] { [] }
        func guideShowFullPath(_ viewPlan: EverythingViewPlan) {}
        func guideClearPresentation() {}
        func guideClearFullPath() {}
    }

    private final class HoldInput: TalkSpeechInput {
        func start() async throws {}
        func finalize() async -> (transcript: String, words: [SpokenWord]) { ("", []) }
        func cancel() {}
    }

    private func makeSession(
        probe: Probe,
        permission: @escaping () async -> Bool = { true },
        silenceTimeout: TimeInterval = 0.2,
        events: @escaping (AsyncStream<AgentLoopEvent>.Continuation) -> Void = { continuation in
            continuation.yield(.finished(.completed))
            continuation.finish()
        }
    ) -> TalkSession {
        let output = FakeOutput(probe: probe)
        return TalkSession(
            sessionController: SessionController(),
            overlayState: PerryCursorState(),
            output: GuideOutputStub(),
            services: .init(
                makeInput: { HoldInput() },
                output: output,
                capture: { throw CancellationError() },
                acceptInput: { text, _, _ in
                    .init(threadID: probe.threadID, request: .init(text: text), saved: Task {})
                },
                run: { input, _ in
                    probe.runs.append(input.request.text)
                    return (
                        threadID: input.threadID,
                        events: AsyncStream<AgentLoopEvent> { continuation in
                            probe.pending = continuation
                            events(continuation)
                        },
                        completion: nil
                    )
                },
                requestPermission: permission,
                makeClickInput: { onTranscript, onPartial, onLevel, onFailure in
                    let input = FakeInput()
                    input.onTranscript = onTranscript
                    input.onPartial = onPartial
                    input.onLevel = onLevel
                    input.onFailure = onFailure
                    probe.inputs.append(input)
                    return input
                },
                stop: { probe.stopped.append($0) },
                speechDrain: {},
                now: { probe.clock },
                silenceTimeout: silenceTimeout,
                finalTranscriptTimeout: 0.2
            )
        )
    }

    func testNewConversationClearsOldTurnAndRejectsLateAnswer() async {
        let probe = Probe()
        let session = makeSession(probe: probe, events: { _ in })
        session.startClick()
        await waitUntil { session.clickState == .listening }
        probe.inputs[0].onTranscript("First question")
        await waitUntil { probe.runs.count == 1 }
        probe.pending?.yield(.textDelta("First answer."))
        await waitUntil { !session.answer.isEmpty }
        session.resetConversation()
        probe.pending?.yield(.textDelta("Late answer."))
        probe.pending?.finish()
        await Task.yield()
        XCTAssertEqual(session.clickState, .idle)
        XCTAssertEqual(session.transcript, "")
        XCTAssertEqual(session.answer, "")
        XCTAssertNil(session.error)
        XCTAssertEqual(probe.stopped, [probe.threadID])
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 where !predicate() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    func testCancelDuringPermissionAwaitNeverStartsRecording() async {
        let probe = Probe()
        var permissionRequested = false
        var permissionContinuation: CheckedContinuation<Bool, Never>?
        let session = makeSession(probe: probe, permission: {
            permissionRequested = true
            return await withCheckedContinuation { permissionContinuation = $0 }
        })
        session.startClick()
        XCTAssertEqual(session.clickState, .requestingPermission)
        await waitUntil { permissionRequested }

        session.cancelClick()
        permissionContinuation?.resume(returning: true)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(session.clickState, .idle)
        XCTAssertEqual(probe.inputs.count, 1)
        XCTAssertEqual(probe.inputs[0].startCalls, 0)
        XCTAssertEqual(probe.inputs[0].cancelCalls, 1)
        XCTAssertTrue(probe.runs.isEmpty)
    }

    func testPermissionDenialCanRecoverWithoutReusingCapture() async {
        let probe = Probe()
        var granted = false
        let session = makeSession(probe: probe, permission: { granted })
        session.startClick()
        await waitUntil { session.clickState == .failed }
        XCTAssertEqual(probe.inputs[0].startCalls, 0)
        XCTAssertEqual(probe.inputs[0].cancelCalls, 1)
        XCTAssertNotNil(session.error)
        XCTAssertTrue(probe.runs.isEmpty)

        granted = true
        session.startClick()
        await waitUntil { session.clickState == .listening }
        XCTAssertEqual(probe.inputs.count, 2)
        XCTAssertEqual(probe.inputs[1].startCalls, 1)
        XCTAssertNil(session.error)
        probe.inputs[0].onTranscript("Stale capture")
        probe.inputs[1].onTranscript("Try again")
        await waitUntil { session.clickState == .idle }
        XCTAssertEqual(probe.runs, ["Try again"])
    }

    func testDeliversAtMostOneSubmissionPerCapture() async {
        let probe = Probe()
        var completions = 0
        let session = makeSession(probe: probe)
        session.onTurnCompleted = { completions += 1 }
        session.startClick()
        await waitUntil { session.clickState == .listening }
        let input = probe.inputs[0]
        input.onPartial("hello")
        await waitUntil { session.transcript == "hello" }

        input.onTranscript("hello there")
        input.onTranscript("hello there again")

        await waitUntil { session.clickState == .idle }
        XCTAssertEqual(probe.runs.count, 1)
        XCTAssertEqual(completions, 1)
    }

    private func hear(_ input: FakeInput, probe: Probe, seconds: Double, rms: Double) async {
        for _ in 0..<Int((seconds / 0.02).rounded()) {
            probe.clock += 0.02
            input.onLevel(probe.clock, rms)
        }
        for _ in 0..<5 { await Task.yield() }
    }

    func testSilenceAfterAClearQuestionEndsTheTurn() async {
        let probe = Probe()
        let session = makeSession(probe: probe, silenceTimeout: 30)
        session.startClick()
        await waitUntil { session.clickState == .listening }
        let input = probe.inputs[0]

        await hear(input, probe: probe, seconds: 0.4, rms: 0.001)
        await hear(input, probe: probe, seconds: 0.8, rms: 0.05)
        input.onPartial("What time is it in Tokyo?")
        await waitUntil { session.transcript == "What time is it in Tokyo?" }
        await hear(input, probe: probe, seconds: 0.4, rms: 0.001)
        XCTAssertEqual(input.finishCalls, 0)
        await hear(input, probe: probe, seconds: 0.2, rms: 0.001)
        await waitUntil { input.finishCalls == 1 }
        input.onTranscript("What time is it in Tokyo?")

        await waitUntil { probe.runs.count == 1 }
        XCTAssertEqual(probe.runs, ["What time is it in Tokyo?"])
    }

    func testFillerPauseKeepsListeningUntilTheSentenceEnds() async {
        let probe = Probe()
        let session = makeSession(probe: probe, silenceTimeout: 30)
        session.startClick()
        await waitUntil { session.clickState == .listening }
        let input = probe.inputs[0]

        await hear(input, probe: probe, seconds: 0.4, rms: 0.001)
        await hear(input, probe: probe, seconds: 0.8, rms: 0.05)
        input.onPartial("Open my notes and um")
        await waitUntil { session.transcript == "Open my notes and um" }
        await hear(input, probe: probe, seconds: 1.0, rms: 0.001)
        XCTAssertEqual(session.clickState, .listening)
        XCTAssertEqual(input.finishCalls, 0)

        await hear(input, probe: probe, seconds: 0.6, rms: 0.05)
        input.onPartial("Open my notes and um the budget one.")
        await waitUntil { session.transcript == "Open my notes and um the budget one." }
        await hear(input, probe: probe, seconds: 1.0, rms: 0.001)
        await waitUntil { input.finishCalls == 1 }
    }

    func testInputThatGoesQuietAfterFinishStillSettles() async {
        let probe = Probe()
        let session = makeSession(probe: probe, silenceTimeout: 30)
        session.startClick()
        await waitUntil { session.clickState == .listening }
        let input = probe.inputs[0]
        await hear(input, probe: probe, seconds: 0.4, rms: 0.001)
        await hear(input, probe: probe, seconds: 0.6, rms: 0.05)
        input.onPartial("Open my notes.")
        await waitUntil { session.transcript == "Open my notes." }
        await hear(input, probe: probe, seconds: 1.0, rms: 0.001)
        await waitUntil { input.finishCalls == 1 }

        await waitUntil { probe.runs.count == 1 }

        XCTAssertEqual(probe.runs, ["Open my notes."])
    }

    func testSendNowSubmitsSpeechButDiscardsSilence() async {
        let probe = Probe()
        let session = makeSession(probe: probe, silenceTimeout: 30)
        session.startClick()
        await waitUntil { session.clickState == .listening }
        session.sendNow()
        XCTAssertEqual(session.clickState, .idle)
        XCTAssertEqual(probe.inputs[0].cancelCalls, 1)

        session.startClick()
        await waitUntil { session.clickState == .listening }
        probe.inputs[1].onPartial("Open my notes")
        await waitUntil { session.transcript == "Open my notes" }
        session.sendNow()
        XCTAssertEqual(session.clickState, .thinking)
        XCTAssertEqual(probe.inputs[1].finishCalls, 1)
        await waitUntil { probe.runs == ["Open my notes"] }
    }

    func testMetersFollowTheVoiceAndTheEndingSilence() async {
        let probe = Probe()
        let session = makeSession(probe: probe, silenceTimeout: 30)
        session.startClick()
        await waitUntil { session.clickState == .listening }
        let input = probe.inputs[0]
        await hear(input, probe: probe, seconds: 0.4, rms: 0.001)
        await hear(input, probe: probe, seconds: 0.6, rms: 0.05)
        XCTAssertGreaterThan(session.level, 0.5)
        XCTAssertEqual(session.endProgress, 0)
        input.onPartial("Open my notes")
        await waitUntil { session.transcript == "Open my notes" }
        await hear(input, probe: probe, seconds: 0.5, rms: 0.001)
        XCTAssertLessThan(session.level, 0.2)
        XCTAssertEqual(session.endProgress, 0.47, accuracy: 0.05)
    }

    func testReturnSendsAndEscapeCancelsInTheListeningView() async throws {
        for (key, code) in [("\r", UInt16(36)), ("\u{1b}", UInt16(53))] {
            let probe = Probe()
            let session = makeSession(probe: probe, silenceTimeout: 30)
            session.startClick()
            await waitUntil { session.clickState == .listening }
            probe.inputs[0].onPartial("Open my notes")
            await waitUntil { session.transcript == "Open my notes" }
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: NotchListeningView(voice: session))
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code
            ))
            window.sendEvent(event)
            await waitUntil { session.clickState != .listening }
            if code == 36 {
                XCTAssertEqual(probe.inputs[0].finishCalls, 1)
            } else {
                XCTAssertEqual(session.clickState, .idle)
                XCTAssertEqual(probe.inputs[0].cancelCalls, 1)
            }
        }
    }

    func testNoSpeechEndsListeningWithActionableError() async {
        let probe = Probe()
        let session = makeSession(probe: probe, silenceTimeout: 30)
        session.startClick()
        await waitUntil { session.clickState == .listening }

        await hear(probe.inputs[0], probe: probe, seconds: 8.1, rms: 0.001)

        await waitUntil { session.clickState == .failed }
        XCTAssertEqual(probe.inputs[0].cancelCalls, 1)
        XCTAssertNotNil(session.error)
        XCTAssertTrue(probe.runs.isEmpty)
    }

    func testSilenceTimeoutStopsListeningWithActionableError() async {
        let probe = Probe()
        let session = makeSession(probe: probe)
        session.startClick()
        await waitUntil { session.clickState == .listening }

        await waitUntil { session.clickState == .failed }

        XCTAssertEqual(probe.inputs[0].cancelCalls, 1)
        XCTAssertNotNil(session.error)
        XCTAssertTrue(probe.runs.isEmpty)
    }

    func testCancelAfterPartialStopsCaptureAndRejectsFinalTranscript() async {
        let probe = Probe()
        let session = makeSession(probe: probe)
        session.startClick()
        await waitUntil { session.clickState == .listening }
        let input = probe.inputs[0]
        input.onPartial("unfinished request")
        await waitUntil { session.transcript == "unfinished request" }

        session.cancelClick()
        input.onTranscript("unfinished request completed late")
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(session.clickState, .idle)
        XCTAssertEqual(input.cancelCalls, 1)
        XCTAssertEqual(input.finishCalls, 0)
        XCTAssertTrue(probe.runs.isEmpty)
        XCTAssertNil(session.error)
    }

    func testFailedRunCanBeRetried() async {
        let probe = Probe()
        var succeed = false
        let session = makeSession(probe: probe, events: { continuation in
            if succeed { continuation.yield(.textDelta("Done. ")) }
            continuation.yield(.finished(succeed ? .completed : .failed("No model.")))
            continuation.finish()
        })
        session.startClick()
        await waitUntil { session.clickState == .listening }
        probe.inputs[0].onTranscript("first")
        await waitUntil { session.clickState == .failed }
        XCTAssertEqual(session.error, "No model.")

        succeed = true
        session.startClick()
        await waitUntil { session.clickState == .listening }
        probe.inputs[1].onTranscript("second")

        await waitUntil { session.clickState == .idle }
        XCTAssertEqual(probe.runs, ["first", "second"])
        XCTAssertEqual(probe.spoken, ["Done."])
        XCTAssertNil(session.error)
    }

    func testCancelDuringTurnStopsProviderAndBlocksLateSpeech() async {
        let probe = Probe()
        var completions = 0
        let session = makeSession(probe: probe, events: { continuation in
            continuation.yield(.textDelta("Working. "))
        })
        session.onTurnCompleted = { completions += 1 }
        session.startClick()
        await waitUntil { session.clickState == .listening }
        probe.inputs[0].onTranscript("do it")
        await waitUntil { probe.spoken == ["Working."] }

        session.cancelClick()

        XCTAssertEqual(session.clickState, .idle)
        XCTAssertEqual(probe.stopped, [probe.threadID])
        XCTAssertEqual(probe.shutUps, 1)

        probe.pending?.yield(.textDelta("Late. "))
        probe.pending?.yield(.finished(.completed))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(probe.spoken, ["Working."])
        XCTAssertEqual(completions, 0)
    }
}

@MainActor
final class NotchListeningPresentationTests: XCTestCase {
    func testListeningKeepsTheNotchOpenUntilTheTurnEnds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = AppController.testing(directory: directory)
        let presentation = NotchPresentation.shared
        for entry in presentation.entries { presentation.remove(entry.id) }
        defer {
            for entry in presentation.entries { presentation.remove(entry.id) }
            controller.collapseNotch()
            try? FileManager.default.removeItem(at: directory)
        }

        controller.presentConversationVoice(.listening)
        XCTAssertEqual(presentation.current?.id, AppController.voiceEntryID)
        XCTAssertEqual(presentation.current?.priority, .voice)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(controller.sessionPanel.isVisible)

        controller.presentConversationVoice(.thinking)
        controller.presentConversationVoice(.speaking)
        XCTAssertTrue(presentation.contains(AppController.voiceEntryID))
        XCTAssertTrue(controller.sessionPanel.isVisible)

        controller.presentConversationVoice(.idle)
        XCTAssertFalse(presentation.contains(AppController.voiceEntryID))
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(controller.sessionPanel.isVisible)
    }
}
