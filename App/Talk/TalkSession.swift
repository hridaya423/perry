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
        var route: (RouteRequirement) async throws -> RouteDecision
        var memory: () -> String? = { nil }
        var skill: (GuideObservation) -> String? = { _ in nil }
    }

    private let sessionController: SessionController
    private let overlayState: PerryCursorState
    private weak var output: (any GuideSessionOutput)?
    private let services: Services
    private let tracer: PointerTraceRecorder
    private let contexts: TalkContextStore

    private(set) var phase: Phase = .idle
    private var input: (any TalkSpeechInput)?
    private var captureTask: Task<GuideObservation, Error>?
    private var warmTask: Task<RouteDecision, Error>?
    private var turnTask: Task<Void, Never>?
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
        tracer: PointerTraceRecorder? = nil,
        contexts: TalkContextStore? = nil
    ) {
        self.sessionController = sessionController
        self.overlayState = overlayState
        self.output = output
        self.services = services
        self.tracer = tracer ?? .live()
        self.contexts = contexts ?? TalkContextStore()
    }

    // MARK: Draw tool surface (.talk allows only these)

    static let drawToolSpecs: [ToolSpec] = DrawCommand.Verb.allCases.map { verb in
        ToolSpec(
            name: verb.rawValue,
            description: verb == .clear
                ? "Clear all drawn marks."
                : "Draw a \(verb.rawValue) mark on the element with the given compact id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "elementID": .object([
                        "type": .string("string"),
                        "description": .string("Compact element id like e12"),
                    ]),
                    "label": .object(["type": .string("string")]),
                ]),
                "required": .array(verb == .clear ? [] : [.string("elementID")]),
            ])
        )
    }

    // MARK: Hold lifecycle

    /// Key-down: listening UI within the ≤50 ms budget, then parallel
    /// capture / STT / pointer trace / provider warm-up.
    func keyDown() {
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
            case .idle:
                let attemptID = UUID()
                try sessionController.wake(at: Date(), attemptID: attemptID)
                var talk = TalkSessionState(id: UUID(), startedAt: Date(), transcript: "")
                talk.isListening = true
                try sessionController.startTalk(talk, attemptID: attemptID)
            case .asking, .guiding, .executing, .reporting, .failed:
                output?.guideSetStatus("Finish or dismiss the current session before talking.")
                return
            }
        } catch {
            output?.guideSetStatus("Perry couldn't start listening.")
            return
        }

        phase = .listening
        overlayState.voiceState = .listening
        overlayState.buddyState = .listening
        sessionController.updateTalk { $0.isListening = true }
        output?.guideShowOverlay()
        PerfMark.mark("talk.listening")

        tracer.start()
        let speech = services.makeInput()
        input = speech
        Task { @MainActor [weak self, weak speech] in
            do {
                try await speech?.start()
            } catch {
                self?.inputFailed(error)
            }
        }
        captureTask = Task { @MainActor in try await services.capture() }
        warmTask = Task { @MainActor in
            let decision = try await services.route(RouteRequirement(
                capabilities: [.vision, .streaming], tier: .fast
            ))
            await decision.provider.warm()
            return decision
        }
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
        turnTask?.cancel()
        turnTask = nil
        captureTask?.cancel()
        captureTask = nil
        warmTask?.cancel()
        warmTask = nil
        input?.cancel()
        input = nil
        services.output.shutUp()
        PerfMark.mark("bargein.silence")
        sessionController.updateTalk { $0.isListening = false; $0.isWorking = false }
        overlayState.voiceState = .idle
        phase = .idle
    }

    /// Session teardown: stop everything; SessionController owns the transition.
    func cancel() {
        bargeIn()
        _ = tracer.stop()
        overlayState.visualGuidanceOverlays = []
        markOverlayIDs = []
        stopReanchor()
        overlayState.buddyState = .idle
    }

    private func inputFailed(_ error: Error) {
        // Settle the input even when the turn is already underway — otherwise
        // a start() failure after key-up would hang `finalize()` forever.
        input?.cancel()
        input = nil
        guard phase == .listening else { return }
        output?.guideSetStatus(
            (error as? LocalizedError)?.errorDescription ?? "Perry couldn't hear that."
        )
        sessionController.updateTalk { $0.isListening = false }
        overlayState.voiceState = .idle
        overlayState.buddyState = .idle
        phase = .idle
    }

    // MARK: Turn

    private func run(trace: [TraceSample]) async {
        do {
            guard let speech = input else { throw CancellationError() }
            let (transcript, words) = await speech.finalize()
            sessionController.updateTalk { $0.transcript = transcript }
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                output?.guideSetStatus("I didn't catch that — hold ⌃⌥ and try again.")
                overlayState.voiceState = .idle
                overlayState.buddyState = .idle
                sessionController.updateTalk { $0.isWorking = false }
                phase = .idle
                return
            }
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

            let elements = Self.observedElements(of: observation)
            index = ElementIndex(elements: elements)
            let bindings = DeixisResolver.resolve(words: words, trace: trace, elements: elements)
            let contextKey = TalkContextKey(
                processID: observation.processID ?? 0,
                windowID: observation.windowID ?? 0
            )
            if TalkContextStore.isResetPhrase(transcript) {
                contexts.reset(contextKey)
            }
            var conversation = contexts.conversation(for: contextKey)

            let decision = try await routeDecision(for: transcript, bindings: bindings, elements: elements)
            let tools = ToolGate.filter(
                Self.drawToolSpecs,
                for: .talk
            ).filter { _ in decision.provider.capabilities.contains(.tools) }
            let request = ModelRequest(
                system: TalkPrompt.system(
                    index: index,
                    bindings: bindings,
                    memory: services.memory(),
                    skill: services.skill(observation)
                ),
                messages: Self.messages(conversation: conversation, transcript: transcript, observation: observation),
                tools: tools,
                tier: TierClassifier.tier(question: transcript, bindingCount: bindings.count, elementCount: elements.count),
                maxOutputTokens: 1024
            )
            try await stream(request: request, provider: decision.provider, observation: observation)
            try? conversation.append(
                question: transcript,
                answer: SpatialAnswer(text: answerText, references: [], followUp: nil, observationID: observation.observationID)
            )
            contexts.update(contextKey, conversation: conversation)
        } catch is CancellationError {
            overlayState.voiceState = .idle
            overlayState.buddyState = .idle
            phase = .idle
        } catch {
            sessionController.updateTalk { $0.isWorking = false }
            overlayState.voiceState = .idle
            overlayState.buddyState = .blocked
            output?.guideSetStatus(
                (error as? ModelProviderError).map { AgentLoop.describe($0) }
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? "Perry couldn't answer that."
            )
            phase = .idle
        }
    }

    private func routeDecision(
        for transcript: String,
        bindings: [DeixisBinding],
        elements: [ObservedElement]
    ) async throws -> RouteDecision {
        let tier = TierClassifier.tier(question: transcript, bindingCount: bindings.count, elementCount: elements.count)
        defer { warmTask = nil }
        if tier == .fast, let warmed = try? await warmTask?.value {
            return warmed
        }
        return try await services.route(RouteRequirement(capabilities: [.vision, .streaming], tier: tier))
    }

    private func stream(request: ModelRequest, provider: any ModelProvider, observation: GuideObservation) async throws {
        var parser = InlineMarkupParser(validElementIDs: index.validIDs)
        var chunker = SentenceChunker()
        answerText = ""
        firstTextMarked = false
        firstInkMarked = false
        firstAudioMarked = false
        for try await event in provider.stream(request) {
            switch event {
            case .textDelta(let delta):
                let result = parser.feed(delta)
                if !result.text.isEmpty {
                    answerText += result.text
                    sessionController.updateTalk { $0.answerText = self.answerText }
                    if !firstTextMarked {
                        firstTextMarked = true
                        PerfMark.mark("answer.first_text")
                    }
                    for sentence in chunker.feed(result.text) {
                        speak(sentence)
                    }
                }
                for command in result.commands {
                    draw(command, observation: observation)
                }
            case .toolCall(let call):
                if let command = drawCommand(from: call) {
                    draw(command, observation: observation)
                }
            case .usage, .done:
                break
            }
        }
        let tail = parser.finish()
        if !tail.text.isEmpty {
            answerText += tail.text
            sessionController.updateTalk { $0.answerText = self.answerText }
            for sentence in chunker.feed(tail.text) {
                speak(sentence)
            }
        }
        for command in tail.commands {
            draw(command, observation: observation)
        }
        if let remainder = chunker.finish() {
            speak(remainder)
        }
        sessionController.updateTalk { $0.isWorking = false; $0.turnCount += 1 }
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
            let center = CGPoint(x: rect.midX, y: rect.midY)
            overlay = .scribble(points: [center, center], accentHex: accentHex, lineWidth: 6, caption: command.label)
        case .arrow:
            overlay = .scribble(
                points: [
                    CGPoint(x: rect.midX, y: rect.minY - 44),
                    CGPoint(x: rect.midX, y: rect.minY - 6),
                ],
                accentHex: accentHex, lineWidth: 5, caption: command.label
            )
        case .underline:
            overlay = .scribble(
                points: [
                    CGPoint(x: rect.minX, y: rect.maxY + 4),
                    CGPoint(x: rect.maxX, y: rect.maxY + 4),
                ],
                accentHex: accentHex, lineWidth: 4, caption: command.label
            )
        case .ring, .caption:
            overlay = .rectangle(rect: rect, accentHex: accentHex, caption: command.label)
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

    /// Model tool calls map to draw commands through the same validity gate the
    /// inline parser uses; anything else was already rejected by ToolGate.check.
    private func drawCommand(from call: ToolCall) -> DrawCommand? {
        guard ToolGate.check(call, on: .talk) == nil,
              let verb = DrawCommand.Verb(rawValue: call.name) else { return nil }
        let label = call.arguments["label"]?.stringValue
        if verb == .clear {
            return DrawCommand(verb: .clear, label: label)
        }
        guard let elementID = call.arguments["elementID"]?.stringValue,
              index.validIDs.contains(elementID) else { return nil }
        return DrawCommand(verb: verb, elementID: elementID, label: label)
    }

    // MARK: Mapping

    /// AXElements → ObservedElements for the resolver/prompt. Secure elements
    /// never reach the model — they are filtered here, before indexing.
    static func observedElements(of observation: GuideObservation) -> [ObservedElement] {
        let windowID = Int(observation.windowID ?? 0)
        return observation.snapshot.elements
            .filter { $0.sensitivity != .secure }
            .map { element in
                ObservedElement(
                    id: element.stableID,
                    role: element.rawRole ?? "AX\(element.role.rawValue)",
                    label: element.label ?? "",
                    frame: CGRect(
                        x: element.frame.x, y: element.frame.y,
                        width: element.frame.width, height: element.frame.height
                    ),
                    windowID: windowID
                )
            }
    }

    static func messages(
        conversation: SpatialConversation,
        transcript: String,
        observation: GuideObservation
    ) -> [ModelMessage] {
        var messages: [ModelMessage] = conversation.turns.flatMap { turn in
            [
                ModelMessage.user([.text(turn.question)]),
                ModelMessage.assistant(text: turn.answer.text, toolCalls: []),
            ]
        }
        var parts: [ModelContentPart] = [.text(transcript)]
        if let screenshot = observation.screenshotData {
            parts.append(.image(data: screenshot, mimeType: observation.screenshotMIMEType))
        }
        messages.append(.user(parts))
        return messages
    }
}
