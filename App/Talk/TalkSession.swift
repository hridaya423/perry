import AppKit
import PerryBrain
import PerryGuide
import PerryOverlay

/// The Talk loop: hold ⌃⌥ → listen + trace + capture in parallel → release →
/// deixis-bound prompt → streamed answer, spoken by sentence and drawn as ink.
/// Ask-never-acts is structural: the request only ever offers draw/observe
/// tools, and every model tool call passes `ToolGate.check` before dispatch.
/// All side effects are injected so the loop is unit-testable with stubs.
@MainActor
final class TalkSession {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case speaking
    }

    struct Services {
        var makeInput: () -> any TalkSpeechInput
        var output: any TalkSpeechOutput
        var capture: () async throws -> GuideObservation
        var acceptInput: (String, UUID?, TalkContextKey?) -> HomeController.AcceptedInput
        var targetHint: () -> CuaTargetHint = { CuaTargetHint() }
        var run: (HomeController.AcceptedInput, AgentCoordinator.SpatialContext) -> (threadID: UUID, events: AsyncStream<AgentLoopEvent>, completion: Task<Void, Never>?)
        var waitForConversation: (UUID) async -> Void = { _ in }
        var guide: ((HomeController.AcceptedInput, AgentCoordinator.SpatialContext, Bool) -> Void)? = nil
        var warm: () async -> Void = {}
        var skill: (GuideObservation) -> String? = { _ in nil }
    }

    let sessionController: SessionController
    let overlayState: PerryCursorState
    weak var output: (any GuideSessionOutput)?
    let services: Services
    private let tracer: PointerTraceRecorder

    private(set) var phase: Phase = .idle
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
    private var index = ElementIndex(elements: [])
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
                output?.guideReportFailure("Perry is still on your last request. Finish or stop it, then hold ⌃⌥ again.", recovery: nil)
                return
            }
        } catch {
            output?.guideReportFailure("Perry couldn’t start listening. Hold ⌃⌥ to try again.", recovery: nil)
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
        // Ack earcon at release so the user hears Perry took the request
        // immediately, whatever the brain (§Phase 1.4).
        output?.guidePlay(.send)
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
            (error as? LocalizedError)?.errorDescription ?? "Perry couldn’t hear that.",
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
                    "Perry can’t see your screen, so it answers from window text only. Turn on Screen Recording for Perry.",
                    recovery: .privacy("Privacy_ScreenCapture")
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
                    ?? "Perry couldn’t answer that.",
                recovery: error is ResponseError || error is ModelProviderError ? .settings(.runtimes) : nil
            )
            phase = .idle
        }
    }

    private static func recovery(forInput error: Error) -> FailureRecovery? {
        switch error as? DictationController.DictationError {
        case .permissionDenied?: .privacy("Privacy_Microphone")
        case .deviceUnavailable?: .settings(.voice)
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
                throw ResponseError(message: outcome.failureReason ?? "Perry couldn’t finish this answer.")
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

    private func draw(_ command: DrawCommand, observation: GuideObservation) {
        switch command.verb {
        case .clear:
            overlayState.visualGuidanceOverlays = []
            markOverlayIDs = []
            stopReanchor()
            return
        default:
            break
        }
        guard let element = index.element(for: command.elementID ?? "") else { return }
        let rect = AXCoordinateConverter.appKitRect(
            axX: element.frame.origin.x,
            axY: element.frame.origin.y,
            width: element.frame.width,
            height: element.frame.height,
            primaryScreenMaxY: primaryMaxY
        )
        // Luminance-adaptive ink (§5): sample the in-memory capture patch
        // under the mark; nil keeps the default mint accent.
        let accentHex = observation.screenshotData.flatMap { data in
            InkAccentSampler.accentHex(
                imageJPEG: data,
                elementCenterAX: CGPoint(x: element.frame.midX, y: element.frame.midY),
                windowBoundsAX: observation.windowBounds.map {
                    CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                } ?? .zero
            )
        } ?? "#34D399"
        let overlay: PerryGuidanceOverlay
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

}
