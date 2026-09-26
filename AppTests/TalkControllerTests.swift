import XCTest
import PerryBrain
import PerryGuide
import PerryOverlay
@testable import Perry

@MainActor
final class ModifierHoldMonitorTests: XCTestCase {
    private func makeMonitor() -> (ModifierHoldMonitor, CallLog) {
        let log = CallLog()
        let monitor = ModifierHoldMonitor(
            onHoldStart: { log.starts += 1 },
            onHoldEnd: { log.ends += 1 },
            onComposer: { log.composers += 1 }
        )
        return (monitor, log)
    }

    final class CallLog {
        var starts = 0
        var ends = 0
        var composers = 0
    }

    func testHoldStartsOnControlOptionAndEndsOnRelease() {
        let (monitor, log) = makeMonitor()
        monitor.handle(timestamp: 1.0, control: true, option: true, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.1, control: true, option: true, isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.starts, 1)
        monitor.handle(timestamp: 1.2, control: false, option: true, isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.ends, 1)
    }

    func testBareOptionOrControlAloneDoesNotHold() {
        let (monitor, log) = makeMonitor()
        monitor.handle(timestamp: 1.0, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.1, control: false, option: false, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.2, control: false, option: true, isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.starts, 0)
        XCTAssertEqual(log.ends, 0)
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

    func testTapDisabledEndsHold() {
        let (monitor, log) = makeMonitor()
        monitor.handle(timestamp: 1.0, control: true, option: true, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.1, control: true, option: true, isFlagsChanged: false, tapDisabled: true)
        XCTAssertEqual(log.ends, 1)
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
}

@MainActor
final class TalkContextStoreTests: XCTestCase {
    private let key = TalkContextKey(processID: 7, windowID: 9)

    func testConversationPersistsWithinTTL() throws {
        var now: TimeInterval = 1000
        let store = TalkContextStore(now: { now })
        var conversation = store.conversation(for: key)
        try conversation.append(
            question: "what is this",
            answer: SpatialAnswer(text: "a button", references: [], followUp: nil, observationID: "o1")
        )
        store.update(key, conversation: conversation)
        now += 120
        XCTAssertEqual(store.conversation(for: key).turns.count, 1)
    }

    func testConversationExpiresAfterTTL() throws {
        var now: TimeInterval = 1000
        let store = TalkContextStore(now: { now }, ttl: 600)
        var conversation = store.conversation(for: key)
        try conversation.append(
            question: "what is this",
            answer: SpatialAnswer(text: "a button", references: [], followUp: nil, observationID: "o1")
        )
        store.update(key, conversation: conversation)
        now += 601
        XCTAssertTrue(store.conversation(for: key).turns.isEmpty)
    }

    func testResetPhraseClearsContext() throws {
        let store = TalkContextStore()
        var conversation = store.conversation(for: key)
        try conversation.append(
            question: "what is this",
            answer: SpatialAnswer(text: "a button", references: [], followUp: nil, observationID: "o1")
        )
        store.update(key, conversation: conversation)
        XCTAssertTrue(TalkContextStore.isResetPhrase("new topic: tell me about that"))
        store.reset(key)
        XCTAssertTrue(store.conversation(for: key).turns.isEmpty)
    }

    func testKeysAreIndependent() throws {
        let store = TalkContextStore()
        let other = TalkContextKey(processID: 8, windowID: 9)
        var conversation = store.conversation(for: key)
        try conversation.append(
            question: "hi",
            answer: SpatialAnswer(text: "hello", references: [], followUp: nil, observationID: "o1")
        )
        store.update(key, conversation: conversation)
        XCTAssertTrue(store.conversation(for: other).turns.isEmpty)
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
        let elements = TalkSession.observedElements(of: observation)
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
