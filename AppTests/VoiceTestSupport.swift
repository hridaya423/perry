import AppKit
import Speech
@testable import Perry

extension PushToTalkController {
    func handle(keyCode: Int64, timestamp: TimeInterval, isKeyDown: Bool, isKeyUp: Bool, modifiers: Bool, tapDisabled: Bool) {
        handle(
            keyCode: keyCode,
            timestamp: timestamp,
            flags: modifiers ? [.maskAlternate, .maskCommand] : [],
            isKeyDown: isKeyDown,
            isKeyUp: isKeyUp,
            tapDisabled: tapDisabled
        )
    }
}

extension ModifierHoldMonitor {
    func handle(timestamp: TimeInterval, control: Bool, option: Bool, isFlagsChanged: Bool, tapDisabled: Bool) {
        var modifiers: ModifierSet = []
        if control { modifiers.insert(.control) }
        if option { modifiers.insert(.option) }
        handle(timestamp: timestamp, modifiers: modifiers, isFlagsChanged: isFlagsChanged, tapDisabled: tapDisabled)
    }
}

extension DictationController {
    func beginRecognitionFixture() throws -> Int {
        cancel()
        languageMode = .fixed(identifier: "en-US")
        session = SystemRecognitionSession(recognizer: nil, request: try Self.makeOnDeviceRequest(supported: true, customWords: []), onEvent: { _ in })
        return recognitionGate.advance()
    }
}

extension RealtimeVoicePipeline {
    func advance(to generation: Int) {
        advance(sessionID: 0, utteranceGeneration: generation)
    }

    func enqueueAudio(_ data: Data, generation: Int) -> EnqueueResult {
        enqueueAudio(data, sessionID: 0, utteranceGeneration: generation)
    }

    func commit(generation: Int) async throws -> CommitResult {
        try await commit(sessionID: 0, utteranceGeneration: generation)
    }
}
