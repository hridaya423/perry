import AppKit
import PerryBrain
import PerryCore

@MainActor
final class VoiceKeyCapture: ObservableObject {
    enum State: Equatable {
        case idle
        case waiting(VoiceService)
        case checking(VoiceService)
        case saved(VoiceService)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    var onSaved: (VoiceService) -> Void = { _ in }

    private var watch: Timer?
    private var changeCount = 0
    private var deadline = Date()

    func getKey(for service: VoiceService) {
        stop()
        state = .waiting(service)
        changeCount = NSPasteboard.general.changeCount
        deadline = Date().addingTimeInterval(600)
        NSWorkspace.shared.open(service.keysPage)
        watch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func submit(_ text: String) {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let service = VoiceService.provider(forKey: key) else {
            state = .failed("That does not look like an ElevenLabs, OpenAI or Cartesia key.")
            return
        }
        Task { await verify(key, service: service, fromClipboard: false) }
    }

    func stop() {
        watch?.invalidate()
        watch = nil
        if case .waiting = state { state = .idle }
    }

    private func poll() {
        guard case .waiting = state else { return stop() }
        guard Date() < deadline else { return stop() }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let service = VoiceService.provider(forKey: text) else { return }
        watch?.invalidate()
        watch = nil
        Task { await verify(text, service: service, fromClipboard: true) }
    }

    private func verify(_ key: String, service: VoiceService, fromClipboard: Bool) async {
        state = .checking(service)
        do {
            let voices = try await service.verify(key: key)
            try KeychainStore().save(key, account: service.keyAccount)
            if fromClipboard, NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) == key {
                NSPasteboard.general.clearContents()
            }
            if UserDefaults.standard.string(forKey: service.voicePreferenceKey) == nil, let first = service.preferredVoice(in: voices) {
                UserDefaults.standard.set(first.id, forKey: service.voicePreferenceKey)
            }
            state = .saved(service)
            onSaved(service)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
