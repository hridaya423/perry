import AVFoundation
import XCTest
@testable import Perry

final class DictationControllerTests: XCTestCase {
    func testATapAVAudioEngineRefusesComesBackAsFalseInsteadOfAnException() {
        let engine = AVAudioEngine()
        let mixer = engine.mainMixerNode
        XCTAssertTrue(DictationController.installTap(on: mixer, format: nil) { _, _ in })
        XCTAssertFalse(DictationController.installTap(on: mixer, format: nil) { _, _ in })
        mixer.removeTap(onBus: 0)
    }

    func testLevelIsTheRootMeanSquareOfTheBuffer() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<1024 { samples[index] = index.isMultiple(of: 2) ? 0.5 : -0.5 }
        XCTAssertEqual(DictationController.rms(buffer), 0.5, accuracy: 1e-6)
        buffer.frameLength = 0
        XCTAssertEqual(DictationController.rms(buffer), 0)
    }

    func testCancelledFinalizationCannotDeliverIntoReplacementInvocation() throws {
        var invocation = VoiceInvocationGate()
        var transcripts: [String] = []
        let controller = DictationController(onTranscript: { text in
            guard let id = invocation.id, invocation.claim(id) else { return }
            transcripts.append(text)
        })
        invocation.begin()
        let oldGeneration = try controller.beginRecognitionFixture()
        controller.finish()
        controller.cancel()
        invocation.begin()
        let replacementID = invocation.id

        controller.handleRecognition(.transcript("old command", isFinal: true, words: []), generation: oldGeneration)

        XCTAssertTrue(transcripts.isEmpty)
        XCTAssertEqual(invocation.id, replacementID)
        let newGeneration = try controller.beginRecognitionFixture()
        controller.handleRecognition(.transcript("new command", isFinal: true, words: []), generation: newGeneration)
        XCTAssertEqual(transcripts, ["new command"])
        XCTAssertNil(invocation.id)
    }

    func testErrorAfterReleaseDoesNotSelectMicrophoneOrDispatchLateFinal() throws {
        var transcripts: [String] = []
        var failures = 0
        var microphoneSelections = 0
        let controller = DictationController(
            onTranscript: { transcripts.append($0) },
            onFailure: { _ in failures += 1 },
            selectFallbackInput: { _ in microphoneSelections += 1; return false }
        )
        let generation = try controller.beginRecognitionFixture()
        controller.finish()

        controller.handleRecognition(.failure(DictationController.DictationError.unavailable), generation: generation)
        controller.handleRecognition(.transcript("run the task", isFinal: true, words: []), generation: generation)

        XCTAssertEqual(microphoneSelections, 0)
        XCTAssertEqual(failures, 1)
        XCTAssertTrue(transcripts.isEmpty)
        XCTAssertFalse(controller.isRunning)
    }

    func testReleasedRecognitionDeliversOneFinalAndIgnoresDuplicateCallbacks() throws {
        var transcripts: [String] = []
        var failures = 0
        let controller = DictationController(
            onTranscript: { transcripts.append($0) },
            onFailure: { _ in failures += 1 },
            selectFallbackInput: { _ in XCTFail("Unexpected microphone recovery"); return false }
        )
        let generation = try controller.beginRecognitionFixture()
        controller.finish()

        controller.handleRecognition(.transcript("open settings", isFinal: true, words: []), generation: generation)
        controller.handleRecognition(.transcript("open settings", isFinal: true, words: []), generation: generation)
        controller.handleRecognition(.failure(DictationController.DictationError.unavailable), generation: generation)

        XCTAssertEqual(transcripts, ["open settings"])
        XCTAssertEqual(failures, 0)
    }

    func testCancelledRecognitionIgnoresPartialAndFinalCallbacks() throws {
        var transcripts: [String] = []
        var partials: [String] = []
        let controller = DictationController(
            onTranscript: { transcripts.append($0) },
            onPartial: { partials.append($0) }
        )
        let generation = try controller.beginRecognitionFixture()
        controller.cancel()

        controller.handleRecognition(.transcript("late", isFinal: false, words: []), generation: generation)
        controller.handleRecognition(.transcript("late command", isFinal: true, words: []), generation: generation)

        XCTAssertTrue(transcripts.isEmpty)
        XCTAssertTrue(partials.isEmpty)
    }

    func testReroutedFailureRejectsLateTranscript() throws {
        var transcripts: [String] = []
        var failures = 0
        let controller = DictationController(
            onTranscript: { transcripts.append($0) },
            onFailure: { _ in failures += 1 }
        )
        let generation = try controller.beginRecognitionFixture()
        controller.handleReroutedRecognition(
            .failure(DictationController.DictationError.unavailable),
            generation: generation,
            detectedIdentifier: "fr-FR"
        )
        controller.handleReroutedRecognition(
            .transcript("ouvre les réglages", isFinal: true, words: []),
            generation: generation,
            detectedIdentifier: "fr-FR"
        )

        XCTAssertEqual(failures, 1)
        XCTAssertTrue(transcripts.isEmpty)
    }

    func testFinalizationTimeoutReportsFailureWithoutMicrophoneRecovery() throws {
        let failure = expectation(description: "Finalization expires")
        let controller = DictationController(
            onTranscript: { _ in XCTFail("Unexpected transcript") },
            onFailure: { _ in failure.fulfill() },
            selectFallbackInput: { _ in XCTFail("Unexpected microphone recovery"); return false }
        )
        _ = try controller.beginRecognitionFixture()
        controller.finish()

        wait(for: [failure], timeout: 4)
        XCTAssertFalse(controller.isRunning)
    }

    func testQueuedTranscriptCannotClaimCancelledOrReplacementInvocation() throws {
        var invocation = VoiceInvocationGate()
        invocation.begin()
        let cancelledID = try XCTUnwrap(invocation.id)
        invocation.cancel()
        XCTAssertFalse(invocation.claim(cancelledID))

        invocation.begin()
        let replacementID = try XCTUnwrap(invocation.id)
        XCTAssertFalse(invocation.claim(cancelledID))
        XCTAssertTrue(invocation.claim(replacementID))
        XCTAssertFalse(invocation.claim(replacementID))
    }

    func testFinalizingInvocationAllowsTranscriptButNotFreshCapture() throws {
        var invocation = VoiceInvocationGate()
        invocation.begin()
        let id = try XCTUnwrap(invocation.id)
        XCTAssertTrue(invocation.inputOpen)

        invocation.finishInput()

        XCTAssertFalse(invocation.inputOpen)
        XCTAssertTrue(invocation.claim(id))
        XCTAssertNil(invocation.id)
    }

    func testReleaseClosesInputButAllowsOneFinalTranscript() {
        var gate = DictationRecognitionGate()
        let generation = gate.advance()
        XCTAssertTrue(gate.inputOpen)

        gate.finishInput()

        XCTAssertFalse(gate.inputOpen)
        XCTAssertTrue(gate.claim(generation))
        XCTAssertFalse(gate.claim(generation))
    }

    func testTerminalFailureClosesInputAndRejectsLateFinal() {
        var gate = DictationRecognitionGate()
        let generation = gate.advance()
        gate.invalidate()

        XCTAssertFalse(gate.inputOpen)
        XCTAssertFalse(gate.claim(generation))
    }

    func testOnDeviceRequestCannotPermitServerRecognition() throws {
        let request = try DictationController.makeOnDeviceRequest(
            supported: true,
            customWords: ["Perry", "DaVinci"]
        )

        XCTAssertTrue(request.requiresOnDeviceRecognition)
        XCTAssertTrue(request.shouldReportPartialResults)
        XCTAssertEqual(request.contextualStrings, ["Perry", "DaVinci"])
    }

    func testUnsupportedLocaleCannotCreateRecognitionRequest() {
        XCTAssertThrowsError(try DictationController.makeOnDeviceRequest(supported: false, customWords: [])) {
            guard case DictationController.DictationError.onDeviceUnavailable = $0 else {
                return XCTFail("Expected an on-device availability error, got \($0)")
            }
        }
    }
}
