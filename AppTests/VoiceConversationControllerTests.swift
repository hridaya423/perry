import AppKit
import SwiftUI
import XCTest
import PerryBrain
@testable import Perry

@MainActor
final class VoiceConversationControllerTests: XCTestCase {
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

    private func makeController(
        probe: Probe,
        permission: @escaping () async -> Bool = { true },
        silenceTimeout: TimeInterval = 0.2,
        events: @escaping (AsyncStream<AgentLoopEvent>.Continuation) -> Void = { continuation in
            continuation.yield(.finished(.completed))
            continuation.finish()
        }
    ) -> VoiceConversationController {
        VoiceConversationController(services: .init(
            requestPermission: permission,
            makeInput: { onTranscript, onPartial, onLevel, onFailure in
                let input = FakeInput()
                input.onTranscript = onTranscript
                input.onPartial = onPartial
                input.onLevel = onLevel
                input.onFailure = onFailure
                probe.inputs.append(input)
                return input
            },
            run: { text in
                probe.runs.append(text)
                return (
                    threadID: probe.threadID,
                    events: AsyncStream<AgentLoopEvent> { continuation in
                        probe.pending = continuation
                        events(continuation)
                    },
                    completion: nil
                )
            },
            stop: { probe.stopped.append($0) },
            output: FakeOutput(probe: probe),
            speechDrain: {},
            now: { probe.clock },
            silenceTimeout: silenceTimeout,
            finalTranscriptTimeout: 0.2
        ))
    }

    func testNewConversationClearsOldTurnAndRejectsLateAnswer() async {
        let probe = Probe()
        let controller = makeController(probe: probe, events: { _ in })
        controller.start()
        await waitUntil { controller.state == .listening }
        probe.inputs[0].onTranscript("First question")
        await waitUntil { probe.runs.count == 1 }
        probe.pending?.yield(.textDelta("First answer."))
        await waitUntil { !controller.answer.isEmpty }
        controller.resetConversation()
        probe.pending?.yield(.textDelta("Late answer."))
        probe.pending?.finish()
        await Task.yield()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.transcript, "")
        XCTAssertEqual(controller.answer, "")
        XCTAssertNil(controller.error)
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
        let controller = makeController(probe: probe, permission: {
            permissionRequested = true
            return await withCheckedContinuation { permissionContinuation = $0 }
        })
        controller.start()
        XCTAssertEqual(controller.state, .requestingPermission)
        await waitUntil { permissionRequested }

        controller.cancel()
        permissionContinuation?.resume(returning: true)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(probe.inputs.count, 1)
        XCTAssertEqual(probe.inputs[0].startCalls, 0)
        XCTAssertEqual(probe.inputs[0].cancelCalls, 1)
        XCTAssertTrue(probe.runs.isEmpty)
    }

    func testPermissionDenialCanRecoverWithoutReusingCapture() async {
        let probe = Probe()
        var granted = false
        let controller = makeController(probe: probe, permission: { granted })
        controller.start()
        await waitUntil { controller.state == .failed }
        XCTAssertEqual(probe.inputs[0].startCalls, 0)
        XCTAssertEqual(probe.inputs[0].cancelCalls, 1)
        XCTAssertNotNil(controller.error)
        XCTAssertTrue(probe.runs.isEmpty)

        granted = true
        controller.start()
        await waitUntil { controller.state == .listening }
        XCTAssertEqual(probe.inputs.count, 2)
        XCTAssertEqual(probe.inputs[1].startCalls, 1)
        XCTAssertNil(controller.error)
        probe.inputs[0].onTranscript("Stale capture")
        probe.inputs[1].onTranscript("Try again")
        await waitUntil { controller.state == .idle }
        XCTAssertEqual(probe.runs, ["Try again"])
    }

    func testDeliversAtMostOneSubmissionPerCapture() async {
        let probe = Probe()
        var completions = 0
        let controller = makeController(probe: probe)
        controller.onTurnCompleted = { completions += 1 }
        controller.start()
        await waitUntil { controller.state == .listening }
        let input = probe.inputs[0]
        input.onPartial("hello")
        await waitUntil { controller.transcript == "hello" }

        input.onTranscript("hello there")
        input.onTranscript("hello there again")

        await waitUntil { controller.state == .idle }
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
        let controller = makeController(probe: probe, silenceTimeout: 30)
        controller.start()
        await waitUntil { controller.state == .listening }
        let input = probe.inputs[0]

        await hear(input, probe: probe, seconds: 0.4, rms: 0.001)
        await hear(input, probe: probe, seconds: 0.8, rms: 0.05)
        input.onPartial("What time is it in Tokyo?")
        await waitUntil { controller.transcript == "What time is it in Tokyo?" }
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
        let controller = makeController(probe: probe, silenceTimeout: 30)
        controller.start()
        await waitUntil { controller.state == .listening }
        let input = probe.inputs[0]

        await hear(input, probe: probe, seconds: 0.4, rms: 0.001)
        await hear(input, probe: probe, seconds: 0.8, rms: 0.05)
        input.onPartial("Open my notes and um")
        await waitUntil { controller.transcript == "Open my notes and um" }
        await hear(input, probe: probe, seconds: 1.0, rms: 0.001)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(input.finishCalls, 0)

        await hear(input, probe: probe, seconds: 0.6, rms: 0.05)
        input.onPartial("Open my notes and um the budget one.")
        await waitUntil { controller.transcript == "Open my notes and um the budget one." }
        await hear(input, probe: probe, seconds: 1.0, rms: 0.001)
        await waitUntil { input.finishCalls == 1 }
    }

    func testInputThatGoesQuietAfterFinishStillSettles() async {
        let probe = Probe()
        let controller = makeController(probe: probe, silenceTimeout: 30)
        controller.start()
        await waitUntil { controller.state == .listening }
        let input = probe.inputs[0]
        await hear(input, probe: probe, seconds: 0.4, rms: 0.001)
        await hear(input, probe: probe, seconds: 0.6, rms: 0.05)
        input.onPartial("Open my notes.")
        await waitUntil { controller.transcript == "Open my notes." }
        await hear(input, probe: probe, seconds: 1.0, rms: 0.001)
        await waitUntil { input.finishCalls == 1 }

        await waitUntil { probe.runs.count == 1 }

        XCTAssertEqual(probe.runs, ["Open my notes."])
    }

    func testSendNowSubmitsSpeechButDiscardsSilence() async {
        let probe = Probe()
        let controller = makeController(probe: probe, silenceTimeout: 30)
        controller.start()
        await waitUntil { controller.state == .listening }
        controller.sendNow()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(probe.inputs[0].cancelCalls, 1)

        controller.start()
        await waitUntil { controller.state == .listening }
        probe.inputs[1].onPartial("Open my notes")
        await waitUntil { controller.transcript == "Open my notes" }
        controller.sendNow()
        XCTAssertEqual(controller.state, .thinking)
        XCTAssertEqual(probe.inputs[1].finishCalls, 1)
        await waitUntil { probe.runs == ["Open my notes"] }
    }

    func testMetersFollowTheVoiceAndTheEndingSilence() async {
        let probe = Probe()
        let controller = makeController(probe: probe, silenceTimeout: 30)
        controller.start()
        await waitUntil { controller.state == .listening }
        let input = probe.inputs[0]
        await hear(input, probe: probe, seconds: 0.4, rms: 0.001)
        await hear(input, probe: probe, seconds: 0.6, rms: 0.05)
        XCTAssertGreaterThan(controller.level, 0.5)
        XCTAssertEqual(controller.endProgress, 0)
        input.onPartial("Open my notes")
        await waitUntil { controller.transcript == "Open my notes" }
        await hear(input, probe: probe, seconds: 0.5, rms: 0.001)
        XCTAssertLessThan(controller.level, 0.2)
        XCTAssertEqual(controller.endProgress, 0.47, accuracy: 0.05)
    }

    func testReturnSendsAndEscapeCancelsInTheListeningView() async throws {
        for (key, code) in [("\r", UInt16(36)), ("\u{1b}", UInt16(53))] {
            let probe = Probe()
            let controller = makeController(probe: probe, silenceTimeout: 30)
            controller.start()
            await waitUntil { controller.state == .listening }
            probe.inputs[0].onPartial("Open my notes")
            await waitUntil { controller.transcript == "Open my notes" }
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: NotchListeningView(voice: controller))
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code
            ))
            window.sendEvent(event)
            await waitUntil { controller.state != .listening }
            if code == 36 {
                XCTAssertEqual(probe.inputs[0].finishCalls, 1)
            } else {
                XCTAssertEqual(controller.state, .idle)
                XCTAssertEqual(probe.inputs[0].cancelCalls, 1)
            }
        }
    }

    func testNoSpeechEndsListeningWithActionableError() async {
        let probe = Probe()
        let controller = makeController(probe: probe, silenceTimeout: 30)
        controller.start()
        await waitUntil { controller.state == .listening }

        await hear(probe.inputs[0], probe: probe, seconds: 8.1, rms: 0.001)

        await waitUntil { controller.state == .failed }
        XCTAssertEqual(probe.inputs[0].cancelCalls, 1)
        XCTAssertNotNil(controller.error)
        XCTAssertTrue(probe.runs.isEmpty)
    }

    func testSilenceTimeoutStopsListeningWithActionableError() async {
        let probe = Probe()
        let controller = makeController(probe: probe)
        controller.start()
        await waitUntil { controller.state == .listening }

        await waitUntil { controller.state == .failed }

        XCTAssertEqual(probe.inputs[0].cancelCalls, 1)
        XCTAssertNotNil(controller.error)
        XCTAssertTrue(probe.runs.isEmpty)
    }

    func testCancelAfterPartialStopsCaptureAndRejectsFinalTranscript() async {
        let probe = Probe()
        let controller = makeController(probe: probe)
        controller.start()
        await waitUntil { controller.state == .listening }
        let input = probe.inputs[0]
        input.onPartial("unfinished request")
        await waitUntil { controller.transcript == "unfinished request" }

        controller.cancel()
        input.onTranscript("unfinished request completed late")
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(input.cancelCalls, 1)
        XCTAssertEqual(input.finishCalls, 0)
        XCTAssertTrue(probe.runs.isEmpty)
        XCTAssertNil(controller.error)
    }

    func testFailedRunCanBeRetried() async {
        let probe = Probe()
        var succeed = false
        let controller = makeController(probe: probe, events: { continuation in
            if succeed { continuation.yield(.textDelta("Done. ")) }
            continuation.yield(.finished(succeed ? .completed : .failed("No model.")))
            continuation.finish()
        })
        controller.start()
        await waitUntil { controller.state == .listening }
        probe.inputs[0].onTranscript("first")
        await waitUntil { controller.state == .failed }
        XCTAssertEqual(controller.error, "No model.")

        succeed = true
        controller.start()
        await waitUntil { controller.state == .listening }
        probe.inputs[1].onTranscript("second")

        await waitUntil { controller.state == .idle }
        XCTAssertEqual(probe.runs, ["first", "second"])
        XCTAssertEqual(probe.spoken, ["Done."])
        XCTAssertNil(controller.error)
    }

    func testCancelDuringTurnStopsProviderAndBlocksLateSpeech() async {
        let probe = Probe()
        var completions = 0
        let controller = makeController(probe: probe, events: { continuation in
            continuation.yield(.textDelta("Working. "))
        })
        controller.onTurnCompleted = { completions += 1 }
        controller.start()
        await waitUntil { controller.state == .listening }
        probe.inputs[0].onTranscript("do it")
        await waitUntil { probe.spoken == ["Working."] }

        controller.cancel()

        XCTAssertEqual(controller.state, .idle)
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
        let controller = AppController(debugStorageDirectory: directory)
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
