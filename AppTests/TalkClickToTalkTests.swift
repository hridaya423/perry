import AppKit
import class SwiftUI.NSHostingView
import XCTest
import PerryBrain
import PerryCore
import PerryGuide
import PerryOverlay
@testable import Perry

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
