import AVFoundation
import XCTest
@testable import Perry

final class MicCaptureTests: XCTestCase {
    func testATapAVAudioEngineRefusesComesBackAsFalseInsteadOfAnException() {
        let engine = AVAudioEngine()
        let mixer = engine.mainMixerNode
        XCTAssertTrue(MicCapture.installTap(on: mixer, format: nil) { _, _ in })
        XCTAssertFalse(MicCapture.installTap(on: mixer, format: nil) { _, _ in })
        mixer.removeTap(onBus: 0)
    }

    func testLevelIsTheRootMeanSquareOfTheBuffer() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<1024 { samples[index] = index.isMultiple(of: 2) ? 0.5 : -0.5 }
        XCTAssertEqual(MicCapture.rms(buffer), 0.5, accuracy: 1e-6)
        buffer.frameLength = 0
        XCTAssertEqual(MicCapture.rms(buffer), 0)
    }
}
