import AppKit
import PerryBrain
import PerryCore
import PerryGuide
import SwiftUI

@MainActor
final class InterviewListener: ObservableObject {
    @Published private(set) var listening = false
    private var input: DictationController?
    private var detector: EndOfTurnDetector?

    func start(onPartial: @escaping (String) -> Void, onDone: @escaping (String) -> Void) {
        guard !listening else { return }
        Task {
            guard await DictationController.ensurePermission() else { return }
            let input = DictationController(
                onTranscript: { [weak self] text in
                    Task { @MainActor in
                        self?.stop()
                        onDone(text)
                    }
                },
                onPartial: { [weak self] text in
                    Task { @MainActor in
                        guard let self, self.listening else { return }
                        onPartial(text)
                        _ = self.detector?.transcript(at: ProcessInfo.processInfo.systemUptime, text: text, lastWordEnd: 0)
                    }
                },
                onLevel: { [weak self] time, rms in
                    Task { @MainActor in self?.level(rms, at: time) }
                },
                onFailure: { [weak self] _ in
                    Task { @MainActor in self?.stop() }
                }
            )
            do {
                try input.start()
            } catch {
                return
            }
            self.input = input
            detector = EndOfTurnDetector(startedAt: ProcessInfo.processInfo.systemUptime)
            listening = true
        }
    }

    func finish() {
        guard listening else { return }
        listening = false
        input?.finish()
    }

    func stop() {
        listening = false
        input?.cancel()
        input = nil
        detector = nil
    }

    private func level(_ rms: Double, at time: TimeInterval) {
        guard listening else { return }
        switch detector?.frame(at: time, rms: rms) {
        case .commit?: finish()
        case .abort?: stop()
        default: break
        }
    }
}
