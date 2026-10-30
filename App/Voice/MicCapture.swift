import Accelerate
import AudioToolbox
import AVFoundation

final class MicCapture {
    private var engine = AVAudioEngine()
    private var tapInstalled = false
    private(set) var isRunning = false

    func start(deviceID: AudioDeviceID?, onBuffer: @escaping AVAudioNodeTapBlock) throws {
        stop()
        engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceID, !MicrophoneDeviceSelector.select(on: input, deviceID: deviceID) {
            throw DictationController.DictationError.deviceUnavailable
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationController.DictationError.unavailable
        }
        guard Self.installTap(on: input, format: format, block: onBuffer) else {
            throw DictationController.DictationError.deviceUnavailable
        }
        tapInstalled = true
        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw error
        }
        isRunning = true
    }

    func stop() {
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        isRunning = false
    }

    /// AVAudioEngine raises an Objective-C exception, not a Swift error, when the tap's
    /// format no longer matches the input hardware (after a device or Bluetooth profile change).
    nonisolated static func installTap(on input: AVAudioNode, format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) -> Bool {
        PerryCatchException { input.installTap(onBus: 0, bufferSize: 1024, format: format, block: block) } == nil
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(samples, 1, &value, vDSP_Length(buffer.frameLength))
        return Double(value)
    }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            let byteCount = frameCount * MemoryLayout<Float>.size
            for channel in 0..<channelCount {
                memcpy(destination[channel], source[channel], byteCount)
            }
            return copy
        }
        if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            let byteCount = frameCount * MemoryLayout<Int16>.size
            for channel in 0..<channelCount {
                memcpy(destination[channel], source[channel], byteCount)
            }
            return copy
        }
        return nil
    }
}
