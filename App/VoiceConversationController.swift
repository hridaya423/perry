import Combine
import Foundation
import PerryBrain
import PerryCore

protocol VoiceConversationInput: AnyObject {
    func start() throws
    func finish()
    func cancel()
}

extension DictationController: VoiceConversationInput {}

@MainActor
final class VoiceConversationController: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case listening
        case thinking
        case speaking
        case failed
    }

    @MainActor
    struct Services {
        var requestPermission: () async -> Bool = { await DictationController.ensurePermission() }
        var makeInput: (
            _ onTranscript: @escaping (String) -> Void,
            _ onPartial: @escaping (String) -> Void,
            _ onLevel: @escaping (TimeInterval, Double) -> Void,
            _ onFailure: @escaping (Error) -> Void
        ) -> any VoiceConversationInput = { onTranscript, onPartial, onLevel, onFailure in
            let input = DictationController(onTranscript: onTranscript, onPartial: onPartial, onLevel: onLevel, onFailure: onFailure)
            input.configure(.default)
            return input
        }
        var run: (String) -> (threadID: UUID, events: AsyncStream<AgentLoopEvent>, completion: Task<Void, Never>?)
        var stop: (UUID) -> Void = { _ in }
        var output: any TalkSpeechOutput
        var speechDrain: (() async -> Void)?
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var silenceTimeout: TimeInterval = 20
        var finalTranscriptTimeout: TimeInterval = 2
    }

    @Published private(set) var state = State.idle
    @Published private(set) var transcript = ""
    @Published private(set) var answer = ""
    @Published private(set) var error: String?
    @Published private(set) var level = 0.0
    @Published private(set) var endProgress = 0.0

    var onTurnCompleted: (() -> Void)?

    private let services: Services
    private var generation = 0
    private var input: (any VoiceConversationInput)?
    private var permissionTask: Task<Void, Never>?
    private var finalizeTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var turnTask: Task<Void, Never>?
    private var activeThreadID: UUID?
    private var submitted = false
    private var detector: EndOfTurnDetector?
    private var meteredAt = -TimeInterval.infinity

    init(services: Services) {
        self.services = services
    }

    func start() {
        guard state == .idle || state == .failed else { return }
        generation += 1
        let generation = self.generation
        submitted = false
        transcript = ""
        answer = ""
        error = nil
        activeThreadID = nil
        state = .requestingPermission
        let input = services.makeInput(
            { [weak self] text in Task { @MainActor in self?.handleTranscript(text, generation: generation) } },
            { [weak self] text in Task { @MainActor in self?.handlePartial(text, generation: generation) } },
            { [weak self] time, rms in Task { @MainActor in self?.handleLevel(rms, at: time, generation: generation) } },
            { [weak self] failure in Task { @MainActor in self?.handleFailure(failure, generation: generation) } }
        )
        self.input = input
        permissionTask = Task { [weak self] in
            guard let self else { return }
            let granted = await services.requestPermission()
            guard self.generation == generation, self.state == .requestingPermission else { return }
            guard granted else {
                fail("Enable microphone and speech recognition for Perry in System Settings › Privacy & Security, then try again.")
                return
            }
            do {
                try input.start()
            } catch {
                fail((error as? LocalizedError)?.errorDescription ?? "Perry couldn’t start listening.")
                return
            }
            guard self.generation == generation, self.state == .requestingPermission else {
                input.cancel()
                return
            }
            detector = EndOfTurnDetector(startedAt: services.now())
            meteredAt = -.infinity
            state = .listening
            armSilenceTimeout(generation: generation)
        }
    }

    func sendNow() {
        guard state == .listening else { return }
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cancel()
        } else {
            finishListening()
        }
    }

    func finishListening() {
        guard state == .listening else { return }
        level = 0
        endProgress = 0
        state = .thinking
        finalizeTask?.cancel()
        finalizeTask = nil
        silenceTask?.cancel()
        silenceTask = nil
        input?.finish()
        let generation = self.generation
        let timeout = services.finalTranscriptTimeout
        finalizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled, self.generation == generation, self.state == .thinking, !self.submitted else { return }
            self.submit(self.transcript, generation: generation)
        }
    }

    func resetConversation() {
        cancel()
        transcript = ""
        answer = ""
        error = nil
    }

    func cancel() {
        generation += 1
        permissionTask?.cancel()
        permissionTask = nil
        finalizeTask?.cancel()
        finalizeTask = nil
        silenceTask?.cancel()
        silenceTask = nil
        turnTask?.cancel()
        turnTask = nil
        input?.cancel()
        input = nil
        if let activeThreadID {
            services.stop(activeThreadID)
        }
        activeThreadID = nil
        submitted = false
        level = 0
        endProgress = 0
        guard state != .idle else { return }
        services.output.shutUp()
        state = .idle
    }

    private func handleTranscript(_ text: String, generation: Int) {
        guard self.generation == generation else { return }
        switch state {
        case .listening, .thinking:
            input = nil
            submit(text, generation: generation)
        default:
            break
        }
    }

    private func handlePartial(_ text: String, generation: Int) {
        guard self.generation == generation, state == .listening, !submitted, !text.isEmpty else { return }
        transcript = text
        _ = detector?.transcript(at: services.now(), text: text, lastWordEnd: 0)
        armSilenceTimeout(generation: generation)
    }

    private func handleLevel(_ rms: Double, at time: TimeInterval, generation: Int) {
        guard self.generation == generation, state == .listening else { return }
        switch detector?.frame(at: time, rms: rms) {
        case .commit?:
            finishListening()
        case .abort?:
            fail("I didn’t hear anything. Check that your microphone is on, then try again.")
        case .silence(_, let progress)?:
            meter(rms, progress: progress, at: time)
        default:
            meter(rms, progress: 0, at: time)
        }
    }

    private func meter(_ rms: Double, progress: Double, at time: TimeInterval) {
        guard time - meteredAt >= 0.05 else { return }
        meteredAt = time
        level = min(max((20 * log10(max(rms, 1e-7)) + 60) / 50, 0), 1)
        endProgress = progress
    }

    private func handleFailure(_ failure: Error, generation: Int) {
        guard self.generation == generation else { return }
        let message = (failure as? LocalizedError)?.errorDescription ?? "Perry couldn’t hear that."
        switch state {
        case .listening:
            fail(message)
        case .thinking where !submitted:
            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fail("I didn’t catch that. Try again.")
            } else {
                submit(transcript, generation: generation)
            }
        default:
            break
        }
    }

    private func submit(_ text: String, generation: Int) {
        guard self.generation == generation, !submitted else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fail("I didn’t catch that. Try again.")
            return
        }
        submitted = true
        finalizeTask?.cancel()
        finalizeTask = nil
        silenceTask?.cancel()
        silenceTask = nil
        transcript = trimmed
        state = .thinking
        input = nil
        let run = services.run(trimmed)
        activeThreadID = run.threadID
        turnTask = Task { [weak self] in
            await self?.consume(events: run.events, generation: generation)
        }
    }

    private func consume(events: AsyncStream<AgentLoopEvent>, generation: Int) async {
        var markup = InlineMarkupParser(validElementIDs: [])
        var chunker = SentenceChunker()
        var completed = false
        var interrupted = false
        var failureMessage: String?
        for await event in events {
            guard self.generation == generation else { return }
            switch event {
            case .textDelta(let delta):
                let result = markup.feed(delta)
                if !result.text.isEmpty {
                    answer += result.text
                    for sentence in chunker.feed(result.text) {
                        state = .speaking
                        services.output.speak(sentence)
                    }
                }
            case .finished(let outcome):
                switch outcome {
                case .completed:
                    completed = true
                case .interrupted, .paused:
                    interrupted = true
                default:
                    failureMessage = outcome.failureReason ?? "Perry couldn’t finish this answer."
                }
            case .toolCallStarted, .toolCallFinished, .note, .draw:
                break
            }
        }
        guard self.generation == generation else { return }
        if completed {
            let tail = markup.finish()
            if !tail.text.isEmpty {
                answer += tail.text
                for sentence in chunker.feed(tail.text) {
                    state = .speaking
                    services.output.speak(sentence)
                }
            }
            if let remainder = chunker.finish() {
                state = .speaking
                services.output.speak(remainder)
            }
            if state == .speaking {
                await waitForSpeechEnd()
            }
            guard self.generation == generation else { return }
            activeThreadID = nil
            state = .idle
            onTurnCompleted?()
        } else if interrupted {
            services.output.shutUp()
            state = .idle
        } else {
            services.output.shutUp()
            error = failureMessage ?? "Perry couldn’t answer that."
            state = .failed
        }
    }

    private func waitForSpeechEnd() async {
        if let speechDrain = services.speechDrain {
            await speechDrain()
            return
        }
        for _ in 0..<1200 {
            guard services.output.isSpeaking, !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func armSilenceTimeout(generation: Int) {
        silenceTask?.cancel()
        let timeout = services.silenceTimeout
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled, self.generation == generation, self.state == .listening else { return }
            self.fail("I didn’t hear anything. Check that your microphone is on, then try again.")
        }
    }

    private func fail(_ message: String) {
        finalizeTask?.cancel()
        finalizeTask = nil
        silenceTask?.cancel()
        silenceTask = nil
        input?.cancel()
        input = nil
        error = message
        state = .failed
    }
}
