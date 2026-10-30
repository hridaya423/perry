import AVFoundation
import CoreAudio

@MainActor
final class MicrophoneLevelMeter: ObservableObject {
    @Published private(set) var level = 0.0
    @Published private(set) var isRunning = false
    @Published private(set) var problem: String?
    private let mic = MicCapture()
    private var timeout: Task<Void, Never>?

    func start(deviceID: UInt32?) async {
        stop()
        problem = nil
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined where await AVCaptureDevice.requestAccess(for: .audio):
            break
        default:
            problem = "I can’t hear the microphone. Turn on Microphone in Privacy."
            return
        }
        do {
            try mic.start(deviceID: deviceID.map { AudioDeviceID($0) }) { [weak self] buffer, _ in
                let value = Self.normalized(MicCapture.rms(buffer))
                Task { @MainActor in self?.level = value }
            }
        } catch DictationController.DictationError.deviceUnavailable, DictationController.DictationError.unavailable {
            problem = "That microphone isn’t available, so I’ll use the built-in one."
            return
        } catch {
            problem = "I couldn’t open that microphone."
            return
        }
        isRunning = true
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        timeout?.cancel()
        timeout = nil
        mic.stop()
        isRunning = false
        level = 0
    }

    nonisolated static func normalized(_ rms: Double) -> Double {
        min(max((20 * log10(max(rms, 1e-7)) + 60) / 50, 0), 1)
    }
}
