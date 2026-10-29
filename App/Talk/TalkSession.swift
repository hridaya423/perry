import AppKit
import Combine
import PerryBrain
import PerryCore
import PerryGuide
import PerryOverlay

protocol VoiceConversationInput: AnyObject {
    func start() throws
    func finish()
    func cancel()
}

extension DictationController: VoiceConversationInput {}

/// The Talk loop: hold ⌃⌥ → listen + trace + capture in parallel → release →
/// deixis-bound prompt → streamed answer, spoken by sentence and drawn as ink.
/// Ask-never-acts is structural: the request only ever offers draw/observe
/// tools, and every model tool call passes `ToolGate.check` before dispatch.
/// All side effects are injected so the loop is unit-testable with stubs.
@MainActor
final class TalkSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case speaking
    }

    enum ClickState: Equatable {
        case idle
        case requestingPermission
        case listening
        case thinking
        case speaking
        case failed
    }

    struct Services {
        var makeInput: () -> any TalkSpeechInput
        var output: any TalkSpeechOutput
        var capture: () async throws -> GuideObservation
        var acceptInput: (String, UUID?, TalkContextKey?) -> HomeController.AcceptedInput
        var targetHint: () -> CuaTargetHint = { CuaTargetHint() }
        var run: (HomeController.AcceptedInput, AgentCoordinator.SpatialContext?) -> (threadID: UUID, events: AsyncStream<AgentLoopEvent>, completion: Task<Void, Never>?)
        var waitForConversation: (UUID) async -> Void = { _ in }
        var guide: ((HomeController.AcceptedInput, AgentCoordinator.SpatialContext, Bool) -> Void)? = nil
        var warm: () async -> Void = {}
        var skill: (GuideObservation) -> String? = { _ in nil }
        var requestPermission: () async -> Bool = { await DictationController.ensurePermission() }
        var makeClickInput: (
            _ onTranscript: @escaping (String) -> Void,
            _ onPartial: @escaping (String) -> Void,
            _ onLevel: @escaping (TimeInterval, Double) -> Void,
            _ onFailure: @escaping (Error) -> Void
        ) -> any VoiceConversationInput = { onTranscript, onPartial, onLevel, onFailure in
            let input = DictationController(onTranscript: onTranscript, onPartial: onPartial, onLevel: onLevel, onFailure: onFailure)
            input.configure(.default)
            return input
        }
        var stop: (UUID) -> Void = { _ in }
        var clickOutput: (any TalkSpeechOutput)?
        var speechDrain: (() async -> Void)?
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var silenceTimeout: TimeInterval = 20
        var finalTranscriptTimeout: TimeInterval = 2
    }

    let sessionController: SessionController
    let overlayState: PerryCursorState
    weak var output: (any GuideSessionOutput)?
    let services: Services
    private let tracer: PointerTraceRecorder

    private(set) var phase: Phase = .idle
    @Published private(set) var clickState = ClickState.idle
    @Published private(set) var transcript = ""
    @Published private(set) var answer = ""
    @Published private(set) var error: String?
    @Published private(set) var level = 0.0
    @Published private(set) var endProgress = 0.0
    private var clickGeneration = 0
    private var clickInput: (any VoiceConversationInput)?
    private var clickPermissionTask: Task<Void, Never>?
    private var clickFinalizeTask: Task<Void, Never>?
    private var clickSilenceTask: Task<Void, Never>?
    private var clickTurnTask: Task<Void, Never>?
    private var clickThreadID: UUID?
    private var clickSubmitted = false
    private var clickDetector: EndOfTurnDetector?
    private var clickMeteredAt = -TimeInterval.infinity
    private static var screenAccessNoticeShown = false
    private static let bubbleCapacity = 150
    private var input: (any TalkSpeechInput)?
    private var warmTask: Task<Void, Never>?
    private var captureTask: Task<GuideObservation, Error>?
    var turnTask: Task<Void, Never>?
    var presentationTask: Task<Void, Never>?
    var askTransitionTask: Task<Void, Never>?
    var askInputSaveTask: Task<Bool, Never>?
    var activeAskID: UUID?
    var index = ElementIndex(elements: [])
    private var answerText = ""
    private var firstTextMarked = false
    private var firstInkMarked = false
    private var firstAudioMarked = false

    /// 10 Hz reanchor (§5): while this turn's marks are shown, poll the
    /// captured window's CG bounds and translate our overlays by the delta —
    /// marks follow a moved window at ~zero cost. Element reflow inside a
    /// static window isn't tracked: AX elements are cross-process snapshot
    /// values with no live handle on this side.
    private var reanchorTimer: Timer?
    private var markOverlayIDs: Set<UUID> = []
    private var markWindowID: CGWindowID?
    private var markWindowBL = CGRect.zero

    /// Fired after a turn's stream completes — onboarding listens for the
    /// "first real talk" moment without polling session state.
    var onTurnCompleted: (() -> Void)?

    private var primaryMaxY: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    init(
        sessionController: SessionController,
        overlayState: PerryCursorState,
        output: any GuideSessionOutput,
        services: Services,
        tracer: PointerTraceRecorder? = nil
    ) {
        self.sessionController = sessionController
        self.overlayState = overlayState
        self.output = output
        self.services = services
        self.tracer = tracer ?? .live()
    }

    // MARK: Hold lifecycle

    /// Key-down: listening cue within the ≤50 ms budget. No real work yet —
    /// the monitor commits the hold after its chord threshold, which is when
    /// mic, trace, capture and warm-up start. A stray ⌃⌥ shortcut never gets
    /// this far.
    func keyDown() {
        output?.guideClearFailure()
        if phase != .idle {
            bargeIn()
        }
        do {
            switch sessionController.state {
            case .talking:
                break
            case .invoking(let invocation):
                var talk = TalkSessionState(id: UUID(), startedAt: Date(), transcript: "")
                talk.isListening = true
                try sessionController.startTalk(talk, attemptID: invocation.id)
            case .reporting, .failed:
                _ = sessionController.requestDismissal()
                fallthrough
            case .idle:
                let attemptID = UUID()
                try sessionController.wake(at: Date(), attemptID: attemptID)
                var talk = TalkSessionState(id: UUID(), startedAt: Date(), transcript: "")
                talk.isListening = true
                try sessionController.startTalk(talk, attemptID: attemptID)
            case .asking, .guiding, .executing:
                output?.guidePlay(.fail)
                output?.guideReportFailure("I’m still on your last task. Finish or stop it, then hold ⌃⌥ again.", recovery: nil)
                return
            }
        } catch {
            output?.guideReportFailure("I couldn’t start listening. Hold ⌃⌥ to try again.", recovery: nil)
            return
        }

        phase = .listening
        overlayState.voiceState = .listening
        overlayState.buddyState = .listening
        sessionController.updateTalk { $0.isListening = true }
        output?.guideShowOverlay()
        PerfMark.mark("talk.listening")
    }

    /// Commit: the hold survived the monitor's chord threshold — start the
    /// real work in parallel: STT, pointer trace, capture, provider warm-up.
    func holdCommitted() {
        guard phase == .listening, input == nil else { return }
        PerfMark.mark("talk.hold_commit")
        tracer.start()
        let speech = services.makeInput()
        input = speech
        let startedSynchronously: Bool
        do {
            // Mic warm (permission cached + engine reusable): start the
            // engine inline on key-down instead of behind a Task hop.
            startedSynchronously = try speech.startIfReady()
        } catch {
            inputFailed(error)
            startedSynchronously = true
        }
        if !startedSynchronously {
            Task { @MainActor [weak self, weak speech] in
                do {
                    try await speech?.start()
                } catch {
                    self?.inputFailed(error)
                }
            }
        }
        captureTask = Task { @MainActor in try await services.capture() }
        warmTask = Task { @MainActor in await services.warm() }
    }

    /// Key-up: freeze the trace, finalize STT, resolve deixis, run the turn.
    func keyUp() {
        guard phase == .listening else { return }
        phase = .thinking
        overlayState.voiceState = .processing
        overlayState.buddyState = .thinking
        sessionController.updateTalk { $0.isListening = false; $0.isWorking = true }
        let trace = tracer.stop()
        turnTask = Task { @MainActor [weak self] in
            await self?.run(trace: trace)
        }
    }

    /// Barge-in: key press during a turn cancels provider output and speech.
    func bargeIn() {
        PerfMark.mark("talk.bargein")
        abortActiveWork()
        PerfMark.mark("bargein.silence")
    }

    /// A hold the monitor cancelled — a chorded key, a release before commit,
    /// or a dead event tap. Discard everything without submitting and let the
    /// session go back to sleep; there is no utterance to answer.
    func holdCancelled() {
        guard phase == .listening else { return }
        PerfMark.mark("talk.cancel.hold")
        abortActiveWork()
        _ = tracer.stop()
        overlayState.buddyState = .idle
        _ = sessionController.requestDismissal()
    }

    /// Session teardown: stop everything; SessionController owns the transition.
    func cancel() {
        PerfMark.mark("talk.cancel.session")
        cancelAsk()
        abortActiveWork()
        _ = tracer.stop()
        overlayState.visualGuidanceOverlays = []
        markOverlayIDs = []
        stopReanchor()
        overlayState.buddyState = .idle
    }

    private func abortActiveWork() {
        turnTask?.cancel()
        turnTask = nil
        warmTask?.cancel()
        warmTask = nil
        captureTask?.cancel()
        captureTask = nil
        input?.cancel()
        input = nil
        services.output.shutUp()
        sessionController.updateTalk { $0.isListening = false; $0.isWorking = false }
        overlayState.voiceState = .idle
        phase = .idle
    }

    private func inputFailed(_ error: Error) {
        PerfMark.mark("talk.input_failed")
        // Settle the input even when the turn is already underway — otherwise
        // a start() failure after key-up would hang `finalize()` forever.
        input?.cancel()
        input = nil
        guard phase == .listening else { return }
        output?.guideReportFailure(
            (error as? LocalizedError)?.errorDescription ?? "I couldn’t hear that. Try again.",
            recovery: Self.recovery(forInput: error)
        )
        sessionController.updateTalk { $0.isListening = false }
        overlayState.voiceState = .idle
        overlayState.buddyState = .idle
        phase = .idle
    }

    // MARK: Turn

    private func run(trace: [TraceSample]) async {
        do {
            try Task.checkCancellation()
            guard let speech = input else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(250))
            let (transcript, words) = await speech.finalize()
            PerfMark.mark("talk.stt.final")
            // The utterance's job ends at finalize — clear so the next hold
            // builds a fresh input instead of re-finalizing this one.
            input = nil
            try Task.checkCancellation()
            sessionController.updateTalk { $0.transcript = transcript }
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                output?.guideReportFailure("I didn’t catch that. Hold ⌃⌥ and try again.", recovery: nil)
                overlayState.voiceState = .idle
                overlayState.buddyState = .idle
                sessionController.updateTalk { $0.isWorking = false }
                phase = .idle
                return
            }
            try Task.checkCancellation()
            guard case .talking(let original) = sessionController.state else { throw CancellationError() }
            // The keypress-time hint keys the per-window conversation map —
            // the same hint the in-flight capture resolved from.
            let hint = services.targetHint()
            let contextKey: TalkContextKey?
            if let processID = hint.processID, let windowID = hint.windowID {
                contextKey = TalkContextKey(processID: processID, windowID: windowID)
            } else {
                contextKey = nil
            }
            let accepted = services.acceptInput(transcript, original.threadID, contextKey)
            sessionController.updateTalk { $0.threadID = accepted.threadID }
            try await accepted.saved.value
            PerfMark.mark("talk.saved")
            try Task.checkCancellation()
            let observation: GuideObservation
            if let captureTask {
                observation = try await captureTask.value
                self.captureTask = nil
            } else {
                observation = try await services.capture()
            }
            try Task.checkCancellation()
            try GuideTargetValidator.requireUnprotected(observation)
            if observation.screenshotData == nil, !Self.screenAccessNoticeShown, !CGPreflightScreenCaptureAccess() {
                Self.screenAccessNoticeShown = true
                output?.guideReportFailure(
                    "I can’t see your screen. Until you turn on Screen Recording, I answer from window text.",
                    recovery: .privacy(.screenRecording)
                )
            }

            let elements = observation.observedElements
            PerfMark.markDynamic("deixis.index.\(elements.count)")
            index = ElementIndex(elements: elements)
            let bindings = DeixisResolver.resolve(words: words, trace: trace, elements: elements)
            if bindings.isEmpty {
                PerfMark.markDynamic("deixis.none")
            } else if bindings.contains(where: { $0.element != nil }) {
                PerfMark.markDynamic("deixis.element")
            } else if bindings.contains(where: { !$0.isWindowLevel }) {
                PerfMark.markDynamic("deixis.point")
            } else {
                PerfMark.markDynamic("deixis.window")
            }
            let spatial = AgentCoordinator.SpatialContext(
                observation: observation, bindings: bindings, skill: services.skill(observation)
            )
            await presentationTask?.value
            try Task.checkCancellation()
            guard case .talking(let talk) = sessionController.state else { throw CancellationError() }
            if let guide = services.guide {
                let full: Bool?
                switch GuideIntentParser.parse(transcript) {
                case .guide: full = false
                case .showEverything: full = true
                default: full = nil
                }
                if let full {
                    if let threadID = talk.threadID { await services.waitForConversation(threadID) }
                    try Task.checkCancellation()
                    guard case .talking(let current) = sessionController.state, current.id == talk.id else { throw CancellationError() }
                    cancel()
                    _ = sessionController.requestDismissal()
                    guide(accepted, spatial, full)
                    return
                }
            }
            let run = services.run(accepted, spatial)
            presentationTask = run.completion
            sessionController.updateTalk { $0.threadID = run.threadID }
            try await stream(events: run.events, observation: observation)
            if answerText.count > Self.bubbleCapacity, !VoiceController.speechIsAudible() {
                output?.guideReportFailure("Perry’s full answer is in your conversation.", recovery: .thread(run.threadID))
            }
        } catch is CancellationError {
            guard !Task.isCancelled else { return }
            PerfMark.markDynamic("talk.turn_cancelled")
            services.output.shutUp()
            sessionController.updateTalk { $0.isWorking = false }
            overlayState.voiceState = .idle
            overlayState.buddyState = .idle
            phase = .idle
        } catch {
            guard !Task.isCancelled else { return }
            PerfMark.markDynamic("talk.turn_failed.\(String(describing: type(of: error)))")
            services.output.shutUp()
            sessionController.updateTalk { $0.isWorking = false }
            overlayState.voiceState = .idle
            overlayState.buddyState = .blocked
            output?.guideReportFailure(
                (error as? ModelProviderError).map { AgentLoop.describe($0) }
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? "I couldn’t answer that. Try again.",
                recovery: error is ResponseError || error is ModelProviderError ? .settings(.brain) : nil
            )
            phase = .idle
        }
    }

    private static func recovery(forInput error: Error) -> FailureRecovery? {
        switch error as? DictationController.DictationError {
        case .permissionDenied?: .privacy(.microphone)
        case .deviceUnavailable?: .settings(.dictation)
        default: nil
        }
    }

    private struct ResponseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func stream(events: AsyncStream<AgentLoopEvent>, observation: GuideObservation) async throws {
        var chunker = SentenceChunker()
        var completed = false
        answerText = ""
        firstTextMarked = false
        firstInkMarked = false
        firstAudioMarked = false
        for await event in events {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let delta):
                answerText += delta
                sessionController.updateTalk { $0.answerText = self.answerText }
                if !firstTextMarked {
                    firstTextMarked = true
                    PerfMark.mark("answer.first_text")
                }
                for sentence in chunker.feed(delta) {
                    speak(sentence)
                }
            case .draw(let command):
                draw(command, observation: observation)
            case .finished(.completed):
                completed = true
            case .finished(.interrupted), .finished(.paused):
                throw CancellationError()
            case .finished(let outcome):
                throw ResponseError(message: outcome.failureReason ?? "I couldn’t finish that answer. Try again.")
            case .toolCallStarted(let call):
                if ToolGate.observeTools.contains(call.name) {
                    index = ElementIndex(elements: [])
                    overlayState.visualGuidanceOverlays.removeAll { markOverlayIDs.contains($0.id) }
                    markOverlayIDs.removeAll()
                    stopReanchor()
                }
            case .toolCallFinished, .note:
                break
            }
        }
        try Task.checkCancellation()
        guard completed else {
            throw ResponseError(message: "The spoken answer ended unexpectedly. Your question and partial answer are still shown.")
        }
        if let remainder = chunker.finish() {
            speak(remainder)
        }
        sessionController.updateTalk { $0.isWorking = false; $0.turnCount += 1 }
        // The turn stays active while queued utterances still play — going
        // idle now would make a key press mid-sentence start a new hold over
        // the old audio instead of cutting it.
        while services.output.isSpeaking {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }
        overlayState.voiceState = .idle
        overlayState.buddyState = .success
        phase = .idle
        onTurnCompleted?()
    }

    private func speak(_ sentence: String) {
        if !firstAudioMarked {
            firstAudioMarked = true
            PerfMark.mark("talk.first_audio")
        }
        phase = .speaking
        overlayState.voiceState = .responding
        services.output.speak(sentence)
    }

    // MARK: Drawing

    func draw(_ command: DrawCommand, observation: GuideObservation) {
        switch command.verb {
        case .clear:
            overlayState.visualGuidanceOverlays = []
            markOverlayIDs = []
            stopReanchor()
            return
        default:
            break
        }
        guard let frame = command.frame ?? index.element(for: command.elementID ?? "")?.frame else { return }
        let rect = AXCoordinateConverter.appKitRect(
            axX: frame.origin.x,
            axY: frame.origin.y,
            width: frame.width,
            height: frame.height,
            primaryScreenMaxY: primaryMaxY
        )
        // Luminance-adaptive ink (§5): sample the in-memory capture patch
        // under the mark; nil keeps the default mint accent.
        let accentHex = observation.screenshotData.flatMap { data in
            InkAccentSampler.accentHex(
                imageJPEG: data,
                elementCenterAX: CGPoint(x: frame.midX, y: frame.midY),
                windowBoundsAX: observation.windowBounds.map {
                    CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                } ?? .zero
            )
        } ?? "#34D399"
        var overlay: PerryGuidanceOverlay
        switch command.verb {
        case .point:
            overlay = .pointMark(center: CGPoint(x: rect.midX, y: rect.midY), accentHex: accentHex, caption: command.label)
        case .arrow:
            overlay = .arrowMark(to: rect, accentHex: accentHex, caption: command.label)
        case .underline:
            overlay = .underlineMark(below: rect, accentHex: accentHex, caption: command.label)
        case .ring, .caption:
            overlay = .ringMark(around: rect, accentHex: accentHex, caption: command.label)
        case .clear:
            return
        }
        overlay.nearbyControls = (command.nearbyFrames.isEmpty ? index.controlFrames(near: frame) : command.nearbyFrames).map {
            AXCoordinateConverter.appKitRect(
                axX: $0.origin.x, axY: $0.origin.y, width: $0.width, height: $0.height,
                primaryScreenMaxY: primaryMaxY
            )
        }
        overlayState.visualGuidanceOverlays.append(overlay)
        markOverlayIDs.insert(overlay.id)
        if reanchorTimer == nil {
            startReanchor(for: observation)
        }
        if !firstInkMarked {
            firstInkMarked = true
            PerfMark.mark("ink.first_draw")
        }
    }

    private func startReanchor(for observation: GuideObservation) {
        guard let windowID = observation.windowID else { return }
        markWindowID = CGWindowID(windowID)
        markWindowBL = observation.windowBounds.map {
            AXCoordinateConverter.appKitRect(
                axX: $0.x, axY: $0.y, width: $0.width, height: $0.height,
                primaryScreenMaxY: primaryMaxY
            )
        } ?? .zero
        reanchorTimer?.invalidate()
        reanchorTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reanchorMarks() }
        }
    }

    private func stopReanchor() {
        reanchorTimer?.invalidate()
        reanchorTimer = nil
        markWindowID = nil
        markWindowBL = .zero
    }

    private func reanchorMarks() {
        markOverlayIDs.formIntersection(
            Set(overlayState.visualGuidanceOverlays.map(\.id))
        )
        guard !markOverlayIDs.isEmpty else {
            stopReanchor()
            return
        }
        guard let windowID = markWindowID,
              let list = CGWindowListCopyWindowInfo(
                  [.optionIncludingWindow], windowID
              ) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? [String: Any],
              let topLeft = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { return }
        let bottomLeft = CGRect(
            x: topLeft.minX, y: primaryMaxY - topLeft.maxY,
            width: topLeft.width, height: topLeft.height
        )
        // First successful read after a nil windowBounds sets the baseline.
        if markWindowBL == .zero {
            markWindowBL = bottomLeft
            return
        }
        let delta = CGPoint(
            x: bottomLeft.minX - markWindowBL.minX,
            y: bottomLeft.minY - markWindowBL.minY
        )
        guard delta != .zero else { return }
        markWindowBL = bottomLeft
        overlayState.visualGuidanceOverlays = overlayState.visualGuidanceOverlays.map {
            markOverlayIDs.contains($0.id) ? $0.translated(by: delta) : $0
        }
    }

    // MARK: Click to talk

    private var clickSpeech: any TalkSpeechOutput { services.clickOutput ?? services.output }

    func startClick() {
        guard clickState == .idle || clickState == .failed else { return }
        clickGeneration += 1
        let generation = clickGeneration
        clickSubmitted = false
        transcript = ""
        answer = ""
        error = nil
        clickThreadID = nil
        clickState = .requestingPermission
        let input = services.makeClickInput(
            { [weak self] text in Task { @MainActor in self?.handleClickTranscript(text, generation: generation) } },
            { [weak self] text in Task { @MainActor in self?.handleClickPartial(text, generation: generation) } },
            { [weak self] time, rms in Task { @MainActor in self?.handleClickLevel(rms, at: time, generation: generation) } },
            { [weak self] failure in Task { @MainActor in self?.handleClickFailure(failure, generation: generation) } }
        )
        clickInput = input
        clickPermissionTask = Task { [weak self] in
            guard let self else { return }
            let granted = await services.requestPermission()
            guard self.clickGeneration == generation, self.clickState == .requestingPermission else { return }
            guard granted else {
                failClick("I need microphone and speech recognition access. Turn both on for Perry in System Settings.")
                return
            }
            do {
                try input.start()
            } catch {
                failClick((error as? LocalizedError)?.errorDescription ?? "I couldn’t start listening. Check your microphone.")
                return
            }
            guard self.clickGeneration == generation, self.clickState == .requestingPermission else {
                input.cancel()
                return
            }
            clickDetector = EndOfTurnDetector(startedAt: services.now())
            clickMeteredAt = -.infinity
            clickState = .listening
            armClickSilenceTimeout(generation: generation)
        }
    }

    func sendNow() {
        guard clickState == .listening else { return }
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cancelClick()
        } else {
            finishListening()
        }
    }

    func finishListening() {
        guard clickState == .listening else { return }
        level = 0
        endProgress = 0
        clickState = .thinking
        clickFinalizeTask?.cancel()
        clickFinalizeTask = nil
        clickSilenceTask?.cancel()
        clickSilenceTask = nil
        clickInput?.finish()
        let generation = clickGeneration
        let timeout = services.finalTranscriptTimeout
        clickFinalizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled, self.clickGeneration == generation, self.clickState == .thinking, !self.clickSubmitted else { return }
            self.submitClick(self.transcript, generation: generation)
        }
    }

    func resetConversation() {
        cancelClick()
        transcript = ""
        answer = ""
        error = nil
    }

    func cancelClick() {
        clickGeneration += 1
        clickPermissionTask?.cancel()
        clickPermissionTask = nil
        clickFinalizeTask?.cancel()
        clickFinalizeTask = nil
        clickSilenceTask?.cancel()
        clickSilenceTask = nil
        clickTurnTask?.cancel()
        clickTurnTask = nil
        clickInput?.cancel()
        clickInput = nil
        if let clickThreadID {
            services.stop(clickThreadID)
        }
        clickThreadID = nil
        clickSubmitted = false
        level = 0
        endProgress = 0
        guard clickState != .idle else { return }
        clickSpeech.shutUp()
        clickState = .idle
    }

    private func handleClickTranscript(_ text: String, generation: Int) {
        guard clickGeneration == generation else { return }
        switch clickState {
        case .listening, .thinking:
            clickInput = nil
            submitClick(text, generation: generation)
        default:
            break
        }
    }

    private func handleClickPartial(_ text: String, generation: Int) {
        guard clickGeneration == generation, clickState == .listening, !clickSubmitted, !text.isEmpty else { return }
        transcript = text
        _ = clickDetector?.transcript(at: services.now(), text: text, lastWordEnd: 0)
        armClickSilenceTimeout(generation: generation)
    }

    private func handleClickLevel(_ rms: Double, at time: TimeInterval, generation: Int) {
        guard clickGeneration == generation, clickState == .listening else { return }
        switch clickDetector?.frame(at: time, rms: rms) {
        case .commit?:
            finishListening()
        case .abort?:
            failClick("I didn’t hear anything. Check your microphone.")
        case .silence(_, let progress)?:
            meter(rms, progress: progress, at: time)
        default:
            meter(rms, progress: 0, at: time)
        }
    }

    private func meter(_ rms: Double, progress: Double, at time: TimeInterval) {
        guard time - clickMeteredAt >= 0.05 else { return }
        clickMeteredAt = time
        level = min(max((20 * log10(max(rms, 1e-7)) + 60) / 50, 0), 1)
        endProgress = progress
    }

    private func handleClickFailure(_ failure: Error, generation: Int) {
        guard clickGeneration == generation else { return }
        let message = (failure as? LocalizedError)?.errorDescription ?? "I couldn’t hear that. Try again."
        switch clickState {
        case .listening:
            failClick(message)
        case .thinking where !clickSubmitted:
            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failClick("I didn’t catch that. Try again.")
            } else {
                submitClick(transcript, generation: generation)
            }
        default:
            break
        }
    }

    private func submitClick(_ text: String, generation: Int) {
        guard clickGeneration == generation, !clickSubmitted else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            failClick("I didn’t catch that. Try again.")
            return
        }
        clickSubmitted = true
        clickFinalizeTask?.cancel()
        clickFinalizeTask = nil
        clickSilenceTask?.cancel()
        clickSilenceTask = nil
        transcript = trimmed
        clickState = .thinking
        clickInput = nil
        let run = services.run(services.acceptInput(trimmed, nil, nil), nil)
        clickThreadID = run.threadID
        clickTurnTask = Task { [weak self] in
            await self?.consumeClick(events: run.events, generation: generation)
        }
    }

    private func consumeClick(events: AsyncStream<AgentLoopEvent>, generation: Int) async {
        var markup = InlineMarkupParser(validElementIDs: [])
        var chunker = SentenceChunker()
        var completed = false
        var interrupted = false
        var failureMessage: String?
        for await event in events {
            guard clickGeneration == generation else { return }
            switch event {
            case .textDelta(let delta):
                let result = markup.feed(delta)
                if !result.text.isEmpty {
                    answer += result.text
                    for sentence in chunker.feed(result.text) {
                        clickState = .speaking
                        clickSpeech.speak(sentence)
                    }
                }
            case .finished(let outcome):
                switch outcome {
                case .completed:
                    completed = true
                case .interrupted, .paused:
                    interrupted = true
                default:
                    failureMessage = outcome.failureReason ?? "I couldn’t finish that answer. Try again."
                }
            case .toolCallStarted, .toolCallFinished, .note, .draw:
                break
            }
        }
        guard clickGeneration == generation else { return }
        if completed {
            let tail = markup.finish()
            if !tail.text.isEmpty {
                answer += tail.text
                for sentence in chunker.feed(tail.text) {
                    clickState = .speaking
                    clickSpeech.speak(sentence)
                }
            }
            if let remainder = chunker.finish() {
                clickState = .speaking
                clickSpeech.speak(remainder)
            }
            if clickState == .speaking {
                await waitForClickSpeechEnd()
            }
            guard clickGeneration == generation else { return }
            clickThreadID = nil
            clickState = .idle
            onTurnCompleted?()
        } else if interrupted {
            clickSpeech.shutUp()
            clickState = .idle
        } else {
            clickSpeech.shutUp()
            error = failureMessage ?? "I couldn’t answer that. Try again."
            clickState = .failed
        }
    }

    private func waitForClickSpeechEnd() async {
        if let speechDrain = services.speechDrain {
            await speechDrain()
            return
        }
        for _ in 0..<1200 {
            guard clickSpeech.isSpeaking, !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func armClickSilenceTimeout(generation: Int) {
        clickSilenceTask?.cancel()
        let timeout = services.silenceTimeout
        clickSilenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled, self.clickGeneration == generation, self.clickState == .listening else { return }
            self.failClick("I didn’t hear anything. Check your microphone.")
        }
    }

    private func failClick(_ message: String) {
        clickFinalizeTask?.cancel()
        clickFinalizeTask = nil
        clickSilenceTask?.cancel()
        clickSilenceTask = nil
        clickInput?.cancel()
        clickInput = nil
        error = message
        clickState = .failed
    }
}
